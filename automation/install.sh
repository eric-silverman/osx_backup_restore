#!/bin/bash
set -euo pipefail

# Interactive setup for macOS Backup Automation.
# Detects values, shows a summary, and installs the LaunchAgent + sudoers drop-in.
# Usage: ./automation/install.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Detect values ──────────────────────────────────────────────────────────

USER_NAME="$(id -un)"
DAILY_SCRIPT="$SCRIPT_DIR/daily_backup.sh"
PLIST_DEST="$HOME/Library/LaunchAgents/com.osxbackup.daily.plist"
SUDOERS_DEST="/etc/sudoers.d/osx_backup_restore"
STAGING_ROOT="${STAGING_ROOT:-${TMPDIR:-/tmp}/mac_backup_staging}"
BACKUP_ROOT="${BACKUP_ROOT:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/Backups}"
DEFAULT_HOUR=15
DEFAULT_MINUTE=15

# ── Display summary ───────────────────────────────────────────────────────

printf '\nmacOS Backup Automation Setup\n'
printf '─────────────────────────────\n'
printf '  User:           %s\n' "$USER_NAME"
printf '  Repo:           %s\n' "$REPO_ROOT"
printf '  Backup dest:    %s\n' "$BACKUP_ROOT"
printf '  Staging dir:    %s\n' "$STAGING_ROOT"
printf '\n'
printf '  This will:\n'
printf '    1. Install LaunchAgent  → %s\n' "$PLIST_DEST"
printf '    2. Configure sudoers    → %s\n' "$SUDOERS_DEST"
printf '\n'

# ── Prompt for schedule ───────────────────────────────────────────────────

read -rp "Backup schedule (HH:MM) [$DEFAULT_HOUR:$(printf '%02d' $DEFAULT_MINUTE)]: " schedule_input
schedule_input="${schedule_input:-$DEFAULT_HOUR:$(printf '%02d' $DEFAULT_MINUTE)}"

if [[ ! "$schedule_input" =~ ^[0-9]{1,2}:[0-9]{2}$ ]]; then
  echo "Invalid format. Use HH:MM (e.g. 15:15)." >&2
  exit 1
fi

HOUR="${schedule_input%%:*}"
MINUTE="${schedule_input#*:}"

# Strip leading zeros for arithmetic comparison.
HOUR_NUM=$((10#$HOUR))
MINUTE_NUM=$((10#$MINUTE))
if (( HOUR_NUM < 0 || HOUR_NUM > 23 || MINUTE_NUM < 0 || MINUTE_NUM > 59 )); then
  echo "Time out of range. Hour 0-23, Minute 0-59." >&2
  exit 1
fi

printf '  Schedule:       daily at %d:%02d\n\n' "$HOUR_NUM" "$MINUTE_NUM"

# ── Confirm ───────────────────────────────────────────────────────────────

read -rp "Proceed? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi
printf '\n'

# ── Step 1: Install LaunchAgent ───────────────────────────────────────────

echo "Installing LaunchAgent…"

launch_args=()
if (( HOUR_NUM != DEFAULT_HOUR )); then
  launch_args+=(--hour "$HOUR_NUM")
fi
if (( MINUTE_NUM != DEFAULT_MINUTE )); then
  launch_args+=(--minute "$MINUTE_NUM")
fi

"$SCRIPT_DIR/update_launch_agent.sh" ${launch_args[@]+"${launch_args[@]}"}
printf '\n'

# ── Step 2: Sudoers ──────────────────────────────────────────────────────

echo "Sudoers preview:"
"$SCRIPT_DIR/setup_sudoers.sh"

read -rp "Install sudoers drop-in? (requires sudo) [y/N] " sudoers_confirm
if [[ "$sudoers_confirm" =~ ^[Yy]$ ]]; then
  "$SCRIPT_DIR/setup_sudoers.sh" --apply
fi
printf '\n'

# ── Post-install checklist ────────────────────────────────────────────────

printf 'Done! Manual step remaining:\n'
printf '  Grant Full Disk Access (System Settings → Privacy & Security) to:\n'
printf '    /usr/bin/rsync\n'
printf '    /opt/homebrew/bin/rsync\n'
printf '    /opt/homebrew/bin/gtar\n'
printf '\n'
