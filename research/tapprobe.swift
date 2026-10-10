// Taps one process (muted), records what arrives through an aggregate device built
// exactly like atmoseq's, outputs silence. Usage: tapprobe PID SECONDS DRIFT(0|1) PREFIX
import CoreAudio
import AudioToolbox
import Foundation

let a = CommandLine.arguments
let pid = pid_t(a[1])!, secs = Double(a[2])!, drift = a[3] == "1", prefix = a[4], devTap = a.count > 5 && a[5] == "dev"

func sysProp<T>(_ sel: AudioObjectPropertySelector, _ v: T) -> T {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var val = v; var size = UInt32(MemoryLayout<T>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &val); return val
}
func uidOf(_ dev: AudioObjectID) -> String {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var s: Unmanaged<CFString>?; var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &s); return s!.takeRetainedValue() as String
}

var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var p = pid, proc = AudioObjectID(0), size = UInt32(4)
guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 4, &p, &size, &proc) == noErr, proc != 0 else { print("no process object"); exit(1) }

let out: AudioObjectID = sysProp(kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0))
let uid = uidOf(out)
let desc = devTap ? CATapDescription(processes: [proc], deviceUID: uid, stream: 0) : CATapDescription(stereoMixdownOfProcesses: [proc])
desc.isPrivate = true; desc.muteBehavior = .muted
var tap = AudioObjectID(0)
guard AudioHardwareCreateProcessTap(desc, &tap) == noErr else { print("tap failed"); exit(1) }
func u32p(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32 {
    var ad = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var v: UInt32 = 0; var sz = UInt32(4); AudioObjectGetPropertyData(obj, &ad, 0, nil, &sz, &v); return v
}
var fad = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var fmt = AudioStreamBasicDescription(); var fsz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
AudioObjectGetPropertyData(tap, &fad, 0, nil, &fsz, &fmt)
print("tap kind \(devTap ? "device-stream" : "stereo-mixdown"): \(Int(fmt.mSampleRate)) Hz \(fmt.mChannelsPerFrame) ch; device clock domain \(u32p(out, kAudioDevicePropertyClockDomain))")
let dict: [String: Any] = [
    kAudioAggregateDeviceNameKey: "tapprobe", kAudioAggregateDeviceUIDKey: "dev.chillibytes.tapprobe.\(UUID().uuidString)",
    kAudioAggregateDeviceMainSubDeviceKey: uid, kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceTapAutoStartKey: true, kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
    kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: drift]],
]
var agg = AudioObjectID(0)
guard AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg) == noErr else { AudioHardwareDestroyProcessTap(tap); print("agg failed"); exit(1) }

let cap = Int(secs * 48000 * 1.3)
let rec = UnsafeMutablePointer<Float>.allocate(capacity: cap)
let maxCB = Int(secs * 48000 / 64)
// per callback: now host, in sampleTime, in hostTime, in rateScalar, out sampleTime, out hostTime, out rateScalar, frames
let ts = UnsafeMutablePointer<Double>.allocate(capacity: maxCB * 8)
nonisolated(unsafe) var n = 0, cb = 0
var procID: AudioDeviceIOProcID?
AudioDeviceCreateIOProcIDWithBlock(&procID, agg, nil) { now, inData, inTime, outData, outTime in
    let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
    let outs = UnsafeMutableAudioBufferListPointer(outData)
    for b in outs { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
    guard ins.count > 0, let src = ins[0].mData?.assumingMemoryBound(to: Float.self) else { return }
    let nch = Int(ins[0].mNumberChannels), frames = Int(ins[0].mDataByteSize) / (4 * nch)
    for f in 0..<frames where n < cap { rec[n] = src[f * nch]; n += 1 }
    if cb < maxCB {
        let t = ts + cb * 8
        t[0] = Double(now.pointee.mHostTime); t[1] = inTime.pointee.mSampleTime; t[2] = Double(inTime.pointee.mHostTime); t[3] = inTime.pointee.mRateScalar
        t[4] = outTime.pointee.mSampleTime; t[5] = Double(outTime.pointee.mHostTime); t[6] = outTime.pointee.mRateScalar; t[7] = Double(frames)
        cb += 1
    }
}
print("aggregate clock domain \(u32p(agg, kAudioDevicePropertyClockDomain))")
AudioDeviceStart(agg, procID)
var tb = mach_timebase_info(); mach_timebase_info(&tb)
let startHost = mach_absolute_time(), startWall = Date()
kill(pid, SIGUSR1)  // tone on — muted by the tap
print("recording \(secs)s, drift compensation \(drift ? "ON" : "OFF"), device \(uid)"); fflush(stdout)
Thread.sleep(forTimeInterval: secs)
kill(pid, SIGTERM)          // tone process gone before the tap goes away
Thread.sleep(forTimeInterval: 0.3)
AudioDeviceStop(agg, procID); AudioDeviceDestroyIOProcID(agg, procID!)
AudioHardwareDestroyAggregateDevice(agg); AudioHardwareDestroyProcessTap(tap)

var d = Data(); func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }; func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + n * 4)); d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(3); u16(1); u32(48000); u32(192000); u16(4); u16(32)
d.append(contentsOf: Array("data".utf8)); u32(UInt32(n * 4)); d.append(UnsafeBufferPointer(start: rec, count: n))
try! d.write(to: URL(fileURLWithPath: "\(prefix).wav"))
var csv = "startHost,\(startHost),startWall,\(startWall.timeIntervalSince1970),numer,\(tb.numer),denom,\(tb.denom)\nnow,inS,inH,inR,outS,outH,outR,frames\n"
for i in 0..<cb { let t = ts + i * 8; csv += (0..<8).map { String(format: "%.6f", t[$0]) }.joined(separator: ",") + "\n" }
try! csv.write(toFile: "\(prefix).csv", atomically: true, encoding: .utf8)
print("wrote \(prefix).wav (\(n) frames) + \(prefix).csv (\(cb) callbacks)")
