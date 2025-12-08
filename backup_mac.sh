#!/bin/bash
if [ -z "${BASH_VERSION:-}" ]; then
  exec /bin/bash "$0" "$@" || {
    echo "This script must run with bash. Please invoke with /bin/bash." >&2
    exit 1
  }
fi
set +o posix 2>/dev/null || true
set -euo pipefail

# Usage: ./backup_mac.sh [dir|tar|zip] [--clean] [--archives|--no-archives]
# - tar (default): creates a .tgz archive of the backup folder
# - dir: creates a backup folder only
# - zip: creates a .zip archive of the backup folder
# - --clean: after creating the archive, delete the original backup folder
# - --archives: include Desktop/Documents/Downloads/Pictures/Movies compressed archives (off by default)
# - --no-archives: force skipping those archives (default)

FORMAT="tar"
CLEAN=false
MAKE_ARCHIVES=false
for arg in "$@"; do
  case "$arg" in
    dir|tar|zip) FORMAT="$arg" ;;
    --clean) CLEAN=true ;;
    --archives) MAKE_ARCHIVES=true ;;
    --no-archives) MAKE_ARCHIVES=false ;;
    *) echo "Unknown argument '$arg'. Usage: ./backup_mac.sh [dir|tar|zip] [--clean] [--archives|--no-archives]" >&2; exit 1 ;;
  esac
done

# ==== CONFIGURABLE BACKUP TARGET ====
# Set BACKUP_ROOT in your environment to override (e.g., iCloud Drive, external disk)
BACKUP_ROOT="${BACKUP_ROOT:-/Volumes/BACKUP}"
# Always stage locally first to avoid iCloud uploads while building the backup
STAGING_ROOT="${STAGING_ROOT:-${TMPDIR:-/tmp}/mac_backup_staging}"
# How many days to keep old staging runs; set to 0 to disable pruning.
STAGING_RETENTION_DAYS="${STAGING_RETENTION_DAYS:-3}"

mkdir -p "$STAGING_ROOT"

LOCK_DIR="$STAGING_ROOT/.backup_lock"
LOCK_FILE="$LOCK_DIR/pid"

cleanup_lock() {
  rm -rf "$LOCK_DIR"
}

prune_staging_root() {
  # Remove stale staging runs and clean up the staging root if it is empty.
  local retention="${STAGING_RETENTION_DAYS:-3}"
  case "$retention" in
    ''|*[!0-9]*) return 0 ;;
  esac
  if [ "$retention" -le 0 ] || [ ! -d "$STAGING_ROOT" ]; then
    return 0
  fi

  # Prune older staging artifacts to keep /tmp tidy.
  find "$STAGING_ROOT" -maxdepth 1 -mindepth 1 -type d -name "System_Backup_*" -mtime +"$retention" -exec rm -rf {} + 2>/dev/null || true
  find "$STAGING_ROOT" -maxdepth 1 -mindepth 1 -type f \( -name "System_Backup_*.tgz" -o -name "System_Backup_*.zip" \) -mtime +"$retention" -exec rm -f {} + 2>/dev/null || true

  # If --clean was requested and the current staging folder is still around (e.g., failure exit), remove it.
  if $CLEAN && [ -n "${BACKUP_DIR:-}" ] && [ -d "$BACKUP_DIR" ]; then
    rm -rf "$BACKUP_DIR"
  fi

  rmdir "$STAGING_ROOT" 2>/dev/null || true
}

acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "$$" > "$LOCK_FILE"
    return 0
  fi

  if [ -f "$LOCK_FILE" ]; then
    local existing_pid
    existing_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
    if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
      echo "Another backup is already running (pid $existing_pid). Exiting." >&2
      exit 1
    fi
    echo "Stale backup lock found (pid $existing_pid); removing and retrying…" >&2
  else
    echo "Backup lock present; removing stale lock and retrying…" >&2
  fi

  rm -rf "$LOCK_DIR"
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "$$" > "$LOCK_FILE"
  else
    echo "Unable to acquire backup lock. Exiting." >&2
    exit 1
  fi
}

cleanup_on_exit() {
  cleanup_lock
  prune_staging_root
}

acquire_lock
trap cleanup_on_exit EXIT INT TERM

STAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_DIR="$STAGING_ROOT/System_Backup_$STAMP"
FINAL_DIR="$BACKUP_ROOT/System_Backup_$STAMP"
FILES_DIR="$BACKUP_DIR/files"
LISTS_DIR="$BACKUP_DIR/lists"
ARCHIVES_DIR="$BACKUP_DIR/archives"
SUMMARY_FILE="$BACKUP_DIR/backup_summary.txt"
BREW_PRESENT=false
MAS_PRESENT=false
ARCHIVES_REQUESTED=$MAKE_ARCHIVES

mkdir -p "$FILES_DIR" "$LISTS_DIR" "$ARCHIVES_DIR"

# Capture output inside the backup for later review while still emitting to the parent stdout/stderr
LOG_FILE="$BACKUP_DIR/backup_log.txt"
touch "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2)

summary_line() { printf '%s\n' "$1" | tee -a "$SUMMARY_FILE"; }
summary_check() {
  local path="$1"; local desc="$2"; local optional="${3:-false}"
  if [ -e "$path" ]; then
    summary_line "✅ $desc → $path"
  else
    if $optional; then
      summary_line "ℹ️  $desc missing (optional) → $path"
    else
      summary_line "⚠️  $desc missing → $path"
    fi
  fi
}

BRCTL_BIN=""
find_brctl() {
  if command -v brctl >/dev/null 2>&1; then
    BRCTL_BIN="$(command -v brctl)"
    return 0
  fi
  local candidate="/System/Library/PrivateFrameworks/CloudDocsDaemon.framework/Versions/A/Support/brctl"
  if [ -x "$candidate" ]; then
    BRCTL_BIN="$candidate"
    return 0
  fi
  return 1
}
find_brctl || true
if [ -n "$BRCTL_BIN" ]; then
  echo "ℹ️  Using brctl at: $BRCTL_BIN"
else
  echo "ℹ️  brctl not found; iCloud eviction will be skipped."
fi

# Detect common iCloud Drive roots so we only try to offload when applicable.
is_icloud_path() {
  case "$1" in
    "$HOME/Library/Mobile Documents/"* ) return 0 ;;
    "$HOME/Library/CloudStorage/iCloud Drive/"* ) return 0 ;;
    "$HOME/Library/CloudStorage/iCloudDrive/"* ) return 0 ;;
    "$HOME/Library/CloudStorage/"*/"iCloud Drive/"* ) return 0 ;;
    *) return 1 ;;
  esac
}

# Wait a bit for iCloud metadata to mark a file as ubiquitous before upload/evict steps.
wait_for_icloud_flag() {
  local target="$1"
  local tries=0
  local max_tries=60  # ~2 minutes at 2s intervals
  while :; do
    local flag
    flag=$(mdls -raw -name kMDItemFSIsUbiquitous "$target" 2>/dev/null || echo "")
    if [ "$flag" = "1" ]; then
      return 0
    fi
    tries=$((tries+1))
    if [ $tries -ge $max_tries ]; then
      return 1
    fi
    sleep 2
  done
}

# Wait for an iCloud item to finish uploading, then request local eviction to save disk space.
ensure_icloud_uploaded_and_offloaded() {
  local item="$1"
  if [ ! -e "$item" ]; then
    return 0
  fi
  if ! is_icloud_path "$item"; then
    return 0
  fi
  if ! command -v mdls >/dev/null 2>&1; then
    echo "ℹ️  Can't verify iCloud status (mdls missing); leaving $item locally."
    return 0
  fi

  local is_ubiq
  is_ubiq=$(mdls -raw -name kMDItemFSIsUbiquitous "$item" 2>/dev/null || echo "0")
  if [ "$is_ubiq" != "1" ]; then
    echo "☁️  Waiting for iCloud to register $item…"
    if ! wait_for_icloud_flag "$item"; then
      echo "ℹ️  $item not marked as an iCloud item yet; skipping upload/evict for now."
      return 0
    fi
  fi

  echo "☁️  Waiting for iCloud to upload $item…"
  local tries=0
  local max_tries=900
  while :; do
    local uploaded percent
    uploaded=$(mdls -raw -name kMDItemUbiquitousItemIsUploaded "$item" 2>/dev/null || echo "0")
    percent=$(mdls -raw -name kMDItemUbiquitousItemPercentUploaded "$item" 2>/dev/null | tr -cd '0-9.' || echo "0")

    if [ "$uploaded" = "1" ]; then
      echo "   ✅ Upload complete."
      break
    fi

    tries=$((tries+1))
    if [ $tries -ge $max_tries ]; then
      echo "   ⏱  Timed out waiting for iCloud upload; leaving locally."
      return 0
    fi

    if [ -n "$percent" ]; then
      echo "   ⏳ Upload progress: ${percent}%"
    fi
    sleep 2
  done

  if [ -n "$BRCTL_BIN" ]; then
    if "$BRCTL_BIN" evict "$item" >/dev/null 2>&1; then
      echo "   🧹 Requested iCloud to evict local copy (kept in cloud)."
    else
      echo "   ⚠️  Could not evict local copy of $item (brctl failed)."
    fi
  else
    echo "   ℹ️  brctl not available; leaving local copy in place."
  fi
}

# Make sure older backups in an iCloud destination are cloud-only before we start a new run.
offload_existing_icloud_backups() {
  local root="$1"
  if [ ! -d "$root" ] || ! is_icloud_path "$root"; then
    return 0
  fi

  echo "🧹 Ensuring existing backups in $root are cloud-only…"

  # Nudge iCloud to materialize the directory contents so find can see placeholders.
  if [ -n "$BRCTL_BIN" ]; then
    "$BRCTL_BIN" download "$root" >/dev/null 2>&1 || true
  fi

  local backups=()
  while IFS= read -r item; do
    [ -z "$item" ] && continue
    backups+=("$item")
  done < <(find "$root" -maxdepth 1 -mindepth 1 -name "System_Backup_*" -print 2>/dev/null)

  if [ ${#backups[@]} -eq 0 ]; then
    echo "   ℹ️  No existing backups found to offload (pattern: System_Backup_*). Current contents of $root (pwd: $(pwd)):"
    ls -1 "$root" 2>/dev/null || true
    return 0
  fi

  for item in "${backups[@]}"; do
    echo "   🔎 Found existing backup: $item"
    ensure_icloud_uploaded_and_offloaded "$item"
  done

}

echo "🔒 Staging backup at: $BACKUP_DIR"
echo "📁 Final destination root: $BACKUP_ROOT"
echo "🧾 Logging to: $LOG_FILE"
echo "This may take a while…"

offload_existing_icloud_backups "$BACKUP_ROOT"

# 1) App inventories
ls /Applications > "$LISTS_DIR/applications_list.txt"
ls ~/Applications >> "$LISTS_DIR/applications_list.txt" 2>/dev/null || true

if command -v brew >/dev/null 2>&1; then
  BREW_PRESENT=true
  brew list > "$LISTS_DIR/brew_list.txt" || true
  brew list --cask > "$LISTS_DIR/brew_cask_list.txt" || true
  brew bundle dump --file="$FILES_DIR/Brewfile" --force || true
fi

# If you use MAS (Mac App Store CLI):
if command -v mas >/dev/null 2>&1; then
  MAS_PRESENT=true
  mas list > "$LISTS_DIR/mas_list.txt" || true
fi

# 2) System/UI lists
defaults read com.apple.dock > "$LISTS_DIR/dock_readable.txt" || true
plutil -convert xml1 -o "$FILES_DIR/com.apple.dock.plist" ~/Library/Preferences/com.apple.dock.plist 2>/dev/null || true
crontab -l > "$FILES_DIR/cronjobs.txt" 2>/dev/null || true
ls ~/Library/LaunchAgents > "$LISTS_DIR/launch_agents.txt" 2>/dev/null || true

# 3) Fonts list + copy fonts
system_profiler SPFontsDataType > "$LISTS_DIR/fonts_list.txt" || true
mkdir -p "$FILES_DIR/fonts_user" "$FILES_DIR/fonts_system"
rsync -a ~/Library/Fonts/ "$FILES_DIR/fonts_user/" 2>/dev/null || true
sudo rsync -a /Library/Fonts/ "$FILES_DIR/fonts_system/" 2>/dev/null || true

# 4) Audio plugins & MIDI
mkdir -p "$FILES_DIR/audio_plugins_user" "$FILES_DIR/audio_plugins_sys"
for p in Components VST VST3 MAS ARA AAX; do
  rsync -a "~/Library/Audio/Plug-Ins/$p/" "$FILES_DIR/audio_plugins_user/$p/" 2>/dev/null || true
  sudo rsync -a "/Library/Audio/Plug-Ins/$p/" "$FILES_DIR/audio_plugins_sys/$p/" 2>/dev/null || true
done

mkdir -p "$FILES_DIR/midi"
rsync -a ~/Library/Audio/MIDI\ Drivers/ "$FILES_DIR/midi/MIDI Drivers/" 2>/dev/null || true
rsync -a ~/Library/Audio/MIDI\ Configurations/ "$FILES_DIR/midi/MIDI Configurations/" 2>/dev/null || true

# 5) DAW data (add/remove as you like)
rsync -a ~/Music/Audio\ Music\ Apps/ "$FILES_DIR/Audio Music Apps/" 2>/dev/null || true
rsync -a ~/Music/Ableton/ "$FILES_DIR/Ableton/" 2>/dev/null || true
rsync -a ~/Documents/Pro\ Tools/ "$FILES_DIR/Pro Tools/" 2>/dev/null || true

# 6) Dev/CLI configs
rsync -a ~/.ssh "$FILES_DIR/ssh" 2>/dev/null || true
rsync -a ~/.gnupg "$FILES_DIR/gnupg" 2>/dev/null || true
rsync -a ~/.config "$FILES_DIR/dot_config" 2>/dev/null || true

for f in .zshrc .bashrc .bash_profile .zprofile .profile .gitconfig .gitignore_global; do
  [ -f ~/"$f" ] && cp ~/"$f" "$FILES_DIR/" || true
done

rsync -a ~/bin "$FILES_DIR/bin" 2>/dev/null || true
rsync -a ~/.local/bin "$FILES_DIR/local_bin" 2>/dev/null || true

# Editors
rsync -a ~/Library/Application\ Support/Code/User/ "$FILES_DIR/vscode_user" 2>/dev/null || true
rsync -a ~/Library/Application\ Support/Sublime\ Text*/Packages/User/ "$FILES_DIR/sublime_user" 2>/dev/null || true
# Cursor IDE configs
rsync -a ~/Library/Application\ Support/Cursor/User/ "$FILES_DIR/cursor_user/" 2>/dev/null || true
rsync -a ~/.cursor/extensions/ "$FILES_DIR/cursor_extensions/" 2>/dev/null || true

# 7) Color profiles & QuickLook plugins
rsync -a ~/Library/ColorSync/Profiles "$FILES_DIR/colorsync_user" 2>/dev/null || true
sudo rsync -a /Library/ColorSync/Profiles "$FILES_DIR/colorsync_system" 2>/dev/null || true
rsync -a ~/Library/QuickLook "$FILES_DIR/quicklook_user" 2>/dev/null || true
sudo rsync -a /Library/QuickLook "$FILES_DIR/quicklook_system" 2>/dev/null || true

# --- Apple Mail ---
echo "📮 Backing up Apple Mail..."
rsync -a ~/Library/Mail/ "$FILES_DIR/apple_mail/Mail/" 2>/dev/null || true
cp ~/Library/Preferences/com.apple.mail.plist "$FILES_DIR/apple_mail/" 2>/dev/null || true

# --- Automator/Services & Shortcuts ---
echo "⚙️  Backing up Services & Shortcuts..."
rsync -a ~/Library/Services/ "$FILES_DIR/services/" 2>/dev/null || true
rsync -a ~/Library/Shortcuts/ "$FILES_DIR/shortcuts/" 2>/dev/null || true

# --- Calendars ---
echo "🗓  Backing up Calendars..."
rsync -a ~/Library/Calendars/ "$FILES_DIR/calendars/" 2>/dev/null || true

# 8) Whole home directory (with sensible excludes)
echo "📦 Rsyncing your entire home folder…"
RSYNC_STATUS=0
rsync -a --info=progress2 --ignore-errors  ~ "$BACKUP_DIR/User_Folder" \
  --exclude ".Trash" \
  --exclude ".DS_Store" \
  --exclude "Library/Caches" \
  --exclude "Library/Logs" \
  --exclude "Library/Mobile Documents" \
  --exclude "Library/CloudStorage" \
  --exclude "Library/Messages" \
  --exclude "Library/Containers" \
  --exclude "Library/Developer" \
  --exclude "Library/Application Support/Steam/steamapps" \
  --exclude "node_modules" \
  --exclude ".rvm" \
  --exclude ".rbenv" \
  --exclude ".pyenv" \
  --exclude ".local/lib/python*" \
  --exclude ".cargo" \
  --exclude "go" \
  --exclude ".npm" \
  --exclude ".nvm" \
  --exclude ".docker" \
  --exclude "Library/Containers/com.docker.docker" \
  --exclude ".aws" \
  --exclude ".kube" \
  --exclude ".gcloud" \
  --exclude ".azure" \
  --exclude "Library/Application Support/FileProvider" \
  --exclude "Library/Application Support/Signal/Crashpad" \
  --exclude "Library/Group Containers/group.com.apple.CoreSpeech" \
  --exclude "Library/Group Containers/group.com.apple.secure-control-center-preferences" \
  --exclude "Dropbox" \
  --exclude "Downloads" \
  --exclude "Documents" \
  --exclude "Desktop" \
  --exclude "Pictures" \
  --exclude "Movies" || RSYNC_STATUS=$?

if [ ${RSYNC_STATUS:-0} -ne 0 ]; then
  echo "⚠️  Home folder rsync completed with status $RSYNC_STATUS (likely permission-denied system files). See above for skipped paths."
fi

# 9) Ensure iCloud items are local, then archive key folders

# Function: wait for iCloud placeholders in a path to be fully downloaded
ensure_icloud_downloaded() {
  local target="$1"
  if ! command -v mdfind >/dev/null 2>&1; then
    echo "⚠️  'mdfind' not available; skipping iCloud check for $target"
    return 0
  fi

  echo "☁️  Ensuring iCloud files are downloaded in: $target"

  # Try to nudge iCloud to download the folder/files if brctl is available
  if [ -n "$BRCTL_BIN" ]; then
    "$BRCTL_BIN" download "$target" >/dev/null 2>&1 || true
  fi

  local tries=0
  local max_tries=900   # ~30 minutes at 2s intervals
  while :; do
    # Find ubiquitous (iCloud) items within target that are NOT downloaded
    local pending
    pending=$(mdfind -onlyin "$target" 'kMDItemFSIsUbiquitous == 1 && kMDItemUbiquitousItemIsDownloaded == 0' || true)
    if [ -z "$pending" ]; then
      echo "   ✅ All iCloud items downloaded for: $target"
      break
    fi

    # Best-effort: ask for each to download if brctl is present
    if [ -n "$BRCTL_BIN" ]; then
      while IFS= read -r item; do
        [ -n "$item" ] && "$BRCTL_BIN" download "$item" >/dev/null 2>&1 || true
      done <<< "$pending"
    fi

    tries=$((tries+1))
    if [ $tries -ge $max_tries ]; then
      echo "   ⏱  Timed out waiting for iCloud in $target; continuing…"
      break
    fi
    sleep 2
  done
}

if $MAKE_ARCHIVES; then
  echo "🗜  Archiving selected folders (Desktop, Documents, Downloads, Pictures, Movies)…"
  for rel in Desktop Documents Downloads Pictures Movies; do
    src="$HOME/$rel"
    if [ -d "$src" ]; then
      ensure_icloud_downloaded "$src"
      out="$ARCHIVES_DIR/${rel}.tar.gz"
      echo "   📦 Creating archive: $out"

      # Exclude very large photo libraries from the Pictures archive
      exclude_args=()
      exclude_args+=("--exclude=*/node_modules")
      if [ "$rel" = "Pictures" ]; then
        # Common library bundles to skip (managed by Photos/iPhoto)
        exclude_args+=("--exclude=$rel/Photos Library.photoslibrary")
        exclude_args+=("--exclude=$rel/*Photos Library*.photoslibrary")
        exclude_args+=("--exclude=$rel/iPhoto Library.photolibrary")
        exclude_args+=("--exclude=$rel/*iPhoto*.photolibrary")
      fi

      tar -C "$HOME" -czf "$out" "${exclude_args[@]}" "$rel" || echo "   ⚠️  Failed to archive $src"
    else
      echo "   ℹ️  Skipping missing folder: $src"
    fi
  done
else
  echo "⏩ Skipping Desktop/Documents/Downloads/Pictures/Movies archives (--no-archives)."
fi

echo "✅ Backup complete (staged): $BACKUP_DIR"

# Write a quick summary so you can verify contents later (kept inside the archive)
summary_line "Backup summary for $BACKUP_DIR"
summary_line "Created: $(date -Iseconds)"
summary_line "Format: $FORMAT  | Clean after archive: $CLEAN  | Archives enabled: $ARCHIVES_REQUESTED"
summary_line ""
summary_check "$LISTS_DIR/applications_list.txt" "Applications list"
summary_check "$LISTS_DIR/brew_list.txt" "brew list" "$BREW_PRESENT"
summary_check "$LISTS_DIR/brew_cask_list.txt" "brew list --cask" "$BREW_PRESENT"
summary_check "$FILES_DIR/Brewfile" "Brewfile" "$BREW_PRESENT"
summary_check "$LISTS_DIR/mas_list.txt" "mas list" "$MAS_PRESENT"
summary_check "$LISTS_DIR/dock_readable.txt" "Dock defaults dump" true
summary_check "$FILES_DIR/com.apple.dock.plist" "Dock plist (xml)" true
summary_check "$FILES_DIR/fonts_user" "User fonts" true
summary_check "$FILES_DIR/fonts_system" "System fonts" true
summary_check "$FILES_DIR/audio_plugins_user" "User audio plugins" true
summary_check "$FILES_DIR/audio_plugins_sys" "System audio plugins" true
summary_check "$FILES_DIR/midi" "MIDI drivers/configurations" true
summary_check "$FILES_DIR/Audio Music Apps" "Logic/DAW data" true
summary_check "$FILES_DIR/Ableton" "Ableton data" true
summary_check "$FILES_DIR/Pro Tools" "Pro Tools data" true
summary_check "$FILES_DIR/ssh" "SSH configs" true
summary_check "$FILES_DIR/gnupg" "GPG configs" true
summary_check "$FILES_DIR/dot_config" "dot-config dir" true
summary_check "$FILES_DIR/bin" "bin" true
summary_check "$FILES_DIR/local_bin" "~/.local/bin" true
summary_check "$FILES_DIR/vscode_user" "VS Code User settings" true
summary_check "$FILES_DIR/sublime_user" "Sublime User settings" true
summary_check "$FILES_DIR/cursor_user" "Cursor settings" true
summary_check "$FILES_DIR/cursor_extensions" "Cursor extensions" true
summary_check "$FILES_DIR/colorsync_user" "ColorSync profiles (user)" true
summary_check "$FILES_DIR/colorsync_system" "ColorSync profiles (system)" true
summary_check "$FILES_DIR/quicklook_user" "QuickLook plugins (user)" true
summary_check "$FILES_DIR/quicklook_system" "QuickLook plugins (system)" true
summary_check "$FILES_DIR/apple_mail" "Apple Mail data" true
summary_check "$FILES_DIR/services" "Services" true
summary_check "$FILES_DIR/shortcuts" "Shortcuts" true
summary_check "$FILES_DIR/calendars" "Calendars" true
summary_check "$BACKUP_DIR/User_Folder" "Home folder rsync copy"
if $ARCHIVES_REQUESTED; then
  summary_check "$ARCHIVES_DIR/Desktop.tar.gz" "Desktop archive" true
  summary_check "$ARCHIVES_DIR/Documents.tar.gz" "Documents archive" true
  summary_check "$ARCHIVES_DIR/Downloads.tar.gz" "Downloads archive" true
  summary_check "$ARCHIVES_DIR/Pictures.tar.gz" "Pictures archive" true
  summary_check "$ARCHIVES_DIR/Movies.tar.gz" "Movies archive" true
else
  summary_line "ℹ️  Archives disabled (--no-archives); Desktop/Documents/Downloads/Pictures/Movies not packaged."
fi
summary_line ""

# Package the backup in staging, then move to the final destination (useful for iCloud targets)
mkdir -p "$BACKUP_ROOT"
OUTPUT_PATH="$FINAL_DIR"

STAGED_SIZE=$(du -sh "$BACKUP_DIR" 2>/dev/null | awk '{print $1}')
echo "📏 Staged backup size: ${STAGED_SIZE:-unknown}"

TAR_BIN="tar"
TAR_PROGRESS_OPTS=()
if command -v gtar >/dev/null 2>&1; then
  TAR_BIN="$(command -v gtar)"
  # Checkpoint every ~5000 files; prints a single-line carriage-returned status.
  TAR_PROGRESS_OPTS=(--checkpoint=5000 --checkpoint-action=printf="   [tar] %u files archived\r")
  echo "ℹ️  Using gtar with periodic tar progress."
else
  echo "ℹ️  Using system tar (no progress checkpoints available)."
fi

case "$FORMAT" in
  dir)
    echo "📂 Moving backup folder to $BACKUP_ROOT…"
    mv "$BACKUP_DIR" "$BACKUP_ROOT/"
    echo "✅ Backup folder moved to: $OUTPUT_PATH"
    FINAL_SIZE=$(du -sh "$OUTPUT_PATH" 2>/dev/null | awk '{print $1}')
    echo "📦 Final folder size: ${FINAL_SIZE:-unknown}"
    ;;
  tar)
    echo "📦 Creating tar archive in staging…"
    "$TAR_BIN" "${TAR_PROGRESS_OPTS[@]}" -C "$(dirname "$BACKUP_DIR")" -czf "$BACKUP_DIR.tgz" "$(basename "$BACKUP_DIR")"
    echo ""  # ensure trailing newline if progress used
    mv "$BACKUP_DIR.tgz" "$BACKUP_ROOT/"
    OUTPUT_PATH="$BACKUP_ROOT/$(basename "$BACKUP_DIR").tgz"
    echo "✅ Tar archive at: $OUTPUT_PATH"
    FINAL_SIZE=$(du -sh "$OUTPUT_PATH" 2>/dev/null | awk '{print $1}')
    echo "📏 Tar size: ${FINAL_SIZE:-unknown}"
    ;;
  zip)
    echo "📦 Creating zip archive in staging…"
    # Use ditto to preserve macOS metadata
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$BACKUP_DIR" "$BACKUP_DIR.zip"
    mv "$BACKUP_DIR.zip" "$BACKUP_ROOT/"
    OUTPUT_PATH="$BACKUP_ROOT/$(basename "$BACKUP_DIR").zip"
    echo "✅ Zip archive at: $OUTPUT_PATH"
    FINAL_SIZE=$(du -sh "$OUTPUT_PATH" 2>/dev/null | awk '{print $1}')
    echo "📏 Zip size: ${FINAL_SIZE:-unknown}"
    ;;
esac

# Optionally remove the original folder after archiving
if $CLEAN; then
  if [ "$FORMAT" = "dir" ]; then
    echo "⚠️  --clean has no effect with 'dir' format; keeping folder."
  else
    echo "🧹 Removing original backup folder: $BACKUP_DIR"
    # Clear immutability flags and make everything writable so cleanup cannot be blocked by odd permissions.
    chflags -R nouchg "$BACKUP_DIR" 2>/dev/null || true
    chmod -R u+w "$BACKUP_DIR" 2>/dev/null || true
    if rm -rf "$BACKUP_DIR"; then
      echo "✅ Removed backup folder."
      echo "✨ Cleanup complete; backup ready at: $OUTPUT_PATH"
    else
      echo "🔁 Retrying cleanup with sudo to remove root-owned files…"
      sudo -n chflags -R nouchg "$BACKUP_DIR" 2>/dev/null || true
      sudo -n chmod -R u+w "$BACKUP_DIR" 2>/dev/null || true
      if sudo -n rm -rf "$BACKUP_DIR"; then
        echo "✅ Removed backup folder with sudo."
        echo "✨ Cleanup complete; backup ready at: $OUTPUT_PATH"
      else
        echo "⚠️  Failed to fully remove backup folder. Configure passwordless sudo for chflags/chmod/rm on staging to allow LaunchAgent cleanup. Remaining at: $BACKUP_DIR"
      fi
    fi
  fi
fi

# For iCloud destinations, wait for the archive upload to finish, then free local space.
  if [ "$FORMAT" != "dir" ]; then
    ensure_icloud_uploaded_and_offloaded "$OUTPUT_PATH"
  fi

echo "✅ Done. Backup ready at: $OUTPUT_PATH"
