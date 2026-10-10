# Research tools

The measurement tools behind [FINDINGS.md](../FINDINGS.md). They are experiment code: small, single-purpose, and written to answer one question each.

Build them all into `research/bin/` with `make research` from the repository root.

They need the same System Audio Recording permission as the helper. The two shell scripts also need Accessibility permission and an English Music UI, because they click through Music's Settings and Equalizer windows.

## Clock experiment (FINDINGS §3)

| File | What it does |
|---|---|
| `tonegen.swift` | Plays a phase-continuous 1000 Hz sine at −40 dBFS. Stays silent until it receives `SIGUSR1`, so the probe can mute it first. |
| `tapprobe.swift` | Taps one process (muted), records what arrives through an aggregate device, and logs the IO timestamps. Arguments choose drift compensation on or off and a stereo-mixdown or device-stream tap. |
| `tone.py` | Measures the recorded tone's pitch and phase over time and lists the Bluetooth driver's "audio delivery speed" log events from the same window. |

```sh
mkdir -p out
bin/tonegen 90 & TPID=$!; sleep 2
bin/tapprobe $TPID 45 1 out/drift_on          # stereo-mixdown tap, drift compensation on
python3 tone.py out/drift_on
bin/tonegen 90 & TPID=$!; sleep 2
bin/tapprobe $TPID 45 0 out/dev_off dev       # device-stream tap, drift compensation off
python3 tone.py out/dev_off
```

The same test through the helper's own pipeline:

```sh
bin/tonegen 90 & TPID=$!; sleep 2
START=$(python3 -c 'import time; print(time.time())')
../atmoseq --test 40 --target $TPID
python3 tone.py test-dry $START
```

Play an Atmos track in Music while these run. It triggers the latency nudges, and Music itself is not touched.

## EQ and preamp measurement (FINDINGS §4)

| File | What it does |
|---|---|
| `musicrec.swift` | Records Music's output for N seconds through an unmuted device-stream tap. |
| `calrec.swift` | Holds a muted tap on Music for its whole lifetime and records named segments on command (`rec NAME`, `end`, `quit` on stdin). Lets a measurement run without being heard. |
| `eqmeasure.swift` | Aligns an EQ-on and an EQ-off recording of the same passage and prints the response at the band centres. Its built-in fit is the early peaking-cascade model, kept for reference; `LOG2N=16` raises the frequency resolution. |
| `preamplaw.swift` | Fits the candidate EQ and preamp models to a set of recordings. This is the analysis that identified Music's design. |
| `measure-eq.sh` | Drives Music for a single EQ on/off measurement of the current stereo track. |
| `measure-preamp.sh` | Drives the preamp sweep: a fresh stream per preamp value, plus the mid-stream and EQ-toggle controls. Silent, about four minutes, restores Music afterwards. |
| `procstate.swift` | Prints a process's Core Audio state (`IsRunningOutput`, devices in use). |

```sh
./measure-preamp.sh "My Playlist" 0123456789ABCDEF 62
cd out
../bin/preamplaw "12,8.56,4.62,2.03,0,2.16,2.44,2.45,3.84,3.31" \
    0 on_0.wav off_0.wav  -6 on_-600.wav off_0.wav  -12 on_-1200.wav off_0.wav
```

The first argument to `preamplaw` is the ten band sliders in dB, as they were during the recordings.

`results/preamplaw-output.txt` is the output from the original run (five recordings: preamp 0, −6, −12, and two at −2.76 from other songs).

## Charts

`charts.py` draws the README charts into `docs/` (light and dark SVGs). The EQ chart comes from `results/preamplaw-output.txt`; the pitch chart needs the `drift_on` and `dev_off` recordings from the clock experiment: `python3 charts.py out`. Needs numpy.

## Caveats

- `measure-eq.sh` and `measure-preamp.sh` were adapted from the scripts used in the original run: file locations changed and the playlist and track became arguments. They have been syntax-checked but not re-run in this form.
- The recordings are not in the repository.
