#!/bin/zsh
# Preamp sweep: for preamp 0, -12, -6 and +6 dB it starts a FRESH stream of one track, then
# records the same passage with Music's EQ on and off. Also records two controls: a preamp
# change made mid-stream, and one followed by toggling the EQ off and on.
#
# Usage: measure-preamp.sh PLAYLIST TRACK_PERSISTENT_ID [POSITION_SECONDS]
#   the track must be in PLAYLIST; get its ID with
#   osascript -e 'tell application "Music" to get persistent ID of current track'
#
# Silent: calrec holds a muted tap on Music for the whole run. It takes over Music for about
# four minutes (switches Dolby Atmos to Off, moves the preamp, toggles the EQ) and restores
# the track, position, preamp, EQ switch and Dolby Atmos = Automatic afterwards.
# Needs Accessibility permission, an English Music UI, and the tools in bin/ (make research).
set -u
PLAYLIST=${1:?playlist name}; TRACK=${2:?track persistent ID}; X=${3:-62}; LEN=14
cd "${0:A:h}"; mkdir -p out; cd out
ms() { osascript -e "tell application \"Music\" to $1"; }
ui() { osascript -e "tell application \"System Events\" to tell process \"Music\"
$1
end tell"; }
eqwin() { ui 'if not (exists window "Equalizer") then click menu item "Equalizer" of menu 1 of menu bar item "Window" of menu bar 1
delay 0.3' >/dev/null; }
eqset() { eqwin; ui "set cb to checkbox \"On\" of window \"Equalizer\"
if (value of cb as integer) is not $1 then click cb
delay 0.2
return value of cb"; }
setpre() { eqwin; ui "set value of slider 1 of window \"Equalizer\" to $1
delay 0.3
return value of slider 1 of window \"Equalizer\""; }
atmos() { ui "click menu item \"Settings…\" of menu 1 of menu bar item 2 of menu bar 1
delay 1
click button \"Playback\" of toolbar 1 of window 1
delay 0.5
set g to group 1 of window \"Playback\"
set a to pop up button 3 of g
click a
delay 0.4
click menu item \"$1\" of menu 1 of a
delay 0.3
set v to value of a
click button \"OK\" of g
return v"; }
laststream() { /usr/bin/log show --last 12s --predicate 'process == "Music" AND eventMessage CONTAINS "EQEffectsProcessor::Prepare stream"' 2>/dev/null | grep -oE 'stream [0-9]+' | tail -1; }
lastfmt() { /usr/bin/log show --last 12s --predicate 'process == "Music" AND eventMessage CONTAINS "Audio format changed to"' 2>/dev/null | grep -oE 'PBAudioFormat\.[A-Za-z]+' | grep -v other | tail -1; }
rec() { print -u3 "rec $1"; /bin/sleep $2; print -u3 "end"; /bin/sleep 0.3; }
fresh() { ms "play (first track of playlist \"$PLAYLIST\" whose persistent ID is \"$TRACK\")" >/dev/null; /bin/sleep 3.5; }

# --- snapshot
ORIG_ID=$(ms 'get persistent ID of current track'); ORIG_LIST=$(ms 'get name of current playlist')
ORIG_POS=$(ms 'get player position'); ORIG_REPEAT=$(ms 'get song repeat as string')
eqwin; ORIG_PRE=$(ui 'return value of slider 1 of window "Equalizer"'); ORIG_EQ=$(ui 'return value of checkbox "On" of window "Equalizer"')
echo "snapshot: track $ORIG_ID in \"$ORIG_LIST\" at ${ORIG_POS}s, preamp slider $ORIG_PRE, eq $ORIG_EQ"

rm -f ctl.fifo; mkfifo ctl.fifo
../bin/calrec < ctl.fifo > calrec.log 2>&1 &
exec 3> ctl.fifo
for i in {1..40}; do grep -q '^ready' calrec.log 2>/dev/null && break; /bin/sleep 0.25; done
grep -q '^ready' calrec.log || { echo "calrec not ready: $(cat calrec.log)"; print -u3 quit; exit 1; }

cleanup() {
  ms 'pause' >/dev/null 2>&1          # Music must be paused before the muted tap goes away
  echo "restore: preamp $(setpre $ORIG_PRE), eq $(eqset $ORIG_EQ), atmos $(atmos Automatic)"
  ui 'if exists window "Equalizer" then click (first button of window "Equalizer" whose subrole is "AXCloseButton")' >/dev/null 2>&1
  ms "play (first track of playlist \"$ORIG_LIST\" whose persistent ID is \"$ORIG_ID\")" >/dev/null 2>&1
  /bin/sleep 1.5; ms 'pause' >/dev/null 2>&1
  ms "set player position to $ORIG_POS" >/dev/null 2>&1; ms "set song repeat to $ORIG_REPEAT" >/dev/null 2>&1
  print -u3 quit; exec 3>&-; wait; rm -f ctl.fifo
  echo "restored (paused): $(ms 'get {name of current track, player position}')"
}
trap cleanup EXIT

echo "atmos → $(atmos Off)"; echo "eq → $(eqset 1)"
for P in 0 -1200 -600 600; do
  echo "--- preamp slider $(setpre $P)"
  fresh; echo "    fresh stream: $(laststream), format $(lastfmt)"
  ms "set player position to $X" >/dev/null; /bin/sleep 0.8; rec on_$P $LEN
  if [[ $P == 0 ]]; then            # control 1: change the preamp while the stream runs
    echo "    live change → $(setpre -1200)"; /bin/sleep 0.5
    ms "set player position to $X" >/dev/null; /bin/sleep 0.8; rec on_0_live-1200 $LEN
    echo "    back → $(setpre 0)"
  fi
  eqset 0 >/dev/null; /bin/sleep 0.5
  ms "set player position to $X" >/dev/null; /bin/sleep 0.8; rec off_$P $LEN
  eqset 1 >/dev/null; /bin/sleep 0.3
done
# control 2: stream started at +6; change the preamp, toggle the EQ off and on
echo "--- toggle test: preamp $(setpre -1200) then EQ off/on"; /bin/sleep 0.4
eqset 0 >/dev/null; /bin/sleep 0.6; eqset 1 >/dev/null; /bin/sleep 0.6
ms "set player position to $X" >/dev/null; /bin/sleep 0.8; rec on_toggle-1200 $LEN
grep saved calrec.log
echo
echo 'next: ../bin/preamplaw "<g1,...,g10>" 0 on_0.wav off_0.wav -6 on_-600.wav off_0.wav -12 on_-1200.wav off_0.wav'
