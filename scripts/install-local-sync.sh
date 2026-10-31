#!/usr/bin/env bash
# Install a systemd user timer that runs scripts/sync-sermons.sh.
# Sunday 18:00 and Monday 06:00 America/Phoenix (MST, no daylight saving).
# Persistent=true runs a missed job the next time this machine is on.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/impact-recap"
SERVICE="$UNIT_DIR/impact-recap-sync.service"
TIMER="$UNIT_DIR/impact-recap-sync.timer"

mkdir -p "$UNIT_DIR" "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

cat >"$SERVICE" <<EOF
[Unit]
Description=Sync Impact Church sermons from this machine

[Service]
Type=oneshot
ExecStart=$ROOT/scripts/sync-sermons.sh
EOF

cat >"$TIMER" <<EOF
[Unit]
Description=Sync Impact Church sermons Sunday at 6:00 PM MST and Monday at 6:00 AM MST

[Timer]
OnCalendar=Sun *-*-* 18:00:00 America/Phoenix
OnCalendar=Mon *-*-* 06:00:00 America/Phoenix
Persistent=true
RandomizedDelaySec=2min

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now impact-recap-sync.timer

if loginctl show-user "$USER" -p Linger --value 2>/dev/null | grep -qx yes; then
  echo "Linger is already enabled; the timer runs when you are logged out."
elif loginctl enable-linger "$USER" 2>/dev/null; then
  echo "Enabled linger so the timer runs when you are logged out."
else
  echo "Could not enable linger. The timer runs only while you are logged in."
  echo "To run it after reboot before you log in: loginctl enable-linger $USER"
fi

echo
systemctl --user list-timers impact-recap-sync.timer --no-pager
echo
if [[ -f "$CONFIG_DIR/config.yml" ]]; then
  echo "Config: $CONFIG_DIR/config.yml"
else
  echo "Still needed: $CONFIG_DIR/config.yml"
  echo "  cp $ROOT/data/config.example.yml $CONFIG_DIR/config.yml"
  echo "  chmod 600 $CONFIG_DIR/config.yml"
  echo "Fill in channel_id, yt_token, and claude_token. Leave the proxy lines unset."
fi
echo
echo "Run once now: $ROOT/scripts/sync-sermons.sh"
echo "Logs: journalctl --user -u impact-recap-sync.service"
