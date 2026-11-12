import AppKit
import CoreGraphics
import Darwin
import Foundation

// Run against a trusted, signature-verified extracted app. Nethriva's hosted-test
// profile isolates connections, preferences and Keychain from personal records.
// Requires access to the Mac desktop services. This is a local startup check,
// not Gatekeeper acceptance or another Mac's CPU emulation.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
guard CommandLine.arguments.count == 2 else {
    fail("Usage: swift scripts/smoke-app-launch.swift /path/to/Nethriva.app")
}
let app = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
guard app.lastPathComponent == "Nethriva.app",
      let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
      let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
      plist["CFBundleExecutable"] as? String == "Nethriva" else {
    fail("Expected a Nethriva application bundle.")
}
NSApplication.shared.setActivationPolicy(.prohibited)
let configuration = NSWorkspace.OpenConfiguration()
configuration.createsNewApplicationInstance = true
configuration.allowsRunningApplicationSubstitution = false
configuration.activates = false
configuration.addsToRecentItems = false
configuration.promptsUserIfNeeded = false
configuration.arguments = ["-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO"]
// LaunchServices supplies the normal desktop context instead of inheriting a
// command tool's sandbox. No developer loader-path overrides are supplied.
configuration.environment = [
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
    "TMPDIR": NSTemporaryDirectory(),
    "XCTestConfigurationFilePath": "/private/tmp/Nethriva-Launch-Smoke-Isolation"
]
func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    repeat {
        if condition() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    } while Date() < deadline
    return condition()
}
var running: NSRunningApplication?
var replied = false
NSWorkspace.shared.openApplication(at: app, configuration: configuration) { application, _ in
    DispatchQueue.main.async { running = application; replied = true }
}
guard waitUntil(30, { replied }), let process = running else {
    fail("LaunchServices could not open the isolated app; check desktop-service access.")
}
guard process.bundleURL?.standardizedFileURL == app else {
    fail("LaunchServices did not select the requested test bundle.")
}
func stopOwnedProcess() {
    guard !process.isTerminated else { return }
    process.terminate()
    if !waitUntil(5, { process.isTerminated }) {
        process.forceTerminate()
        if !waitUntil(3, { process.isTerminated }) { kill(process.processIdentifier, SIGKILL) }
    }
}
let started = waitUntil(30) {
    guard !process.isTerminated else { return true }
    guard process.isFinishedLaunching else { return false }
    // Inspect only geometry for this process; no titles, images or other apps.
    let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
    return windows.contains { window in
        guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == process.processIdentifier,
              (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let width = bounds["Width"] as? NSNumber,
              let height = bounds["Height"] as? NSNumber else { return false }
        return width.doubleValue >= 900 && height.doubleValue >= 600
    }
}
let healthy = started && !process.isTerminated && waitUntil(3, { process.isTerminated }) == false
stopOwnedProcess()
guard healthy else { fail("Application exited early or did not finish launching with a workspace window.") }
print("PASS: isolated application finished launching, created a workspace window and remained running; only the smoke process was closed.")
