import AppKit
import SwiftUI

struct SessionLayout: Equatable {
    enum Split: String { case none, horizontal, vertical }
    private(set) var split: Split = .none
    private(set) var panes: [UUID] = []
    private(set) var weights: [CGFloat] = []
    private(set) var selection: UUID?
    var detached = Set<UUID>()
    mutating func select(_ id: UUID?) {
        if let id, !detached.contains(id) { selection = id }
    }
    mutating func prune(_ ids: Set<UUID>) {
        detached.formIntersection(ids)
        let removed = panes.filter { !ids.contains($0) || detached.contains($0) }
        for id in removed { removePane(id) }
        if let selection, !ids.contains(selection) || detached.contains(selection) { self.selection = panes.first }
    }
    func visible(_ tabs: [SessionTab]) -> [UUID] {
        let main = tabs.map(\.id).filter { !detached.contains($0) }
        guard let selected = selection.flatMap({ main.contains($0) ? $0 : nil }) ?? main.first else { return [] }
        let group = panes.filter { main.contains($0) }
        return split != .none && group.count > 1 && group.contains(selected) ? group : [selected]
    }
    func canSplit(_ id: UUID, tabs: [SessionTab]) -> Bool {
        !detached.contains(id) && tabs.contains(where: { $0.id == id })
            && tabs.contains(where: { $0.id != id && !detached.contains($0.id) })
    }
    mutating func showSplit(with id: UUID, tabs: [SessionTab], direction: Split) {
        guard direction != .none, canSplit(id, tabs: tabs) else { return }
        prune(Set(tabs.map(\.id)))
        if !panes.contains(id) {
            let anchor = selection.flatMap { selected in
                tabs.contains(where: { $0.id == selected && selected != id && !detached.contains(selected) }) ? selected : nil
            } ?? visible(tabs).first(where: { $0 != id })
                ?? tabs.first(where: { $0.id != id && !detached.contains($0.id) })?.id
            guard let anchor else { return }
            panes = [anchor, id]; equalize()
        }
        split = direction; selection = id
    }
    func isSSHSplit(tabs: [SessionTab]) -> Bool {
        panes.count > 1 && panes.allSatisfy { id in
            !detached.contains(id) && tabs.contains { $0.id == id && $0.connection.kind == .ssh && $0.tool == .primary }
        }
    }
    func canAddSSH(_ id: UUID, tabs: [SessionTab]) -> Bool {
        isSSHSplit(tabs: tabs) && panes.count < 4 && !panes.contains(id) && !detached.contains(id)
            && tabs.contains { $0.id == id && $0.connection.kind == .ssh && $0.tool == .primary }
    }
    mutating func addSSH(_ id: UUID, tabs: [SessionTab]) {
        guard canAddSSH(id, tabs: tabs) else { return }
        let share = 1 / CGFloat(panes.count + 1)
        weights = SessionSplitMetrics.normalized(weights).map { $0 * (1 - share) } + [share]
        panes.append(id); selection = id
    }
    mutating func removePane(_ id: UUID) {
        guard let index = panes.firstIndex(of: id) else { return }
        panes.remove(at: index)
        if weights.indices.contains(index) { weights.remove(at: index) }
        if panes.count < 2 { panes = []; weights = []; split = .none }
        else { weights = SessionSplitMetrics.normalized(weights) }
    }
    mutating func showSingle(_ id: UUID) {
        if panes.contains(id) { panes = []; weights = []; split = .none }
        select(id)
    }
    mutating func equalize() { weights = Array(repeating: 1 / CGFloat(max(1, panes.count)), count: panes.count) }
    mutating func resize(divider: Int, delta: CGFloat, metrics: SessionSplitMetrics) {
        guard metrics.lengths.count == panes.count else { return }
        weights = metrics.resizing(divider: divider, delta: delta)
    }
}

/// Geometry is independent of tab focus. Only the two panes beside a dragged
/// divider change size; the native session surfaces themselves remain retained.
struct SessionSplitMetrics {
    static let dividerWidth: CGFloat = 12
    let horizontal: Bool
    let size: CGSize
    let gap: CGFloat
    let minimum: CGFloat
    let lengths: [CGFloat]
    static func normalized(_ values: [CGFloat]) -> [CGFloat] {
        let values = values.map { $0.isFinite ? max(0, $0) : 0 }
        let sum = values.reduce(0, +)
        guard sum.isFinite, sum > 0 else { return Array(repeating: 1 / CGFloat(max(1, values.count)), count: values.count) }
        return values.map { $0 / sum }
    }
    init(size: CGSize, direction: SessionLayout.Split, weights: [CGFloat]) {
        self.size = CGSize(width: max(0, size.width), height: max(0, size.height))
        horizontal = direction != .vertical
        let count = max(1, weights.count), total = horizontal ? self.size.width : self.size.height
        gap = count > 1 ? min(Self.dividerWidth, total / CGFloat(count - 1)) : 0
        let available = max(0, total - gap * CGFloat(count - 1))
        let minimum = min(96, available / CGFloat(count))
        self.minimum = minimum
        let extra = max(0, available - minimum * CGFloat(count))
        lengths = Self.normalized(weights.isEmpty ? [1] : weights).map { minimum + extra * $0 }
    }
    func paneFrame(_ index: Int) -> CGRect {
        let origin = lengths.prefix(index).reduce(0, +) + gap * CGFloat(index)
        return horizontal ? CGRect(x: origin, y: 0, width: lengths[index], height: size.height)
            : CGRect(x: 0, y: origin, width: size.width, height: lengths[index])
    }
    func dividerFrame(_ index: Int) -> CGRect {
        let origin = lengths.prefix(index + 1).reduce(0, +) + gap * CGFloat(index)
        return horizontal ? CGRect(x: origin, y: 0, width: gap, height: size.height)
            : CGRect(x: 0, y: origin, width: size.width, height: gap)
    }
    func resizing(divider index: Int, delta: CGFloat) -> [CGFloat] {
        guard lengths.indices.contains(index), lengths.indices.contains(index + 1), delta.isFinite else { return Self.normalized(lengths.map { max(0, $0 - minimum) }) }
        var changed = lengths
        let pair = lengths[index] + lengths[index + 1]
        changed[index] = min(pair - minimum, max(minimum, lengths[index] + delta))
        changed[index + 1] = pair - changed[index]
        return Self.normalized(changed.map { max(0, $0 - minimum) })
    }
}

@MainActor
final class SessionLifetime {
    private var cleanup: [String: () -> Void] = [:]
    private var started = Set<String>()
    private var closed = false
    var focus: (() -> Void)?
    func own(_ key: String, cleanup: @escaping () -> Void) { if closed { cleanup() } else { self.cleanup[key] = cleanup } }
    func claimStart(_ key: String) -> Bool { !closed && started.insert(key).inserted }
    func close() { closed = true; focus = nil; let actions = Array(cleanup.values); cleanup.removeAll(); actions.forEach { $0() } }
}
private struct SessionLifetimeKey: EnvironmentKey { static let defaultValue: SessionLifetime? = nil }
private struct SplitSessionKey: EnvironmentKey { static let defaultValue = false }
private struct SessionWindowActionKey: EnvironmentKey { static let defaultValue: OpenWindowAction? = nil }
extension EnvironmentValues {
    var sessionOpenWindow: OpenWindowAction? { get { self[SessionWindowActionKey.self] } set { self[SessionWindowActionKey.self] = newValue } }
    var sessionIsSplit: Bool { get { self[SplitSessionKey.self] } set { self[SplitSessionKey.self] = newValue } }
    var sessionLifetime: SessionLifetime? { get { self[SessionLifetimeKey.self] } set { self[SessionLifetimeKey.self] = newValue } }
}

/// Retains a single hosting surface per live tab. Reparenting moves that same
/// view to a split pane/window; it never constructs another protocol session.
@MainActor
final class SessionSurfaceStore: ObservableObject {
    @Published private(set) var revision = 0
    @MainActor struct Entry {
        let controller: RetainedSessionController
        let lifetime: SessionLifetime
        var view: NSView { controller.view }
    }
    private(set) var entries: [UUID: Entry] = [:]
    private var windows: [UUID: DetachedSessionWindow] = [:]
    private weak var state: AppState?
    private var settings: AppSettings?
    private var recovery: SessionRecovery?
    private var editors: RemoteFileEditors?
    private var inputMonitor: Any?
    private var windowObserver: NSObjectProtocol?
    var surfaceFactory: ((SessionTab) -> AnyView)?
    var openWindow: OpenWindowAction?
    let router = TerminalCommandRouter()
    let terminalTools = TerminalExperience()
    func configure(state: AppState, settings: AppSettings, recovery: SessionRecovery, editors: RemoteFileEditors) {
        self.state = state; self.settings = settings; self.recovery = recovery
        self.editors = editors
        if windowObserver == nil {
            windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                Task { @MainActor [weak self] in
                    guard let self, let state = self.state else { return }
                    let candidates = state.tabs.map(\.id).filter { self.entries[$0]?.view.window === window && self.entries[$0]?.view.isHidden == false }
                    if let id = candidates.first(where: { $0 == state.selectedTabID }) ?? candidates.first { self.activate(id) }
                }
            }
        }
        if inputMonitor == nil {
            inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let content = event.window?.contentView,
                      let hit = content.hitTest(content.convert(event.locationInWindow, from: nil)) else { return event }
                if let id = entries.first(where: { hit === $0.value.view || hit.isDescendant(of: $0.value.view) })?.key,
                   self.state?.selectedTabID != id { self.activate(id) }
                return event
            }
        }
        sync()
    }
    func sync() {
        guard let state, let settings, let recovery, let editors else { return }
        let ids = Set(state.tabs.map(\.id))
        state.layout.prune(ids)
        for id in Array(entries.keys) where !ids.contains(id) { close(id) }
        for tab in state.tabs {
            let lifetime = entries[tab.id]?.lifetime ?? SessionLifetime()
            let content = surfaceFactory?(tab) ?? AnyView(SessionSurface(tab: tab))
            let root = AnyView(content
                .environmentObject(state).environmentObject(settings).environmentObject(recovery)
                .environmentObject(editors)
                .environment(\.sessionOpenWindow, openWindow)
                .environment(\.sessionLifetime, lifetime).environment(\.sessionTabID, tab.id).environment(\.commandRouter, router)
                .environment(\.terminalAppearance, state.libraryTools.appearance(for: tab.connection))
                .environment(\.terminalExperience, terminalTools)
                .environmentObject(state.libraryTools)
                .environment(\.sessionIsActive, state.selectedTabID == tab.id)
                .environment(\.sessionIsSplit, state.layout.panes.count > 1 && state.layout.panes.contains(tab.id)).id(tab.id))
            if let entry = entries[tab.id] { entry.controller.host.rootView = root }
            else {
                let controller = RetainedSessionController(root: root)
                entries[tab.id] = Entry(controller: controller, lifetime: lifetime)
            }
        }
        revision += 1
    }
    func detach(_ id: UUID) {
        guard !CredentialAccessGate.shared.isLocked else { return }
        guard let state, let tab = state.tabs.first(where: { $0.id == id }) else { return }
        if let existing = windows[id] { existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return }
        state.layout.detached.insert(id)
        state.layout.prune(Set(state.tabs.map(\.id)))
        let controller = DetachedSessionWindow(store: self, id: id, title: tab.title)
        windows[id] = controller
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        state.selectedTabID = id
        sync()
    }
    func dock(_ id: UUID) {
        guard let state else { return }
        if let controller = windows.removeValue(forKey: id) { controller.window?.delegate = nil; controller.window?.close() }
        state.layout.detached.remove(id); state.selectedTabID = id
        sync()
    }
    func activate(_ id: UUID) {
        guard !CredentialAccessGate.shared.isLocked, state?.tabs.contains(where: { $0.id == id }) == true else { return }
        state?.selectedTabID = id; sync()
        if let window = windows[id]?.window { window.makeKeyAndOrderFront(nil) }
    }
    func isDetached(_ id: UUID) -> Bool { state?.layout.detached.contains(id) == true }
    func isSelected(_ id: UUID) -> Bool { state?.selectedTabID == id }
    func close(_ id: UUID) {
        router.remove(id)
        terminalTools.close(id)
        if let controller = windows.removeValue(forKey: id) { controller.window?.delegate = nil; controller.window?.close() }
        if let entry = entries.removeValue(forKey: id) {
            entry.lifetime.close(); entry.controller.removeFromParent(); entry.view.removeFromSuperview(); entry.controller.host.rootView = AnyView(EmptyView())
        }
    }
    deinit {
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
    }
}

final class RetainedSessionController: NSViewController {
    let host: NSHostingView<AnyView>
    init(root: AnyView) {
        host = NSHostingView(rootView: root)
        host.sizingOptions = []; host.sceneBridgingOptions = []
        host.wantsLayer = true; host.layer?.masksToBounds = true
        super.init(nibName: nil, bundle: nil); view = host
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
}

private final class DetachedSessionWindow: NSWindowController, NSWindowDelegate {
    private weak var store: SessionSurfaceStore?
    private let id: UUID
    init(store: SessionSurfaceStore, id: UUID, title: String) {
        self.store = store; self.id = id
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title; window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: VStack(spacing: 0) {
            HStack { Text("Detached session").font(.caption); Spacer(); Button("Return to Workspace") { [weak store] in store?.dock(id) } }.padding(8)
            SessionMount(store: store, id: id, detached: true)
        })
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    func windowShouldClose(_ sender: NSWindow) -> Bool { store?.dock(id); return false }
    func windowDidBecomeKey(_ notification: Notification) { store?.activate(id) }
}

/// SwiftUI owns layout markers, not live session descendants. Native session
/// hosts sit beside the SwiftUI shell in a plain AppKit content container.
/// This avoids migrating a live hosting graph between different SwiftUI graphs.
struct SessionMount: NSViewRepresentable {
    @ObservedObject var store: SessionSurfaceStore
    let id: UUID
    var detached = false
    var visible = true
    func makeNSView(context: Context) -> SessionViewportMarker {
        let marker = SessionViewportMarker(); update(marker); return marker
    }
    func updateNSView(_ marker: SessionViewportMarker, context: Context) { update(marker) }
    private func update(_ marker: SessionViewportMarker) {
        marker.place = { [weak store] marker in
            guard let store, store.isDetached(id) == detached, let entry = store.entries[id], let window = marker.window else { return }
            let container: SessionWindowContainer
            if let existing = window.contentViewController as? SessionWindowContainer { container = existing }
            else {
                guard let content = window.contentView else { return }
                container = SessionWindowContainer(original: content, controller: window.contentViewController)
                window.contentViewController = container
            }
            let host = entry.view
            let relocated = host.superview !== container.view
            if relocated {
                host.removeFromSuperview(); container.view.addSubview(host)
            }
            host.translatesAutoresizingMaskIntoConstraints = true
            host.autoresizingMask = []
            host.frame = marker.convert(marker.bounds, to: container.view)
            host.isHidden = CredentialAccessGate.shared.isLocked || !visible || marker.bounds.width <= 0 || marker.bounds.height <= 0
            if relocated, !host.isHidden {
                DispatchQueue.main.async { [weak store, weak host] in
                    guard host?.window?.isKeyWindow == true, store?.isSelected(id) == true else { return }
                    entry.lifetime.focus?()
                }
            }
        }
        marker.schedulePlacement()
    }
}

final class SessionViewportMarker: NSView {
    var place: ((SessionViewportMarker) -> Void)?
    private var scheduled = false
    func schedulePlacement() {
        guard !scheduled else { return }; scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; scheduled = false; place?(self)
        }
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); schedulePlacement() }
    override func setFrameSize(_ size: NSSize) { super.setFrameSize(size); schedulePlacement() }
    override func setFrameOrigin(_ point: NSPoint) { super.setFrameOrigin(point); schedulePlacement() }
    override func layout() { super.layout(); schedulePlacement() }
}

private final class SessionWindowContainer: NSViewController {
    init(original: NSView, controller: NSViewController?) {
        super.init(nibName: nil, bundle: nil)
        view = NSView(frame: original.frame)
        if let controller { controller.removeFromParent(); addChild(controller) }
        original.removeFromSuperview(); original.frame = view.bounds; original.autoresizingMask = [.width, .height]
        view.addSubview(original)
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
}

struct SessionSurface: View {
    let tab: SessionTab
    @Environment(\.terminalExperience) private var experience
    @EnvironmentObject private var library: LibraryTools
    @ViewBuilder var body: some View {
        VStack(spacing: 0) {
            if tab.tool == .primary, DefaultField.appearance.supports(tab.connection.kind), let experience {
                TerminalSessionTools(id: tab.id, experience: experience, library: library)
            }
            surface
        }.environment(\.terminalAppearance, library.appearance(for: tab.connection))
    }
    @ViewBuilder private var surface: some View {
        if let vm = tab.virtualMachine { VMConsoleSessionView(connection: tab.connection, virtualMachine: vm) }
        else if tab.tool == .sftp { SFTPBrowserView(connection: tab.connection) }
        else {
            switch tab.connection.kind {
            case .localShell: LocalTerminalSessionView()
            case .ssh: SSHSessionView(connection: tab.connection)
            case .telnet: TelnetSessionView(connection: tab.connection)
            case .serial: SerialSessionView(connection: tab.connection)
            case .rdp: RDPSessionView(connection: tab.connection)
            case .virtualization: VirtualizationHostView(connection: tab.connection)
            case .vnc, .spice: VMConsoleSessionView(connection: tab.connection, virtualMachine: nil)
            }
        }
    }
}
