import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationSplitView {
            ConnectionSidebarView(
                onNewConnection: { group in
                    openWindow(
                        id: "connection-editor",
                        value: ConnectionEditorRequest(initialGroup: group)
                    )
                },
                onEditConnection: { connection in
                    openWindow(
                        id: "connection-editor",
                        value: ConnectionEditorRequest(connection: connection)
                    )
                }
            )
                .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 360)
        } detail: {
            SessionWorkspaceView()
        }
        .toolbar {
            ToolbarItem {
                Button {
                    openWindow(id: "credential-manager")
                } label: {
                    Label("Credential Profiles", systemImage: "key.horizontal")
                }
                .help("Manage reusable usernames and Keychain passwords")
            }

            ToolbarItem {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
            }

            ToolbarItem {
                Button {
                    openWindow(id: NethrivaWindow.help)
                } label: {
                    Label("Help", systemImage: "questionmark.circle")
                }
                .help("Open Nethriva Help")
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    openWindow(id: "connection-editor", value: ConnectionEditorRequest())
                } label: {
                    Label("New Connection", systemImage: "plus")
                }
            }

            ToolbarItem {
                Menu {
                    Button {
                        appState.chooseConnectionArchiveToImport()
                    } label: {
                        Label("Import Connections…", systemImage: "square.and.arrow.down")
                    }

                    Button {
                        appState.requestConnectionExport()
                    } label: {
                        Label("Export Connections…", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Label("Connection Library", systemImage: "arrow.left.arrow.right")
                }
                .help("Import or export the connection library")
            }
        }
        .alert("Nethriva Data Notice", isPresented: Binding(
            get: { appState.persistenceNotice != nil },
            set: { if !$0 { appState.persistenceNotice = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.persistenceNotice ?? "")
        }
        .onChange(of: appState.connectionTransferRequest?.id) { _, _ in
            guard let request = appState.connectionTransferRequest else { return }
            openWindow(id: "connection-transfer", value: request)
            appState.connectionTransferRequest = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            appState.shutdownSSHTransports()
        }
    }
}

struct ConnectionEditorRequest: Codable, Hashable, Identifiable {
    let id: UUID
    let connectionID: UUID?
    let initialGroup: String?

    init(connection: RemoteConnection? = nil, initialGroup: String? = nil) {
        self.id = connection?.id ?? UUID()
        self.connectionID = connection?.id
        self.initialGroup = initialGroup
    }
}
