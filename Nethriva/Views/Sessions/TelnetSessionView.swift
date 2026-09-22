import AppKit
import Network
import SwiftTerm
import SwiftUI

struct TelnetSessionView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var inputController = TelnetInputController()

    let connection: RemoteConnection

    @State private var sessionID = UUID()
    @State private var status: TelnetSessionStatus = .connecting
    @State private var credentialError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label("Telnet", systemImage: "network")
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

            ZStack {
                TelnetTerminalSurface(
                    connection: connection,
                    inputController: inputController,
                    onStatus: { status = $0 }
                )
                .id(sessionID)

                if inputController.isAwaitingPassword, status == .connected {
                    passwordBanner
                }

                if case .ended(let message) = status {
                    VStack {
                        Spacer()
                        HStack(spacing: 12) {
                            Image(systemName: "network.slash")
                                .foregroundStyle(.secondary)
                            Text(message)
                                .font(.callout)
                            Button("Reconnect") {
                                status = .connecting
                                sessionID = UUID()
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
        }
        .onAppear(perform: loadSavedPassword)
    }

    private var passwordBanner: some View {
        VStack {
            HStack(spacing: 10) {
                Image(systemName: "key.fill")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Telnet password entry")
                        .font(.callout.weight(.medium))
                    Text("Telnet is unencrypted. Send credentials only on a trusted network.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if inputController.hasSavedPassword {
                    Button("Send Saved Password") {
                        inputController.sendSavedPassword()
                    }
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

    private func loadSavedPassword() {
        do {
            inputController.setSavedPassword(try appState.password(for: connection))
            credentialError = nil
        } catch {
            credentialError = "Could not read the saved password: \(error.localizedDescription)"
        }
    }
}

private enum TelnetSessionStatus: Equatable {
    case connecting
    case connected
    case ended(String)
}

private struct TelnetTerminalSurface: NSViewRepresentable {
    let connection: RemoteConnection
    let inputController: TelnetInputController
    let onStatus: (TelnetSessionStatus) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(inputController: inputController, onStatus: onStatus)
    }

    func makeNSView(context: Context) -> TerminalView {
        let terminalView = PasteableNetworkTerminalView(frame: .zero)
        terminalView.terminalDelegate = context.coordinator
        context.coordinator.attach(terminalView)
        terminalView.feed(text: "Connecting with Telnet…\r\n")
        terminalView.feed(text: "Warning: Telnet traffic is not encrypted.\r\n")
        context.coordinator.connect(host: connection.host, port: connection.port)

        DispatchQueue.main.async {
            terminalView.window?.makeFirstResponder(terminalView)
        }
        return terminalView
    }

    func updateNSView(_ terminalView: TerminalView, context: Context) {
        context.coordinator.onStatus = onStatus
    }

    static func dismantleNSView(_ terminalView: TerminalView, coordinator: Coordinator) {
        terminalView.terminalDelegate = nil
        coordinator.close()
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        var onStatus: (TelnetSessionStatus) -> Void

        private let inputController: TelnetInputController
        private let queue = DispatchQueue(label: "com.vitalii.nethriva.telnet")
        private var connection: NWConnection?
        private var parser = TelnetProtocolParser()
        private weak var terminalView: TerminalView?
        private var promptTail = ""

        init(
            inputController: TelnetInputController,
            onStatus: @escaping (TelnetSessionStatus) -> Void
        ) {
            self.inputController = inputController
            self.onStatus = onStatus
        }

        func attach(_ terminalView: TerminalView) {
            self.terminalView = terminalView
            inputController.attach(to: terminalView, sender: { [weak self] bytes in
                self?.send(bytes)
            })
        }

        func connect(host: String, port: Int) {
            guard (1...65_535).contains(port),
                  let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
                finish("Invalid Telnet port.")
                return
            }

            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: endpointPort,
                using: .tcp
            )
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.publish(.connected)
                    self.receive()
                case .failed(let error):
                    self.finish("Telnet connection failed: \(error.localizedDescription)")
                case .cancelled:
                    break
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }

        func close() {
            connection?.stateUpdateHandler = nil
            connection?.cancel()
            connection = nil
            inputController.detach()
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            queue.async { [weak self] in
                guard let self, let response = self.parser.updateWindowSize(
                    columns: newCols,
                    rows: newRows
                ) else { return }
                self.sendRaw(response)
            }
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            inputController.inputSubmitted(data)
            send(Array(data))
        }

        private func send(_ bytes: [UInt8]) {
            queue.async { [weak self] in
                guard let self else { return }
                self.sendRaw(TelnetProtocolParser.escapeOutgoing(bytes))
            }
        }

        private func sendRaw(_ bytes: [UInt8]) {
            connection?.send(
                content: Data(bytes),
                completion: .contentProcessed { [weak self] error in
                    if let error {
                        self?.finish("Telnet send failed: \(error.localizedDescription)")
                    }
                }
            )
        }

        private func receive() {
            connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
                [weak self] data, _, isComplete, error in
                guard let self else { return }

                if let data, !data.isEmpty {
                    let result = self.parser.process(Array(data))
                    for response in result.responses {
                        self.sendRaw(response)
                    }
                    if !result.display.isEmpty {
                        let text = String(decoding: result.display, as: UTF8.self)
                        DispatchQueue.main.async {
                            self.terminalView?.feed(byteArray: result.display[...])
                            self.observePrompt(text)
                        }
                    }
                }

                if let error {
                    self.finish("Telnet connection ended: \(error.localizedDescription)")
                } else if isComplete {
                    self.finish("Telnet session closed.")
                } else {
                    self.receive()
                }
            }
        }

        private func observePrompt(_ text: String) {
            promptTail = String((promptTail + text).suffix(160))
            if promptTail.localizedCaseInsensitiveContains("password:") {
                promptTail = ""
                inputController.passwordPromptDetected()
            }
        }

        private func publish(_ status: TelnetSessionStatus) {
            DispatchQueue.main.async { [weak self] in
                self?.onStatus(status)
            }
        }

        private func finish(_ message: String) {
            connection?.stateUpdateHandler = nil
            connection?.cancel()
            connection = nil
            inputController.processDidEnd()
            publish(.ended(message))
        }
    }
}

private final class PasteableNetworkTerminalView: TerminalView {
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        paste(self)
    }
}

private final class TelnetInputController: ObservableObject {
    @Published private(set) var isAwaitingPassword = false
    private var savedPassword: String?
    private weak var terminalView: TerminalView?
    private var sender: (([UInt8]) -> Void)?

    var hasSavedPassword: Bool {
        !(savedPassword?.isEmpty ?? true)
    }

    func setSavedPassword(_ password: String?) {
        savedPassword = password
    }

    func attach(to terminalView: TerminalView, sender: @escaping ([UInt8]) -> Void) {
        self.terminalView = terminalView
        self.sender = sender
        isAwaitingPassword = false
    }

    func detach() {
        terminalView = nil
        sender = nil
        isAwaitingPassword = false
    }

    func sendSavedPassword() {
        guard let savedPassword, !savedPassword.isEmpty else { return }
        sender?(Array((savedPassword + "\r").utf8))
        isAwaitingPassword = false
        if let terminalView {
            terminalView.window?.makeFirstResponder(terminalView)
        }
    }

    func passwordPromptDetected() {
        isAwaitingPassword = true
    }

    func inputSubmitted(_ data: ArraySlice<UInt8>) {
        guard data.contains(10) || data.contains(13) else { return }
        isAwaitingPassword = false
    }

    func processDidEnd() {
        DispatchQueue.main.async { [weak self] in
            self?.isAwaitingPassword = false
        }
    }
}

struct TelnetParseResult: Equatable {
    var display: [UInt8] = []
    var responses: [[UInt8]] = []
}

struct TelnetProtocolParser {
    private enum State {
        case data
        case command
        case option(UInt8)
        case subnegotiationOption
        case subnegotiation(option: UInt8, bytes: [UInt8])
        case subnegotiationCommand(option: UInt8, bytes: [UInt8])
    }

    private enum Code {
        static let subnegotiationEnd: UInt8 = 240
        static let subnegotiation: UInt8 = 250
        static let will: UInt8 = 251
        static let wont: UInt8 = 252
        static let doCode: UInt8 = 253
        static let dont: UInt8 = 254
        static let iac: UInt8 = 255
    }

    private enum Option {
        static let echo: UInt8 = 1
        static let suppressGoAhead: UInt8 = 3
        static let terminalType: UInt8 = 24
        static let windowSize: UInt8 = 31
    }

    private var state: State = .data
    private var columns = 80
    private var rows = 24
    private var windowSizeEnabled = false

    mutating func process(_ input: [UInt8]) -> TelnetParseResult {
        var result = TelnetParseResult()

        for byte in input {
            switch state {
            case .data:
                if byte == Code.iac {
                    state = .command
                } else {
                    result.display.append(byte)
                }
            case .command:
                switch byte {
                case Code.iac:
                    result.display.append(byte)
                    state = .data
                case Code.will, Code.wont, Code.doCode, Code.dont:
                    state = .option(byte)
                case Code.subnegotiation:
                    state = .subnegotiationOption
                default:
                    state = .data
                }
            case .option(let command):
                result.responses.append(contentsOf: negotiation(command: command, option: byte))
                state = .data
            case .subnegotiationOption:
                state = .subnegotiation(option: byte, bytes: [])
            case .subnegotiation(let option, var bytes):
                if byte == Code.iac {
                    state = .subnegotiationCommand(option: option, bytes: bytes)
                } else {
                    bytes.append(byte)
                    state = .subnegotiation(option: option, bytes: bytes)
                }
            case .subnegotiationCommand(let option, var bytes):
                if byte == Code.subnegotiationEnd {
                    if let response = subnegotiationResponse(option: option, bytes: bytes) {
                        result.responses.append(response)
                    }
                    state = .data
                } else if byte == Code.iac {
                    bytes.append(Code.iac)
                    state = .subnegotiation(option: option, bytes: bytes)
                } else {
                    state = .data
                }
            }
        }
        return result
    }

    mutating func updateWindowSize(columns: Int, rows: Int) -> [UInt8]? {
        self.columns = min(max(columns, 1), 65_535)
        self.rows = min(max(rows, 1), 65_535)
        return windowSizeEnabled ? windowSizeMessage() : nil
    }

    static func escapeOutgoing(_ bytes: [UInt8]) -> [UInt8] {
        bytes.flatMap { $0 == Code.iac ? [Code.iac, Code.iac] : [$0] }
    }

    private mutating func negotiation(command: UInt8, option: UInt8) -> [[UInt8]] {
        switch command {
        case Code.will:
            let accepted = option == Option.echo || option == Option.suppressGoAhead
            return [[Code.iac, accepted ? Code.doCode : Code.dont, option]]
        case Code.doCode:
            let accepted = option == Option.suppressGoAhead
                || option == Option.terminalType
                || option == Option.windowSize
            if option == Option.windowSize, accepted {
                windowSizeEnabled = true
                return [
                    [Code.iac, Code.will, option],
                    windowSizeMessage(),
                ]
            }
            return [[Code.iac, accepted ? Code.will : Code.wont, option]]
        default:
            return []
        }
    }

    private func subnegotiationResponse(option: UInt8, bytes: [UInt8]) -> [UInt8]? {
        guard option == Option.terminalType, bytes.first == 1 else { return nil }
        return [Code.iac, Code.subnegotiation, Option.terminalType, 0]
            + Array("xterm-256color".utf8)
            + [Code.iac, Code.subnegotiationEnd]
    }

    private func windowSizeMessage() -> [UInt8] {
        let payload: [UInt8] = [
            UInt8((columns >> 8) & 0xff),
            UInt8(columns & 0xff),
            UInt8((rows >> 8) & 0xff),
            UInt8(rows & 0xff),
        ]
        return [Code.iac, Code.subnegotiation, Option.windowSize]
            + Self.escapeOutgoing(payload)
            + [Code.iac, Code.subnegotiationEnd]
    }
}
