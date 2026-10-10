# AtmosEQ

Brings Apple Music's equalizer back for Dolby Atmos tracks on macOS 26 and 27.

## The bug

Since macOS 26, Music's EQ is silently skipped whenever a track plays in Dolby Atmos. The Equalizer window still works and stereo tracks are still equalized, but Atmos tracks play flat on every output device. On macOS 15 the EQ applied to Atmos as well.

It has been reported to Apple and is still present in macOS 26.7.1 and the 27.2 developer beta.

## What AtmosEQ does

AtmosEQ is a small command-line helper that runs next to Music:

- It taps Music's output after Music has rendered Atmos, so spatial rendering and head tracking are untouched.
- It applies the EQ Music would have applied. The filter design and the preamp behaviour were measured from Music itself and match within about 0.3 dB.
- It reads the sliders from Music's own Equalizer window, so you keep using that window as before. Changes apply while you drag.
- It only steps in when Music reports an Atmos track and has skipped its own EQ. Stereo tracks pass through untouched, so nothing is equalized twice.
- Its audio stream runs only while Music is playing, so it does not keep your headphones or your Mac awake.

## Requirements

- macOS 26 or later, on an administrator account (the helper reads Music's log lines with `/usr/bin/log`)
- Xcode or the Command Line Tools, for `swiftc`
- Music's EQ switched on (Window > Equalizer)

## Build and run

```sh
make          # or: swiftc -O -swift-version 5 main.swift -o atmoseq
./atmoseq
```

Leave it running in a terminal. Ctrl-C stops it and Music plays as before.

A normal session looks like this:

```
tap ready on AirPods Pro @ 48000 Hz, 2 ch (device-stream tap, no drift compensation)
playing → tap running
EQ "Manual": preamp -2.8 dB (EQ strength 73%), bands 12.0 8.6 4.6 2.0 0.0 2.2 2.4 2.5 3.8 3.3
Atmos track, Music skipped its EQ → applying "Manual"
passthrough: stereo track (lossless) — Music's own EQ handles it
stopped → tap idle (device free to sleep)
```

## Permissions

macOS asks for these on behalf of the app you start the helper from (Terminal, iTerm and so on):

| Permission | Needed for | Without it |
|---|---|---|
| System Audio Recording | the audio tap | The tap delivers silence. The helper notices within a few seconds and lets go, so Music is audible again. |
| Automation → Music | reading preset values by name | No EQ values when the Equalizer window is closed. |
| Accessibility | reading the Equalizer window's sliders live | It follows one preset by name (`--preset`, default `Manual`) with a short delay. |

## The preamp

Music's preamp is not a volume control. It sets how much of the EQ is applied:

| Preamp | EQ strength |
|---|---|
| 0 dB | 100% (the sliders as shown) |
| −6 dB | 50% of the boost |
| −12 dB | 25% of the boost |
| above 0 dB | more than the sliders show, up to a ceiling |

Music itself only reads the preamp when a track starts. AtmosEQ applies it while you drag.

## Options

| Option | Effect |
|---|---|
| `--preset NAME` | Preset to follow while the Equalizer window is closed. Default: the last one seen in that window, else `Manual`. |
| `--preamp DB` | Use this preamp instead of Music's slider. |
| `--always` | Apply the EQ to everything and ignore Music's log. Switch Music's own EQ off if you use this. |
| `--test SECONDS` | Silent self-test. Outputs nothing and records the audio before and after the EQ to `test-dry.wav` and `test-eq.wav`. |
| `--target PID` | With `--test`: tap another process instead of Music (it is muted). Used with `research/tonegen`. |

## Status and limits

- Tested on macOS 26.7.1 (25G241) with Music 1.6.6 and AirPods Pro 3. It follows output changes and has also attached to AirPods Max and the built-in speakers.
- It runs in a terminal. There is no login item or menu bar app yet.
- It depends on three of Music's log messages: `EQEffectsProcessor::Prepare/Unprepare stream`, `EQEffectsProcessor::SetEQSettings` and `Audio format changed to PBAudioFormat`. If a macOS update removes them, the helper stops adding EQ and Atmos plays flat again; it never stacks a second EQ on a stereo track.
- Only boosts were measured. Sliders below 0 dB are assumed to mirror boosts.
- If Music plays to something other than the system output device, such as AirPlay, there is nothing to tap and the helper stays idle.
- The tap adds about one audio buffer of delay (roughly 10 ms).

## How it works

[FINDINGS.md](FINDINGS.md) has the investigation: why Music skips the EQ, why the tap has to be clocked by the output device, and how Music's EQ and preamp were identified.

The tools used for those measurements are in [research/](research/).

## Disclaimer

This project is not affiliated with Apple or Dolby. Apple Music, AirPods and Dolby Atmos are trademarks of their respective owners.
