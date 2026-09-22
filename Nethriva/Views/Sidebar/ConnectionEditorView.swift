import AppKit
import SwiftUI

struct ConnectionEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    private let connection: RemoteConnection?

    @State private var name: String
    @State private var kind: ConnectionKind
    @State private var host: String
    @State private var port: Int
    @State private var username: String
    @State private var password = ""
    @State private var hasSavedPassword = false
    @State private var removeSavedPassword = false
    @State private var group: String
    @State private var isFavorite: Bool
    @State private var sshAuthentication: SSHAuthenticationMode
    @State private var sshIdentityFile: String
    @State private var sshJumpHost: String
    @State private var sshForwardAgent: Bool
    @State private var sshCompression: Bool
    @State private var sshKeepAliveInterval: Int
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
    @State private var rdpAdminSession: Bool
    @State private var rdpAutoReconnect: Bool
    @State private var rdpReconnectRetries: Int
    @State private var isShowingRDPDisplayOptions = true
    @State private var isShowingRDPDeviceOptions = false
    @State private var isShowingRDPSecurityOptions = false
    @State private var errorMessage: String?

    init(connection: RemoteConnection? = nil, initialGroup: String? = nil) {
        self.connection = connection
        _name = State(initialValue: connection?.name ?? "")
        _kind = State(initialValue: connection?.kind ?? .ssh)
        _host = State(initialValue: connection?.host ?? "")
        _port = State(initialValue: connection?.port ?? ConnectionKind.ssh.defaultPort)
        _username = State(initialValue: connection?.username ?? "")
        _group = State(initialValue: connection?.group ?? initialGroup ?? "Ungrouped")
        _isFavorite = State(initialValue: connection?.isFavorite ?? false)
        _sshAuthentication = State(initialValue: connection?.effectiveSSHAuthentication ?? .automatic)
        _sshIdentityFile = State(initialValue: connection?.sshIdentityFile ?? "")
        _sshJumpHost = State(initialValue: connection?.sshJumpHost ?? "")
        _sshForwardAgent = State(initialValue: connection?.sshForwardAgent ?? false)
        _sshCompression = State(initialValue: connection?.sshCompression ?? false)
        _sshKeepAliveInterval = State(initialValue: connection?.effectiveSSHKeepAliveInterval ?? 30)
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
        _rdpClipboard = State(initialValue: connection?.effectiveRDPClipboard ?? true)
        _rdpAudioMode = State(initialValue: connection?.effectiveRDPAudioMode ?? .local)
        _rdpMicrophone = State(initialValue: connection?.rdpMicrophone ?? false)
        _rdpRedirectHome = State(initialValue: connection?.rdpRedirectHome ?? false)
        _rdpSharedFolder = State(initialValue: connection?.rdpSharedFolder ?? "")
        _rdpPrinters = State(initialValue: connection?.rdpPrinters ?? false)
        _rdpSmartCards = State(initialValue: connection?.rdpSmartCards ?? false)
        _rdpUSBDevices = State(initialValue: connection?.rdpUSBDevices ?? false)
        _rdpNetworkProfile = State(initialValue: connection?.effectiveRDPNetworkProfile ?? .automatic)
        _rdpGraphicsAcceleration = State(initialValue: connection?.effectiveRDPGraphicsAcceleration ?? true)
        _rdpCertificatePolicy = State(initialValue: connection?.effectiveRDPCertificatePolicy ?? .trustOnFirstUse)
        _rdpAdminSession = State(initialValue: connection?.rdpAdminSession ?? false)
        _rdpAutoReconnect = State(initialValue: connection?.effectiveRDPAutoReconnect ?? true)
        _rdpReconnectRetries = State(initialValue: connection?.effectiveRDPReconnectRetries ?? 10)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Text(connection == nil ? "New Connection" : "Edit Connection")
                    .font(.title2.weight(.semibold))

                TextField("Name", text: $name, prompt: Text("Production server"))

                Picker("Protocol", selection: $kind) {
                    Text("SSH").tag(ConnectionKind.ssh)
                    Text("Telnet").tag(ConnectionKind.telnet)
                    Text("RDP").tag(ConnectionKind.rdp)
                }
                .onChange(of: kind) { _, newValue in
                    port = newValue.defaultPort
                }

                TextField("Host", text: $host, prompt: Text("server.example.com"))
                    .textContentType(.URL)

                TextField("Port", value: $port, format: .number)

                TextField("Username", text: $username)
                    .textContentType(.username)

                SecureField(connection == nil ? "Password (optional)" : "New password (leave blank to keep current)", text: $password)
                    .textContentType(.password)
                    .onChange(of: password) { _, newValue in
                        if !newValue.isEmpty {
                            removeSavedPassword = false
                        }
                    }

                if connection != nil && hasSavedPassword {
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

                if kind == .ssh {
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

                        Toggle("Forward SSH agent", isOn: $sshForwardAgent)
                        Toggle("Enable compression", isOn: $sshCompression)

                        Stepper(value: $sshKeepAliveInterval, in: 0...3600, step: 5) {
                            Text(sshKeepAliveInterval == 0
                                ? "Keep alive: Off"
                                : "Keep alive: \(sshKeepAliveInterval) seconds")
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
                        Toggle("Share clipboard", isOn: $rdpClipboard)

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
                        TextField("Domain", text: $rdpDomain)
                        TextField("Gateway", text: $rdpGatewayHost, prompt: Text("gateway.example.com"))
                        TextField("Gateway Username", text: $rdpGatewayUsername)

                        Picker("Certificate", selection: $rdpCertificatePolicy) {
                            ForEach(RDPCertificatePolicy.allCases) { policy in
                                Text(policy.displayName).tag(policy)
                            }
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
            height: kind == .rdp ? 760 : (kind == .ssh && isShowingSSHOptions ? 650 : 520)
        )
        .task {
            guard let connection else { return }
            hasSavedPassword = (try? appState.password(for: connection)) != nil
        }
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (1...65535).contains(port)
    }

    private var availableGroups: [String] {
        let names = appState.groups + [group]
        return Array(Set(names.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func save() {
        let updatedConnection = RemoteConnection(
            id: connection?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: kind,
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: port,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            group: group.trimmingCharacters(in: .whitespacesAndNewlines),
            isFavorite: isFavorite,
            createdAt: connection?.createdAt ?? Date(),
            sshAuthentication: kind == .ssh ? sshAuthentication : nil,
            sshIdentityFile: kind == .ssh ? normalizedOptional(sshIdentityFile) : nil,
            sshJumpHost: kind == .ssh ? normalizedOptional(sshJumpHost) : nil,
            sshForwardAgent: kind == .ssh ? sshForwardAgent : nil,
            sshCompression: kind == .ssh ? sshCompression : nil,
            sshKeepAliveInterval: kind == .ssh ? sshKeepAliveInterval : nil,
            rdpDomain: kind == .rdp ? normalizedOptional(rdpDomain) : nil,
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
            rdpAdminSession: kind == .rdp ? rdpAdminSession : nil,
            rdpAutoReconnect: kind == .rdp ? rdpAutoReconnect : nil,
            rdpReconnectRetries: kind == .rdp ? rdpReconnectRetries : nil
        )

        do {
            if connection == nil {
                try appState.add(updatedConnection, password: password)
            } else {
                try appState.update(
                    updatedConnection,
                    password: password,
                    removeSavedPassword: removeSavedPassword
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

    private var footerText: String {
        switch kind {
        case .ssh:
            "macOS OpenSSH uses your SSH config and keys. Saved passwords remain in Keychain."
        case .telnet:
            "Telnet is intended only for legacy devices on trusted management networks."
        case .rdp:
            "RDP uses the bundled FreeRDP runtime. Saved passwords remain in Keychain."
        case .localShell:
            "Local terminal sessions run on this Mac."
        }
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
