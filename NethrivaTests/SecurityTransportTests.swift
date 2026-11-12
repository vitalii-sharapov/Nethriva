import AppKit
import Darwin
import Network
import WebKit
import XCTest
@testable import Nethriva

final class SecurityTransportTests: XCTestCase {
    func testRDPRejectsControlCharactersAndGatewayOptionInjection() throws {
        let base = RemoteConnection(name: "Synthetic", kind: .rdp, host: "desktop.example.invalid")
        for value in ["line\nbreak", "nul\0value", "tab\tvalue"] {
            var changed = base; changed.username = value
            XCTAssertThrowsError(try FreeRDPArgumentsBuilder.arguments(for: changed, password: nil))
            XCTAssertThrowsError(try FreeRDPArgumentsBuilder.arguments(for: base, password: value))
        }
        var gateway = base; gateway.rdpGatewayHost = "gateway.example.invalid,usage-method:detect"
        XCTAssertThrowsError(try FreeRDPArgumentsBuilder.arguments(for: gateway, password: nil))
        gateway.rdpGatewayHost = "gateway.example.invalid"; gateway.rdpGatewayUsername = "synthetic,p:injected"
        XCTAssertThrowsError(try FreeRDPArgumentsBuilder.arguments(for: gateway, password: nil))
        var ipv6 = base; ipv6.host = "2001:db8::1"
        XCTAssertTrue(try FreeRDPArgumentsBuilder.arguments(for: ipv6, password: nil).contains("/v:[2001:db8::1]:3389"))
    }
    func testRDPDefaultsRequireNLAAndCertificateValidation() throws {
        let connection = RemoteConnection(name: "Synthetic desktop", kind: .rdp, host: "desktop.example.invalid")
        let arguments = try FreeRDPArgumentsBuilder.arguments(for: connection, password: nil)
        XCTAssertTrue(arguments.contains("/sec:nla"))
        XCTAssertTrue(arguments.contains("/cert:deny"))
        XCTAssertFalse(arguments.contains("/sec:rdp"))
        XCTAssertFalse(arguments.contains("/cert:ignore"))
        XCTAssertTrue(arguments.contains("-clipboard"), "Local clipboard access requires opt-in")
        let decoded = try JSONDecoder().decode(RemoteConnection.self, from: JSONEncoder().encode(connection))
        XCTAssertNil(decoded.rdpSecurityMode)
        XCTAssertEqual(decoded.effectiveRDPSecurityMode, .nla)
    }

    @MainActor func testUnverifiedRDPCompatibilityNeedsExplicitSessionApproval() throws {
        var connection = RemoteConnection(name: "Synthetic desktop", kind: .rdp, host: "desktop.example.invalid")
        XCTAssertFalse(ConnectionSecurityConsent.requiresRDPConfirmation(connection))
        connection.rdpSecurityMode = .legacyRDP
        XCTAssertTrue(ConnectionSecurityConsent.requiresRDPConfirmation(connection))
        XCTAssertTrue(try FreeRDPArgumentsBuilder.arguments(for: connection, password: nil).contains("/sec:rdp"))
        connection.rdpSecurityMode = .tls
        XCTAssertFalse(ConnectionSecurityConsent.requiresRDPConfirmation(connection))
        XCTAssertTrue(try FreeRDPArgumentsBuilder.arguments(for: connection, password: nil).contains("/sec:tls"))
        connection.rdpCertificatePolicy = .ignore
        XCTAssertTrue(ConnectionSecurityConsent.requiresRDPConfirmation(connection))
    }

    func testSavedConsoleCredentialsRequireProtectedTransport() {
        for kind in [ConnectionKind.vnc, .spice] {
            var connection = RemoteConnection(name: "Synthetic console", kind: kind, host: "console.example.invalid")
            XCTAssertFalse(ConsoleCredentialPolicy.permitsAutomaticCredentials(for: connection))
            connection.virtualization = VirtualizationConfiguration(consoleTransport: .tcp)
            XCTAssertFalse(ConsoleCredentialPolicy.permitsAutomaticCredentials(for: connection))
            connection.virtualization?.consoleTransport = .tls
            XCTAssertTrue(ConsoleCredentialPolicy.permitsAutomaticCredentials(for: connection))
            connection.virtualization?.consoleTransport = .webSocket
            XCTAssertTrue(ConsoleCredentialPolicy.permitsAutomaticCredentials(for: connection))
            connection.virtualization?.consoleTransport = .tcp
            connection.virtualization?.tunnelConnectionID = UUID()
            XCTAssertTrue(ConsoleCredentialPolicy.permitsAutomaticCredentials(for: connection))
        }
    }

    func testCertificateStorageRejectsLinksAndPublicFoldersWithoutChangingThem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Nethriva-Certificate-Test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target"), link = root.appendingPathComponent("link")
        try RDPCertificateStorage.prepare(target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try RDPCertificateStorage.prepare(link))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        XCTAssertThrowsError(try RDPCertificateStorage.prepare(target))
        let mode = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o755, "Unsafe existing paths must not be chmodded behind the user's back")
        XCTAssertNoThrow(try RDPCertificateStorage.prepare(target, requiresPrivateAccess: false))
    }

    @MainActor func testUnencryptedVNCWithholdsSavedCredentialsWhenServerRequestsPlain() async throws {
        let server = try CredentialProbeVNC()
        defer { server.stop() }
        let listening = expectation(description: "Loopback fixture ready")
        server.start { listening.fulfill() }
        await fulfillment(of: [listening], timeout: 5)
        let port = try XCTUnwrap(server.listener.port)
        let requested = expectation(description: "Raw console requires deliberate credential entry")
        let bridge = VMConsoleWebBridge(), configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let resources = try XCTUnwrap(Bundle.main.resourceURL?.appendingPathComponent("Consoles"))
        configuration.setURLSchemeHandler(VMConsoleAssets(root: resources), forURLScheme: "nethriva-console")
        configuration.userContentController.add(bridge, name: "vmConsole")
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = web; bridge.webView = web; web.navigationDelegate = bridge
        let http = try VirtualizationHTTP(connection: RemoteConnection(name: "Synthetic", kind: .vnc, host: "127.0.0.1", port: Int(port.rawValue)))
        defer {
            bridge.stop(); http.close(); web.navigationDelegate = nil
            configuration.userContentController.removeScriptMessageHandler(forName: "vmConsole"); window.contentView = nil
        }
        bridge.onCredentials = { requested.fulfill() }
        bridge.configure(VMConsoleDescriptor(renderer: .vnc, host: "127.0.0.1", port: Int(port.rawValue),
            password: "SYNTHETIC-NOT-A-REAL-SECRET", username: "synthetic-user"), http: http,
            options: ["fit": true, "viewOnly": true, "clipboard": false])
        web.load(URLRequest(url: URL(string: "nethriva-console://bundle/console.html")!))
        await fulfillment(of: [requested], timeout: 10)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThan(server.received.count, 0, "The test must exercise the actual handshake")
        XCTAssertNil(server.received.range(of: Data("SYNTHETIC-NOT-A-REAL-SECRET".utf8)))
        XCTAssertNil(server.received.range(of: Data("synthetic-user".utf8)))
        bridge.credentials("SYNTHETIC-NOT-A-REAL-SECRET") // Native API must also refuse without one-time permission.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(server.received.range(of: Data("SYNTHETIC-NOT-A-REAL-SECRET".utf8)))
    }

    @MainActor func testBundledRDPCanvasLoadsInApplicationHostWithoutConnecting() throws {
#if arch(arm64)
        let session = try EmbeddedRDPSession(viewportSize: CGSize(width: 640, height: 480))
        XCTAssertEqual(session.connectionState, .idle)
        XCTAssertGreaterThan(session.view.frame.width, 0)
        session.close()
#else
        throw XCTSkip("The bundled native runtime is arm64 only")
#endif
    }

    @MainActor func testBundledNativeVerifierRejectsMalformedCertificatesAndHasSecurityABI() throws {
#if arch(arm64)
        let libraryURL = try XCTUnwrap(Bundle.main.resourceURL?.appendingPathComponent("FreeRDP/Frameworks/libNethrivaRDP.dylib"))
        let library = try XCTUnwrap(dlopen(libraryURL.path, RTLD_NOW | RTLD_LOCAL))
        defer { dlclose(library) }
        XCTAssertNotNil(dlsym(library, "NethrivaRDPSetConfigPath"), "The actual runtime must include the new security ABI")
        typealias Verify = @convention(c) (UnsafePointer<UInt8>?, Int, UnsafePointer<CChar>?) -> Int32
        let symbol = try XCTUnwrap(dlsym(library, "NethrivaRDPVerifySystemCertificate"))
        let verify = unsafeBitCast(symbol, to: Verify.self)
        XCTAssertEqual(verify(nil, 0, nil), 0)
        for count in 1...512 {
            let data = Data(repeating: UInt8(truncatingIfNeeded: count), count: count)
            let status = data.withUnsafeBytes { bytes in
                "host.example.invalid".withCString { verify(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, $0) }
            }
            XCTAssertEqual(status, 0)
        }
        let one: [UInt8] = [0]
        one.withUnsafeBufferPointer { bytes in
            XCTAssertEqual(verify(bytes.baseAddress, 1024 * 1024 + 1, nil), 0)
        }
#else
        throw XCTSkip("The bundled native runtime is arm64 only; this is not Intel RDP certification")
#endif
    }
}

private final class CredentialProbeVNC: @unchecked Sendable {
    let listener: NWListener
    private let queue = DispatchQueue(label: "nethriva.synthetic.credential-probe")
    private let lock = NSLock()
    private var connection: NWConnection?, input = Data(), captured = Data(), stage = 0
    var received: Data { lock.withLock { captured } }
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start(ready: @escaping () -> Void) {
        listener.stateUpdateHandler = { state in if case .ready = state { ready() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                if case .ready = state { self?.write(Data("RFB 003.008\n".utf8)); self?.read() }
            }
            connection.start(queue: self.queue)
        }
        listener.start(queue: queue)
    }
    private func write(_ data: Data) { connection?.send(content: data, completion: .contentProcessed { _ in }) }
    private func read() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data {
                self.lock.withLock { self.captured += data }
                self.input += data
                guard self.input.count <= 65536 else { self.stop(); return }
                if self.stage == 0, self.input.count >= 12 { self.input.removeFirst(12); self.stage = 1; self.write(Data([1, 19])) }
                if self.stage == 1, self.input.count >= 1 { self.input.removeFirst(); self.stage = 2; self.write(Data([0, 2])) }
                if self.stage == 2, self.input.count >= 2 { self.input.removeFirst(2); self.stage = 3; self.write(Data([0, 1, 0, 0, 1, 0])) }
                if self.stage == 3, self.input.count >= 4 { self.input.removeFirst(4); self.stage = 4 }
            }
            if !complete && error == nil { self.read() }
        }
    }
    func stop() { listener.cancel(); connection?.cancel() }
}
