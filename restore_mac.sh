#!/bin/bash
set -euo pipefail

#############################################
# Verbose, timed, self-logging restore script
# - Pre-auths sudo and keeps it alive
# - Uses ditto for /Library/* copies
# - Auto-detects modern rsync; falls back if needed
#############################################

# ====== Input handling: accept dir or archive ======
# Usage: ./restore_mac.sh [--clean] [<backup_dir_or_archive>]
# - If omitted, falls back to first match of ~/Desktop/System_Backup_*
# - --clean: if restoring from an archive, delete the temporary extracted folder when done

INPUT_PATH=""
CLEAN_EXTRACT=false
for arg in "$@"; do
  case "$arg" in
    --clean) CLEAN_EXTRACT=true ;;
    --) break ;;
    -*) echo "Unknown option: $arg" >&2; exit 1 ;;
    *) if [ -z "$INPUT_PATH" ]; then INPUT_PATH="$arg"; fi ;;
  esac
done

# Timestamp for logging and temp paths
STAMP="$(date +"%Y%m%d_%H%M%S")"

# Resolve backup source path (dir or archive), but defer extraction until after logging starts
DEFAULT_GLOB=~/Desktop/System_Backup_*
if [ -z "$INPUT_PATH" ]; then
  # Expand glob and pick first match safely
  set +o noglob
  for p in $DEFAULT_GLOB; do INPUT_PATH="$p"; break; done
  set -o noglob || true
fi

RESOLVED_DIR=""
ARCHIVE_PATH=""
if [ -n "${INPUT_PATH:-}" ]; then
  if [ -d "$INPUT_PATH" ]; then
    RESOLVED_DIR="$INPUT_PATH"
  elif [ -f "$INPUT_PATH" ]; then
    ARCHIVE_PATH="$INPUT_PATH"
  fi
fi

# ====== Logging setup ======
LOGFILE=~/Desktop/restore_log_$STAMP.txt
mkdir -p "$(dirname "$LOGFILE")"
exec > >(tee -a "$LOGFILE") 2>&1

# ====== Pretty printing helpers ======
section() {
  local title="$1"
  echo
  echo "────────────────────────────────────────────────────────"
  echo "⏱️  $(date +"%Y-%m-%d %H:%M:%S")  —  $title"
  echo "────────────────────────────────────────────────────────"
}
note()   { echo "🔹 $*"; }
warn()   { echo "⚠️  $*"; }
ok()     { echo "✅ $*"; }
fail()   { echo "❌ $*"; }
bullet() { echo "  • $*"; }

# Timed step helper (runs block in SAME shell so functions are visible)
timed() {
  local label="$1"; shift
  local start_ts end_ts elapsed
  section "$label"
  start_ts=$(date +%s)
  eval "$@"
  end_ts=$(date +%s)
  elapsed=$(( end_ts - start_ts ))
  ok "$label — done in ${elapsed}s"
}

# ====== Tools: rsync detection & wrappers ======
RSYNC="/usr/bin/rsync"
PROGRESS_FLAGS="--progress -h -v"   # default for Apple rsync
if [ -x /opt/homebrew/bin/rsync ]; then
  RSYNC="/opt/homebrew/bin/rsync"
  PROGRESS_FLAGS="--info=progress2" # modern rsync
fi

rs()       { "$RSYNC" -a $PROGRESS_FLAGS "$@"; }  # progress for large copies
rs_quiet() { "$RSYNC" -a "$@"; }                  # quiet for small configs

# macOS-friendly system copy (preserves metadata/Xattrs/ACLs better)
copy_sys() {
  # usage: copy_sys <src/> <dest/>
  local src="$1"; local dest="$2"
  # Create destination if missing
  sudo mkdir -p "$dest"
  # Use ditto (more reliable for /Library stuff than old rsync)
  # -V = verbose (prints filenames). If you want it quieter, remove -V.
  sudo /usr/bin/ditto -V "$src" "$dest"
}

# Size/preview helper
size_of() {
  local path="$1"
  if [ -d "$path" ] || [ -f "$path" ]; then
    du -sh "$path" 2>/dev/null | awk '{print $1}'
  else
    echo "-"
  fi
}
exists_any() { ls "$1" 1>/dev/null 2>&1; }

# ====== Resolve and (if needed) extract backup ======
timed "Locating Backup Source" '
  if [ -n "$RESOLVED_DIR" ]; then
    BACKUP_DIR="$RESOLVED_DIR"
    note "Using backup directory: $BACKUP_DIR"
  elif [ -n "$ARCHIVE_PATH" ]; then
    note "Archive provided: $ARCHIVE_PATH"
    EXTRACT_DIR=~/Desktop/restore_extract_$STAMP
    mkdir -p "$EXTRACT_DIR"
    case "$ARCHIVE_PATH" in
      *.tar.gz|*.tgz)
        note "Extracting tar archive to $EXTRACT_DIR…"
        tar -xzf "$ARCHIVE_PATH" -C "$EXTRACT_DIR"
        ;;
      *.zip)
        note "Extracting zip archive to $EXTRACT_DIR…"
        /usr/bin/ditto -x -k "$ARCHIVE_PATH" "$EXTRACT_DIR"
        ;;
      *)
        fail "Unsupported archive type: $ARCHIVE_PATH"; exit 1;
        ;;
    esac
    # If extraction produced a single directory, use it as the backup root
    one_dir=$(find "$EXTRACT_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)
    remainder=$(find "$EXTRACT_DIR" -mindepth 1 -maxdepth 1 | wc -l | tr -d " ")
    if [ "$remainder" = "1" ] && [ -n "$one_dir" ]; then
      BACKUP_DIR="$one_dir"
    else
      BACKUP_DIR="$EXTRACT_DIR"
    fi
    note "Using extracted backup directory: $BACKUP_DIR"
  else
    fail "Could not locate backup. Pass a directory or .tgz/.tar.gz/.zip file, or place a System_Backup_* on Desktop."; exit 1;
  fi
'

FILES_DIR="$BACKUP_DIR/files"

# ====== Sanity checks ======
section "Startup & Sanity Checks"
note "Log file: $LOGFILE"
note "Backup dir: $BACKUP_DIR"
if [ ! -d "$BACKUP_DIR" ]; then fail "Backup folder not found after resolution."; exit 1; fi
if [ ! -d "$FILES_DIR" ]; then fail "'$FILES_DIR' missing. Wrong backup?"; exit 1; fi
bullet "Quit Mail, Calendar, and other apps before running."
ok "Environment ready."

# ====== Sudo pre-auth + keepalive (prevents mid-step hangs) ======
section "Sudo Pre-auth"
if sudo -vn 2>/dev/null; then
  ok "Sudo already authenticated."
else
  note "Requesting admin password for elevated operations…"
  sudo -v
fi
# Keep sudo alive while this script runs
( while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done ) 2>/dev/null &

# ====== Fonts ======
timed "Restoring Fonts" '
  if [ -d "$FILES_DIR/fonts_user" ]; then
    note "User fonts size: $(size_of "$FILES_DIR/fonts_user")"
    mkdir -p ~/Library/Fonts
    rs "$FILES_DIR/fonts_user/" ~/Library/Fonts/
  else
    warn "No user fonts to restore."
  fi

  if [ -d "$FILES_DIR/fonts_system" ]; then
    note "System fonts size: $(size_of "$FILES_DIR/fonts_system")"
    copy_sys "$FILES_DIR/fonts_system/" "/Library/Fonts/"
  else
    note "No system fonts captured (ok)."
  fi
'

# ====== ColorSync & QuickLook ======
timed "Restoring ColorSync Profiles & QuickLook Plugins" '
  if [ -d "$FILES_DIR/colorsync_user" ]; then
    note "ColorSync (user): $(size_of "$FILES_DIR/colorsync_user")"
    mkdir -p ~/Library/ColorSync/Profiles
    rs "$FILES_DIR/colorsync_user/" ~/Library/ColorSync/Profiles/
  fi
  if [ -d "$FILES_DIR/colorsync_system" ]; then
    note "ColorSync (system): $(size_of "$FILES_DIR/colorsync_system")"
    copy_sys "$FILES_DIR/colorsync_system/" "/Library/ColorSync/Profiles/"
  fi

  if [ -d "$FILES_DIR/quicklook_user" ]; then
    note "QuickLook (user): $(size_of "$FILES_DIR/quicklook_user")"
    mkdir -p ~/Library/QuickLook
    rs "$FILES_DIR/quicklook_user/" ~/Library/QuickLook/
  fi
  if [ -d "$FILES_DIR/quicklook_system" ]; then
    note "QuickLook (system): $(size_of "$FILES_DIR/quicklook_system")"
    copy_sys "$FILES_DIR/quicklook_system/" "/Library/QuickLook/"
  fi
'

# ====== SSH / GPG / CLI ======
timed "Restoring SSH, GPG, and CLI Configs" '
  # SSH
  if [ -d "$FILES_DIR/ssh" ]; then
    note "~/.ssh before: $(size_of ~/.ssh)"
    mkdir -p ~/.ssh
    rs_quiet "$FILES_DIR/ssh/" ~/.ssh/
    chmod 700 ~/.ssh
    if exists_any ~/.ssh/*; then chmod 600 ~/.ssh/*; fi
    note "~/.ssh after: $(size_of ~/.ssh)"
  else
    note "No SSH directory in backup (skipping)."
  fi

  # GPG
  if [ -d "$FILES_DIR/gnupg" ]; then
    note "~/.gnupg before: $(size_of ~/.gnupg)"
    mkdir -p ~/.gnupg
    rs_quiet "$FILES_DIR/gnupg/" ~/.gnupg/
    chmod 700 ~/.gnupg
    if exists_any ~/.gnupg/*; then chmod 600 ~/.gnupg/*; fi
    note "~/.gnupg after: $(size_of ~/.gnupg)"
  else
    note "No GPG directory in backup (skipping)."
  fi

  # ~/.config and dotfiles
  if [ -d "$FILES_DIR/dot_config" ]; then
    note "~/.config before: $(size_of ~/.config)"
    mkdir -p ~/.config
    rs_quiet "$FILES_DIR/dot_config/" ~/.config/
    note "~/.config after: $(size_of ~/.config)"
  fi

  for f in .zshrc .bashrc .bash_profile .zprofile .profile .gitconfig .gitignore_global; do
    if [ -f "$FILES_DIR/$f" ]; then
      cp "$FILES_DIR/$f" ~/
      note "Restored ~/$f"
    fi
  done

  [ -d "$FILES_DIR/bin" ] && { mkdir -p ~/bin; rs_quiet "$FILES_DIR/bin/" ~/bin/; note "Restored ~/bin"; } || true
  [ -d "$FILES_DIR/local_bin" ] && { mkdir -p ~/.local/bin; rs_quiet "$FILES_DIR/local_bin/" ~/.local/bin/; note "Restored ~/.local/bin"; } || true
'

# ====== Editors ======
timed "Restoring Editor Settings (VS Code, Cursor, Sublime)" '
  if [ -d "$FILES_DIR/vscode_user" ]; then
    mkdir -p ~/Library/Application\ Support/Code/User
    rs_quiet "$FILES_DIR/vscode_user/" ~/Library/Application\ Support/Code/User/
    note "VS Code user settings restored."
  fi

  if [ -d "$FILES_DIR/cursor_user" ]; then
    mkdir -p ~/Library/Application\ Support/Cursor/User
    rs_quiet "$FILES_DIR/cursor_user/" ~/Library/Application\ Support/Cursor/User/
    note "Cursor user settings restored."
  fi

  if [ -d "$FILES_DIR/cursor_extensions" ]; then
    mkdir -p ~/.cursor/extensions
    rs_quiet "$FILES_DIR/cursor_extensions/" ~/.cursor/extensions/
    note "Cursor extensions restored."
  fi

  # Sublime Text User settings (support both ST4 and ST3 paths)
  if [ -d "$FILES_DIR/sublime_user" ]; then
    mkdir -p ~/Library/Application\ Support/Sublime\ Text/Packages/User
    rs_quiet "$FILES_DIR/sublime_user/" ~/Library/Application\ Support/Sublime\ Text/Packages/User/
    note "Sublime Text (ST4) User settings restored."

    mkdir -p ~/Library/Application\ Support/Sublime\ Text\ 3/Packages/User
    rs_quiet "$FILES_DIR/sublime_user/" ~/Library/Application\ Support/Sublime\ Text\ 3/Packages/User/
    note "Sublime Text 3 User settings restored."
  fi
'

# ====== DAW Data ======
timed "Restoring DAW Data (Logic/Ableton/Pro Tools)" '
  # Logic: Audio Music Apps
  if [ -d "$FILES_DIR/Audio Music Apps" ]; then
    mkdir -p ~/Music/Audio\ Music\ Apps
    rs "$FILES_DIR/Audio Music Apps/" ~/Music/Audio\ Music\ Apps/
    note "Audio Music Apps restored."
  fi

  # Ableton
  if [ -d "$FILES_DIR/Ableton" ]; then
    mkdir -p ~/Music/Ableton
    rs "$FILES_DIR/Ableton/" ~/Music/Ableton/
    note "Ableton folder restored."
  fi

  # Pro Tools
  if [ -d "$FILES_DIR/Pro Tools" ]; then
    mkdir -p ~/Documents/Pro\ Tools
    rs "$FILES_DIR/Pro Tools/" ~/Documents/Pro\ Tools/
    note "Pro Tools folder restored."
  fi
'

# ====== Audio Plugins & MIDI ======
timed "Restoring Audio Plugins & MIDI" '
  for p in Components VST VST3 MAS ARA AAX; do
    if [ -d "$FILES_DIR/audio_plugins_user/$p" ]; then
      note "User $p: $(size_of "$FILES_DIR/audio_plugins_user/$p")"
      mkdir -p ~/Library/Audio/Plug-Ins/$p
      rs_quiet "$FILES_DIR/audio_plugins_user/$p/" ~/Library/Audio/Plug-Ins/$p/
    fi
    if [ -d "$FILES_DIR/audio_plugins_sys/$p" ]; then
      note "System $p: $(size_of "$FILES_DIR/audio_plugins_sys/$p")"
      copy_sys "$FILES_DIR/audio_plugins_sys/$p/" "/Library/Audio/Plug-Ins/$p/"
    fi
  done

  [ -d "$FILES_DIR/midi/MIDI Drivers" ] && { mkdir -p ~/Library/Audio/MIDI\ Drivers; rs_quiet "$FILES_DIR/midi/MIDI Drivers/" ~/Library/Audio/MIDI\ Drivers/; note "MIDI Drivers restored."; } || true
  [ -d "$FILES_DIR/midi/MIDI Configurations" ] && { mkdir -p ~/Library/Audio/MIDI\ Configurations; rs_quiet "$FILES_DIR/midi/MIDI Configurations/" ~/Library/Audio/MIDI\ Configurations/; note "MIDI Configurations restored."; } || true
'

# ====== Apple Mail ======
timed "Restoring Apple Mail (Quit Mail First)" '
  if [ -d "$FILES_DIR/apple_mail/Mail" ]; then
    note "Mail data size: $(size_of "$FILES_DIR/apple_mail/Mail")"
    mkdir -p ~/Library/Mail
    rs "$FILES_DIR/apple_mail/Mail/" ~/Library/Mail/
  else
    warn "No Mail folder found in backup."
  fi

  if [ -f "$FILES_DIR/apple_mail/com.apple.mail.plist" ]; then
    cp "$FILES_DIR/apple_mail/com.apple.mail.plist" ~/Library/Preferences/
    note "Mail plist restored."
  fi
'

# ====== Services & Shortcuts ======
timed "Restoring Services & Shortcuts" '
  if [ -d "$FILES_DIR/services" ]; then
    mkdir -p ~/Library/Services
    rs_quiet "$FILES_DIR/services/" ~/Library/Services/
    note "Services restored."
  fi

  if [ -d "$FILES_DIR/shortcuts" ]; then
    note "Shortcuts size: $(size_of "$FILES_DIR/shortcuts")"
    mkdir -p ~/Library/Shortcuts
    rs "$FILES_DIR/shortcuts/" ~/Library/Shortcuts/
  fi
'

# ====== Calendars ======
timed "Restoring Calendars (Quit Calendar First)" '
  if [ -d "$FILES_DIR/calendars" ]; then
    note "Calendars size: $(size_of "$FILES_DIR/calendars")"
    mkdir -p ~/Library/Calendars
    rs "$FILES_DIR/calendars/" ~/Library/Calendars/
  else
    note "No Calendars in backup (ok if you use iCloud/Google)."
  fi
'

# ====== User Archives (Desktop/Documents/Downloads/Pictures/Movies) ======
timed "Restoring User Archives (Desktop, Documents, Downloads, Pictures, Movies)" '
  ARCHIVES_DIR="$BACKUP_DIR/archives"
  if [ -d "$ARCHIVES_DIR" ]; then
    extract_archive() {
      local name="$1"
      local tgt="$HOME/$name"
      local tarpath="$ARCHIVES_DIR/${name}.tar.gz"
      if [ -f "$tarpath" ]; then
        note "Extracting $tarpath to $tgt"
        mkdir -p "$tgt"
        tar -C "$HOME" -xzf "$tarpath" || warn "Failed extracting $tarpath"
      else
        note "No archive for $name (skipping)."
      fi
    }

    extract_archive "Desktop"
    extract_archive "Documents"
    extract_archive "Downloads"
    extract_archive "Pictures"
    extract_archive "Movies"
  else
    note "No archives directory found (likely created with --no-archives). Skipping archived Desktop/Documents/Downloads/Pictures/Movies."
  fi
'

# ====== LaunchAgents & cron ======
timed "Restoring LaunchAgents & cron" '
  if [ -f "$FILES_DIR/cronjobs.txt" ]; then
    crontab "$FILES_DIR/cronjobs.txt"
    note "Cron installed."
  else
    note "No cronjobs.txt found."
  fi

  if [ -d "$BACKUP_DIR/User_Folder/Library/LaunchAgents" ]; then
    mkdir -p ~/Library/LaunchAgents
    rs_quiet "$BACKUP_DIR/User_Folder/Library/LaunchAgents/" ~/Library/LaunchAgents/
    note "LaunchAgents restored."
  fi
'

# ====== Homebrew from Brewfile ======
timed "Restoring Homebrew (Brewfile)" '
  if [ -f "$FILES_DIR/Brewfile" ]; then
    if ! command -v brew >/dev/null 2>&1; then
      note "Installing Homebrew…"
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      echo '\''eval "$(/opt/homebrew/bin/brew shellenv)"'\'' >> ~/.zprofile
      eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
    note "Running brew bundle (this can take a while)…"
    brew bundle --file="$FILES_DIR/Brewfile"
  else
    note "No Brewfile found (skipping)."
  fi
'

# ====== Dock (optional) ======
timed "Restoring Dock Layout" '
  if [ -f "$FILES_DIR/com.apple.dock.plist" ]; then
    note "Restoring Dock plist…"
    # Convert XML back to binary and copy to Preferences
    plutil -convert binary1 "$FILES_DIR/com.apple.dock.plist" -o ~/Library/Preferences/com.apple.dock.plist
    killall Dock || true
    note "Dock layout restored. (If it doesn’t look right, log out and back in.)"
  else
    note "No Dock plist captured (skipping)."
  fi
'

# ====== Cleanup extracted data (optional) ======
if [ "${CLEAN_EXTRACT}" = true ] && [ -n "${EXTRACT_DIR:-}" ] && [ -d "$EXTRACT_DIR" ]; then
  timed "Cleaning Up Extracted Files" '
    note "Removing temporary extract folder: $EXTRACT_DIR"
    rm -rf "$EXTRACT_DIR"
  '
fi


section "All Done"
ok "Restore complete! Log saved to: $LOGFILE"
bullet "Sign into iCloud/App Store and license managers (iLok, Arturia, NI, UA, etc.)."
bullet "Open Mail/Calendar to let them reindex."
bullet "Point DAWs at your sample libraries if on external drives."
