import CoreAudio
import Foundation
func u32(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var v: UInt32 = 99; var sz = UInt32(4)
    let e = AudioObjectGetPropertyData(obj, &a, 0, nil, &sz, &v)
    return e == noErr ? "\(v)" : "err \(e)"
}
let pid = pid_t(CommandLine.arguments[1])!
var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var p = pid, proc = AudioObjectID(0), size = UInt32(4)
let e = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 4, &p, &size, &proc)
print("process object \(proc) (err \(e)); isRunning \(u32(proc, kAudioProcessPropertyIsRunning)), isRunningOutput \(u32(proc, kAudioProcessPropertyIsRunningOutput)), isRunningInput \(u32(proc, kAudioProcessPropertyIsRunningInput))")
// devices the process is using
var da = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyDevices, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
var dsz: UInt32 = 0
if AudioObjectGetPropertyDataSize(proc, &da, 0, nil, &dsz) == noErr, dsz > 0 {
    var devs = [AudioObjectID](repeating: 0, count: Int(dsz) / 4)
    AudioObjectGetPropertyData(proc, &da, 0, nil, &dsz, &devs)
    print("output devices: \(devs)")
} else { print("output devices: none") }
// all process objects with their pids/running state
var la = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var lsz: UInt32 = 0
AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &la, 0, nil, &lsz)
var objs = [AudioObjectID](repeating: 0, count: Int(lsz) / 4)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &la, 0, nil, &lsz, &objs)
for o in objs {
    var pa = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var op: pid_t = 0; var s4 = UInt32(4)
    AudioObjectGetPropertyData(o, &pa, 0, nil, &s4, &op)
    let ro = u32(o, kAudioProcessPropertyIsRunningOutput)
    if ro == "1" || op == pid { print("  obj \(o) pid \(op) runningOutput \(ro)") }
}
