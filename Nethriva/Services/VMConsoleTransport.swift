import AppKit
import Darwin
import Foundation
import Network
import Security
import WebKit

@MainActor
final class VMSSHTunnel {
    private var forward: (socket: String, specification: String)?
    private var generation = UUID()
    private(set) var port: Int = 0

    func start(host: RemoteConnection, destination: String, port remotePort: Int, socketPath: String?) async throws {
        stop()
        let generation = generation
        var fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VirtualizationError.unavailable }
        defer { if fd >= 0 { Darwin.close(fd) } }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw VirtualizationError.unavailable }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        port = Int(UInt16(bigEndian: address.sin_port))
        guard port > 0 else { throw VirtualizationError.unavailable }
        let forward: String
        if let socketPath {
            guard socketPath.hasPrefix("/"), !socketPath.contains(":"),
                  socketPath.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { throw VirtualizationError.invalidConfiguration }
            forward = "127.0.0.1:\(port):\(socketPath)"
        } else {
            guard (1...65535).contains(remotePort),
                  destination.rangeOfCharacter(from: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-:")).inverted) == nil else {
                throw VirtualizationError.invalidConfiguration
            }
            forward = "127.0.0.1:\(port):\(destination.contains(":") ? "[\(destination)]" : destination):\(remotePort)"
        }
        let socket = try await TunnelControl.socket(for: host)
        try await TunnelControl.execute("check", tunnel: nil, socket: socket)
        try Task.checkCancellation()
        guard self.generation == generation else { throw CancellationError() }
        Darwin.close(fd)
        fd = -1
        // Only the selected forward is added to the already authenticated master.
        // Config forwards remain suppressed; ClearAllForwardings cannot erase this
        // explicit control request. No login/password or long-lived child needed.
        do { try await TunnelControl.consoleForward("forward", specification: forward, socket: socket) }
        catch {
            if error is TunnelControl.Failure { Self.removeForward((socket, forward)) }
            throw error
        }
        guard self.generation == generation, !Task.isCancelled else {
            Self.removeForward((socket, forward)); throw CancellationError()
        }
        self.forward = (socket, forward)
        for _ in 0..<30 {
            try Task.checkCancellation()
            guard self.generation == generation else { throw CancellationError() }
            if await isListening(), self.generation == generation { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        stop()
        throw VirtualizationError.message("The SSH tunnel did not become ready. Check host authentication and forwarding permissions.")
    }

    private func isListening() async -> Bool {
        guard (1...65535).contains(port) else { return false }
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        return await withCheckedContinuation { continuation in
            let gate = ProbeGate(continuation: continuation, connection: connection)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: gate.finish(true)
                case .failed: gate.finish(false)
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { gate.finish(false) }
        }
    }
    func stop() { generation = UUID(); let owned = forward; forward = nil; port = 0; Self.removeForward(owned) }
    nonisolated private static func removeForward(_ owned: (socket: String, specification: String)?) {
        guard let owned else { return }
        Task { try? await TunnelControl.consoleForward("cancel", specification: owned.specification, socket: owned.socket) }
    }
    deinit { Self.removeForward(forward) }
}

private final class ProbeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private let connection: NWConnection
    init(continuation: CheckedContinuation<Bool, Never>, connection: NWConnection) {
        self.continuation = continuation; self.connection = connection
    }
    func finish(_ result: Bool) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        connection.cancel()
        continuation?.resume(returning: result)
    }
}

final class VMConsoleAssets: NSObject, WKURLSchemeHandler {
    private let root: URL
    init(root: URL) { self.root = root }
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.host == "bundle" else {
            urlSchemeTask.didFailWithError(VirtualizationError.invalidConfiguration); return
        }
        let target = root.appendingPathComponent(String(url.path.drop(while: { $0 == "/" }))).standardizedFileURL
        guard target.path.hasPrefix(root.standardizedFileURL.path + "/"),
              let data = try? Data(contentsOf: target) else {
            urlSchemeTask.didFailWithError(VirtualizationError.unavailable); return
        }
        let mime: String
        switch target.pathExtension.lowercased() {
        case "js": mime = "text/javascript"
        case "css": mime = "text/css"
        case "html": mime = "text/html"
        case "json": mime = "application/json"
        default: mime = "application/octet-stream"
        }
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: "utf-8"))
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

/// Only VMware one-time ticket sockets use this transport. URLSession's ATS
/// requirements can reject privately issued ESXi certificates even after a pin
/// matches. Network.framework lets the API-issued identity authorize that exact
/// endpoint without a global ATS exception, cookies, redirects, or HTTP login.
private final class VMConsoleTicketTrust: @unchecked Sendable {
    private let lock = NSLock()
    private var result: VMConsoleTrustResult = .notChallenged
    func record(_ value: VMConsoleTrustResult) {
        lock.lock(); defer { lock.unlock() }; result = value
    }
    func snapshot() -> VMConsoleTrustResult {
        lock.lock(); defer { lock.unlock() }; return result
    }
}

final class VMConsoleTicketTLS: @unchecked Sendable {
    let connection: NWConnection
    private let trustState: VMConsoleTicketTrust

    init(descriptor: VMConsoleDescriptor) throws {
        guard descriptor.singleUseTicket, let url = descriptor.webSocketURL,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme == "wss",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.fragment == nil, (1...65535).contains(parts.port ?? 443) else {
            throw VirtualizationError.invalidConfiguration
        }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        webSocket.maximumMessageSize = 8 * 1024 * 1024
        webSocket.setSubprotocols(["binary"])
        // Only the API origin is permitted; never copy cookies or Authorization.
        if let origin = descriptor.headers["Origin"] {
            guard let value = URLComponents(string: origin), value.scheme == "https", value.host != nil,
                  value.user == nil, value.password == nil, value.query == nil, value.fragment == nil,
                  value.path.isEmpty || value.path == "/",
                  origin.rangeOfCharacter(from: .controlCharacters) == nil else {
                throw VirtualizationError.invalidConfiguration
            }
            webSocket.setAdditionalHeaders([("Origin", origin)])
        }
        let state = VMConsoleTicketTrust()
        trustState = state
        let pin = descriptor.certificatePin
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let reference = sec_trust_copy_ref(trust).takeRetainedValue()
            if let pin {
                guard let leaf = (SecTrustCopyCertificateChain(reference) as? [SecCertificate])?.first else {
                    state.record(.missingCertificate); complete(false); return
                }
                let matched = pin.matches(SecCertificateCopyData(leaf) as Data)
                state.record(matched ? .pinVerified : .pinMismatch)
                complete(matched)
            } else {
                state.record(.systemTrust)
                // Missing pins still require a trusted chain, validity, and the
                // exact ticket hostname. There is no ignore/TOFU fallback here.
                let policy = SecPolicyCreateSSL(true, host as CFString)
                guard SecTrustSetPolicies(reference, policy) == errSecSuccess else { complete(false); return }
                complete(SecTrustEvaluateWithError(reference, nil))
            }
        }, DispatchQueue(label: "com.vitalii.nethriva.vm-ticket-trust"))
        // Set verification before NWParameters/NWConnection copy protocol options.
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        connection = NWConnection(to: .url(url), using: parameters)
    }

    func failureMessage(_ error: Error?) -> String {
        let value = trustState.snapshot()
        if let error = error as? NWError {
            switch error {
            case .tls(let code):
                if case .pinVerified = value {
                    return "The ESXi certificate matched the VMware ticket, but TLS negotiation failed (TLS code \(code)). Check ESXi TLS/cipher compatibility and any proxy, then reconnect for a fresh ticket."
                }
                if case .systemTrust = value {
                    return "The VMware ticket supplied no supported certificate identity and macOS could not validate the ESXi TLS connection (TLS code \(code)). Check ESXi certificate trust, then reconnect for a fresh ticket."
                }
                return value.failureMessage(nil) + " TLS code \(code)."
            case .posix(let code): return value.failureMessage(nil) + " Network code \(code.rawValue)."
            case .dns(let code): return value.failureMessage(nil) + " DNS code \(code)."
            default: break
            }
        }
        return value.failureMessage(error)
    }
}

@MainActor
final class VMConsoleChannel {
    private var tcp: NWConnection?
    private var socket: URLSessionWebSocketTask?
    private var reading: Task<Void, Never>?
    private var writing: Task<Void, Never>?
    private var outgoing: [Data] = []
    private let id: String
    private weak var bridge: VMConsoleWebBridge?
    private var stopped = false
    private var pendingBytes = 0
    private var ticketTLS: VMConsoleTicketTLS?
    private var ticketBased = false
    init(id: String, bridge: VMConsoleWebBridge) { self.id = id; self.bridge = bridge }

    func open(descriptor: VMConsoleDescriptor, http: VirtualizationHTTP) {
        if let url = descriptor.webSocketURL {
            ticketBased = descriptor.singleUseTicket
            if ticketBased {
                do {
                    let transport = try VMConsoleTicketTLS(descriptor: descriptor)
                    ticketTLS = transport
                    let connection = transport.connection
                    connection.stateUpdateHandler = { [weak self] state in
                        Task { @MainActor in
                            guard let self, !self.stopped else { return }
                            switch state {
                            case .ready: await self.emit("open"); self.receiveTicket()
                            case .failed(let error), .waiting(let error): await self.fail(error)
                            default: break
                            }
                        }
                    }
                    connection.start(queue: .global(qos: .userInitiated))
                } catch { Task { await fail(error) } }
                return
            }
            var request = URLRequest(url: url)
            for (key, value) in descriptor.headers { request.setValue(value, forHTTPHeaderField: key) }
            let task = http.socket(request)
            socket = task
            task.resume()
            reading = Task { [weak self] in
                guard let self else { return }
                do {
                    // noVNC can send its first bytes immediately; URLSession queues them until the handshake finishes.
                    await emit("open")
                    while !Task.isCancelled && !stopped {
                        let message = try await task.receive()
                        let data: Data
                        switch message {
                        case .data(let value): data = value
                        case .string(let value): data = Data(value.utf8)
                        @unknown default: throw VirtualizationError.invalidResponse
                        }
                        guard data.count <= 8 * 1024 * 1024 else { throw VirtualizationError.invalidResponse }
                        await emit("data", data: data)
                    }
                } catch { if !stopped { await fail(error) } }
            }
        } else {
            guard (1...65535).contains(descriptor.port) else { Task { await fail() }; return }
            let parameters: NWParameters
            if descriptor.usesTLS {
                let tls = NWProtocolTLS.Options()
                sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
                sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, descriptor.host)
                // Network.framework's default verifier performs system trust and hostname verification.
                // Do not inherit the management host's "ignore certificate" policy or downgrade to plain TCP.
                parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
            } else { parameters = .tcp }
            let connection = NWConnection(host: NWEndpoint.Host(descriptor.host),
                port: NWEndpoint.Port(rawValue: UInt16(descriptor.port))!, using: parameters)
            tcp = connection
            connection.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, !self.stopped else { return }
                    switch state {
                    case .ready: await self.emit("open"); self.receiveTCP()
                    case .failed: await self.fail()
                    default: break
                    }
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    private func receiveTicket() {
        guard !stopped else { return }
        ticketTLS?.connection.receiveMessage { [weak self] data, context, complete, error in
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                if let error { await self.fail(error); return }
                guard let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
                      complete else { await self.fail(); return }
                switch metadata.opcode {
                case .binary:
                    if let data, !data.isEmpty { await self.emit("data", data: data) }
                case .close: await self.fail(); return
                case .pong: break
                default: await self.fail(); return
                }
                self.receiveTicket()
            }
        }
    }

    private func receiveTCP() {
        guard !stopped else { return }
        tcp?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                if let data, !data.isEmpty { await self.emit("data", data: data) }
                if complete || error != nil { await self.fail() }
                else { self.receiveTCP() }
            }
        }
    }
    func send(_ data: Data) {
        guard !stopped, pendingBytes + data.count <= 8 * 1024 * 1024 else { Task { await fail() }; return }
        pendingBytes += data.count
        if let ticketTLS {
            let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
            let context = NWConnection.ContentContext(identifier: "vm-ticket-binary", metadata: [metadata])
            ticketTLS.connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
                Task { @MainActor in
                    if let error { await self?.fail(error) } else { await self?.sent(data.count) }
                }
            })
        } else if let socket {
            outgoing.append(data)
            guard writing == nil else { return }
            writing = Task { [weak self] in
                guard let self else { return }
                do {
                    while !outgoing.isEmpty && !stopped {
                        let next = outgoing.removeFirst()
                        try await socket.send(.data(next))
                        await sent(next.count)
                    }
                } catch { await fail(error) }
                writing = nil
            }
        } else {
            tcp?.send(content: data, completion: .contentProcessed { [weak self] error in
                Task { @MainActor in
                    if error != nil { await self?.fail() } else { await self?.sent(data.count) }
                }
            })
        }
    }
    private func sent(_ count: Int) async {
        guard !stopped else { return }
        pendingBytes = max(0, pendingBytes - count)
        await bridge?.event(["kind": "sent", "id": id, "count": count])
    }
    private func emit(_ kind: String, data: Data? = nil) async {
        var event: [String: Any] = ["kind": kind, "id": id]
        if let data { event["data"] = data.base64EncodedString() }
        await bridge?.event(event)
    }
    private func fail(_ error: Error? = nil) async {
        guard !stopped else { return }
        if ticketBased {
            let message = ticketTLS?.failureMessage(error) ?? VMConsoleTrustResult.notChallenged.failureMessage(error)
            bridge?.onError?(message)
        }
        stop()
        await emit("error")
    }
    func stop() {
        stopped = true
        reading?.cancel(); reading = nil
        writing?.cancel(); writing = nil; outgoing.removeAll()
        tcp?.cancel(); tcp = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        ticketTLS?.connection.cancel(); ticketTLS = nil
    }
}

@MainActor
final class VMConsoleWebBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    weak var webView: WKWebView?
    var descriptor: VMConsoleDescriptor?
    var http: VirtualizationHTTP?
    var options: [String: Any] = [:]
    var onState: ((String) -> Void)?
    var onCredentials: (() -> Void)?
    var onError: ((String) -> Void)?
    private var channels: [String: VMConsoleChannel] = [:]
    private var ready = false
    private var started = false
    private var ticketOpened = false

    func configure(_ descriptor: VMConsoleDescriptor, http: VirtualizationHTTP, options: [String: Any]) {
        self.descriptor = descriptor; self.http = http; self.options = options
        ticketOpened = false
        if descriptor.renderer == .hostWeb, let url = descriptor.webURL {
            webView?.load(URLRequest(url: url))
        } else { startIfReady() }
    }
    private func startIfReady() {
        guard ready, !started, let descriptor, descriptor.renderer != .hostWeb else { return }
        started = true
        var config = options
        config["renderer"] = descriptor.renderer == .spice ? "spice" : "vnc"
        let permitted = descriptor.protectsCredentials || options["allowUnprotectedCredentials"] as? Bool == true
        config["password"] = permitted ? descriptor.password ?? "" : ""
        config["username"] = permitted ? descriptor.username ?? "" : ""
        webView?.callAsyncJavaScript("window.startConsole(configuration)", arguments: ["configuration": config], in: nil, in: .page, completionHandler: { [weak self] result in
            if case .failure = result { self?.onState?("failed") }
        })
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.scheme == "nethriva-console",
              let value = message.body as? [String: Any], let kind = value["kind"] as? String else { return }
        switch kind {
        case "ready": ready = true; startIfReady()
        case "connected", "failed": onState?(kind)
        case "credentialsRequired":
            if descriptor?.singleUseTicket == true {
                onError?("VMware requested unsupported console authentication after issuing a WebMKS ticket. Reconnect for a fresh ticket; do not enter a guest or vCenter password here.")
            } else { onCredentials?() }
        case "clipboard":
            guard options["clipboard"] as? Bool == true, let text = value["text"] as? String, text.utf8.count < 1024 * 1024 else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case "open":
            guard let id = value["id"] as? String, UUID(uuidString: id) != nil,
                  channels.count < 12, channels[id] == nil, let descriptor, let http else { return }
            if descriptor.singleUseTicket {
                guard !ticketOpened else {
                    Task { await event(["kind": "error", "id": id]) }; return
                }
                ticketOpened = true
            }
            let channel = VMConsoleChannel(id: id, bridge: self)
            channels[id] = channel
            channel.open(descriptor: descriptor, http: http)
        case "send":
            guard let id = value["id"] as? String, let encoded = value["data"] as? String,
                  encoded.count < 1024 * 1024, let data = Data(base64Encoded: encoded) else { return }
            channels[id]?.send(data)
        case "close":
            if let id = value["id"] as? String {
                channels.removeValue(forKey: id)?.stop()
                Task { await event(["kind": "close", "id": id]) }
            }
        default: break
        }
    }
    func event(_ event: [String: Any]) async {
        _ = try? await webView?.callAsyncJavaScript("window.nativeConsoleEvent(event)", arguments: ["event": event], in: nil, contentWorld: .page)
    }
    func action(_ action: String, value: Any = NSNull()) {
        options[action] = value
        webView?.callAsyncJavaScript("window.consoleAction(action, value)", arguments: ["action": action, "value": value], in: nil, in: .page, completionHandler: nil)
        if action == "release" { webView?.window?.makeFirstResponder(nil) }
    }
    func credentials(_ password: String, allowUnprotected: Bool = false) {
        guard descriptor?.protectsCredentials == true || allowUnprotected else { return }
        webView?.callAsyncJavaScript("window.consoleCredentials(password, username)",
            arguments: ["password": password, "username": descriptor?.username ?? ""], in: nil, in: .page, completionHandler: nil)
    }
    func stop() {
        channels.values.forEach { $0.stop() }; channels.removeAll()
        webView?.evaluateJavaScript("window.stopConsole?.()", completionHandler: nil)
        webView?.stopLoading()
        ready = false; started = false; ticketOpened = false; descriptor = nil; http = nil
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if descriptor?.renderer == .hostWeb { onState?("hostWeb") }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onState?("failed")
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.scheme == "nethriva-console", url.host == "bundle" { decisionHandler(.allow); return }
        if descriptor?.renderer == .hostWeb, let origin = descriptor?.webURL,
           VirtualizationHTTP.sameOrigin(url, origin) { decisionHandler(.allow); return }
        decisionHandler(.cancel)
    }
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let http {
            http.urlSession(URLSession.shared, didReceive: challenge, completionHandler: completionHandler)
        } else { completionHandler(.performDefaultHandling, nil) }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, let origin = descriptor?.webURL,
           VirtualizationHTTP.sameOrigin(url, origin) { webView.load(navigationAction.request) }
        return nil
    }
}
