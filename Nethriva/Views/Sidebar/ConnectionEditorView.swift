import AppKit
import SwiftUI

struct ConnectionEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var library: LibraryTools

    private let connection: RemoteConnection?

    @State private var name: String
    @State private var kind: ConnectionKind
    @State private var host: String
    @State private var port: Int
    @State private var username: String
    @State private var credentialProfileID: UUID?
    @State private var password = ""
    @State private var hasSavedPassword = false
    @State private var removeSavedPassword = false
    @State private var group: String
    @State private var isFavorite: Bool
    @State private var sshAuthentication: SSHAuthenticationMode
    @State private var sshIdentityFile: String
    @State private var sshJumpHost: String
    @State private var showsJumpHosts = false
    @State private var sshForwardAgent: Bool
    @State private var sshCompression: Bool
    @State private var sshKeepAliveInterval: Int
    @State private var sshX11: SSHX11Configuration
    @State private var serialBaudRate: Int
    @State private var serialDataBits: Int
    @State private var serialParity: SerialParity
    @State private var serialStopBits: Int
    @State private var serialFlowControl: SerialFlowControl
    @State private var serialLocalEcho: Bool
    @State private var availableSerialPorts: [String] = []
    @State private var isShowingSSHOptions: Bool
    @State private var rdpDomain: String
    @State private var rdpGatewayHost: String
    @State private var rdpGatewayUsername: String
    @State private var rdpScale: Int
    @State private var rdpClipboard: Bool
    @State private var rdpAudioMode: RDPAudioMode
    @State private var rdpMicrophone: Bool
    @State private var rdpRedirectHome: Bool
    @State private var rdpSharedFolder: String
    @State private var rdpPrinters: Bool
    @State private var rdpSmartCards: Bool
    @State private var rdpUSBDevices: Bool
    @State private var rdpNetworkProfile: RDPNetworkProfile
    @State private var rdpGraphicsAcceleration: Bool
    @State private var rdpCertificatePolicy: RDPCertificatePolicy
    @State private var rdpSecurityMode: RDPSecurityMode
    @State private var rdpAdminSession: Bool
    @State private var rdpAutoReconnect: Bool
    @State private var rdpReconnectRetries: Int
    @State private var isShowingRDPDisplayOptions = true
    @State private var isShowingRDPDeviceOptions = false
    @State private var isShowingRDPSecurityOptions = false
    @State private var errorMessage: String?
    @State private var vmConfiguration: VirtualizationConfiguration
    @State private var terminalProfileID: UUID?
    @State private var inheritedFields: Set<DefaultField>
    @State private var selectedTemplate: ConnectionTemplate?
    @State private var confirmsTemplate = false

    init(connection: RemoteConnection? = nil, initialGroup: String? = nil) {
        self.connection = connection
        _terminalProfileID = State(initialValue: connection?.terminalProfileID)
        _inheritedFields = State(initialValue: connection?.inheritedFields ?? [])
        _vmConfiguration = State(initialValue: connection?.virtualization ?? VirtualizationConfiguration())
        _name = State(initialValue: connection?.name ?? "")
        _kind = State(initialValue: connection?.kind ?? .ssh)
        _host = State(initialValue: connection?.host ?? "")
        _port = State(initialValue: connection?.port ?? ConnectionKind.ssh.defaultPort)
        _username = State(initialValue: connection?.username ?? "")
        _credentialProfileID = State(initialValue: connection?.credentialProfileID)
        _group = State(initialValue: connection?.group ?? initialGroup ?? "Ungrouped")
        _isFavorite = State(initialValue: connection?.isFavorite ?? false)
        _sshAuthentication = State(initialValue: connection?.effectiveSSHAuthentication ?? .automatic)
        _sshIdentityFile = State(initialValue: connection?.sshIdentityFile ?? "")
        _sshJumpHost = State(initialValue: connection?.sshJumpHost ?? "")
        _sshForwardAgent = State(initialValue: connection?.sshForwardAgent ?? false)
        _sshCompression = State(initialValue: connection?.sshCompression ?? false)
        _sshKeepAliveInterval = State(initialValue: connection?.effectiveSSHKeepAliveInterval ?? 30)
        _sshX11 = State(initialValue: connection?.sshX11 ?? SSHX11Configuration())
        _serialBaudRate = State(initialValue: connection?.effectiveSerialBaudRate ?? 115_200)
        _serialDataBits = State(initialValue: connection?.effectiveSerialDataBits ?? 8)
        _serialParity = State(initialValue: connection?.effectiveSerialParity ?? .none)
        _serialStopBits = State(initialValue: connection?.effectiveSerialStopBits ?? 1)
        _serialFlowControl = State(initialValue: connection?.effectiveSerialFlowControl ?? .none)
        _serialLocalEcho = State(initialValue: connection?.effectiveSerialLocalEcho ?? false)
        _isShowingSSHOptions = State(initialValue:
            connection?.sshIdentityFile != nil
                || connection?.sshJumpHost != nil
                || connection?.sshAuthentication != nil
                || connection?.sshForwardAgent == true
                || connection?.sshCompression == true
        )
        _rdpDomain = State(initialValue: connection?.rdpDomain ?? "")
        _rdpGatewayHost = State(initialValue: connection?.rdpGatewayHost ?? "")
        _rdpGatewayUsername = State(initialValue: connection?.rdpGatewayUsername ?? "")
        _rdpScale = State(initialValue: connection?.effectiveRDPScale ?? 100)
        _rdpClipboard = State(initialValue: connection?.effectiveRDPClipboard ?? false)
        _rdpAudioMode = State(initialValue: connection?.effectiveRDPAudioMode ?? .local)
        _rdpMicrophone = State(initialValue: connection?.rdpMicrophone ?? false)
        _rdpRedirectHome = State(initialValue: connection?.rdpRedirectHome ?? false)
        _rdpSharedFolder = State(initialValue: connection?.rdpSharedFolder ?? "")
        _rdpPrinters = State(initialValue: connection?.rdpPrinters ?? false)
        _rdpSmartCards = State(initialValue: connection?.rdpSmartCards ?? false)
        _rdpUSBDevices = State(initialValue: connection?.rdpUSBDevices ?? false)
        _rdpNetworkProfile = State(initialValue: connection?.effectiveRDPNetworkProfile ?? .automatic)
        _rdpGraphicsAcceleration = State(initialValue: connection?.effectiveRDPGraphicsAcceleration ?? true)
        _rdpCertificatePolicy = State(initialValue: connection?.effectiveRDPCertificatePolicy ?? .systemValidation)
        _rdpSecurityMode = State(initialValue: connection?.effectiveRDPSecurityMode ?? .nla)
        _rdpAdminSession = State(initialValue: connection?.rdpAdminSession ?? false)
        _rdpAutoReconnect = State(initialValue: connection?.effectiveRDPAutoReconnect ?? true)
        _rdpReconnectRetries = State(initialValue: connection?.effectiveRDPReconnectRetries ?? 10)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Text(connection == nil ? "New Connection" : "Edit Connection")
                    .font(.title2.weight(.semibold))

                Menu("Apply Template…") {
                    ForEach(library.data.templates.filter { $0.kind == kind }) { template in
                        Button(template.name) { selectedTemplate = template; confirmsTemplate = true }
                    }
                }.disabled(!library.data.templates.contains { $0.kind == kind })
                if DefaultField.appearance.supports(kind) {
                    Picker("Terminal Profile", selection: $terminalProfileID) {
                        Text("App Default").tag(UUID?.none)
                        ForEach(library.data.profiles) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                DisclosureGroup("Inherit Selected Fields from Group") {
                    ForEach(DefaultField.allCases.filter { $0.supports(kind) }) { field in
                        Toggle(field.label, isOn: Binding(get: { inheritedFields.contains(field) }, set: { if $0 { inheritedFields.insert(field) } else { inheritedFields.remove(field) } }))
                    }
                    Text("Checked fields use the nearest group’s defaults when a session opens. Unchecked fields use this connection’s values. A missing group value falls back to this connection. Existing clients do not inherit automatically.").font(.caption).foregroundStyle(.secondary)
                    Button("Manage Templates & Group Defaults…") { appState.toolsGroupRequest = group; openWindow(id: "library-tools") }
                }

                TextField("Name", text: $name, prompt: Text("Production server"))

                Picker("Protocol", selection: $kind) {
                    Text("SSH").tag(ConnectionKind.ssh)
                    Text("Telnet").tag(ConnectionKind.telnet)
                    Text("Serial").tag(ConnectionKind.serial)
                    Text("RDP").tag(ConnectionKind.rdp)
                    Text("Virtualization Host").tag(ConnectionKind.virtualization)
                    Text("VNC Console").tag(ConnectionKind.vnc)
                    Text("SPICE Console").tag(ConnectionKind.spice)
                }
                .onChange(of: kind) { _, newValue in
                    port = newValue.defaultPort
                    if newValue == .virtualization { port = vmConfiguration.platform.defaultPort }
                    if newValue == .serial {
                        host = availableSerialPorts.first ?? ""
                        credentialProfileID = nil
                        username = ""
                        password = ""
                    } else if connection?.kind == .serial {
                        host = ""
                    }
                }

                if kind == .serial {
                    HStack {
                        Picker("Available Port", selection: $host) {
                            Text("Choose a port").tag("")
                            ForEach(availableSerialPorts, id: \.self) { device in
                                Text(device).tag(device)
                            }
                            if !host.isEmpty && !availableSerialPorts.contains(host) {
                                Text("Unavailable: \(host)").tag(host)
                            }
                        }
                        Button {
                            refreshSerialPorts()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Refresh connected serial adapters")
                    }
                    TextField("Device Path", text: $host, prompt: Text("/dev/cu.usbserial-…"))
                        .font(.system(.body, design: .monospaced))
                    Text("Plug in a USB-to-serial adapter, then choose its /dev/cu.* port. You can also enter the path manually.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Baud Rate", selection: $serialBaudRate) {
                        ForEach(SerialPortConfiguration.supportedBaudRates, id: \.self) { rate in
                            Text(rate.formatted()).tag(rate)
                        }
                    }
                    Picker("Data Bits", selection: $serialDataBits) {
                        Text("7").tag(7)
                        Text("8").tag(8)
                    }
                    Picker("Parity", selection: $serialParity) {
                        ForEach(SerialParity.allCases) { value in
                            Text(value.displayName).tag(value)
                        }
                    }
                    Picker("Stop Bits", selection: $serialStopBits) {
                        Text("1").tag(1)
                        Text("2").tag(2)
                    }
                    Picker("Flow Control", selection: $serialFlowControl) {
                        ForEach(SerialFlowControl.allCases) { value in
                            Text(value.displayName).tag(value)
                        }
                    }
                    Toggle("Local Echo", isOn: $serialLocalEcho)
                } else {
                    TextField("Host", text: $host, prompt: Text("server.example.com"))
                        .textContentType(.URL)
                    TextField("Port", value: $port, format: .number)
                    HStack {
                        Picker("Credentials", selection: $credentialProfileID) {
                            Text("This connection's own credentials").tag(nil as UUID?)
                            ForEach(appState.credentialProfiles) { profile in
                                Text(profile.name).tag(profile.id as UUID?)
                            }
                        }
                        Button("Manage…") { openWindow(id: "credential-manager") }
                    }
                    if let credentialProfileID {
                        if let profile = appState.credentialProfiles.first(where: { $0.id == credentialProfileID }) {
                            Text("Uses \(profile.name)'s username\(kind == .rdp && !profile.domain.isEmpty ? " and Windows domain" : "") and Keychain password. Changes to that profile affect every linked connection.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Label("This credential profile is missing. Choose another profile.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                        }
                    } else {
                        TextField("Username", text: $username)
                            .textContentType(.username)
                        SecureField(connection == nil ? "Password (optional)" : "New password (leave blank to keep current)", text: $password)
                            .textContentType(.password)
                            .onChange(of: password) { _, newValue in
                                if !newValue.isEmpty { removeSavedPassword = false }
                            }
                    }
                }

                if kind != .serial && credentialProfileID == nil && connection != nil && hasSavedPassword {
                    HStack {
                        if removeSavedPassword {
                            Label("Saved password will be removed when you save.", systemImage: "key.slash")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("Undo") {
                                removeSavedPassword = false
                            }
                        } else {
                            Label("A password is stored in Keychain.", systemImage: "key.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Remove Saved Password", role: .destructive) {
                                password = ""
                                removeSavedPassword = true
                            }
                        }
                    }
                }

                HStack {
                    TextField("Group", text: $group)

                    Menu {
                        ForEach(availableGroups, id: \.self) { groupName in
                            Button(groupName) {
                                group = groupName
                            }
                        }
                    } label: {
                        Image(systemName: "folder")
                    }
                    .menuStyle(.borderlessButton)
                    .help("Choose an existing group")
                }

                Toggle("Favorite", isOn: $isFavorite)

                if kind == .virtualization {
                    Picker("Platform", selection: $vmConfiguration.platform) {
                        ForEach(VirtualizationPlatform.allCases) { Text($0.displayName).tag($0) }
                    }.onChange(of: vmConfiguration.platform) { _, platform in port = platform.defaultPort }
                    if vmConfiguration.platform == .libvirt {
                        Picker("libvirt Connection", selection: Binding(get: { vmConfiguration.effectiveLibvirtURI }, set: { vmConfiguration.libvirtURI = $0 })) {
                            Text("System (qemu:///system)").tag("qemu:///system")
                            Text("User session (qemu:///session)").tag("qemu:///session")
                        }
                    }
                    if !vmConfiguration.platform.usesSSH { certificatePicker }
                    TextField("Guest-tools ISO / VDI", text: optionalText(\.toolsImage), prompt: Text("Optional host-side media location"))
                    Text(VirtualizationHostController.mediaHint(vmConfiguration.platform)).font(.caption).foregroundStyle(.secondary)
                    Text("VM inventory, console access, and power controls use host permissions. Graceful shutdown requires guest support. ISO media must already exist on the host.").font(.caption).foregroundStyle(.secondary)
                    if vmConfiguration.platform == .proxmox {
                        Text("Use a realm-qualified account (user@pam or user@pve). For an API token, use user@realm!token as username and its secret as password; console ticket creation may require a password-authenticated account.").font(.caption).foregroundStyle(.secondary)
                    }
                    if vmConfiguration.platform == .hyperv {
                        Text("Requires Windows OpenSSH, Hyper-V PowerShell permissions, and access to VMConnect on port 2179. Modern Windows integration services come through Windows Update.").font(.caption).foregroundStyle(.secondary)
                    }
                    if vmConfiguration.platform == .vmware {
                        Toggle("Interactive federated sign-in (vCenter)", isOn: Binding(get: { vmConfiguration.federation != nil }, set: { vmConfiguration.federation = $0 ? VMFederationConfiguration() : nil }))
                        if vmConfiguration.federation != nil {
                            TextField("Authorization URL", text: federationText(\.authorizationURL))
                            TextField("Token URL", text: federationText(\.tokenURL))
                            TextField("Native Client ID", text: federationText(\.clientID))
                            TextField("Scopes", text: federationText(\.scope))
                            TextField("Resource (optional)", text: federationText(\.resource))
                            Picker("Exchange Token Type", selection: Binding(get: { vmConfiguration.federation?.effectiveSubjectTokenType ?? "urn:ietf:params:oauth:token-type:jwt" }, set: { vmConfiguration.federation?.subjectTokenType = $0 })) {
                                Text("JWT (typical federated vCenter)").tag("urn:ietf:params:oauth:token-type:jwt")
                                Text("OAuth Access Token").tag("urn:ietf:params:oauth:token-type:access_token")
                            }
                            Text("An administrator must register a public/native OAuth client with S256 PKCE and redirect URI nethriva-auth://oauth/callback. Requires vCenter 7.0.2+ token exchange and a SAML bearer token. System-validated HTTPS is mandatory. MFA stays in the system browser; tokens remain in memory and expire within five minutes. Configure only trusted organization endpoints.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if vmConfiguration.platform == .nutanix {
                        Toggle("Use bearer token instead of password", isOn: optionalBool(\.useBearerToken))
                        Text("Prism Central inventory uses the v3 API; advanced actions use v4. Console token generation requires a host exposing the v4.2+ console API and a bearer token or authenticated session cookie for its WebSocket. Store the bearer token in the password field.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if kind == .vnc || kind == .spice {
                    Picker("Transport", selection: Binding(get: { vmConfiguration.consoleTransport ?? .tcp }, set: {
                        vmConfiguration.consoleTransport = $0
                        if $0 != .tcp { vmConfiguration.tunnelConnectionID = nil }
                    })) {
                        ForEach(ConsoleTransport.allCases) { Text($0.displayName).tag($0) }
                    }
                    if vmConfiguration.consoleTransport == .webSocket {
                        TextField("WebSocket Path", text: optionalText(\.consolePath), prompt: Text("/websockify"))
                        certificatePicker
                    } else if vmConfiguration.consoleTransport == .tls {
                        Text("Requires a TLS-wrapped VNC/SPICE listener (for example an administrator-configured TLS proxy), not a VeNCrypt-only listener. TLS 1.2+, macOS certificate trust and hostname verification are required. No insecure fallback is attempted.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Picker("SSH Tunnel", selection: $vmConfiguration.tunnelConnectionID) {
                            Text("None — direct connection").tag(nil as UUID?)
                            ForEach(appState.connections.filter { $0.kind == .ssh }) { Text($0.name).tag($0.id as UUID?) }
                        }
                        Text("Direct TCP is not encrypted. Prefer an SSH tunnel or secure WebSocket. For a tunnel, Host and Port identify the console from the SSH server's perspective; open that host's SSH tab first for authentication.").font(.caption).foregroundStyle(.orange)
                    }
                }
                if kind == .virtualization || kind == .vnc || kind == .spice {
                    Toggle("Console view only", isOn: optionalBool(\.viewOnly))
                    Toggle("Share console text clipboard", isOn: optionalBool(\.shareClipboard))
                    Text("Clipboard and guest resizing depend on the console server and guest agent. Host web consoles use their own controls. Console tabs do not transfer files; use SSH/SFTP or RDP for that.").font(.caption).foregroundStyle(.secondary)
                }
                if usesSSH {
                    DisclosureGroup("SSH Options", isExpanded: $isShowingSSHOptions) {
                        Picker("Authentication", selection: $sshAuthentication) {
                            ForEach(SSHAuthenticationMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }

                        HStack {
                            TextField("Identity File", text: $sshIdentityFile, prompt: Text("Use SSH config / agent"))

                            Button("Choose…") {
                                chooseIdentityFile()
                            }

                            if !sshIdentityFile.isEmpty {
                                Button {
                                    sshIdentityFile = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .help("Clear identity file")
                            }
                        }

                        TextField("Jump Host", text: $sshJumpHost, prompt: Text("user@bastion.example.com"))
                        Button("Configure Jump Chain…") { showsJumpHosts = true }
                            .sheet(isPresented: $showsJumpHosts) { JumpHostEditor(value: $sshJumpHost, connections: appState.connections.map { appState.resolvedConnection(for: $0) }) }

                        Toggle("Forward SSH agent", isOn: $sshForwardAgent)
                        Toggle("Enable compression", isOn: $sshCompression)

                        Stepper(value: $sshKeepAliveInterval, in: 0...3600, step: 5) {
                            Text(sshKeepAliveInterval == 0
                                ? "Keep alive: Off"
                                : "Keep alive: \(sshKeepAliveInterval) seconds")
                        }
                        if kind == .ssh {
                        Picker("X11 Forwarding", selection: $sshX11.mode) {
                            ForEach(SSHX11Mode.allCases) { Text($0.title).tag($0) }
                        }
                        if sshX11.mode != .off {
                            TextField("Local XQuartz DISPLAY", text: $sshX11.display, prompt: Text("Detect after installing and starting XQuartz"))
                            HStack {
                                Button("Detect XQuartz Display") {
                                    Task { do { sshX11.display = try await SSHX11Configuration.detectDisplay() }
                                        catch { errorMessage = "Start XQuartz and log out/in after installation, then retry. DISPLAY must be a local XQuartz socket." } }
                                }
                                Link("XQuartz Setup", destination: URL(string: "https://www.xquartz.org/FAQs.html")!)
                            }
                            Text("Install XQuartz separately. The server must allow X11 forwarding and have xauth. No public X11 listener or xhost + is needed. A dedicated SSH transport prevents sharing the forwarded display with unrelated tabs.").font(.caption).foregroundStyle(.secondary)
                            Text(sshX11.mode == .trusted ? "Trusted X11 lets remote applications monitor input and interact with other X applications on this Mac. Use only with a fully trusted host." : "Untrusted X11 restricts remote applications but may not work with applications or XQuartz configurations that require trusted forwarding.").font(.caption).foregroundStyle(.orange)
                        }
                        }

                        Text("Automatic authentication follows your ~/.ssh/config and ssh-agent. Identity and jump-host settings override those values for this connection.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if kind == .telnet {
                    Label(
                        "Telnet is unencrypted. Credentials and session data can be read by anyone able to observe the network path. Use it only on trusted management networks.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                if kind == .rdp {
                    DisclosureGroup("Display & Performance", isExpanded: $isShowingRDPDisplayOptions) {
                        LabeledContent("Display") {
                            Label("Fit Tab Automatically", systemImage: "arrow.up.left.and.arrow.down.right")
                        }

                        Text("The Windows desktop follows the available tab area, including changes caused by showing, hiding, or resizing the sidebar.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Picker("Interface Scale", selection: $rdpScale) {
                            Text("Comfortable (100%)").tag(100)
                            Text("Larger (140%)").tag(140)
                            Text("Largest (180%)").tag(180)
                        }

                        Picker("Network", selection: $rdpNetworkProfile) {
                            ForEach(RDPNetworkProfile.allCases) { profile in
                                Text(profile.displayName).tag(profile)
                            }
                        }

                        Toggle("Modern graphics pipeline (H.264 / AVC444)", isOn: $rdpGraphicsAcceleration)
                    }

                    DisclosureGroup("Devices & Clipboard", isExpanded: $isShowingRDPDeviceOptions) {
                        Toggle("Share clipboard and enable file transfers", isOn: $rdpClipboard)

                        Picker("Remote Audio", selection: $rdpAudioMode) {
                            ForEach(RDPAudioMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }

                        Toggle("Redirect microphone", isOn: $rdpMicrophone)
                        Toggle("Share home folder", isOn: $rdpRedirectHome)

                        HStack {
                            TextField("Shared Folder", text: $rdpSharedFolder, prompt: Text("Optional local folder"))
                            Button("Choose…", action: chooseRDPSharedFolder)
                            if !rdpSharedFolder.isEmpty {
                                Button {
                                    rdpSharedFolder = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        Toggle("Redirect printers", isOn: $rdpPrinters)
                        Toggle("Redirect smart cards", isOn: $rdpSmartCards)
                        Toggle("Redirect USB devices", isOn: $rdpUSBDevices)
                    }

                    DisclosureGroup("Security, Gateway & Reliability", isExpanded: $isShowingRDPSecurityOptions) {
                        if credentialProfileID == nil {
                            TextField("Domain", text: $rdpDomain)
                        }
                        TextField("Gateway", text: $rdpGatewayHost, prompt: Text("gateway.example.com"))
                        TextField("Gateway Username", text: $rdpGatewayUsername)

                        Picker("Certificate", selection: $rdpCertificatePolicy) {
                            ForEach(RDPCertificatePolicy.allCases) { policy in
                                Text(policy.displayName).tag(policy)
                            }
                        }
                        Picker("Session Security", selection: $rdpSecurityMode) {
                            ForEach(RDPSecurityMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        if rdpSecurityMode == .legacyRDP {
                            Text("Legacy RDP cannot verify the server using TLS certificates. Use only with a separately protected network route; you must confirm each new session.")
                                .font(.caption).foregroundStyle(.orange)
                        }

                        if rdpCertificatePolicy == .ignore {
                            Label("Certificate verification is disabled for this connection.", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }

                        Toggle("Connect to administrative session", isOn: $rdpAdminSession)
                        Toggle("Automatically reconnect", isOn: $rdpAutoReconnect)
                        if rdpAutoReconnect {
                            Stepper("Reconnect attempts: \(rdpReconnectRetries)", value: $rdpReconnectRetries, in: 0...1000)
                        }

                        Text("Passwords stay in macOS Keychain and are passed directly to the embedded FreeRDP client, never as visible process arguments.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Text(footerText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                Button(connection == nil ? "Add" : "Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding()
        }
        .frame(
            width: 600,
            height: kind == .rdp || kind == .virtualization || kind == .vnc || kind == .spice ? 780 : (kind == .serial ? 680 : (kind == .ssh && isShowingSSHOptions ? 690 : 560))
        )
        .navigationTitle(connection == nil ? "New Connection" : "Edit Connection")
        .confirmationDialog("Apply \(selectedTemplate?.name ?? "template")?", isPresented: $confirmsTemplate, titleVisibility: .visible) {
            Button("Apply Settings to This Draft") { if let template = selectedTemplate { applyTemplate(template) }; selectedTemplate = nil }
        } message: { Text("Copies credential-profile reference, port, jump/gateway, terminal profile, keepalive and scale where present. Host, name, group and saved passwords stay unchanged. Review the fields before Save.") }
        .task {
            refreshSerialPorts()
            guard let connection else { return }
            if connection.credentialProfileID == nil {
                hasSavedPassword = (try? appState.hasSavedPassword(for: connection)) ?? false
            }
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            if kind == .serial { refreshSerialPorts() }
        }
    }
    private func federationText(_ path: WritableKeyPath<VMFederationConfiguration, String>) -> Binding<String> {
        Binding(get: { vmConfiguration.federation?[keyPath: path] ?? "" }, set: { vmConfiguration.federation?[keyPath: path] = $0 })
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (kind == .serial
                ? SerialPortDiscovery.isValidDevicePath(host.trimmingCharacters(in: .whitespacesAndNewlines))
                    && SerialPortConfiguration.supportedBaudRates.contains(serialBaudRate)
                : (1...65535).contains(port))
            && (credentialProfileID == nil || appState.credentialProfiles.contains { $0.id == credentialProfileID })
    }

    private var availableGroups: [String] {
        let names = appState.groups + [group]
        return Array(Set(names.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func save() {
        if kind == .ssh, sshX11.mode != .off, !SSHX11Configuration.validDisplay(sshX11.display) {
            errorMessage = "Configure a local XQuartz DISPLAY before saving X11 forwarding."; return
        }
        var updatedConnection = RemoteConnection(
            id: connection?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: kind,
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: kind == .serial ? 0 : port,
            username: kind == .serial || credentialProfileID != nil ? "" : username.trimmingCharacters(in: .whitespacesAndNewlines),
            credentialProfileID: kind == .serial ? nil : credentialProfileID,
            group: group.trimmingCharacters(in: .whitespacesAndNewlines),
            isFavorite: isFavorite,
            createdAt: connection?.createdAt ?? Date(),
            sshAuthentication: usesSSH ? sshAuthentication : nil,
            sshIdentityFile: usesSSH ? normalizedOptional(sshIdentityFile) : nil,
            sshJumpHost: usesSSH ? normalizedOptional(sshJumpHost) : nil,
            sshForwardAgent: usesSSH ? sshForwardAgent : nil,
            sshCompression: usesSSH ? sshCompression : nil,
            sshKeepAliveInterval: usesSSH ? sshKeepAliveInterval : nil,
            sshX11: kind == .ssh && sshX11.mode != .off ? sshX11 : nil,
            serialBaudRate: kind == .serial ? serialBaudRate : nil,
            serialDataBits: kind == .serial ? serialDataBits : nil,
            serialParity: kind == .serial ? serialParity : nil,
            serialStopBits: kind == .serial ? serialStopBits : nil,
            serialFlowControl: kind == .serial ? serialFlowControl : nil,
            serialLocalEcho: kind == .serial ? serialLocalEcho : nil,
            rdpDomain: kind == .rdp && credentialProfileID == nil ? normalizedOptional(rdpDomain) : nil,
            rdpGatewayHost: kind == .rdp ? normalizedOptional(rdpGatewayHost) : nil,
            rdpGatewayUsername: kind == .rdp ? normalizedOptional(rdpGatewayUsername) : nil,
            rdpDisplayMode: kind == .rdp ? .dynamicWindow : nil,
            rdpWidth: nil,
            rdpHeight: nil,
            rdpScale: kind == .rdp ? rdpScale : nil,
            rdpClipboard: kind == .rdp ? rdpClipboard : nil,
            rdpAudioMode: kind == .rdp ? rdpAudioMode : nil,
            rdpMicrophone: kind == .rdp ? rdpMicrophone : nil,
            rdpRedirectHome: kind == .rdp ? rdpRedirectHome : nil,
            rdpSharedFolder: kind == .rdp ? normalizedOptional(rdpSharedFolder) : nil,
            rdpPrinters: kind == .rdp ? rdpPrinters : nil,
            rdpSmartCards: kind == .rdp ? rdpSmartCards : nil,
            rdpUSBDevices: kind == .rdp ? rdpUSBDevices : nil,
            rdpNetworkProfile: kind == .rdp ? rdpNetworkProfile : nil,
            rdpGraphicsAcceleration: kind == .rdp ? rdpGraphicsAcceleration : nil,
            rdpCertificatePolicy: kind == .rdp ? rdpCertificatePolicy : nil,
            rdpSecurityMode: kind == .rdp ? rdpSecurityMode : nil,
            rdpAdminSession: kind == .rdp ? rdpAdminSession : nil,
            rdpAutoReconnect: kind == .rdp ? rdpAutoReconnect : nil,
            rdpReconnectRetries: kind == .rdp ? rdpReconnectRetries : nil,
            virtualization: [.virtualization, .vnc, .spice].contains(kind) ? vmConfiguration : nil
        )

        updatedConnection.terminalProfileID = terminalProfileID
        updatedConnection.terminalAppearance = terminalProfileID == connection?.terminalProfileID ? connection?.terminalAppearance : nil
        updatedConnection.inheritedFields = Set(inheritedFields.filter { $0.supports(kind) })

        do {
            if usesSSH { _ = try SSHJumpChain.validate(sshJumpHost) }
            if updatedConnection.virtualization != nil {
                try vmConfiguration.validate()
                _ = try VMInput.endpoint(for: updatedConnection)
            }
            if connection == nil {
                try appState.add(updatedConnection, password: credentialProfileID == nil && kind != .serial ? password : nil)
            } else {
                try appState.update(
                    updatedConnection,
                    password: credentialProfileID == nil && kind != .serial ? password : nil,
                    removeSavedPassword: removeSavedPassword
                        || (kind == .serial && connection?.kind != .serial)
                        || (credentialProfileID != nil && connection?.credentialProfileID == nil)
                )
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func normalizedOptional(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func applyTemplate(_ template: ConnectionTemplate) {
        let defaults = template.defaults
        if let id = defaults.credentialProfileID { credentialProfileID = id }
        if let value = defaults.ports[kind] { port = value }
        if let value = defaults.jumpHost, kind == .ssh { sshJumpHost = value }
        if let value = defaults.gateway, kind == .rdp { rdpGatewayHost = value }
        if let id = defaults.terminalProfileID { terminalProfileID = id }
        if let value = defaults.keepAlive, kind == .ssh { sshKeepAliveInterval = value }
        if let value = defaults.desktopScale, kind == .rdp { rdpScale = value }
        inheritedFields.subtract(defaults.populatedFields(for: kind))
    }

    private var footerText: String {
        switch kind {
        case .ssh:
            "macOS OpenSSH uses your SSH config and keys. Saved passwords remain in Keychain."
        case .telnet:
            "Telnet is intended only for legacy devices on trusted management networks."
        case .serial:
            "Serial connects directly to a local device. Disconnect before unplugging the adapter."
        case .rdp:
            "RDP uses the bundled FreeRDP runtime. Saved passwords remain in Keychain."
        case .localShell:
            "Local terminal sessions run on this Mac."
        case .virtualization:
            "Host credentials stay in Keychain. VM console tickets remain in memory only."
        case .vnc, .spice:
            "Use SSH tunneling or secure WebSocket for consoles outside a trusted network."
        }
    }

    private var usesSSH: Bool { kind == .ssh || (kind == .virtualization && vmConfiguration.platform.usesSSH) }
    private func optionalText(_ key: WritableKeyPath<VirtualizationConfiguration, String?>) -> Binding<String> {
        Binding(get: { vmConfiguration[keyPath: key] ?? "" }, set: { vmConfiguration[keyPath: key] = normalizedOptional($0) })
    }
    private func optionalBool(_ key: WritableKeyPath<VirtualizationConfiguration, Bool?>) -> Binding<Bool> {
        Binding(get: { vmConfiguration[keyPath: key] ?? false }, set: { vmConfiguration[keyPath: key] = $0 })
    }
    private var certificatePicker: some View {
        VStack(alignment: .leading) {
            Picker("Host Certificate", selection: Binding(get: { vmConfiguration.effectiveCertificatePolicy }, set: { vmConfiguration.certificatePolicy = $0 })) {
                ForEach(RDPCertificatePolicy.allCases) { Text($0.displayName).tag($0) }
            }
            if vmConfiguration.effectiveCertificatePolicy == .ignore {
                Text("Certificate verification is disabled. This permits server impersonation; use system validation or verify a trust-on-first-use fingerprint.").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func refreshSerialPorts() {
        let ports = SerialPortDiscovery.availablePorts()
        if ports != availableSerialPorts { availableSerialPorts = ports }
    }

    private func chooseIdentityFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose SSH Private Key"
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if !sshIdentityFile.isEmpty {
            let currentURL = URL(fileURLWithPath: (sshIdentityFile as NSString).expandingTildeInPath)
            panel.directoryURL = currentURL.deletingLastPathComponent()
        } else {
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        }

        if panel.runModal() == .OK, let url = panel.url {
            sshIdentityFile = url.path
        }
    }

    private func chooseRDPSharedFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Folder to Share with the Remote PC"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if !rdpSharedFolder.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: rdpSharedFolder)
        }

        if panel.runModal() == .OK, let url = panel.url {
            rdpSharedFolder = url.path
        }
    }
}
