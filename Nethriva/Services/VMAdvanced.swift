import AppKit
import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import Network

enum RDPRuntimeArchitecture {
    static var current: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }
    static func root(resourceURL: URL?, architecture: String = current) -> URL? {
        guard let root = resourceURL?.appendingPathComponent("FreeRDP") else { return nil }
        return architecture == "arm64" ? root : root.appendingPathComponent("x86_64")
    }
}

enum SessionKeyboardNavigation {
    static func next(ids: [UUID], selected: UUID?, offset: Int) -> UUID? {
        guard !ids.isEmpty else { return nil }
        guard let selected, let index = ids.firstIndex(of: selected) else { return offset < 0 ? ids.last : ids.first }
        return ids[((index + offset) % ids.count + ids.count) % ids.count]
    }
}

enum SSHX11Mode: String, Codable, CaseIterable, Identifiable {
    case off, untrusted, trusted
    var id: String { rawValue }
    var title: String { switch self { case .off: "Off"; case .untrusted: "Untrusted (-X)"; case .trusted: "Trusted (-Y)" } }
}

struct SSHX11Configuration: Codable, Hashable {
    var mode: SSHX11Mode = .off
    var display = ""
    static func validDisplay(_ value: String) -> Bool {
        guard value.count <= 4096, value.rangeOfCharacter(from: .controlCharacters) == nil, !value.contains(" ") else { return false }
        if value.range(of: "^:[0-9]+(\\.[0-9]+)?$", options: .regularExpression) != nil { return true }
        return value.range(of: "^/(private/)?tmp/[A-Za-z0-9._/-]+/org\\.xquartz:[0-9]+(\\.[0-9]+)?$", options: .regularExpression) != nil && !value.contains("..")
    }
    func arguments(xauthAvailable: Bool? = nil) throws -> [String] {
        guard mode != .off else { return ["-x"] }
        guard Self.validDisplay(display), xauthAvailable ?? FileManager.default.isExecutableFile(atPath: "/opt/X11/bin/xauth") else {
            throw VirtualizationError.message("Install XQuartz and configure its local DISPLAY before enabling X11 forwarding.")
        }
        return [mode == .trusted ? "-Y" : "-X", "-o", "ForwardX11Trusted=\(mode == .trusted ? "yes" : "no")", "-o", "XAuthLocation=/opt/X11/bin/xauth", "-o", "ControlMaster=no", "-o", "ControlPath=none"]
    }
    static func detectDisplay() async throws -> String {
        try await BackgroundWork.run {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl"); process.arguments = ["getenv", "DISPLAY"]
            process.standardInput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice; process.standardOutput = pipe
            try process.run(); try? pipe.fileHandleForWriting.close()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate(); DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) } } } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: timeout)
            defer { timeout.cancel(); try? pipe.fileHandleForReading.close() }
            let data = try pipe.fileHandleForReading.read(upToCount: 4097) ?? Data()
            process.waitUntilExit()
            let display = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0, data.count <= 4096, validDisplay(display) else { throw VirtualizationError.invalidConfiguration }
            return display
        }
    }
}

enum VMGuestAddress {
    static func cpu(_ cores: Int?, sockets: Int = 1) -> Int? {
        guard let cores, (1...4096).contains(cores), (1...4096).contains(sockets), cores <= 4096 / sockets else { return nil }
        return cores * sockets
    }
    static func memoryMiB(_ value: Int?, unit: String = "MiB") -> Int? {
        guard let value, value > 0 else { return nil }
        let result: Int
        switch unit.lowercased() {
        case "kib", "kb", "k": result = value / 1024
        case "b", "bytes": result = value / (1024 * 1024)
        case "gib", "gb", "g": guard value <= (1 << 20) else { return nil }; result = value * 1024
        case "mib", "mb", "m": result = value
        default: return nil
        }
        return (1...(1 << 30)).contains(result) ? result : nil
    }
    /// Host-reported addresses are untrusted. Only literal, routable guest addresses become shortcuts.
    static func usable(_ values: [String]) -> [String] {
        Array(Set(values.filter {
            if let ip = IPv4Address($0) {
                let bytes = Array(ip.rawValue)
                return bytes[0] != 0 && bytes[0] != 127 && bytes[0] < 224 && !(bytes[0] == 169 && bytes[1] == 254)
            }
            if let ip = IPv6Address($0) {
                let bytes = Array(ip.rawValue)
                if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
                    let mapped = bytes.suffix(4).map(String.init).joined(separator: ".")
                    return !usable([mapped]).isEmpty
                }
                if bytes.prefix(12).allSatisfy({ $0 == 0 }) { return false }
                return ip != .any && ip != .loopback && bytes[0] != 0xff && !(bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80)
            }
            return false
        })).sorted()
    }
    static func connection(address: String, kind: ConnectionKind, name: String) throws -> RemoteConnection {
        guard [.ssh, .rdp].contains(kind), usable([address]) == [address] else { throw VirtualizationError.invalidConfiguration }
        // Never reuse management-host credentials in a guest OS.
        return RemoteConnection(name: name, kind: kind, host: address, port: kind.defaultPort, username: "")
    }
}

enum VMSnapshotInput {
    static func name(_ value: String?) throws -> String {
        guard let value, !value.isEmpty, value.count <= 80,
              value.rangeOfCharacter(from: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).inverted) == nil else {
            throw VirtualizationError.message("Use 1–80 letters, digits, hyphens or underscores for the snapshot name.")
        }
        return value
    }
}

/// Public native-client registration metadata only. Tokens are never Codable or stored in Keychain.
struct VMFederationConfiguration: Codable, Hashable {
    var authorizationURL = ""
    var tokenURL = ""
    var clientID = ""
    var scope = "openid allatclaims"
    var resource = ""
    var subjectTokenType: String?
    var effectiveSubjectTokenType: String { subjectTokenType ?? "urn:ietf:params:oauth:token-type:jwt" }
    static let redirectURI = "nethriva-auth://oauth/callback"
    func validate() throws {
        guard ["urn:ietf:params:oauth:token-type:jwt", "urn:ietf:params:oauth:token-type:access_token"].contains(effectiveSubjectTokenType) else { throw VirtualizationError.invalidConfiguration }
        for raw in [authorizationURL, tokenURL] {
            guard let parts = URLComponents(string: raw), parts.scheme == "https", parts.host != nil,
                  parts.user == nil, parts.password == nil, parts.fragment == nil, parts.query == nil else {
                throw VirtualizationError.message("Federation endpoints must be administrator-approved HTTPS URLs without embedded credentials or query strings.")
            }
        }
        guard [clientID, scope, resource].allSatisfy({ $0.count <= 4096 && $0.rangeOfCharacter(from: .controlCharacters) == nil }),
              !clientID.isEmpty, !scope.isEmpty else { throw VirtualizationError.invalidConfiguration }
    }
}

/// Token POSTs never follow redirects, reuse browser cookies, cache responses or reveal server bodies.
final class FederationHTTP: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    init(configuration: URLSessionConfiguration = .ephemeral) { self.configuration = configuration; super.init() }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func post(_ url: URL, fields: [String: String]) async throws -> [String: Any] {
        let config = configuration
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForResource = 60
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = VirtualizationHTTP.form(fields)
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw VirtualizationError.authentication }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 512 * 1024 else { throw VirtualizationError.invalidResponse }
                data.append(byte)
            }
            guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw VirtualizationError.invalidResponse }
            return result
        } catch is CancellationError { throw CancellationError() }
        catch { throw VirtualizationError.message("Federated sign-in failed. Check the native-client registration, PKCE support, HTTPS trust, and vCenter token-exchange support.") }
    }
}

@MainActor
final class VMwareFederation: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = VMwareFederation()
    private struct Authorization { let connection: RemoteConnection; let assertion: String; let expiry: Date; let nonce: UUID }
    private var authorizations: [UUID: Authorization] = [:]
    private var expiryTasks: [UUID: Task<Void, Never>] = [:]
    private var browser: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private var epoch = UUID()
    private var signInHost: UUID? { didSet { isSigningIn = signInHost != nil } }
    @Published private(set) var isSigningIn = false
    var cachedAuthorizationCount: Int { authorizations.count }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { NSApp.keyWindow ?? NSApp.mainWindow ?? NSWindow() }
    func assertion(for connection: RemoteConnection) -> String? {
        guard let authorization = authorizations[connection.id] else { return nil }
        guard authorization.connection == connection, authorization.expiry > Date(), !CredentialAccessGate.shared.isLocked else {
            authorizations[connection.id] = nil; expiryTasks.removeValue(forKey: connection.id)?.cancel(); return nil
        }
        return authorization.assertion
    }
    func clear() {
        epoch = UUID(); authorizations.removeAll(); browser?.cancel(); browser = nil
        expiryTasks.values.forEach { $0.cancel() }; expiryTasks.removeAll()
        continuation?.resume(throwing: CancellationError()); continuation = nil
        signInHost = nil
    }
    func discard(for id: UUID) {
        authorizations[id] = nil
        expiryTasks.removeValue(forKey: id)?.cancel()
        if signInHost == id { clear() }
    }
    nonisolated static func base64URL(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    nonisolated static func callbackCode(_ url: URL, state: String) throws -> String {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme == "nethriva-auth",
              parts.host == "oauth", parts.path == "/callback", parts.fragment == nil else { throw VirtualizationError.authentication }
        let items = parts.queryItems ?? []
        guard items.filter({ $0.name == "state" }).count == 1, items.first(where: { $0.name == "state" })?.value == state,
              items.filter({ $0.name == "code" }).count == 1, !items.contains(where: { $0.name == "error" }),
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty, code.count <= 8192 else { throw VirtualizationError.authentication }
        return code
    }
    nonisolated static func bearerAssertion(_ encoded: String) throws -> String {
        guard encoded.count < 512 * 1024, let data = Data(base64Encoded: encoded),
              let xml = String(data: data, encoding: .utf8), !xml.localizedCaseInsensitiveContains("<!DOCTYPE"),
              !xml.localizedCaseInsensitiveContains("<!ENTITY") else { throw VirtualizationError.invalidResponse }
        let root = try VMXMLDocument.parse(data)
        guard root.name == "Assertion", root.attributes["Version"] == "2.0",
              root.attributes.values.contains("urn:oasis:names:tc:SAML:2.0:assertion"),
              root.descendants("SubjectConfirmation").contains(where: { $0.attributes["Method"] == "urn:oasis:names:tc:SAML:2.0:cm:bearer" }) else {
            throw VirtualizationError.message("vCenter did not issue a SAML 2.0 bearer assertion. Holder-of-key tokens are not supported by this native flow.")
        }
        // Preserve signed XML byte-for-byte. vCenter verifies the assertion when LoginByToken is called.
        return xml.replacingOccurrences(of: "^<\\?xml[^>]*\\?>\\s*", with: "", options: .regularExpression)
    }
    func signIn(connection: RemoteConnection, authorize: ((URL) async throws -> URL)? = nil,
                tokenHTTP: FederationHTTP = FederationHTTP(), vcenterHTTP: VirtualizationHTTP? = nil) async throws {
        guard !CredentialAccessGate.shared.isLocked, !isSigningIn, connection.virtualization?.platform == .vmware,
              let config = connection.virtualization?.federation else { throw VirtualizationError.invalidConfiguration }
        try config.validate()
        let epoch = epoch
        signInHost = connection.id
        defer { if self.epoch == epoch, signInHost == connection.id { signInHost = nil } }
        guard connection.virtualization?.effectiveCertificatePolicy == .systemValidation else {
            throw VirtualizationError.message("Federated sign-in requires system-validated vCenter HTTPS. Install the organization's CA through its approved process first.")
        }
        let verifier = Self.base64URL(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
        let state = UUID().uuidString + UUID().uuidString
        var url = URLComponents(string: config.authorizationURL)!
        url.queryItems = [URLQueryItem(name: "response_type", value: "code"), .init(name: "client_id", value: config.clientID),
            .init(name: "redirect_uri", value: VMFederationConfiguration.redirectURI), .init(name: "scope", value: config.scope),
            .init(name: "state", value: state), .init(name: "code_challenge", value: Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))),
            .init(name: "code_challenge_method", value: "S256")]
        if !config.resource.isEmpty { url.queryItems?.append(.init(name: "resource", value: config.resource)) }
        let callback: URL
        if let authorize { callback = try await authorize(url.url!) }
        else { callback = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let browser = ASWebAuthenticationSession(url: url.url!, callbackURLScheme: "nethriva-auth") { [weak self] callback, _ in
                    Task { @MainActor in
                        guard let self, self.epoch == epoch, let continuation = self.continuation else { return }
                        self.continuation = nil; self.browser = nil
                        if let callback { continuation.resume(returning: callback) }
                        else { continuation.resume(throwing: VirtualizationError.cancelled) }
                    }
                }
                browser.presentationContextProvider = self; browser.prefersEphemeralWebBrowserSession = true
                self.browser = browser
                if !browser.start() { self.browser = nil; self.continuation = nil; continuation.resume(throwing: VirtualizationError.cancelled) }
            }
        } onCancel: { Task { @MainActor in if self.epoch == epoch { self.clear() } } }
        }
        try Task.checkCancellation()
        guard self.epoch == epoch, !CredentialAccessGate.shared.isLocked else { throw CancellationError() }
        let code = try Self.callbackCode(callback, state: state)
        var fields = ["grant_type": "authorization_code", "client_id": config.clientID, "code": code,
            "redirect_uri": VMFederationConfiguration.redirectURI, "code_verifier": verifier]
        if !config.resource.isEmpty { fields["resource"] = config.resource }
        let tokens = try await tokenHTTP.post(URL(string: config.tokenURL)!, fields: fields)
        try Task.checkCancellation()
        guard self.epoch == epoch, !CredentialAccessGate.shared.isLocked else { throw CancellationError() }
        guard let access = tokens["access_token"] as? String, !access.isEmpty, access.count < 256 * 1024 else { throw VirtualizationError.authentication }
        let http = try vcenterHTTP ?? VirtualizationHTTP(connection: connection, rejectRedirects: true)
        defer { http.close() }
        let data = try await http.request("/api/vcenter/authentication/token", method: "POST",
            headers: ["Content-Type": "application/x-www-form-urlencoded"], body: VirtualizationHTTP.form([
                "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
                "subject_token": Data(access.utf8).base64EncodedString(),
                "subject_token_type": config.effectiveSubjectTokenType,
                "requested_token_type": "urn:ietf:params:oauth:token-type:saml2"]))
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              result["issued_token_type"] as? String == "urn:ietf:params:oauth:token-type:saml2",
              let encoded = result["access_token"] as? String else { throw VirtualizationError.invalidResponse }
        let assertion = try Self.bearerAssertion(encoded)
        try Task.checkCancellation()
        guard self.epoch == epoch, !CredentialAccessGate.shared.isLocked else { throw CancellationError() }
        let expiry = min((result["expires_in"] as? Double) ?? 120, 300)
        guard expiry > 0 else { throw VirtualizationError.authentication }
        let nonce = UUID(), id = connection.id
        authorizations[id] = Authorization(connection: connection, assertion: assertion, expiry: Date().addingTimeInterval(expiry), nonce: nonce)
        expiryTasks.removeValue(forKey: id)?.cancel()
        expiryTasks[id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(expiry)) } catch { return }
            guard let self, authorizations[id]?.nonce == nonce else { return }
            authorizations[id] = nil; expiryTasks[id] = nil
        }
    }
}
