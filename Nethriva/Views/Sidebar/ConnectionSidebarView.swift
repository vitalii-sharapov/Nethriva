import AppKit
import SwiftUI

struct ConnectionSidebarView: View {
    @EnvironmentObject private var appState: AppState
    let onNewConnection: (String?) -> Void
    let onEditConnection: (RemoteConnection) -> Void

    @State private var isPresentingNewGroup = false
    @State private var newGroupName = ""
    @State private var actionError: String?

    var body: some View {
        List(selection: $appState.selectedConnectionID) {
            if !favorites.isEmpty {
                Section("Favorites") {
                    ForEach(favorites) { connection in
                        row(connection)
                    }
                }
            }

            ForEach(groupNames, id: \.self) { groupName in
                Section {
                    let groupConnections = connections(in: groupName)
                    ForEach(groupConnections) { connection in
                        row(connection)
                    }
                    if groupConnections.isEmpty {
                        Button {
                            onNewConnection(groupName)
                        } label: {
                            Label("Add a connection", systemImage: "plus")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    groupHeader(groupName)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Nethriva")
        .safeAreaInset(edge: .bottom) {
            HStack {
                Menu {
                    Button {
                        onNewConnection(nil)
                    } label: {
                        Label("New Connection", systemImage: "plus.rectangle.on.folder")
                    }

                    Button {
                        newGroupName = ""
                        isPresentingNewGroup = true
                    } label: {
                        Label("New Group", systemImage: "folder.badge.plus")
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)

                Menu {
                    selectedConnectionActions
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .help("Actions for the selected connection")

                Menu {
                    Button("Import Connections…") {
                        appState.chooseConnectionArchiveToImport()
                    }
                    Button("Export Connections…") {
                        appState.requestConnectionExport()
                    }
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .menuStyle(.borderlessButton)
                .help("Import or export the connection library")

                Spacer()

                Button {
                    appState.openSelectedConnection()
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderless)
                .help("Open selected connection")
                .disabled(appState.selectedConnection == nil)
            }
            .padding(10)
            .background(.bar)
        }
        .alert("New Group", isPresented: $isPresentingNewGroup) {
            TextField("Group name", text: $newGroupName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                _ = appState.addGroup(newGroupName)
            }
            .disabled(newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Create an empty sidebar group. You can add connections to it afterward.")
        }
        .alert("Could Not Complete Action", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "Unknown error")
        }
    }

    private var favorites: [RemoteConnection] {
        appState.connections.filter(\.isFavorite)
    }

    private var groupNames: [String] {
        var result = appState.groups
        for connection in appState.connections where !connection.isFavorite {
            guard !result.contains(where: {
                $0.caseInsensitiveCompare(connection.group) == .orderedSame
            }) else { continue }
            result.append(connection.group)
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func connections(in groupName: String) -> [RemoteConnection] {
        appState.connections
            .filter {
                !$0.isFavorite && $0.group.caseInsensitiveCompare(groupName) == .orderedSame
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func hasConnections(in groupName: String) -> Bool {
        appState.connections.contains {
            $0.kind != .localShell && $0.group.caseInsensitiveCompare(groupName) == .orderedSame
        }
    }

    @ViewBuilder
    private func groupHeader(_ groupName: String) -> some View {
        HStack {
            Label(groupName, systemImage: "folder")
            Spacer()
            Menu {
                Button("Add Connection") {
                    onNewConnection(groupName)
                }
                if !hasConnections(in: groupName) {
                    Divider()
                    Button("Delete Empty Group", role: .destructive) {
                        appState.deleteGroup(groupName)
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
        }
    }

    @ViewBuilder
    private var selectedConnectionActions: some View {
        if let connection = appState.selectedConnection {
            Button("Open") {
                appState.open(connection)
            }

            if connection.kind == .ssh {
                Button("Open SFTP Browser") {
                    appState.openSFTP(connection)
                }
            }

            if connection.kind != .localShell {
                Button("Edit…") {
                    onEditConnection(connection)
                }
                Button("Duplicate") {
                    duplicate(connection)
                }

                Menu("Move to Group") {
                    ForEach(appState.groups, id: \.self) { groupName in
                        Button(groupName) {
                            appState.move(connection, toGroup: groupName)
                        }
                        .disabled(connection.group.caseInsensitiveCompare(groupName) == .orderedSame)
                    }
                }

                Divider()
                Button("Copy Address") {
                    copyToClipboard(connection.endpointDescription)
                }
                if connection.kind == .ssh {
                    Button("Copy SSH Command") {
                        copyToClipboard(sshCommand(for: connection))
                    }
                }
            }

            Button(connection.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                appState.toggleFavorite(connection)
            }

            if connection.kind != .localShell {
                Divider()
                Button("Delete", role: .destructive) {
                    appState.delete(connection)
                }
            }
        } else {
            Text("Select a connection")
        }
    }

    private func row(_ connection: RemoteConnection) -> some View {
        ConnectionRowView(connection: connection)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tag(connection.id)
            .contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture(count: 1)
                    .onEnded {
                        appState.selectedConnectionID = connection.id
                    }
            )
            .simultaneousGesture(
                TapGesture(count: 2)
                    .onEnded {
                        appState.selectedConnectionID = connection.id
                        appState.open(connection)
                    }
            )
            .contextMenu {
                Button("Open") {
                    appState.open(connection)
                }

                if connection.kind == .ssh {
                    Button("Open SFTP Browser") {
                        appState.openSFTP(connection)
                    }
                }

                if connection.kind != .localShell {
                    Button("Edit…") {
                        onEditConnection(connection)
                    }
                    Button("Duplicate") {
                        duplicate(connection)
                    }

                    Menu("Move to Group") {
                        ForEach(appState.groups, id: \.self) { groupName in
                            Button(groupName) {
                                appState.move(connection, toGroup: groupName)
                            }
                            .disabled(connection.group.caseInsensitiveCompare(groupName) == .orderedSame)
                        }
                    }

                    Divider()
                    Button("Copy Address") {
                        copyToClipboard(connection.endpointDescription)
                    }
                    if connection.kind == .ssh {
                        Button("Copy SSH Command") {
                            copyToClipboard(sshCommand(for: connection))
                        }
                    }
                }

                Button(connection.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                    appState.toggleFavorite(connection)
                }

                if connection.kind != .localShell {
                    Divider()
                    Button("Delete", role: .destructive) {
                        appState.delete(connection)
                    }
                }
            }
    }

    private func duplicate(_ connection: RemoteConnection) {
        do {
            try appState.duplicate(connection)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func sshCommand(for connection: RemoteConnection) -> String {
        let destination = connection.username.isEmpty
            ? connection.host
            : "\(connection.username)@\(connection.host)"
        return connection.port == ConnectionKind.ssh.defaultPort
            ? "ssh \(destination)"
            : "ssh -p \(connection.port) \(destination)"
    }
}
