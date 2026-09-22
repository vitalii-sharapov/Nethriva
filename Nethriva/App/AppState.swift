import AppKit
import Foundation
import UniformTypeIdentifiers

enum ConnectionImportConflictPolicy: String, CaseIterable, Identifiable {
    case keepExisting
    case replaceExisting

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .keepExisting: "Keep existing connections"
        case .replaceExisting: "Replace existing connections"
        }
    }

    var explanation: String {
        switch self {
        case .keepExisting:
            "Connections already present in this library are skipped, including their imported credentials."
        case .replaceExisting:
            "Matching connection settings are replaced. Imported credentials replace saved credentials only when the archive contains one."
        }
    }
}

struct ConnectionImportSummary {
    let added: Int
    let replaced: Int
    let skipped: Int
    let credentialsImported: Int

    var message: String {
        var parts = ["Added \(added) connection\(added == 1 ? "" : "s")"]
        if replaced > 0 { parts.append("replaced \(replaced)") }
        if skipped > 0 { parts.append("skipped \(skipped)") }
        if credentialsImported > 0 {
            parts.append("saved \(credentialsImported) credential\(credentialsImported == 1 ? "" : "s") in Keychain")
        }
        return parts.joined(separator: ", ") + "."
    }
}

enum RDPLoginStorageError: LocalizedError {
    case connectionUnavailable

    var errorDescription: String? {
        "The saved RDP connection is no longer available. Its credentials were not stored."
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var connections: [RemoteConnection]
    @Published private(set) var groups: [String]
    @Published private(set) var tabs: [SessionTab] = []
    @Published var selectedConnectionID: RemoteConnection.ID?
    @Published var selectedTabID: SessionTab.ID?
    @Published var persistenceNotice: String?
    @Published var connectionTransferRequest: ConnectionTransferRequest?

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
        let loadResult: ConnectionLoadResult
        var initialNotice: String?
        do {
            loadResult = try store.load()
        } catch {
            loadResult = ConnectionLoadResult(connections: [.localShell], recoveryNotice: nil)
            initialNotice = error.localizedDescription
        }
        let loadedConnections = loadResult.connections
        self.connections = loadedConnections
        self.groups = Self.normalizedGroups(
            groupStore.load() + loadedConnections
                .filter { $0.kind != .localShell }
                .map(\.group)
        )
        self.selectedConnectionID = self.connections.first?.id
        self.groupStore.save(self.groups)
        self.persistenceNotice = initialNotice ?? loadResult.recoveryNotice
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
        let closedConnection = tabs[index].connection
        let wasSelected = selectedTabID == tabID
        tabs.remove(at: index)

        if wasSelected {
            if tabs.indices.contains(index) {
                selectedTabID = tabs[index].id
            } else {
                selectedTabID = tabs.last?.id
            }
        }

        closeSSHTransportIfUnused(for: closedConnection)
    }

    func add(_ connection: RemoteConnection, password: String?) throws {
        connections.append(connection)
        addGroupIfNeeded(connection.group)
        do {
            try persist()
            if let password, !password.isEmpty {
                try credentialVault.save(password: password, for: connection.id)
            }
        } catch {
            connections.removeAll { $0.id == connection.id }
            try? persist()
            try? credentialVault.deletePassword(for: connection.id)
            throw error
        }
        selectedConnectionID = connection.id
    }

    func update(
        _ connection: RemoteConnection,
        password: String?,
        removeSavedPassword: Bool = false
    ) throws {
        guard let index = connections.firstIndex(where: { $0.id == connection.id }) else { return }
        let previous = connections[index]
        connections[index] = connection
        addGroupIfNeeded(connection.group)
        do {
            try persist()
            if removeSavedPassword {
                try credentialVault.deletePassword(for: connection.id)
            } else if let password, !password.isEmpty {
                try credentialVault.save(password: password, for: connection.id)
            }
        } catch {
            connections[index] = previous
            try? persist()
            throw error
        }
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
        let previous = connections[index]
        connections[index].group = Self.normalizedGroupName(group)
        addGroupIfNeeded(group)
        do {
            try persist()
        } catch {
            connections[index] = previous
            report(error)
        }
    }

    func password(for connection: RemoteConnection) throws -> String? {
        try credentialVault.password(for: connection.id)
    }

    func savePassword(_ password: String, for connection: RemoteConnection) throws {
        try credentialVault.save(password: password, for: connection.id)
    }

    @discardableResult
    func saveRDPLogin(
        _ credentials: RDPCredentialCandidate,
        for connectionID: RemoteConnection.ID
    ) throws -> RemoteConnection {
        guard var connection = connections.first(where: {
            $0.id == connectionID && $0.kind == .rdp
        }) else {
            throw RDPLoginStorageError.connectionUnavailable
        }
        connection.username = credentials.username
        connection.rdpDomain = credentials.domain?.isEmpty == false ? credentials.domain : nil
        try update(connection, password: credentials.password)
        return connection
    }

    func removePassword(for connection: RemoteConnection) throws {
        try credentialVault.deletePassword(for: connection.id)
    }

    func toggleFavorite(_ connection: RemoteConnection) {
        guard let index = connections.firstIndex(where: { $0.id == connection.id }) else { return }
        connections[index].isFavorite.toggle()
        do {
            try persist()
        } catch {
            connections[index].isFavorite.toggle()
            report(error)
        }
    }

    func delete(_ connection: RemoteConnection) {
        guard connection.kind != .localShell else { return }
        let previousConnections = connections
        let previousTabs = tabs
        let previousSelectedConnectionID = selectedConnectionID
        let previousSelectedTabID = selectedTabID
        connections.removeAll { $0.id == connection.id }
        tabs.removeAll { $0.connection.id == connection.id }
        if selectedConnectionID == connection.id {
            selectedConnectionID = connections.first?.id
        }
        if let selectedTabID, !tabs.contains(where: { $0.id == selectedTabID }) {
            self.selectedTabID = tabs.last?.id
        }
        do {
            try persist()
        } catch {
            connections = previousConnections
            tabs = previousTabs
            selectedConnectionID = previousSelectedConnectionID
            selectedTabID = previousSelectedTabID
            report(error)
            return
        }
        do {
            try credentialVault.deletePassword(for: connection.id)
        } catch {
            report(error)
        }
        closeSSHTransportIfUnused(for: connection)
    }

    var selectedConnection: RemoteConnection? {
        guard let selectedConnectionID else { return nil }
        return connections.first { $0.id == selectedConnectionID }
    }

    var selectedTab: SessionTab? {
        guard let selectedTabID else { return nil }
        return tabs.first { $0.id == selectedTabID }
    }

    func shutdownSSHTransports() {
        SSHConnectionReuse.shutdownAll(connections: tabs.map(\.connection))
    }

    func exportDiagnostics() {
        do {
            try DiagnosticReportService.export(connections: connections)
        } catch {
            report(error)
        }
    }

    func requestConnectionExport() {
        connectionTransferRequest = ConnectionTransferRequest(operation: .export)
    }

    func chooseConnectionArchiveToImport() {
        let panel = NSOpenPanel()
        panel.title = "Import Nethriva Connections"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: ConnectionTransferService.plainFilenameExtension) ?? .data,
            UTType(filenameExtension: ConnectionTransferService.encryptedFilenameExtension) ?? .data,
            .json,
        ]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self?.connectionTransferRequest = ConnectionTransferRequest(operation: .importFile(url))
            }
        }
    }

    func makeConnectionArchive(includeCredentials: Bool) throws -> ConnectionArchive {
        let exportedConnections = connections.filter { $0.kind != .localShell }
        let credentials: [ConnectionArchiveCredential]
        if includeCredentials {
            credentials = try exportedConnections.compactMap { connection in
                guard let password = try credentialVault.password(for: connection.id) else { return nil }
                return ConnectionArchiveCredential(connectionID: connection.id, password: password)
            }
        } else {
            credentials = []
        }
        return ConnectionArchive(
            groups: Self.normalizedGroups(groups + exportedConnections.map(\.group)),
            connections: exportedConnections,
            credentials: credentials
        )
    }

    func importConnectionArchive(
        _ archive: ConnectionArchive,
        conflictPolicy: ConnectionImportConflictPolicy
    ) throws -> ConnectionImportSummary {
        let previousConnections = connections
        let previousGroups = groups
        let previousSelectedConnectionID = selectedConnectionID
        var mergedConnections = connections
        var appliedConnectionIDs = Set<UUID>()
        var added = 0
        var replaced = 0
        var skipped = 0

        for imported in archive.connections where imported.kind != .localShell {
            if let index = mergedConnections.firstIndex(where: { $0.id == imported.id }) {
                switch conflictPolicy {
                case .keepExisting:
                    skipped += 1
                case .replaceExisting:
                    mergedConnections[index] = imported
                    appliedConnectionIDs.insert(imported.id)
                    replaced += 1
                }
            } else {
                mergedConnections.append(imported)
                appliedConnectionIDs.insert(imported.id)
                added += 1
            }
        }

        let credentialsToImport = archive.credentials.filter {
            appliedConnectionIDs.contains($0.connectionID)
        }
        let previousCredentials = try Dictionary(uniqueKeysWithValues: credentialsToImport.map {
            ($0.connectionID, try credentialVault.password(for: $0.connectionID))
        })

        connections = mergedConnections
        groups = Self.normalizedGroups(
            previousGroups + archive.groups + mergedConnections
                .filter { $0.kind != .localShell }
                .map(\.group)
        )
        if let selectedConnectionID,
           !connections.contains(where: { $0.id == selectedConnectionID }) {
            self.selectedConnectionID = connections.first?.id
        }

        do {
            try persist()
            groupStore.save(groups)
            for credential in credentialsToImport {
                try credentialVault.save(
                    password: credential.password,
                    for: credential.connectionID
                )
            }
        } catch {
            connections = previousConnections
            groups = previousGroups
            selectedConnectionID = previousSelectedConnectionID
            try? persist()
            groupStore.save(previousGroups)
            for (connectionID, password) in previousCredentials {
                if let password {
                    try? credentialVault.save(password: password, for: connectionID)
                } else {
                    try? credentialVault.deletePassword(for: connectionID)
                }
            }
            throw error
        }

        if selectedConnectionID == nil {
            selectedConnectionID = connections.first?.id
        }
        return ConnectionImportSummary(
            added: added,
            replaced: replaced,
            skipped: skipped,
            credentialsImported: credentialsToImport.count
        )
    }

    private func persist() throws {
        try store.save(connections)
    }

    private func addGroupIfNeeded(_ name: String) {
        _ = addGroup(name)
    }

    private func closeSSHTransportIfUnused(for connection: RemoteConnection) {
        guard connection.kind == .ssh else { return }
        let key = SSHConnectionReuse.controlKey(for: connection)
        guard !tabs.contains(where: {
            $0.connection.kind == .ssh && SSHConnectionReuse.controlKey(for: $0.connection) == key
        }) else { return }
        SSHConnectionReuse.shutdown(connection: connection)
    }

    private func report(_ error: Error) {
        persistenceNotice = error.localizedDescription
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
