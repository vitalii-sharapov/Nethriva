import AppKit
import CryptoKit
import Foundation
import XCTest
@testable import Nethriva

final class AdvancedConnectionTests: XCTestCase {
    @MainActor func testFederationCacheExpiresWithoutAnotherCredentialRead() async throws {
        AdvancedVMProtocol.fixture.reset(); AdvancedVMProtocol.fixture.setExpiry(0.05)
        let federation = VMwareFederation.shared; federation.clear(); defer { federation.clear() }
        var connection = RemoteConnection(name: "Federated Test", kind: .virtualization, host: "vc.example.invalid", port: 443)
        connection.virtualization = VirtualizationConfiguration(platform: .vmware, federation: VMFederationConfiguration(
            authorizationURL: "https://idp.example.invalid/authorize", tokenURL: "https://idp.example.invalid/token", clientID: "test-native-client"))
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AdvancedVMProtocol.self]
        try await federation.signIn(connection: connection, authorize: { url in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            return URL(string: "nethriva-auth://oauth/callback?state=\(items.first { $0.name == "state" }!.value!)&code=fixture-code")!
        }, tokenHTTP: FederationHTTP(configuration: config), vcenterHTTP: VirtualizationHTTP(connection: connection, configuration: config, rejectRedirects: true))
        XCTAssertEqual(federation.cachedAuthorizationCount, 1)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(federation.cachedAuthorizationCount, 0, "Expiry must erase cached authorization without waiting for another API read")
    }
    @MainActor func testFederatedBackendCannotFallbackToSavedPassword() async throws {
        AdvancedVMProtocol.fixture.reset(); VMwareFederation.shared.clear()
        var connection = RemoteConnection(name: "Federated Test", kind: .virtualization, host: "vc.example.invalid", port: 443, username: "unit-test-user")
        connection.virtualization = VirtualizationConfiguration(platform: .vmware, federation: VMFederationConfiguration(
            authorizationURL: "https://idp.example.invalid/authorize", tokenURL: "https://idp.example.invalid/token", clientID: "test-native-client"))
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AdvancedVMProtocol.self]
        let backend = try VMwareBackend(connection: connection, password: "unit-test-placeholder", http: VirtualizationHTTP(connection: connection, configuration: config))
        defer { backend.close() }
        do { _ = try await backend.machines(); XCTFail("A federated connection must not perform a password login") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Password fallback is disabled")) }
        XCTAssertTrue(AdvancedVMProtocol.fixture.methods.isEmpty)
    }
    @MainActor func testFederationUsesPKCEExchangeAndSOAPTokenWithoutSavingCredentials() async throws {
        AdvancedVMProtocol.fixture.reset()
        let federation = VMwareFederation.shared
        federation.clear(); defer { federation.clear() }
        var connection = RemoteConnection(name: "Federated Test", kind: .virtualization, host: "vc.example.invalid", port: 443)
        connection.virtualization = VirtualizationConfiguration(platform: .vmware, federation: VMFederationConfiguration(
            authorizationURL: "https://idp.example.invalid/authorize", tokenURL: "https://idp.example.invalid/token", clientID: "test-native-client"))
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AdvancedVMProtocol.self]
        let oauth = FederationHTTP(configuration: config)
        let vcConfig = URLSessionConfiguration.ephemeral; vcConfig.protocolClasses = [AdvancedVMProtocol.self]
        let http = try VirtualizationHTTP(connection: connection, configuration: vcConfig, rejectRedirects: true)
        try await federation.signIn(connection: connection, authorize: { url in
            let fields = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(fields.first(where: { $0.name == "code_challenge_method" })?.value, "S256")
            AdvancedVMProtocol.fixture.setChallenge(fields.first(where: { $0.name == "code_challenge" })?.value ?? "")
            let state = try XCTUnwrap(fields.first(where: { $0.name == "state" })?.value)
            return URL(string: "nethriva-auth://oauth/callback?state=\(state)&code=fixture-code")!
        }, tokenHTTP: oauth, vcenterHTTP: http)
        XCTAssertNotNil(federation.assertion(for: connection))
        var changed = connection; changed.host = "other.example.invalid"
        XCTAssertNil(federation.assertion(for: changed))
        // A scope mismatch invalidates cached authorization rather than retargeting it.
        try await federation.signIn(connection: connection, authorize: { url in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            AdvancedVMProtocol.fixture.setChallenge(items.first { $0.name == "code_challenge" }!.value!)
            return URL(string: "nethriva-auth://oauth/callback?state=\(items.first { $0.name == "state" }!.value!)&code=fixture-code")!
        }, tokenHTTP: oauth, vcenterHTTP: try VirtualizationHTTP(connection: connection, configuration: vcConfig, rejectRedirects: true))
        let backendHTTP = try VirtualizationHTTP(connection: connection, configuration: vcConfig)
        let backend = try VMwareBackend(connection: connection, password: nil, http: backendHTTP)
        defer { backend.close() }
        _ = try await backend.machines()
        XCTAssertTrue(AdvancedVMProtocol.fixture.pkceVerified)
        XCTAssertTrue(AdvancedVMProtocol.fixture.soapBearerVerified)
        XCTAssertFalse(AdvancedVMProtocol.fixture.methods.contains("Login"))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(connection), as: UTF8.self).contains("fixture-saml"))
        federation.clear(); XCTAssertNil(federation.assertion(for: connection))
    }
    @MainActor func testVMwareSnapshotsUseConfirmedItemIdentityAndNoRecursiveDeletion() async throws {
        AdvancedVMProtocol.fixture.reset()
        var connection = RemoteConnection(name: "Test Host", kind: .virtualization, host: "vc.example.invalid", port: 443, username: "unit-test-user")
        connection.virtualization = VirtualizationConfiguration(platform: .vmware)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AdvancedVMProtocol.self]
        let backend = try VMwareBackend(connection: connection, password: "unit-test-placeholder", http: VirtualizationHTTP(connection: connection, configuration: config))
        defer { backend.close() }
        let machines = try await backend.machines()
        let vm = try XCTUnwrap(machines.first)
        var progress: [VMTaskProgress] = []; backend.taskProgress = { progress.append($0) }
        let snapshots = try await backend.snapshots(for: vm)
        XCTAssertEqual(snapshots.map(\.id), ["snapshot-1"])
        try await backend.snapshot(.create, vm: vm, snapshot: nil, name: "before_patch")
        try await backend.snapshot(.delete, vm: vm, snapshot: snapshots[0], name: nil)
        try await backend.snapshot(.revert, vm: vm, snapshot: snapshots[0], name: nil)
        XCTAssertTrue(AdvancedVMProtocol.fixture.safeSnapshotFlags)
        XCTAssertEqual(progress.last?.percent, 100)
        let before = AdvancedVMProtocol.fixture.methods.filter { $0.hasSuffix("Snapshot_Task") }.count
        do {
            try await backend.snapshot(.delete, vm: vm, snapshot: VMSnapshot(id: "snapshot-missing", name: "Missing"), name: nil)
            XCTFail("Stale snapshot must not be changed")
        } catch {}
        XCTAssertEqual(AdvancedVMProtocol.fixture.methods.filter { $0.hasSuffix("Snapshot_Task") }.count, before)
    }
    func testGuestAddressesAndCredentialFreeShortcuts() throws {
        XCTAssertEqual(VMGuestAddress.usable(["192.0.2.10", "192.0.2.10", "2001:db8::10", "127.0.0.1", "::1", "0.0.0.0", "169.254.1.1", "fe80::1", "ff02::1", "guest.example.invalid", "192.0.2.10\n"]), ["192.0.2.10", "2001:db8::10"])
        for kind: ConnectionKind in [.ssh, .rdp] {
            let connection = try VMGuestAddress.connection(address: "192.0.2.10", kind: kind, name: "Test Guest")
            XCTAssertEqual(connection.username, ""); XCTAssertNil(connection.credentialProfileID)
            XCTAssertNil(connection.rdpDomain); XCTAssertEqual(connection.port, kind.defaultPort)
        }
        XCTAssertThrowsError(try VMGuestAddress.connection(address: "guest.example.invalid", kind: .ssh, name: "Test"))
        XCTAssertTrue(VMGuestAddress.usable(["::ffff:127.0.0.1", "::ffff:169.254.1.1", "::2"]).isEmpty)
        XCTAssertThrowsError(try VMGuestAddress.connection(address: "192.0.2.10", kind: .telnet, name: "Test"))
    }
    func testSnapshotNamesAndProgressAreBounded() throws {
        XCTAssertEqual(try VMSnapshotInput.name("before_patch-1"), "before_patch-1")
        for name in ["", "a\nb", "a'b", "-option value", String(repeating: "x", count: 81)] { XCTAssertThrowsError(try VMSnapshotInput.name(name)) }
        XCTAssertEqual(VMTaskProgress("Running", percent: 200).percent, 100)
        XCTAssertEqual(VMTaskProgress("Running", percent: -1).percent, 0)
        XCTAssertNil(VMTaskProgress("Running").percent)
    }
    func testHostResourceSizesCannotOverflowAndUnitsAreRespected() {
        XCTAssertNil(VMGuestAddress.cpu(Int.max, sockets: Int.max))
        XCTAssertNil(VMGuestAddress.memoryMiB(Int.max, unit: "GiB"))
        XCTAssertEqual(VMGuestAddress.memoryMiB(4096, unit: "MiB"), 4096)
        XCTAssertEqual(VMGuestAddress.memoryMiB(4, unit: "GiB"), 4096)
        XCTAssertEqual(VMGuestAddress.memoryMiB(4_194_304, unit: "KiB"), 4096)
        XCTAssertEqual(VMGuestAddress.cpu(2, sockets: 2), 4)
    }
    func testX11RequiresLocalDisplayAndIsolatesMaster() throws {
        XCTAssertEqual(try SSHX11Configuration().arguments(xauthAvailable: false), ["-x"])
        for display in ["remote.example.invalid:0", "192.0.2.10:0", ":0\n", "DISPLAY=:0", "/tmp/../bad/org.xquartz:0", "/tmp/foo';id;/org.xquartz:0"] { XCTAssertFalse(SSHX11Configuration.validDisplay(display)) }
        XCTAssertTrue(SSHX11Configuration.validDisplay("/private/tmp/com.apple.launchd.test/org.xquartz:0"))
        for mode: SSHX11Mode in [.trusted, .untrusted] {
            let config = SSHX11Configuration(mode: mode, display: ":0")
            let args = try config.arguments(xauthAvailable: true)
            XCTAssertTrue(args.contains(mode == .trusted ? "-Y" : "-X"))
            XCTAssertTrue(args.contains("ControlMaster=no")); XCTAssertTrue(args.contains("ControlPath=none"))
            XCTAssertTrue(args.contains("ForwardX11Trusted=\(mode == .trusted ? "yes" : "no")"))
            XCTAssertThrowsError(try config.arguments(xauthAvailable: false))
        }
        var connection = RemoteConnection(name: "Test", kind: .ssh, host: "ssh.example.invalid")
        connection.sshX11 = SSHX11Configuration(mode: .untrusted, display: ":0")
        XCTAssertEqual(try JSONDecoder().decode(RemoteConnection.self, from: JSONEncoder().encode(connection)).sshX11, connection.sshX11)
        XCTAssertTrue(try SFTPChannel.arguments(for: connection).contains("ForwardX11=no"))
    }
    func testSessionKeyboardWrappingAndEmptySelection() {
        let ids = [UUID(), UUID(), UUID()]
        XCTAssertNil(SessionKeyboardNavigation.next(ids: [], selected: nil, offset: 1))
        XCTAssertEqual(SessionKeyboardNavigation.next(ids: ids, selected: ids[2], offset: 1), ids[0])
        XCTAssertEqual(SessionKeyboardNavigation.next(ids: ids, selected: ids[0], offset: -1), ids[2])
        XCTAssertEqual(SessionKeyboardNavigation.next(ids: ids, selected: nil, offset: -1), ids[2])
    }
    @MainActor func testFederationCallbackRejectsCSRFAndDuplicateValues() throws {
        XCTAssertEqual(try VMwareFederation.callbackCode(URL(string: "nethriva-auth://oauth/callback?state=fixture&code=test-code")!, state: "fixture"), "test-code")
        for raw in ["nethriva-auth://oauth/callback?state=wrong&code=test-code", "nethriva-auth://oauth/callback?state=fixture&state=fixture&code=test-code", "nethriva-auth://other/callback?state=fixture&code=test-code", "nethriva-auth://oauth/callback?state=fixture&code=test-code&error=denied", "https://oauth/callback?state=fixture&code=test-code"] {
            XCTAssertThrowsError(try VMwareFederation.callbackCode(URL(string: raw)!, state: "fixture"))
        }
        XCTAssertEqual(VMwareFederation.base64URL(Data([0xfb, 0xff])), "-_8")
    }
    @MainActor func testFederationOnlyAcceptsBoundedBearerAssertionAndTrustedEndpoints() throws {
        let xml = "<saml:Assertion xmlns:saml='urn:oasis:names:tc:SAML:2.0:assertion' Version='2.0'><saml:Subject><saml:SubjectConfirmation Method='urn:oasis:names:tc:SAML:2.0:cm:bearer'/></saml:Subject></saml:Assertion>"
        XCTAssertEqual(try VMwareFederation.bearerAssertion(Data(xml.utf8).base64EncodedString()), xml)
        XCTAssertThrowsError(try VMwareFederation.bearerAssertion(Data(xml.replacingOccurrences(of: "cm:bearer", with: "cm:holder-of-key").utf8).base64EncodedString()))
        XCTAssertThrowsError(try VMwareFederation.bearerAssertion(Data("<!DOCTYPE x [<!ENTITY a 'bad'>]>\(xml)".utf8).base64EncodedString()))
        XCTAssertThrowsError(try VMwareFederation.bearerAssertion("not-base64"))
        var config = VMFederationConfiguration(authorizationURL: "https://idp.example.invalid/authorize", tokenURL: "https://idp.example.invalid/token", clientID: "test-native-client")
        try config.validate()
        config.tokenURL = "https://user:password@idp.example.invalid/token"
        XCTAssertThrowsError(try config.validate())
        config.tokenURL = "http://idp.example.invalid/token"
        XCTAssertThrowsError(try config.validate())
    }
    func testArchitectureSelectionDoesNotLoadArmRuntimeOnIntel() throws {
        let root = URL(fileURLWithPath: "/synthetic/resources")
        XCTAssertEqual(RDPRuntimeArchitecture.root(resourceURL: root, architecture: "arm64")?.path, "/synthetic/resources/FreeRDP")
        XCTAssertEqual(RDPRuntimeArchitecture.root(resourceURL: root, architecture: "x86_64")?.path, "/synthetic/resources/FreeRDP/x86_64")
        XCTAssertNil(RDPRuntimeArchitecture.root(resourceURL: nil))
    }
    func testSignedManifestRejectsTamperingAndUntrustedAssetURLs() throws {
        let key = Curve25519.Signing.PrivateKey()
        let asset = UpdateManifest.Asset(architecture: "arm64", url: "https://github.com/vitalii-sharapov/Nethriva/releases/download/v0.13.0/Nethriva-0.13.0-macOS-arm64.zip", sha256: String(repeating: "a", count: 64), size: 100)
        let manifest = UpdateManifest(schema: 1, version: "0.13.0", assets: [asset])
        let data = try JSONEncoder().encode(manifest), signature = try key.signature(for: data)
        XCTAssertEqual(try UpdateValidation.verify(data, signature: signature, publicKey: key.publicKey.rawRepresentation), manifest)
        XCTAssertThrowsError(try UpdateValidation.verify(data + Data([0]), signature: signature, publicKey: key.publicKey.rawRepresentation))
        XCTAssertThrowsError(try UpdateValidation.verify(data, signature: signature, publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation))
        for raw in ["http://github.com/vitalii-sharapov/Nethriva/releases/download/v0.13.0/app.zip", "https://github.com/other/Nethriva/releases/download/v0.13.0/app.zip", "https://github.com/vitalii-sharapov/Nethriva/releases/download/../app.zip", "https://github.com/vitalii-sharapov/Nethriva/releases/download/v0.13.0/app.zip?token=bad"] { XCTAssertNil(UpdateValidation.assetURL(raw)) }
        var invalid = manifest; invalid.assets[0].url = "https://other.example.invalid/app.zip"
        let bad = try JSONEncoder().encode(invalid)
        XCTAssertThrowsError(try UpdateValidation.verify(bad, signature: key.signature(for: bad), publicKey: key.publicKey.rawRepresentation))
        XCTAssertTrue(UpdateValidation.newer("v0.13.0", than: "0.12.1"))
        XCTAssertFalse(UpdateValidation.newer("0.12.1", than: "0.13.0"))
        XCTAssertFalse(UpdateValidation.newer("0.13.0", than: "0.13.0"))
        XCTAssertNil(UpdateValidation.version("0.13.0-beta"))
    }
    func testVerifiedArchiveIsPrivateQuarantinedAndCannotOverwrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Nethriva-update-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("synthetic.zip")
        let source = URL(string: "https://github.com/vitalii-sharapov/Nethriva/releases/download/v0.13.0/Nethriva-0.13.0-macOS-arm64.zip")!
        let data = Data("synthetic-update-not-an-app".utf8)
        try UpdateArchiveWriter.write(data, to: file, source: source)
        XCTAssertEqual(try Data(contentsOf: file), data)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        let properties = try (file as NSURL).resourceValues(forKeys: [.quarantinePropertiesKey])
        XCTAssertNotNil(properties[.quarantinePropertiesKey])
        XCTAssertFalse((properties[.quarantinePropertiesKey] as? [String: Any] ?? [:]).isEmpty)
        XCTAssertThrowsError(try UpdateArchiveWriter.write(Data("replacement".utf8), to: file, source: source))
        XCTAssertEqual(try Data(contentsOf: file), data)
        let link = root.appendingPathComponent("symlink.zip")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try UpdateArchiveWriter.write(data, to: link, source: source))
    }
    func testVMwareSnapshotTreeAndDetailsWithNamespacePrefixes() throws {
        let xml = """
        <RetrievePropertiesExResponse><returnval><objects><obj>vm-1</obj>
        <propSet><name>name</name><val>Test Guest</val></propSet>
        <propSet><name>runtime.host</name><val>host-1</val></propSet>
        <propSet><name>guest.ipAddress</name><val>192.0.2.10</val></propSet>
        <propSet><name>config.guestFullName</name><val>Test Linux</val></propSet>
        <propSet><name>config.hardware.numCPU</name><val>4</val></propSet>
        <propSet><name>config.hardware.memoryMB</name><val>4096</val></propSet></objects></returnval></RetrievePropertiesExResponse>
        """
        let vm = try XCTUnwrap(VMwareBackend.parseMachines(VMXMLDocument.parse(Data(xml.utf8))).first)
        XCTAssertEqual(vm.cpuCount, 4); XCTAssertEqual(vm.memoryMiB, 4096); XCTAssertEqual(vm.guestIPs, ["192.0.2.10"])
        XCTAssertEqual(vm.node, "host-1"); XCTAssertEqual(vm.operatingSystem, "Test Linux")
        let tree = "<s:result xmlns:s='urn:test'><currentSnapshot>snapshot-2</currentSnapshot><rootSnapshotList><snapshot>snapshot-1</snapshot><name>First</name><createTime>2026-01-01</createTime><childSnapshotList><snapshot>snapshot-2</snapshot><name>Second</name></childSnapshotList></rootSnapshotList></s:result>"
        let snapshots = try VMwareBackend.parseSnapshots(VMXMLDocument.parse(Data(tree.utf8)))
        XCTAssertEqual(snapshots.map(\.id), ["snapshot-1", "snapshot-2"])
        XCTAssertTrue(snapshots[1].current)
    }
}

private final class AdvancedVMProtocol: URLProtocol {
    static let assertion = "<saml:Assertion xmlns:saml='urn:oasis:names:tc:SAML:2.0:assertion' Version='2.0' ID='fixture-saml'><saml:Subject><saml:SubjectConfirmation Method='urn:oasis:names:tc:SAML:2.0:cm:bearer'/></saml:Subject></saml:Assertion>"
    static let fixture = Fixture()
    final class Fixture: @unchecked Sendable {
        private let lock = NSLock()
        private var _methods: [String] = []
        private var challenge = ""
        private var pkce = false, soap = false, safeFlags = true
        private var expiry: Double = 120
        var lifetime: Double { lock.withLock { expiry } }
        var methods: [String] { lock.withLock { _methods } }
        var pkceVerified: Bool { lock.withLock { pkce } }
        var soapBearerVerified: Bool { lock.withLock { soap } }
        var safeSnapshotFlags: Bool { lock.withLock { safeFlags } }
        func reset() { lock.withLock { _methods = []; challenge = ""; pkce = false; soap = false; safeFlags = true; expiry = 120 } }
        func setExpiry(_ value: Double) { lock.withLock { expiry = value } }
        func setChallenge(_ value: String) { lock.withLock { challenge = value } }
        func token(_ verifier: String) { lock.withLock { pkce = VMwareFederation.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) == challenge } }
        func record(_ method: String, root: VMXMLNode) {
            lock.withLock {
                _methods.append(method)
                if method == "LoginByToken" { soap = !root.descendants("Security").isEmpty && root.descendants("Assertion").first?.attributes["ID"] == "fixture-saml" }
                if method == "CreateSnapshot_Task" { safeFlags = safeFlags && root.descendants("memory").first?.text == "false" && root.descendants("quiesce").first?.text == "false" }
                if method == "RemoveSnapshot_Task" { safeFlags = safeFlags && root.descendants("removeChildren").first?.text == "false" }
            }
        }
    }
    override class func canInit(with request: URLRequest) -> Bool { ["vc.example.invalid", "idp.example.invalid"].contains(request.url?.host ?? "") }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream, body.isEmpty {
                stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count >= 0, body.count + max(0, count) <= 512 * 1024 else { throw URLError(.badServerResponse) }
                    if count == 0 { break }; body.append(contentsOf: buffer.prefix(count))
                }
            }
            let result: Data
            if request.url?.path == "/token" {
                let fields = URLComponents(string: "https://idp.example.invalid/?" + String(decoding: body, as: UTF8.self))?.queryItems ?? []
                Self.fixture.token(fields.first(where: { $0.name == "code_verifier" })?.value ?? "")
                result = try JSONSerialization.data(withJSONObject: ["access_token": "unit-test-token", "token_type": "Bearer"])
            } else if request.url?.path == "/api/vcenter/authentication/token" {
                result = try JSONSerialization.data(withJSONObject: ["access_token": Data(Self.assertion.utf8).base64EncodedString(), "issued_token_type": "urn:ietf:params:oauth:token-type:saml2", "expires_in": Self.fixture.lifetime])
            } else {
                let root = try VMXMLDocument.parse(body)
                let method = root.child("Body")?.children.first?.name ?? ""
                Self.fixture.record(method, root: root)
                let content: String
                switch method {
                case "RetrieveServiceContent": content = "<returnval><sessionManager>session</sessionManager><propertyCollector>collector</propertyCollector><viewManager>views</viewManager><rootFolder>root</rootFolder><about><apiType>VirtualCenter</apiType><apiVersion>8.0.3</apiVersion></about></returnval>"
                case "CreateContainerView": content = "<returnval>view-1</returnval>"
                case "Login", "LoginByToken", "DestroyView", "Logout": content = ""
                case "CreateSnapshot_Task", "RemoveSnapshot_Task", "RevertToSnapshot_Task": content = "<returnval>task-1</returnval>"
                case "RetrievePropertiesEx" where !root.descendants("pathSet").filter({ $0.text == "snapshot" }).isEmpty:
                    content = "<returnval><objects><propSet><name>snapshot</name><val><rootSnapshotList><snapshot>snapshot-1</snapshot><name>Before</name></rootSnapshotList></val></propSet></objects></returnval>"
                case "RetrievePropertiesEx" where !root.descendants("pathSet").filter({ $0.text == "info.state" }).isEmpty:
                    content = "<returnval><objects><propSet><name>info.state</name><val>success</val></propSet><propSet><name>info.progress</name><val>100</val></propSet></objects></returnval>"
                case "RetrievePropertiesEx": content = "<returnval><objects><obj>vm-1</obj><propSet><name>name</name><val>Test Guest</val></propSet></objects></returnval>"
                default: throw URLError(.unsupportedURL)
                }
                result = Data("<soap:Envelope xmlns:soap='http://schemas.xmlsoap.org/soap/envelope/'><soap:Body><\(method)Response>\(content)</\(method)Response></soap:Body></soap:Envelope>".utf8)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
