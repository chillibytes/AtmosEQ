// Plays a phase-continuous 1000 Hz sine at -40 dBFS, but only after SIGUSR1
// (sent once the probe's muting tap is in place). Self-exits after argv[1] seconds.
import AVFoundation
import Synchronization

let on = Atomic<Bool>(false)
let life = Double(CommandLine.arguments.dropFirst().first ?? "") ?? 60
let engine = AVAudioEngine()
let sr = engine.outputNode.outputFormat(forBus: 0).sampleRate
let inc = 2 * Double.pi * 1000 / sr
nonisolated(unsafe) var phase = 0.0
let src = AVAudioSourceNode { _, _, frameCount, abl in
    let bufs = UnsafeMutableAudioBufferListPointer(abl)
    let live = on.load(ordering: .relaxed)
    for f in 0..<Int(frameCount) {
        let v = live ? Float(sin(phase) * 0.01) : 0
        phase += inc; if phase > 2 * Double.pi { phase -= 2 * Double.pi }
        for b in bufs { b.mData!.assumingMemoryBound(to: Float.self)[f] = v }
    }
    return noErr
}
engine.attach(src)
engine.connect(src, to: engine.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2))
try! engine.start()
print("tonegen pid \(getpid()) @ \(sr) Hz"); fflush(stdout)
signal(SIGUSR1, SIG_IGN)
let s1 = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
s1.setEventHandler { on.store(true, ordering: .relaxed) }
s1.resume()
DispatchQueue.main.asyncAfter(deadline: .now() + life) { exit(0) }
RunLoop.main.run()
