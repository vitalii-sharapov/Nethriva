import SwiftUI

struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
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
        .toolbar {
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
