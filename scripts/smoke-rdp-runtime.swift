import AppKit
import Darwin
import Foundation

// Run only against a trusted, signature-verified local release. This creates a
// native canvas without starting a connection, loading client records or Keychain.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
guard CommandLine.arguments.count == 2 else {
    fail("Usage: swift scripts/smoke-rdp-runtime.swift /path/to/Nethriva.app")
}
let runtime = URL(fileURLWithPath: CommandLine.arguments[1])
    .appendingPathComponent("Contents/Resources/FreeRDP")
let library = runtime.appendingPathComponent("Frameworks/libNethrivaRDP.dylib")
guard let handle = dlopen(library.path, RTLD_NOW | RTLD_LOCAL) else {
    fail("RDP runtime failed to load: " + (dlerror().map { String(cString: $0) } ?? "unknown loader error"))
}
func symbol<T>(_ name: String, _ type: T.Type) -> T {
    guard let value = dlsym(handle, name) else { fail("Missing bridge export: " + name) }
    return unsafeBitCast(value, to: type)
}
let configure = symbol("NethrivaRDPConfigureOpenSSL", (@convention(c) (UnsafePointer<CChar>?) -> Int32).self)
let create = symbol("NethrivaRDPCreateView", (@convention(c) (Double, Double) -> UnsafeMutableRawPointer?).self)
let getView = symbol("NethrivaRDPGetView", (@convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?).self)
let resize = symbol("NethrivaRDPResize", (@convention(c) (UnsafeMutableRawPointer?, Double, Double, Double, Double, Double) -> Void).self)
let destroy = symbol("NethrivaRDPDestroy", (@convention(c) (UnsafeMutableRawPointer?) -> Void).self)
NSApplication.shared.setActivationPolicy(.prohibited)
let configured = runtime.appendingPathComponent("Frameworks/ossl-modules").path.withCString { configure($0) }
guard configured == 1 else { fail("Bundled OpenSSL providers did not initialize.") }
autoreleasepool {
    guard let session = create(640, 480), getView(session) != nil else { fail("Could not create native RDP canvas.") }
    resize(session, 800, 600, 800, 600, 100)
    destroy(session)
}
// Keep Objective-C library code resident until process exit.
print("PASS: bundled RDP load, OpenSSL providers, native canvas, resize and destroy; no network connection or credentials used.")
