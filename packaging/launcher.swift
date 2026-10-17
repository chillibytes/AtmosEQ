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
//
// Started by launchd it is the login item. Started any other way (Finder, `open`, System
// Settings' "Quit & Reopen") it never runs a second engine: it reports or asks for a
// permission for the installer, or else restarts the login item. macOS only shows the
// Screen Recording prompt to an app started that way, not to a background login item.

import AppKit
import ApplicationServices
import Foundation

let label = "dev.chillibytes.atmoseq"
let args = Array(CommandLine.arguments.dropFirst())

func log(_ s: String) {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
    print("[\(f.string(from: Date()))] launcher: \(s)"); fflush(stdout)
}

/// Automation of Music: noErr = allowed, errAEEventNotPermitted = denied,
/// errAEEventWouldRequireUserConsent = not asked yet, procNotFound = Music isn't running.
func musicAutomation(ask: Bool) -> OSStatus {
    var target = AEAddressDesc()
    let id = Array("com.apple.Music".utf8)
    guard AECreateDesc(DescType(typeApplicationBundleID), id, id.count, &target) == noErr else { return OSStatus(procNotFound) }
    defer { AEDisposeDesc(&target) }
    return AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
}

if ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] != label {
    switch (args.first, args.dropFirst().first) {
    case ("--status", let path?):
        // The installer starts a fresh copy for every check: macOS fixes the Screen
        // Recording answer for the life of a process.
        let music: String
        switch Int(musicAutomation(ask: false)) {
        case Int(noErr): music = "yes"
        case Int(errAEEventWouldRequireUserConsent): music = "ask"
        case Int(procNotFound): music = "not-running"
        default: music = "no"
        }
        let status = """
            screen-recording=\(CGPreflightScreenCaptureAccess() ? "yes" : "no")
            accessibility=\(AXIsProcessTrusted() ? "yes" : "no")
            music=\(music)

            """
        try? status.write(toFile: path, atomically: true, encoding: .utf8)
    case ("--ask", "music"):
        _ = musicAutomation(ask: true)   // returns once the dialog is answered
    case ("--ask", let what?):
        NSApplication.shared.setActivationPolicy(.accessory)
        if what == "screen-recording" { _ = CGRequestScreenCaptureAccess() }   // only the first request shows a dialog
        if what == "accessibility" {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
        // Stay up while the dialog is open. The installer quits us once it's answered, and so
        // does System Settings' "Quit & Reopen".
        DispatchQueue.main.asyncAfter(deadline: .now() + 600) { exit(0) }
        NSApplication.shared.run()
    default:
        // Opened by hand, or reopened by System Settings after a permission was turned on:
        // restart the login item so it picks the permission up.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["kickstart", "-k", "gui/\(getuid())/\(label)"]
        try? p.run()
        p.waitUntilExit()
    }
    exit(0)
}

// The login item.

if let path = ProcessInfo.processInfo.environment["ATMOSEQ_LOG"] { freopen(path, "a", stdout) }

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

func startEngine() {
    guard FileManager.default.isExecutableFile(atPath: engine) else {
        log("engine not found at \(engine) — run `make install` again")
        exit(1)
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: engine)
    p.arguments = args
    p.terminationHandler = { proc in
        DispatchQueue.main.async { exit(proc.terminationStatus) }   // launchd restarts us on failure
    }
    do { try p.run() } catch { log("couldn't start the engine: \(error)"); exit(1) }
    child = p
}

// The engine is only started once recording is allowed, so Music is never muted behind a
// missing permission. The answer to CGPreflightScreenCaptureAccess is fixed for the life of
// a process, so until then we exit with a failure every minute and launchd starts us again.
// (Waiting on the run loop, not in a sleep, so `make install` can stop us right away.)
if CGPreflightScreenCaptureAccess() {
    startEngine()
} else {
    log("no Screen Recording permission yet (Music plays untouched until then); run `make install` to set it up")
    DispatchQueue.main.asyncAfter(deadline: .now() + 60) { exit(75) }   // launchd restarts us (KeepAlive on failure)
}
RunLoop.main.run()
