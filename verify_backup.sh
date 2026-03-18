#!/bin/bash
set -euo pipefail

# Usage: ./verify_backup.sh /path/to/System_Backup_<timestamp>[.tgz|.zip]
# Works on a backup directory or a tar/zip archive by inspecting contents.

TARGET=${1:-}
if [ -z "$TARGET" ]; then
  echo "Usage: $0 /path/to/System_Backup_<timestamp>[.tgz|.zip]" >&2
  exit 1
fi

if [ -d "$TARGET" ]; then
  MODE="dir"
  ROOT="$TARGET"
elif [ -f "$TARGET" ]; then
  case "$TARGET" in
    *.tgz|*.tar.gz) MODE="tar" ;;
    *.zip) MODE="zip" ;;
    *) echo "Unsupported archive type: $TARGET" >&2; exit 1 ;;
  esac
  # Find top-level folder name inside archive (first path component)
  if [ "$MODE" = "tar" ]; then
    ROOT=$(tar -tf "$TARGET" | head -n 1 | cut -d/ -f1)
  else
    ROOT=$(unzip -Z1 "$TARGET" | head -n 1 | cut -d/ -f1)
  fi
else
  echo "Target not found: $TARGET" >&2
  exit 1
fi

if [ -z "$ROOT" ]; then
  echo "Could not determine backup root inside archive." >&2
  exit 1
fi

case "$MODE" in
  dir)
    has_item() { [ -e "$ROOT/$1" ]; }
    ;;
  tar)
    has_item() { tar -tf "$TARGET" | grep -Fqx "$ROOT/$1"; }
    ;;
  zip)
    has_item() { unzip -Z1 "$TARGET" | grep -Fqx "$ROOT/$1"; }
    ;;
esac

PASS=0
FAIL=0

check() {
  local path="$1"; local desc="$2"; local optional="${3:-false}"
  if has_item "$path"; then
    echo "✅ $desc → $path"
    PASS=$((PASS+1))
  else
    if $optional; then
      echo "ℹ️  $desc missing (optional) → $path"
    else
      echo "⚠️  $desc missing → $path"
      FAIL=$((FAIL+1))
    fi
  fi
}

echo "Verifying backup: $TARGET"
echo "Mode: $MODE  | Root: $ROOT"
echo ""

check "backup_summary.txt" "Backup summary" true
check "lists/applications_list.txt" "Applications list"
check "lists/brew_list.txt" "Homebrew packages"
check "lists/brew_cask_list.txt" "Homebrew casks"
check "files/Brewfile" "Brewfile"
check "lists/mas_list.txt" "MAS list" true
check "lists/dock_readable.txt" "Dock defaults" true
check "files/com.apple.dock.plist" "Dock plist" true
check "files/fonts_user" "User fonts" true
check "files/fonts_system" "System fonts" true
check "files/audio_plugins_user" "User audio plugins" true
check "files/audio_plugins_sys" "System audio plugins" true
check "files/midi" "MIDI drivers/configs" true
check "files/Audio Music Apps" "Logic/DAW data" true
check "files/Ableton" "Ableton data" true
check "files/Pro Tools" "Pro Tools data" true
check "files/ssh" "SSH configs" true
check "files/gnupg" "GPG configs" true
check "files/dot_config" "~/.config" true
check "files/bin" "~/bin" true
check "files/local_bin" "~/.local/bin" true
check "files/vscode_user" "VS Code User settings" true
check "files/sublime_user" "Sublime User settings" true
check "files/cursor_user" "Cursor settings" true
check "files/cursor_extensions" "Cursor extensions" true
check "files/colorsync_user" "ColorSync profiles (user)" true
check "files/colorsync_system" "ColorSync profiles (system)" true
check "files/quicklook_user" "QuickLook plugins (user)" true
check "files/quicklook_system" "QuickLook plugins (system)" true
check "files/apple_mail" "Apple Mail" true
check "files/services" "Services" true
check "files/shortcuts" "Shortcuts" true
check "files/calendars" "Calendars" true
check "User_Folder" "Home folder rsync copy"
check "archives/Desktop.tar.gz" "Desktop archive" true
check "archives/Documents.tar.gz" "Documents archive" true
check "archives/Downloads.tar.gz" "Downloads archive" true
check "archives/Pictures.tar.gz" "Pictures archive" true
check "archives/Movies.tar.gz" "Movies archive" true

echo ""
echo "Passed: $PASS  | Missing (required): $FAIL"
[ $FAIL -eq 0 ] || exit 1
