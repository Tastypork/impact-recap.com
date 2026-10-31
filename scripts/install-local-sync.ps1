# Register a Task Scheduler job that runs scripts\sync-sermons.ps1.
# Sunday 18:00 and Monday 06:00 MST (UTC-7, no daylight saving).
# StartWhenAvailable runs a missed job the next time this PC is on and you are logged in.
# Re-run this script to update the task after the repo moves or the schedule changes.

$ErrorActionPreference = "Stop"

$syncScript = Join-Path $PSScriptRoot "sync-sermons.ps1"
if (-not (Test-Path -LiteralPath $syncScript)) {
    throw "Could not find $syncScript"
}

$configDir = Join-Path $env:APPDATA "impact-recap"
New-Item -ItemType Directory -Force -Path $configDir | Out-Null

$userId = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$syncScript`""
$argumentsXml = [System.Security.SecurityElement]::Escape($arguments)
$userIdXml = [System.Security.SecurityElement]::Escape($userId)

$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Sync Impact Church sermons Sunday at 6:00 PM MST and Monday at 6:00 AM MST.</Description>
  </RegistrationInfo>
  <Triggers>
    <CalendarTrigger>
      <StartBoundary>2026-11-01T18:00:00-07:00</StartBoundary>
      <RandomDelay>PT2M</RandomDelay>
      <ScheduleByWeek>
        <DaysOfWeek>
          <Sunday />
        </DaysOfWeek>
        <WeeksInterval>1</WeeksInterval>
      </ScheduleByWeek>
    </CalendarTrigger>
    <CalendarTrigger>
      <StartBoundary>2026-11-02T06:00:00-07:00</StartBoundary>
      <RandomDelay>PT2M</RandomDelay>
      <ScheduleByWeek>
        <DaysOfWeek>
          <Monday />
        </DaysOfWeek>
        <WeeksInterval>1</WeeksInterval>
      </ScheduleByWeek>
    </CalendarTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$userIdXml</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <WakeToRun>true</WakeToRun>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <ExecutionTimeLimit>PT2H</ExecutionTimeLimit>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>$argumentsXml</Arguments>
    </Exec>
  </Actions>
</Task>
"@

Register-ScheduledTask -TaskName "ImpactRecapSync" -Xml $xml -Force | Out-Null

$info = Get-ScheduledTaskInfo -TaskName "ImpactRecapSync"
Write-Host "Registered ImpactRecapSync."
Write-Host ("Next run: {0}" -f $info.NextRunTime)
Write-Host "The task runs while you are logged in, including when the screen is locked."
Write-Host "To wake a sleeping PC, enable Allow wake timers in Power Options."
Write-Host ""

$configPath = Join-Path $configDir "config.yml"
if (Test-Path -LiteralPath $configPath) {
    Write-Host "Config: $configPath"
} else {
    $example = Join-Path (Split-Path -Parent $PSScriptRoot) "data\config.example.yml"
    Write-Host "Still needed: $configPath"
    Write-Host "  copy `"$example`" `"$configPath`""
    Write-Host "Fill in channel_id, yt_token, and claude_token. Leave the proxy lines unset."
}

Write-Host ""
Write-Host "Run once now:"
Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -File `"$syncScript`""
Write-Host "Log: $(Join-Path $env:LOCALAPPDATA 'impact-recap\sync.log')"
