import AppKit
import SwiftUI
import XCTest
@testable import Nethriva

final class WorkflowTests: XCTestCase {
    func testJumpHostChainsPreserveOrderAndValidatePorts() throws {
        XCTAssertEqual(try SSHJumpChain.validate("admin@bastion.example.invalid:2222,inner,[2001:db8::1]:22"), ["admin@bastion.example.invalid:2222", "inner", "[2001:db8::1]:22"])
        XCTAssertEqual(try SSHJumpChain.validate(""), [])
        for bad in ["-oProxyCommand=x", "host\nother", "host,", "host:0", "host:65536", "[::1]:abc", "user@@host", "host/other", "2001:db8::1", Array(repeating: "host", count: 9).joined(separator: ",")] {
            XCTAssertThrowsError(try SSHJumpChain.validate(bad), bad)
        }
    }
    func testSavedJumpDestinationBracketsIPv6() {
        let host = RemoteConnection(name: "Synthetic", kind: .ssh, host: "2001:db8::2", port: 2222, username: "admin")
        XCTAssertEqual(SSHJumpChain.destination(host), "admin@[2001:db8::2]:2222")
    }
    func testSnippetRenderingQuotesParametersWithoutRecursiveExpansion() throws {
        let snippet = CommandSnippet(name: "Lookup", command: "printf %s {{name}}; echo {{name}} {{next}}")
        XCTAssertEqual(snippet.parameters, ["name", "next"])
        XCTAssertEqual(try snippet.render(["name": "a'b;$(id)", "next": "{{name}}"]), "printf %s 'a'\"'\"'b;$(id)'; echo 'a'\"'\"'b;$(id)' '{{name}}'")
        XCTAssertThrowsError(try snippet.render([:]))
        XCTAssertThrowsError(try snippet.render(["name": "\0", "next": "x"]))
        XCTAssertTrue(snippet.confirmExecution)
        XCTAssertTrue(CommandSnippet.requiresConfirmation("echo one\necho two")); XCTAssertTrue(CommandSnippet.requiresConfirmation("\u{1b}[A"))
        XCTAssertFalse(CommandSnippet.requiresConfirmation("echo one"))
        XCTAssertThrowsError(try CommandSnippet(name: "Empty", command: "").render([:]))
        XCTAssertThrowsError(try CommandSnippet(name: "Huge", command: String(repeating: "x", count: 32769)).render([:]))
        XCTAssertThrowsError(try CommandSnippet(name: "Too many", command: (0..<33).map { "{{p\($0)}}" }.joined(separator: " ")).render([:]))
    }
    @MainActor func testRouterRequiresRegisteredLiveTarget() {
        let router = TerminalCommandRouter(), id = UUID()
        var received = ""
        XCTAssertFalse(router.insert("echo test", into: id))
        router.register(id) { received = $0; return true }
        XCTAssertTrue(router.insert("echo test", into: id)); XCTAssertEqual(received, "echo test")
        XCTAssertFalse(router.insert("\0", into: id)); XCTAssertFalse(router.insert(String(repeating: "x", count: 65537), into: id))
        router.remove(id); XCTAssertFalse(router.insert("echo test", into: id))
    }
    @MainActor func testWorkflowLibraryRoundTripAndCorruptDataPreserved() throws {
        let suite = "WorkflowTests." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = WorkflowLibrary(defaults: defaults), host = UUID()
        let snippet = CommandSnippet(name: "Synthetic", command: "echo {{value}}")
        let tunnel = TunnelConfiguration(name: "Synthetic", connectionID: host, listenPort: 1088)
        try library.save(snippet); try library.save(tunnel)
        let restored = WorkflowLibrary(defaults: defaults)
        XCTAssertEqual(restored.snippets, [snippet]); XCTAssertEqual(restored.tunnels, [tunnel])
        XCTAssertNotNil(defaults.data(forKey: "workflow.library.v1.backup"))
        let corrupt = Data("invalid".utf8); defaults.set(corrupt, forKey: "workflow.library.v1")
        let damaged = WorkflowLibrary(defaults: defaults)
        XCTAssertNotNil(damaged.notice); XCTAssertThrowsError(try damaged.save(snippet))
        XCTAssertEqual(defaults.data(forKey: "workflow.library.v1"), corrupt)
    }
    func testTunnelArgumentsAreIsolatedFromUserForwardingConfiguration() throws {
        let host = RemoteConnection(name: "Synthetic", kind: .ssh, host: "host.example.invalid")
        let socket = try SSHConnectionReuse.controlPath(for: host).replacingOccurrences(of: "%C", with: String(repeating: "a", count: 40))
        let tunnel = TunnelConfiguration(name: "Synthetic", connectionID: UUID(), listenPort: 1089, destinationHost: "2001:db8::3", destinationPort: 443)
        let args = try TunnelControl.arguments("forward", tunnel: tunnel, socket: socket)
        XCTAssertEqual(Array(args.prefix(4)), ["-F", "none", "-S", socket])
        XCTAssertTrue(args.contains("127.0.0.1:1089:[2001:db8::3]:443"))
        XCTAssertTrue(try SSHConnectionReuse.arguments(for: host).contains("ClearAllForwardings=yes"))
        XCTAssertThrowsError(try TunnelControl.arguments("forward", tunnel: tunnel, socket: "/tmp/foreign.socket"))
        XCTAssertThrowsError(try TunnelControl.arguments("exit", tunnel: tunnel, socket: socket))
        var invalid = tunnel; invalid.listenPort = 22; XCTAssertThrowsError(try invalid.validate())
        invalid = tunnel; invalid.destinationHost = "x\ny"; XCTAssertThrowsError(try invalid.validate())
        var socks = tunnel; socks.kind = .socks; XCTAssertEqual(socks.specification, "127.0.0.1:1089"); XCTAssertEqual(socks.flag, "-D")
        var remote = tunnel; remote.kind = .remote; XCTAssertEqual(remote.flag, "-R")
        let console = try TunnelControl.consoleForwardArguments("forward", specification: "127.0.0.1:44222:/tmp/console.sock", socket: socket)
        XCTAssertEqual(Array(console.prefix(4)), ["-F", "none", "-S", socket])
        XCTAssertTrue(console.contains("127.0.0.1:44222:/tmp/console.sock")); XCTAssertFalse(console.contains("ClearAllForwardings=yes"))
        XCTAssertThrowsError(try TunnelControl.consoleForwardArguments("forward", specification: "0.0.0.0:44222:host:5900", socket: socket))
        XCTAssertThrowsError(try TunnelControl.consoleForwardArguments("forward", specification: "127.0.0.1:44222:host\nother", socket: socket))
    }
    func testSplitLayoutDoesNotDisplayDetachedOrClosedTabs() {
        let tabs = (0..<3).map { _ in SessionTab(connection: .localShell) }
        var layout = SessionLayout(); layout.select(tabs[0].id)
        layout.showSplit(with: tabs[1].id, tabs: tabs, direction: .horizontal)
        XCTAssertEqual(layout.visible(tabs), [tabs[0].id, tabs[1].id])
        layout.select(tabs[1].id); XCTAssertEqual(layout.panes, [tabs[0].id, tabs[1].id])
        layout.detached.insert(tabs[1].id); layout.prune(Set(tabs.map(\.id)))
        XCTAssertEqual(layout.visible(tabs), [tabs[0].id]); XCTAssertEqual(layout.split, .none)
        layout.prune([tabs[2].id]); XCTAssertEqual(layout.visible([tabs[2]]), [tabs[2].id]); XCTAssertTrue(layout.detached.isEmpty)
    }
    func testNewSessionOpensAloneAndReturningRestoresSSHSplit() {
        let ssh = RemoteConnection(name: "Synthetic SSH", kind: .ssh, host: "host.example.invalid")
        let tabs = [SessionTab(connection: ssh), SessionTab(connection: ssh),
                    SessionTab(connection: RemoteConnection(name: "Synthetic RDP", kind: .rdp, host: "desktop.example.invalid"))]
        var layout = SessionLayout()
        layout.select(tabs[0].id)
        layout.showSplit(with: tabs[1].id, tabs: tabs, direction: .horizontal)
        layout.select(tabs[2].id)
        XCTAssertEqual(layout.visible(tabs), [tabs[2].id])
        layout.select(tabs[0].id)
        XCTAssertEqual(layout.visible(tabs), [tabs[0].id, tabs[1].id])
    }
    func testSSHGroupSupportsFourPanesAndKeepsSizesAcrossSingleSessions() {
        let ssh = RemoteConnection(name: "Synthetic SSH", kind: .ssh, host: "host.example.invalid")
        let tabs = (0..<5).map { _ in SessionTab(connection: ssh) } + [
            SessionTab(connection: .localShell), SessionTab(connection: ssh, tool: .sftp),
            SessionTab(connection: RemoteConnection(name: "Synthetic RDP", kind: .rdp, host: "desktop.example.invalid"))]
        var layout = SessionLayout(); layout.select(tabs[0].id)
        layout.showSplit(with: tabs[1].id, tabs: tabs, direction: .horizontal)
        layout.addSSH(tabs[2].id, tabs: tabs); layout.addSSH(tabs[3].id, tabs: tabs)
        XCTAssertEqual(layout.visible(tabs), Array(tabs.prefix(4)).map(\.id))
        let metrics = SessionSplitMetrics(size: CGSize(width: 1400, height: 600), direction: layout.split, weights: layout.weights)
        layout.resize(divider: 1, delta: 150, metrics: metrics)
        let savedWeights = layout.weights
        for tab in tabs.suffix(4) {
            layout.select(tab.id)
            XCTAssertEqual(layout.visible(tabs), [tab.id])
            XCTAssertEqual(layout.weights, savedWeights)
            XCTAssertFalse(layout.canAddSSH(tab.id, tabs: tabs))
        }
        layout.select(tabs[2].id)
        XCTAssertEqual(layout.visible(tabs).count, 4)
        XCTAssertEqual(layout.weights, savedWeights)
        layout.addSSH(tabs[4].id, tabs: tabs)
        XCTAssertEqual(layout.panes.count, 4)
        layout.removePane(tabs[1].id)
        XCTAssertEqual(layout.panes, [tabs[0].id, tabs[2].id, tabs[3].id])
        XCTAssertTrue(layout.canAddSSH(tabs[4].id, tabs: tabs))
        XCTAssertFalse(layout.canAddSSH(tabs[6].id, tabs: tabs))
        XCTAssertFalse(layout.canAddSSH(tabs[7].id, tabs: tabs))
        layout.detached.insert(tabs[2].id); layout.prune(Set(tabs.map(\.id)))
        XCTAssertEqual(layout.panes, [tabs[0].id, tabs[3].id])
        XCTAssertEqual(layout.weights.reduce(0, +), 1, accuracy: 0.000001)
        layout.prune(Set(tabs.dropFirst().map(\.id)))
        XCTAssertTrue(layout.panes.isEmpty); XCTAssertEqual(layout.split, .none)
    }
    func testEveryDividerResizesOnlyItsAdjacentPanesAndPreservesBounds() {
        let size = CGSize(width: 1400, height: 900)
        for direction in [SessionLayout.Split.horizontal, .vertical] {
            for count in 2...4 {
                let original = SessionSplitMetrics(size: size, direction: direction, weights: Array(repeating: 1, count: count))
                for index in 0..<(count - 1) {
                    let moved = SessionSplitMetrics(size: size, direction: direction, weights: original.resizing(divider: index, delta: 60))
                    XCTAssertEqual(moved.lengths[index], original.lengths[index] + 60, accuracy: 0.000001)
                    XCTAssertEqual(moved.lengths[index + 1], original.lengths[index + 1] - 60, accuracy: 0.000001)
                    for other in 0..<count where other != index && other != index + 1 {
                        XCTAssertEqual(moved.lengths[other], original.lengths[other], accuracy: 0.000001)
                    }
                    for delta in [CGFloat(-10000), 10000] {
                        let clamped = SessionSplitMetrics(size: size, direction: direction, weights: original.resizing(divider: index, delta: delta))
                        XCTAssertTrue(clamped.lengths.allSatisfy { $0 >= clamped.minimum - 0.000001 })
                        XCTAssertEqual(clamped.lengths.reduce(0, +) + clamped.gap * CGFloat(count - 1),
                                       direction == .horizontal ? size.width : size.height, accuracy: 0.000001)
                        XCTAssertFalse(clamped.paneFrame(index).intersects(clamped.dividerFrame(index)))
                        XCTAssertFalse(clamped.paneFrame(index + 1).intersects(clamped.dividerFrame(index)))
                    }
                }
            }
        }
        let tiny = SessionSplitMetrics(size: CGSize(width: 20, height: 10), direction: .horizontal, weights: [1, 1, 1, 1])
        XCTAssertTrue(tiny.lengths.allSatisfy { $0 >= 0 && $0.isFinite })
        XCTAssertEqual(tiny.lengths.reduce(0, +) + tiny.gap * 3, 20, accuracy: 0.000001)
    }
    @MainActor func testDividerDragUsesWindowCoordinatesAndOriginalGeometry() throws {
        let view = SessionPaneDividerView(frame: NSRect(x: 300, y: 0, width: 12, height: 500))
        var original: [CGFloat] = [], replacement: [CGFloat] = [], resets = 0
        view.onResize = { original.append($0) }; view.onEqualize = { resets += 1 }
        func event(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat = 100, clicks: Int = 1) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: [],
                                            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
        }
        view.mouseDown(with: try event(.leftMouseDown, x: 306))
        view.mouseDragged(with: try event(.leftMouseDragged, x: 406))
        view.frame.origin.x = 400
        view.onResize = { replacement.append($0) }
        view.mouseDragged(with: try event(.leftMouseDragged, x: 456))
        view.mouseUp(with: try event(.leftMouseUp, x: 456))
        XCTAssertEqual(original, [100, 150]); XCTAssertTrue(replacement.isEmpty)
        XCTAssertTrue(view.accessibilityPerformIncrement()); XCTAssertEqual(replacement, [20])
        view.mouseDown(with: try event(.leftMouseDown, x: 456, clicks: 2)); XCTAssertEqual(resets, 1)
        view.horizontal = false
        view.mouseDown(with: try event(.leftMouseDown, x: 10, y: 200))
        view.mouseDragged(with: try event(.leftMouseDragged, x: 10, y: 140))
        view.mouseUp(with: try event(.leftMouseUp, x: 10, y: 140))
        XCTAssertEqual(replacement, [20, 60])
    }
    @MainActor func testOpeningRDPAndSSHInAppStateDoesNotReplaceSplitMembers() {
        let suite = "SplitOpeningTests." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(store: UserDefaultsConnectionStore(defaults: defaults, storageKey: "connections"), groupStore: UserDefaultsConnectionGroupStore(defaults: defaults))
        let ssh = RemoteConnection(name: "Synthetic SSH", kind: .ssh, host: "host.example.invalid")
        state.open(ssh); state.open(ssh)
        let ids = state.tabs.map(\.id)
        state.layout.showSplit(with: ids[0], tabs: state.tabs, direction: .horizontal)
        state.selectedTabID = ids[0]
        let group = state.layout.panes
        state.open(RemoteConnection(name: "Synthetic RDP", kind: .rdp, host: "desktop.example.invalid"))
        XCTAssertEqual(state.layout.visible(state.tabs), [state.tabs.last!.id])
        state.openSFTP(ssh); XCTAssertEqual(state.layout.visible(state.tabs), [state.tabs.last!.id])
        state.open(ssh)
        let added = state.tabs.last!.id
        XCTAssertEqual(state.layout.visible(state.tabs), [added])
        state.layout.addSSH(added, tabs: state.tabs)
        XCTAssertEqual(state.layout.visible(state.tabs), group + [added])
        state.close(tabID: group[0])
        XCTAssertEqual(state.layout.panes, [group[1], added])
        state.selectedTabID = group[1]
        XCTAssertEqual(state.layout.visible(state.tabs), [group[1], added])
        state.tabs.map(\.id).forEach { state.close(tabID: $0) }
    }
    @MainActor func testRejectedTunnelDoesNotCancelUnownedForward() async {
        let host = RemoteConnection(name: "Synthetic", kind: .ssh, host: "host.example.invalid")
        let tunnel = TunnelConfiguration(name: "Synthetic", connectionID: host.id)
        var calls: [String] = [], releases = 0
        let manager = TunnelManager(resolveSocket: { _ in "/synthetic/socket" }, control: { operation, _, _ in
            calls.append(operation)
            if operation == "forward" { throw WorkflowError.invalid("Rejected") }
        })
        manager.onReleased = { _ in releases += 1 }; manager.start(tunnel, host: host)
        for _ in 0..<100 { if manager.active[tunnel.id] == nil { break }; await Task.yield() }
        XCTAssertEqual(calls, ["check", "forward"]); XCTAssertTrue(manager.leases.isEmpty); XCTAssertEqual(releases, 1)
    }
    @MainActor func testUncertainTunnelRequiresExplicitStopAndKeepsLease() async {
        let host = RemoteConnection(name: "Synthetic", kind: .ssh, host: "host.example.invalid")
        let tunnel = TunnelConfiguration(name: "Synthetic", connectionID: host.id)
        var calls: [String] = []
        let manager = TunnelManager(resolveSocket: { _ in "/synthetic/socket" }, control: { operation, _, _ in
            calls.append(operation); if operation == "forward" { throw TunnelControl.Failure.uncertain }
        })
        manager.start(tunnel, host: host)
        for _ in 0..<100 { if manager.status[tunnel.id]?.contains("uncertain") == true { break }; await Task.yield() }
        XCTAssertEqual(manager.leases, [host]); XCTAssertEqual(calls, ["check", "forward"])
        manager.start(tunnel, host: host); XCTAssertEqual(calls.count, 2)
        manager.stop(tunnel.id)
        for _ in 0..<100 { if manager.active[tunnel.id] == nil { break }; await Task.yield() }
        XCTAssertEqual(calls, ["check", "forward", "cancel"]); XCTAssertTrue(manager.leases.isEmpty)
    }
    @MainActor func testSessionLifetimeCleansExactlyOnceAndRejectsLateStarts() {
        let lifetime = SessionLifetime(); var count = 0
        XCTAssertTrue(lifetime.claimStart("session")); XCTAssertFalse(lifetime.claimStart("session"))
        lifetime.own("session") { count += 1 }; lifetime.close(); lifetime.close(); XCTAssertEqual(count, 1)
        XCTAssertNil(lifetime.focus)
        XCTAssertFalse(lifetime.claimStart("late")); lifetime.own("late") { count += 1 }; XCTAssertEqual(count, 2)
    }
    @MainActor func testHostingSurfaceAndNativeViewRetainedWhenMoved() async throws {
        let suite = "SurfaceTests." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(store: UserDefaultsConnectionStore(defaults: defaults, storageKey: "connections"), groupStore: UserDefaultsConnectionGroupStore(defaults: defaults))
        let store = SessionSurfaceStore(), counter = SurfaceCounter()
        store.surfaceFactory = { _ in AnyView(SyntheticNativeSurface(counter: counter)) }
        store.configure(state: state, settings: AppSettings(defaults: defaults), recovery: SessionRecovery(), editors: RemoteFileEditors())
        state.open(.localShell); store.sync()
        let id = try XCTUnwrap(state.tabs.first?.id), entry = try XCTUnwrap(store.entries[id])
        let first = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let second = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        first.isReleasedWhenClosed = false; second.isReleasedWhenClosed = false
        defer { first.contentView = nil; second.contentView = nil; first.close(); second.close() }
        first.contentView = entry.view; entry.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(counter.makes, 1)
        first.contentView = nil; second.contentView = entry.view; store.sync(); entry.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(store.entries[id]?.view === entry.view); XCTAssertEqual(counter.makes, 1); XCTAssertEqual(counter.dismantles, 0)
        second.contentView = nil
        first.contentView = NSHostingView(rootView: SessionMount(store: store, id: id))
        first.contentView?.layoutSubtreeIfNeeded()
        for _ in 0..<2 {
            store.detach(id)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(state.layout.detached.contains(id))
            XCTAssertTrue(store.entries[id]?.view === entry.view)
            store.dock(id); first.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertFalse(state.layout.detached.contains(id))
        }
        XCTAssertEqual(counter.makes, 1); XCTAssertEqual(counter.dismantles, 0)
        var cleanups = 0; entry.lifetime.own("synthetic") { cleanups += 1 }
        state.close(tabID: id); store.sync(); store.close(id)
        XCTAssertEqual(cleanups, 1); XCTAssertNil(store.entries[id])
    }
    func testRemoteTextLimitsAndHashDetectSameSizeChanges() throws {
        let first = try RemoteTextSnapshot(data: Data("before".utf8), mode: 0o640)
        let next = try RemoteTextSnapshot(data: Data("after!".utf8), mode: 0o640)
        XCTAssertNotEqual(first.fingerprint, next.fingerprint)
        XCTAssertThrowsError(try RemoteTextSnapshot(data: Data([0xff]), mode: 0o600))
        XCTAssertThrowsError(try RemoteTextSnapshot.encode("\0"))
        XCTAssertThrowsError(try RemoteTextSnapshot.encode(String(repeating: "x", count: 2097153)))
    }
    @MainActor func testRemoteEditorCancellationKeepsUnsavedBuffer() {
        let suite = "EditorTests." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(store: UserDefaultsConnectionStore(defaults: defaults, storageKey: "connections"), groupStore: UserDefaultsConnectionGroupStore(defaults: defaults))
        let connection = RemoteConnection(name: "Synthetic", kind: .ssh, host: "host.example.invalid")
        let item = SFTPFileItem(name: "synthetic.txt", path: "/synthetic.txt", isDirectory: false, isSymbolicLink: false, size: 0, permissions: "-rw-------", modifiedText: "")
        let model = RemoteTextEditorModel(connection: connection, item: item, appState: state)
        model.text = "unsaved synthetic edits"; model.cancel()
        XCTAssertEqual(model.text, "unsaved synthetic edits"); XCTAssertFalse(model.busy)
        XCTAssertTrue(model.error?.contains("verify the remote file") == true)
        model.close(); XCTAssertEqual(model.text, "")
    }
    @MainActor func testWorkspaceMarkersTrackSplitFramesAndInactiveVisibility() async throws {
        let suite = "WorkspaceTests." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(store: UserDefaultsConnectionStore(defaults: defaults, storageKey: "connections"), groupStore: UserDefaultsConnectionGroupStore(defaults: defaults))
        let store = SessionSurfaceStore(), recovery = SessionRecovery(), counter = SurfaceCounter()
        store.surfaceFactory = { _ in AnyView(SyntheticNativeSurface(counter: counter)) }
        store.configure(state: state, settings: AppSettings(defaults: defaults), recovery: recovery, editors: RemoteFileEditors())
        state.open(.localShell); state.open(.localShell); store.sync()
        let ids = state.tabs.map(\.id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { for id in ids { store.close(id) }; window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView: SessionWorkspaceView().environmentObject(state).environmentObject(recovery).environmentObject(store))
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let first = try XCTUnwrap(store.entries[ids[0]]?.view), second = try XCTUnwrap(store.entries[ids[1]]?.view)
        XCTAssertTrue(first.isHidden); XCTAssertFalse(second.isHidden)
        state.layout.showSplit(with: ids[0], tabs: state.tabs, direction: .horizontal)
        state.selectedTabID = ids[0]
        let metrics = SessionSplitMetrics(size: CGSize(width: 1000, height: 550), direction: .horizontal, weights: state.layout.weights)
        state.layout.resize(divider: 0, delta: 150, metrics: metrics)
        store.sync(); window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(first.isHidden); XCTAssertFalse(second.isHidden)
        XCTAssertGreaterThan(second.frame.width, first.frame.width)
        XCTAssertFalse(first.frame.intersects(second.frame))
        XCTAssertGreaterThan(first.frame.height, 300)
        XCTAssertTrue(first.superview === second.superview)
        XCTAssertFalse(first.superview is NSHostingView<AnyView>)
        XCTAssertEqual(counter.makes, 2); XCTAssertEqual(counter.dismantles, 0)
        state.layout.showSingle(ids[1]); state.selectedTabID = ids[1]; store.sync()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(first.isHidden); XCTAssertFalse(second.isHidden); XCTAssertEqual(counter.makes, 2)
    }
    @MainActor func testFourNativePanesHaveWorkingDividersAndRestoreAfterRDP() async throws {
        let suite = "FourPaneTests." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(store: UserDefaultsConnectionStore(defaults: defaults, storageKey: "connections"), groupStore: UserDefaultsConnectionGroupStore(defaults: defaults))
        let store = SessionSurfaceStore(), recovery = SessionRecovery(), counter = SurfaceCounter()
        store.surfaceFactory = { _ in AnyView(SyntheticNativeSurface(counter: counter)) }
        store.configure(state: state, settings: AppSettings(defaults: defaults), recovery: recovery, editors: RemoteFileEditors())
        let ssh = RemoteConnection(name: "Synthetic SSH", kind: .ssh, host: "host.example.invalid")
        for _ in 0..<4 { state.open(ssh) }
        let ids = state.tabs.map(\.id)
        state.selectedTabID = ids[0]
        state.layout.showSplit(with: ids[1], tabs: state.tabs, direction: .horizontal)
        state.layout.addSSH(ids[2], tabs: state.tabs); state.layout.addSSH(ids[3], tabs: state.tabs)
        state.selectedTabID = ids[3]; store.sync()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 750), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { state.tabs.map(\.id).forEach { store.close($0) }; window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView: SessionWorkspaceView().environmentObject(state).environmentObject(recovery).environmentObject(store))
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        let views = try ids.map { try XCTUnwrap(store.entries[$0]?.view) }
        XCTAssertTrue(views.allSatisfy { !$0.isHidden && $0.frame.width >= 96 })
        XCTAssertEqual(counter.makes, 4); XCTAssertEqual(counter.dismantles, 0)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
        let content = try XCTUnwrap(window.contentView)
        let dividers = descendants(content).compactMap { $0 as? SessionPaneDividerView }
        XCTAssertEqual(dividers.count, 3)
        for divider in dividers {
            let point = divider.convert(NSPoint(x: divider.bounds.midX, y: divider.bounds.midY), to: content)
            XCTAssertTrue(content.hitTest(point) === divider, "A native terminal must not cover its resize handle")
        }
        let divider = try XCTUnwrap(dividers.first { $0.identifier?.rawValue == "SessionPaneDivider-1" })
        let point = divider.convert(NSPoint(x: divider.bounds.midX, y: divider.bounds.midY), to: nil)
        let initial = views.map { $0.frame.width }, revision = store.revision
        func event(_ type: NSEvent.EventType, delta: CGFloat) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: point.x + delta, y: point.y), modifierFlags: [],
                                            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        divider.mouseDown(with: try event(.leftMouseDown, delta: 0))
        divider.mouseDragged(with: try event(.leftMouseDragged, delta: 40))
        divider.mouseUp(with: try event(.leftMouseUp, delta: 40))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(views[0].frame.width, initial[0], accuracy: 1)
        XCTAssertEqual(views[1].frame.width, initial[1] + 40, accuracy: 1)
        XCTAssertEqual(views[2].frame.width, initial[2] - 40, accuracy: 1)
        XCTAssertEqual(views[3].frame.width, initial[3], accuracy: 1)
        XCTAssertEqual(store.revision, revision, "Dragging must not replace live hosting roots")
        let resizedWeights = state.layout.weights
        let resizedFrames = views.map(\.frame)
        state.open(RemoteConnection(name: "Synthetic RDP", kind: .rdp, host: "desktop.example.invalid"))
        let rdpID = try XCTUnwrap(state.tabs.last?.id)
        try await Task.sleep(for: .milliseconds(200))
        let rdp = try XCTUnwrap(store.entries[rdpID]?.view)
        XCTAssertTrue(views.allSatisfy(\.isHidden)); XCTAssertFalse(rdp.isHidden)
        XCTAssertEqual(views.map(\.frame), resizedFrames, "Hidden SSH terminals must keep their viewport while another tab is full-size")
        XCTAssertGreaterThan(rdp.frame.width, 1300)
        state.selectedTabID = ids[2]
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(views.allSatisfy { !$0.isHidden }); XCTAssertTrue(rdp.isHidden)
        XCTAssertEqual(state.layout.weights, resizedWeights)
        XCTAssertEqual(counter.makes, 5); XCTAssertEqual(counter.dismantles, 0)
    }
    func testBundledHelpIncludesWorkflowTools() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "NethrivaHelp", withExtension: "html"))
        let help = try String(contentsOf: url, encoding: .utf8)
        for topic in ["Detach to Window", "Command-K", "SSH Tunnels", "Configure Jump Chain", "Edit Remote File", "Command Snippets"] { XCTAssertTrue(help.contains(topic), topic) }
    }
    func testRemoteEditorConflictsPreserveNewerContentAndExplicitOverwriteWorks() async throws {
        try await Task.detached {
            let fixture = try LocalSFTPFixture(); defer { fixture.close() }
            let file = fixture.root.appendingPathComponent("edit.txt")
            try Data("initial".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
            let baseline = try fixture.channel.readText(file.path)
            try Data("changed".utf8).write(to: file)
            XCTAssertThrowsError(try fixture.channel.saveText(Data("edited".utf8), path: file.path, baseline: baseline, overwriteChanged: false))
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "changed")
            let saved = try fixture.channel.saveText(Data("edited".utf8), path: file.path, baseline: baseline, overwriteChanged: true)
            XCTAssertEqual(saved.text, "edited"); XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "edited")
            XCTAssertEqual(try fixture.channel.attributes(file.path)?.mode.map { $0 & 0o777 }, 0o640)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).contains { $0.hasSuffix(".partial") })
            let link = fixture.root.appendingPathComponent("link.txt")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
            XCTAssertThrowsError(try fixture.channel.readText(link.path))
            try Data([0, 255]).write(to: file); XCTAssertThrowsError(try fixture.channel.readText(file.path))
        }.value
    }
}

private final class SurfaceCounter { var makes = 0; var dismantles = 0 }
private struct SyntheticNativeSurface: NSViewRepresentable {
    let counter: SurfaceCounter
    func makeCoordinator() -> SurfaceCounter { counter }
    func makeNSView(context: Context) -> NSView { counter.makes += 1; return NSView() }
    func updateNSView(_ view: NSView, context: Context) {}
    static func dismantleNSView(_ view: NSView, coordinator: SurfaceCounter) { coordinator.dismantles += 1 }
}
