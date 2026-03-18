#!/bin/bash
set -euo pipefail

# Boots out and removes the LaunchAgent plist from ~/Library/LaunchAgents.
# Usage: ./automation/remove_launch_agent.sh

PLIST_DEST="$HOME/Library/LaunchAgents/com.osxbackup.daily.plist"

# Try to read the label from the plist if present; fall back to the known label.
LABEL="com.osxbackup.daily"
if [ -f "$PLIST_DEST" ]; then
  LABEL=$(/usr/libexec/PlistBuddy -c "Print:Label" "$PLIST_DEST" 2>/dev/null || echo "$LABEL")
fi

# Stop the job if it's loaded, ignoring failures if it's already gone.
launchctl bootout "gui/$(id -u)" "$PLIST_DEST" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true

if [ -f "$PLIST_DEST" ]; then
  rm "$PLIST_DEST"
  echo "Removed plist: $PLIST_DEST"
else
  echo "Plist already absent at $PLIST_DEST"
fi

echo "LaunchAgent booted out (label: $LABEL)"
