import AppKit
import Darwin
import Foundation

enum RDPViewportSizing {
    static let supportedDisplayScales = [100, 140, 180]

    static func desktopSize(for viewport: CGSize) -> CGSize {
        CGSize(
            width: dimension(viewport.width),
            height: dimension(viewport.height)
        )
    }

    static func validatedDisplayScale(_ scale: Int) -> Int {
        supportedDisplayScales.contains(scale) ? scale : 100
    }

    private static func dimension(_ value: CGFloat) -> CGFloat {
        let clamped = min(max(Int(value.rounded()), 200), 8192)
        return CGFloat(clamped & ~1)
    }
}

enum EmbeddedRDPError: LocalizedError {
    case runtimeMissing
    case loadFailed(String)
    case missingSymbol(String)
    case viewCreationFailed
    case startFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .runtimeMissing:
            "The embedded FreeRDP runtime is missing from the app bundle."
        case .loadFailed(let message):
            "The embedded FreeRDP runtime could not be loaded: \(message)"
        case .missingSymbol(let name):
            "The embedded FreeRDP runtime is incomplete (missing \(name))."
        case .viewCreationFailed:
            "The embedded RDP canvas could not be created."
        case .startFailed(let status):
            "FreeRDP could not start the embedded session (status \(status))."
        }
    }
}

@MainActor
final class EmbeddedRDPSession {
    enum ConnectionState: Int32 {
        case ended = -1
        case idle = 0
        case connecting = 1
        case connected = 2
    }

    private typealias CreateViewFunction = @convention(c) (Double, Double) -> UnsafeMutableRawPointer?
    private typealias GetViewFunction = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    private typealias StartFunction = @convention(c) (
        UnsafeMutableRawPointer?,
        Int32,
        UnsafePointer<UnsafePointer<CChar>?>?
    ) -> Int32
    private typealias StateFunction = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    private typealias LastErrorFunction = @convention(c) (UnsafeMutableRawPointer?) -> UInt32
    private typealias ResizeFunction = @convention(c) (
        UnsafeMutableRawPointer?,
        Double,
        Double,
        Double,
        Double,
        Double
    ) -> Void
    private typealias FocusFunction = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias PasteFunction = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias PasteFilesFunction = @convention(c) (
        UnsafeMutableRawPointer?,
        Int32,
        UnsafePointer<UnsafePointer<CChar>?>?
    ) -> Int32
    private typealias PasteFilesAtPointFunction = @convention(c) (
        UnsafeMutableRawPointer?,
        Int32,
        UnsafePointer<UnsafePointer<CChar>?>?,
        Double,
        Double
    ) -> Int32
    private typealias DestroyFunction = @convention(c) (UnsafeMutableRawPointer?) -> Void

    private var library: UnsafeMutableRawPointer?
    private var session: UnsafeMutableRawPointer?
    private var viewStorage: NSView?

    private let startFunction: StartFunction
    private let stateFunction: StateFunction
    private let lastErrorFunction: LastErrorFunction
    private let resizeFunction: ResizeFunction
    private let focusFunction: FocusFunction
    private let pasteFunction: PasteFunction
    private let pasteFilesFunction: PasteFilesFunction
    private let pasteFilesAtPointFunction: PasteFilesAtPointFunction
    private let destroyFunction: DestroyFunction

    var view: NSView {
        guard let viewStorage else {
            preconditionFailure("The embedded RDP view is no longer available.")
        }
        return viewStorage
    }

    init(viewportSize: CGSize) throws {
        guard let runtimeRoot = Bundle.main.resourceURL?.appendingPathComponent("FreeRDP") else {
            throw EmbeddedRDPError.runtimeMissing
        }

        let libraryURL = runtimeRoot
            .appendingPathComponent("Frameworks")
            .appendingPathComponent("libRemoteDeckRDP.dylib")
        let providerDirectory = runtimeRoot
            .appendingPathComponent("Frameworks/ossl-modules", isDirectory: true)
        setenv("OPENSSL_MODULES", providerDirectory.path, 1)

        guard FileManager.default.fileExists(atPath: libraryURL.path) else {
            throw EmbeddedRDPError.runtimeMissing
        }
        guard let library = dlopen(libraryURL.path, RTLD_NOW | RTLD_LOCAL) else {
            let message = dlerror().map { String(cString: $0) } ?? "Unknown loader error"
            throw EmbeddedRDPError.loadFailed(message)
        }
        self.library = library

        let create: CreateViewFunction = try Self.symbol("RemoteDeckRDPCreateView", from: library)
        let getView: GetViewFunction = try Self.symbol("RemoteDeckRDPGetView", from: library)
        startFunction = try Self.symbol("RemoteDeckRDPStart", from: library)
        stateFunction = try Self.symbol("RemoteDeckRDPConnectionState", from: library)
        lastErrorFunction = try Self.symbol("RemoteDeckRDPLastError", from: library)
        resizeFunction = try Self.symbol("RemoteDeckRDPResize", from: library)
        focusFunction = try Self.symbol("RemoteDeckRDPFocus", from: library)
        pasteFunction = try Self.symbol("RemoteDeckRDPPaste", from: library)
        pasteFilesFunction = try Self.symbol("RemoteDeckRDPPasteFiles", from: library)
        pasteFilesAtPointFunction = try Self.symbol("RemoteDeckRDPPasteFilesAtPoint", from: library)
        destroyFunction = try Self.symbol("RemoteDeckRDPDestroy", from: library)

        guard let session = create(viewportSize.width, viewportSize.height),
              let rawView = getView(session) else {
            dlclose(library)
            throw EmbeddedRDPError.viewCreationFailed
        }
        self.session = session
        let view = Unmanaged<NSView>.fromOpaque(rawView).takeUnretainedValue()
        viewStorage = view
    }

    deinit {
        if let session {
            destroyFunction(session)
        }
        viewStorage = nil
        if let library {
            dlclose(library)
        }
    }

    func start(arguments: [String]) throws {
        let strings = arguments.map { strdup($0) }
        defer { strings.forEach { free($0) } }
        let pointers: [UnsafePointer<CChar>?] = strings.map { pointer in
            pointer.map { UnsafePointer<CChar>($0) }
        }
        let status = pointers.withUnsafeBufferPointer { buffer in
            startFunction(session, Int32(buffer.count), buffer.baseAddress)
        }
        guard status == 0 else {
            throw EmbeddedRDPError.startFailed(status)
        }
    }

    var connectionState: ConnectionState {
        ConnectionState(rawValue: stateFunction(session)) ?? .ended
    }

    var lastError: UInt32 {
        lastErrorFunction(session)
    }

    func resize(viewport: CGSize, desktop: CGSize, displayScale: Int) {
        resizeFunction(
            session,
            viewport.width,
            viewport.height,
            desktop.width,
            desktop.height,
            Double(displayScale)
        )
    }

    func focus() {
        focusFunction(session)
    }

    func paste() {
        pasteFunction(session)
    }

    func pasteFiles(_ urls: [URL]) -> Bool {
        pasteFiles(urls, at: nil)
    }

    func pasteFiles(_ urls: [URL], at point: CGPoint?) -> Bool {
        let strings = urls.map { strdup($0.path) }
        defer { strings.forEach { free($0) } }
        let pointers: [UnsafePointer<CChar>?] = strings.map { pointer in
            pointer.map { UnsafePointer<CChar>($0) }
        }
        return pointers.withUnsafeBufferPointer { buffer in
            if let point {
                return pasteFilesAtPointFunction(
                    session,
                    Int32(buffer.count),
                    buffer.baseAddress,
                    point.x,
                    point.y
                ) == 1
            }
            return pasteFilesFunction(session, Int32(buffer.count), buffer.baseAddress) == 1
        }
    }

    func close() {
        guard let session else { return }
        destroyFunction(session)
        self.session = nil
        viewStorage = nil
        if let library {
            dlclose(library)
            self.library = nil
        }
    }

    private static func symbol<T>(_ name: String, from library: UnsafeMutableRawPointer) throws -> T {
        guard let address = dlsym(library, name) else {
            throw EmbeddedRDPError.missingSymbol(name)
        }
        return unsafeBitCast(address, to: T.self)
    }
}
