import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var connections: [RemoteConnection]
    @Published private(set) var groups: [String]
    @Published private(set) var tabs: [SessionTab] = []
    @Published var selectedConnectionID: RemoteConnection.ID?
    @Published var selectedTabID: SessionTab.ID?

    private let store: ConnectionPersisting
    private let groupStore: ConnectionGroupPersisting
    private let credentialVault: CredentialVault

    init(
        store: ConnectionPersisting = UserDefaultsConnectionStore(),
        groupStore: ConnectionGroupPersisting = UserDefaultsConnectionGroupStore(),
        credentialVault: CredentialVault = KeychainService.shared
    ) {
        self.store = store
        self.groupStore = groupStore
        self.credentialVault = credentialVault
        let loadedConnections = store.load()
        self.connections = loadedConnections
        self.groups = Self.normalizedGroups(
            groupStore.load() + loadedConnections
                .filter { $0.kind != .localShell }
                .map(\.group)
        )
        self.selectedConnectionID = self.connections.first?.id
        self.groupStore.save(self.groups)
    }

    func open(_ connection: RemoteConnection) {
        let tab = SessionTab(connection: connection)
        tabs.append(tab)
        selectedTabID = tab.id
    }

    func openSFTP(_ connection: RemoteConnection) {
        guard connection.kind == .ssh else { return }
        let tab = SessionTab(connection: connection, tool: .sftp)
        tabs.append(tab)
        selectedTabID = tab.id
    }

    func openSelectedConnection() {
        guard let connection = selectedConnection else { return }
        open(connection)
    }

    func close(tabID: SessionTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let wasSelected = selectedTabID == tabID
        tabs.remove(at: index)

        if wasSelected {
            if tabs.indices.contains(index) {
                selectedTabID = tabs[index].id
            } else {
                selectedTabID = tabs.last?.id
            }
        }
    }

    func add(_ connection: RemoteConnection, password: String?) throws {
        if let password, !password.isEmpty {
            try credentialVault.save(password: password, for: connection.id)
        }
        connections.append(connection)
        addGroupIfNeeded(connection.group)
        persist()
        selectedConnectionID = connection.id
    }

    func update(_ connection: RemoteConnection, password: String?) throws {
        guard let index = connections.firstIndex(where: { $0.id == connection.id }) else { return }
        if let password, !password.isEmpty {
            try credentialVault.save(password: password, for: connection.id)
        }
        connections[index] = connection
        addGroupIfNeeded(connection.group)
        persist()
        selectedConnectionID = connection.id
    }

    @discardableResult
    func addGroup(_ name: String) -> Bool {
        let normalizedName = Self.normalizedGroupName(name)
        guard !groups.contains(where: { $0.caseInsensitiveCompare(normalizedName) == .orderedSame }) else {
            return false
        }
        groups.append(normalizedName)
        groups.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        groupStore.save(groups)
        return true
    }

    func deleteGroup(_ name: String) {
        guard !connections.contains(where: {
            $0.kind != .localShell && $0.group.caseInsensitiveCompare(name) == .orderedSame
        }) else { return }
        groups.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
        groupStore.save(groups)
    }

    func duplicate(_ connection: RemoteConnection) throws {
        guard connection.kind != .localShell else { return }
        let copy = RemoteConnection(
            name: "\(connection.name) Copy",
            kind: connection.kind,
            host: connection.host,
            port: connection.port,
            username: connection.username,
            group: connection.group,
            isFavorite: false,
            sshAuthentication: connection.sshAuthentication,
            sshIdentityFile: connection.sshIdentityFile,
            sshJumpHost: connection.sshJumpHost,
            sshForwardAgent: connection.sshForwardAgent,
            sshCompression: connection.sshCompression,
            sshKeepAliveInterval: connection.sshKeepAliveInterval,
            rdpDomain: connection.rdpDomain,
            rdpGatewayHost: connection.rdpGatewayHost,
            rdpGatewayUsername: connection.rdpGatewayUsername,
            rdpDisplayMode: connection.rdpDisplayMode,
            rdpWidth: connection.rdpWidth,
            rdpHeight: connection.rdpHeight,
            rdpScale: connection.rdpScale,
            rdpClipboard: connection.rdpClipboard,
            rdpAudioMode: connection.rdpAudioMode,
            rdpMicrophone: connection.rdpMicrophone,
            rdpRedirectHome: connection.rdpRedirectHome,
            rdpSharedFolder: connection.rdpSharedFolder,
            rdpPrinters: connection.rdpPrinters,
            rdpSmartCards: connection.rdpSmartCards,
            rdpUSBDevices: connection.rdpUSBDevices,
            rdpNetworkProfile: connection.rdpNetworkProfile,
            rdpGraphicsAcceleration: connection.rdpGraphicsAcceleration,
            rdpCertificatePolicy: connection.rdpCertificatePolicy,
            rdpAdminSession: connection.rdpAdminSession,
            rdpAutoReconnect: connection.rdpAutoReconnect,
            rdpReconnectRetries: connection.rdpReconnectRetries
        )
        try add(copy, password: try credentialVault.password(for: connection.id))
    }

    func move(_ connection: RemoteConnection, toGroup group: String) {
        guard connection.kind != .localShell,
              let index = connections.firstIndex(where: { $0.id == connection.id }) else { return }
        connections[index].group = Self.normalizedGroupName(group)
        addGroupIfNeeded(group)
        persist()
    }

    func password(for connection: RemoteConnection) throws -> String? {
        try credentialVault.password(for: connection.id)
    }

    func savePassword(_ password: String, for connection: RemoteConnection) throws {
        try credentialVault.save(password: password, for: connection.id)
    }

    func toggleFavorite(_ connection: RemoteConnection) {
        guard let index = connections.firstIndex(where: { $0.id == connection.id }) else { return }
        connections[index].isFavorite.toggle()
        persist()
    }

    func delete(_ connection: RemoteConnection) {
        guard connection.kind != .localShell else { return }
        connections.removeAll { $0.id == connection.id }
        tabs.removeAll { $0.connection.id == connection.id }
        if selectedConnectionID == connection.id {
            selectedConnectionID = connections.first?.id
        }
        if let selectedTabID, !tabs.contains(where: { $0.id == selectedTabID }) {
            self.selectedTabID = tabs.last?.id
        }
        try? credentialVault.deletePassword(for: connection.id)
        persist()
    }

    var selectedConnection: RemoteConnection? {
        guard let selectedConnectionID else { return nil }
        return connections.first { $0.id == selectedConnectionID }
    }

    var selectedTab: SessionTab? {
        guard let selectedTabID else { return nil }
        return tabs.first { $0.id == selectedTabID }
    }

    private func persist() {
        store.save(connections)
    }

    private func addGroupIfNeeded(_ name: String) {
        _ = addGroup(name)
    }

    private static func normalizedGroups<S: Sequence>(_ names: S) -> [String] where S.Element == String {
        var result: [String] = []
        for name in names {
            let normalizedName = normalizedGroupName(name)
            guard !result.contains(where: {
                $0.caseInsensitiveCompare(normalizedName) == .orderedSame
            }) else { continue }
            result.append(normalizedName)
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private static func normalizedGroupName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Ungrouped" : trimmed
    }
}
