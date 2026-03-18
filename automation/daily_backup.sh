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
# Local state directory — NOT in iCloud Drive — avoids bird daemon contention
# that silently breaks reads/writes on files in ~/Library/Mobile Documents.
STATE_DIR="$HOME/.local/share/osx_backup_restore"
mkdir -p "$STATE_DIR"
LAST_RUN_FILE="$STATE_DIR/last_backup_timestamp"
MANIFEST_FILE="$STATE_DIR/backup_manifest"
# Handoff file: backup_mac.sh writes the newly created archive path here so we
# can register it in the manifest without listing the iCloud Drive directory
# (which appears empty from a LaunchAgent context).
BACKUP_MANIFEST_HANDOFF="$STATE_DIR/last_backup_path"

# One-time migration from old iCloud-based state files.
_old_ts="$BACKUP_ROOT/.last_backup_timestamp"
_old_mf="$BACKUP_ROOT/.backup_manifest"
if [ ! -f "$LAST_RUN_FILE" ] && [ -f "$_old_ts" ]; then
  cp "$_old_ts" "$LAST_RUN_FILE" 2>/dev/null || true
fi
if [ ! -f "$MANIFEST_FILE" ] && [ -f "$_old_mf" ]; then
  cp "$_old_mf" "$MANIFEST_FILE" 2>/dev/null || true
fi

# Truncate launchd log files at start so each run is fresh (launchd appends by default).
: > "$LOG_OUT"
: > "$LOG_ERR"

notify() {
  # Usage: notify "message" "title" ["subtitle"]
  local message="${1//\"/\\\"}"
  local title="${2//\"/\\\"}"
  local subtitle="${3:-}"
  subtitle="${subtitle//\"/\\\"}"

  local script="display notification \"$message\" with title \"$title\""
  if [ -n "$subtitle" ]; then
    script="display notification \"$message\" with title \"$title\" subtitle \"$subtitle\""
  fi

  # Try direct notification first (works when the script already runs in the GUI session).
  if /usr/bin/osascript -e "$script" >/dev/null 2>&1; then
    return
  fi

  # If running outside the GUI session (e.g., as a LaunchDaemon), target the console user explicitly.
  local console_user console_uid
  console_user=$(stat -f "%Su" /dev/console 2>/dev/null || true)
  if [ -n "$console_user" ]; then
    console_uid=$(id -u "$console_user" 2>/dev/null || true)
    if [ -n "$console_uid" ]; then
      launchctl asuser "$console_uid" sudo -u "$console_user" /usr/bin/osascript -e \
        "$script" >/dev/null 2>&1 || \
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
    echo "Backup already completed on $today; skipping to keep one backup per day." >> "$LOG_OUT"
    notify "Already ran today — skipping." "Daily Backup — Skipped" "$today"
    exit 0
  fi
fi

BACKUP_START=$SECONDS
_avail_gb="?"
_avail_raw=$(df -k "$HOME" 2>/dev/null | awk 'NR==2{print $4}')
if [ -n "$_avail_raw" ] && [ "$_avail_raw" -gt 0 ] 2>/dev/null; then
  _avail_gb=$(( _avail_raw / 1024 / 1024 ))
fi
notify "Rsync + compress to iCloud Drive" "Daily Backup — Starting" "${_avail_gb} GB free on disk"
trap 'notify "Line $LINENO: $BASH_COMMAND" "Daily Backup — Failed" "Check /tmp/daily_backup.{out,err}"' ERR

# Pre-flight: check that the staging volume has enough free space.
# With gtar available (the normal case), the home folder is streamed directly
# into the .tgz with no intermediate rsync copy.  Peak disk use is roughly the
# staged config files (~5-30 GB) plus the growing .tgz — 50 GB is a safe min.
# Without gtar (fallback), a full rsync staging copy is made first; peak usage
# is ~170 GB plus the .tgz, so 200 GB is required.
STAGING_ROOT="${STAGING_ROOT:-${TMPDIR:-/tmp}/mac_backup_staging}"
mkdir -p "$STAGING_ROOT" 2>/dev/null || true
avail_kb=$(df -k "$STAGING_ROOT" 2>/dev/null | awk 'NR==2{print $4}')
if command -v gtar >/dev/null 2>&1; then
  min_kb=$((50 * 1024 * 1024))   # 50 GB — staged configs + compressed .tgz
  min_label="50 GB"
else
  min_kb=$((200 * 1024 * 1024))  # 200 GB — full rsync staging copy + .tgz
  min_label="200 GB"
fi
if [ -n "$avail_kb" ] && [ "$avail_kb" -lt "$min_kb" ] 2>/dev/null; then
  avail_gb=$(( avail_kb / 1024 / 1024 ))
  echo "❌ Staging volume has only ${avail_gb} GB free (need ~${min_label}). Aborting." >&2
  notify "Only ${avail_gb} GB free — need at least ${min_label}. Free up space and retry." "Daily Backup — Aborted" "Not enough disk space"
  exit 1
fi

# Run the main backup script.
# Pass BACKUP_MANIFEST_HANDOFF so backup_mac.sh can write the archive path to
# a local file; we read it back below to seed the manifest without needing to
# list the iCloud Drive directory (invisible from LaunchAgent context).
BACKUP_ROOT="$BACKUP_ROOT" BACKUP_MANIFEST_HANDOFF="$BACKUP_MANIFEST_HANDOFF" \
  /bin/bash "$SCRIPT_DIR/backup_mac.sh" tar --clean

# Register the newly created backup in the manifest via the handoff file.
# This is the primary manifest-update path; the /bin/ls merge loop below is
# a secondary pass that may not see any files when running as a LaunchAgent.
_new_backup=$(cat "$BACKUP_MANIFEST_HANDOFF" 2>/dev/null | head -1 | tr -d '\n')
if [ -n "$_new_backup" ]; then
  grep -qxF "$_new_backup" "$MANIFEST_FILE" 2>/dev/null || \
    echo "$_new_backup" >> "$MANIFEST_FILE"
fi

# Prune first, then record the timestamp.  This way even if the timestamp
# write fails (iCloud "Resource deadlock avoided"), old backups are already
# cleaned up and the only consequence is a possible duplicate run today.

# Keep only the 10 most recent backups.
# The manifest tracks backups because iCloud Drive can make directory contents
# invisible to glob/ls from a LaunchAgent context (cloud-only files have no
# local placeholder visible to the shell).  The manifest is stored locally
# (in STATE_DIR) so it's always readable/writable without iCloud contention.

# Merge any visible files into the manifest so it stays in sync.
# Use /bin/ls instead of bash glob — iCloud's FUSE-like filesystem can make
# files invisible to glob expansion even when /bin/ls can list them.
_visible_list=$(mktemp /tmp/backup_visible.XXXXXX 2>/dev/null || mktemp)
while IFS= read -r fname; do
  [ -z "$fname" ] && continue
  if [[ "$fname" == .System_Backup_*.icloud ]]; then
    # Normalise .icloud placeholder to its real .tgz path.
    real=${fname#.}
    real=${real%.icloud}
    entry="$BACKUP_ROOT/$real"
  elif [[ "$fname" == System_Backup_*.tgz ]]; then
    entry="$BACKUP_ROOT/$fname"
  else
    continue
  fi
  echo "$entry" >> "$_visible_list"
  grep -qxF "$entry" "$MANIFEST_FILE" 2>/dev/null || \
    echo "$entry" >> "$MANIFEST_FILE"
done < <(/bin/ls -1 "$BACKUP_ROOT" 2>/dev/null)

# Reconcile: drop manifest entries whose backups no longer exist on disk.
# Only when the directory was readable (at least one backup file visible) so we
# don't wipe the manifest when iCloud makes the entire directory invisible.
if [ -s "$_visible_list" ]; then
  _stale=0
  _kept=()
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    if grep -qxF "$line" "$_visible_list" 2>/dev/null; then
      _kept+=("$line")
    else
      _stale=$((_stale + 1))
      echo "   ♻️  Stale manifest entry removed: $(basename "$line")"
    fi
  done < "$MANIFEST_FILE"
  if [ "$_stale" -gt 0 ]; then
    echo "   Removed $_stale stale entries from manifest."
    printf '%s\n' "${_kept[@]}" > "$MANIFEST_FILE"
  fi
fi
rm -f "$_visible_list"

echo "🧹 Pruning backups in $BACKUP_ROOT (keep 10)..."

# Read manifest, sort by embedded timestamp (descending), prune oldest.
sorted_backups=()
while IFS= read -r line; do
  [ -z "$line" ] && continue
  sorted_backups+=("$line")
done < <(sort -u -t_ -k3,4 -r "$MANIFEST_FILE" 2>/dev/null)

total_backups=${#sorted_backups[@]}
echo "   📦 Manifest lists $total_backups backups."

prune_count=0
if [ "$total_backups" -gt 10 ]; then
  prune_list=("${sorted_backups[@]:10}")
  prune_count=${#prune_list[@]}
  echo "   🗑️  Pruning $prune_count backups:"
  for target in "${prune_list[@]}"; do
    echo "      $target"
    b=$(basename "$target")
    rm -f -- "$target" "$BACKUP_ROOT/.$b.icloud" 2>/dev/null || true
  done
  # Rewrite the manifest with only the kept entries.
  printf '%s\n' "${sorted_backups[@]:0:10}" > "$MANIFEST_FILE"
else
  echo "   ✅ Nothing to prune."
fi

# Evict local copies of all kept backups so they remain cloud-only.
echo "☁️  Evicting local copies of kept backups from iCloud…"
_brctl=""
if command -v brctl >/dev/null 2>&1; then
  _brctl="$(command -v brctl)"
elif [ -x "/System/Library/PrivateFrameworks/CloudDocsDaemon.framework/Versions/A/Support/brctl" ]; then
  _brctl="/System/Library/PrivateFrameworks/CloudDocsDaemon.framework/Versions/A/Support/brctl"
fi

if [ -n "$_brctl" ]; then
  while IFS= read -r _kept_backup; do
    [ -z "$_kept_backup" ] && continue
    # Only evict if the file is locally present; cloud-only placeholders can be skipped.
    if [ -f "$_kept_backup" ]; then
      "$_brctl" evict "$_kept_backup" >/dev/null 2>&1 && \
        echo "   ☁️  Evicted local copy: $(basename "$_kept_backup")" || true
    fi
  done < "$MANIFEST_FILE"
  echo "   ✅ Done — kept backups are cloud-only."
else
  echo "   ℹ️  brctl not available; kept backups may remain locally downloaded."
fi

# Record today's date so the next launchd trigger skips re-running today.
printf '%s' "$today" > "$LAST_RUN_FILE"

# Build a useful completion notification with duration and archive size.
_elapsed=$(( SECONDS - BACKUP_START ))
_hours=$(( _elapsed / 3600 ))
_mins=$(( (_elapsed % 3600) / 60 ))
if [ "$_hours" -gt 0 ]; then
  _duration="${_hours}h ${_mins}m"
else
  _duration="${_mins}m"
fi
# Get archive size from the newest .tgz via /bin/ls (glob unreliable on iCloud).
# || true prevents set -e from firing when ls finds no locally-present .tgz
# (iCloud may have already evicted the file to cloud-only storage).
_newest_tgz=$(/bin/ls -1t "$BACKUP_ROOT"/System_Backup_*.tgz 2>/dev/null | head -1) || true
_archive_size=""
if [ -n "$_newest_tgz" ] && [ -f "$_newest_tgz" ]; then
  _archive_size=$(du -sh "$_newest_tgz" 2>/dev/null | awk '{print $1}')
fi
_subtitle="Completed in $_duration"
if [ -n "$_archive_size" ]; then
  _subtitle="$_subtitle — archive: $_archive_size"
fi
# After pruning, total_backups reflects kept count (min of total_backups, 10).
_kept=$(( total_backups > 10 ? 10 : total_backups ))
notify "$_kept backups in iCloud ($prune_count pruned)" "Daily Backup — Complete" "$_subtitle"
