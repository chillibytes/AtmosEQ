// Holds a MUTED device-stream tap on Music for its whole lifetime (Music is inaudible
// while this runs) and records segments on command. stdin: "rec NAME" / "end" / "quit".
import CoreAudio
import AudioToolbox
import Foundation
import Synchronization

func run(_ p: String, _ a: [String]) -> String {
    let pr = Process(), pipe = Pipe(); pr.executableURL = URL(fileURLWithPath: p); pr.arguments = a; pr.standardOutput = pipe
    try? pr.run(); let d = pipe.fileHandleForReading.readDataToEndOfFile(); pr.waitUntilExit(); return String(decoding: d, as: UTF8.self)
}
func say(_ s: String) { print(s); fflush(stdout) }
guard let pid = run("/usr/bin/pgrep", ["-x", "Music"]).split(separator: "\n").first.flatMap({ pid_t($0) }) else { say("Music not running"); exit(1) }
var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var p = pid, proc = AudioObjectID(0), size = UInt32(4)
guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 4, &p, &size, &proc) == noErr, proc != 0 else { say("no process object"); exit(1) }
var dAddr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var out = AudioObjectID(0); size = 4
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &dAddr, 0, nil, &size, &out)
var uAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var su: Unmanaged<CFString>?; var ssz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
AudioObjectGetPropertyData(out, &uAddr, 0, nil, &ssz, &su); let uid = su!.takeRetainedValue() as String

let desc = CATapDescription(processes: [proc], deviceUID: uid, stream: 0)
desc.isPrivate = true; desc.muteBehavior = .muted
var tap = AudioObjectID(0)
guard AudioHardwareCreateProcessTap(desc, &tap) == noErr else { say("tap failed"); exit(1) }
let dict: [String: Any] = [
    kAudioAggregateDeviceNameKey: "calrec", kAudioAggregateDeviceUIDKey: "dev.chillibytes.calrec.\(UUID().uuidString)",
    kAudioAggregateDeviceMainSubDeviceKey: uid, kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceTapAutoStartKey: true, kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
    kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: false]],
]
var agg = AudioObjectID(0)
guard AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg) == noErr else { AudioHardwareDestroyProcessTap(tap); say("agg failed"); exit(1) }
let cap = 48000 * 40 * 2
let rec = UnsafeMutablePointer<Float>.allocate(capacity: cap)
let recording = Atomic<Bool>(false)
nonisolated(unsafe) var n = 0
var procID: AudioDeviceIOProcID?
AudioDeviceCreateIOProcIDWithBlock(&procID, agg, nil) { _, inData, _, outData, _ in
    let outs = UnsafeMutableAudioBufferListPointer(outData)
    for b in outs { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
    guard recording.load(ordering: .relaxed) else { return }
    let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
    guard ins.count > 0, let s = ins[0].mData?.assumingMemoryBound(to: Float.self) else { return }
    let nch = Int(ins[0].mNumberChannels), frames = Int(ins[0].mDataByteSize) / (4 * nch)
    for f in 0..<frames where n + 2 <= cap { rec[n] = s[f * nch]; rec[n + 1] = nch > 1 ? s[f * nch + 1] : s[f * nch]; n += 2 }
}
guard AudioDeviceStart(agg, procID) == noErr else { say("start failed"); exit(1) }
func teardown() {
    AudioDeviceStop(agg, procID); AudioDeviceDestroyIOProcID(agg, procID!)
    AudioHardwareDestroyAggregateDevice(agg); AudioHardwareDestroyProcessTap(tap)
}
func save(_ name: String) {
    var d = Data(); func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }; func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + n * 4)); d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(3); u16(2); u32(48000); u32(384000); u16(8); u16(32)
    d.append(contentsOf: Array("data".utf8)); u32(UInt32(n * 4)); d.append(UnsafeBufferPointer(start: rec, count: n))
    try! d.write(to: URL(fileURLWithPath: "\(name).wav"))
    var pk: Float = 0; for i in 0..<n { pk = max(pk, abs(rec[i])) }
    say("saved \(name).wav \(String(format: "%.1f", Double(n / 2) / 48000)) s peak \(String(format: "%.3f", pk))")
}
say("ready (Music muted on \(uid))")
var current = ""
while let line = readLine() {
    let parts = line.split(separator: " ").map(String.init)
    guard let cmd = parts.first else { continue }
    if cmd == "rec", parts.count > 1 { n = 0; current = parts[1]; recording.store(true, ordering: .relaxed) }
    else if cmd == "end" { recording.store(false, ordering: .relaxed); Thread.sleep(forTimeInterval: 0.05); save(current) }
    else if cmd == "quit" { break }
}
teardown(); say("bye")
