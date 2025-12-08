#!/bin/bash
set -euo pipefail

# Refreshes the LaunchAgent after editing the plist.
# Usage: ./automation/update_launch_agent.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST_SRC="$SCRIPT_DIR/com.eric.dailybackup.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/com.osxbackup.daily.plist"

if [ ! -f "$PLIST_SRC" ]; then
  echo "Missing plist at $PLIST_SRC" >&2
  exit 1
fi

mkdir -p "$(dirname "$PLIST_DEST")"
cp "$PLIST_SRC" "$PLIST_DEST"

LABEL=$(/usr/libexec/PlistBuddy -c "Print:Label" "$PLIST_DEST" 2>/dev/null || true)
LABEL=${LABEL:-com.osxbackup.daily}

launchctl bootout "gui/$(id -u)" "$PLIST_DEST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_DEST"
launchctl kickstart -k "gui/$(id -u)/$LABEL"

echo "LaunchAgent refreshed:"
echo "  Plist: $PLIST_DEST"
echo "  Label: $LABEL"
