#!/usr/bin/env python3
# Draws the README charts as plain SVG (light and dark variants) into docs/.
# Usage: charts.py PROBE_DIR   (PROBE_DIR holds drift_on.wav and dev_off.wav from tapprobe)
# The EQ chart uses results/preamplaw-output.txt and needs no recordings.
import sys, os, math, re
import numpy as np

here = os.path.dirname(os.path.abspath(__file__))
out = os.path.join(here, '..', 'docs')
os.makedirs(out, exist_ok=True)
probe = sys.argv[1] if len(sys.argv) > 1 else None

THEMES = {
    'light': dict(bg='#ffffff', fg='#1f2328', muted='#656d76', grid='#d8dee4',
                  c0='#0969da', c1='#8250df', c2='#bf3989', bad='#cf222e', good='#1a7f37'),
    'dark':  dict(bg='#0d1117', fg='#e6edf3', muted='#8d96a0', grid='#30363d',
                  c0='#4493f8', c1='#ab7df8', c2='#f778ba', bad='#f85149', good='#3fb950'),
}
FONT = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif"
W, H = 820, 412
L, R, T, B = 64, 24, 64, 52   # plot margins


def svg(theme, body, title):
    t = THEMES[theme]
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" '
            f'font-family="{FONT}" font-size="12">\n'
            f'<rect width="{W}" height="{H}" rx="8" fill="{t["bg"]}"/>\n'
            f'<text x="{L}" y="30" font-size="15" font-weight="600" fill="{t["fg"]}">{title}</text>\n'
            + body + '</svg>\n')


def path(pts):
    return 'M' + ' L'.join(f'{x:.1f},{y:.1f}' for x, y in pts)


# ---------------------------------------------------------------- EQ response

BANDS = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
SLIDERS = [12, 8.56, 4.62, 2.03, 0, 2.16, 2.44, 2.45, 3.84, 3.31]   # during the recordings
FS = 48000.0


def model_db(f, preamp):
    """The helper's EQ (main.swift DSP.load): bells in series, H = 1 + p(g-1)BP."""
    z = np.exp(-2j * np.pi * f / FS)
    h = np.ones_like(f, dtype=complex)
    p = 10 ** (preamp / 20)
    for fc, s in zip(BANDS, SLIDERS):
        g = 10 ** (s / 20)
        k = 1 + p * (g - 1)
        w = 2 * math.pi * fc / FS
        sn, c = math.sin(w), math.cos(w)
        a = sn * math.sinh(math.log(2) / 2 * 1.0 * w / sn)
        b = [1 + a * k, -2 * c, 1 - a * k]
        d = [1 + a, -2 * c, 1 - a]
        h *= (b[0] + b[1] * z + b[2] * z * z) / (d[0] + d[1] * z + d[2] * z * z)
    return 20 * np.log10(np.abs(h))


def measured():
    rows = []
    txt = open(os.path.join(here, 'results', 'preamplaw-output.txt')).read()
    for line in txt.split('  freq')[1].splitlines()[1:]:
        v = line.split()
        if len(v) == 7 and re.fullmatch(r'\d+', v[0]):
            rows.append((float(v[0]), float(v[1]), float(v[3]), float(v[5])))
    return rows


def eq_chart(theme):
    t = THEMES[theme]
    x0, x1, y0, y1 = math.log10(20), math.log10(20000), -2, 18
    X = lambda f: L + (math.log10(f) - x0) / (x1 - x0) * (W - L - R)
    Y = lambda db: T + (y1 - db) / (y1 - y0) * (H - T - B)
    o = []
    for db in range(0, 19, 3):
        o.append(f'<line x1="{L}" x2="{W-R}" y1="{Y(db):.1f}" y2="{Y(db):.1f}" stroke="{t["grid"]}" '
                 f'stroke-width="{1.2 if db == 0 else 0.6}"/>')
        o.append(f'<text x="{L-8}" y="{Y(db)+4:.1f}" text-anchor="end" fill="{t["muted"]}">{"+" if db else ""}{db} dB</text>')
    for f, lab in [(20, '20'), (50, '50'), (100, '100'), (200, '200'), (500, '500'), (1000, '1k'),
                   (2000, '2k'), (5000, '5k'), (10000, '10k'), (20000, '20k')]:
        o.append(f'<line x1="{X(f):.1f}" x2="{X(f):.1f}" y1="{T}" y2="{H-B}" stroke="{t["grid"]}" stroke-width="0.6"/>')
        o.append(f'<text x="{X(f):.1f}" y="{H-B+18}" text-anchor="middle" fill="{t["muted"]}">{lab}</text>')
    o.append(f'<text x="{(L+W-R)/2}" y="{H-10}" text-anchor="middle" fill="{t["muted"]}">Hz</text>')

    f = np.logspace(x0, x1, 400)
    rows = measured()
    for i, (pre, col) in enumerate([(0, t['c0']), (-6, t['c1']), (-12, t['c2'])]):
        o.append(f'<path d="{path([(X(a), Y(b)) for a, b in zip(f, model_db(f, pre))])}" fill="none" '
                 f'stroke="{col}" stroke-width="2.2" stroke-linejoin="round"/>')
        for r in rows:
            o.append(f'<circle cx="{X(r[0]):.1f}" cy="{Y(r[1+i]):.1f}" r="3" fill="{t["bg"]}" stroke="{col}" stroke-width="1.6"/>')
        lx = W - R - 340 + i * 115
        o.append(f'<line x1="{lx}" x2="{lx+22}" y1="26" y2="26" stroke="{col}" stroke-width="2.2"/>')
        o.append(f'<text x="{lx+28}" y="30" fill="{t["fg"]}">preamp {pre if pre else "0"} dB</text>')
    lx = W - R - 340
    o.append(f'<circle cx="{lx+11}" cy="44" r="3" fill="{t["bg"]}" stroke="{t["muted"]}" stroke-width="1.6"/>')
    o.append(f'<text x="{lx+28}" y="48" fill="{t["muted"]}">Music, measured</text>')
    o.append(f'<line x1="{lx+140}" x2="{lx+162}" y1="44" y2="44" stroke="{t["muted"]}" stroke-width="2.2"/>')
    o.append(f'<text x="{lx+168}" y="48" fill="{t["muted"]}">AtmosEQ</text>')
    return svg(theme, '\n'.join(o) + '\n', "Music's EQ vs AtmosEQ")


# ---------------------------------------------------------------- tone pitch

def pitch(prefix):
    raw = open(prefix + '.wav', 'rb').read()
    nch = int.from_bytes(raw[22:24], 'little')
    x = np.frombuffer(raw[44:], dtype=np.float32)[0::nch]
    a, b = x[:-1], x[1:]
    i = np.where((a < 0) & (b >= 0) & ((b - a) > 1e-4))[0]
    zc = i + (-a[i]) / (b[i] - a[i])
    ts, fr, k = [], [], 0
    while k < len(zc) - 1:   # frequency per 100 ms window
        j = int(np.searchsorted(zc, zc[k] + 4800)) - 1
        if j > k:
            ts.append(zc[k] / FS); fr.append((j - k) / ((zc[j] - zc[k]) / FS))
        k = j + 1
    return ts, fr


def pitch_chart(theme, mix, dev):
    t = THEMES[theme]
    x1, y0, y1 = 45, 975, 1025
    X = lambda s: L + s / x1 * (W - L - R)
    Y = lambda hz: T + (y1 - min(max(hz, y0), y1)) / (y1 - y0) * (H - T - B)
    o = []
    for hz in range(980, 1021, 10):
        o.append(f'<line x1="{L}" x2="{W-R}" y1="{Y(hz):.1f}" y2="{Y(hz):.1f}" stroke="{t["grid"]}" '
                 f'stroke-width="{1.2 if hz == 1000 else 0.6}"/>')
        o.append(f'<text x="{L-8}" y="{Y(hz)+4:.1f}" text-anchor="end" fill="{t["muted"]}">{hz} Hz</text>')
    for s in range(0, 46, 5):
        o.append(f'<text x="{X(s):.1f}" y="{H-B+18}" text-anchor="middle" fill="{t["muted"]}">{s} s</text>')
    for (ts, fr), col in [(mix, t['bad']), (dev, t['good'])]:
        pts = [(X(a), Y(b)) for a, b in zip(ts, fr) if a <= x1]
        o.append(f'<path d="{path(pts)}" fill="none" stroke="{col}" stroke-width="1.8" stroke-linejoin="round"/>')
    for i, (lab, col) in enumerate([('stereo-mixdown tap', t['bad']), ('device-stream tap (AtmosEQ)', t['good'])]):
        lx = W - R - 400 + i * 170
        o.append(f'<line x1="{lx}" x2="{lx+22}" y1="26" y2="26" stroke="{col}" stroke-width="2.2"/>')
        o.append(f'<text x="{lx+28}" y="30" fill="{t["fg"]}">{lab}</text>')
    return svg(theme, '\n'.join(o) + '\n', 'A 1 kHz tone through the tap')


for theme in THEMES:
    open(os.path.join(out, f'eq-response-{theme}.svg'), 'w').write(eq_chart(theme))
    if probe:
        mix, dev = pitch(os.path.join(probe, 'drift_on')), pitch(os.path.join(probe, 'dev_off'))
        open(os.path.join(out, f'tone-pitch-{theme}.svg'), 'w').write(pitch_chart(theme, mix, dev))
print('wrote', sorted(os.listdir(out)))
