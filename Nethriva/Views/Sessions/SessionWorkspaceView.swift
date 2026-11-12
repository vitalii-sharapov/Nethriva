import AppKit
import SwiftUI

struct SessionWorkspaceView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var recovery: SessionRecovery
    @EnvironmentObject private var surfaces: SessionSurfaceStore

    var body: some View {
        VStack(spacing: 0) {
            if recovery.suspended {
                Label("Network interrupted. Transfers require explicit Retry.", systemImage: "network.slash").font(.caption).padding(8)
            }
            SessionTabBar()
            Divider()
            if appState.tabs.contains(where: { !appState.layout.detached.contains($0.id) }) {
                GeometryReader { geometry in
                    let visible = appState.layout.visible(appState.tabs)
                    let split = visible.count > 1
                    let metrics = SessionSplitMetrics(size: geometry.size, direction: appState.layout.split,
                                                      weights: appState.layout.panes.count > 1 ? appState.layout.weights : [1])
                    ZStack(alignment: .topLeading) {
                        ForEach(appState.tabs.filter { !appState.layout.detached.contains($0.id) }) { tab in
                            // Keep hidden group members at their split dimensions;
                            // changing tabs must not resize a background SSH PTY.
                            let frame = appState.layout.panes.firstIndex(of: tab.id).map { metrics.paneFrame($0) }
                                ?? CGRect(origin: .zero, size: geometry.size)
                            SessionMount(store: surfaces, id: tab.id, visible: visible.contains(tab.id))
                                .frame(width: frame.width, height: frame.height)
                                .clipped()
                                .offset(x: frame.minX, y: frame.minY)
                                .opacity(visible.contains(tab.id) ? 1 : 0)
                                .allowsHitTesting(visible.contains(tab.id))
                                .accessibilityHidden(!visible.contains(tab.id))
                                .simultaneousGesture(TapGesture().onEnded { surfaces.activate(tab.id) })
                        }
                        if split {
                            ForEach(0..<(visible.count - 1), id: \.self) { index in
                                let frame = metrics.dividerFrame(index)
                                SessionPaneDivider(horizontal: metrics.horizontal, index: index, resize: { delta in
                                    guard appState.layout.panes == visible else { return }
                                    appState.layout.resize(divider: index, delta: delta, metrics: metrics)
                                }, equalize: { appState.layout.equalize() })
                                .frame(width: frame.width, height: frame.height)
                                .offset(x: frame.minX, y: frame.minY)
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView {
                    VStack(spacing: 12) {
                        Image("NethrivaMark").resizable().scaledToFit().frame(width: 76, height: 76).accessibilityHidden(true)
                        Text(appState.tabs.isEmpty ? "No Open Sessions" : "No Docked Sessions")
                    }
                } description: {
                    Text("Open a connection with Command-K, or return a detached session to the workspace.")
                } actions: {
                    if appState.selectedConnection != nil { Button("Open Selected Connection") { appState.openSelectedConnection() } }
                }
            }
        }
        .onChange(of: appState.tabs) { _, _ in surfaces.sync() }
        .onChange(of: appState.selectedTabID) { _, _ in surfaces.sync() }
        .onChange(of: appState.layout) { old, new in
            // Moving a divider updates only marker geometry, not hosting roots.
            if old.visible(appState.tabs) != new.visible(appState.tabs) || old.detached != new.detached { surfaces.sync() }
        }
        .task { surfaces.openWindow = openWindow; surfaces.sync() }
    }
}

private struct SessionPaneDivider: NSViewRepresentable {
    let horizontal: Bool
    let index: Int
    let resize: (CGFloat) -> Void
    let equalize: () -> Void
    func makeNSView(context: Context) -> SessionPaneDividerView { SessionPaneDividerView() }
    func updateNSView(_ view: SessionPaneDividerView, context: Context) {
        view.horizontal = horizontal; view.onResize = resize; view.onEqualize = equalize
        view.identifier = NSUserInterfaceItemIdentifier("SessionPaneDivider-\(index)")
        view.setAccessibilityLabel("Resize session panes \(index + 1) and \(index + 2)")
    }
}

/// Uses window coordinates and captures the original geometry for the whole
/// drag. Moving the divider must not move the gesture's coordinate space.
final class SessionPaneDividerView: NSView {
    var horizontal = true {
        didSet { if oldValue != horizontal { window?.invalidateCursorRects(for: self); needsDisplay = true } }
    }
    var onResize: (CGFloat) -> Void = { _ in }
    var onEqualize: () -> Void = {}
    private var dragOrigin: NSPoint?
    private var dragResize: ((CGFloat) -> Void)?
    private var hovering = false
    private var tracking: NSTrackingArea?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolTip = "Drag to resize sessions. Double-click for equal sizes."
        setAccessibilityElement(true); setAccessibilityRole(.splitter)
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: horizontal ? .resizeLeftRight : .resizeUpDown) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount > 1 { onEqualize(); return }
        dragOrigin = event.locationInWindow; dragResize = onResize
    }
    override func mouseDragged(with event: NSEvent) {
        guard let dragOrigin else { return }
        let delta = horizontal ? event.locationInWindow.x - dragOrigin.x : dragOrigin.y - event.locationInWindow.y
        dragResize?(delta)
    }
    override func mouseUp(with event: NSEvent) { dragOrigin = nil; dragResize = nil }
    override func accessibilityPerformIncrement() -> Bool { onResize(20); return true }
    override func accessibilityPerformDecrement() -> Bool { onResize(-20); return true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        (hovering ? NSColor.controlAccentColor : NSColor.separatorColor).setFill()
        let line = horizontal ? NSRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height)
            : NSRect(x: 0, y: bounds.midY - 0.5, width: bounds.width, height: 1)
        line.fill()
        for offset in [CGFloat(-4), 0, 4] {
            let point = horizontal ? NSPoint(x: bounds.midX, y: bounds.midY + offset)
                : NSPoint(x: bounds.midX + offset, y: bounds.midY)
            NSBezierPath(ovalIn: NSRect(x: point.x - 1.5, y: point.y - 1.5, width: 3, height: 3)).fill()
        }
    }
}
