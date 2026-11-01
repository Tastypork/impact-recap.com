# Weekly sermon sync from this PC's IP.
#
# YouTube blocks transcript fetches from GitHub-hosted runners. This script
# keeps a separate checkout (so it never touches the working tree you edit),
# runs the same incremental sync as the old scheduled workflow, and pushes
# content/sermons so Netlify still builds.
#
# Requires Windows PowerShell 5.1, Git for Windows, and Python 3.10+.
#
# Config: %APPDATA%\impact-recap\config.yml
#   Copy from data\config.example.yml. Leave the proxy lines unset so
#   transcript requests come from this PC.
# Checkout: %LOCALAPPDATA%\impact-recap\checkout
# Log: %LOCALAPPDATA%\impact-recap\sync.log

$ErrorActionPreference = "Stop"

$RepoUrl = if ($env:IMPACT_RECAP_REPO_URL) { $env:IMPACT_RECAP_REPO_URL } else { "git@github.com:Tastypork/impact-recap.com.git" }
$Branch = if ($env:IMPACT_RECAP_BRANCH) { $env:IMPACT_RECAP_BRANCH } else { "main" }
$StateRoot = Join-Path $env:LOCALAPPDATA "impact-recap"
$Checkout = Join-Path $StateRoot "checkout"
$ConfigSrc = if ($env:IMPACT_RECAP_CONFIG) { $env:IMPACT_RECAP_CONFIG } else { Join-Path $env:APPDATA "impact-recap\config.yml" }
$LogFile = Join-Path $StateRoot "sync.log"

$env:GIT_TERMINAL_PROMPT = "0"

function Write-Log([string]$Message) {
    $line = "{0} {1}" -f (Get-Date).ToString("o"), $Message
    Add-Content -Path $LogFile -Value $line -Encoding utf8
    Write-Host $line
}

function Add-GitToPath {
    $candidates = @(
        (Join-Path $env:ProgramFiles "Git\cmd"),
        (Join-Path ${env:ProgramFiles(x86)} "Git\cmd"),
        (Join-Path $env:LOCALAPPDATA "Programs\Git\cmd")
    )
    foreach ($dir in $candidates) {
        if ($dir -and (Test-Path (Join-Path $dir "git.exe"))) {
            $env:PATH = "$dir;$env:PATH"
            break
        }
    }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "git was not found. Install Git for Windows, then open a new PowerShell window."
    }
}

function Invoke-Git {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GitArgs)
    & git @GitArgs
    if ($LASTEXITCODE -ne 0) {
        throw "git $($GitArgs -join ' ') failed ($LASTEXITCODE)"
    }
}

function Wait-ForGitHub {
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        & git ls-remote $RepoUrl HEAD *> $null
        if ($LASTEXITCODE -eq 0) { return }
        Write-Log "GitHub is not reachable yet (attempt $attempt/6); waiting for the network."
        Start-Sleep -Seconds 10
    }
    throw "Could not reach $RepoUrl"
}

function Test-SermonPath([string]$Path) {
    return ($Path -like "content/sermons/*") -or ($Path -like "data/failed/*")
}

# Commit leftover sermon files from a previous run that died before push.
# Anything else in the checkout is unexpected; stop rather than mixing it in.
function Commit-PendingSermons {
    $status = @(& git status --porcelain)
    if ($LASTEXITCODE -ne 0) { throw "git status failed ($LASTEXITCODE)" }
    if ($status.Count -eq 0) { return }

    foreach ($line in $status) {
        if ($line.Length -lt 4) { throw "Could not parse git status line: $line" }
        $rest = $line.Substring(3).Trim()
        foreach ($part in ($rest -split " -> ")) {
            $path = $part.Trim().Trim('"')
            if (-not (Test-SermonPath $path)) {
                throw "Sync checkout has unexpected changes ($path). Leaving it untouched."
            }
        }
    }

    Invoke-Git add -- content/sermons
    if (Test-Path "data/failed") {
        Invoke-Git add -- data/failed
    }
    & git diff --cached --quiet
    if ($LASTEXITCODE -eq 0) { return }
    if ($LASTEXITCODE -gt 1) { throw "git diff failed ($LASTEXITCODE)" }
    Invoke-Git commit -m "Sync sermons (incremental)"
}

function Push-IfAhead {
    Invoke-Git fetch origin $Branch
    $head = (& git rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0) { throw "git rev-parse HEAD failed" }
    $remote = (& git rev-parse "origin/$Branch").Trim()
    if ($LASTEXITCODE -ne 0) { throw "git rev-parse origin/$Branch failed" }
    if ($head -eq $remote) {
        Write-Log "Nothing to push."
        return
    }
    Invoke-Git push origin "HEAD:${Branch}"
    Write-Log "Pushed sermon sync to origin/$Branch."
}

New-Item -ItemType Directory -Force -Path $StateRoot | Out-Null
Add-GitToPath

$lockStream = $null
$lockPath = Join-Path $StateRoot "sync.lock"
try {
    $lockStream = [System.IO.File]::Open(
        $lockPath,
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )
} catch [System.IO.IOException] {
    Write-Log "Another sync is already running."
    exit 0
}

try {
    if (-not (Test-Path -LiteralPath $ConfigSrc)) {
        throw "Missing $ConfigSrc. Copy data\config.example.yml there and set channel_id, yt_token, and claude_token."
    }

    Wait-ForGitHub

    if (-not (Test-Path (Join-Path $Checkout ".git"))) {
        Write-Log "Cloning $RepoUrl into $Checkout"
        Invoke-Git clone --branch $Branch $RepoUrl $Checkout
    }

    Set-Location $Checkout
    Invoke-Git fetch origin $Branch
    Invoke-Git checkout $Branch
    Commit-PendingSermons
    Invoke-Git pull --rebase origin $Branch

    Copy-Item -LiteralPath $ConfigSrc -Destination (Join-Path $Checkout "data\config.yml") -Force

    $python = Join-Path $Checkout ".venv\Scripts\python.exe"
    if (-not (Test-Path $python)) {
        if (Get-Command py -ErrorAction SilentlyContinue) {
            & py -3 -m venv .venv
        } elseif (Get-Command python -ErrorAction SilentlyContinue) {
            & python -m venv .venv
        } else {
            throw "Python 3 was not found. Install Python 3.10+ from python.org and include the py launcher."
        }
        if ($LASTEXITCODE -ne 0) { throw "Could not create the virtual environment ($LASTEXITCODE)." }
        $python = Join-Path $Checkout ".venv\Scripts\python.exe"
    }

    & $python -m pip install -q -r requirements-sync.txt
    if ($LASTEXITCODE -ne 0) { throw "pip install failed ($LASTEXITCODE)" }

    & $python video_sync.py --mode incremental
    $syncStatus = $LASTEXITCODE

    Commit-PendingSermons
    Invoke-Git pull --rebase origin $Branch
    Push-IfAhead

    exit $syncStatus
} catch {
    Write-Log $_.Exception.Message
    exit 1
} finally {
    if ($lockStream) { $lockStream.Dispose() }
}
