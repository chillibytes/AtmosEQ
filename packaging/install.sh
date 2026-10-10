#!/bin/zsh
# Builds AtmosEQ.app (the launcher, which holds the permissions) and the engine, installs
# them, and registers a login item (a LaunchAgent, so it also restarts after a crash).
# Permissions belong to the launcher, so they survive engine updates; only a changed
# launcher has to be allowed again.
set -eu
cd "${0:A:h}/.."
LABEL=dev.chillibytes.atmoseq
APP="$HOME/Applications/AtmosEQ.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/AtmosEQ.log"
BUILD=build/AtmosEQ.app
ENGINE_DIR="$HOME/Library/Application Support/AtmosEQ"

rm -rf build && mkdir -p "$BUILD/Contents/MacOS"
swiftc -O -swift-version 5 packaging/launcher.swift -o "$BUILD/Contents/MacOS/AtmosEQ"
cp packaging/Info.plist "$BUILD/Contents/Info.plist"
codesign --force --sign - --identifier "$LABEL" "$BUILD" 2>/dev/null   # ad hoc
# The engine stays a plain binary outside the bundle (see packaging/launcher.swift).
swiftc -O -swift-version 5 main.swift -o build/atmoseq 2>/dev/null
codesign --force --sign - --identifier atmoseq build/atmoseq

cdhash() { codesign -dvvv "$1" 2>&1 | awk -F= '/^CDHash=/{print $2}'; }
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
pkill -INT -x atmoseq 2>/dev/null || true      # a copy started by hand from a terminal
/bin/sleep 1

mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
if [[ -d "$APP" && "$(cdhash "$APP")" == "$(cdhash "$BUILD")" ]]; then
  echo "AtmosEQ.app is already this build; keeping it (and its permissions)."
else
  if [[ -d "$APP" ]]; then
    # macOS ties permissions to the exact ad-hoc build. Clear the old grants so it asks
    # again instead of silently refusing.
    for service in AudioCapture ScreenCapture AppleEvents Accessibility; do tccutil reset $service "$LABEL" >/dev/null 2>&1 || true; done
    rm -rf "$APP"
  fi
  cp -R "$BUILD" "$APP"
fi

mkdir -p "$ENGINE_DIR"
cp build/atmoseq "$ENGINE_DIR/atmoseq"

sed -e "s|@APP@|$APP|g" -e "s|@LOG@|$LOG|g" "packaging/$LABEL.plist" > "$PLIST"
launchctl bootstrap "gui/$UID" "$PLIST"

cat <<MSG
Installed. AtmosEQ now starts at login.
  app:  $APP
  log:  $LOG
macOS will ask for three permissions the first time: System Audio Recording,
control of Music, and Accessibility (that one opens System Settings).
MSG
