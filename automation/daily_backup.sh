#!/bin/bash
if [ -z "${BASH_VERSION:-}" ]; then
  exec /bin/bash "$0" "$@"
fi
set -euo pipefail

# Where to store backups; override by exporting BACKUP_ROOT before running.
BACKUP_ROOT="${BACKUP_ROOT:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/Backups}"
# Resolve repo root relative to this script to avoid hardcoding user paths.
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_OUT="/tmp/daily_backup.out"
LOG_ERR="/tmp/daily_backup.err"
MIN_INTERVAL_SECONDS=$((48 * 3600))
LAST_RUN_FILE="$BACKUP_ROOT/.last_backup_timestamp"

# Truncate launchd log files at start so each run is fresh (launchd appends by default).
: > "$LOG_OUT"
: > "$LOG_ERR"

notify() {
  local message="${1//\"/\\\"}"
  local title="${2//\"/\\\"}"

  # Try direct notification first (works when the script already runs in the GUI session).
  if command -v osascript >/dev/null 2>&1; then
    if /usr/bin/osascript -e "display notification \"$message\" with title \"$title\"" >/dev/null 2>&1; then
      return
    fi
  fi

  # If running outside the GUI session (e.g., as a LaunchDaemon), target the console user explicitly.
  local console_user console_uid
  console_user=$(stat -f "%Su" /dev/console 2>/dev/null || true)
  if [ -n "$console_user" ]; then
    console_uid=$(id -u "$console_user" 2>/dev/null || true)
    if [ -n "$console_uid" ]; then
      launchctl asuser "$console_uid" sudo -u "$console_user" /usr/bin/osascript -e \
        "display notification \"$message\" with title \"$title\"" >/dev/null 2>&1 || \
        logger "daily_backup: failed to send notification to $console_user"
    fi
  fi
}

mkdir -p "$BACKUP_ROOT"

# Skip the run if the last successful backup finished less than 48 hours ago.
now_epoch=$(date +%s)
if [ -f "$LAST_RUN_FILE" ]; then
  last_run_epoch=$(cat "$LAST_RUN_FILE" 2>/dev/null || true)
  if [[ "$last_run_epoch" =~ ^[0-9]+$ ]]; then
    elapsed=$((now_epoch - last_run_epoch))
    if [ "$elapsed" -lt "$MIN_INTERVAL_SECONDS" ]; then
      hours=$((elapsed / 3600))
      message="Last backup finished ${hours}h ago; skipping to keep an every-other-day cadence."
      echo "$message" >> "$LOG_OUT"
      notify "$message" "Daily Backup"
      exit 0
    fi
  fi
fi

notify "Starting daily backup…" "Daily Backup"
trap 'notify "Daily backup failed." "Daily Backup"' ERR

# Run the main backup script, keeping only the tarball output.
BACKUP_ROOT="$BACKUP_ROOT" /bin/bash "$SCRIPT_DIR/backup_mac.sh" tar --clean

# Keep only the 5 most recent backups.
cd "$BACKUP_ROOT"
prune_list=$(ls -1t System_Backup_*.tgz 2>/dev/null | tail -n +6 || true)
if [ -n "$prune_list" ]; then
  printf '%s\n' "$prune_list" | xargs rm --
fi

printf '%s' "$(date +%s)" > "$LAST_RUN_FILE"

notify "Daily backup completed." "Daily Backup"
