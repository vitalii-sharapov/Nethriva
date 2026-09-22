import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var appState: AppState
    @State private var editorRequest: ConnectionEditorRequest?

    var body: some View {
        NavigationSplitView {
            ConnectionSidebarView(
                onNewConnection: { group in
                    editorRequest = ConnectionEditorRequest(initialGroup: group)
                },
                onEditConnection: { connection in
                    editorRequest = ConnectionEditorRequest(connection: connection)
                }
            )
                .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 360)
        } detail: {
            SessionWorkspaceView()
        }
        .sheet(item: $editorRequest) { request in
            ConnectionEditorView(
                connection: request.connection,
                initialGroup: request.initialGroup
            )
        }
        .sheet(item: $appState.connectionTransferRequest) { request in
            ConnectionTransferView(request: request)
                .environmentObject(appState)
        }
        .toolbar {
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
                    editorRequest = ConnectionEditorRequest()
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
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            appState.shutdownSSHTransports()
        }
    }
}

private struct ConnectionEditorRequest: Identifiable {
    let id = UUID()
    var connection: RemoteConnection?
    var initialGroup: String?

    init(connection: RemoteConnection? = nil, initialGroup: String? = nil) {
        self.connection = connection
        self.initialGroup = initialGroup
    }
}
