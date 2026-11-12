import AppKit
import Darwin
import Network
import SwiftUI

struct ConnectionCheckResult: Identifiable, Equatable {
    enum Outcome: String { case passed, failed, skipped }
    let stage: String
    let outcome: Outcome
    let detail: String
    var id: String { stage }
}

/// Exactly-once completion for network callbacks, timeout and cancellation races.
final class ProbeCompletion<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?
    func install(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result) }
        else { self.continuation = continuation; lock.unlock() }
    }
    func finish(_ result: Result<T, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation; self.continuation = nil
        lock.unlock(); continuation?.resume(with: result)
    }
}

enum ConnectionCheckService {
    static func dns(_ host: String, timeout: TimeInterval = 5) async throws -> Bool {
        let completion = ProbeCompletion<Bool>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                guard !Task.isCancelled else { completion.finish(.failure(CancellationError())); return }
                DispatchQueue.global(qos: .utility).async {
                    var hints = addrinfo(), addresses: UnsafeMutablePointer<addrinfo>?
                    hints.ai_socktype = SOCK_STREAM
                    let status = getaddrinfo(host, nil, &hints, &addresses)
                    if let addresses { freeaddrinfo(addresses) }
                    completion.finish(.success(status == 0))
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { completion.finish(.success(false)) }
            }
        } onCancel: { completion.finish(.failure(CancellationError())) }
    }
    static func tcp(host: String, port: Int, timeout: TimeInterval = 5) async throws -> Bool {
        guard (1...65535).contains(port), let port = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }
        let completion = ProbeCompletion<Bool>()
        let connection = NWConnection(host: .init(host), port: port, using: .tcp)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                guard !Task.isCancelled else { completion.finish(.failure(CancellationError())); return }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: completion.finish(.success(true)); connection.cancel()
                    case .failed, .cancelled: completion.finish(.success(false)); connection.cancel()
                    default: break
                    }
                }
                connection.start(queue: DispatchQueue(label: "com.vitalii.nethriva.probe"))
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { completion.finish(.success(false)); connection.cancel() }
            }
        } onCancel: { completion.finish(.failure(CancellationError())); connection.cancel() }
    }
    static func report(_ results: [ConnectionCheckResult]) -> String {
        "Nethriva Connection Check (redacted)\n" + results.map { "\($0.stage): \($0.outcome.rawValue) — \($0.detail)" }.joined(separator: "\n") +
        "\nNo endpoints, account names, paths, certificates, credentials, tickets, or server response bodies are included."
    }
}

private final class CheckHTTPDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor
final class ConnectionCheckModel: ObservableObject {
    @Published private(set) var results: [ConnectionCheckResult] = []
    @Published private(set) var running = false
    private var work: Task<Void, Never>?
    private var generation = UUID()
    private let service = SFTPService()
    deinit { work?.cancel() }
    func cancel() { generation = UUID(); work?.cancel(); work = nil; service.close(); running = false }
    func check(_ connection: RemoteConnection) {
        cancel(); results = []; running = true
        let generation = generation
        work = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == generation { running = false } }
            do {
                if connection.kind == .localShell || connection.kind == .serial {
                    let ready = connection.kind == .localShell || SerialPortDiscovery.availablePorts().contains(connection.host)
                    results.append(.init(stage: "Local device", outcome: ready ? .passed : .failed, detail: ready ? "The local surface/device is available." : "Reconnect the serial adapter and refresh its port."))
                    return
                }
                guard !connection.host.isEmpty, connection.host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                      connection.host.rangeOfCharacter(from: .controlCharacters) == nil, !connection.host.hasPrefix("-"), (1...65535).contains(connection.port) else {
                    results.append(.init(stage: "Configuration", outcome: .failed, detail: "Enter a host without whitespace and a valid port.")); return
                }
                let resolved = try await ConnectionCheckService.dns(connection.host)
                try Task.checkCancellation()
                guard self.generation == generation else { return }
                results.append(.init(stage: "DNS", outcome: resolved ? .passed : .failed, detail: resolved ? "macOS resolved the host." : "macOS could not resolve the name within five seconds. Check DNS/search domains. SSH aliases may still work through SSH configuration."))
                if resolved {
                    let reachable = try await ConnectionCheckService.tcp(host: connection.host, port: connection.port)
                    try Task.checkCancellation()
                    guard self.generation == generation else { return }
                    results.append(.init(stage: "TCP", outcome: reachable ? .passed : .failed, detail: reachable ? "The configured TCP port accepted a connection; this does not prove the service or login works." : "The port did not accept a connection within five seconds. Check service, firewall, routing, or VPN."))
                    if reachable, connection.kind == .virtualization, connection.virtualization?.platform != .libvirt, connection.virtualization?.platform != .hyperv {
                        var components = URLComponents(); components.scheme = "https"; components.host = connection.host; components.port = connection.port; components.path = "/"
                        if let url = components.url {
                            let config = URLSessionConfiguration.ephemeral
                            config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
                            let session = URLSession(configuration: config, delegate: CheckHTTPDelegate(), delegateQueue: nil)
                            defer { session.invalidateAndCancel() }
                            var request = URLRequest(url: url, timeoutInterval: 5); request.httpMethod = "HEAD"
                            do {
                                let (_, response) = try await session.data(for: request)
                                try Task.checkCancellation()
                                guard self.generation == generation else { return }
                                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                                results.append(.init(stage: "TLS/HTTPS", outcome: .passed, detail: "System certificate validation succeeded; HTTP status \(code). No credentials were sent or redirects followed."))
                            } catch {
                                try Task.checkCancellation()
                                guard self.generation == generation else { return }
                                results.append(.init(stage: "TLS/HTTPS", outcome: .failed, detail: "Strict HTTPS check failed (network code \((error as NSError).code)). Self-signed hosts may work with explicitly approved in-app trust; this check never bypasses validation."))
                            }
                        }
                    } else {
                        results.append(.init(stage: "TLS / host identity", outcome: .skipped, detail: "This protocol negotiates identity inside its session. A raw port check cannot verify it."))
                    }
                }
                results.append(.init(stage: "Authentication", outcome: .skipped, detail: "No login was attempted. Use the optional SSH/SFTP check or open the session to authenticate."))
            } catch is CancellationError {} catch {
                guard self.generation == generation else { return }
                results.append(.init(stage: "Check", outcome: .failed, detail: "The check could not finish. Retry when the network is ready."))
            }
        }
    }
    func authenticate(_ connection: RemoteConnection, password: String?) {
        guard !running, connection.kind == .ssh else { return }
        running = true
        generation = UUID()
        let generation = generation
        work = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == generation { running = false } }
            results.removeAll { $0.stage == "Authentication" }
            do {
                _ = try await service.list(connection: connection, password: password, path: ".")
                try Task.checkCancellation()
                guard self.generation == generation else { return }
                results.append(.init(stage: "Authentication", outcome: .passed, detail: "SSH authentication and the SFTP subsystem accepted a read-only listing. No paths or filenames were retained in this report."))
            } catch is CancellationError {} catch {
                guard self.generation == generation else { return }
                let message = (error as? SFTPServiceError)?.localizedDescription ?? "The authentication check failed. Open SSH to review host trust and login."
                results.append(.init(stage: "Authentication", outcome: .failed, detail: message))
            }
            service.close()
        }
    }
}

struct ConnectionCheckView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var model = ConnectionCheckModel()
    let connection: RemoteConnection
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connection Check").font(.title2.weight(.semibold))
            Text("Reachability checks do not log in or change server configuration. Reports omit private connection details.").foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.results) { result in
                        Label(result.stage + " — " + result.outcome.rawValue.capitalized,
                              systemImage: result.outcome == .passed ? "checkmark.circle" : result.outcome == .failed ? "exclamationmark.triangle" : "minus.circle")
                        Text(result.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            if model.running { ProgressView("Checking…") }
            HStack {
                Button("Check Reachability") { model.check(connection) }.disabled(model.running)
                if connection.kind == .ssh {
                    Button("Check SSH/SFTP Login") {
                        Task {
                            do {
                                let snapshot = appState.resolvedConnection(for: connection)
                                let password = try await appState.sessionPassword(for: snapshot)
                                try Task.checkCancellation(); _ = try appState.credentialGate.check()
                                model.authenticate(snapshot, password: password)
                            }
                            catch { appState.persistenceNotice = "The credential could not be read for the optional login check." }
                        }
                    }.disabled(model.running)
                }
                Spacer()
                if model.running { Button("Cancel") { model.cancel() } }
                Menu("Report") {
                    Button("Copy Redacted Report") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(ConnectionCheckService.report(model.results), forType: .string)
                    }
                    Button("Export Redacted Report…") {
                        let panel = NSSavePanel(); panel.nameFieldStringValue = "Nethriva-Connection-Check.txt"; panel.allowedContentTypes = [.plainText]
                        if panel.runModal() == .OK, let url = panel.url { try? ConnectionCheckService.report(model.results).write(to: url, atomically: true, encoding: .utf8) }
                    }
                }.disabled(model.results.isEmpty || model.running)
            }
        }
        .padding(20).frame(minWidth: 620, minHeight: 430)
        .onDisappear { model.cancel() }
    }
}
