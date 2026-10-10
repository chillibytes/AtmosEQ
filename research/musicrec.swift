// Records Music's output on the default device via a device-stream tap (unmuted:
// you keep hearing Music normally). Usage: musicrec SECONDS OUT.wav
import CoreAudio
import AudioToolbox
import Foundation

let secs = Double(CommandLine.arguments[1])!, outPath = CommandLine.arguments[2]
func run(_ p: String, _ a: [String]) -> String {
    let pr = Process(), pipe = Pipe(); pr.executableURL = URL(fileURLWithPath: p); pr.arguments = a; pr.standardOutput = pipe
    try? pr.run(); let d = pipe.fileHandleForReading.readDataToEndOfFile(); pr.waitUntilExit(); return String(decoding: d, as: UTF8.self)
}
guard let pid = run("/usr/bin/pgrep", ["-x", "Music"]).split(separator: "\n").first.flatMap({ pid_t($0) }) else { print("Music not running"); exit(1) }
var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var p = pid, proc = AudioObjectID(0), size = UInt32(4)
guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 4, &p, &size, &proc) == noErr, proc != 0 else { print("no process object"); exit(1) }
var dAddr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var out = AudioObjectID(0); size = 4
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &dAddr, 0, nil, &size, &out)
var uAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var su: Unmanaged<CFString>?; var ssz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
AudioObjectGetPropertyData(out, &uAddr, 0, nil, &ssz, &su); let uid = su!.takeRetainedValue() as String

let desc = CATapDescription(processes: [proc], deviceUID: uid, stream: 0)
desc.isPrivate = true; desc.muteBehavior = .unmuted
var tap = AudioObjectID(0)
guard AudioHardwareCreateProcessTap(desc, &tap) == noErr else { print("tap failed"); exit(1) }
let dict: [String: Any] = [
    kAudioAggregateDeviceNameKey: "musicrec", kAudioAggregateDeviceUIDKey: "dev.chillibytes.musicrec.\(UUID().uuidString)",
    kAudioAggregateDeviceMainSubDeviceKey: uid, kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceTapAutoStartKey: true, kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
    kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: false]],
]
var agg = AudioObjectID(0)
guard AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg) == noErr else { AudioHardwareDestroyProcessTap(tap); print("agg failed"); exit(1) }
let cap = Int(secs * 48000 * 1.2) * 2
let rec = UnsafeMutablePointer<Float>.allocate(capacity: cap)
nonisolated(unsafe) var n = 0
var procID: AudioDeviceIOProcID?
AudioDeviceCreateIOProcIDWithBlock(&procID, agg, nil) { _, inData, _, outData, _ in
    let outs = UnsafeMutableAudioBufferListPointer(outData)
    for b in outs { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
    let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
    guard ins.count > 0, let s = ins[0].mData?.assumingMemoryBound(to: Float.self) else { return }
    let nch = Int(ins[0].mNumberChannels), frames = Int(ins[0].mDataByteSize) / (4 * nch)
    for f in 0..<frames where n + 2 <= cap {
        rec[n] = s[f * nch]; rec[n + 1] = nch > 1 ? s[f * nch + 1] : s[f * nch]; n += 2
    }
}
AudioDeviceStart(agg, procID)
Thread.sleep(forTimeInterval: secs)
AudioDeviceStop(agg, procID); AudioDeviceDestroyIOProcID(agg, procID!)
AudioHardwareDestroyAggregateDevice(agg); AudioHardwareDestroyProcessTap(tap)
var d = Data(); func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }; func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + n * 4)); d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(3); u16(2); u32(48000); u32(384000); u16(8); u16(32)
d.append(contentsOf: Array("data".utf8)); u32(UInt32(n * 4)); d.append(UnsafeBufferPointer(start: rec, count: n))
try! d.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath): \(String(format: "%.1f", Double(n / 2) / 48000)) s")
