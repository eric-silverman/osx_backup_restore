#!/bin/bash
set -euo pipefail

# Refreshes the LaunchAgent after editing the plist.
# Usage: ./automation/update_launch_agent.sh [--hour H] [--minute M]
#   --hour H     Override the StartCalendarInterval Hour (0-23)
#   --minute M   Override the StartCalendarInterval Minute (0-59)

OVERRIDE_HOUR=""
OVERRIDE_MINUTE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hour)   OVERRIDE_HOUR="$2"; shift 2 ;;
    --minute) OVERRIDE_MINUTE="$2"; shift 2 ;;
    *)        echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST_SRC="$SCRIPT_DIR/com.osxbackup.daily.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/com.osxbackup.daily.plist"

if [ ! -f "$PLIST_SRC" ]; then
  echo "Missing plist at $PLIST_SRC" >&2
  exit 1
fi

mkdir -p "$(dirname "$PLIST_DEST")"
cp "$PLIST_SRC" "$PLIST_DEST"

# Auto-correct the hardcoded script path to match this repo's location.
DAILY_SCRIPT="$SCRIPT_DIR/daily_backup.sh"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:1 $DAILY_SCRIPT" "$PLIST_DEST"
echo "Updated ProgramArguments[1] → $DAILY_SCRIPT"

# Override schedule if requested.
if [[ -n "$OVERRIDE_HOUR" ]]; then
  /usr/libexec/PlistBuddy -c "Set :StartCalendarInterval:Hour $OVERRIDE_HOUR" "$PLIST_DEST"
  echo "Updated Hour → $OVERRIDE_HOUR"
fi
if [[ -n "$OVERRIDE_MINUTE" ]]; then
  /usr/libexec/PlistBuddy -c "Set :StartCalendarInterval:Minute $OVERRIDE_MINUTE" "$PLIST_DEST"
  echo "Updated Minute → $OVERRIDE_MINUTE"
fi

LABEL=$(/usr/libexec/PlistBuddy -c "Print:Label" "$PLIST_DEST" 2>/dev/null || true)
LABEL=${LABEL:-com.osxbackup.daily}

launchctl bootout "gui/$(id -u)" "$PLIST_DEST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_DEST"
launchctl kickstart -k "gui/$(id -u)/$LABEL"

echo "LaunchAgent refreshed:"
echo "  Plist: $PLIST_DEST"
echo "  Label: $LABEL"
