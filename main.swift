// AtmosEQ — re-applies Apple Music's EQ to Dolby Atmos playback on macOS 26+.
//
// Music skips attaching its EQ processing tap to player items created with spatial
// formats allowed, so Atmos plays flat. This taps Music's (already spatialized)
// output on the current output device, mutes the original, and plays it back with
// the EQ applied — but only while Music's own EQ is enabled, the stream that is playing
// is an Atmos stream, and Music's EQ is not attached to that stream (per Music's log).
//
// Clocking: the tap is a device-stream tap (same clock as the output device) with
// drift compensation off. A stereo-mixdown tap runs on its own clock, and every
// AirPods "audio delivery speed" nudge (±10%, every few seconds during spatial
// playback) then gets resampled into an audible pitch wobble.
//
// The IO callback is allocation-free: all DSP state lives in raw buffers.

import ApplicationServices
import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

let kBands: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
let kNB = 10
// Music's EQ, identified from EQ-on vs EQ-off recordings of the same passages at preamp
// 0, -2.76, -6 and -12 dB (matches all of them within 0.26 dB rms):
//   ten bells in series, each  H = 1 + p·(g − 1)·BP(f)   with g = 10^(slider/20),
//   BP a unity-peak band-pass one octave wide (RBJ bandwidth form), p = 10^(preamp/20).
// So the preamp is an EQ-strength control, not a volume: 0 dB = full EQ, -6 ≈ half the
// boost, -12 ≈ a quarter. Music only reads it when a stream starts; here it is live.
// Cuts are assumed to mirror boosts (not measured). Music's EQ output also has a
// ceiling near +12 dBFS, kept here as a hard clamp on the EQ'd signal.
let kBandwidthOct = 1.0
let kCeiling: Double = 4.0
let kMaxCh = 16

// MARK: - DSP (raw memory, safe to touch from the IO thread)

final class DSP: @unchecked Sendable {
    // coef[bank][band][b0 b1 b2 a1 a2]
    let coef = UnsafeMutablePointer<Double>.allocate(capacity: 2 * kNB * 5)
    let preamp = UnsafeMutablePointer<Double>.allocate(capacity: 2)
    // state[ch][band][z1 z2]
    let state = UnsafeMutablePointer<Double>.allocate(capacity: kMaxCh * kNB * 2)
    // per-callback channel pointers/strides (filled on the IO thread, no allocation)
    let inPtr = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: kMaxCh)
    let outPtr = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: kMaxCh)
    let inStride = UnsafeMutablePointer<Int>.allocate(capacity: kMaxCh)
    let outStride = UnsafeMutablePointer<Int>.allocate(capacity: kMaxCh)
    let bank = Atomic<Int>(0)
    let wantWet = Atomic<Bool>(false)
    var wet = 0.0  // IO-thread only
    var sampleRate = 48000.0

    // Diagnostics (IO thread writes, main reads; torn reads are fine for logging)
    let callbacks = Atomic<Int>(0)
    let maxNanos = Atomic<Int>(0)
    let heardAudio = Atomic<Bool>(false)
    var lastFrames = 0, inCh = 0, outCh = 0
    var peakIn: Float = 0, peakOut: Float = 0

    // Test mode: device output is silent, processed + dry audio (first two channels)
    // are recorded instead.
    var testMode = false
    var recCap = 0
    var recWet: UnsafeMutablePointer<Float>?
    var recDry: UnsafeMutablePointer<Float>?
    let recPos = Atomic<Int>(0)

    init() {
        for b in 0..<2 { for i in 0..<kNB { setFlat(b, i) }; preamp[b] = 1 }
        resetState()
    }

    func resetState() { state.initialize(repeating: 0, count: kMaxCh * kNB * 2) }

    func setFlat(_ b: Int, _ i: Int) {
        let p = coef + (b * kNB + i) * 5
        p[0] = 1; p[1] = 0; p[2] = 0; p[3] = 0; p[4] = 0
    }

    // Main thread: fill the inactive bank, then flip.
    func load(preampDB: Double, gains: [Double]) {
        let next = 1 - bank.load(ordering: .acquiring)
        let strength = pow(10, preampDB / 20)
        for i in 0..<kNB {
            let g = pow(10, gains[i] / 20), f = kBands[i]
            // k = this band's boost (or mirrored cut) amount after the preamp scales it
            let k = 1 + strength * ((g >= 1 ? g : 1 / g) - 1)
            if abs(k - 1) < 1e-4 || f >= sampleRate * 0.49 { setFlat(next, i); continue }
            let w = 2 * Double.pi * f / sampleRate, sn = sin(w), c = cos(w)
            let alpha = sn * sinh(log(2.0) / 2 * kBandwidthOct * w / sn)
            // boost: (1 + αk, −2c, 1 − αk) / (1 + α, −2c, 1 − α); cut: the reciprocal
            let nk = g >= 1 ? k : 1, dk = g >= 1 ? 1 : k
            let a0 = 1 + alpha * dk
            let p = coef + (next * kNB + i) * 5
            p[0] = (1 + alpha * nk) / a0; p[1] = -2 * c / a0; p[2] = (1 - alpha * nk) / a0
            p[3] = -2 * c / a0; p[4] = (1 - alpha * dk) / a0
        }
        preamp[next] = 1
        bank.store(next, ordering: .releasing)
    }
}

let dsp = DSP()

// Map an AudioBufferList onto per-channel pointers + strides (interleaved or not).
@inline(__always)
func mapChannels(_ abl: UnsafeMutableAudioBufferListPointer, _ ptrs: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>,
                 _ strides: UnsafeMutablePointer<Int>, frames: inout Int) -> Int {
    var ch = 0
    frames = Int.max
    for b in 0..<abl.count {
        let buf = abl[b], nch = max(1, Int(buf.mNumberChannels))
        guard let base = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
        frames = min(frames, Int(buf.mDataByteSize) / (4 * nch))
        for c in 0..<nch where ch < kMaxCh { ptrs[ch] = base + c; strides[ch] = nch; ch += 1 }
    }
    if frames == Int.max { frames = 0 }
    return ch
}

// IO thread. Input = tap (same format as the device stream), output = device.
func render(_ d: DSP, _ inList: UnsafePointer<AudioBufferList>, _ outList: UnsafeMutablePointer<AudioBufferList>) {
    let t0 = DispatchTime.now().uptimeNanoseconds
    let outs = UnsafeMutableAudioBufferListPointer(outList)
    for k in 0..<outs.count { if let p = outs[k].mData { memset(p, 0, Int(outs[k].mDataByteSize)) } }

    var inFrames = 0, outFrames = 0
    let nIn = mapChannels(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inList)), d.inPtr, d.inStride, frames: &inFrames)
    let nOut = mapChannels(outs, d.outPtr, d.outStride, frames: &outFrames)
    d.lastFrames = outFrames; d.inCh = nIn; d.outCh = nOut
    guard nIn > 0, nOut > 0 else { return }

    let n = min(inFrames, outFrames)
    let nch = min(nIn, nOut)
    let b = d.bank.load(ordering: .acquiring)
    let target = d.wantWet.load(ordering: .relaxed) ? 1.0 : 0.0
    let step = 1.0 / (0.03 * d.sampleRate)  // 30 ms crossfade
    let pre = d.preamp[b]
    let cf = d.coef + b * kNB * 5
    var heard = false
    var pkIn = d.peakIn, pkOut = d.peakOut
    let rec = d.testMode ? d.recPos.load(ordering: .relaxed) : 0
    let recRoom = d.testMode ? max(0, min(n, d.recCap - rec)) : 0

    for f in 0..<n {
        if d.wet != target { d.wet = d.wet < target ? min(target, d.wet + step) : max(target, d.wet - step) }
        let w = d.wet
        for c in 0..<nch {
            let x = d.inPtr[c]![f * d.inStride[c]]
            if x != 0 { heard = true }
            pkIn = max(pkIn, abs(x))
            // Run the EQ even while dry so the filter state is warm for the crossfade.
            var y = Double(x) * pre
            let st = d.state + c * kNB * 2
            for i in 0..<kNB {
                let k = cf + i * 5, s = st + i * 2
                let o = k[0] * y + s[0]
                s[0] = k[1] * y - k[3] * o + s[1]
                s[1] = k[2] * y - k[4] * o
                y = o
            }
            let v: Float = w == 0 ? x : Float(w * max(-kCeiling, min(kCeiling, y)) + (1 - w) * Double(x))
            pkOut = max(pkOut, abs(v))
            if d.testMode {
                if c < 2, f < recRoom, let rw = d.recWet, let rd = d.recDry {
                    let j = (rec + f) * 2 + c
                    rw[j] = v; rd[j] = x
                    if nch == 1 { rw[j + 1] = v; rd[j + 1] = x }
                }
            } else {
                d.outPtr[c]![f * d.outStride[c]] = v
            }
        }
    }
    if d.testMode && recRoom > 0 { d.recPos.store(rec + recRoom, ordering: .relaxed) }

    d.peakIn = pkIn; d.peakOut = pkOut
    if heard { d.heardAudio.store(true, ordering: .relaxed) }
    d.callbacks.add(1, ordering: .relaxed)
    let dt = Int(DispatchTime.now().uptimeNanoseconds - t0)
    if dt > d.maxNanos.load(ordering: .relaxed) { d.maxNanos.store(dt, ordering: .relaxed) }
}

// MARK: - Core Audio helpers

func prop<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ initial: T,
             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr ? value : nil
}

func stringProp(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var s: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &s) == noErr, let s else { return nil }
    return s.takeRetainedValue() as String
}

func processObject(pid: pid_t) -> AudioObjectID? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                          mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var p = pid, obj = AudioObjectID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioObjectID>.size)
    let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                         UInt32(MemoryLayout<pid_t>.size), &p, &size, &obj)
    return err == noErr && obj != kAudioObjectUnknown ? obj : nil
}

func defaultOutput() -> (AudioObjectID, String)? {
    guard let dev: AudioObjectID = prop(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0)),
          dev != kAudioObjectUnknown, let uid = stringProp(dev, kAudioDevicePropertyDeviceUID) else { return nil }
    return (dev, uid)
}

func run(_ path: String, _ args: [String]) -> String {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    try? p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

func musicPID() -> pid_t? { run("/usr/bin/pgrep", ["-x", "Music"]).split(separator: "\n").first.flatMap { pid_t($0) } }

func log(_ s: String) {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
    print("[\(f.string(from: Date()))] \(s)"); fflush(stdout)
}

// MARK: - Tap + aggregate device, IO gated on the target process actually playing

final class Engine {
    var tapID = AudioObjectID(kAudioObjectUnknown)
    var aggID = AudioObjectID(kAudioObjectUnknown)
    var procObj = AudioObjectID(kAudioObjectUnknown)
    var procID: AudioDeviceIOProcID?
    var runListener: AudioObjectPropertyListenerBlock?
    var ovListener: AudioObjectPropertyListenerBlock?
    var pid: pid_t = 0
    var outUID = ""
    var ioRunning = false
    var ioStarted = Date()
    var suppressed = false     // failsafe tripped; re-armed on the next play/stop or device change
    var startFailed = false
    var lastPlaying = false
    var overloadTimes: [Date] = []
    var onIOChange: () -> Void = {}
    var onIOWillStart: () -> Void = {}

    var ready: Bool { procID != nil }

    func targetPlaying() -> Bool {
        (prop(procObj, kAudioProcessPropertyIsRunningOutput, UInt32(0)) ?? 0) != 0
    }

    func setup(pid: pid_t, mute: CATapMuteBehavior) -> Bool {
        teardown()
        guard let proc = processObject(pid: pid) else { return false }
        guard let (outDev, uid) = defaultOutput() else { log("no default output"); return false }

        let desc = CATapDescription(processes: [proc], deviceUID: uid, stream: 0)
        desc.name = "AtmosEQ"
        desc.isPrivate = true
        desc.muteBehavior = mute
        var err = AudioHardwareCreateProcessTap(desc, &tapID)
        guard err == noErr else { log("CreateProcessTap failed \(err)"); return false }

        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AtmosEQ",
            kAudioAggregateDeviceUIDKey: "dev.chillibytes.atmoseq.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
            // Same clock as the device: no drift compensation (it would resample).
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: false]],
        ]
        err = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggID)
        guard err == noErr else { log("CreateAggregateDevice failed \(err)"); teardown(); return false }

        dsp.sampleRate = prop(aggID, kAudioDevicePropertyNominalSampleRate, Float64(48000)) ?? 48000

        let d = dsp
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { _, inData, _, outData, _ in render(d, inData, outData) }
        guard err == noErr, procID != nil else { log("CreateIOProc failed \(err)"); teardown(); return false }

        var ovAddr = AudioObjectPropertyAddress(mSelector: kAudioDeviceProcessorOverload, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let ov: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.overloadTimes.append(Date()) }
        AudioObjectAddPropertyListenerBlock(aggID, &ovAddr, .main, ov)
        ovListener = ov

        procObj = proc
        var runAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let rl: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.suppressed = false; self?.sync() }
        AudioObjectAddPropertyListenerBlock(proc, &runAddr, .main, rl)
        runListener = rl

        self.pid = pid
        self.outUID = uid
        let fmt: AudioStreamBasicDescription? = prop(tapID, kAudioTapPropertyFormat, AudioStreamBasicDescription())
        log("tap ready on \(stringProp(outDev, kAudioObjectPropertyName) ?? uid) @ \(Int(dsp.sampleRate)) Hz, \(fmt?.mChannelsPerFrame ?? 0) ch (device-stream tap, no drift compensation)")
        sync()
        return true
    }

    // Run our IO exactly while the target is outputting audio.
    func sync() {
        guard ready else { return }
        // Re-arm the failsafe on every play/stop edge (the HAL notification isn't guaranteed).
        let playing = targetPlaying()
        if playing != lastPlaying { lastPlaying = playing; suppressed = false }
        let want = playing && !suppressed
        if want && !ioRunning {
            dsp.resetState()
            dsp.heardAudio.store(false, ordering: .relaxed)
            onIOWillStart()
            let err = AudioDeviceStart(aggID, procID)
            if err == noErr { ioRunning = true; ioStarted = Date(); startFailed = false; onIOChange() }
            else if !startFailed { startFailed = true; log("couldn't start the tap (\(err)) — retrying") }
        } else if !want && ioRunning {
            AudioDeviceStop(aggID, procID)
            ioRunning = false; onIOChange()
        }
    }

    func teardown() {
        if let procID { if ioRunning { AudioDeviceStop(aggID, procID) }; AudioDeviceDestroyIOProcID(aggID, procID) }
        procID = nil; ioRunning = false
        if let runListener, procObj != kAudioObjectUnknown {
            var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(procObj, &a, .main, runListener)
        }
        if let ovListener, aggID != kAudioObjectUnknown {
            var a = AudioObjectPropertyAddress(mSelector: kAudioDeviceProcessorOverload, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(aggID, &a, .main, ovListener)
        }
        runListener = nil; ovListener = nil; procObj = AudioObjectID(kAudioObjectUnknown)
        if aggID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggID); aggID = AudioObjectID(kAudioObjectUnknown) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = AudioObjectID(kAudioObjectUnknown) }
    }
}

// MARK: - Watch Music's log: EQ on/off, which streams Music's own EQ is running on,
// and the track format. We only ever add EQ when all of that says "Atmos track, Music
// skipped its EQ"; if the log lines disappear (macOS update), we stay out of the way.

final class MusicWatcher {
    var eqEnabled = true
    var prepared = Set<Int>()
    var spatial = [Int: Bool]()   // stream number → is it an Atmos/multichannel stream?
    var current: Int?             // the stream that is actually playing
    var sawEQLine = false         // have we seen any of Music's EQ log lines at all?
    // Music pre-loads the next track and attaches its EQ to that stream early, so a
    // prepared stream that isn't the current one says nothing about the audible audio.
    var pendingPrepared: Bool { prepared.contains { $0 != current } }
    var onChange: () -> Void = {}
    var onSettings: () -> Void = {}
    var onStreamStart: () -> Void = {}

    let rePrep = try! NSRegularExpression(pattern: #"EQEffectsProcessor::(Prepare|Unprepare) stream (\d+)"#)
    let reSet = try! NSRegularExpression(pattern: #"EQEffectsProcessor::SetEQSettings '.*' \((enabled|disabled)\)"#)
    let reNew = try! NSRegularExpression(pattern: #"RP/NQ\.(\d+) Created new AudioQueue for format:'([^']+)'.*?channelsPerFrame:(\d+)"#)
    let reStart = try! NSRegularExpression(pattern: #"faqrp_(?:startTimebaseCommon|transitionCallback): \(0x[0-9a-f]+ RP/NQ\.(\d+)\).*calling CMTimebaseSetRateAndAnchor"#)
    let predicate = #"process == "Music" AND ((category == "effects" AND (eventMessage CONTAINS "EQEffectsProcessor::" OR eventMessage CONTAINS "EQManager::SetEQSettings")) OR eventMessage CONTAINS "Created new AudioQueue for format" OR eventMessage CONTAINS "calling CMTimebaseSetRateAndAnchor")"#

    func handle(_ line: String, live: Bool = true) {
        let r = NSRange(line.startIndex..., in: line)
        if let m = rePrep.firstMatch(in: line, range: r),
           let kind = Range(m.range(at: 1), in: line), let n = Range(m.range(at: 2), in: line), let id = Int(line[n]) {
            if line[kind] == "Prepare" { prepared.insert(id) } else { prepared.remove(id) }
            sawEQLine = true
        } else if let m = reSet.firstMatch(in: line, range: r), let k = Range(m.range(at: 1), in: line) {
            eqEnabled = line[k] == "enabled"
            sawEQLine = true
        } else if let m = reNew.firstMatch(in: line, range: r), let n = Range(m.range(at: 1), in: line), let f = Range(m.range(at: 2), in: line),
                  let c = Range(m.range(at: 3), in: line), let id = Int(line[n]) {
            spatial[id] = line[f] == "qc+3" || (Int(line[c]) ?? 2) > 2
            if spatial.count > 64, let oldest = spatial.keys.min() { spatial[oldest] = nil }
        } else if let m = reStart.firstMatch(in: line, range: r), let n = Range(m.range(at: 1), in: line), let id = Int(line[n]) {
            current = id
            if live { onStreamStart() }
        } else if line.contains("EQManager::SetEQSettings") {
            sawEQLine = true
            if live { onSettings() }
            return
        } else { return }
        onChange()
    }

    func replay(_ window: String) {
        run("/usr/bin/log", ["show", "--last", window, "--style", "compact", "--predicate", predicate])
            .split(separator: "\n").forEach { handle(String($0), live: false) }
    }

    // A stream that has been playing (or paused) for longer than the quick replay window
    // has no creation line in it. Fill only what is still unknown, off the main thread.
    func backfillIfNeeded() {
        guard current == nil || spatial[current!] == nil || !sawEQLine else { return }
        DispatchQueue.global().async {
            let old = MusicWatcher(); old.replay("6h")
            DispatchQueue.main.async {
                if self.current == nil { self.current = old.current }
                for (k, v) in old.spatial where self.spatial[k] == nil { self.spatial[k] = v }
                if !self.sawEQLine && old.sawEQLine { self.sawEQLine = true; self.eqEnabled = old.eqEnabled; self.prepared = old.prepared }
                self.onChange()
            }
        }
    }

    func stream() {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        p.arguments = ["stream", "--style", "compact", "--predicate", predicate]
        p.standardOutput = pipe
        var pending = ""
        pipe.fileHandleForReading.readabilityHandler = { h in
            let chunk = String(decoding: h.availableData, as: UTF8.self)
            DispatchQueue.main.async {
                pending += chunk
                while let nl = pending.firstIndex(of: "\n") {
                    let line = String(pending[..<nl]); pending.removeSubrange(...nl)
                    self.handle(line)
                }
            }
        }
        p.terminationHandler = { _ in DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.stream() } }
        try? p.run()
    }
}

// MARK: - Live EQ settings: Music's Equalizer window (Accessibility) when it is open —
// instant, and works for whichever preset is selected — else AppleScript by preset name.

final class EQWindowReader {
    private var app: AXUIElement?
    private var appPID: pid_t = 0
    private var window: AXUIElement?

    private func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v as? T
    }

    // The Equalizer window is the one with a preset pop-up and 11 sliders (preamp + 10 bands,
    // values in hundredths of a dB).
    private func sliders(of w: AXUIElement) -> (name: String, vals: [Double])? {
        guard let kids: [AXUIElement] = attr(w, kAXChildrenAttribute) else { return nil }
        var name = "", vals: [Double] = []
        for k in kids {
            guard let role: String = attr(k, kAXRoleAttribute) else { continue }
            if role == kAXPopUpButtonRole { name = attr(k, kAXValueAttribute) ?? name }
            else if role == kAXSliderRole, let v: NSNumber = attr(k, kAXValueAttribute) { vals.append(v.doubleValue / 100) }
        }
        return vals.count == 11 ? (name, vals) : nil
    }

    func read(pid: pid_t) -> (name: String, pre: Double, gains: [Double])? {
        if appPID != pid {
            let a = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(a, 0.3)
            app = a; appPID = pid; window = nil
        }
        if let w = window, let s = sliders(of: w) { return (s.name, s.vals[0], Array(s.vals[1...])) }
        window = nil
        guard let app, let wins: [AXUIElement] = attr(app, kAXWindowsAttribute) else { return nil }
        for w in wins {
            if let s = sliders(of: w) { window = w; return (s.name, s.vals[0], Array(s.vals[1...])) }
        }
        return nil
    }
}

func readPreset(_ name: String) -> (Double, [Double])? {
    let out = run("/usr/bin/osascript", ["-e", "tell application \"Music\" to get {preamp, band 1, band 2, band 3, band 4, band 5, band 6, band 7, band 8, band 9, band 10} of EQ preset \"\(name)\""])
    let vals = out.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    return vals.count == 11 ? (vals[0], Array(vals[1...])) : nil
}

func writeWAV(_ path: String, _ buf: UnsafePointer<Float>, frames: Int, rate: Double) {
    var d = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    let bytes = UInt32(frames * 2 * 4)
    d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVEfmt ".utf8))
    u32(16); u16(3); u16(2); u32(UInt32(rate)); u32(UInt32(rate) * 8); u16(8); u16(32)
    d.append(contentsOf: Array("data".utf8)); u32(bytes)
    d.append(UnsafeBufferPointer(start: buf, count: frames * 2))
    try? d.write(to: URL(fileURLWithPath: path))
}

// MARK: - Main

var presetName = UserDefaults.standard.string(forKey: "preset") ?? "Manual"
var always = false
var testSeconds = 0.0
var targetPID: pid_t?
var preampOverride: Double?
var replayWindow: String?
var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    switch a {
    case "--preset", "-p": presetName = args.next() ?? presetName
    case "--always": always = true
    case "--test": testSeconds = Double(args.next() ?? "") ?? 15
    case "--target": targetPID = args.next().flatMap { pid_t($0) }
    case "--preamp": preampOverride = args.next().flatMap { Double($0) }
    case "--replay": replayWindow = args.next()
    default:
        print("""
        usage: atmoseq [--preset NAME] [--preamp DB] [--always] [--test SECONDS [--target PID]]
          --preset  Music EQ preset to mirror while the Equalizer window is closed
                    (default: the last one seen in that window, else Manual)
          --preamp  use this preamp (EQ strength) instead of Music's slider
          --replay  diagnostic: run Music's log history (e.g. 30m) through the decision
                    logic, print every change of mind, and exit
          --always  apply EQ regardless of Music's own EQ state (turn Music's EQ off)
          --test    silent self-test: helper outputs nothing, records dry + EQ'd audio
                    to test-dry.wav / test-eq.wav. Music stays audible; any other
                    --target process is muted.
        """)
        exit(a == "-h" || a == "--help" ? 0 : 1)
    }
}
let test = testSeconds > 0

let engine = Engine()
let watcher = MusicWatcher()
var lastPreset: [Double] = []
var lastWet: Bool?
var lastReason = ""
// Set when playback (re)starts while a pre-loaded stream already has Music's EQ: that
// stream is probably the one starting, so stay dry until the log confirms which it is.
var holdUntil = Date.distantPast
var reportedAudio = false

// Why we are NOT adding EQ right now; empty = add it. EQ goes on only when the stream
// that is PLAYING is an Atmos stream and Music's own EQ is not attached to it.
// Anything unknown → stay out (never double the EQ).
func passthroughReason() -> String {
    if !watcher.sawEQLine { return "can't see Music's EQ log lines yet" }
    if !watcher.eqEnabled { return "Music's EQ is off" }
    if holdUntil > Date() { return "song change — waiting to see which stream starts" }
    guard let cur = watcher.current, let spatial = watcher.spatial[cur] else { return "don't know which stream is playing yet" }
    if !spatial { return "stereo stream \(cur) — Music's own EQ handles it" }
    if watcher.prepared.contains(cur) { return "Music's own EQ is running on stream \(cur)" }
    return ""
}

func updateWet() {
    let reason = test || always ? "" : passthroughReason()
    let wet = reason.isEmpty
    dsp.wantWet.store(wet, ordering: .relaxed)
    if !test && (wet != lastWet || reason != lastReason) {
        lastWet = wet; lastReason = reason
        log(wet ? "Atmos stream, Music skipped its EQ → applying \"\(presetName)\"" : "passthrough: \(reason)")
    }
}

func applyEQ(name: String, pre: Double, gains: [Double]) {
    let flat = [pre] + gains
    if !name.isEmpty && name != presetName {
        presetName = name
        UserDefaults.standard.set(name, forKey: "preset")
        lastPreset = []
    }
    guard flat != lastPreset else { return }
    lastPreset = flat
    let pre = preampOverride ?? pre
    dsp.load(preampDB: pre, gains: gains)
    log("EQ \"\(presetName)\": preamp \(String(format: "%+.1f", pre)) dB (EQ strength \(Int((pow(10, pre / 20) * 100).rounded()))%), bands \(gains.map { String(format: "%.1f", $0) }.joined(separator: " "))")
}

// Fallback path (Equalizer window closed, or no Accessibility permission).
func refreshPreset() {
    guard let (pre, gains) = readPreset(presetName) else { return }
    applyEQ(name: presetName, pre: pre, gains: gains)
}

let eqWindow = EQWindowReader()
let axTrusted = AXIsProcessTrusted()
var windowOpen = false
var pollCount = 0

// 5 Hz while the Equalizer window is open (slider drags apply live), 1 Hz to notice it opening.
func pollEQWindow() {
    pollCount += 1
    guard axTrusted, !test, engine.ready, windowOpen || pollCount % 5 == 0 else { return }
    if let r = eqWindow.read(pid: engine.pid) {
        windowOpen = true
        applyEQ(name: r.name, pre: r.pre, gains: r.gains)
    } else {
        windowOpen = false
    }
}

engine.onIOWillStart = {
    guard !test, !always, watcher.pendingPrepared else { return }
    holdUntil = Date().addingTimeInterval(2)
    dsp.wet = 0   // IO is stopped here, so the render thread isn't touching this
    updateWet()
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.05) { updateWet() }   // fallback release
}
engine.onIOChange = {
    if engine.ioRunning { reportedAudio = false }
    log(engine.ioRunning ? "playing → tap running" : "stopped → tap idle (device free to sleep)")
}

func tick() {
    if engine.ioRunning {
        if !reportedAudio, dsp.heardAudio.load(ordering: .relaxed) { reportedAudio = true; log("receiving audio ✓") }
        // Failsafe: the tap mutes Music. If it only yields silence while Music plays
        // (no System Audio Recording permission, or Music is on another device), let go.
        if !dsp.heardAudio.load(ordering: .relaxed), Date().timeIntervalSince(engine.ioStarted) > 5, !test {
            engine.suppressed = true; engine.sync()
            log("FAILSAFE: only silence while the target was playing — tap released, Music unmuted until the next play/stop.")
        }
        // Occasional overloads are normal (the AirPods engine logs them with or without us);
        // a sustained burst means we can't keep up.
        let now = Date()
        engine.overloadTimes.removeAll { now.timeIntervalSince($0) > 10 }
        if engine.overloadTimes.count > 30 && !test {
            engine.suppressed = true; engine.sync(); engine.overloadTimes.removeAll()
            log("FAILSAFE: sustained audio overloads — tap released, Music unmuted until the next play/stop.")
        }
    }
    engine.sync()
    if !test { updateWet() }
    let pid = targetPID ?? musicPID()
    let uid = defaultOutput()?.1 ?? ""
    if let pid {
        if !engine.ready || engine.pid != pid || engine.outUID != uid {
            let mute: CATapMuteBehavior = test ? (targetPID == nil ? .unmuted : .muted) : .mutedWhenTapped
            if engine.setup(pid: pid, mute: mute) { lastPreset = []; refreshPreset() }
        }
    } else if engine.ready {
        engine.teardown(); log("Music quit, tap released")
    }
}

func finishTest() -> Never {
    if let t = targetPID { kill(t, SIGTERM); Thread.sleep(forTimeInterval: 0.3) }  // muted target goes first
    engine.teardown()
    let frames = dsp.recPos.load(ordering: .relaxed)
    let cb = dsp.callbacks.load(ordering: .relaxed)
    let budget = Double(dsp.lastFrames) / dsp.sampleRate * 1e3
    log("callbacks \(cb), \(dsp.lastFrames) frames each (budget \(String(format: "%.2f", budget)) ms), worst callback \(String(format: "%.3f", Double(dsp.maxNanos.load(ordering: .relaxed)) / 1e6)) ms")
    log("overloads seen \(engine.overloadTimes.count); channels in \(dsp.inCh), out \(dsp.outCh)")
    log("peak in \(String(format: "%.3f", dsp.peakIn)), peak EQ'd \(String(format: "%.3f", dsp.peakOut)); recorded \(String(format: "%.1f", Double(frames) / dsp.sampleRate)) s")
    if let w = dsp.recWet, let r = dsp.recDry, frames > 0 {
        writeWAV("test-eq.wav", w, frames: frames, rate: dsp.sampleRate)
        writeWAV("test-dry.wav", r, frames: frames, rate: dsp.sampleRate)
        log("wrote test-dry.wav and test-eq.wav")
    }
    exit(0)
}

for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { if test { finishTest() }; engine.teardown(); log("stopped"); exit(0) }
    src.resume()
    _ = Unmanaged.passRetained(src)
}

if let w = replayWindow {
    var last = "?"
    for line in run("/usr/bin/log", ["show", "--last", w, "--style", "compact", "--predicate", watcher.predicate]).split(separator: "\n") {
        watcher.handle(String(line), live: false)
        let r = passthroughReason()
        if r != last { last = r; print(line.prefix(23), r.isEmpty ? "APPLY (stream \(watcher.current ?? -1))" : "passthrough: \(r)") }
    }
    exit(0)
}

if test {
    dsp.testMode = true
    dsp.recCap = Int(testSeconds * 48000 * 1.1)
    dsp.recWet = .allocate(capacity: dsp.recCap * 2)
    dsp.recDry = .allocate(capacity: dsp.recCap * 2)
    DispatchQueue.main.asyncAfter(deadline: .now() + testSeconds + 1) { finishTest() }
}
if !always && !test { watcher.replay("20m"); watcher.stream() }
watcher.onChange = updateWet
watcher.onStreamStart = { holdUntil = .distantPast }   // runs before onChange → updateWet
var lastSettingsRefresh = Date.distantPast
watcher.onSettings = {
    // Without the window reader, follow Music's "settings changed" events (throttled).
    guard !windowOpen, Date().timeIntervalSince(lastSettingsRefresh) > 0.3 else { return }
    lastSettingsRefresh = Date(); refreshPreset()
}
tick()
refreshPreset()
updateWet()
if !always && !test {
    watcher.backfillIfNeeded()
    log(axTrusted ? "live EQ control: on (reads Music's Equalizer window while it's open)"
                  : "live EQ control: limited (no Accessibility permission) — following preset \"\(presetName)\" via AppleScript")
}
// Follow output-device changes immediately instead of waiting for the next tick.
var outAddr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &outAddr, .main) { _, _ in tick() }
// Start/stop with Music's output even if the HAL notification is missed.
Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in engine.sync() }
Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in pollEQWindow() }
if test, let t = targetPID { kill(t, SIGUSR1) }  // tone generator: start once muted by the tap
Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in tick() }
Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in if !windowOpen { refreshPreset() } }
RunLoop.main.run()
