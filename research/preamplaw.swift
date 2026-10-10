// How does Music's preamp enter its EQ, and what are the band filters?
// Usage: preamplaw "g1,..,g10" P on.wav off.wav [P on.wav off.wav ...]
//   g1..g10  band slider values in dB; P = preamp (dB) that was in effect when the
//   EQ-on stream STARTED; on/off = the same passage recorded with Music's EQ on and off.
// Steps, in the order the investigation ran them:
//   1. free fit: one EQ-strength factor p per recording (parallel bank vs peaking cascade)
//   2. fixed laws on an RBJ peaking cascade (whole-EQ blend, per-band blend, dB scaling)
//   3. constant-pole bells, H = 1 + p(g − 1)BP, in series and in parallel
//   4. high-frequency detail: design sample rate and bandwidth-compensated alpha
// Result: bells in series, one octave wide (RBJ bandwidth form), p = 10^(P/20).
import Accelerate
import Foundation

let a = CommandLine.arguments
let G = a[1].split(separator: ",").map { Double($0)! }
let cases: [(P: Double, on: String, off: String)] = stride(from: 2, to: a.count - 2, by: 3).map { (Double(a[$0])!, a[$0 + 1], a[$0 + 2]) }
let fs = 48000.0
let bands: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

func load(_ p: String) -> [Float] {
    let d = try! Data(contentsOf: URL(fileURLWithPath: p))
    let f = d.subdata(in: 44..<d.count).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    return stride(from: 0, to: f.count - 1, by: 2).map { (f[$0] + f[$0 + 1]) * 0.5 }
}
let log2n = vDSP_Length(15), n = 1 << 15
let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
func mag2(_ x: [Float]) -> [Float] {
    var re = [Float](repeating: 0, count: n / 2), im = re, out = re
    re.withUnsafeMutableBufferPointer { rp in im.withUnsafeMutableBufferPointer { ip in
        var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
        x.withUnsafeBufferPointer { xp in xp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ctoz($0, 2, &sc, 1, vDSP_Length(n / 2)) } }
        vDSP_fft_zrip(setup, &sc, 1, log2n, FFTDirection(FFT_FORWARD)); vDSP_zvmags(&sc, 1, &out, 1, vDSP_Length(n / 2))
    } }
    return out
}
func measure(_ on: [Float], _ off: [Float]) -> [(f: Double, db: Double)] {
    func env(_ x: [Float]) -> [Float] { stride(from: 0, to: x.count - 240, by: 240).map { i in var s: Float = 0; vDSP_svesq(Array(x[i..<i + 240]), 1, &s, 240); return sqrt(s) } }
    let ea = env(on), eb = env(off)
    var bestLag = 0; var best: Float = -1
    for lag in -600...600 {
        var s: Float = 0; var cnt = 0
        for i in 0..<min(ea.count, eb.count) { let j = i + lag; if j >= 0 && j < eb.count { s += ea[i] * eb[j]; cnt += 1 } }
        if cnt > 1000 { let v = s / Float(cnt); if v > best { best = v; bestLag = lag } }
    }
    var lagS = bestLag * 240; var bestC: Float = -.infinity; var fine = 0
    for d in -480...480 {
        var s: Float = 0
        for i in stride(from: 96000, to: 96000 + 48000, by: 3) { let j = i + lagS + d; if j >= 0 && j < off.count && i < on.count { s += on[i] * off[j] } }
        if s > bestC { bestC = s; fine = d }
    }
    lagS += fine
    var win = [Float](repeating: 0, count: n); vDSP_hann_window(&win, vDSP_Length(n), Int32(vDSP_HANN_NORM))
    var pa = [Double](repeating: 0, count: n / 2), pb = pa
    let start = max(0, -lagS), end = min(on.count, off.count - lagS)
    for i in stride(from: start, to: end - n, by: n / 2) {
        var xa = [Float](repeating: 0, count: n), xb = xa
        vDSP_vmul(Array(on[i..<i + n]), 1, win, 1, &xa, 1, vDSP_Length(n))
        vDSP_vmul(Array(off[(i + lagS)..<(i + lagS + n)]), 1, win, 1, &xb, 1, vDSP_Length(n))
        let ma = mag2(xa), mb = mag2(xb)
        for k in 0..<n / 2 { pa[k] += Double(ma[k]); pb[k] += Double(mb[k]) }
    }
    var grid: [(f: Double, db: Double)] = []
    var f = 25.0
    let floorP = (pb.max() ?? 1) * 1e-9
    while f < 17000 {
        let lo = Int(f / pow(2, 1 / 24) / fs * Double(n)), hi = max(lo + 1, Int(f * pow(2, 1 / 24) / fs * Double(n)))
        var sa = 0.0, sb = 0.0
        for k in lo..<min(hi, n / 2) { sa += pa[k]; sb += pb[k] }
        if sb > floorP * Double(hi - lo) { grid.append((f, 10 * log10(sa / sb))) }
        f *= pow(2, 1 / 12)
    }
    return grid
}

struct C { var re: Double, im: Double
    static func + (l: C, r: C) -> C { C(re: l.re + r.re, im: l.im + r.im) }
    static func * (l: C, r: C) -> C { C(re: l.re * r.re - l.im * r.im, im: l.re * r.im + l.im * r.re) }
    static func / (l: C, r: C) -> C { let d = r.re * r.re + r.im * r.im; return C(re: (l.re * r.re + l.im * r.im) / d, im: (l.im * r.re - l.re * r.im) / d) }
}
func biq(_ b: (Double, Double, Double), _ aa: (Double, Double, Double), _ f: Double) -> C {
    let w = 2 * Double.pi * f / fs
    let z1 = C(re: cos(w), im: -sin(w)), z2 = C(re: cos(2 * w), im: -sin(2 * w))
    let num = C(re: b.0, im: 0) + C(re: b.1, im: 0) * z1 + C(re: b.2, im: 0) * z2
    let den = C(re: aa.0, im: 0) + C(re: aa.1, im: 0) * z1 + C(re: aa.2, im: 0) * z2
    return num / den
}
func bandpass(_ fc: Double, _ q: Double, _ f: Double) -> C {
    let w0 = 2 * Double.pi * fc / fs, al = sin(w0) / (2 * q)
    return biq((al, 0, -al), (1 + al, -2 * cos(w0), 1 - al), f)
}
func peak(_ fc: Double, _ g: Double, _ q: Double, _ f: Double) -> C {
    let A = pow(10, g / 40), w0 = 2 * Double.pi * fc / fs, al = sin(w0) / (2 * q)
    return biq((1 + al * A, -2 * cos(w0), 1 - al * A), (1 + al / A, -2 * cos(w0), 1 - al / A), f)
}

let grids = cases.map { c -> [(f: Double, db: Double)] in measure(load(c.on), load(c.off)) }
print("measured at band centers:")
for (c, g) in zip(cases, grids) {
    let row = bands.map { fc in g.min { abs(log2($0.f / fc)) < abs(log2($1.f / fc)) }!.db }
    print(String(format: "  preamp %+6.2f: ", c.P) + row.map { String(format: "%+5.1f", $0) }.joined(separator: " "))
}


print("\n== 1. free EQ-strength factor per recording")
// S[case][point] = complex "EQ difference" at p = 1 for the model; fit p per case.
func fit(_ name: String, _ shape: (Double, Double, Double) -> C, _ p1: ClosedRange<Double>, _ p2: ClosedRange<Double>, _ p2name: String) {
    var best = (err: Double.infinity, q: 0.0, x: 0.0, ps: [Double](), errs: [Double]())
    for q in stride(from: p1.lowerBound, through: p1.upperBound, by: 0.02) { for x in stride(from: p2.lowerBound, through: p2.upperBound, by: 0.02) {
        var tot = 0.0, ps: [Double] = [], errs: [Double] = []
        for (ci, g) in grids.enumerated() {
            let S = g.map { shape(q, x, $0.f) }
            func err(_ p: Double) -> Double {
                var e = 0.0
                for (k, pt) in g.enumerated() {
                    let re = 1 + p * S[k].re, im = p * S[k].im
                    let d = 10 * log10(re * re + im * im) - pt.db
                    e += d * d
                }
                return e / Double(g.count)
            }
            var bp = 1.0, be = err(1.0)
            if cases[ci].P != 0 {
                be = .infinity
                for p in stride(from: 0.0, through: 2.5, by: 0.01) { let e = err(p); if e < be { be = e; bp = p } }
                for p in stride(from: max(0, bp - 0.01), through: bp + 0.01, by: 0.001) { let e = err(p); if e < be { be = e; bp = p } }
            }
            tot += be; ps.append(bp); errs.append(sqrt(be))
        }
        if tot < best.err { best = (tot, q, x, ps, errs) }
    } }
    print(String(format: "\n%@: Q %.2f, %@ %.2f, overall rms %.2f dB", name, best.q, p2name, best.x, sqrt(best.err / Double(grids.count))))
    for (i, c) in cases.enumerated() {
        print(String(format: "  preamp %+6.2f dB: fitted p %.3f  (10^(P/20) = %.3f)  rms %.2f dB", c.P, best.ps[i], pow(10, c.P / 20), best.errs[i]))
    }
}
fit("MODEL A  parallel band-pass bank, H = 1 + p·c·Σ(g−1)·BP", { q, c, f in
    var s = C(re: 0, im: 0)
    for (i, fc) in bands.enumerated() where abs(G[i]) > 1e-6 { let k = c * (pow(10, G[i] / 20) - 1); let b = bandpass(fc, q, f); s = s + C(re: k * b.re, im: k * b.im) }
    return s
}, 0.4...2.6, 0.6...1.6, "c")
fit("MODEL B  blended peaking cascade, H = 1 + p·(ΠPeak − 1)", { q, sc, f in
    var h = C(re: 1, im: 0)
    for (i, fc) in bands.enumerated() where abs(G[i]) > 1e-6 { h = h * peak(fc, G[i] * sc, q, f) }
    return C(re: h.re - 1, im: h.im)
}, 0.4...2.0, 0.6...1.6, "gain scale")

print("\n== 2. fixed laws, RBJ peaking cascade")
// Fixed-law candidates: no per-recording freedom. p = 10^(P/k).
func rmsAll(_ model: (Double, Double) -> Double) -> (Double, [Double]) {   // model(P, f) -> dB
    var tot = 0.0, cnt = 0, per: [Double] = []
    for (c, g) in zip(cases, grids) {
        var e = 0.0
        for pt in g { let d = model(c.P, pt.f) - pt.db; e += d * d }
        per.append(sqrt(e / Double(g.count))); tot += e; cnt += g.count
    }
    return (sqrt(tot / Double(cnt)), per)
}
func dB(_ c: C) -> Double { 10 * log10(c.re * c.re + c.im * c.im) }
func cascade(_ gains: [Double], _ q: Double, _ f: Double) -> C {
    var h = C(re: 1, im: 0)
    for (i, fc) in bands.enumerated() where abs(gains[i]) > 1e-6 { h = h * peak(fc, gains[i], q, f) }
    return h
}
struct Res { var err = Double.infinity; var q = 0.0, s = 0.0, k = 0.0; var per: [Double] = [] }
func search(_ name: String, ks: [Double], _ model: @escaping (Double, Double, Double, Double, Double) -> Double) {
    var best = Res()
    for k in ks { for q in stride(from: 0.6, through: 1.6, by: 0.02) { for sc in stride(from: 0.8, through: 1.3, by: 0.01) {
        let (e, per) = rmsAll { P, f in model(q, sc, k, P, f) }
        if e < best.err { best = Res(err: e, q: q, s: sc, k: k, per: per) }
    } } }
    print(String(format: "%@\n   Q %.2f, gain scale %.2f, p = 10^(P/%.1f): rms %.2f dB   per recording: %@", name, best.q, best.s, best.k, best.err,
                 best.per.map { String(format: "%.2f", $0) }.joined(separator: " ")))
}
let kFree = Array(stride(from: 12.0, through: 26.0, by: 0.5))
// B: whole-EQ blend
let B: (Double, Double, Double, Double, Double) -> Double = { q, sc, k, P, f in
    let h0 = cascade(G.map { $0 * sc }, q, f), p = pow(10, P / k)
    return dB(C(re: 1 + p * (h0.re - 1), im: p * h0.im))
}
search("B20  whole-EQ blend  H = 1 + p(H0 − 1), k = 20", ks: [20], B)
search("Bk   whole-EQ blend, k free", ks: kFree, B)
// C: each band's linear gain blended toward 1, then a normal cascade
let Cm: (Double, Double, Double, Double, Double) -> Double = { q, sc, k, P, f in
    let p = pow(10, P / k)
    return dB(cascade(G.map { 20 * log10(max(1e-6, 1 + p * (pow(10, $0 * sc / 20) - 1))) }, q, f))
}
search("C20  per-band blend  g' = 1 + p(g − 1), k = 20", ks: [20], Cm)
search("Ck   per-band blend, k free", ks: kFree, Cm)
// D: band dB gains scaled linearly with preamp: G' = G·(1 + P/k)
let D: (Double, Double, Double, Double, Double) -> Double = { q, sc, k, P, f in
    dB(cascade(G.map { $0 * sc * max(0, 1 + P / k) }, q, f))
}
search("Dk   dB scaling  G' = G(1 + P/k), k free", ks: kFree, D)
// E: dB gains scaled by p^x
let E: (Double, Double, Double, Double, Double) -> Double = { q, sc, k, P, f in
    dB(cascade(G.map { $0 * sc * pow(10, P / k) }, q, f))
}
search("Ek   dB scaling  G' = G·10^(P/k), k free", ks: Array(stride(from: 14.0, through: 60.0, by: 1.0)), E)

print("\n== 3. constant-pole bells")
// Constant-pole bell: H = 1 + (g − 1)·BP(f; Q)  (boost); reciprocal for cuts.
func bell(_ fc: Double, _ g: Double, _ q: Double, _ f: Double) -> C {
    let b = bandpass(fc, q, f)
    if g >= 1 { return C(re: 1 + (g - 1) * b.re, im: (g - 1) * b.im) }
    let k = 1 / g - 1
    return C(re: 1, im: 0) / C(re: 1 + k * b.re, im: k * b.im)
}
func search2(_ name: String, ks: [Double], scs: [Double], _ model: @escaping (Double, Double, Double, Double, Double) -> Double) {
    var best = Res()
    for k in ks { for q in stride(from: 0.5, through: 3.0, by: 0.02) { for sc in scs {
        let (e, per) = rmsAll { P, f in model(q, sc, k, P, f) }
        if e < best.err { best = Res(err: e, q: q, s: sc, k: k, per: per) }
    } } }
    print(String(format: "%@\n   Q %.2f, gain scale %.2f, p = 10^(P/%.1f): rms %.2f dB   per recording: %@", name, best.q, best.s, best.k, best.err,
                 best.per.map { String(format: "%.2f", $0) }.joined(separator: " ")))
}
let scFree = Array(stride(from: 0.8, through: 1.3, by: 0.01))
// F: cascade of constant-pole bells, preamp scales each band's (g − 1)
let F: (Double, Double, Double, Double, Double) -> Double = { q, sc, k, P, f in
    let p = pow(10, P / k)
    var h = C(re: 1, im: 0)
    for (i, fc) in bands.enumerated() where abs(G[i]) > 1e-6 { h = h * bell(fc, 1 + p * (pow(10, G[i] * sc / 20) - 1), q, f) }
    return dB(h)
}
search2("F   bells in series, g' = 1 + p(g − 1): everything nominal (scale 1.00, k 20)", ks: [20], scs: [1.0], F)
search2("F   same, gain scale free, k = 20", ks: [20], scs: scFree, F)
search2("F   same, gain scale and k free", ks: kFree, scs: scFree, F)
// A': parallel bank revisited with p fixed
let A2: (Double, Double, Double, Double, Double) -> Double = { q, sc, k, P, f in
    let p = pow(10, P / k)
    var s = C(re: 1, im: 0)
    for (i, fc) in bands.enumerated() where abs(G[i]) > 1e-6 { let kk = p * (pow(10, G[i] * sc / 20) - 1); let b = bandpass(fc, q, f); s = s + C(re: kk * b.re, im: kk * b.im) }
    return dB(s)
}
search2("A   bells in parallel, H = 1 + pΣ(g − 1)BP: nominal (scale 1.00, k 20)", ks: [20], scs: [1.0], A2)
search2("A   same, gain scale and k free", ks: kFree, scs: scFree, A2)

for q in [1.30, 1.38, 1.414] {
    let (e, per) = rmsAll { P, f in F(q, 1.0, 20, P, f) }
    print(String(format: "Q %.3f nominal: rms %.2f dB  per recording %@", q, e, per.map { String(format: "%.2f", $0) }.joined(separator: " ")))
}
print("\n  freq    P=0 meas  model    P=-6 meas model    P=-12 meas model")
for (k, pt) in grids[0].enumerated() where k % 4 == 0 {
    func near(_ g: [(f: Double, db: Double)]) -> Double { g.min { abs(log2($0.f / pt.f)) < abs(log2($1.f / pt.f)) }!.db }
    print(String(format: "%7.0f   %+6.2f  %+6.2f     %+6.2f  %+6.2f     %+6.2f  %+6.2f", pt.f, pt.db, F(1.414, 1, 20, 0, pt.f), near(grids[1]), F(1.414, 1, 20, -6, pt.f), near(grids[2]), F(1.414, 1, 20, -12, pt.f)))
}

print("\n== 4. high-frequency design")
// HF variants: design sample rate (the EQ runs at the track's rate, then gets resampled)
// and bandwidth-compensated alpha (RBJ "BW in octaves" form).
func bell2(_ fc: Double, _ g: Double, _ f: Double, fsd: Double, q: Double, bw: Double?) -> C {
    let w0 = 2 * Double.pi * fc / fsd
    let al = bw.map { sin(w0) * sinh(log(2.0) / 2 * $0 * w0 / sin(w0)) } ?? sin(w0) / (2 * q)
    let w = 2 * Double.pi * f / fsd
    let z1 = C(re: cos(w), im: -sin(w)), z2 = C(re: cos(2 * w), im: -sin(2 * w))
    let gg = max(g, 1e-6)
    func resp(_ k: Double) -> C {
        let num = C(re: 1 + al * k, im: 0) + C(re: -2 * cos(w0), im: 0) * z1 + C(re: 1 - al * k, im: 0) * z2
        let den = C(re: 1 + al, im: 0) + C(re: -2 * cos(w0), im: 0) * z1 + C(re: 1 - al, im: 0) * z2
        return num / den
    }
    return gg >= 1 ? resp(gg) : C(re: 1, im: 0) / resp(1 / gg)
}
func modelV(_ P: Double, _ f: Double, fsd: Double, q: Double, bw: Double?) -> Double {
    let p = pow(10, P / 20)
    var h = C(re: 1, im: 0)
    for (i, fc) in bands.enumerated() where abs(G[i]) > 1e-6 && fc < fsd * 0.49 { h = h * bell2(fc, 1 + p * (pow(10, G[i] / 20) - 1), f, fsd: fsd, q: q, bw: bw) }
    return dB(h)
}
for fsd in [44100.0, 48000.0, 96000.0] {
    var bq = (e: Double.infinity, q: 0.0, per: [Double]())
    for q in stride(from: 1.0, through: 1.8, by: 0.01) { let (e, per) = rmsAll { P, f in modelV(P, f, fsd: fsd, q: q, bw: nil) }; if e < bq.e { bq = (e, q, per) } }
    print(String(format: "constant-Q, designed at %.0f Hz: best Q %.2f  rms %.2f dB  [%@]", fsd, bq.q, bq.e, bq.per.map { String(format: "%.2f", $0) }.joined(separator: " ")))
    var bb = (e: Double.infinity, bw: 0.0, per: [Double]())
    for bw in stride(from: 0.7, through: 1.4, by: 0.01) { let (e, per) = rmsAll { P, f in modelV(P, f, fsd: fsd, q: 1, bw: bw) }; if e < bb.e { bb = (e, bw, per) } }
    print(String(format: "BW-octaves,  designed at %.0f Hz: best BW %.2f oct  rms %.2f dB  [%@]", fsd, bb.bw, bb.e, bb.per.map { String(format: "%.2f", $0) }.joined(separator: " ")))
}
print("\n  freq    P=0 meas   BW1.0@44.1k  BW1.0@48k   constQ1.41@48k")
for (k, pt) in grids[0].enumerated() where k % 4 == 0 && pt.f > 1500 {
    print(String(format: "%7.0f   %+6.2f     %+6.2f      %+6.2f      %+6.2f", pt.f, pt.db, modelV(0, pt.f, fsd: 44100, q: 1, bw: 1.0), modelV(0, pt.f, fsd: 48000, q: 1, bw: 1.0), modelV(0, pt.f, fsd: 48000, q: 1.414, bw: nil)))
}
