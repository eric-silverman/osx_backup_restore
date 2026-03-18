#!/bin/bash
# test_prune.sh — Verify that the manifest-based pruning logic works correctly.
# Creates dummy backup files + manifests in temp directories and confirms
# the right files survive and the manifest is updated.
set -euo pipefail

PASS=0
FAIL=0
TEST_NUM=0

run_test() {
  local desc="$1"
  TEST_NUM=$((TEST_NUM + 1))
  echo ""
  echo "── Test $TEST_NUM: $desc ──"
}

assert_exists() {
  if [ -e "$1" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "   FAIL: expected to exist: $1"
  fi
}

assert_not_exists() {
  if [ ! -e "$1" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "   FAIL: expected to be pruned: $1"
  fi
}

assert_line_count() {
  local file="$1" expected="$2" label="$3"
  local actual
  actual=$(wc -l < "$file" 2>/dev/null | tr -d ' ')
  if [ "$actual" -eq "$expected" ]; then
    PASS=$((PASS + 1))
    echo "   OK: $label has $actual lines."
  else
    FAIL=$((FAIL + 1))
    echo "   FAIL: $label expected $expected lines, got $actual"
  fi
}

# ── Pruning logic extracted from daily_backup.sh (manifest-based) ──
do_prune() {
  local BACKUP_ROOT="$1"
  local MANIFEST_FILE="$BACKUP_ROOT/.backup_manifest"

  # Merge visible files into the manifest.
  local _visible_list
  _visible_list=$(mktemp /tmp/backup_visible.XXXXXX 2>/dev/null || mktemp)

  shopt -s nullglob
  _just_created=("$BACKUP_ROOT"/System_Backup_*.tgz "$BACKUP_ROOT"/.System_Backup_*.tgz.icloud)
  shopt -u nullglob

  touch "$MANIFEST_FILE" 2>/dev/null || true
  if [ ${#_just_created[@]} -gt 0 ]; then
    for f in "${_just_created[@]}"; do
      entry="$f"
      b=$(basename "$f")
      if [[ "$b" == .*.icloud ]]; then
        real=${b#.}
        real=${real%.icloud}
        entry="$BACKUP_ROOT/$real"
      fi
      echo "$entry" >> "$_visible_list"
      grep -qxF "$entry" "$MANIFEST_FILE" 2>/dev/null || \
        echo "$entry" >> "$MANIFEST_FILE" 2>/dev/null || true
    done
  fi

  # Reconcile: drop manifest entries whose backups no longer exist on disk.
  # Only when at least one backup file was visible (directory is readable).
  if [ -s "$_visible_list" ]; then
    local _stale=0
    local _kept=()
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      if grep -qxF "$line" "$_visible_list" 2>/dev/null; then
        _kept+=("$line")
      else
        _stale=$((_stale + 1))
      fi
    done < "$MANIFEST_FILE"
    if [ "$_stale" -gt 0 ]; then
      echo "   Removed $_stale stale manifest entries."
      printf '%s\n' "${_kept[@]}" > "$MANIFEST_FILE" 2>/dev/null || true
    fi
  fi
  rm -f "$_visible_list"

  echo "   Pruning backups (keep 10)..."

  sorted_backups=()
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    sorted_backups+=("$line")
  done < <(sort -t_ -k3,4 -r "$MANIFEST_FILE" 2>/dev/null)

  total_backups=${#sorted_backups[@]}
  echo "   Manifest lists $total_backups backups."

  if [ "$total_backups" -gt 10 ]; then
    prune_list=("${sorted_backups[@]:10}")
    prune_count=${#prune_list[@]}
    echo "   Pruning $prune_count backups:"
    for target in "${prune_list[@]}"; do
      echo "      $target"
      b=$(basename "$target")
      rm -f -- "$target" "$BACKUP_ROOT/.$b.icloud" 2>/dev/null || true
    done
    printf '%s\n' "${sorted_backups[@]:0:10}" > "$MANIFEST_FILE" 2>/dev/null || true
  else
    echo "   Nothing to prune (<= 10)."
  fi
}

# Helper: create dummy backup files + corresponding manifest
make_backups() {
  local dir="$1"; shift
  local manifest="$dir/.backup_manifest"
  > "$manifest"
  for name in "$@"; do
    touch "$dir/$name"
    # Normalise .icloud names to .tgz paths in the manifest
    if [[ "$name" == .*.icloud ]]; then
      real=${name#.}
      real=${real%.icloud}
      echo "$dir/$real" >> "$manifest"
    else
      echo "$dir/$name" >> "$manifest"
    fi
  done
}

CLEANUP_DIRS=("")
new_dir() {
  local d
  d=$(mktemp -d)
  CLEANUP_DIRS+=("$d")
  echo "$d"
}
cleanup() { rm -rf "${CLEANUP_DIRS[@]}" 2>/dev/null || true; }
trap cleanup EXIT

# ════════════════════════════════════════════════════
# Test 1: 12 .tgz files → oldest 2 should be pruned
# ════════════════════════════════════════════════════
run_test "12 .tgz backups → keep newest 10, prune oldest 2"

DIR=$(new_dir)
make_backups "$DIR" \
  System_Backup_20260201_151558.tgz \
  System_Backup_20260202_151505.tgz \
  System_Backup_20260203_151505.tgz \
  System_Backup_20260204_151505.tgz \
  System_Backup_20260205_151505.tgz \
  System_Backup_20260206_151503.tgz \
  System_Backup_20260207_151505.tgz \
  System_Backup_20260208_151527.tgz \
  System_Backup_20260209_152931.tgz \
  System_Backup_20260210_151505.tgz \
  System_Backup_20260213_151505.tgz \
  System_Backup_20260214_151532.tgz

do_prune "$DIR"

assert_not_exists "$DIR/System_Backup_20260201_151558.tgz"
assert_not_exists "$DIR/System_Backup_20260202_151505.tgz"
assert_exists "$DIR/System_Backup_20260203_151505.tgz"
assert_exists "$DIR/System_Backup_20260214_151532.tgz"
assert_line_count "$DIR/.backup_manifest" 10 "manifest"

# ════════════════════════════════════════════════════
# Test 2: exactly 10 → nothing should be pruned
# ════════════════════════════════════════════════════
run_test "Exactly 10 backups → nothing pruned"

DIR2=$(new_dir)
make_backups "$DIR2" \
  System_Backup_20260201_120000.tgz \
  System_Backup_20260202_120000.tgz \
  System_Backup_20260203_120000.tgz \
  System_Backup_20260204_120000.tgz \
  System_Backup_20260205_120000.tgz \
  System_Backup_20260206_120000.tgz \
  System_Backup_20260207_120000.tgz \
  System_Backup_20260208_120000.tgz \
  System_Backup_20260209_120000.tgz \
  System_Backup_20260210_120000.tgz

do_prune "$DIR2"

count=$(ls -1 "$DIR2"/System_Backup_*.tgz 2>/dev/null | wc -l | tr -d ' ')
if [ "$count" -eq 10 ]; then
  PASS=$((PASS + 1))
  echo "   OK: all 10 still present."
else
  FAIL=$((FAIL + 1))
  echo "   FAIL: expected 10, got $count"
fi
assert_line_count "$DIR2/.backup_manifest" 10 "manifest"

# ════════════════════════════════════════════════════
# Test 3: iCloud-only (no local files, manifest only)
#   This is the real-world LaunchAgent scenario where
#   glob sees nothing but the manifest knows about them.
# ════════════════════════════════════════════════════
run_test "iCloud-only: no local files visible, prune via manifest only"

DIR3=$(new_dir)
# Create manifest entries but NO actual files (simulates invisible iCloud files)
MANIFEST="$DIR3/.backup_manifest"
for i in $(seq -w 1 14); do
  echo "$DIR3/System_Backup_202602${i}_120000.tgz" >> "$MANIFEST"
done

do_prune "$DIR3"

assert_line_count "$MANIFEST" 10 "manifest"
# Verify the oldest 4 were removed from the manifest
if grep -q "20260201" "$MANIFEST"; then
  FAIL=$((FAIL + 1))
  echo "   FAIL: oldest entry still in manifest"
else
  PASS=$((PASS + 1))
  echo "   OK: oldest entries removed from manifest."
fi
# Verify newest is kept
if grep -q "20260214" "$MANIFEST"; then
  PASS=$((PASS + 1))
  echo "   OK: newest entry retained in manifest."
else
  FAIL=$((FAIL + 1))
  echo "   FAIL: newest entry missing from manifest"
fi

# ════════════════════════════════════════════════════
# Test 4: mix of .tgz and .icloud placeholders
# ════════════════════════════════════════════════════
run_test "Mix of .tgz and .icloud placeholders → prune oldest by filename"

DIR4=$(new_dir)
make_backups "$DIR4" \
  .System_Backup_20260101_120000.tgz.icloud \
  .System_Backup_20260102_120000.tgz.icloud \
  .System_Backup_20260103_120000.tgz.icloud \
  .System_Backup_20260104_120000.tgz.icloud \
  .System_Backup_20260105_120000.tgz.icloud \
  .System_Backup_20260106_120000.tgz.icloud \
  System_Backup_20260107_120000.tgz \
  System_Backup_20260108_120000.tgz \
  System_Backup_20260109_120000.tgz \
  System_Backup_20260110_120000.tgz \
  System_Backup_20260111_120000.tgz \
  System_Backup_20260112_120000.tgz

do_prune "$DIR4"

# Oldest 2 (.icloud variants) should be gone
assert_not_exists "$DIR4/.System_Backup_20260101_120000.tgz.icloud"
assert_not_exists "$DIR4/.System_Backup_20260102_120000.tgz.icloud"
# 3rd oldest .icloud should survive
assert_exists "$DIR4/.System_Backup_20260103_120000.tgz.icloud"
# Newest local .tgz should survive
assert_exists "$DIR4/System_Backup_20260112_120000.tgz"
assert_line_count "$DIR4/.backup_manifest" 10 "manifest"

# ════════════════════════════════════════════════════
# Test 5: empty directory → no crash
# ════════════════════════════════════════════════════
run_test "Empty directory → graceful no-op"

DIR5=$(new_dir)
do_prune "$DIR5"
PASS=$((PASS + 1))
echo "   OK: no crash on empty dir."

# ════════════════════════════════════════════════════
# Test 6: 15 backups → prune 5
# ════════════════════════════════════════════════════
run_test "15 backups → prune oldest 5"

DIR6=$(new_dir)
names=()
for i in $(seq -w 1 15); do
  names+=("System_Backup_202602${i}_120000.tgz")
done
make_backups "$DIR6" "${names[@]}"

do_prune "$DIR6"

remaining=$(ls -1 "$DIR6"/System_Backup_*.tgz 2>/dev/null | wc -l | tr -d ' ')
if [ "$remaining" -eq 10 ]; then
  PASS=$((PASS + 1))
  echo "   OK: 10 files remain."
else
  FAIL=$((FAIL + 1))
  echo "   FAIL: expected 10, got $remaining"
fi
for i in 01 02 03 04 05; do
  assert_not_exists "$DIR6/System_Backup_2026020${i}_120000.tgz"
done
assert_exists "$DIR6/System_Backup_20260215_120000.tgz"
assert_line_count "$DIR6/.backup_manifest" 10 "manifest"

# ════════════════════════════════════════════════════
# Test 7: non-backup files are not touched
# ════════════════════════════════════════════════════
run_test "Non-backup files are left alone"

DIR7=$(new_dir)
names=()
for i in $(seq -w 1 12); do
  names+=("System_Backup_202601${i}_120000.tgz")
done
make_backups "$DIR7" "${names[@]}"
touch "$DIR7/.last_backup_timestamp"
touch "$DIR7/README.txt"
touch "$DIR7/.DS_Store"

do_prune "$DIR7"

assert_exists "$DIR7/.last_backup_timestamp"
assert_exists "$DIR7/README.txt"
assert_exists "$DIR7/.DS_Store"

# ════════════════════════════════════════════════════
# Test 8: manifest is seeded from glob when missing
# ════════════════════════════════════════════════════
run_test "Missing manifest is auto-seeded from visible files"

DIR8=$(new_dir)
# Create files but NO manifest
for i in $(seq -w 1 12); do
  touch "$DIR8/System_Backup_202603${i}_120000.tgz"
done

do_prune "$DIR8"

assert_exists "$DIR8/.backup_manifest"
assert_line_count "$DIR8/.backup_manifest" 10 "manifest"
remaining=$(ls -1 "$DIR8"/System_Backup_*.tgz 2>/dev/null | wc -l | tr -d ' ')
if [ "$remaining" -eq 10 ]; then
  PASS=$((PASS + 1))
  echo "   OK: 10 files remain after auto-seed + prune."
else
  FAIL=$((FAIL + 1))
  echo "   FAIL: expected 10, got $remaining"
fi

# ════════════════════════════════════════════════════
# Test 9: timestamp write fallback
# ════════════════════════════════════════════════════
run_test "Timestamp write fallback (temp file + mv)"

DIR9=$(new_dir)
LAST_RUN_FILE="$DIR9/.last_backup_timestamp"
today="2026-02-15"

if ! printf '%s' "$today" > "$LAST_RUN_FILE" 2>/dev/null; then
  _ts_tmp=$(mktemp "${LAST_RUN_FILE}.XXXXXX" 2>/dev/null || mktemp /tmp/last_backup_ts.XXXXXX)
  printf '%s' "$today" > "$_ts_tmp"
  mv -f "$_ts_tmp" "$LAST_RUN_FILE" 2>/dev/null || true
fi

content=$(cat "$LAST_RUN_FILE" 2>/dev/null || echo "")
if [ "$content" = "$today" ]; then
  PASS=$((PASS + 1))
  echo "   OK: timestamp written correctly."
else
  FAIL=$((FAIL + 1))
  echo "   FAIL: expected '$today', got '$content'"
fi

# Read-only dir fallback
DIR9B=$(new_dir)
LAST_RUN_FILE="$DIR9B/.last_backup_timestamp"
chmod 555 "$DIR9B"

{
  if ! printf '%s' "$today" > "$LAST_RUN_FILE" 2>/dev/null; then
    _ts_tmp=$(mktemp "${LAST_RUN_FILE}.XXXXXX" 2>/dev/null || mktemp /tmp/last_backup_ts.XXXXXX)
    printf '%s' "$today" > "$_ts_tmp" 2>/dev/null
    mv -f "$_ts_tmp" "$LAST_RUN_FILE" 2>/dev/null || \
      echo "   (expected) Could not write to read-only dir — fallback logged warning."
  fi
} 2>/dev/null

chmod 755 "$DIR9B"
PASS=$((PASS + 1))
echo "   OK: fallback did not crash the script."

# ════════════════════════════════════════════════════
# Test 10: duplicate manifest entries are handled
# ════════════════════════════════════════════════════
run_test "Duplicate manifest entries don't cause extra retention"

DIR10=$(new_dir)
MANIFEST="$DIR10/.backup_manifest"
# Write 12 unique entries, some duplicated
for i in $(seq -w 1 12); do
  echo "$DIR10/System_Backup_202604${i}_120000.tgz" >> "$MANIFEST"
  touch "$DIR10/System_Backup_202604${i}_120000.tgz"
done
# Add duplicates of a few
echo "$DIR10/System_Backup_20260412_120000.tgz" >> "$MANIFEST"
echo "$DIR10/System_Backup_20260411_120000.tgz" >> "$MANIFEST"

do_prune "$DIR10"

remaining=$(ls -1 "$DIR10"/System_Backup_*.tgz 2>/dev/null | wc -l | tr -d ' ')
if [ "$remaining" -le 10 ]; then
  PASS=$((PASS + 1))
  echo "   OK: $remaining files remain (duplicates didn't inflate count)."
else
  FAIL=$((FAIL + 1))
  echo "   FAIL: expected <= 10, got $remaining"
fi

# ════════════════════════════════════════════════════
# Summary
# ════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════"
TOTAL=$((PASS + FAIL))
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
if [ "$FAIL" -eq 0 ]; then
  echo "All tests passed."
else
  echo "SOME TESTS FAILED."
  exit 1
fi
