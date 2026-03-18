#!/bin/bash
set -euo pipefail

# Reports whether a backup is currently running, with progress and ETA.
# Usage: ./automation/check_backup_running.sh
# Return codes: 0 = running, 1 = not running, 2 = stale lock detected.

STAGING_ROOT="${STAGING_ROOT:-${TMPDIR:-/tmp}/mac_backup_staging}"
LOCK_DIR="$STAGING_ROOT/.backup_lock"
LOCK_FILE="$LOCK_DIR/pid"
STATUS_FILE="$STAGING_ROOT/.backup_status"

fmt_duration() {
  local secs="$1"
  if [ "$secs" -ge 3600 ]; then
    printf '%dh %dm' $((secs / 3600)) $(( (secs % 3600) / 60 ))
  elif [ "$secs" -ge 60 ]; then
    printf '%dm %ds' $((secs / 60)) $((secs % 60))
  else
    printf '%ds' "$secs"
  fi
}

# --- Detect running backup ---
backup_pid=""

# Check 1: lock file
if [ -f "$LOCK_FILE" ]; then
  pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    backup_pid="$pid"
  elif [ -n "$pid" ]; then
    echo "Stale backup lock found (PID $pid not running)."
    exit 2
  fi
fi

# Check 2: process scan (lock may be missing after crash/kill)
if [ -z "$backup_pid" ]; then
  for p in $(pgrep -f 'backup_mac\.sh' 2>/dev/null || true); do
    if ps -p "$p" -o command= 2>/dev/null | grep -q 'backup_mac\.sh'; then
      backup_pid="$p"
      break
    fi
  done
fi

if [ -z "$backup_pid" ]; then
  echo "No backup is currently running."
  exit 1
fi

# --- Read status file for progress ---
now=$(date +%s)

if [ ! -f "$STATUS_FILE" ]; then
  echo "Backup is running (PID $backup_pid)."
  exit 0
fi

# Parse key=value pairs from status file
phase="" start="" staged_kb="" tar_start="" tgz="" backup_dir=""
while IFS='=' read -r key val; do
  case "$key" in
    phase)      phase="$val" ;;
    start)      start="$val" ;;
    staged_kb)  staged_kb="$val" ;;
    tar_start)  tar_start="$val" ;;
    tgz)        tgz="$val" ;;
    backup_dir) backup_dir="$val" ;;
  esac
done < "$STATUS_FILE"

elapsed=0
if [ -n "$start" ]; then
  elapsed=$((now - start))
fi

echo "Backup is running (PID $backup_pid)"
echo "  Elapsed: $(fmt_duration $elapsed)"

case "$phase" in
  init)
    echo "  Phase:   Initializing (collecting app lists, configs, fonts…)"
    ;;
  rsync)
    echo "  Phase:   Rsyncing home folder"
    if [ -n "$backup_dir" ] && [ -d "$backup_dir" ]; then
      size=$(du -sh "$backup_dir" 2>/dev/null | awk '{print $1}')
      echo "  Staged:  ${size:-calculating…}"
    fi
    ;;
  tar)
    echo "  Phase:   Compressing (tar + gzip)"
    if [ -n "$tgz" ] && [ -f "$tgz" ]; then
      tgz_kb=$(du -sk "$tgz" 2>/dev/null | awk '{print $1}')
      tgz_human=$(du -sh "$tgz" 2>/dev/null | awk '{print $1}')
      echo "  Archive: $tgz_human"

      # Estimate progress: typical compression ratio is ~65% of staged size.
      if [ -n "$staged_kb" ] && [ "$staged_kb" -gt 0 ] 2>/dev/null; then
        expected_kb=$(( staged_kb * 65 / 100 ))
        if [ "$expected_kb" -gt 0 ] && [ -n "$tgz_kb" ]; then
          pct=$(( tgz_kb * 100 / expected_kb ))
          # Cap at 99% since estimate is approximate
          [ "$pct" -gt 99 ] && pct=99
          echo "  Progress: ~${pct}% (estimated)"

          # ETA based on tar phase elapsed time
          if [ -n "$tar_start" ] && [ "$pct" -gt 0 ]; then
            tar_elapsed=$((now - tar_start))
            if [ "$tar_elapsed" -gt 30 ] && [ "$pct" -lt 99 ]; then
              eta_secs=$(( tar_elapsed * (100 - pct) / pct ))
              echo "  ETA:     ~$(fmt_duration $eta_secs)"
            fi
          fi
        fi

        staged_human=$(awk "BEGIN{printf \"%.0fG\", $staged_kb/1024/1024}")
        echo "  Staged:  $staged_human (source)"
      fi
    else
      echo "  Archive: starting…"
    fi
    ;;
  move)
    echo "  Phase:   Moving archive to iCloud Drive"
    ;;
  *)
    echo "  Phase:   $phase"
    ;;
esac

exit 0
