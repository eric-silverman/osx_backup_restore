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

# Skip the run if a backup already completed today.
today=$(date +%F)
if [ -f "$LAST_RUN_FILE" ]; then
  last_run_raw=$(cat "$LAST_RUN_FILE" 2>/dev/null || true)
  last_run_date="$last_run_raw"
  if [[ "$last_run_raw" =~ ^[0-9]+$ ]]; then
    last_run_date=$(date -r "$last_run_raw" +%F 2>/dev/null || true)
  fi
  if [ -n "$last_run_date" ] && [ "$last_run_date" = "$today" ]; then
    message="Backup already completed on $today; skipping to keep one backup per day."
    echo "$message" >> "$LOG_OUT"
    notify "$message" "Daily Backup"
    exit 0
  fi
fi

notify "Starting daily backup…" "Daily Backup"
trap 'notify "Daily backup failed." "Daily Backup"' ERR

# Run the main backup script, keeping only the tarball output.
BACKUP_ROOT="$BACKUP_ROOT" /bin/bash "$SCRIPT_DIR/backup_mac.sh" tar --clean

# Keep only the 10 most recent backups.
cd "$BACKUP_ROOT"
echo "🧹 Pruning backups in $BACKUP_ROOT (keep 10)..."
shopt -s nullglob
backups=(System_Backup_*.tgz System_Backup_*.tgz.icloud)
if [ ${#backups[@]} -eq 0 ]; then
  echo "   ℹ️  No backups matched System_Backup_*.tgz; skipping prune."
else
  mapfile -t sorted_backups < <(ls -1t -- "${backups[@]}")
  total_backups=${#sorted_backups[@]}
  echo "   📦 Found $total_backups backups."
  if [ "$total_backups" -gt 10 ]; then
    prune_list=("${sorted_backups[@]:10}")
    prune_count=${#prune_list[@]}
    echo "   🗑️  Pruning $prune_count backups:"
    printf '%s\n' "${prune_list[@]}"
    rm -- "${prune_list[@]}"
  else
    echo "   ✅ Nothing to prune."
  fi
fi

printf '%s' "$today" > "$LAST_RUN_FILE"

notify "Daily backup completed." "Daily Backup"
