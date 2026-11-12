import AppKit
import SwiftUI

enum WorkflowError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

enum SSHJumpChain {
    static func validate(_ value: String) throws -> [String] {
        if value.isEmpty { return [] }
        let hops = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard hops.count <= 8 else { throw WorkflowError.invalid("Use at most eight jump hosts.") }
        for hop in hops {
            guard !hop.isEmpty, !hop.hasPrefix("-"), hop.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                  hop.rangeOfCharacter(from: .controlCharacters) == nil, !hop.contains("/"), !hop.contains("%") else {
                throw WorkflowError.invalid("Use user@host:port, host aliases, or bracketed IPv6 addresses without whitespace.")
            }
            let pieces = hop.split(separator: "@", omittingEmptySubsequences: false)
            guard pieces.count <= 2, pieces.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") }) else { throw WorkflowError.invalid("The jump host username/host is invalid.") }
            let endpoint = String(pieces.last!)
            let host: String, port: String?
            if endpoint.hasPrefix("[") {
                guard let closing = endpoint.firstIndex(of: "]") else { throw WorkflowError.invalid("Bracket the complete IPv6 address.") }
                host = String(endpoint[endpoint.index(after: endpoint.startIndex)..<closing])
                let tail = String(endpoint[endpoint.index(after: closing)...])
                guard tail.isEmpty || tail.hasPrefix(":") else { throw WorkflowError.invalid("Invalid jump host port.") }
                port = tail.isEmpty ? nil : String(tail.dropFirst())
            } else {
                let parts = endpoint.split(separator: ":", omittingEmptySubsequences: false)
                guard parts.count <= 2 else { throw WorkflowError.invalid("Bracket IPv6 jump hosts.") }
                host = String(parts[0]); port = parts.count == 2 ? String(parts[1]) : nil
            }
            guard !host.isEmpty, host.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "._-:".unicodeScalars.contains($0) }) else {
                throw WorkflowError.invalid("The jump host address is invalid.")
            }
            if let port { guard let number = Int(port), port.allSatisfy(\.isNumber), (1...65535).contains(number) else { throw WorkflowError.invalid("Jump host ports must be 1–65535.") } }
        }
        return hops
    }
    static func destination(_ connection: RemoteConnection) -> String {
        let host = connection.host.contains(":") ? "[\(connection.host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))]" : connection.host
        return (connection.username.isEmpty ? "" : connection.username + "@") + host + (connection.port == 22 ? "" : ":\(connection.port)")
    }
}

struct JumpHostEditor: View {
    private struct Hop: Identifiable { var id = UUID(); var address: String }
    @Binding var value: String
    let connections: [RemoteConnection]
    @State private var hops: [Hop] = []
    @State private var newHop = ""
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Jump Hosts — first hop to last").font(.headline)
            ForEach($hops) { $hop in
                let index = hops.firstIndex(where: { $0.id == hop.id }) ?? 0
                HStack {
                    TextField("user@host:port", text: $hop.address)
                    Button("↑") { if let index = hops.firstIndex(where: { $0.id == hop.id }), index > 0 { hops.swapAt(index, index - 1) } }.disabled(index == 0)
                    Button("↓") { if let index = hops.firstIndex(where: { $0.id == hop.id }), index + 1 < hops.count { hops.swapAt(index, index + 1) } }.disabled(index + 1 == hops.count)
                    Button("Remove") { hops.removeAll { $0.id == hop.id } }
                }
            }
            HStack {
                TextField("Add host or SSH config alias", text: $newHop)
                Button("Add") { hops.append(Hop(address: newHop)); newHop = "" }.disabled(newHop.isEmpty || hops.count >= 8)
                Menu("Saved SSH Host") {
                    ForEach(connections.filter { $0.kind == .ssh }) { connection in
                        Button(connection.name) { hops.append(Hop(address: SSHJumpChain.destination(connection))) }
                    }
                }.disabled(hops.count >= 8)
            }
            Text("Per-hop keys, authentication and aliases follow ~/.ssh/config. Selecting a saved host adds its address, not its Keychain password or key settings. No agent forwarding is automatically enabled.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Apply") {
                do { let chain = hops.map(\.address).joined(separator: ","); _ = try SSHJumpChain.validate(chain); value = chain; dismiss() }
                catch { self.error = error.localizedDescription }
            } }
        }.padding(20).frame(width: 640)
        .onAppear { hops = value.isEmpty ? [] : value.components(separatedBy: ",").map { Hop(address: $0) } }
    }
}

struct CommandSnippet: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var group: String = "General"
    var command: String
    var quoteParameters = true
    var confirmExecution = true
    static func requiresConfirmation(_ text: String) -> Bool { text.rangeOfCharacter(from: .controlCharacters) != nil }
    var parameters: [String] {
        let pattern = #"\{\{([A-Za-z][A-Za-z0-9_]{0,31})\}\}"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let matches = regex.matches(in: command, range: NSRange(command.startIndex..., in: command))
        var names: [String] = []
        for match in matches {
            if let range = Range(match.range(at: 1), in: command) { let name = String(command[range]); if !names.contains(name) { names.append(name) } }
        }
        return names
    }
    func render(_ values: [String: String]) throws -> String {
        guard !name.isEmpty, name.count <= 200, group.count <= 200, parameters.count <= 32, !command.isEmpty, command.utf8.count <= 32768, !command.contains("\0") else { throw WorkflowError.invalid("Use a name/group up to 200 characters, at most 32 parameters, and a command up to 32 KiB without NUL characters.") }
        var result = command
        // One regex pass: parameter values are never reinterpreted as new placeholders.
        let regex = try NSRegularExpression(pattern: #"\{\{([A-Za-z][A-Za-z0-9_]{0,31})\}\}"#)
        for match in regex.matches(in: command, range: NSRange(command.startIndex..., in: command)).reversed() {
            guard let keyRange = Range(match.range(at: 1), in: command), let range = Range(match.range, in: result), let value = values[String(command[keyRange])], !value.contains("\0") else {
                throw WorkflowError.invalid("Fill every snippet parameter before inserting it.")
            }
            let replacement = quoteParameters ? "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" : value
            result.replaceSubrange(range, with: replacement)
        }
        guard result.utf8.count <= 65536 else { throw WorkflowError.invalid("The rendered command is too large.") }
        return result
    }
}

@MainActor
final class WorkflowLibrary: ObservableObject {
    private struct Archive: Codable { var version = 1; var snippets: [CommandSnippet]; var tunnels: [TunnelConfiguration] }
    @Published private(set) var snippets: [CommandSnippet] = []
    @Published private(set) var tunnels: [TunnelConfiguration] = []
    @Published var notice: String?
    private let defaults: UserDefaults
    private let key = "workflow.library.v1"
    private var damaged = false
    init(defaults: UserDefaults = NethrivaDataProfile.defaults) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: key) else { return }
        do {
            guard data.count <= 8 * 1024 * 1024 else { throw WorkflowError.invalid("Oversized workflow library.") }
            let archive = try JSONDecoder().decode(Archive.self, from: data)
            guard archive.version == 1, archive.snippets.count <= 1000, archive.tunnels.count <= 1000 else { throw WorkflowError.invalid("Unsupported workflow library.") }
            guard Set(archive.snippets.map(\.id)).count == archive.snippets.count, Set(archive.tunnels.map(\.id)).count == archive.tunnels.count else { throw WorkflowError.invalid("Duplicate workflow identities.") }
            for snippet in archive.snippets { _ = try snippet.render(Dictionary(uniqueKeysWithValues: snippet.parameters.map { ($0, "preview") })) }
            for tunnel in archive.tunnels { try tunnel.validate() }
            snippets = archive.snippets; tunnels = archive.tunnels
        } catch { damaged = true; notice = "The workflow library could not be decoded. It was preserved; saving is disabled until recovered." }
    }
    func save(_ snippet: CommandSnippet) throws {
        _ = try snippet.render(Dictionary(uniqueKeysWithValues: snippet.parameters.map { ($0, "preview") }))
        var next = snippets.filter { $0.id != snippet.id }; next.append(snippet)
        try persist(snippets: next, tunnels: tunnels); snippets = next
    }
    func save(_ tunnel: TunnelConfiguration) throws {
        try tunnel.validate()
        var next = tunnels.filter { $0.id != tunnel.id }; next.append(tunnel)
        try persist(snippets: snippets, tunnels: next); tunnels = next
    }
    func deleteSnippet(_ id: UUID) throws { let next = snippets.filter { $0.id != id }; try persist(snippets: next, tunnels: tunnels); snippets = next }
    func deleteTunnel(_ id: UUID) throws { let next = tunnels.filter { $0.id != id }; try persist(snippets: snippets, tunnels: next); tunnels = next }
    private func persist(snippets: [CommandSnippet], tunnels: [TunnelConfiguration]) throws {
        guard !damaged, snippets.count <= 1000, tunnels.count <= 1000 else { throw WorkflowError.invalid("The workflow library cannot be saved. Its existing data was preserved.") }
        let data = try JSONEncoder().encode(Archive(snippets: snippets, tunnels: tunnels))
        guard data.count <= 8 * 1024 * 1024 else { throw WorkflowError.invalid("The workflow library exceeds 8 MiB. Existing data was preserved.") }
        if let previous = defaults.data(forKey: key) { defaults.set(previous, forKey: key + ".backup") }
        defaults.set(data, forKey: key)
    }
}

@MainActor
final class TerminalCommandRouter {
    struct Recipient: Equatable { let id: UUID; let generation: UUID }
    private struct Route { var sender: (String) -> Bool; var ready: () -> Bool; weak var source: AnyObject?; let generation: UUID }
    private var senders: [UUID: Route] = [:]
    func register(_ id: UUID?, identity: AnyObject? = nil, ready: @escaping () -> Bool = { true }, sender: @escaping (String) -> Bool) {
        guard let id else { return }
        let previous = senders[id]
        let sameSource = identity == nil ? previous?.source == nil : previous?.source === identity
        let generation = sameSource ? previous?.generation ?? UUID() : UUID()
        senders[id] = Route(sender: sender, ready: ready, source: identity, generation: generation)
    }
    func remove(_ id: UUID?) { if let id { senders[id] = nil } }
    func insert(_ text: String, into id: UUID) -> Bool {
        guard !CredentialAccessGate.shared.isLocked else { return false }
        guard !text.contains("\0"), text.utf8.count <= 65536 else { return false }
        return senders[id]?.sender(text) ?? false
    }
    func prepare(_ ids: Set<UUID>, command: String) throws -> [Recipient] {
        _ = try CredentialAccessGate.shared.check()
        guard !ids.isEmpty, ids.count <= 100, !command.isEmpty, command.utf8.count <= 32768,
              command.rangeOfCharacter(from: .controlCharacters) == nil else { throw WorkflowError.invalid("Select 1–100 terminals and enter a single-line command without control characters.") }
        return try ids.sorted { $0.uuidString < $1.uuidString }.map { id in
            guard let route = senders[id], route.ready() else { throw WorkflowError.invalid("A selected terminal is disconnected or at an authentication prompt. Nothing was sent.") }
            return Recipient(id: id, generation: route.generation)
        }
    }
    func execute(_ command: String, recipients: [Recipient]) throws -> [UUID: Bool] {
        guard !recipients.isEmpty, Set(recipients.map(\.id)).count == recipients.count else { throw WorkflowError.invalid("Invalid recipient selection.") }
        let fresh = try prepare(Set(recipients.map(\.id)), command: command)
        guard Set(fresh.map { "\($0.id):\($0.generation)" }) == Set(recipients.map { "\($0.id):\($0.generation)" }) else { throw WorkflowError.invalid("A selected terminal restarted. Nothing was sent; review recipients again.") }
        // No suspension between preflight and writes. Per-target acceptance is
        // not a remote execution guarantee and cannot be an atomic transaction.
        return Dictionary(uniqueKeysWithValues: recipients.map { ($0.id, insert(command + "\r", into: $0.id)) })
    }
}
private struct CommandRouterKey: EnvironmentKey { static let defaultValue: TerminalCommandRouter? = nil }
private struct SessionIDKey: EnvironmentKey { static let defaultValue: UUID? = nil }
extension EnvironmentValues {
    var commandRouter: TerminalCommandRouter? { get { self[CommandRouterKey.self] } set { self[CommandRouterKey.self] = newValue } }
    var sessionTabID: UUID? { get { self[SessionIDKey.self] } set { self[SessionIDKey.self] = newValue } }
}

struct SnippetManagerView: View {
    @EnvironmentObject private var library: WorkflowLibrary
    @EnvironmentObject private var appState: AppState
    let router: TerminalCommandRouter
    @State private var snippet = CommandSnippet(name: "", command: "")
    @State private var values: [String: String] = [:]
    @State private var target: UUID?
    @State private var preview = ""
    @State private var error: String?
    @State private var confirmRun = false
    private var terminals: [SessionTab] { appState.tabs.filter { $0.tool == .primary && [.localShell, .ssh, .telnet, .serial].contains($0.connection.kind) } }
    private func targetLabel(_ tab: SessionTab) -> String { tab.title + " · tab " + String((appState.tabs.firstIndex(where: { $0.id == tab.id }) ?? 0) + 1) }
    var body: some View {
        HSplitView {
            List {
                Button("New Snippet") { snippet = .init(name: "", command: ""); values = [:]; preview = "" }
                ForEach(library.snippets.sorted { $0.name < $1.name }) { item in
                    Button(item.group + " / " + item.name) { snippet = item; values = [:]; preview = "" }.buttonStyle(.plain)
                }
            }.frame(minWidth: 180, idealWidth: 220, maxWidth: 280)
            VStack(alignment: .leading, spacing: 10) {
                TextField("Snippet name", text: $snippet.name)
                TextField("Group", text: $snippet.group)
                Text("Command Template").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $snippet.command).font(.system(.body, design: .monospaced)).frame(minHeight: 120)
                Text("Use unquoted {{parameter}} placeholders. Do not save passwords/tokens in snippets. No credentials are automatically substituted.").font(.caption).foregroundStyle(.secondary)
                Toggle("Shell-quote parameter values", isOn: $snippet.quoteParameters)
                Toggle("Confirm before executing", isOn: $snippet.confirmExecution)
                if !snippet.parameters.isEmpty {
                    ScrollView {
                        VStack(spacing: 6) { ForEach(Array(snippet.parameters.prefix(32)), id: \.self) { parameter in
                            TextField(parameter, text: Binding(get: { values[parameter] ?? "" }, set: { values[parameter] = $0 }))
                        } }
                    }.frame(maxHeight: 150)
                }
                Picker("Target terminal", selection: $target) {
                    Text("Select a terminal").tag(nil as UUID?)
                    ForEach(terminals) { Text(targetLabel($0)).tag($0.id as UUID?) }
                }
                Text(preview).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxHeight: 100)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                if let notice = library.notice { Text(notice).foregroundStyle(.orange) }
                HStack {
                    Button("Save") { do { try library.save(snippet); error = nil } catch { self.error = error.localizedDescription } }
                    Button("Delete", role: .destructive) { do { try library.deleteSnippet(snippet.id); snippet = .init(name: "", command: "") } catch { self.error = error.localizedDescription } }
                    Spacer()
                    Button("Preview") { render() }
                    Button("Insert") { if render() { send(execute: false) } }.disabled(target == nil)
                    Button("Run…") { if render() { if snippet.confirmExecution || CommandSnippet.requiresConfirmation(preview) { confirmRun = true } else { send(execute: true) } } }.disabled(target == nil)
                }
            }.padding(16).frame(minWidth: 460)
        }.frame(minWidth: 760, minHeight: 560)
        .onAppear { target = appState.selectedTabID }
        .confirmationDialog("Execute on \(terminals.first { $0.id == target }.map(targetLabel) ?? "the selected terminal")?", isPresented: $confirmRun, titleVisibility: .visible) {
            Button("Execute") { send(execute: true) }; Button("Cancel", role: .cancel) {}
        } message: { Text(preview) }
    }
    @discardableResult private func render() -> Bool {
        do { preview = try snippet.render(values); error = nil; return true } catch { self.error = error.localizedDescription; return false }
    }
    private func send(execute: Bool) {
        if !execute, CommandSnippet.requiresConfirmation(preview) {
            error = "Newlines/control characters may execute immediately in a terminal. Use Run and confirm it instead."; return
        }
        guard let target, terminals.contains(where: { $0.id == target }), router.insert(preview + (execute ? "\r" : ""), into: target) else {
            error = "The selected terminal is closed or waiting for credentials. Connect it first."; return
        }
    }
}

struct QuickConnectView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected: String?
    @FocusState private var focused: Bool
    private var connections: [RemoteConnection] { appState.connections.filter { ConnectionSearch.matches($0, query: query) } }
    private var actions: [String] { ["SSH Tunnels", "Command Snippets", "Help"].filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) } }
    private struct VMResult: Identifiable { let host: RemoteConnection; let vm: VirtualMachine; var id: String { "vm:" + host.id.uuidString + ":" + vm.id } }
    private var machines: [VMResult] {
        appState.connections.flatMap { host in
            (appState.vmInventory[host.id] ?? []).filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.node.localizedCaseInsensitiveContains(query) || host.name.localizedCaseInsensitiveContains(query) }.map { VMResult(host: host, vm: $0) }
        }
    }
    private var ids: [String] { connections.map { $0.id.uuidString } + actions + machines.map(\.id) }
    var body: some View {
        VStack {
            TextField("Find a connection, IP, group, or action", text: $query).textFieldStyle(.roundedBorder).focused($focused).onSubmit(open)
            List(selection: $selected) {
                ForEach(connections) { connection in
                    VStack(alignment: .leading) {
                        Label(connection.name, systemImage: connection.kind.systemImage)
                        if let endpoint = settings.sidebarEndpoint(for: connection) { Text(endpoint).font(.caption).foregroundStyle(.secondary) }
                    }.tag(connection.id.uuidString).onTapGesture(count: 2) { selected = connection.id.uuidString; open() }
                }
                ForEach(actions, id: \.self) { action in Text(action).tag(action).onTapGesture(count: 2) { selected = action; open() } }
                ForEach(machines) { result in
                    Label(result.vm.name + " — " + result.host.name, systemImage: "desktopcomputer").tag(result.id)
                        .onTapGesture(count: 2) { selected = result.id; open() }
                }
            }
            HStack { Text("↑ ↓ select · Return opens").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Open", action: open).keyboardShortcut(.defaultAction).disabled(ids.isEmpty) }
        }.padding(16).frame(width: 560, height: 440)
        .onAppear { focused = true; selected = ids.first }
        .onChange(of: query) { _, _ in selected = ids.first }
        .onMoveCommand { direction in
            guard !ids.isEmpty, direction == .up || direction == .down else { return }
            let index = ids.firstIndex(of: selected ?? "") ?? 0
            selected = ids[min(ids.count - 1, max(0, index + (direction == .down ? 1 : -1)))]
        }
    }
    private func open() {
        let id = selected ?? ids.first
        if let connection = connections.first(where: { $0.id.uuidString == id }) { appState.open(connection) }
        else if let result = machines.first(where: { $0.id == id }) { appState.openVMConsole(result.vm, on: result.host) }
        else if id == "SSH Tunnels" { openWindow(id: "ssh-tunnels") }
        else if id == "Command Snippets" { openWindow(id: "command-snippets") }
        else if id == "Help" { openWindow(id: NethrivaWindow.help) }
        dismiss()
    }
}
