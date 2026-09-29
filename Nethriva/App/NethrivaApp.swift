import SwiftUI

@main
struct NethrivaApp: App {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var appState = AppState()
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(settings)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            NethrivaHelpCommands()

            CommandGroup(after: .newItem) {
                Button("Find Connection…") {
                    appState.focusConnectionSearch()
                }
                .keyboardShortcut("f", modifiers: [.command])

                Divider()

                Button("Open Selected Connection") {
                    appState.openSelectedConnection()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("Open SFTP for Selected Connection") {
                    guard let connection = appState.selectedConnection else { return }
                    appState.openSFTP(connection)
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(appState.selectedConnection?.kind != .ssh)

                Divider()

                Button("Import Connections…") {
                    appState.chooseConnectionArchiveToImport()
                }

                Button("Export Connections…") {
                    appState.requestConnectionExport()
                }

                Button("Manage Credential Profiles…") {
                    openWindow(id: "credential-manager")
                }

                Divider()

                Button("Export Redacted Diagnostics…") {
                    appState.exportDiagnostics()
                }
            }
        }

        WindowGroup("Connection", id: "connection-editor", for: ConnectionEditorRequest.self) { request in
            if let request = request.wrappedValue {
                ConnectionEditorView(
                    connection: request.connectionID.flatMap { connectionID in
                        appState.connections.first { $0.id == connectionID }
                    },
                    initialGroup: request.initialGroup
                )
                .environmentObject(appState)
            } else {
                ConnectionEditorView()
                    .environmentObject(appState)
            }
        }
        .windowResizability(.contentSize)

        WindowGroup("Connection Library", id: "connection-transfer", for: ConnectionTransferRequest.self) { request in
            if let request = request.wrappedValue {
                ConnectionTransferView(request: request)
                    .environmentObject(appState)
            } else {
                ContentUnavailableView("No transfer selected", systemImage: "arrow.left.arrow.right")
                    .frame(width: 560, height: 500)
            }
        }
        .windowResizability(.contentSize)

        Window("Nethriva Help", id: NethrivaWindow.help) {
            NethrivaHelpView()
        }
        .defaultSize(width: 1040, height: 760)
        .windowResizability(.contentMinSize)

        Window("Credential Profiles", id: "credential-manager") {
            CredentialManagerView()
                .environmentObject(appState)
        }
        .defaultSize(width: 780, height: 510)

        Settings {
            NethrivaSettingsView()
                .environmentObject(settings)
        }
    }
}
