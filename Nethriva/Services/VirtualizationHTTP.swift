import AppKit
import CryptoKit
import Foundation
import Security

/// Certificate authority delegated by an authenticated VMware ticket. Never persisted.
struct VMConsoleCertificatePin: Sendable {
    enum Algorithm: Sendable { case sha256, sha1 }
    let algorithm: Algorithm
    let fingerprints: Set<String>

    static func normalize(_ value: String, algorithm: Algorithm) -> String? {
        let compact = value.replacingOccurrences(of: ":", with: "").lowercased()
        let count = algorithm == .sha256 ? 64 : 40
        guard compact.count == count, compact.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        return compact
    }
    func matches(_ certificate: Data) -> Bool {
        let digest: String
        switch algorithm {
        case .sha256: digest = SHA256.hash(data: certificate).map { String(format: "%02x", $0) }.joined()
        case .sha1: digest = Insecure.SHA1.hash(data: certificate).map { String(format: "%02x", $0) }.joined()
        }
        return fingerprints.contains(digest)
    }
}

/// Deliberately contains no endpoint, ticket, certificate bytes, or server text.
enum VMConsoleTrustResult: Sendable {
    case notChallenged, systemTrust, pinVerified, pinMismatch, endpointMismatch, missingCertificate, unexpectedAuthentication, redirectRejected

    func failureMessage(_ error: Error?) -> String {
        let value = error as NSError?
        let code = value?.domain == NSURLErrorDomain ? value?.code : nil
        let detail = code.map { " (network code \($0))" } ?? ""
        let reason: String
        switch self {
        case .pinMismatch:
            reason = "The ESXi certificate does not match the identity supplied by the VMware ticket. Check the host certificate recorded in vCenter; do not bypass this mismatch."
        case .endpointMismatch:
            reason = "The TLS challenge does not match the ESXi host and port supplied by the VMware ticket."
        case .missingCertificate:
            reason = "The VMware console TLS challenge did not provide a server certificate."
        case .unexpectedAuthentication:
            reason = "The VMware console requested additional HTTP authentication instead of accepting its ticket. Check console permissions and any proxy."
        case .redirectRejected:
            reason = "The VMware console redirected its single-use ticket. Redirects are blocked to prevent ticket disclosure; check the console endpoint or proxy."
        case .systemTrust where code.map({ [NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
                                           NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
                                           NSURLErrorSecureConnectionFailed].contains($0) }) == true:
            reason = "The VMware ticket supplied no supported certificate identity and macOS could not validate the ESXi TLS connection. Check the ESXi certificate trust and ticket thumbprint configuration."
        case .pinVerified:
            reason = "The ESXi certificate matched the VMware ticket, but the console connection failed afterward. Check ticket expiry, console permissions, and any proxy."
        default:
            if code == NSURLErrorSecureConnectionFailed {
                reason = "The VMware console TLS handshake failed before a certificate could be verified. Check ESXi TLS compatibility and any proxy."
            } else {
                reason = "The VMware console could not connect. Check ESXi DNS, console-port reachability, permissions, and any proxy."
            }
        }
        return reason + detail + " Reconnect for a fresh ticket."
    }
}

/// Ephemeral, per-host sessions prevent tokens and cookies entering a shared browser or disk cache.
final class VirtualizationHTTP: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    let origin: URL
    let policy: RDPCertificatePolicy
    private let ownerID: UUID
    private let configuration: URLSessionConfiguration
    private let certificatePin: VMConsoleCertificatePin?
    private let ticketTransport: Bool
    private let rejectRedirects: Bool
    private let trustLock = NSLock()
    private var trustResult: VMConsoleTrustResult = .notChallenged

    private func recordTrust(_ result: VMConsoleTrustResult) {
        trustLock.lock(); defer { trustLock.unlock() }
        trustResult = result
    }
    func consoleFailureMessage(_ error: Error?) -> String {
        trustLock.lock(); let result = trustResult; trustLock.unlock()
        return result.failureMessage(error)
    }
    private lazy var session: URLSession = {
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    init(connection: RemoteConnection, configuration: URLSessionConfiguration = .ephemeral, rejectRedirects: Bool = false) throws {
        origin = try VMInput.endpoint(for: connection)
        ownerID = connection.id
        policy = connection.virtualization?.effectiveCertificatePolicy ?? .systemValidation
        self.configuration = configuration
        certificatePin = nil
        ticketTransport = false
        self.rejectRedirects = rejectRedirects
        super.init()
    }

    /// Console transport has no API cookies, HTTP credentials, or automatic redirects.
    init(consoleURL: URL, certificatePin: VMConsoleCertificatePin?, configuration: URLSessionConfiguration = .ephemeral) throws {
        guard let components = URLComponents(url: consoleURL, resolvingAgainstBaseURL: false),
              components.scheme == "wss", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.fragment == nil,
              (1...65535).contains(components.port ?? 443) else { throw VirtualizationError.invalidConfiguration }
        var origin = components
        origin.scheme = "https"; origin.path = "/"; origin.query = nil
        guard let url = origin.url else { throw VirtualizationError.invalidConfiguration }
        self.origin = url
        ownerID = UUID(); policy = .systemValidation
        self.configuration = configuration
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        self.certificatePin = certificatePin
        ticketTransport = true
        rejectRedirects = true
        super.init()
    }

    func request(_ path: String, method: String = "GET", headers: [String: String] = [:], body: Data? = nil,
                 acceptedErrorStatuses: Set<Int> = []) async throws -> Data {
        guard path.hasPrefix("/"), let url = URL(string: path, relativeTo: origin)?.absoluteURL,
              Self.sameOrigin(url, origin) else { throw VirtualizationError.invalidConfiguration }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if request.value(forHTTPHeaderField: "Accept") == nil {
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw VirtualizationError.invalidResponse }
            switch response.statusCode {
            case 200..<300: break
            case 401: throw VirtualizationError.authentication
            case 403: throw VirtualizationError.forbidden
            case 404, 405: throw VirtualizationError.unavailable
            default:
                // SOAP faults use HTTP 500; an explicit caller may safely parse the
                // bounded body instead of discarding its structured fault type.
                guard acceptedErrorStatuses.contains(response.statusCode) else {
                    throw VirtualizationError.http(response.statusCode)
                }
            }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 16 * 1024 * 1024 else { throw VirtualizationError.invalidResponse }
                data.append(byte)
            }
            return data
        } catch let error as VirtualizationError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch {
            // Do not surface URLs, authentication headers, cookies, or arbitrary server response text.
            let code = (error as NSError).code
            if [NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
                NSURLErrorServerCertificateHasUnknownRoot].contains(code) {
                throw VirtualizationError.message("Certificate validation failed. Review the certificate policy in the host's settings.")
            }
            throw VirtualizationError.message("The host could not be reached. Check the address, network, VPN, and TLS settings.")
        }
    }

    func json(_ path: String, method: String = "GET", headers: [String: String] = [:], body: Any? = nil) async throws -> Any {
        var headers = headers
        var data: Data?
        if let body {
            headers["Content-Type"] = "application/json"
            data = try JSONSerialization.data(withJSONObject: body)
        }
        let response = try await request(path, method: method, headers: headers, body: data)
        if response.isEmpty { return [:] as [String: Any] }
        do { return try JSONSerialization.jsonObject(with: response) }
        catch { throw VirtualizationError.invalidResponse }
    }

    func cookies(for url: URL) -> [HTTPCookie] {
        session.configuration.httpCookieStorage?.cookies(for: url) ?? []
    }

    func socket(_ request: URLRequest) -> URLSessionWebSocketTask {
        session.webSocketTask(with: request)
    }

    func close() { session.invalidateAndCancel() }

    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && (lhs.port ?? 443) == (rhs.port ?? 443)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if ticketTransport { recordTrust(.redirectRejected) }
        completionHandler(!rejectRedirects && !ticketTransport && request.url.map { Self.sameOrigin($0, origin) } == true ? request : nil)
    }

    // WebSocket tasks may deliver task-level challenges. Apply the same rules as
    // session-level trust, including refusal to send API credentials to ESXi.
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler: completionHandler)
    }

    private func handle(_ challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if ticketTransport && challenge.protectionSpace.authenticationMethod != NSURLAuthenticationMethodServerTrust {
            recordTrust(.unexpectedAuthentication)
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            if ticketTransport {
                recordTrust(.missingCertificate)
                completionHandler(.cancelAuthenticationChallenge, nil); return
            }
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if ticketTransport {
            guard challenge.protectionSpace.host.lowercased() == origin.host?.lowercased(),
                  challenge.protectionSpace.port == (origin.port ?? 443) else {
                recordTrust(.endpointMismatch)
                completionHandler(.cancelAuthenticationChallenge, nil); return
            }
            if let certificatePin {
                guard let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
                    recordTrust(.missingCertificate)
                    completionHandler(.cancelAuthenticationChallenge, nil); return
                }
                guard certificatePin.matches(SecCertificateCopyData(leaf) as Data) else {
                    recordTrust(.pinMismatch)
                    completionHandler(.cancelAuthenticationChallenge, nil); return
                }
                recordTrust(.pinVerified)
                completionHandler(.useCredential, URLCredential(trust: trust)); return
            }
            // A host omitting thumbprints must pass normal system certificate validation.
            recordTrust(.systemTrust)
            completionHandler(.performDefaultHandling, nil); return
        }
        if policy == .systemValidation {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if policy == .ignore {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        guard let certificate = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let data = SecCertificateCopyData(certificate) as Data
        let fingerprint = SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined(separator: ":")
        let key = "virtualization.certificate.\(ownerID.uuidString).\(challenge.protectionSpace.host).\(challenge.protectionSpace.port)"
        Task { @MainActor in
            let defaults = NethrivaDataProfile.defaults
            if let saved = defaults.string(forKey: key) {
                completionHandler(saved == fingerprint ? .useCredential : .cancelAuthenticationChallenge,
                                  saved == fingerprint ? URLCredential(trust: trust) : nil)
                return
            }
            let alert = NSAlert()
            alert.messageText = "Trust Virtualization Host Certificate?"
            alert.informativeText = "Verify this SHA-256 fingerprint with your administrator before trusting this host:\n\n\(fingerprint)"
            alert.addButton(withTitle: "Trust Certificate")
            alert.addButton(withTitle: "Cancel")
            let trusted = alert.runModal() == .alertFirstButtonReturn
            if trusted { defaults.set(fingerprint, forKey: key) }
            completionHandler(trusted ? .useCredential : .cancelAuthenticationChallenge,
                              trusted ? URLCredential(trust: trust) : nil)
        }
    }

    static func form(_ values: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        let encoded = (components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        return Data(encoded.utf8)
    }
}

final class VMXMLNode {
    let name: String
    let attributes: [String: String]
    var text = ""
    var children: [VMXMLNode] = []
    init(name: String, attributes: [String: String] = [:]) {
        self.name = name.components(separatedBy: ":").last ?? name
        self.attributes = attributes
    }
    func child(_ name: String) -> VMXMLNode? { children.first { $0.name == name } }
    func descendants(_ name: String) -> [VMXMLNode] {
        children.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(name) }
    }
}

final class VMXMLDocument: NSObject, XMLParserDelegate {
    private var stack: [VMXMLNode] = []
    private var root: VMXMLNode?
    static func parse(_ data: Data) throws -> VMXMLNode {
        let delegate = VMXMLDocument()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        // Host-provided XML must not expand internal or external entities.
        // These APIs use UTF-8. Reject alternate encodings before the DTD check so a
        // UTF-16 document cannot hide entity declarations behind interleaved NULs.
        guard data.count <= 16 * 1024 * 1024, !data.contains(0),
              let text = String(data: data, encoding: .utf8) else { throw VirtualizationError.invalidResponse }
        let prefix = text.uppercased()
        guard !prefix.contains("<!DOCTYPE"), !prefix.contains("<!ENTITY"),
              parser.parse(), let root = delegate.root else {
            throw VirtualizationError.invalidResponse
        }
        return root
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard stack.count < 100 else { parser.abortParsing(); return }
        let node = VMXMLNode(name: elementName.components(separatedBy: ":").last ?? elementName, attributes: attributeDict)
        if let parent = stack.last { parent.children.append(node) } else { root = node }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        _ = stack.popLast()
    }
}

@MainActor
protocol VirtualizationBackend: AnyObject {
    var taskProgress: ((VMTaskProgress) -> Void)? { get set }
    var supportsSnapshots: Bool { get }
    func machines() async throws -> [VirtualMachine]
    func details(for vm: VirtualMachine) async throws -> VirtualMachine
    func snapshots(for vm: VirtualMachine) async throws -> [VMSnapshot]
    func snapshot(_ action: VMSnapshotAction, vm: VirtualMachine, snapshot: VMSnapshot?, name: String?) async throws
    func perform(_ action: VMAction, on vm: VirtualMachine, media: String?) async throws
    func console(for vm: VirtualMachine) async throws -> VMConsoleDescriptor
    func close()
}

extension VirtualizationBackend {
    var supportsSnapshots: Bool { false }
    func details(for vm: VirtualMachine) async throws -> VirtualMachine { vm }
    func snapshots(for vm: VirtualMachine) async throws -> [VMSnapshot] { throw VirtualizationError.unavailable }
    func snapshot(_ action: VMSnapshotAction, vm: VirtualMachine, snapshot: VMSnapshot?, name: String?) async throws { throw VirtualizationError.unavailable }
}

@MainActor
enum VirtualizationBackendFactory {
    static func make(connection: RemoteConnection, password: String?) throws -> any VirtualizationBackend {
        let configuration = connection.virtualization ?? VirtualizationConfiguration()
        try configuration.validate()
        _ = try VMInput.endpoint(for: connection)
        if configuration.platform.usesSSH {
            return SSHVirtualizationBackend(connection: connection, password: password)
        }
        if configuration.platform == .vmware {
            return try VMwareBackend(connection: connection, password: password)
        }
        return try RESTVirtualizationBackend(connection: connection, password: password)
    }
}
