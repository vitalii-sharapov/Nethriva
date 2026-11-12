import AppKit
import SwiftTerm
import SwiftUI

struct SerialSessionView: View {
    @EnvironmentObject private var settings: AppSettings
    let connection: RemoteConnection

    @State private var sessionID = UUID()
    @State private var status: SerialStatus = .connecting
    @StateObject private var inputController = SerialInputController()

    var body: some View {
        let generation = sessionID
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label("Serial", systemImage: "cable.connector")
                    .font(.headline)
                if let endpoint = settings.sessionEndpoint(for: connection) {
                    Text(endpoint)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text("\(connection.effectiveSerialBaudRate.formatted()) baud · \(connection.effectiveSerialDataBits)\(connection.effectiveSerialParity.rawValue.prefix(1).uppercased())\(connection.effectiveSerialStopBits)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                ConnectionCheckButton(connection: connection).labelStyle(.iconOnly)
                if case .ended = status {
                    Button("Reconnect") { status = .connecting; sessionID = UUID() }
                } else {
                    Button("Disconnect") { inputController.disconnect(); status = .ended("Serial session disconnected.") }
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(.bar)
            Divider()

            ZStack {
                SerialTerminalSurface(connection: connection, inputController: inputController, onStatus: { if generation == sessionID { status = $0 } })
                    .id(sessionID)

                if case .ended(let message) = status {
                    VStack {
                        Spacer()
                        HStack(spacing: 12) {
                            Image(systemName: "cable.connector.slash")
                                .foregroundStyle(.secondary)
                            Text(message).font(.callout)
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
    }
}

private enum SerialStatus {
    case connecting
    case connected
    case ended(String)
}

private struct SerialTerminalSurface: NSViewRepresentable {
    let connection: RemoteConnection
    let inputController: SerialInputController
    let onStatus: (SerialStatus) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(localEcho: connection.effectiveSerialLocalEcho, onStatus: onStatus)
    }

    func makeNSView(context: Context) -> TerminalView {
        let terminal = PasteableSerialTerminalView(frame: .zero, options: context.environment.terminalAppearance.options)
        context.environment.terminalAppearance.apply(terminal)
        context.coordinator.capture = TerminalCapture(view: terminal, id: context.environment.sessionTabID, experience: context.environment.terminalExperience)
        terminal.terminalDelegate = context.coordinator
        context.coordinator.attach(terminal)
        context.environment.sessionLifetime?.focus = { [weak terminal] in if let terminal { terminal.window?.makeFirstResponder(terminal) } }
        inputController.disconnector = { [weak coordinator = context.coordinator] in coordinator?.close() }
        context.environment.commandRouter?.register(context.environment.sessionTabID, identity: terminal, ready: { [weak coordinator = context.coordinator] in coordinator?.ready == true }) { [weak coordinator = context.coordinator, weak terminal] text in
            guard let coordinator, let terminal, coordinator.ready else { return false }
            coordinator.send(source: terminal, data: Array(text.utf8)[...]); return true
        }
        terminal.feed(text: "Opening \(connection.host)…\r\n")
        context.coordinator.connect(SerialPortConfiguration(connection: connection))
        context.coordinator.focus.update(context.environment.sessionIsActive) { terminal.window?.makeFirstResponder(terminal) }
        return terminal
    }

    func updateNSView(_ terminal: TerminalView, context: Context) {
        context.coordinator.onStatus = onStatus
        context.coordinator.focus.update(context.environment.sessionIsActive) { terminal.window?.makeFirstResponder(terminal) }
    }

    static func dismantleNSView(_ terminal: TerminalView, coordinator: Coordinator) {
        terminal.terminalDelegate = nil
        coordinator.capture?.close()
        coordinator.close()
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        var capture: TerminalCapture?
        let focus = SessionFocusGate()
        var ready = false
        var onStatus: (SerialStatus) -> Void

        private let localEcho: Bool
        private let service = SerialPortService()
        private var outputLimiter = TerminalEscapeLimiter()
        private weak var terminal: TerminalView?

        init(localEcho: Bool, onStatus: @escaping (SerialStatus) -> Void) {
            self.localEcho = localEcho
            self.onStatus = onStatus
        }

        func attach(_ terminal: TerminalView) {
            self.terminal = terminal
            service.onData = { [weak terminal, weak self] bytes in
                // SerialPortService publishes data on the main queue.
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let bounded = self.outputLimiter.filter(bytes[...])
                    terminal?.feed(byteArray: bounded[...])
                    self.capture?.output(bounded[...])
                }
            }
            service.onState = { [weak self, weak terminal] state in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch state {
                    case .connected:
                        self.ready = true
                        terminal?.feed(text: "Connected.\r\n")
                        if self.focus.active { terminal?.window?.makeFirstResponder(terminal) }
                        self.onStatus(.connected)
                    case .ended(let message):
                        self.capture?.close()
                        self.ready = false
                        terminal?.feed(text: "\r\n\(message)\r\n")
                        self.onStatus(.ended(message))
                    }
                }
            }
        }

        func connect(_ configuration: SerialPortConfiguration) {
            service.open(configuration)
        }

        func close() {
            DispatchQueue.main.async { [weak self] in self?.capture?.close() }
            ready = false
            service.onData = nil
            service.onState = nil
            service.close()
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Array(data)
            service.send(bytes)
            if localEcho { source.feed(byteArray: bytes[...]) }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) { TerminalLinkSecurity.open(link) }
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

private final class PasteableSerialTerminalView: TerminalView {
    override func paste(_ sender: Any) { TerminalInputSecurity.paste(into: self) }
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        paste(self)
    }
}

private final class SerialInputController: ObservableObject {
    var disconnector: (() -> Void)?
    func disconnect() { disconnector?() }
}
