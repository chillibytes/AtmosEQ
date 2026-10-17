#!/bin/zsh
# Builds AtmosEQ.app (the launcher, which holds the permissions) and the engine, installs
# them, registers a login item (a LaunchAgent, so it also restarts after a crash), and
# walks through the permissions, waiting until each one is on.
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
SOURCE_HASH="$ENGINE_DIR/launcher.sha256"

echo "Building…"
rm -rf build && mkdir -p "$BUILD/Contents/MacOS"
swiftc -O -swift-version 5 packaging/launcher.swift -o "$BUILD/Contents/MacOS/AtmosEQ"
cp packaging/Info.plist "$BUILD/Contents/Info.plist"
codesign --force --sign - --identifier "$LABEL" "$BUILD" 2>/dev/null   # ad hoc
# The engine stays a plain binary outside the bundle (see packaging/launcher.swift).
swiftc -O -swift-version 5 main.swift -o build/atmoseq 2>build/swiftc.log || { cat build/swiftc.log; exit 1 }
codesign --force --sign - --identifier atmoseq build/atmoseq 2>/dev/null

# Stop every running copy. launchd stops the login item in the background, and copies
# started from a terminal, Finder or System Settings aren't launchd's at all; registering
# the login item while one is still around fails ("Bootstrap failed: 5").
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
pkill -INT -x atmoseq 2>/dev/null || true      # an engine started by hand from a terminal
pkill -TERM -x AtmosEQ 2>/dev/null || true     # a launcher started outside launchd
for i in {1..50}; do
  launchctl print "gui/$UID/$LABEL" &>/dev/null || pgrep -qx 'AtmosEQ|atmoseq' || break
  /bin/sleep 0.1
done
pkill -KILL -x AtmosEQ 2>/dev/null || true     # older launchers ignored SIGTERM while waiting

mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs" "$ENGINE_DIR"
cdhash() { codesign -dvvv "$1" 2>&1 | awk -F= '/^CDHash=/{print $2}'; }
source_hash=$(cat packaging/launcher.swift packaging/Info.plist | shasum -a 256)
# macOS ties permissions to the exact ad-hoc build. Keep the installed launcher while its
# source is unchanged, even if a compiler update would now build it differently.
if [[ -d "$APP" ]] && [[ "$(cat "$SOURCE_HASH" 2>/dev/null)" == "$source_hash" || "$(cdhash "$APP")" == "$(cdhash "$BUILD")" ]]; then
  echo "AtmosEQ.app is unchanged; keeping it (and its permissions)."
else
  if [[ -d "$APP" ]]; then
    # The old grants don't match the new build. Clear them so macOS asks again instead of
    # silently refusing.
    for service in AudioCapture ScreenCapture AppleEvents Accessibility; do tccutil reset $service "$LABEL" >/dev/null 2>&1 || true; done
    rm -rf "$APP"
  fi
  cp -R "$BUILD" "$APP"
fi
print -r -- "$source_hash" > "$SOURCE_HASH"
cp build/atmoseq "$ENGINE_DIR/atmoseq"

sed -e "s|@APP@|$APP|g" -e "s|@LOG@|$LOG|g" "packaging/$LABEL.plist" > "$PLIST"
launchctl enable "gui/$UID/$LABEL" 2>/dev/null || true
for attempt in {1..10}; do
  launchctl bootstrap "gui/$UID" "$PLIST" 2>/dev/null && break
  (( attempt < 10 )) || launchctl bootstrap "gui/$UID" "$PLIST"   # last try: show the error and stop
  /bin/sleep 0.5
done
echo "Installed: $APP, starting at login."

# Permissions. Each check starts a fresh copy of the app through LaunchServices: macOS fixes
# the Screen Recording answer for the life of a process, and a copy started from this script
# would be checked as the terminal instead.
permission() {
  local f=$(mktemp)
  # (-W complains when the copy has already exited by the time it starts waiting)
  open -W -g -n "$APP" --args --status "$f" 2>/dev/null || true
  for i in {1..20}; do [[ -s $f ]] && break; /bin/sleep 0.1; done
  sed -n "s/^$1=//p" "$f"
  rm -f "$f"
}
setting_up=""
allow() {   # allow KEY "Name in System Settings" PANE
  if [[ $(permission $1) == yes ]]; then echo "  ✓ $2"; return; fi
  if [[ -z $setting_up ]]; then
    setting_up=1
    echo "\nAtmosEQ needs a few permissions; this waits until each one is on (Ctrl-C to finish later)."
  fi
  echo "  → $2: turn on AtmosEQ in the System Settings window that opens."
  echo "    (If AtmosEQ isn't listed: click +, open your home folder's Applications folder, pick AtmosEQ.)"
  open -g -n "$APP" --args --ask $1   # adds AtmosEQ to the list, and may show a dialog too
  /bin/sleep 1
  open "x-apple.systempreferences:com.apple.preference.security?$3"
  until [[ $(permission $1) == yes ]]; do /bin/sleep 2; done
  pkill -f "AtmosEQ.app/Contents/MacOS/AtmosEQ --ask" 2>/dev/null || true
  echo "  ✓ $2"
}

if [[ ! -t 0 || ! -t 1 ]]; then
  echo "Not run from a terminal, so not setting up permissions. Run \`make install\` in Terminal to do that."
  exit 0
fi
allow screen-recording "Screen & System Audio Recording (for the audio tap)" Privacy_ScreenCapture
allow accessibility "Accessibility (to read Music's Equalizer window)" Privacy_Accessibility
case $(permission music) in
  yes) echo "  ✓ Control of Music (to read EQ presets)" ;;
  ask)
    echo "  → Control of Music: click Allow in the dialog."
    open -W -g -n "$APP" --args --ask music 2>/dev/null || true
    if [[ $(permission music) == yes ]]; then echo "  ✓ Control of Music"
    else echo "  ✗ Control of Music was declined. To change that: System Settings > Privacy & Security > Automation > AtmosEQ > Music."; fi ;;
  no) echo "  ✗ Control of Music is off. To turn it on: System Settings > Privacy & Security > Automation > AtmosEQ > Music." ;;
  *) echo "  • Control of Music: macOS asks the first time Music plays with AtmosEQ running. Click Allow." ;;
esac

launchctl kickstart -k "gui/$UID/$LABEL"
/bin/sleep 2
if pgrep -qx atmoseq; then
  echo "\nDone. AtmosEQ is running and starts at login. What it's doing: $LOG"
else
  echo "\nAtmosEQ didn't start. The end of $LOG says why."
fi
