#!/bin/bash
# seed_fake_backups.sh — Create fake backup archives and manifest entries
# to test pruning behaviour in daily_backup.sh without running real backups.
#
# Usage:
#   ./automation/seed_fake_backups.sh [COUNT]
#   ./automation/seed_fake_backups.sh --clean
#
#   COUNT   Number of fake backups to create (default: 15, triggers pruning at >10)
#   --clean Remove all fake backups previously created by this script
#
# Fake backups are tiny .tgz files (~200 bytes) with realistic names and are
# registered in the manifest. After seeding, run daily_backup.sh (or its
# pruning logic) to verify that old entries get cleaned up correctly.
#
# Environment:
#   BACKUP_ROOT  Override backup destination (default: iCloud Drive Backups)
set -euo pipefail

BACKUP_ROOT="${BACKUP_ROOT:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/Backups}"
STATE_DIR="$HOME/.local/share/osx_backup_restore"
MANIFEST_FILE="$STATE_DIR/backup_manifest"
MARKER=".fake_backup_marker"

# ── Clean mode ──────────────────────────────────────────────────────────────
if [ "${1:-}" = "--clean" ]; then
  echo "Cleaning fake backups from $BACKUP_ROOT ..."
  if [ ! -f "$BACKUP_ROOT/$MARKER" ]; then
    echo "No marker file found — nothing to clean."
    exit 0
  fi

  removed=0
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    f="$BACKUP_ROOT/$name"
    if [ -f "$f" ]; then
      rm -f "$f"
      removed=$((removed + 1))
    fi
    # Remove from manifest
    if [ -f "$MANIFEST_FILE" ]; then
      grep -vxF "$f" "$MANIFEST_FILE" > "$MANIFEST_FILE.tmp" 2>/dev/null || true
      mv -f "$MANIFEST_FILE.tmp" "$MANIFEST_FILE"
    fi
  done < "$BACKUP_ROOT/$MARKER"

  rm -f "$BACKUP_ROOT/$MARKER"
  echo "Removed $removed fake backups and cleaned manifest."
  exit 0
fi

# ── Seed mode ───────────────────────────────────────────────────────────────
COUNT="${1:-15}"
if ! [[ "$COUNT" =~ ^[0-9]+$ ]] || [ "$COUNT" -lt 1 ]; then
  echo "Usage: $0 [COUNT|--clean]"
  echo "  COUNT must be a positive integer (default: 15)"
  exit 1
fi

mkdir -p "$BACKUP_ROOT"
mkdir -p "$STATE_DIR"
touch "$MANIFEST_FILE"

# Check for existing fakes
if [ -f "$BACKUP_ROOT/$MARKER" ]; then
  existing=$(wc -l < "$BACKUP_ROOT/$MARKER" | tr -d ' ')
  echo "Warning: $existing fake backups already exist."
  echo "Run '$0 --clean' first to remove them, or they will be kept alongside new ones."
  printf "Continue? [y/N] "
  read -r answer
  if [[ ! "$answer" =~ ^[Yy] ]]; then
    echo "Aborted."
    exit 0
  fi
fi

echo "Seeding $COUNT fake backups into $BACKUP_ROOT ..."

# Generate timestamps going backwards from yesterday, one per day at 03:15:00
# (the typical LaunchAgent schedule), so they don't collide with a real
# backup that might run today.
created=0
> "$BACKUP_ROOT/$MARKER.tmp"

for i in $(seq 1 "$COUNT"); do
  # Days ago: 1 = yesterday, 2 = day before, etc.
  days_ago=$i
  if date --version >/dev/null 2>&1; then
    # GNU date
    stamp=$(date -d "$days_ago days ago" +"%Y%m%d_031500")
  else
    # macOS/BSD date
    stamp=$(date -v-"${days_ago}"d +"%Y%m%d_031500")
  fi

  name="System_Backup_${stamp}.tgz"
  path="$BACKUP_ROOT/$name"

  if [ -f "$path" ]; then
    echo "  skip: $name (already exists)"
    continue
  fi

  # Create a tiny valid .tgz (gzipped tar of an empty directory)
  tmp_stage=$(mktemp -d)
  mkdir -p "$tmp_stage/System_Backup_${stamp}"
  echo "Fake backup created by seed_fake_backups.sh" > "$tmp_stage/System_Backup_${stamp}/backup_summary.txt"
  tar czf "$path" -C "$tmp_stage" "System_Backup_${stamp}" 2>/dev/null
  rm -rf "$tmp_stage"

  # Register in manifest (if not already present)
  grep -qxF "$path" "$MANIFEST_FILE" 2>/dev/null || echo "$path" >> "$MANIFEST_FILE"

  # Track in marker for clean-up
  echo "$name" >> "$BACKUP_ROOT/$MARKER.tmp"

  created=$((created + 1))
  echo "  created: $name"
done

# Append to existing marker (don't overwrite in case of multiple runs)
if [ -f "$BACKUP_ROOT/$MARKER" ]; then
  cat "$BACKUP_ROOT/$MARKER.tmp" >> "$BACKUP_ROOT/$MARKER"
else
  mv "$BACKUP_ROOT/$MARKER.tmp" "$BACKUP_ROOT/$MARKER"
fi
rm -f "$BACKUP_ROOT/$MARKER.tmp"

total_manifest=$(wc -l < "$MANIFEST_FILE" | tr -d ' ')

echo ""
echo "Done: $created fake backups created."
echo "Manifest now has $total_manifest entries (pruning triggers at >10)."
echo ""
echo "Next steps:"
echo "  1. Clear the run timestamp so daily_backup.sh will execute:"
echo "     ./automation/clear_timestamp.sh"
echo "  2. Run the daily backup (which will prune before backing up):"
echo "     BACKUP_ROOT=\"$BACKUP_ROOT\" ./automation/daily_backup.sh"
echo "  3. Or run just the prune test suite:"
echo "     ./automation/test_prune.sh"
echo ""
echo "To remove all fakes:  $0 --clean"
