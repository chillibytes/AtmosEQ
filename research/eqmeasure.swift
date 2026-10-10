// Measures |H(f)| = EQ-on / EQ-off from two recordings of the same passage, then fits
// band Q and end-band filter types to Music's preset gains.
// Usage: eqmeasure ON.wav OFF.wav PREAMP G1 ... G10
import Accelerate
import Foundation

var a = CommandLine.arguments
let joint = a.count > 1 && a[1] == "--joint"
func load(_ p: String) -> [Float] {
    let d = try! Data(contentsOf: URL(fileURLWithPath: p))
    let f = d.subdata(in: 44..<d.count).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    return stride(from: 0, to: f.count - 1, by: 2).map { (f[$0] + f[$0 + 1]) * 0.5 }
}
let pre = joint ? 0.0 : Double(a[3])!
let gains = joint ? a[2].split(separator: ",").map { Double($0)! } : a[4...13].map { Double($0)! }
let pairs: [(String, String)] = joint ? stride(from: 3, to: a.count - 1, by: 2).map { (a[$0], a[$0 + 1]) } : [(a[1], a[2])]
let fs = 48000.0

// FFT helpers
func fftMag2(_ x: [Float], _ n: Int, _ setup: FFTSetup, _ log2n: vDSP_Length) -> [Float] {
    var re = [Float](repeating: 0, count: n / 2), im = [Float](repeating: 0, count: n / 2)
    var out = [Float](repeating: 0, count: n / 2)
    re.withUnsafeMutableBufferPointer { rp in im.withUnsafeMutableBufferPointer { ip in
        var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
        x.withUnsafeBufferPointer { xp in xp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ctoz($0, 2, &sc, 1, vDSP_Length(n / 2)) } }
        vDSP_fft_zrip(setup, &sc, 1, log2n, FFTDirection(FFT_FORWARD))
        vDSP_zvmags(&sc, 1, &out, 1, vDSP_Length(n / 2))
    } }
    return out
}

func measure(_ on: [Float], _ off: [Float]) -> [(f: Double, db: Double)] {
// 1) Align by cross-correlating energy envelopes (5 ms hops), then refine on samples.
func env(_ x: [Float]) -> [Float] { stride(from: 0, to: x.count - 240, by: 240).map { i in var s: Float = 0; vDSP_svesq(Array(x[i..<i + 240]), 1, &s, 240); return sqrt(s) } }
let ea = env(on), eb = env(off)
var bestLag = 0; var best: Float = -1
let maxLag = 600  // ±3 s
for lag in -maxLag...maxLag {
    var s: Float = 0; var cnt = 0
    for i in stride(from: 0, to: min(ea.count, eb.count), by: 1) { let j = i + lag; if j >= 0 && j < eb.count { s += ea[i] * eb[j]; cnt += 1 } }
    if cnt > 1000 { let v = s / Float(cnt); if v > best { best = v; bestLag = lag } }
}
var lagS = bestLag * 240
var bestC: Float = -.infinity; var fine = 0
for d in -480...480 {
    var s: Float = 0
    for i in stride(from: 96000, to: 96000 + 48000, by: 3) { let j = i + lagS + d; if j >= 0 && j < off.count && i < on.count { s += on[i] * off[j] } }
    if s > bestC { bestC = s; fine = d }
}
lagS += fine
print("alignment: off-recording lags on-recording by \(lagS) samples (\(String(format: "%.1f", Double(lagS) / 48)) ms)")

// 2) Welch spectra on the overlapping, aligned region.
let n = 1 << (Int(ProcessInfo.processInfo.environment["LOG2N"] ?? "13") ?? 13), log2n = vDSP_Length(Int(ProcessInfo.processInfo.environment["LOG2N"] ?? "13") ?? 13)
let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
var win = [Float](repeating: 0, count: n); vDSP_hann_window(&win, vDSP_Length(n), Int32(vDSP_HANN_NORM))
var pa = [Double](repeating: 0, count: n / 2), pb = pa
let start = max(0, -lagS), end = min(on.count, off.count - lagS)
var frames = 0
for i in stride(from: start, to: end - n, by: n / 2) {
    var xa = [Float](repeating: 0, count: n), xb = xa
    vDSP_vmul(Array(on[i..<i + n]), 1, win, 1, &xa, 1, vDSP_Length(n))
    vDSP_vmul(Array(off[(i + lagS)..<(i + lagS + n)]), 1, win, 1, &xb, 1, vDSP_Length(n))
    let ma = fftMag2(xa, n, setup, log2n), mb = fftMag2(xb, n, setup, log2n)
    for k in 0..<n / 2 { pa[k] += Double(ma[k]); pb[k] += Double(mb[k]) }
    frames += 1
}
print("averaged \(frames) frames (\(String(format: "%.1f", Double(end - start) / fs)) s)")

// 3) Measured response on a 1/12-octave grid (only where the reference has energy).
var grid: [(f: Double, db: Double)] = []
var f = 20.0
let floorP = (pb.max() ?? 1) * 1e-9
while f < 20000 {
    let lo = Int(f / pow(2, 1 / 24) / fs * Double(n)), hi = max(lo + 1, Int(f * pow(2, 1 / 24) / fs * Double(n)))
    var sa = 0.0, sb = 0.0
    for k in lo..<min(hi, n / 2) { sa += pa[k]; sb += pb[k] }
    if sb > floorP * Double(hi - lo) { grid.append((f, 10 * log10(sa / sb))) }
    f *= pow(2, 1 / 12)
}
return grid
}
let bands: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
var grids: [[(f: Double, db: Double)]] = []
for (x, y) in pairs { print("== \(x) vs \(y)"); grids.append(measure(load(x), load(y))) }
let grid = grids[0]
func measuredAt(_ fc: Double) -> Double? { grid.min { abs(log2($0.f / fc)) < abs(log2($1.f / fc)) }.flatMap { abs(log2($0.f / fc)) < 0.1 ? $0.db : nil } }
print("\nband    slider   measured")
for (i, fc) in bands.enumerated() {
    print(String(format: "%6.0f  %+6.1f   %@", fc, gains[i], measuredAt(fc).map { String(format: "%+6.2f dB", $0) } ?? "  n/a"))
}

// 4) Fit: preamp + 10 biquads; global Q; peaking or shelving end bands; gain scale.
func biquadDB(_ type: Int, _ fc: Double, _ g: Double, _ q: Double, _ fx: Double) -> Double {
    if abs(g) < 1e-6 { return 0 }
    let A = pow(10, g / 40), w0 = 2 * Double.pi * fc / fs, cw = cos(w0), sw = sin(w0), al = sw / (2 * q)
    var b0, b1, b2, a0, a1, a2: Double
    switch type {
    case 1: // low shelf
        let s = 2 * sqrt(A) * al
        b0 = A * ((A + 1) - (A - 1) * cw + s); b1 = 2 * A * ((A - 1) - (A + 1) * cw); b2 = A * ((A + 1) - (A - 1) * cw - s)
        a0 = (A + 1) + (A - 1) * cw + s; a1 = -2 * ((A - 1) + (A + 1) * cw); a2 = (A + 1) + (A - 1) * cw - s
    case 2: // high shelf
        let s = 2 * sqrt(A) * al
        b0 = A * ((A + 1) + (A - 1) * cw + s); b1 = -2 * A * ((A - 1) + (A + 1) * cw); b2 = A * ((A + 1) + (A - 1) * cw - s)
        a0 = (A + 1) - (A - 1) * cw + s; a1 = 2 * ((A - 1) - (A + 1) * cw); a2 = (A + 1) - (A - 1) * cw - s
    default: // peaking
        b0 = 1 + al * A; b1 = -2 * cw; b2 = 1 - al * A; a0 = 1 + al / A; a1 = -2 * cw; a2 = 1 - al / A
    }
    let w = 2 * Double.pi * fx / fs
    func mag(_ c0: Double, _ c1: Double, _ c2: Double) -> Double {
        let re = c0 + c1 * cos(w) + c2 * cos(2 * w), im = -(c1 * sin(w) + c2 * sin(2 * w)); return re * re + im * im
    }
    return 10 * log10(mag(b0, b1, b2) / mag(a0, a1, a2))
}
func model(_ fx: Double, q: Double, lo: Int, hi: Int, scale: Double, preOff: Double, sq: Double = 0.707) -> Double {
    var db = pre + preOff
    for (i, fc) in bands.enumerated() {
        let t = i == 0 ? lo : (i == 9 ? hi : 0)
        db += biquadDB(t, min(fc, fs * 0.45), gains[i] * scale, t == 0 ? q : sq, fx)
    }
    return db
}
let fitPtsAll = grids.map { g in g.filter { $0.f >= 25 && $0.f <= 17000 } }
let fitPts = grid.filter { $0.f >= 25 && $0.f <= 17000 }
var bestFit = (err: Double.infinity, q: 0.0, lo: 0, hi: 0, scale: 1.0, off: 0.0)
for lo in [0, 1] { for hi in [0, 2] {
    for qi in stride(from: 0.4, through: 4.0, by: 0.02) { for sc in stride(from: 0.8, through: 1.6, by: 0.02) {
        // best constant offset (level) in closed form
        let diffs = fitPts.map { $0.db - model($0.f, q: qi, lo: lo, hi: hi, scale: sc, preOff: 0) }
        let off = diffs.reduce(0, +) / Double(diffs.count)
        let err = sqrt(diffs.map { ($0 - off) * ($0 - off) }.reduce(0, +) / Double(diffs.count))
        if err < bestFit.err { bestFit = (err, qi, lo, hi, sc, off) }
    } }
} }
let names = [0: "peaking", 1: "low shelf", 2: "high shelf"]
print(String(format: "\nbest fit: Q %.2f, 32 Hz %@, 16 kHz %@, gain scale %.2f×, level offset %+.2f dB, rms error %.2f dB",
             bestFit.q, names[bestFit.lo]!, names[bestFit.hi]!, bestFit.scale, bestFit.off, bestFit.err))
let mine = fitPts.map { $0.db - model($0.f, q: 1.41, lo: 0, hi: 0, scale: 1, preOff: 0) }
let mOff = mine.reduce(0, +) / Double(mine.count)
print(String(format: "current atmoseq model (Q 1.41 peaking, 1.0×): rms error %.2f dB (level offset %+.2f dB)",
             sqrt(mine.map { ($0 - mOff) * ($0 - mOff) }.reduce(0, +) / Double(mine.count)), mOff))
print("\nfreq     measured   bestfit   atmoseq-now")
for p in fitPts where Int(round(log2(p.f / 20) * 12)) % 6 == 0 {
    print(String(format: "%7.0f  %+7.2f   %+7.2f   %+7.2f", p.f, p.db,
                 model(p.f, q: bestFit.q, lo: bestFit.lo, hi: bestFit.hi, scale: bestFit.scale, preOff: bestFit.off),
                 model(p.f, q: 1.41, lo: 0, hi: 0, scale: 1, preOff: mOff)))
}

if joint {
    var best = (err: Double.infinity, q: 0.0, sc: 1.0, off: 0.0, lo: 0, hi: 0, sq: 0.707)
    let wide = ProcessInfo.processInfo.environment["WIDE"] != nil
    for lo in (wide ? [0] : [0, 1]) { for hi in (wide ? [0] : [0, 2]) { for sq in (lo == 0 && hi == 0 ? [0.707] : Array(stride(from: 0.3, through: 1.5, by: 0.05))) {
    for qi in stride(from: wide ? 0.5 : 0.7, through: wide ? 2.0 : 1.3, by: 0.02) { for sc in stride(from: wide ? 0.0 : 0.85, through: wide ? 2.0 : 1.05, by: 0.01) {
        var diffs: [Double] = []
        for pts in fitPtsAll { for p in pts { diffs.append(p.db - model(p.f, q: qi, lo: lo, hi: hi, scale: sc, preOff: 0, sq: sq)) } }
        let off = diffs.reduce(0, +) / Double(diffs.count)
        let err = sqrt(diffs.map { ($0 - off) * ($0 - off) }.reduce(0, +) / Double(diffs.count))
        if err < best.err { best = (err, qi, sc, off, lo, hi, sq) }
    } } } } }
    let nm = [0: "peaking", 1: "low shelf", 2: "high shelf"]
    print(String(format: "\nJOINT FIT (preamp ignored): Q %.2f, 32 Hz %@, 16 kHz %@, shelf Q %.2f, gain scale %.3f×, fixed level %+.2f dB, rms %.2f dB", best.q, nm[best.lo]!, nm[best.hi]!, best.sq, best.sc, best.off, best.err))
    for (k, pts) in fitPtsAll.enumerated() {
        let d = pts.map { $0.db - model($0.f, q: best.q, lo: best.lo, hi: best.hi, scale: best.sc, preOff: best.off, sq: best.sq) }
        let worst = d.map { abs($0) }.max() ?? 0
        print(String(format: "  pair %d: rms %.2f dB, worst %.2f dB", k + 1, sqrt(d.map { $0 * $0 }.reduce(0, +) / Double(d.count)), worst))
        for (i, p) in pts.enumerated() where abs(d[i]) > 1.0 { print(String(format: "     %7.0f Hz  measured %+6.2f  model %+6.2f", p.f, p.db, p.db - d[i])) }
    }
}
