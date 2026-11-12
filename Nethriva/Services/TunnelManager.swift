import AppKit
import Darwin
import SwiftUI

struct TunnelConfiguration: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable { case local, remote, socks }
    var id = UUID()
    var name: String
    var connectionID: UUID
    var kind: Kind = .local
    var listenPort = 1080
    var destinationHost = "localhost"
    var destinationPort = 22
    func validate() throws {
        guard !name.isEmpty, name.count <= 200, (1024...65535).contains(listenPort), (1...65535).contains(destinationPort),
              !destinationHost.isEmpty, !destinationHost.hasPrefix("-"), destinationHost.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              destinationHost.rangeOfCharacter(from: .controlCharacters) == nil,
              destinationHost.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "._-:".unicodeScalars.contains($0) }) else {
            throw WorkflowError.invalid("Use an unprivileged listen port (1024–65535), a valid destination host and port, and a name.")
        }
    }
    var specification: String {
        if kind == .socks { return "127.0.0.1:\(listenPort)" }
        let host = destinationHost.contains(":") ? "[\(destinationHost)]" : destinationHost
        return "127.0.0.1:\(listenPort):\(host):\(destinationPort)"
    }
    var flag: String { kind == .local ? "-L" : kind == .remote ? "-R" : "-D" }
}

enum TunnelControl {
    enum Failure: LocalizedError {
        case uncertain
        var errorDescription: String? { "The forwarding acknowledgement was interrupted. State is uncertain; explicitly Stop before retrying." }
    }
    static func arguments(_ operation: String, tunnel: TunnelConfiguration?, socket: String) throws -> [String] {
        guard ["check", "forward", "cancel"].contains(operation) else { throw WorkflowError.invalid("Unsupported tunnel operation.") }
        guard SSHConnectionReuse.ownsControlSocket(socket) else { throw WorkflowError.invalid("The SSH control socket is not owned by this app instance.") }
        // No user config here: importing LocalForward/RemoteForward options would
        // accidentally act on forwards outside this manager.
        var args = ["-F", "none", "-S", socket, "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes", "-O", operation]
        if let tunnel { try tunnel.validate(); args += [tunnel.flag, tunnel.specification] }
        return args + ["--", "nethriva-control.invalid"]
    }
    static func socket(for host: RemoteConnection) async throws -> String {
        var args = try SFTPChannel.arguments(for: host)
        let destination = args[args.count - 2]; args.removeLast(4)
        let output = try await run(["-G"] + args + ["--", destination], capture: true)
        guard let line = String(data: output, encoding: .utf8)?.components(separatedBy: "\n").first(where: { $0.hasPrefix("controlpath ") }) else {
            throw WorkflowError.invalid("OpenSSH did not resolve a control socket.")
        }
        let socket = String(line.dropFirst("controlpath ".count))
        guard SSHConnectionReuse.ownsControlSocket(socket) else { throw WorkflowError.invalid("OpenSSH returned an unexpected control socket.") }
        return socket
    }
    static func execute(_ operation: String, tunnel: TunnelConfiguration?, socket: String) async throws {
        let args = try arguments(operation, tunnel: tunnel, socket: socket)
        _ = try await run(args, capture: false, uncertainOnInterrupt: operation == "forward")
    }
    static func consoleForwardArguments(_ operation: String, specification: String, socket: String) throws -> [String] {
        guard ["forward", "cancel"].contains(operation), specification.hasPrefix("127.0.0.1:"), specification.utf8.count <= 4096,
              specification.rangeOfCharacter(from: .controlCharacters) == nil else { throw WorkflowError.invalid("Invalid console forwarding request.") }
        var args = try arguments(operation, tunnel: nil, socket: socket)
        args.insert(contentsOf: ["-L", specification], at: args.count - 2)
        return args
    }
    static func consoleForward(_ operation: String, specification: String, socket: String) async throws {
        _ = try await run(consoleForwardArguments(operation, specification: specification, socket: socket), capture: false, uncertainOnInterrupt: operation == "forward")
    }
    private static func run(_ args: [String], capture: Bool, uncertainOnInterrupt: Bool = false) async throws -> Data {
        let token = SFTPCancellation()
        return try await withTaskCancellationHandler {
            try await BackgroundWork.run {
                let process = Process(), pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh"); process.arguments = args
                process.standardInput = FileHandle.nullDevice; process.standardOutput = capture ? pipe : FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                let fd = pipe.fileHandleForReading.fileDescriptor
                _ = fcntl(fd, F_SETFL, O_NONBLOCK)
                try token.start(process)
                try? pipe.fileHandleForWriting.close()
                defer { token.detach(); try? pipe.fileHandleForReading.close() }
                var output = Data(), buffer = [UInt8](repeating: 0, count: 8192)
                let deadline = Date().addingTimeInterval(5)
                do {
                    repeat {
                        if capture {
                            while true {
                                let count = Darwin.read(fd, &buffer, buffer.count)
                                if count <= 0 { break }
                                guard output.count + count <= 512 * 1024 else { throw WorkflowError.invalid("OpenSSH configuration output exceeded the safety limit.") }
                                output.append(contentsOf: buffer.prefix(count))
                            }
                        }
                        try token.check()
                        guard Date() < deadline else { throw WorkflowError.invalid("The SSH control request timed out.") }
                        if !process.isRunning { break }
                        usleep(10000)
                    } while true
                    // Drain the final pipe bytes after exit.
                    if capture { while true {
                        let count = Darwin.read(fd, &buffer, buffer.count); if count <= 0 { break }
                        guard output.count + count <= 512 * 1024 else { throw WorkflowError.invalid("OpenSSH configuration output exceeded the safety limit.") }
                        output.append(contentsOf: buffer.prefix(count))
                    } }
                } catch { token.cancel(); if uncertainOnInterrupt { throw Failure.uncertain }; throw error }
                guard process.terminationStatus == 0 else {
                    throw WorkflowError.invalid("OpenSSH rejected the request. Authenticate the SSH tab first; check the port and server forwarding policy.")
                }
                return output
            }
        } onCancel: { token.cancel() }
    }
}

@MainActor
final class TunnelManager: ObservableObject {
    @Published private(set) var active: [UUID: RemoteConnection] = [:]
    @Published private(set) var status: [UUID: String] = [:]
    private var configurations: [UUID: TunnelConfiguration] = [:]
    private var sockets: [UUID: String] = [:]
    private var work: [UUID: Task<Void, Never>] = [:]
    private var monitor: Task<Void, Never>?
    private let resolveSocket: (RemoteConnection) async throws -> String
    private let control: (String, TunnelConfiguration?, String) async throws -> Void
    init(resolveSocket: @escaping (RemoteConnection) async throws -> String = TunnelControl.socket,
         control: @escaping (String, TunnelConfiguration?, String) async throws -> Void = { try await TunnelControl.execute($0, tunnel: $1, socket: $2) }) {
        self.resolveSocket = resolveSocket; self.control = control
    }
    var onReleased: ((RemoteConnection) -> Void)?
    var leases: [RemoteConnection] { Array(active.values) }
    func start(_ tunnel: TunnelConfiguration, host: RemoteConnection) {
        guard work[tunnel.id] == nil, active[tunnel.id] == nil else { return }
        do {
            try tunnel.validate(); _ = try SFTPChannel.arguments(for: host)
            guard host.kind == .ssh, host.id == tunnel.connectionID else { throw WorkflowError.invalid("Select this tunnel's saved SSH host.") }
        } catch { status[tunnel.id] = error.localizedDescription; return }
        if tunnel.kind != .remote, configurations.values.contains(where: { $0.kind != .remote && $0.listenPort == tunnel.listenPort }) {
            status[tunnel.id] = "Another managed tunnel already owns that local port."; return
        }
        if tunnel.kind == .remote, configurations.contains(where: { id, config in
            config.kind == .remote && config.listenPort == tunnel.listenPort && active[id].map { SSHConnectionReuse.controlKey(for: $0) == SSHConnectionReuse.controlKey(for: host) } == true
        }) { status[tunnel.id] = "Another managed tunnel owns that remote port on this SSH transport."; return }
        configurations[tunnel.id] = tunnel; active[tunnel.id] = host // Lease while starting too.
        status[tunnel.id] = "Starting…"
        work[tunnel.id] = Task { [weak self] in
            guard let self else { return }
            defer { work[tunnel.id] = nil }
            do {
                let socket = try await resolveSocket(host)
                sockets[tunnel.id] = socket
                try await control("check", nil, socket)
                try Task.checkCancellation()
                try await control("forward", tunnel, socket)
                status[tunnel.id] = "Active (forward accepted; destination not probed)"
                beginMonitoring()
            } catch {
                if error is TunnelControl.Failure {
                    status[tunnel.id] = error.localizedDescription; beginMonitoring(); return
                }
                // A rejected forward is not ours: never cancel a preexisting forward.
                active[tunnel.id] = nil; configurations[tunnel.id] = nil
                sockets[tunnel.id] = nil
                status[tunnel.id] = error is CancellationError ? "Stopped" : error.localizedDescription
                onReleased?(host)
            }
        }
    }
    func stop(_ id: UUID) {
        guard let host = active[id], let config = configurations[id] else { return }
        if work[id] != nil { work[id]?.cancel(); return }
        status[id] = "Stopping…"
        work[id] = Task { [weak self] in
            guard let self else { return }
            defer { work[id] = nil }
            do {
                guard let socket = sockets[id] else { throw WorkflowError.invalid("Missing control socket.") }
                try await control("cancel", config, socket)
                active[id] = nil; configurations[id] = nil; status[id] = "Stopped"; onReleased?(host)
                sockets[id] = nil
            } catch { status[id] = "Stop was not confirmed. Retry Stop, or close the SSH master if the network is lost." }
        }
    }
    func stopAll() { for id in Array(active.keys) { stop(id) } }
    private func beginMonitoring() {
        guard monitor == nil else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard let self else { return }
                if active.isEmpty { monitor = nil; return }
                for (id, host) in active where work[id] == nil {
                    do { guard let socket = sockets[id] else { continue }; try await control("check", nil, socket) }
                    catch {
                        if let socket = sockets[id], FileManager.default.fileExists(atPath: socket) {
                            status[id] = "SSH control is unavailable; tunnel state is uncertain. Retry Stop explicitly."
                        } else {
                            active[id] = nil; configurations[id] = nil; sockets[id] = nil; status[id] = "SSH transport ended — start explicitly after reconnecting."; onReleased?(host)
                        }
                    }
                }
            }
        }
    }
}

struct TunnelManagerView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var library: WorkflowLibrary
    @EnvironmentObject private var manager: TunnelManager
    @State private var draft = TunnelConfiguration(name: "", connectionID: UUID())
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SSH Tunnels").font(.title2)
            Text("Authenticate an SSH tab first. Start/Stop controls only these managed forwards; no password appears in process arguments. Listeners bind to loopback. Remote bind behavior also depends on server GatewayPorts policy.").font(.caption).foregroundStyle(.secondary)
            List(library.tunnels) { tunnel in
                HStack {
                    VStack(alignment: .leading) { Text(tunnel.name); Text(manager.status[tunnel.id] ?? "Stopped").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Edit") { draft = tunnel }.disabled(manager.active[tunnel.id] != nil)
                    if manager.active[tunnel.id] != nil { Button("Stop") { manager.stop(tunnel.id) } }
                    else { Button("Start") {
                        if let host = appState.connections.first(where: { $0.id == tunnel.connectionID && $0.kind == .ssh }) { manager.start(tunnel, host: appState.resolvedConnection(for: host)) }
                        else { error = "The tunnel's SSH connection no longer exists." }
                    } }
                    Button("Delete", role: .destructive) { do { try library.deleteTunnel(tunnel.id) } catch { self.error = error.localizedDescription } }.disabled(manager.active[tunnel.id] != nil)
                }
            }.frame(minHeight: 170)
            Form {
                TextField("Name", text: $draft.name)
                Picker("SSH host", selection: Binding<UUID?>(get: { appState.connections.contains(where: { $0.id == draft.connectionID && $0.kind == .ssh }) ? draft.connectionID : nil }, set: { if let id = $0 { draft.connectionID = id } })) {
                    Text("Choose an SSH connection").tag(nil as UUID?)
                    ForEach(appState.connections.filter { $0.kind == .ssh }) { Text($0.name).tag($0.id as UUID?) }
                }
                Picker("Direction", selection: $draft.kind) { Text("Local → remote service").tag(TunnelConfiguration.Kind.local); Text("Remote → service on this Mac's network").tag(TunnelConfiguration.Kind.remote); Text("Local SOCKS proxy").tag(TunnelConfiguration.Kind.socks) }
                TextField("Listen port", value: $draft.listenPort, format: .number.grouping(.never))
                if draft.kind != .socks {
                    TextField("Destination host", text: $draft.destinationHost)
                    TextField("Destination port", value: $draft.destinationPort, format: .number.grouping(.never))
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            if let notice = library.notice { Text(notice).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("New") { draft = .init(name: "", connectionID: appState.connections.first(where: { $0.kind == .ssh })?.id ?? UUID()) }
                Button("Open Host SSH") { if let host = appState.connections.first(where: { $0.id == draft.connectionID }) { appState.open(host) } }
                Spacer()
                Button("Save Tunnel") { do { try library.save(draft); error = nil } catch { self.error = error.localizedDescription } }
                    .disabled(manager.active[draft.id] != nil || !appState.connections.contains(where: { $0.id == draft.connectionID && $0.kind == .ssh }))
            }
        }.padding(20).frame(minWidth: 760, minHeight: 540)
        .onAppear { if !appState.connections.contains(where: { $0.id == draft.connectionID }) { draft.connectionID = appState.connections.first(where: { $0.kind == .ssh })?.id ?? UUID() } }
    }
}
