#!/usr/bin/env python3
# Pitch/phase check of a recorded 1 kHz tone (from tapprobe or `atmoseq --test`), lined up with
# the Bluetooth driver's "audio delivery speed" log events. Usage: tone.py PREFIX [START_UNIX_TIME]
import sys, array, datetime, subprocess, re
prefix = sys.argv[1]
fs = 48000.0
raw = open(prefix + '.wav', 'rb').read(); nch = int.from_bytes(raw[22:24], 'little')
x = array.array('f'); x.frombytes(raw[44:]); x = x[0::nch]
import os
if not os.path.exists(prefix + '.csv'):
    csvp = None
else:
    csvp = prefix + '.csv'
lines = open(csvp).read().splitlines() if csvp else ['startHost,0,startWall,%f,numer,1,denom,1' % float(sys.argv[2]), 'h', '0,0,0,1,0,0,1,%d' % 10**9]
h = lines[0].split(','); startHost = float(h[1]); startWall = float(h[3]); numer = float(h[5]); denom = float(h[7])
cbs = [list(map(float, l.split(','))) for l in lines[2:]]
# frame index -> host time via callback 'now' (start of each callback's block)
fidx = []; acc = 0
for c in cbs: fidx.append((acc, c[0])); acc += int(c[7])
def wall_of_frame(i):
    lo, hi = 0, len(fidx) - 1
    while lo < hi:
        m = (lo + hi + 1) // 2
        if fidx[m][0] <= i: lo = m
        else: hi = m - 1
    f0, host = fidx[lo]
    return startWall + (host - startHost) * numer / denom / 1e9 + (i - f0) / fs
# upward zero crossings with linear interpolation
zc = []
for i in range(1, len(x)):
    a, b = x[i - 1], x[i]
    if a < 0 <= b and (b - a) > 1e-4: zc.append(i - 1 + (-a) / (b - a))
print(f"{len(x)} frames, {len(zc)} upward crossings")
if len(zc) < 100: sys.exit()
# per-100ms frequency
win = []
k = 0
while k < len(zc) - 1:
    j = k
    while j + 1 < len(zc) and zc[j + 1] - zc[k] < 4800: j += 1
    if j > k: win.append((zc[k], (j - k) / ((zc[j] - zc[k]) / fs)))
    k = j + 1
fr = [f for _, f in win]
print(f"freq per 100ms: min {min(fr):.2f}  max {max(fr):.2f}  (ideal 1000.00)")
off = [(t, f) for t, f in win if abs(f - 1000) > 2]
print(f"windows off by >2 Hz: {len(off)} of {len(win)}")
# phase residual vs ideal 48 samples/cycle, look for slopes (rate change) and jumps (drop/repeat)
res = [(zc[n], zc[n] - (zc[0] + n * 48.0)) for n in range(len(zc))]
jumps = []
for n in range(1, len(zc)):
    d = (zc[n] - zc[n - 1]) - 48.0
    if abs(d) > 1.0: jumps.append((zc[n], d))
print(f"period glitches (>1 sample off): {len(jumps)}; final phase drift {res[-1][1]:+.1f} samples")
def ts(i): return datetime.datetime.fromtimestamp(wall_of_frame(i)).strftime('%H:%M:%S.%f')[:-3]
# group consecutive off-pitch windows into episodes
ep = []
for t, f in off:
    if ep and t - ep[-1][1] < 9600: ep[-1][1] = t; ep[-1][2].append(f)
    else: ep.append([t, t, [f]])
for s, e, fs_ in ep:
    print(f"  off-pitch {ts(s)} → {ts(e)}  ({(e - s) / fs + 0.1:.1f}s)  freq {min(fs_):.1f}–{max(fs_):.1f} Hz")
for t, d in jumps[:40]:
    print(f"  glitch {ts(t)}  period off by {d:+.1f} samples")
# rate scalars from timestamps
ir = [c[3] for c in cbs]; orr = [c[6] for c in cbs]
print(f"input rateScalar {min(ir):.4f}–{max(ir):.4f}; output rateScalar {min(orr):.4f}–{max(orr):.4f}")
# coreaudiod delivery-speed events in the window
s0 = datetime.datetime.fromtimestamp(startWall).strftime('%Y-%m-%d %H:%M:%S')
s1 = datetime.datetime.fromtimestamp(startWall + len(x) / fs + 1).strftime('%Y-%m-%d %H:%M:%S')
out = subprocess.run(['/usr/bin/log', 'show', '--start', s0, '--end', s1, '--info', '--predicate',
    'process == "coreaudiod" AND (eventMessage CONTAINS "delivery speed" OR eventMessage CONTAINS "Overload thread")'], capture_output=True, text=True).stdout
for l in out.splitlines():
    m = re.search(r'(\d\d:\d\d:\d\d\.\d{3}).*?(Latency Target \d+, Currently running [A-Za-z ]+, multiplier [0-9.]+|Audio IO Overload)', l)
    if m: print("  log", m.group(1), m.group(2))
