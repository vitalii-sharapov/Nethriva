import AppKit
import SwiftUI

struct RDPSessionView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var recovery: SessionRecovery
    @Environment(\.sessionLifetime) private var lifetime
    @State private var recoveryPending = false
    @StateObject private var controller: RDPSessionController

    let connection: RemoteConnection

    init(connection: RemoteConnection) {
        self.connection = connection
        _controller = StateObject(wrappedValue: RDPSessionController(connection: connection))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("RDP", systemImage: "display")
                    .font(.subheadline.weight(.semibold))

                if let endpoint = settings.sessionEndpoint(for: connection) {
                    Text(endpoint)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer()
                ConnectionCheckButton(connection: connection).labelStyle(.iconOnly)
                Button { controller.fitToScreen() } label: { Label("Fit Screen", systemImage: "arrow.down.right.and.arrow.up.left") }
                    .labelStyle(.iconOnly).disabled(!controller.isRunning)
                    .help("Reapply the current tab size and restore desktop keyboard focus")

                if !controller.viewportDescription.isEmpty {
                    Text(controller.viewportDescription)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Menu {
                    ForEach(RDPViewportSizing.supportedDisplayScales, id: \.self) { scale in
                        Button {
                            controller.setDisplayScale(scale)
                        } label: {
                            HStack {
                                Text(controller.displayScaleLabel(for: scale))
                                if controller.displayScale == scale {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Label("\(controller.displayScale)%", systemImage: "textformat.size")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Change the size of text and controls in the remote Windows session")

                Button { controller.sendCtrlAltDel() } label: { Label("Ctrl+Alt+Del", systemImage: "keyboard") }
                    .labelStyle(.iconOnly).help("Send Ctrl+Alt+Del to Windows")
                    .disabled(!controller.isRunning)

                Button {
                    controller.pasteFromMac()
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                .disabled(!controller.isRunning || !connection.effectiveRDPClipboard)
                .help(connection.effectiveRDPClipboard ? "Paste Mac text or copied Finder files into Windows" : "Enable clipboard and file transfers in this connection's settings before connecting")
                if connection.effectiveRDPClipboard {
                    Label("Clipboard shared", systemImage: "doc.on.clipboard").font(.caption2).foregroundStyle(.secondary)
                }

                Label(controller.compactStatus, systemImage: controller.statusIcon)
                    .font(.caption)
                    .foregroundStyle(controller.statusColor)

                if let credentialSaveError = controller.credentialSaveError {
                    Label("Credentials not saved", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help(credentialSaveError)
                }

                if controller.canDisconnect {
                    Button("Disconnect", role: .destructive) {
                        recoveryPending = false
                        controller.stop()
                    }
                } else if controller.canReconnect {
                    Button("Reconnect") {
                        recoveryPending = false
                        controller.reconnect()
                    }
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(.bar)

            Divider()

            ZStack {
                Color.black
                EmbeddedRDPSurface(controller: controller)

                if controller.showsOverlay {
                    statusOverlay
                }

                if controller.isDropTargeted {
                    dropOverlay
                }

                if let transferMessage = controller.transferMessage {
                    VStack {
                        Spacer()
                        Label(transferMessage, systemImage: "checkmark.circle.fill")
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(.regularMaterial, in: Capsule())
                            .shadow(radius: 8, y: 3)
                            .padding(.bottom, 18)
                    }
                    .allowsHitTesting(false)
                }
            }
            .clipped()
        }
        .task {
            lifetime?.own("rdp") { [controller = controller] in controller.stop() }
            do {
                guard ConnectionSecurityConsent.confirmRDP(connection) else { controller.showError("Connection cancelled before credentials were read."); return }
                let password = try await appState.sessionPassword(for: connection)
                try Task.checkCancellation(); _ = try appState.credentialGate.check()
                controller.configure(
                    password: password,
                    saveCredentials: { credentials in
                        try appState.saveRDPLogin(credentials, for: connection.id, expectedConnection: connection)
                    }
                )
            } catch {
                controller.showError("Could not read the saved password: \(error.localizedDescription)")
            }
        }
        .onDisappear {
            if lifetime == nil { controller.stop() }
        }
        .onChange(of: recovery.suspended) { _, suspended in
            if suspended, controller.canDisconnect { recoveryPending = true; controller.stop() }
        }
        .onChange(of: recovery.epoch) { _, _ in
            if recoveryPending, settings.recoverNetworkSessions { recoveryPending = false; controller.reconnect() }
        }
    }

    private var dropOverlay: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 38))
            Text("Drop to paste into Windows")
                .font(.title3.weight(.semibold))
            Text("The item will be streamed to the active Windows folder or desktop")
                .font(.callout)
        }
        .foregroundStyle(.white)
        .padding(26)
        .background(Color.accentColor.opacity(0.88), in: RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 16)
        .allowsHitTesting(false)
    }

    private var statusOverlay: some View {
        RDPStatusPanel(
            title: controller.statusTitle,
            detail: controller.statusDetail,
            icon: controller.statusIcon,
            iconColor: controller.statusColor,
            isLaunching: controller.isLaunching,
            reconnect: controller.canReconnect ? { controller.reconnect() } : nil
        )
        .padding(30)
    }
}

struct RDPStatusPanel: View {
    let title: String
    let detail: String
    let icon: String
    let iconColor: Color
    let isLaunching: Bool
    var reconnect: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            if isLaunching {
                ProgressView().controlSize(.large)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 38))
                    .foregroundStyle(iconColor)
            }
            Text(title)
                .font(.title2.weight(.semibold))
            ScrollView {
                Text(detail)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: 240)
            if let reconnect {
                Button("Reconnect", action: reconnect)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .foregroundStyle(.primary)
        .padding(28)
        .frame(maxWidth: 580)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 18)
    }
}

private struct EmbeddedRDPSurface: NSViewRepresentable {
    @ObservedObject var controller: RDPSessionController
    func makeCoordinator() -> SessionFocusGate { SessionFocusGate() }

    func makeNSView(context: Context) -> EmbeddedRDPContainerView {
        let view = EmbeddedRDPContainerView()
        view.onViewportChange = { [weak controller = controller] size in
            controller?.viewportChanged(to: size)
        }
        view.onDropTargetChange = { [weak controller = controller] targeted in
            controller?.setDropTargeted(targeted)
        }
        view.onFilesDropped = { [weak controller = controller] urls, point in
            controller?.receiveDroppedFiles(urls, at: point)
        }
        controller.attach(to: view)
        context.environment.sessionLifetime?.focus = { [weak controller] in controller?.restoreFocus() }
        controller.setSurfaceActive(context.environment.sessionIsActive)
        context.coordinator.update(context.environment.sessionIsActive) { controller.restoreFocus() }
        return view
    }

    func updateNSView(_ nsView: EmbeddedRDPContainerView, context: Context) {
        controller.attach(to: nsView)
        controller.setSurfaceActive(context.environment.sessionIsActive)
        context.coordinator.update(context.environment.sessionIsActive) { controller.restoreFocus() }
    }

    static func dismantleNSView(_ nsView: EmbeddedRDPContainerView, coordinator: SessionFocusGate) {
        nsView.onViewportChange = nil
        nsView.onDropTargetChange = nil
        nsView.onFilesDropped = nil
        nsView.removeRemoteView()
    }
}

@MainActor
private final class EmbeddedRDPContainerView: NSView {
    var onViewportChange: ((CGSize) -> Void)?
    var onDropTargetChange: ((Bool) -> Void)?
    var onFilesDropped: (([URL], CGPoint) -> Void)?
    private weak var remoteView: NSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        remoteView?.frame = bounds
        reportViewport()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportViewport()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let acceptsFiles = fileURLs(from: sender.draggingPasteboard).isEmpty == false
        onDropTargetChange?(acceptsFiles)
        return acceptsFiles ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDropTargetChange?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        fileURLs(from: sender.draggingPasteboard).isEmpty == false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender.draggingPasteboard)
        let point = convert(sender.draggingLocation, from: nil)
        onDropTargetChange?(false)
        guard !urls.isEmpty else { return false }
        onFilesDropped?(urls, point)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        onDropTargetChange?(false)
    }

    func install(remoteView: NSView) {
        guard self.remoteView !== remoteView else { return }
        removeRemoteView()
        self.remoteView = remoteView
        remoteView.frame = bounds
        remoteView.autoresizingMask = [.width, .height]
        addSubview(remoteView)
        reportViewport()
    }

    func removeRemoteView() {
        remoteView?.removeFromSuperview()
        remoteView = nil
    }

    private func reportViewport() {
        guard bounds.width >= 200, bounds.height >= 200 else { return }
        onViewportChange?(bounds.size)
    }

    private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) ?? []
        return objects.compactMap { ($0 as? NSURL).map { $0 as URL } }
    }
}

@MainActor
final class RDPSessionController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case launching
        case running
        case stopped
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var viewportDescription = ""
    @Published private(set) var displayScale: Int
    @Published private(set) var isDropTargeted = false
    @Published private(set) var transferMessage: String?
    @Published private(set) var credentialSaveError: String?

    private var connection: RemoteConnection
    private weak var container: EmbeddedRDPContainerView?
    private var session: EmbeddedRDPSession?
    private var password: String?
    private var saveCredentials: ((RDPCredentialCandidate) throws -> RemoteConnection)?
    private var credentialsReady = false
    private var viewport: CGSize?
    private var monitorTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var transferMessageTask: Task<Void, Never>?
    private var surfaceActive = true

    init(connection: RemoteConnection) {
        self.connection = connection
        displayScale = RDPViewportSizing.validatedDisplayScale(connection.effectiveRDPScale)
    }

    deinit {
        monitorTask?.cancel()
        resizeTask?.cancel()
        transferMessageTask?.cancel()
    }

    var isLaunching: Bool { phase == .idle || phase == .launching }
    var isRunning: Bool { phase == .running }
    var canDisconnect: Bool { phase == .launching || phase == .running }
    var canReconnect: Bool {
        if case .failed = phase { return true }
        return phase == .stopped
    }
    var showsOverlay: Bool { phase != .running }

    var compactStatus: String {
        switch phase {
        case .idle: "Preparing"
        case .launching: "Connecting"
        case .running: "Connected"
        case .stopped: "Disconnected"
        case .failed: "Failed"
        }
    }

    var statusTitle: String {
        switch phase {
        case .idle: "Preparing RDP Session…"
        case .launching: "Connecting…"
        case .running: "Connected"
        case .stopped: "RDP Session Disconnected"
        case .failed: "RDP Connection Failed"
        }
    }

    var statusDetail: String {
        switch phase {
        case .idle:
            "Measuring the available tab area."
        case .launching:
            "Opening the remote desktop directly inside this tab."
        case .running:
            "The remote desktop follows the size of the available workspace."
        case .stopped:
            "The remote desktop session has been closed."
        case .failed(let message):
            message
        }
    }

    var statusIcon: String {
        switch phase {
        case .running: "checkmark.circle.fill"
        case .idle, .launching: "ellipsis.circle"
        case .stopped: "rectangle.slash"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var statusColor: Color {
        switch phase {
        case .running: .green
        case .idle, .launching: .accentColor
        case .stopped: .secondary
        case .failed: .red
        }
    }

    func configure(
        password: String?,
        saveCredentials: @escaping (RDPCredentialCandidate) throws -> RemoteConnection
    ) {
        self.password = password
        self.saveCredentials = saveCredentials
        credentialsReady = true
        startIfReady()
    }

    fileprivate func attach(to container: EmbeddedRDPContainerView) {
        self.container = container
        if let session {
            container.install(remoteView: session.view)
        }
        startIfReady()
    }

    fileprivate func viewportChanged(to size: CGSize) {
        viewport = size
        let desktop = RDPViewportSizing.desktopSize(for: size)
        updateViewportDescription(desktop)

        guard session != nil else {
            startIfReady()
            return
        }

        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self, let session = self.session else { return }
            session.resize(viewport: size, desktop: desktop, displayScale: self.displayScale)
        }
    }

    func setDisplayScale(_ scale: Int) {
        let validatedScale = RDPViewportSizing.validatedDisplayScale(scale)
        guard displayScale != validatedScale else { return }
        displayScale = validatedScale

        guard let viewport else { return }
        let desktop = RDPViewportSizing.desktopSize(for: viewport)
        updateViewportDescription(desktop)
        session?.resize(viewport: viewport, desktop: desktop, displayScale: validatedScale)
    }

    func displayScaleLabel(for scale: Int) -> String {
        switch scale {
        case 140: "Larger — 140%"
        case 180: "Largest — 180%"
        default: "Comfortable — 100%"
        }
    }

    func pasteFromMac() {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: options) ?? []
        let urls = objects.compactMap { ($0 as? NSURL).map { $0 as URL } }
        if !urls.isEmpty {
            receiveDroppedFiles(urls, at: nil)
        } else {
            session?.paste()
        }
    }

    func sendCtrlAltDel() { if isRunning { session?.sendCtrlAltDel() } }
    func setSurfaceActive(_ active: Bool) { surfaceActive = active }
    func restoreFocus() { if surfaceActive, isRunning { session?.focus() } }
    func fitToScreen() {
        guard isRunning, let viewport else { return }
        session?.resize(viewport: viewport, desktop: RDPViewportSizing.desktopSize(for: viewport), displayScale: displayScale)
        restoreFocus()
    }

    fileprivate func setDropTargeted(_ targeted: Bool) {
        isDropTargeted = targeted
    }

    fileprivate func receiveDroppedFiles(_ urls: [URL], at point: CGPoint?) {
        guard !urls.isEmpty else { return }
        guard isRunning, let session else {
            showTransferMessage("Connect the RDP session before dropping files")
            return
        }
        if session.pasteFiles(urls, at: point) {
            showTransferMessage(
                "Pasting \(urls.count) item\(urls.count == 1 ? "" : "s") into Windows…"
            )
        } else {
            showTransferMessage("Windows file clipboard is not available for this session")
        }
    }

    func reconnect() {
        shutDown(markStopped: false)
        phase = .idle
        credentialSaveError = nil
        startIfReady()
    }

    func stop() {
        shutDown(markStopped: true)
    }

    func showError(_ message: String) {
        phase = .failed(message)
    }

    private func startIfReady() {
        guard !CredentialAccessGate.shared.isLocked else { return }
        guard phase == .idle,
              session == nil,
              credentialsReady,
              let container,
              let viewport else { return }

        phase = .launching
        do {
            let embeddedSession = try EmbeddedRDPSession(viewportSize: viewport)
            session = embeddedSession
            container.install(remoteView: embeddedSession.view)

            let desktop = RDPViewportSizing.desktopSize(for: viewport)
            let arguments = try FreeRDPArgumentsBuilder.arguments(
                for: connection,
                password: password,
                surface: .embedded(width: Int(desktop.width), height: Int(desktop.height)),
                displayScale: displayScale
            )
            try embeddedSession.start(arguments: arguments)
            embeddedSession.resize(viewport: viewport, desktop: desktop, displayScale: displayScale)
            beginMonitoring(embeddedSession)
        } catch {
            session?.close()
            session = nil
            container.removeRemoteView()
            phase = .failed(error.localizedDescription)
        }
    }

    private func beginMonitoring(_ monitoredSession: EmbeddedRDPSession) {
        monitorTask?.cancel()
        monitorTask = Task { [weak self, weak monitoredSession] in
            while !Task.isCancelled,
                  let self,
                  let monitoredSession,
                  self.session === monitoredSession {
                switch monitoredSession.connectionState {
                case .connected:
                    if let credentials = monitoredSession.takeCredentialsToSave() {
                        do {
                            if let saveCredentials {
                                let savedConnection = try saveCredentials(credentials)
                                self.connection = savedConnection
                                self.password = credentials.password
                            }
                        } catch {
                            self.credentialSaveError =
                                "The RDP session connected, but the credentials could not be saved: \(error.localizedDescription)"
                        }
                    }
                    if self.phase != .running {
                        self.phase = .running
                        if self.surfaceActive { monitoredSession.focus() }
                        if let viewport = self.viewport {
                            let desktop = RDPViewportSizing.desktopSize(for: viewport)
                            monitoredSession.resize(
                                viewport: viewport,
                                desktop: desktop,
                                displayScale: self.displayScale
                            )
                        }
                    }
                case .ended:
                    self.phase = .failed(self.message(for: monitoredSession.lastError))
                    return
                case .idle, .connecting:
                    break
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func shutDown(markStopped: Bool) {
        monitorTask?.cancel()
        resizeTask?.cancel()
        monitorTask = nil
        resizeTask = nil
        isDropTargeted = false
        container?.removeRemoteView()
        session?.close()
        session = nil
        if markStopped {
            phase = .stopped
        }
    }

    private func showTransferMessage(_ message: String) {
        transferMessageTask?.cancel()
        transferMessage = message
        transferMessageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.transferMessage = nil
        }
    }

    private func updateViewportDescription(_ desktop: CGSize) {
        viewportDescription = "\(Int(desktop.width)) × \(Int(desktop.height)) • \(displayScale)%"
    }

    private func message(for code: UInt32) -> String {
        switch code {
        case 0x00020014:
            "Windows rejected the username, domain, or password. Edit the connection, re-enter the password, and reconnect."
        case 0x00020006:
            "Nethriva could not reach the RDP service. Check the host, port, VPN, and firewall."
        case 0:
            "The remote computer closed the RDP session."
        default:
            "FreeRDP ended with error \(String(format: "0x%08X", code))."
        }
    }
}
