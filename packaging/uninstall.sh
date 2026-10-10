#!/bin/zsh
# Stops AtmosEQ and removes the login item, the app and its permission entries.
set -u
LABEL=dev.chillibytes.atmoseq
APP="$HOME/Applications/AtmosEQ.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null
rm -f "$PLIST"
rm -rf "$APP" "$HOME/Library/Application Support/AtmosEQ"
for service in AudioCapture ScreenCapture AppleEvents Accessibility; do tccutil reset $service "$LABEL" >/dev/null 2>&1; done
defaults delete "$LABEL" 2>/dev/null
echo "AtmosEQ removed. Logs are still in ~/Library/Logs/AtmosEQ.log*"
