#!/bin/zsh
# Measures Music's EQ curve: plays the same 20 s of the current track twice (EQ on, then
# off), records Music's output both times, and prints the measured response.
#
# Needs: a stereo track playing (Music's EQ does nothing on Atmos, which is the bug; set
# Dolby Atmos to Off in Music > Settings > Playback and start a new track), Accessibility
# permission for UI scripting, an English Music UI, and the tools in bin/ (make research).
# You hear the passage twice. Your EQ ends up switched back on.
set -u
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
# Slider values in the Equalizer window are hundredths of a dB: preamp, then the 10 bands.
sliders() { eqwin; ui 'set out to ""
repeat with i from 1 to 11
set out to out & ((value of slider i of window "Equalizer") as integer) & " "
end repeat
return out' | awk '{for (i = 1; i <= NF; i++) printf "%.2f ", $i / 100}'; }
eqstate() { /usr/bin/log show --last 4s --predicate 'process == "Music" AND eventMessage CONTAINS "EQEffectsProcessor::SetEQSettings"' 2>/dev/null | grep -oE '\((enabled|disabled)\)' | tail -1; }

fmt=$(/usr/bin/log show --last 30m --predicate 'process == "Music" AND eventMessage CONTAINS "Audio format changed to"' 2>/dev/null | grep -oE 'PBAudioFormat\.[A-Za-z]+' | grep -v other | tail -1)
echo "current track: $(ms 'get name of current track') [$fmt]"
[[ "$fmt" == *dolbyAtmos* ]] && { echo "ABORT: this is an Atmos track; Music's EQ does not apply to it."; exit 1; }
vals=($(sliders)); pre=$vals[1]; bands=(${vals[2,11]})
dur=$(ms 'get duration of current track'); pos=$(ms 'get player position')
start=$(awk -v d="$dur" -v p="$pos" 'BEGIN { printf "%.2f", (p + 26 < d) ? p : ((d - 32 > 0) ? d - 32 : 0) }')
echo "preamp $pre | bands $bands | passage starts at ${start}s"

echo "EQ checkbox: $(eqset 1)"; ms "set player position to $start" >/dev/null; /bin/sleep 0.8
../bin/musicrec 20 on.wav
echo "EQ checkbox: $(eqset 0)"; /bin/sleep 0.4; echo "Music log: $(eqstate)"
ms "set player position to $start" >/dev/null; /bin/sleep 0.8
../bin/musicrec 20 off.wav
echo "EQ checkbox restored: $(eqset 1)"; /bin/sleep 0.4; echo "Music log: $(eqstate)"
# Note: the preamp only takes effect when a stream starts, so "pre" is only meaningful if
# this stream began with that preamp. Use measure-preamp.sh to study the preamp itself.
LOG2N=16 ../bin/eqmeasure on.wav off.wav $pre $bands
