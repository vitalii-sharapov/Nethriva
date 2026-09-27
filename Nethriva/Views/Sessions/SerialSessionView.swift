import AppKit
import SwiftTerm
import SwiftUI

struct SerialSessionView: View {
    @EnvironmentObject private var settings: AppSettings
    let connection: RemoteConnection

    @State private var sessionID = UUID()
    @State private var status: SerialStatus = .connecting

    var body: some View {
        VStack(spacing: 0) {
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
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(.bar)
            Divider()

            ZStack {
                SerialTerminalSurface(connection: connection, onStatus: { status = $0 })
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
    let onStatus: (SerialStatus) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(localEcho: connection.effectiveSerialLocalEcho, onStatus: onStatus)
    }

    func makeNSView(context: Context) -> TerminalView {
        let terminal = PasteableSerialTerminalView(frame: .zero)
        terminal.terminalDelegate = context.coordinator
        context.coordinator.attach(terminal)
        terminal.feed(text: "Opening \(connection.host)…\r\n")
        context.coordinator.connect(SerialPortConfiguration(connection: connection))
        DispatchQueue.main.async { terminal.window?.makeFirstResponder(terminal) }
        return terminal
    }

    func updateNSView(_ terminal: TerminalView, context: Context) {
        context.coordinator.onStatus = onStatus
    }

    static func dismantleNSView(_ terminal: TerminalView, coordinator: Coordinator) {
        terminal.terminalDelegate = nil
        coordinator.close()
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        var onStatus: (SerialStatus) -> Void

        private let localEcho: Bool
        private let service = SerialPortService()
        private weak var terminal: TerminalView?

        init(localEcho: Bool, onStatus: @escaping (SerialStatus) -> Void) {
            self.localEcho = localEcho
            self.onStatus = onStatus
        }

        func attach(_ terminal: TerminalView) {
            self.terminal = terminal
            service.onData = { [weak terminal] bytes in
                terminal?.feed(byteArray: bytes[...])
            }
            service.onState = { [weak self, weak terminal] state in
                guard let self else { return }
                switch state {
                case .connected:
                    terminal?.feed(text: "Connected.\r\n")
                    terminal?.window?.makeFirstResponder(terminal)
                    self.onStatus(.connected)
                case .ended(let message):
                    terminal?.feed(text: "\r\n\(message)\r\n")
                    self.onStatus(.ended(message))
                }
            }
        }

        func connect(_ configuration: SerialPortConfiguration) {
            service.open(configuration)
        }

        func close() {
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
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

private final class PasteableSerialTerminalView: TerminalView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        paste(self)
    }
}
