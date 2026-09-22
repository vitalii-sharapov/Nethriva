import AppKit
import SwiftTerm
import SwiftUI

/// Runs Apple's OpenSSH client inside SwiftTerm's native pseudo-terminal.
/// This intentionally shares the same ~/.ssh configuration, identities,
/// known_hosts entries, ssh-agent, and interactive auth behavior as Terminal.
struct SSHSessionView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var inputController = OpenSSHInputController()

    let connection: RemoteConnection

    @State private var processID = UUID()
    @State private var processEnded = false
    @State private var exitCode: Int32?
    @State private var credentialError: String?

    var body: some View {
        HSplitView {
            SSHFileTreeView(connection: connection)

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
                }
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(.bar)
                Divider()
                terminalPane
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var terminalPane: some View {
        ZStack {
            OpenSSHTerminalSurface(
                connection: connection,
                inputController: inputController,
                onTermination: { code in
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
                        Button("Reconnect") {
                            exitCode = nil
                            processEnded = false
                            processID = UUID()
                        }
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
        guard let exitCode else { return "SSH process ended." }
        return exitCode == 0
            ? "SSH session closed."
            : "SSH exited with status \(exitCode)."
    }

    private func loadSavedPassword() {
        do {
            inputController.setSavedPassword(try appState.password(for: connection))
            credentialError = nil
        } catch {
            credentialError = "Could not read the saved password: \(error.localizedDescription)"
        }
    }
}

private struct OpenSSHTerminalSurface: NSViewRepresentable {
    let connection: RemoteConnection
    let inputController: OpenSSHInputController
    let onTermination: (Int32?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTermination: onTermination)
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminalView = PasswordObservingTerminalView(frame: .zero)
        terminalView.processDelegate = context.coordinator
        context.coordinator.inputController = inputController
        inputController.attach(to: terminalView)

        let destination = connection.username.isEmpty
            ? connection.host
            : "\(connection.username)@\(connection.host)"
        var arguments = [
            "-tt",
            "-p", String(connection.port),
            "-o", "ConnectTimeout=15",
            "-o", "StrictHostKeyChecking=ask",
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
        }
        if connection.sshCompression == true {
            arguments.append("-C")
        }
        arguments += SSHConnectionReuse.arguments
        arguments.append(destination)

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

        DispatchQueue.main.async {
            terminalView.window?.makeFirstResponder(terminalView)
        }
        return terminalView
    }

    func updateNSView(_ terminalView: LocalProcessTerminalView, context: Context) {
        context.coordinator.onTermination = onTermination
        context.coordinator.inputController = inputController
    }

    static func dismantleNSView(_ terminalView: LocalProcessTerminalView, coordinator: Coordinator) {
        terminalView.processDelegate = nil
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
        return values
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        var onTermination: (Int32?) -> Void
        weak var inputController: OpenSSHInputController?

        init(onTermination: @escaping (Int32?) -> Void) {
            self.onTermination = onTermination
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            let normalizedCode = exitCode.map { code in
                code > 255 ? (code >> 8) & 0xff : code
            }
            DispatchQueue.main.async { [onTermination] in
                onTermination(normalizedCode)
            }
        }
    }
}

private final class PasswordObservingTerminalView: PasteableLocalProcessTerminalView {
    var passwordPromptObserver: (() -> Void)?
    var submittedInputObserver: (() -> Void)?
    private var promptTail = ""

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)

        // Terminal output can arrive in very small fragments. Keep prompt
        // detection local to the AppKit view so normal command output does not
        // allocate byte arrays or enqueue work on SwiftUI's main actor.
        promptTail = String((promptTail + String(decoding: slice, as: UTF8.self)).suffix(160))
        if promptTail.localizedCaseInsensitiveContains("password:") {
            promptTail = ""
            passwordPromptObserver?()
        }
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        super.send(source: source, data: data)
        guard data.contains(10) || data.contains(13) else { return }
        submittedInputObserver?()
    }
}

private final class OpenSSHInputController: ObservableObject {
    @Published private(set) var isAwaitingPassword = false
    @Published private var savedPassword: String?

    var hasSavedPassword: Bool {
        guard let savedPassword else { return false }
        return !savedPassword.isEmpty
    }

    private weak var terminalView: LocalProcessTerminalView?
    func setSavedPassword(_ password: String?) {
        savedPassword = password
    }

    func attach(to terminalView: PasswordObservingTerminalView) {
        self.terminalView = terminalView
        isAwaitingPassword = false

        terminalView.passwordPromptObserver = { [weak self] in
            self?.passwordPromptDetected()
        }
        terminalView.submittedInputObserver = { [weak self] in
            self?.inputSubmitted()
        }
    }

    func detach(from terminalView: LocalProcessTerminalView) {
        if let terminalView = terminalView as? PasswordObservingTerminalView {
            terminalView.passwordPromptObserver = nil
            terminalView.submittedInputObserver = nil
        }
        if self.terminalView === terminalView {
            self.terminalView = nil
        }
    }

    func sendSavedPassword() {
        guard let terminalView, let savedPassword, !savedPassword.isEmpty else { return }
        let bytes = Array((savedPassword + "\r").utf8)
        terminalView.send(source: terminalView, data: bytes[...])
        isAwaitingPassword = false
        terminalView.window?.makeFirstResponder(terminalView)
    }

    func processDidEnd() {
        isAwaitingPassword = false
        terminalView = nil
    }

    private func passwordPromptDetected() {
        DispatchQueue.main.async { [weak self] in
            self?.isAwaitingPassword = true
        }
    }

    private func inputSubmitted() {
        DispatchQueue.main.async { [weak self] in
            self?.isAwaitingPassword = false
        }
    }
}
