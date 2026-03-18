#!/bin/bash
# Removes the last-run timestamp so the next LaunchAgent trigger runs a backup.
# Usage: ./automation/clear_timestamp.sh

STATE_DIR="$HOME/.local/share/osx_backup_restore"
LAST_RUN_FILE="$STATE_DIR/last_backup_timestamp"

# Also check old iCloud-based location for migration scenarios.
_old="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Backups/.last_backup_timestamp"

cleared=false
for f in "$LAST_RUN_FILE" "$_old"; do
  if [ -f "$f" ]; then
    old=$(cat "$f" 2>/dev/null)
    rm -f "$f"
    echo "Cleared timestamp at $f (was: ${old:-empty})."
    cleared=true
  fi
done

if [ "$cleared" = false ]; then
  echo "No timestamp file found. Backup will run on next trigger."
else
  echo "Next LaunchAgent trigger will run a backup."
fi
