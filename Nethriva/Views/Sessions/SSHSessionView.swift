import AppKit
import SwiftTerm
import SwiftUI

/// Runs Apple's OpenSSH client inside SwiftTerm's native pseudo-terminal.
/// This intentionally shares the same ~/.ssh configuration, identities,
/// known_hosts entries, ssh-agent, and interactive auth behavior as Terminal.
struct SSHSessionView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var recovery: SessionRecovery
    @Environment(\.sessionIsSplit) private var isSplit
    @Environment(\.sessionLifetime) private var lifetime
    @StateObject private var inputController = OpenSSHInputController()

    let connection: RemoteConnection

    @State private var processID = UUID()
    @State private var processEnded = false
    @State private var exitCode: Int32?
    @State private var credentialError: String?
    @State private var recoveryPending = false
    @State private var credentialTask: Task<Void, Never>?

    var body: some View {
        HSplitView {
            SSHFileTreeView(connection: connection)
                .frame(width: isSplit ? 0 : nil)
                .clipped().opacity(isSplit ? 0 : 1).allowsHitTesting(!isSplit).accessibilityHidden(isSplit)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Label("SSH", systemImage: "chevron.left.forwardslash.chevron.right")
                        .font(.headline)
                    if let endpoint = settings.sessionEndpoint(for: connection) {
                        Text(endpoint)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                ConnectionCheckButton(connection: connection).labelStyle(.iconOnly)
                    if processEnded {
                        Button("Reconnect", action: reconnect)
                    } else {
                        Text(inputController.isAwaitingPassword ? "Authentication" : "Active").font(.caption).foregroundStyle(.secondary)
                        Button("Disconnect") { recoveryPending = false; inputController.disconnect(); processEnded = true }
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(.bar)
                Divider()
                terminalPane
            }
            .frame(minWidth: isSplit ? 220 : 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: recovery.suspended) { _, suspended in
            if suspended, !processEnded { recoveryPending = true; inputController.disconnect(); processEnded = true }
        }
        .onChange(of: recovery.epoch) { _, _ in
            if recoveryPending, settings.recoverNetworkSessions { reconnect() }
        }
    }

    private var terminalPane: some View {
        let generation = processID
        return ZStack {
            OpenSSHTerminalSurface(
                connection: connection,
                inputController: inputController,
                onTermination: { code in
                    guard generation == processID else { return }
                    inputController.processDidEnd()
                    exitCode = code
                    processEnded = true
                }
            )
            .id(processID)

            if inputController.isAwaitingPassword, !processEnded {
                passwordPromptBanner
            }

            if processEnded {
                VStack {
                    Spacer()
                    HStack(spacing: 12) {
                        Image(systemName: "network.slash")
                            .foregroundStyle(.secondary)
                        Text(terminationMessage)
                            .font(.callout)
                        Button("Reconnect", action: reconnect)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 8, y: 3)
                    .padding(.bottom, 18)
                }
            }
        }
        .onAppear(perform: loadSavedPassword)
    }

    private var passwordPromptBanner: some View {
        VStack {
            HStack(spacing: 10) {
                Image(systemName: "key.fill")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Password entry is hidden")
                        .font(.callout.weight(.medium))
                    Text("Type or paste it and press Return—no characters or dots will appear.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if inputController.hasSavedPassword {
                    Button("Send Saved Password") {
                        inputController.sendSavedPassword()
                    }
                    .help("Send the password stored for this connection in macOS Keychain")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 8, y: 3)
            .padding(.top, 14)

            if let credentialError {
                Text(credentialError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Spacer()
        }
        .padding(.horizontal)
    }

    private var terminationMessage: String {
        if recoveryPending { return "Session interrupted. Reconnect when the network is ready; previous commands will not be replayed." }
        guard let exitCode else { return "SSH process ended." }
        return exitCode == 0
            ? "SSH session closed."
            : "SSH exited with status \(exitCode)."
    }

    private func loadSavedPassword() {
        credentialTask?.cancel()
        inputController.setSavedPassword(nil)
        credentialTask = Task {
            do {
                let password = try await appState.sessionPassword(for: connection)
                try Task.checkCancellation()
                inputController.setSavedPassword(password); credentialError = nil
            } catch { credentialError = "Could not read the saved password: \(error.localizedDescription)" }
        }
        let task = credentialTask
        // Closing a retained tab cancels provider authentication even if its
        // SwiftUI view has not delivered onDisappear yet.
        lifetime?.own("credential-fetch") { task?.cancel(); inputController.setSavedPassword(nil) }
    }

    private func reconnect() {
        recoveryPending = false; exitCode = nil; processEnded = false
        loadSavedPassword()
        processID = UUID()
    }
}

private struct OpenSSHTerminalSurface: NSViewRepresentable {
    let connection: RemoteConnection
    let inputController: OpenSSHInputController
    let onTermination: (Int32?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTermination: onTermination)
    }

    func makeNSView(context: Context) -> ManagedProcessTerminalView {
        let terminalView = PasswordObservingTerminalView(frame: .zero, options: context.environment.terminalAppearance.options)
        context.environment.terminalAppearance.apply(terminalView)
        context.coordinator.capture = TerminalCapture(view: terminalView, id: context.environment.sessionTabID, experience: context.environment.terminalExperience)
        terminalView.processDelegate = context.coordinator
        context.coordinator.inputController = inputController
        inputController.attach(to: terminalView)
        context.environment.sessionLifetime?.focus = { [weak terminalView] in if let terminalView { terminalView.window?.makeFirstResponder(terminalView) } }
        context.environment.commandRouter?.register(context.environment.sessionTabID, identity: terminalView, ready: { [weak inputController] in inputController?.canInsert == true }) { [weak inputController] in inputController?.insert($0) ?? false }

        do { try SSHInputValidation.validate(connection) }
        catch {
            terminalView.feed(text: "The SSH host, account or jump settings are not valid. Review this connection before retrying.\r\n")
            DispatchQueue.main.async { onTermination(1) }
            return terminalView
        }
        let destination = connection.username.isEmpty
            ? connection.host
            : "\(connection.username)@\(connection.host)"
        var arguments = [
            "-tt",
            "-p", String(connection.port),
            "-o", "ConnectTimeout=15",
            "-o", "StrictHostKeyChecking=ask",
            "-o", "PermitLocalCommand=no",
        ]

        let keepAliveInterval = connection.effectiveSSHKeepAliveInterval
        if keepAliveInterval > 0 {
            arguments += [
                "-o", "ServerAliveInterval=\(keepAliveInterval)",
                "-o", "ServerAliveCountMax=3",
            ]
        }

        switch connection.effectiveSSHAuthentication {
        case .automatic:
            break
        case .password:
            arguments += [
                "-o", "PreferredAuthentications=keyboard-interactive,password",
                "-o", "PubkeyAuthentication=no",
            ]
        case .publicKey:
            arguments += [
                "-o", "PreferredAuthentications=publickey",
                "-o", "PasswordAuthentication=no",
                "-o", "KbdInteractiveAuthentication=no",
            ]
        }

        if let identityFile = normalized(connection.sshIdentityFile) {
            arguments += ["-i", (identityFile as NSString).expandingTildeInPath]
        }
        if let jumpHost = normalized(connection.sshJumpHost) {
            arguments += ["-J", jumpHost]
        }
        if connection.sshForwardAgent == true {
            arguments.append("-A")
        } else {
            arguments += ["-o", "ForwardAgent=no"]
        }
        if connection.sshCompression == true {
            arguments.append("-C")
        }
        do {
            arguments += try (connection.sshX11 ?? SSHX11Configuration()).arguments()
            if connection.sshX11 == nil || connection.sshX11?.mode == .off { arguments += try SSHConnectionReuse.arguments(for: connection) }
        }
        catch {
            terminalView.feed(text: "SSH could not prepare its private transport or X11 display. Review the connection and local display settings.\r\n")
            DispatchQueue.main.async { onTermination(1) }
            return terminalView
        }
        arguments += ["--", destination]

        terminalView.feed(text: "Connecting with macOS OpenSSH…\r\n")
        if let identityFile = normalized(connection.sshIdentityFile) {
            terminalView.feed(text: "Identity: \((identityFile as NSString).lastPathComponent)\r\n")
        }
        terminalView.startProcess(
            executable: "/usr/bin/ssh",
            args: arguments,
            environment: sshEnvironment,
            currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        )

        context.coordinator.focus.update(context.environment.sessionIsActive) {
            terminalView.window?.makeFirstResponder(terminalView)
        }
        return terminalView
    }

    func updateNSView(_ terminalView: ManagedProcessTerminalView, context: Context) {
        context.environment.commandRouter?.register(context.environment.sessionTabID, identity: terminalView, ready: { [weak inputController] in inputController?.canInsert == true }) { [weak inputController] in inputController?.insert($0) ?? false }
        context.coordinator.onTermination = onTermination
        context.coordinator.inputController = inputController
        context.coordinator.focus.update(context.environment.sessionIsActive) { terminalView.window?.makeFirstResponder(terminalView) }
    }

    static func dismantleNSView(_ terminalView: ManagedProcessTerminalView, coordinator: Coordinator) {
        terminalView.processDelegate = nil
        coordinator.capture?.close()
        coordinator.inputController?.detach(from: terminalView)
        terminalView.terminate()
    }

    private var sshEnvironment: [String] {
        var values = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
        let inheritedNames = [
            "SSH_AUTH_SOCK",
            "SSH_AGENT_PID",
            "PATH",
            "LANG",
            "LC_ALL",
            "LC_CTYPE",
        ]

        for name in inheritedNames {
            guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else { continue }
            values.removeAll { $0.hasPrefix("\(name)=") }
            values.append("\(name)=\(value)")
        }
        if let x11 = connection.sshX11, x11.mode != .off, SSHX11Configuration.validDisplay(x11.display) {
            values.removeAll { $0.hasPrefix("DISPLAY=") }; values.append("DISPLAY=\(x11.display)")
        }
        return values
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    final class Coordinator: NSObject, ManagedProcessTerminalViewDelegate {
        var capture: TerminalCapture?
        let focus = SessionFocusGate()
        var onTermination: (Int32?) -> Void
        weak var inputController: OpenSSHInputController?

        init(onTermination: @escaping (Int32?) -> Void) {
            self.onTermination = onTermination
        }

        func sizeChanged(source: ManagedProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: ManagedProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) { TerminalLinkSecurity.open(link) }

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            let normalizedCode = exitCode.map { code in
                code > 255 ? (code >> 8) & 0xff : code
            }
            DispatchQueue.main.async { [weak self, onTermination] in
                self?.capture?.close()
                onTermination(normalizedCode)
            }
        }
    }
}

class PasswordObservingTerminalView: PasteableLocalProcessTerminalView {
    private(set) var authenticationPrompt = false
    var passwordPromptObserver: (() -> Void)?
    var submittedInputObserver: (() -> Void)?
    private var promptTail = ""

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)

        // Terminal output can arrive in very small fragments. Keep prompt
        // detection local to the AppKit view so normal command output does not
        // allocate byte arrays or enqueue work on SwiftUI's main actor.
        promptTail = String((promptTail + String(decoding: slice.suffix(160), as: UTF8.self)).suffix(160))
        if ["password:", "passphrase", "verification code", "one-time", "continue connecting (yes/no"].contains(where: { promptTail.localizedCaseInsensitiveContains($0) }) { authenticationPrompt = true }
        if promptTail.localizedCaseInsensitiveContains("password:") {
            promptTail = ""
            passwordPromptObserver?()
        }
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        super.send(source: source, data: data)
        guard data.contains(10) || data.contains(13) else { return }
        authenticationPrompt = false
        submittedInputObserver?()
    }
}

@MainActor final class OpenSSHInputController: ObservableObject {
    private let credentialGate: CredentialAccessGate
    init(credentialGate: CredentialAccessGate = .shared) { self.credentialGate = credentialGate }
    var canInsert: Bool { !credentialGate.isLocked && terminalView != nil && !isAwaitingPassword && (terminalView as? PasswordObservingTerminalView)?.authenticationPrompt != true }
    @Published private(set) var isAwaitingPassword = false
    @Published private var savedPassword: String?

    var hasSavedPassword: Bool {
        guard let savedPassword else { return false }
        return !savedPassword.isEmpty
    }

    private weak var terminalView: ManagedProcessTerminalView?
    private var generation = UUID()
    func setSavedPassword(_ password: String?) {
        savedPassword = password.flatMap { value in
            value.utf8.count <= 65536 && value.rangeOfCharacter(from: .controlCharacters) == nil ? value : nil
        }
    }

    func attach(to terminalView: PasswordObservingTerminalView) {
        self.terminalView = terminalView
        generation = UUID()
        isAwaitingPassword = false

        terminalView.passwordPromptObserver = { [weak self] in
            self?.passwordPromptDetected()
        }
        terminalView.submittedInputObserver = { [weak self] in
            self?.inputSubmitted()
        }
    }

    func detach(from terminalView: ManagedProcessTerminalView) {
        if let terminalView = terminalView as? PasswordObservingTerminalView {
            terminalView.passwordPromptObserver = nil
            terminalView.submittedInputObserver = nil
        }
        if self.terminalView === terminalView {
            generation = UUID()
            self.terminalView = nil
        }
    }

    func sendSavedPassword() {
        guard !credentialGate.isLocked, isAwaitingPassword, let terminalView, let savedPassword, !savedPassword.isEmpty else { return }
        let bytes = Array((savedPassword + "\r").utf8)
        terminalView.send(source: terminalView, data: bytes[...])
        isAwaitingPassword = false
        terminalView.window?.makeFirstResponder(terminalView)
    }

    func processDidEnd() {
        generation = UUID()
        isAwaitingPassword = false
        terminalView = nil
        savedPassword = nil
    }

    func disconnect() { generation = UUID(); terminalView?.terminate(); terminalView = nil; isAwaitingPassword = false; savedPassword = nil }
    func insert(_ text: String) -> Bool {
        guard canInsert, let terminalView else { return false }
        terminalView.send(source: terminalView, data: Array(text.utf8)[...]); return true
    }

    private func passwordPromptDetected() {
        let generation = generation
        DispatchQueue.main.async { [weak self] in
            guard self?.generation == generation else { return }
            if self?.isAwaitingPassword == false { self?.isAwaitingPassword = true }
        }
    }

    private func inputSubmitted() {
        let generation = generation
        DispatchQueue.main.async { [weak self] in
            guard self?.generation == generation else { return }
            if self?.isAwaitingPassword == true { self?.isAwaitingPassword = false }
        }
    }
}
