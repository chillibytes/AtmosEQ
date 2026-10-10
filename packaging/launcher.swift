// AtmosEQ.app's executable: a small launcher that owns the permissions and runs the
// engine (the plain `atmoseq` binary) as its child.
//
// macOS checks the tap's permission, Accessibility and Automation against the
// *responsible* app, which for a child process is this launcher. Keeping the launcher
// this small means it rarely changes, so engine updates keep the permissions.
//
// Which permission: coreaudiod lets a process tap audio if its app has Microphone,
// Screen Recording or System Audio Recording. Only the System Audio Recording route lights
// the purple recording indicator. So the bundle deliberately has no
// NSAudioCaptureUsageDescription (that request is refused without asking) and AtmosEQ
// asks for Screen Recording instead, the same way a terminal-launched atmoseq works.

import AppKit
import ApplicationServices
import Foundation

func log(_ s: String) {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
    print("[\(f.string(from: Date()))] launcher: \(s)"); fflush(stdout)
}
if let path = ProcessInfo.processInfo.environment["ATMOSEQ_LOG"] { freopen(path, "a", stdout) }

// The answer to CGPreflightScreenCaptureAccess is fixed for the life of a process, so
// while permission is missing we exit with a failure and let launchd start us again.
let engine = ProcessInfo.processInfo.environment["ATMOSEQ_ENGINE"]
    ?? NSHomeDirectory() + "/Library/Application Support/AtmosEQ/atmoseq"
var child: Process?

for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        if let c = child, c.isRunning { c.interrupt(); c.waitUntilExit() }   // engine unmutes Music on SIGINT
        exit(0)
    }
    src.resume()
    _ = Unmanaged.passRetained(src)
}

// Ask once for Accessibility (opens System Settings) and for Screen Recording. The engine
// is only started once recording is allowed, so Music is never muted behind a prompt.
if !AXIsProcessTrusted() {
    _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
}
if !CGPreflightScreenCaptureAccess() {
    _ = CGRequestScreenCaptureAccess()   // shows the request once; later calls do nothing
    log("waiting for Screen Recording permission (Music plays untouched until then); checking again in 15 s")
    Thread.sleep(forTimeInterval: 15)
    exit(75)   // launchd restarts us (KeepAlive on failure)
}

guard FileManager.default.isExecutableFile(atPath: engine) else {
    log("engine not found at \(engine) — run `make install` again")
    exit(1)
}
let p = Process()
p.executableURL = URL(fileURLWithPath: engine)
p.arguments = Array(CommandLine.arguments.dropFirst())
p.terminationHandler = { proc in
    DispatchQueue.main.async { exit(proc.terminationStatus) }   // launchd restarts us on failure
}
do { try p.run() } catch { log("couldn't start the engine: \(error)"); exit(1) }
child = p
RunLoop.main.run()
