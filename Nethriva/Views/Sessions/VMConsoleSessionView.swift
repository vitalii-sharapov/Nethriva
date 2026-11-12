import AppKit
import SwiftUI
import WebKit

@MainActor
final class VMConsoleController: ObservableObject {
    @Published var status = "Disconnected"
    @Published var error: String?
    @Published var needsPassword = false
    @Published var hostWeb = false
    @Published var hyperVConnection: RemoteConnection?
    @Published var fit = true
    @Published var resizeGuest = false
    @Published var viewOnly = false
    @Published var clipboard = false
    @Published private(set) var unencrypted = false
    private var allowUnprotectedCredentials = false
    let bridge = VMConsoleWebBridge()
    let tunnel = VMSSHTunnel()
    private var backend: (any VirtualizationBackend)?
    private var http: VirtualizationHTTP?
    private var work: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var generation = UUID()
    private let connection: RemoteConnection
    private let machine: VirtualMachine?
    private var descriptor: VMConsoleDescriptor?
    private weak var webView: WKWebView?

    init(connection: RemoteConnection, machine: VirtualMachine?) {
        self.connection = connection; self.machine = machine
        viewOnly = connection.virtualization?.viewOnly ?? false
        clipboard = connection.virtualization?.shareClipboard ?? false
        bridge.onState = { [weak self] state in
            guard let self else { return }
            deadline?.cancel()
            switch state {
            case "connected": status = "Connected"; needsPassword = false
            case "hostWeb": status = "Host console"; hostWeb = true
            default: status = "Failed"; error = error ?? "The console disconnected or could not initialize. Check the VM, console permissions, and host version, then reconnect."; bridge.stop(); tunnel.stop(); descriptor = nil
            }
        }
        bridge.onCredentials = { [weak self] in
            self?.needsPassword = true; self?.status = "Console authentication"; self?.deadline?.cancel()
        }
        bridge.onError = { [weak self] message in
            guard let self else { return }
            deadline?.cancel(); needsPassword = false; status = "Failed"; error = message
            bridge.stop(); tunnel.stop(); descriptor = nil
        }
    }
    func attach(_ webView: WKWebView) {
        self.webView = webView; bridge.webView = webView
        if let descriptor, let http { load(descriptor, http: http) }
    }
    func connect(appState: AppState, consolePassword: String? = nil) {
        guard !appState.credentialGate.isLocked else { return }
        stop(); error = nil; status = "Connecting"
        guard ConnectionSecurityConsent.confirmUnverifiedHost(connection) else { status = "Disconnected"; return }
        let generation = generation
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let password: String?
                if consolePassword != nil || !ConsoleCredentialPolicy.permitsAutomaticCredentials(for: connection)
                    || connection.virtualization?.platform == .vmware && connection.virtualization?.federation != nil {
                    password = nil
                } else { password = try await appState.sessionPassword(for: connection) }
                try Task.checkCancellation(); _ = try appState.credentialGate.check()
                var descriptor: VMConsoleDescriptor
                if let machine {
                    let backend = try VirtualizationBackendFactory.make(connection: connection, password: password)
                    self.backend = backend
                    descriptor = try await backend.console(for: machine)
                } else {
                    _ = try VMInput.endpoint(for: connection)
                    try connection.virtualization?.validate()
                    descriptor = VMConsoleDescriptor(renderer: connection.kind == .spice ? .spice : .vnc,
                        host: connection.host, port: connection.port, password: password, username: connection.username)
                    descriptor.usesTLS = connection.virtualization?.consoleTransport == .tls
                    if connection.virtualization?.consoleTransport == .webSocket {
                        var components = URLComponents(url: try VMInput.endpoint(for: connection), resolvingAgainstBaseURL: false)!
                        components.scheme = "wss"
                        components.path = connection.virtualization?.consolePath ?? "/websockify"
                        descriptor.webSocketURL = components.url
                    } else if connection.virtualization?.consoleTransport != .tls, let id = connection.virtualization?.tunnelConnectionID {
                        guard let host = appState.connections.first(where: { $0.id == id && $0.kind == .ssh }) else {
                            throw VirtualizationError.message("The configured SSH tunnel host is missing. Edit this console connection to choose an SSH host.")
                        }
                        descriptor.sshHost = appState.resolvedConnection(for: host)
                    }
                }
                try Task.checkCancellation()
                guard self.generation == generation else { return }
                if let consolePassword { descriptor.password = consolePassword }
                unencrypted = !descriptor.protectsCredentials && descriptor.renderer != .hyperv && descriptor.renderer != .hostWeb
                if unencrypted, consolePassword != nil {
                    guard ConnectionSecurityConsent.confirmUnencryptedCredential() else { throw VirtualizationError.cancelled }
                    allowUnprotectedCredentials = true
                }
                if descriptor.renderer == .hyperv {
                    var rdp = connection
                    rdp.kind = .rdp; rdp.host = descriptor.host; rdp.port = descriptor.port
                    rdp.rdpVirtualMachineID = descriptor.vmID
                    rdp.rdpCertificatePolicy = connection.virtualization?.effectiveCertificatePolicy
                    rdp.rdpDisplayMode = .dynamicWindow
                    hyperVConnection = rdp; status = "Hyper-V console"
                    return
                }
                if let host = descriptor.sshHost {
                    try await tunnel.start(host: host, destination: descriptor.host, port: descriptor.port, socketPath: descriptor.sshSocketPath)
                    descriptor.host = "127.0.0.1"; descriptor.port = tunnel.port
                }
                try Task.checkCancellation()
                guard self.generation == generation else { return }
                let http = try VirtualizationHTTP(connection: connection)
                self.http = http; self.descriptor = descriptor
                hostWeb = descriptor.renderer == .hostWeb
                if webView != nil { load(descriptor, http: http) }
                startDeadline()
            } catch {
                guard self.generation == generation, !Task.isCancelled else { return }
                self.error = error.localizedDescription; status = "Failed"; tunnel.stop()
            }
        }
    }
    private func load(_ descriptor: VMConsoleDescriptor, http: VirtualizationHTTP) {
        bridge.configure(descriptor, http: http, options: ["fit": fit, "resizeGuest": resizeGuest, "viewOnly": viewOnly, "clipboard": clipboard,
            "allowUnprotectedCredentials": allowUnprotectedCredentials])
        if descriptor.renderer != .hostWeb {
            webView?.load(URLRequest(url: URL(string: "nethriva-console://bundle/console.html")!))
        }
    }
    func action(_ action: String) {
        guard !hostWeb else { return }
        if action == "paste" {
            if let value = NSPasteboard.general.string(forType: .string), value.utf8.count <= 1024 * 1024 {
                bridge.action("paste", value: value)
            }
        } else { bridge.action(action) }
    }
    func setFit(_ value: Bool) { bridge.action("fit", value: value) }
    func fitToScreen() {
        fit = true
        // Reapply even when auto-fit is already enabled, without reconnecting
        // or requesting a different resolution inside the guest.
        setFit(true)
    }
    func setResizeGuest(_ value: Bool) { bridge.action("resizeGuest", value: value) }
    func setViewOnly(_ value: Bool) { bridge.action("viewOnly", value: value); if value { bridge.action("release") } }
    func setClipboard(_ value: Bool) { bridge.action("clipboard", value: value) }
    func fullScreen() { webView?.window?.toggleFullScreen(nil) }
    private func startDeadline() {
        deadline?.cancel()
        let generation = generation
        deadline = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(45))
                guard let self, self.generation == generation else { return }
                error = "The console did not become ready. Check its address, protocol, host trust, and authentication."
                status = "Failed"; bridge.stop(); tunnel.stop()
            } catch {}
        }
    }
    func submitPassword(_ value: String) {
        if unencrypted, !ConnectionSecurityConsent.confirmUnencryptedCredential() { return }
        needsPassword = false; status = "Connecting"; startDeadline(); bridge.credentials(value, allowUnprotected: unencrypted)
    }
    func stop() {
        generation = UUID(); work?.cancel(); work = nil; deadline?.cancel(); deadline = nil
        bridge.stop(); tunnel.stop(); backend?.close(); backend = nil; http?.close(); http = nil
        descriptor = nil; hyperVConnection = nil; needsPassword = false; status = "Disconnected"
        allowUnprotectedCredentials = false; unencrypted = false
    }
}

struct VMConsoleSessionView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var recovery: SessionRecovery
    @Environment(\.sessionLifetime) private var lifetime
    @State private var recoveryPending = false
    @StateObject private var controller: VMConsoleController
    @State private var consolePassword = ""
    let connection: RemoteConnection
    let virtualMachine: VirtualMachine?
    init(connection: RemoteConnection, virtualMachine: VirtualMachine?) {
        self.connection = connection; self.virtualMachine = virtualMachine
        _controller = StateObject(wrappedValue: VMConsoleController(connection: connection, machine: virtualMachine))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("Console", systemImage: "desktopcomputer").font(.subheadline.weight(.semibold))
                if let endpoint = settings.sessionEndpoint(for: connection) { Text(endpoint).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                ConnectionCheckButton(connection: connection).labelStyle(.iconOnly)
                if controller.hyperVConnection == nil {
                    Button { controller.fitToScreen() } label: {
                        Label("Fit Screen", systemImage: "arrow.down.right.and.arrow.up.left")
                    }
                    .accessibilityIdentifier("vmConsole.fitScreen")
                    .help("Fit the whole display into this tab, preserving its proportions. Keeps fitting as the window or sidebar changes, without changing the guest resolution.")
                    .disabled(controller.hostWeb || controller.status != "Connected")
                    Button("Ctrl+Alt+Del") { controller.action("cad") }.disabled(controller.viewOnly || controller.hostWeb || controller.status != "Connected")
                    Button("Send Clipboard") { controller.action("paste") }
                        .help("Send Mac text to the guest clipboard, then paste inside the guest. SPICE without an agent uses US-layout typing.")
                        .disabled(!controller.clipboard || controller.viewOnly || controller.hostWeb || controller.status != "Connected")
                    Menu("Display & Input") {
                        Toggle("Fit to Screen Automatically", isOn: $controller.fit)
                        Toggle("Resize Guest to Fit (When Supported)", isOn: $controller.resizeGuest)
                        Toggle("View Only", isOn: $controller.viewOnly)
                        Toggle("Share Text Clipboard", isOn: $controller.clipboard)
                        Button("Release Keyboard / Pointer") { controller.action("release") }
                        Button("Full Screen") { controller.fullScreen() }
                    }.disabled(controller.hostWeb)
                }
                Text(controller.status).font(.caption).foregroundStyle(.secondary)
                if ["Connected", "Connecting", "Console authentication", "Host console"].contains(controller.status) {
                    Button("Disconnect") { recoveryPending = false; controller.stop() }
                } else {
                    Button("Reconnect") { recoveryPending = false; controller.connect(appState: appState) }
                }
            }.controlSize(.small).padding(.horizontal, 10).frame(height: 34).background(.bar)
            Divider()
            if let rdp = controller.hyperVConnection {
                RDPSessionView(connection: rdp)
            } else {
                ZStack {
                    VMConsoleSurface(controller: controller)
                        .allowsHitTesting(!controller.viewOnly || controller.hostWeb)
                    if let error = controller.error {
                        VStack(spacing: 12) {
                            Label("Console Connection Failed", systemImage: "exclamationmark.triangle.fill").font(.title3)
                            Text(error).multilineTextAlignment(.center).textSelection(.enabled)
                            Button("Reconnect") { controller.connect(appState: appState) }
                            if connection.kind == .spice || connection.kind == .vnc || connection.virtualization?.platform == .libvirt {
                                SecureField("Separate VM console password", text: $consolePassword).textFieldStyle(.roundedBorder)
                                Button("Retry with Console Password") {
                                    controller.connect(appState: appState, consolePassword: consolePassword)
                                    consolePassword = ""
                                }
                            }
                        }.padding(24).frame(maxWidth: 530).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    } else if controller.needsPassword {
                        VStack(spacing: 12) {
                            Text("Console Password").font(.headline)
                            if controller.unencrypted {
                                Text("Unencrypted connection: saved credentials are withheld. A password entered here requires a separate one-time warning.")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                            Text("This is the VM's VNC password, which may differ from the host login.").font(.caption)
                            SecureField("Console password", text: $consolePassword).textFieldStyle(.roundedBorder)
                            Button("Authenticate") { controller.submitPassword(consolePassword); consolePassword = "" }.keyboardShortcut(.defaultAction)
                        }.padding(24).frame(width: 400).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    } else if controller.status == "Connecting" {
                        ProgressView("Opening console…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }.clipped()
                if controller.hostWeb {
                    Text("Host-provided web console: sign in here if asked. Use the host console toolbar for special keys, scaling, clipboard, and capture release.")
                        .font(.caption).foregroundStyle(.secondary).padding(8).background(.bar)
                }
            }
        }
        .task {
            lifetime?.own("vm-console") { [controller = controller] in controller.stop() }
            if lifetime?.claimStart("vm-console") != false { controller.connect(appState: appState) }
        }
        .onDisappear { if lifetime == nil { controller.stop() } }
        .onChange(of: recovery.suspended) { _, suspended in
            if suspended, ["Connected", "Connecting", "Console authentication"].contains(controller.status) {
                recoveryPending = true; controller.stop()
            }
        }
        .onChange(of: recovery.epoch) { _, _ in
            if recoveryPending, settings.recoverNetworkSessions { recoveryPending = false; controller.connect(appState: appState) }
        }
        .onChange(of: controller.fit) { _, value in controller.setFit(value) }
        .onChange(of: controller.resizeGuest) { _, value in controller.setResizeGuest(value) }
        .onChange(of: controller.viewOnly) { _, value in controller.setViewOnly(value) }
        .onChange(of: controller.clipboard) { _, value in controller.setClipboard(value) }
    }
}

struct VMConsoleSurface: NSViewRepresentable {
    let controller: VMConsoleController
    func makeCoordinator() -> SessionFocusGate { SessionFocusGate() }
    func makeNSView(context: Context) -> WKWebView {
        // Focus must follow a retained session when it moves to another window.
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        if let root = Bundle.main.resourceURL?.appendingPathComponent("Consoles") {
            config.setURLSchemeHandler(VMConsoleAssets(root: root), forURLScheme: "nethriva-console")
        }
        config.userContentController.add(controller.bridge, name: "vmConsole")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = controller.bridge; webView.uiDelegate = controller.bridge
        webView.setValue(false, forKey: "drawsBackground")
        controller.attach(webView)
        context.environment.sessionLifetime?.focus = { [weak webView] in if let webView { webView.window?.makeFirstResponder(webView) } }
        return webView
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.update(context.environment.sessionIsActive) { nsView.window?.makeFirstResponder(nsView) }
    }
    static func dismantleNSView(_ nsView: WKWebView, coordinator: SessionFocusGate) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "vmConsole")
        nsView.navigationDelegate = nil; nsView.uiDelegate = nil; nsView.stopLoading()
    }
}
