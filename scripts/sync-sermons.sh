#!/usr/bin/env bash
# Weekly sermon sync from this machine's IP.
#
# YouTube blocks transcript fetches from GitHub-hosted runners. This script
# keeps a separate checkout (so it never touches the working tree you edit),
# runs the same incremental sync as the old scheduled workflow, and pushes
# content/sermons so Netlify still builds.
#
# Config (gitignored, mode 600): ~/.config/impact-recap/config.yml
#   Copy from data/config.example.yml. Leave the proxy lines unset so
#   transcript requests come from this machine.
#
# Checkout: ~/.local/share/impact-recap/checkout
# Logs: journalctl --user -u impact-recap-sync.service

set -euo pipefail

REPO_URL="${IMPACT_RECAP_REPO_URL:-git@github.com:Tastypork/impact-recap.com.git}"
BRANCH="${IMPACT_RECAP_BRANCH:-main}"
STATE_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/impact-recap"
CHECKOUT="$STATE_ROOT/checkout"
CONFIG_SRC="${IMPACT_RECAP_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/impact-recap/config.yml}"
LOCK="$STATE_ROOT/sync.lock"

export GIT_TERMINAL_PROMPT=0

log() { printf '%s %s\n' "$(date -Is)" "$*"; }

wait_for_github() {
  local attempt
  for attempt in 1 2 3 4 5 6; do
    if git ls-remote "$REPO_URL" HEAD >/dev/null 2>&1; then
      return 0
    fi
    log "GitHub is not reachable yet (attempt ${attempt}/6); waiting for the network."
    sleep 10
  done
  log "Could not reach $REPO_URL"
  return 1
}

# Commit leftover sermon files from a previous run that died before push.
# Anything else in the checkout is unexpected; stop rather than mixing it in.
commit_pending_sermons() {
  local line path
  if [[ -z "$(git status --porcelain)" ]]; then
    return 0
  fi
  while IFS= read -r line; do
    path="${line:3}"
    case "$path" in
      content/sermons/* | data/failed/*) ;;
      *)
        log "Sync checkout has unexpected changes ($path). Leaving it untouched."
        return 1
        ;;
    esac
  done < <(git status --porcelain)

  git add -- content/sermons
  if [[ -d data/failed ]]; then
    git add -- data/failed
  fi
  if git diff --cached --quiet; then
    return 0
  fi
  git commit -m "Sync sermons (incremental)"
}

push_if_ahead() {
  git fetch origin "$BRANCH"
  if [[ "$(git rev-parse HEAD)" == "$(git rev-parse "origin/$BRANCH")" ]]; then
    log "Nothing to push."
    return 0
  fi
  git push origin "HEAD:$BRANCH"
  log "Pushed sermon sync to origin/$BRANCH."
}

mkdir -p "$STATE_ROOT"
exec 9>"$LOCK"
if ! flock -n 9; then
  log "Another sync is already running."
  exit 0
fi

if [[ ! -f "$CONFIG_SRC" ]]; then
  log "Missing $CONFIG_SRC"
  log "Copy data/config.example.yml there and set channel_id, yt_token, and claude_token."
  exit 1
fi

wait_for_github

if [[ ! -d "$CHECKOUT/.git" ]]; then
  log "Cloning $REPO_URL into $CHECKOUT"
  git clone --branch "$BRANCH" "$REPO_URL" "$CHECKOUT"
fi

cd "$CHECKOUT"
git fetch origin "$BRANCH"
git checkout "$BRANCH"
commit_pending_sermons
git pull --rebase origin "$BRANCH"

install -m 600 "$CONFIG_SRC" data/config.yml

if [[ ! -x .venv/bin/python ]]; then
  python3 -m venv .venv
fi
.venv/bin/pip install -q -r requirements-sync.txt

set +e
.venv/bin/python video_sync.py --mode incremental -n 3
sync_status=$?
set -e

commit_pending_sermons
git pull --rebase origin "$BRANCH"
push_if_ahead

exit "$sync_status"
