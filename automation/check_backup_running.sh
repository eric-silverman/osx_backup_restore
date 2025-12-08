#!/bin/bash
set -euo pipefail

# Reports whether a backup is currently running and prints the PID if so.
# Usage: ./automation/check_backup_running.sh
# Return codes: 0 = running, 1 = not running, 2 = stale lock detected.

STAGING_ROOT="${STAGING_ROOT:-${TMPDIR:-/tmp}/mac_backup_staging}"
LOCK_DIR="$STAGING_ROOT/.backup_lock"
LOCK_FILE="$LOCK_DIR/pid"

if [ ! -f "$LOCK_FILE" ]; then
  echo "No backup is currently running (no lock file at $LOCK_FILE)."
  exit 1
fi

pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
if [ -z "$pid" ]; then
  echo "Lock file exists but is empty: $LOCK_FILE"
  exit 2
fi

if kill -0 "$pid" 2>/dev/null; then
  echo "Backup is running with PID: $pid"
  exit 0
else
  echo "Stale backup lock found (PID $pid not running)."
  exit 2
fi
