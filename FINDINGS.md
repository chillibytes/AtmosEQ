# Findings

Notes from the investigation behind AtmosEQ. Everything here was observed on macOS 26.7.1 (25G241) with Music 1.6.6 and AirPods Pro 3, from the unified log and from recordings of Music's own output.

## 1. Why Music skips the EQ on Atmos

Music runs its EQ, Sound Enhancer and Visualizer through one audio processing tap that it attaches to each `AVPlayerItem`. Its log (subsystem `com.apple.Music`) shows the decision per item.

A stereo item gets the tap:

```
play> avf> AVCFPlayerItemSetAllowedAudioSpatializationFormats for playerItem …: 0x0
play> effects> tap> addPlayerItem <AVPlayerItem …>
play> effects> 1 effect enabled
play> effects> tap> setting playerItem.audioTapProcessor to 0x…
EQEffectsProcessor::Prepare stream N
```

An item created with spatial formats allowed never does:

```
play> avf> AVCFPlayerItemSetAllowedAudioSpatializationFormats for playerItem …: 0x4
        (no addPlayerItem, no audioTapProcessor, no EQEffectsProcessor::Prepare)
play> effects> tap> **ERROR** RemovePlayerItem not in array <AVPlayerItem …>     ← at teardown
```

So the EQ is not broken for Atmos. Music does not attach it.

The known manual workaround confirms this. If an item is created while Dolby Atmos is set to Off, it gets the tap. When playback then switches to the Atmos variant, the tap stays, `EQEffectsProcessor::Prepare` runs on the 16-channel stream, the spatial mixer still receives 12-channel 7.1.4, and the EQ is audible in Atmos. The next item created normally loses it again.

## 2. Where to intercept

Music renders spatial audio inside its own process (`AUSpatialMixerV2` in the AudioQueue mixer, head tracking included) and hands finished binaural stereo to the output device. A Core Audio process tap on Music therefore sees the final audio. Because both the renderer and the EQ are linear, equalizing after rendering gives the same result as equalizing each channel before it.

Music's stream is floating point with a lot of headroom. With a +12 dB bass boost its output peaks at 3 to 4 times full scale, and the device volume scales it down later. Clamping that signal to ±1.0 destroys it. Music's EQ output does have its own ceiling near 4.0 (+12 dBFS): a recording at preamp +6 dB had 335 samples within 0.5% of its peak value, against 4 at preamp 0.

## 3. The tap has to be clocked by the output device

During spatial playback the Bluetooth driver keeps adjusting the AirPods' latency by nudging the delivery speed. coreaudiod logs it:

```
audio delivery speed Latency Target 12, Currently running Running, multiplier 0.900000
```

This happened 301 times in 30 minutes of normal listening. It is inaudible when Music plays directly, because Music's samples stay in the device's own timeline.

A stereo-mixdown tap (`CATapDescription(stereoMixdownOfProcesses:)`) runs on a separate clock. Audio crossing from that clock to the device gets resampled, and every nudge becomes a pitch error. A phase-continuous 1000 Hz tone recorded through each configuration (`research/tonegen`, `tapprobe`, `tone.py`):

| Tap | Drift compensation | Tone after each nudge |
|---|---|---|
| stereo mixdown | on | 984–1017 Hz for about 1 s |
| stereo mixdown | off | 979–1022 Hz for about 2.7 s, plus sample slips (−836 samples in 45 s) |
| device stream | off | 1000.00 Hz; one 16-sample slip that coincided with a system-wide IO overload |
| device stream, through the helper | off | 1000.00 Hz, no slips in 42.9 s across 8 nudges |

The nudges are larger at track starts (a 93 ms latency target against the usual 6–16 ms), which made the first seconds of a track sound slowed down with the mixdown tap.

A device-stream tap (`CATapDescription(processes:deviceUID:stream:)`) on the same device as the aggregate's main sub-device, with drift compensation off, is sample-synchronous.

Two related points:

- Music stops its device IO between tracks. A helper that keeps the device running turns the latency-mode switch into a long nudge and blocks idle sleep. AtmosEQ runs its IO only while `kAudioProcessPropertyIsRunningOutput` is set for Music. It polls the property rather than relying on the change notification alone: in one session an earlier build did not resume after an output switch.
- The same IO engine logs overloads during normal playback without any helper (185 in the same 30 minutes), so a single overload is not a sign the helper is too slow.

## 4. Music's EQ and preamp

### Method

The same passage of a stereo track was recorded from Music's output with the EQ on and off (`research/musicrec`, `calrec`). The ratio of the long-term spectra is the EQ's magnitude response. Models were then fitted to it on a 1/12-octave grid from 25 Hz to 17 kHz (`research/preamplaw`).

Sliders during all measurements, 32 Hz to 16 kHz: +12, +8.56, +4.62, +2.03, 0, +2.16, +2.44, +2.45, +3.84, +3.31 dB.

### The preamp is read when a stream starts

Peak level of the same passage, EQ on:

| Preamp | How it was set | Peak |
|---|---|---|
| 0 dB | before the stream started | 3.88 |
| −12 dB | changed mid-stream | 3.89 |
| −12 dB | before the stream started | 1.20 |
| −6 dB | before the stream started | 1.87 |
| +6 dB | before the stream started | 4.02 (at the ceiling) |
| −12 dB | changed mid-stream, then EQ toggled off and on | 4.02 (still the +6 stream) |

With the EQ off the peak was 0.829 at every preamp setting.

### Measured response at the band centres (dB)

| Preamp | 32 | 64 | 125 | 250 | 500 | 1k | 2k | 4k | 8k | 16k |
|---|---|---|---|---|---|---|---|---|---|---|
| 0 | 15.7 | 15.6 | 10.2 | 4.8 | 1.6 | 3.0 | 3.8 | 4.4 | 5.4 | 3.6 |
| −2.76 | 12.7 | 12.3 | 7.5 | 3.4 | 1.2 | 2.4 | 2.9 | 3.3 | 4.2 | 2.9 |
| −6 | 9.8 | 9.0 | 5.3 | 2.2 | 0.9 | 1.6 | 1.7 | 1.9 | 3.0 | 2.1 |
| −12 | 5.7 | 4.8 | 2.6 | 1.1 | 0.4 | 0.7 | 1.0 | 0.9 | 1.5 | 1.5 |

The preamp changes the size of the boosts and leaves the overall level almost alone: it is an EQ-strength control, not a volume.

### The model

Ten bells in series. For a band with slider gain `g = 10^(dB/20)` and preamp strength `p = 10^(preamp/20)`:

```
H(f) = 1 + p · (g − 1) · BP(f)
```

`BP` is a band-pass with unity peak gain, one octave wide, designed with the bandwidth-compensated alpha from the RBJ cookbook:

```
alpha = sin(w0) · sinh(ln(2)/2 · BW · w0 / sin(w0)),   BW = 1 octave
b = (1 + alpha·k, −2cos(w0), 1 − alpha·k),  a = (1 + alpha, −2cos(w0), 1 − alpha),  k = 1 + p·(g − 1)
```

Fit quality across the five recordings (rms error, no per-recording parameters):

| Model | rms |
|---|---|
| RBJ peaking cascade, whole EQ blended by `p` | 0.53 dB |
| RBJ peaking cascade, each band's gain blended by `p` | 0.46 dB |
| bells in parallel | 0.92 dB |
| bells in series, constant Q 1.38 | 0.40 dB |
| bells in series, bandwidth form, best fit 0.99 octave | 0.26 dB |

With the series-bell model the free parameters land on their nominal values (gain scale 0.97–1.00, preamp exponent 20–20.5), which is why it is taken as the actual design. `research/results/preamplaw-output.txt` has the full output.

Not determined:

- Cuts. Every slider was at or above 0 dB, so the helper assumes cuts mirror boosts.
- The EQ's sample rate. The stereo tracks ran at 44.1 kHz; designs at 44.1, 48 and 96 kHz fit equally well. The helper designs at the device rate.
- The model runs 0.3 to 0.6 dB high between 4 and 10 kHz at preamp 0.

### The helper against Music

Measured through the helper's real pipeline (`atmoseq --test`), band centres in dB:

| Preamp | Source | 32 | 64 | 125 | 250 | 500 | 1k | 2k | 4k | 8k | 16k |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 0 | Music | 15.8 | 15.5 | 10.1 | 4.8 | 1.6 | 3.0 | 3.8 | 4.4 | 5.4 | 3.6 |
| 0 | helper | 15.1 | 15.8 | 10.2 | 4.7 | 1.6 | 3.1 | 3.8 | 4.6 | 5.8 | 3.8 |
| −6 | Music | 9.8 | 8.9 | 5.2 | 2.2 | 0.8 | 1.6 | 1.9 | 2.0 | 2.9 | 2.0 |
| −6 | helper | 9.3 | 9.0 | 5.1 | 2.2 | 0.8 | 1.6 | 2.0 | 2.4 | 3.1 | 2.0 |
| −12 | Music | 5.8 | 4.8 | 2.6 | 1.1 | 0.3 | 0.6 | 1.1 | 0.9 | 1.5 | 1.4 |
| −12 | helper | 5.4 | 4.8 | 2.5 | 1.1 | 0.4 | 0.8 | 1.0 | 1.2 | 1.6 | 1.0 |

The two sets come from different passages, and the 32 Hz column rests on one or two FFT bins, so differences of half a dB there are within the measurement.

## 5. Other things that are broken in Music

- AppleScript `EQ enabled` reads `false` while the EQ is on, and cannot be set (error −10006).
- AppleScript `current EQ preset` fails (error −1728). Named presets can still be read.

The helper therefore takes the EQ's on/off state from Music's log and the slider values from the Equalizer window through Accessibility, with AppleScript by preset name as the fallback.

## 6. When the helper adds EQ

All of these must hold, otherwise audio passes through unchanged:

1. Music's EQ log lines have been seen at all.
2. The last `EQEffectsProcessor::SetEQSettings` said `(enabled)`.
3. The last settled `Audio format changed to PBAudioFormat.…` was `dolbyAtmos`, or no format has been logged yet.
4. No stream is currently between `EQEffectsProcessor::Prepare` and `Unprepare`, meaning Music's own EQ is not running.

If a macOS update renames or hides these messages, condition 1 or 3 fails and the helper does nothing. The failure mode is flat Atmos, never a doubled EQ.

Two failsafes release the tap, which unmutes Music: only silence captured for five seconds while Music plays, or a sustained burst of IO overloads.
