import AppKit
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

struct ConnectionSidebarView: View {
    @EnvironmentObject private var appState: AppState
    let onNewConnection: (String?) -> Void
    let onEditConnection: (RemoteConnection) -> Void

    @State private var isPresentingNewGroup = false
    @State private var newGroupName = ""
    @State private var newGroupParent: String?
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool
    @State private var collapsedGroups: Set<String> = []
    @State private var renameRequest: RemoteConnection?
    @State private var renamedConnectionName = ""
    @State private var renameGroupPath: String?
    @State private var renamedGroupName = ""
    @State private var groupPendingRemoval: String?
    @State private var actionError: String?
    @State private var selectedItems: Set<SidebarSelectionItem> = []
    @State private var selectionAnchor: SidebarSelectionItem?
    @State private var dropTargetGroup: String?
    @State private var dropTargetConnectionID: UUID?
    @State private var isFavoritesDropTarget = false

    var body: some View {
        List {
            if isSearching {
                Section("Search Results") {
                    if searchResults.isEmpty {
                        Label("No matching connections", systemImage: "magnifyingglass")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(searchResults) { connection in
                            row(connection)
                        }
                    }
                }
            } else {
                Section {
                    if favorites.isEmpty {
                        Text("Drop connections here to add favorites")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .dropDestination(for: SidebarDragPayload.self) { payloads, _ in
                                acceptDrop(payloads, into: .favorites)
                            } isTargeted: { targeted in
                                isFavoritesDropTarget = targeted
                            }
                    } else {
                        ForEach(favorites) { connection in
                            row(connection)
                        }
                    }
                } header: {
                    Text("Favorites")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .background(isFavoritesDropTarget ? Color.accentColor.opacity(0.2) : Color.clear)
                        .dropDestination(for: SidebarDragPayload.self) { payloads, _ in
                            acceptDrop(payloads, into: .favorites)
                        } isTargeted: { targeted in
                            isFavoritesDropTarget = targeted
                        }
                }
            }

            if !isSearching {
                ForEach(rootGroupNames, id: \.self) { groupName in
                    groupTree(groupName)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Nethriva")
        .safeAreaInset(edge: .top) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search name or IP address", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.bar)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Menu {
                    Button {
                        onNewConnection(nil)
                    } label: {
                        Label("New Connection", systemImage: "plus.rectangle.on.folder")
                    }

                    Button {
                        beginNewGroup(under: nil)
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
        .alert(newGroupParent == nil ? "New Group" : "New Subgroup", isPresented: $isPresentingNewGroup) {
            TextField("Group name", text: $newGroupName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                if let parent = newGroupParent {
                    _ = appState.addSubgroup(newGroupName, under: parent)
                    collapsedGroups.remove(parent)
                } else {
                    _ = appState.addGroup(newGroupName)
                }
            }
            .disabled(!isValidNewGroupName)
        } message: {
            Text(newGroupParent.map { "Create a subgroup inside \($0)." }
                 ?? "Create a group in the sidebar. You can add connections or subgroups afterward.")
        }
        .alert("Rename Connection", isPresented: Binding(
            get: { renameRequest != nil },
            set: { if !$0 { renameRequest = nil } }
        )) {
            TextField("Connection name", text: $renamedConnectionName)
            Button("Cancel", role: .cancel) { renameRequest = nil }
            Button("Rename") { commitRename() }
                .disabled(renamedConnectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Change only the display name; connection settings and saved credentials stay the same.")
        }
        .alert("Rename Group", isPresented: Binding(
            get: { renameGroupPath != nil },
            set: { if !$0 { renameGroupPath = nil } }
        )) {
            TextField("Group name", text: $renamedGroupName)
            Button("Cancel", role: .cancel) { renameGroupPath = nil }
            Button("Rename") { commitGroupRename() }
                .disabled(!isValidRenamedGroupName)
        } message: {
            Text("Connections and subgroups will move with this group. Saved credentials are unchanged.")
        }
        .alert("Remove Group?", isPresented: Binding(
            get: { groupPendingRemoval != nil },
            set: { if !$0 { groupPendingRemoval = nil } }
        )) {
            Button("Cancel", role: .cancel) { groupPendingRemoval = nil }
            Button("Remove Group", role: .destructive) { commitGroupRemoval() }
        } message: {
            Text("Remove “\(groupPendingRemoval ?? "this group")” and its subgroups? Their connections will move to Ungrouped, and Favorite markers will be removed so every connection appears there. Saved credentials will stay unchanged.")
        }
        .alert("Could Not Complete Action", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "Unknown error")
        }
        .onChange(of: appState.connectionSearchFocusRequest) { _, _ in
            isSearchFocused = true
        }
        .onAppear {
            if let selectedID = appState.selectedConnectionID {
                let item = SidebarSelectionItem.connection(selectedID)
                selectedItems = [item]
                selectionAnchor = item
            }
        }
        .onChange(of: appState.selectedConnectionID) { _, selectedID in
            if let selectedID {
                let item = SidebarSelectionItem.connection(selectedID)
                if !selectedItems.contains(item) {
                    selectedItems = [item]
                    selectionAnchor = item
                }
            } else if selectedItems.contains(where: { if case .connection = $0 { true } else { false } }) {
                selectedItems.removeAll()
                selectionAnchor = nil
            }
        }
        .onChange(of: searchText) { _, _ in
            selectedItems.removeAll()
            selectionAnchor = nil
            appState.selectedConnectionID = nil
        }
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var searchResults: [RemoteConnection] {
        appState.connections
            .filter { ConnectionSearch.matches($0, query: searchText) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var isValidNewGroupName: Bool {
        let name = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && !name.contains("/")
            && name.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private var isValidRenamedGroupName: Bool {
        let name = renamedGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && !name.contains("/")
            && name.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private var favorites: [RemoteConnection] {
        appState.connections.filter(\.isFavorite)
    }

    private var groupNames: [String] {
        var result = appState.groups
        if !result.contains(where: { $0.caseInsensitiveCompare("Ungrouped") == .orderedSame }) {
            result.append("Ungrouped")
        }
        for connection in appState.connections where !connection.isFavorite {
            guard !result.contains(where: {
                $0.caseInsensitiveCompare(connection.group) == .orderedSame
            }) else { continue }
            result.append(connection.group)
        }
        for group in result {
            let segments = group.split(separator: "/")
            for prefix in segments.indices {
                let ancestor = segments[0...prefix].joined(separator: "/")
                if !result.contains(where: { $0.caseInsensitiveCompare(ancestor) == .orderedSame }) {
                    result.append(ancestor)
                }
            }
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var rootGroupNames: [String] {
        groupNames.filter { parentGroup(of: $0) == nil }
    }

    private var visibleItems: [SidebarSelectionItem] {
        if isSearching {
            return searchResults.map { .connection($0.id) }
        }
        var items = favorites.map { SidebarSelectionItem.connection($0.id) }
        for group in rootGroupNames {
            appendVisibleItems(in: group, to: &items)
        }
        return items
    }

    private func appendVisibleItems(in group: String, to items: inout [SidebarSelectionItem]) {
        items.append(.group(group))
        guard !collapsedGroups.contains(group) else { return }
        items.append(contentsOf: connections(in: group).map { .connection($0.id) })
        for child in childGroups(of: group) {
            appendVisibleItems(in: child, to: &items)
        }
    }

    private var currentModifiers: NSEvent.ModifierFlags {
        NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
    }

    private func select(_ item: SidebarSelectionItem, modifiers: NSEvent.ModifierFlags) {
        let updated = SidebarSelection.update(
            selected: selectedItems,
            anchor: selectionAnchor,
            clicked: item,
            visible: visibleItems,
            modifiers: modifiers
        )
        selectedItems = updated.selected
        selectionAnchor = updated.anchor
        if case .connection(let id) = item, updated.selected.contains(item) {
            appState.selectedConnectionID = id
        } else if let selectedID = appState.selectedConnectionID,
                  updated.selected.contains(.connection(selectedID)) {
            return
        } else {
            appState.selectedConnectionID = appState.connections.first {
                updated.selected.contains(.connection($0.id))
            }?.id
        }
    }

    private func childGroups(of parent: String) -> [String] {
        groupNames.filter { parentGroup(of: $0)?.caseInsensitiveCompare(parent) == .orderedSame }
    }

    private func parentGroup(of group: String) -> String? {
        guard let separator = group.lastIndex(of: "/") else { return nil }
        return String(group[..<separator])
    }

    private func groupTree(_ groupName: String) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { !collapsedGroups.contains(groupName) },
            set: { expanded in
                if expanded { collapsedGroups.remove(groupName) }
                else { collapsedGroups.insert(groupName) }
            }
        )) {
            let directConnections = connections(in: groupName)
            let children = childGroups(of: groupName)
            ForEach(directConnections) { connection in
                row(connection)
            }
            ForEach(children, id: \.self) { child in
                AnyView(groupTree(child))
            }
            if directConnections.isEmpty && children.isEmpty {
                Button {
                    onNewConnection(groupName)
                } label: {
                    Label("Add a connection", systemImage: "plus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .dropDestination(for: SidebarDragPayload.self) { payloads, _ in
                    acceptDrop(payloads, into: .group(groupName))
                } isTargeted: { targeted in
                    updateDropTarget(groupName, targeted: targeted)
                }
            }
        } label: {
            groupHeader(groupName)
        }
    }

    private func connections(in groupName: String) -> [RemoteConnection] {
        appState.connections
            .filter {
                !$0.isFavorite && $0.group.caseInsensitiveCompare(groupName) == .orderedSame
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @ViewBuilder
    private func groupHeader(_ groupName: String) -> some View {
        let content = HStack {
            Label(groupName.split(separator: "/").last.map(String.init) ?? groupName, systemImage: "folder")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    select(.group(groupName), modifiers: currentModifiers)
                }
            Menu {
                groupActions(for: groupName)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
        }
        .frame(minHeight: 28)
        .contentShape(Rectangle())
        .contextMenu {
            groupActions(for: groupName)
        }
        .background(
            dropTargetGroup == groupName || selectedItems.contains(.group(groupName))
                ? Color.accentColor.opacity(0.2) : Color.clear
        )
        .dropDestination(for: SidebarDragPayload.self) { payloads, _ in
            acceptDrop(payloads, into: .group(groupName))
        } isTargeted: { targeted in
            updateDropTarget(groupName, targeted: targeted)
        }

        if groupName == "Ungrouped" {
            content
        } else {
            let payload = dragPayload(for: .group(groupName))
            content.onDrag {
                payload.itemProvider
            } preview: {
                dragPreview(for: .group(groupName))
            }
        }
    }

    @ViewBuilder
    private func groupActions(for groupName: String) -> some View {
        Button("New Connection…") {
            onNewConnection(groupName)
        }
        if groupName != "Ungrouped" {
            Button("New Subgroup…") {
                beginNewGroup(under: groupName)
            }
            Divider()
            Button("Rename Group…") {
                beginRenameGroup(groupName)
            }
            Button(collapsedGroups.contains(groupName) ? "Expand Group" : "Collapse Group") {
                if collapsedGroups.contains(groupName) {
                    collapsedGroups.remove(groupName)
                } else {
                    collapsedGroups.insert(groupName)
                }
            }
            Button("Copy Group Path") {
                copyToClipboard(groupName)
            }
            Divider()
            Button("Remove Group…", role: .destructive) {
                groupPendingRemoval = groupName
            }
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
                Button("Rename…") {
                    beginRename(connection)
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

    @ViewBuilder
    private func row(_ connection: RemoteConnection) -> some View {
        let content = draggableRowLabel(connection)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture(count: 1)
                    .onEnded {
                        select(.connection(connection.id), modifiers: currentModifiers)
                    }
            )
            .simultaneousGesture(
                TapGesture(count: 2)
                    .onEnded {
                        select(.connection(connection.id), modifiers: [])
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
                    Button("Rename…") {
                        beginRename(connection)
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

        if connection.kind == .localShell {
            content.background(
                selectedItems.contains(.connection(connection.id))
                    ? Color.accentColor.opacity(0.2) : Color.clear
            )
        } else {
            content
                .background(dropTargetConnectionID == connection.id
                            || selectedItems.contains(.connection(connection.id))
                            ? Color.accentColor.opacity(0.2) : Color.clear)
                .dropDestination(for: SidebarDragPayload.self) { payloads, _ in
                    acceptDrop(payloads, into: connection.isFavorite
                               ? .favorites : .group(connection.group))
                } isTargeted: { targeted in
                    updateDropTarget(connection.id, targeted: targeted)
                }
        }
    }

    @ViewBuilder
    private func draggableRowLabel(_ connection: RemoteConnection) -> some View {
        if connection.kind == .localShell {
            ConnectionRowView(connection: connection)
        } else {
            let payload = dragPayload(for: .connection(connection.id))
            HStack(spacing: 4) {
                ConnectionRowView(connection: connection)
                    .onDrag {
                        payload.itemProvider
                    } preview: {
                        dragPreview(for: .connection(connection.id))
                    }
                Image(systemName: "line.3.horizontal")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
                    .help("Drag this connection or the selected connections")
                    .onDrag {
                        payload.itemProvider
                    } preview: {
                        dragPreview(for: .connection(connection.id))
                    }
            }
        }
    }

    private enum DropDestination {
        case group(String)
        case favorites
    }

    private func updateDropTarget(_ group: String, targeted: Bool) {
        if targeted { dropTargetGroup = group }
        else if dropTargetGroup == group { dropTargetGroup = nil }
    }

    private func updateDropTarget(_ connectionID: UUID, targeted: Bool) {
        if targeted { dropTargetConnectionID = connectionID }
        else if dropTargetConnectionID == connectionID { dropTargetConnectionID = nil }
    }

    private func dragPayload(for item: SidebarSelectionItem) -> SidebarDragPayload {
        let selection = selectedItems.contains(item) ? selectedItems : [item]
        return SidebarDragPayload(
            connectionIDs: appState.connections
                .filter { selection.contains(.connection($0.id)) && $0.kind != .localShell }
                .map(\.id),
            groupPaths: appState.groups.filter {
                selection.contains(.group($0)) && $0.caseInsensitiveCompare("Ungrouped") != .orderedSame
            }
        )
    }

    private func dragPreview(for item: SidebarSelectionItem) -> some View {
        let payload = dragPayload(for: item)
        let count = payload.connectionIDs.count + payload.groupPaths.count
        return Label("\(count) \(count == 1 ? "item" : "items")", systemImage: "folder")
            .font(.callout.weight(.medium))
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func acceptDrop(_ payloads: [SidebarDragPayload], into destination: DropDestination) -> Bool {
        guard let payload = payloads.first else { return false }
        do {
            switch destination {
            case .group(let group):
                try appState.moveSidebarItems(
                    withConnectionIDs: Set(payload.connectionIDs),
                    groupPaths: Set(payload.groupPaths),
                    toGroup: group
                )
                collapsedGroups.remove(group)
            case .favorites:
                guard payload.groupPaths.isEmpty else {
                    throw ConnectionMoveError.groupsCannotBeFavorites
                }
                try appState.addConnectionsToFavorites(withIDs: Set(payload.connectionIDs))
            }
            selectedItems.removeAll()
            selectionAnchor = nil
            appState.selectedConnectionID = nil
            return true
        } catch {
            actionError = error.localizedDescription
            return false
        }
    }

    private func duplicate(_ connection: RemoteConnection) {
        do {
            try appState.duplicate(connection)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func beginNewGroup(under parent: String?) {
        newGroupName = ""
        newGroupParent = parent
        isPresentingNewGroup = true
    }

    private func beginRename(_ connection: RemoteConnection) {
        renamedConnectionName = connection.name
        renameRequest = connection
    }

    private func beginRenameGroup(_ group: String) {
        renameGroupPath = group
        renamedGroupName = group.split(separator: "/").last.map(String.init) ?? group
    }

    private func commitGroupRename() {
        guard let previousPath = renameGroupPath else { return }
        do {
            let updatedPath = try appState.renameGroup(previousPath, to: renamedGroupName)
            selectedItems = Set(selectedItems.map { item in
                guard case .group(let path) = item else { return item }
                return .group(rebasedGroupPath(path, from: previousPath, to: updatedPath))
            })
            if case .group(let path) = selectionAnchor {
                selectionAnchor = .group(rebasedGroupPath(path, from: previousPath, to: updatedPath))
            }
            collapsedGroups = Set(collapsedGroups.map {
                rebasedGroupPath($0, from: previousPath, to: updatedPath)
            })
        } catch {
            actionError = error.localizedDescription
        }
        renameGroupPath = nil
    }

    private func commitGroupRemoval() {
        guard let path = groupPendingRemoval else { return }
        defer { groupPendingRemoval = nil }
        do {
            try appState.removeGroup(path)
            selectedItems = selectedItems.filter { item in
                guard case .group(let selectedPath) = item else { return true }
                return !groupPath(selectedPath, isWithin: path)
            }
            if case .group(let anchorPath) = selectionAnchor,
               groupPath(anchorPath, isWithin: path) {
                selectionAnchor = nil
            }
            collapsedGroups = Set(collapsedGroups.filter { !groupPath($0, isWithin: path) })
            if let dropTargetGroup, groupPath(dropTargetGroup, isWithin: path) {
                self.dropTargetGroup = nil
            }
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func groupPath(_ candidate: String, isWithin parent: String) -> Bool {
        candidate.caseInsensitiveCompare(parent) == .orderedSame
            || candidate.lowercased().hasPrefix(parent.lowercased() + "/")
    }

    private func rebasedGroupPath(_ path: String, from old: String, to new: String) -> String {
        if path.caseInsensitiveCompare(old) == .orderedSame { return new }
        if path.lowercased().hasPrefix(old.lowercased() + "/") {
            return new + path.dropFirst(old.count)
        }
        return path
    }

    private func commitRename() {
        guard let connection = renameRequest else { return }
        do {
            try appState.rename(connection, to: renamedConnectionName)
        } catch {
            actionError = error.localizedDescription
        }
        renameRequest = nil
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func sshCommand(for connection: RemoteConnection) -> String {
        let resolved = appState.resolvedConnection(for: connection)
        let destination = resolved.username.isEmpty
            ? connection.host
            : "\(resolved.username)@\(connection.host)"
        return connection.port == ConnectionKind.ssh.defaultPort
            ? "ssh \(destination)"
            : "ssh -p \(connection.port) \(destination)"
    }
}

enum SidebarSelectionItem: Hashable {
    case connection(UUID)
    case group(String)

    var isGroup: Bool {
        if case .group = self { return true }
        return false
    }
}

enum SidebarSelection {
    static func update(
        selected: Set<SidebarSelectionItem>,
        anchor: SidebarSelectionItem?,
        clicked: SidebarSelectionItem,
        visible: [SidebarSelectionItem],
        modifiers: NSEvent.ModifierFlags
    ) -> (selected: Set<SidebarSelectionItem>, anchor: SidebarSelectionItem?) {
        if modifiers.contains(.shift),
           let anchor,
           anchor.isGroup == clicked.isGroup,
           let first = visible.firstIndex(of: anchor),
           let last = visible.firstIndex(of: clicked) {
            let range = visible[min(first, last)...max(first, last)].filter {
                switch (anchor, $0) {
                case (.connection, .connection), (.group, .group): true
                default: false
                }
            }
            let selectedRange = Set(range)
            return (
                modifiers.contains(.command) ? selected.union(selectedRange) : selectedRange,
                anchor
            )
        }
        if modifiers.contains(.command) {
            var updated = selected
            if !updated.insert(clicked).inserted {
                updated.remove(clicked)
            }
            return (updated, clicked)
        }
        return ([clicked], clicked)
    }
}

struct SidebarDragPayload: Codable, Transferable, Equatable {
    let connectionIDs: [UUID]
    let groupPaths: [String]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .nethrivaSidebarItems)
    }

    var itemProvider: NSItemProvider {
        let provider = NSItemProvider()
        provider.register(self)
        return provider
    }
}

private extension UTType {
    static let nethrivaSidebarItems = UTType(
        exportedAs: "com.vitalii.nethriva.sidebar-items",
        conformingTo: .data
    )
}

enum ConnectionSearch {
    static func matches(_ connection: RemoteConnection, query: String) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return true }
        let searchable = [connection.name, connection.host, connection.group, String(connection.port)]
        return terms.allSatisfy { term in
            searchable.contains { $0.localizedStandardContains(term) }
        }
    }
}
