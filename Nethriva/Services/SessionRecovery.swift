import AppKit
import Network
import SwiftUI

private struct SessionIsActiveKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var sessionIsActive: Bool {
        get { self[SessionIsActiveKey.self] }
        set { self[SessionIsActiveKey.self] = newValue }
    }
}

/// Focus only on activation, not every SwiftUI redraw or background connection.
@MainActor
final class SessionFocusGate {
    nonisolated init() {}
    private(set) var active = false
    private var generation = UUID()
    func update(_ active: Bool, focus: @escaping () -> Void) {
        guard self.active != active else { return }
        self.active = active; generation = UUID()
        guard active else { return }
        let generation = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active, self.generation == generation else { return }
            focus()
        }
    }
}

enum BackgroundWork {
    static func run<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try work()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

enum VMInventorySearch {
    static func filter(_ machines: [VirtualMachine], query: String) -> [VirtualMachine] {
        guard !query.isEmpty else { return machines }
        return machines.filter { [$0.name, $0.id, $0.node, $0.state.displayName].contains { $0.localizedCaseInsensitiveContains(query) } }
    }
}

/// One application observer, rather than one path monitor for every terminal.
/// Recovery is debounced; file writes and terminal commands are never replayed.
@MainActor
final class SessionRecovery: ObservableObject {
    @Published private(set) var suspended = false
    @Published private(set) var epoch = 0
    private var sleeping = false
    private var available = true
    private var signature: String?
    private var pending: Task<Void, Never>?
    private let monitor = NWPathMonitor()
    private var observers: [NSObjectProtocol] = []
    init(observeSystem: Bool = true) {
        guard observeSystem else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleep() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.wake() }
        })
        monitor.pathUpdateHandler = { [weak self] path in
            let signature = path.availableInterfaces.filter { path.usesInterfaceType($0.type) }.map(\.name).sorted().joined(separator: ",")
            let available = path.status == .satisfied
            Task { @MainActor in self?.network(available: available, signature: signature) }
        }
        monitor.start(queue: DispatchQueue(label: "com.vitalii.nethriva.recovery"))
    }
    deinit {
        pending?.cancel(); monitor.cancel()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
    func sleep() { sleeping = true; suspend() }
    func wake() { sleeping = false; schedule() }
    func network(available: Bool, signature: String) {
        let changed = self.signature != nil && self.signature != signature
        let restored = !self.available && available
        self.signature = signature; self.available = available
        if !available || changed { suspend() }
        if available && (changed || restored || suspended) { schedule() }
    }
    private func suspend() { pending?.cancel(); pending = nil; suspended = true }
    private func schedule() {
        guard !sleeping, available, suspended else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)); try Task.checkCancellation(); self?.finishRecovery() } catch {}
        }
    }
    func finishRecovery() {
        guard !sleeping, available, suspended else { return }
        suspended = false; epoch += 1
    }
}

struct ConnectionCheckButton: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.sessionOpenWindow) private var sessionOpenWindow
    let connection: RemoteConnection
    var body: some View {
        Button { (sessionOpenWindow ?? openWindow)(id: "connection-check", value: ConnectionEditorRequest(connection: connection)) } label: {
            Label("Connection Check", systemImage: "stethoscope")
        }
        .help("Check reachability without logging in; optional SSH authentication check")
    }
}
