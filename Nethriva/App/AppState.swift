import AppKit
import Foundation
import UniformTypeIdentifiers

enum ConnectionImportConflictPolicy: String, CaseIterable, Identifiable {
    case keepExisting
    case replaceExisting

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .keepExisting: "Keep existing items"
        case .replaceExisting: "Replace matching items"
        }
    }

    var explanation: String {
        switch self {
        case .keepExisting:
            "Matching connections and credential profiles are kept, including their existing Keychain passwords."
        case .replaceExisting:
            "Matching connections and profiles are replaced. Imported passwords replace saved passwords only when the archive contains one."
        }
    }
}

struct ConnectionImportSummary {
    let added: Int
    let replaced: Int
    let skipped: Int
    let credentialsImported: Int
    let profilesAdded: Int
    let profilesReplaced: Int

    var message: String {
        var parts = ["Added \(added) connection\(added == 1 ? "" : "s")"]
        if replaced > 0 { parts.append("replaced \(replaced)") }
        if skipped > 0 { parts.append("skipped \(skipped)") }
        if profilesAdded > 0 { parts.append("added \(profilesAdded) credential profile\(profilesAdded == 1 ? "" : "s")") }
        if profilesReplaced > 0 { parts.append("replaced \(profilesReplaced) profile\(profilesReplaced == 1 ? "" : "s")") }
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

enum CredentialProfileError: LocalizedError {
    case unavailable
    case invalidFields
    case nameConflict
    case inUse(Int)

    var errorDescription: String? {
        switch self {
        case .unavailable: "The selected credential profile is no longer available."
        case .invalidFields: "Enter a profile name and username."
        case .nameConflict: "A credential profile with that name already exists."
        case .inUse(let count): "This profile is used by \(count) connection\(count == 1 ? "" : "s"). Unlink those connections before deleting it."
        }
    }
}

enum ConnectionMoveError: LocalizedError {
    case unknownGroup
    case noMovableConnections
    case groupCannotContainItself
    case groupNameConflict
    case groupsCannotBeFavorites

    var errorDescription: String? {
        switch self {
        case .unknownGroup: "The destination group is no longer available."
        case .noMovableConnections: "Select at least one saved connection to move."
        case .groupCannotContainItself: "A group cannot be moved into itself or one of its subgroups."
        case .groupNameConflict: "A group with that name already exists at the destination."
        case .groupsCannotBeFavorites: "Move groups into another group; only connections can be added to Favorites."
        }
    }
}

enum ConnectionGroupError: LocalizedError {
    case unavailable
    case protectedGroup
    case invalidName
    case nameConflict

    var errorDescription: String? {
        switch self {
        case .unavailable: "The group is no longer available."
        case .protectedGroup: "Ungrouped is a built-in destination and cannot be renamed."
        case .invalidName: "Enter a group name without slashes or control characters."
        case .nameConflict: "A group with that name already exists here."
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var connections: [RemoteConnection]
    @Published private(set) var groups: [String]
    @Published private(set) var credentialProfiles: [CredentialProfile]
    @Published private(set) var tabs: [SessionTab] = []
    @Published var selectedConnectionID: RemoteConnection.ID?
    @Published var selectedTabID: SessionTab.ID?
    @Published var persistenceNotice: String?
    @Published var connectionTransferRequest: ConnectionTransferRequest?
    @Published var connectionSearchFocusRequest = UUID()

    private let store: ConnectionPersisting
    private let groupStore: ConnectionGroupPersisting
    private let profileStore: CredentialProfilePersisting
    private let credentialVault: CredentialVault

    convenience init() {
        self.init(
            store: UserDefaultsConnectionStore(),
            groupStore: UserDefaultsConnectionGroupStore(),
            profileStore: UserDefaultsCredentialProfileStore(),
            credentialVault: KeychainService.shared
        )
    }

    init(
        store: ConnectionPersisting,
        groupStore: ConnectionGroupPersisting = UserDefaultsConnectionGroupStore(),
        profileStore: CredentialProfilePersisting = InMemoryCredentialProfileStore(),
        credentialVault: CredentialVault = KeychainService.shared
    ) {
        self.store = store
        self.groupStore = groupStore
        self.profileStore = profileStore
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
        do {
            credentialProfiles = try profileStore.load()
        } catch {
            credentialProfiles = []
            initialNotice = [initialNotice, error.localizedDescription].compactMap { $0 }.joined(separator: "\n")
        }
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
        let tab = SessionTab(connection: resolvedConnection(for: connection))
        tabs.append(tab)
        selectedTabID = tab.id
    }

    func openSFTP(_ connection: RemoteConnection) {
        guard connection.kind == .ssh else { return }
        let tab = SessionTab(connection: resolvedConnection(for: connection), tool: .sftp)
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
        try validateProfileReference(for: connection)
        connections.append(connection)
        addGroupIfNeeded(connection.group)
        do {
            try persist()
            if connection.credentialProfileID == nil, let password, !password.isEmpty {
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
        try validateProfileReference(for: connection)
        guard let index = connections.firstIndex(where: { $0.id == connection.id }) else { return }
        let previous = connections[index]
        connections[index] = connection
        addGroupIfNeeded(connection.group)
        do {
            try persist()
            if removeSavedPassword {
                try credentialVault.deletePassword(for: connection.id)
            } else if connection.credentialProfileID == nil, let password, !password.isEmpty {
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
        var added = false
        for group in Self.groupPathPrefixes(normalizedName) {
            guard !groups.contains(where: { $0.caseInsensitiveCompare(group) == .orderedSame }) else {
                continue
            }
            groups.append(group)
            added = true
        }
        guard added else { return false }
        groups.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        groupStore.save(groups)
        return true
    }

    @discardableResult
    func addSubgroup(_ name: String, under parent: String) -> Bool {
        let segment = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !segment.isEmpty,
              !segment.contains("/"),
              segment.rangeOfCharacter(from: .controlCharacters) == nil,
              groups.contains(where: { $0.caseInsensitiveCompare(parent) == .orderedSame }) else {
            return false
        }
        return addGroup("\(parent)/\(segment)")
    }

    func deleteGroup(_ name: String) {
        guard !connections.contains(where: {
            $0.kind != .localShell && Self.isGroup($0.group, within: name)
        }), !groups.contains(where: {
            $0.caseInsensitiveCompare(name) != .orderedSame && Self.isGroup($0, within: name)
        }) else { return }
        groups.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
        groupStore.save(groups)
    }

    @discardableResult
    func renameGroup(_ path: String, to name: String) throws -> String {
        guard let existing = groups.first(where: {
            $0.caseInsensitiveCompare(path) == .orderedSame
        }) else { throw ConnectionGroupError.unavailable }
        guard existing.caseInsensitiveCompare("Ungrouped") != .orderedSame else {
            throw ConnectionGroupError.protectedGroup
        }
        let segment = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !segment.isEmpty,
              !segment.contains("/"),
              segment.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ConnectionGroupError.invalidName
        }
        let parent = existing.split(separator: "/").dropLast().joined(separator: "/")
        let destination = parent.isEmpty ? segment : "\(parent)/\(segment)"
        guard !groups.contains(where: {
            $0.caseInsensitiveCompare(destination) == .orderedSame
                && $0.caseInsensitiveCompare(existing) != .orderedSame
        }) else { throw ConnectionGroupError.nameConflict }
        guard destination != existing else { return existing }

        let previousConnections = connections
        let previousGroups = groups
        let rename = [(old: existing, new: destination)]
        for index in connections.indices {
            if let updated = Self.replacingGroupPrefix(connections[index].group, using: rename) {
                connections[index].group = updated
            }
        }
        groups = Self.normalizedGroups(groups.map { group in
            Self.replacingGroupPrefix(group, using: rename) ?? group
        })
        do {
            try persist()
            groupStore.save(groups)
        } catch {
            connections = previousConnections
            groups = previousGroups
            groupStore.save(previousGroups)
            throw error
        }
        return destination
    }

    func rename(_ connection: RemoteConnection, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, connection.kind != .localShell else { return }
        var updated = connection
        updated.name = trimmed
        try update(updated, password: nil)
        tabs = tabs.map { tab in
            guard tab.connection.id == updated.id else { return tab }
            var tabConnection = tab.connection
            tabConnection.name = trimmed
            return SessionTab(
                id: tab.id,
                connection: tabConnection,
                tool: tab.tool,
                openedAt: tab.openedAt
            )
        }
    }

    func focusConnectionSearch() {
        connectionSearchFocusRequest = UUID()
    }

    func resolvedConnection(for connection: RemoteConnection) -> RemoteConnection {
        guard let profileID = connection.credentialProfileID,
              let profile = credentialProfiles.first(where: { $0.id == profileID }) else {
            return connection
        }
        var resolved = connection
        resolved.username = profile.username
        if resolved.kind == .rdp {
            resolved.rdpDomain = profile.domain.isEmpty ? nil : profile.domain
        }
        return resolved
    }

    func profileUsageCount(_ profileID: UUID) -> Int {
        connections.filter { $0.credentialProfileID == profileID }.count
    }

    func hasSavedPassword(for profile: CredentialProfile) throws -> Bool {
        try credentialVault.containsPassword(for: profile.id)
    }

    func saveProfile(
        _ profile: CredentialProfile,
        password: String?,
        removeSavedPassword: Bool = false
    ) throws {
        let normalized = CredentialProfile(
            id: profile.id,
            name: profile.name.trimmingCharacters(in: .whitespacesAndNewlines),
            username: profile.username.trimmingCharacters(in: .whitespacesAndNewlines),
            domain: profile.domain.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !normalized.name.isEmpty, !normalized.username.isEmpty else {
            throw CredentialProfileError.invalidFields
        }
        guard !credentialProfiles.contains(where: {
            $0.id != normalized.id && $0.name.caseInsensitiveCompare(normalized.name) == .orderedSame
        }) else { throw CredentialProfileError.nameConflict }

        let previous = credentialProfiles
        if let index = credentialProfiles.firstIndex(where: { $0.id == normalized.id }) {
            credentialProfiles[index] = normalized
        } else {
            credentialProfiles.append(normalized)
        }
        credentialProfiles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        do {
            try profileStore.save(credentialProfiles)
            if removeSavedPassword {
                try credentialVault.deletePassword(for: normalized.id)
            } else if let password, !password.isEmpty {
                try credentialVault.save(password: password, for: normalized.id)
            }
        } catch {
            credentialProfiles = previous
            try? profileStore.save(previous)
            throw error
        }
    }

    func deleteProfile(_ profile: CredentialProfile) throws {
        let usage = profileUsageCount(profile.id)
        guard usage == 0 else { throw CredentialProfileError.inUse(usage) }
        let previous = credentialProfiles
        credentialProfiles.removeAll { $0.id == profile.id }
        do {
            try profileStore.save(credentialProfiles)
            try credentialVault.deletePassword(for: profile.id)
        } catch {
            credentialProfiles = previous
            try? profileStore.save(previous)
            throw error
        }
    }

    private func validateProfileReference(for connection: RemoteConnection) throws {
        guard let profileID = connection.credentialProfileID else { return }
        guard connection.kind != .localShell, connection.kind != .serial,
              credentialProfiles.contains(where: { $0.id == profileID }) else {
            throw CredentialProfileError.unavailable
        }
    }

    func duplicate(_ connection: RemoteConnection) throws {
        guard connection.kind != .localShell else { return }
        let copy = RemoteConnection(
            name: "\(connection.name) Copy",
            kind: connection.kind,
            host: connection.host,
            port: connection.port,
            username: connection.username,
            credentialProfileID: connection.credentialProfileID,
            group: connection.group,
            isFavorite: false,
            sshAuthentication: connection.sshAuthentication,
            sshIdentityFile: connection.sshIdentityFile,
            sshJumpHost: connection.sshJumpHost,
            sshForwardAgent: connection.sshForwardAgent,
            sshCompression: connection.sshCompression,
            sshKeepAliveInterval: connection.sshKeepAliveInterval,
            serialBaudRate: connection.serialBaudRate,
            serialDataBits: connection.serialDataBits,
            serialParity: connection.serialParity,
            serialStopBits: connection.serialStopBits,
            serialFlowControl: connection.serialFlowControl,
            serialLocalEcho: connection.serialLocalEcho,
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
        try add(copy, password: (connection.kind == .serial || connection.credentialProfileID != nil)
            ? nil : try credentialVault.password(for: connection.id))
    }

    func move(_ connection: RemoteConnection, toGroup group: String) {
        do {
            try moveConnections(withIDs: [connection.id], toGroup: group)
        } catch {
            report(error)
        }
    }

    func moveConnections(withIDs ids: Set<UUID>, toGroup group: String) throws {
        try moveSidebarItems(withConnectionIDs: ids, groupPaths: [], toGroup: group)
    }

    func moveSidebarItems(
        withConnectionIDs connectionIDs: Set<UUID>,
        groupPaths: Set<String>,
        toGroup group: String
    ) throws {
        let destination = Self.normalizedGroupName(group)
        guard destination == "Ungrouped" || groups.contains(where: {
            $0.caseInsensitiveCompare(destination) == .orderedSame
        }) else {
            throw ConnectionMoveError.unknownGroup
        }

        let canonicalGroups = groupPaths.compactMap { selected in
            groups.first { $0.caseInsensitiveCompare(selected) == .orderedSame }
        }.filter { $0.caseInsensitiveCompare("Ungrouped") != .orderedSame }
        guard canonicalGroups.count == groupPaths.filter({
            $0.caseInsensitiveCompare("Ungrouped") != .orderedSame
        }).count else {
            throw ConnectionMoveError.unknownGroup
        }
        let movingGroups = canonicalGroups.filter { candidate in
            !canonicalGroups.contains { other in
                other.caseInsensitiveCompare(candidate) != .orderedSame
                    && Self.isGroup(candidate, within: other)
            }
        }
        guard !movingGroups.contains(where: { Self.isGroup(destination, within: $0) }) else {
            throw ConnectionMoveError.groupCannotContainItself
        }

        let renames: [(old: String, new: String)] = movingGroups.map { old in
            let leaf = old.split(separator: "/").last.map(String.init) ?? old
            let new = destination == "Ungrouped" ? leaf : "\(destination)/\(leaf)"
            return (old, new)
        }
        let newRoots = renames.map { $0.new.lowercased() }
        guard Set(newRoots).count == newRoots.count,
              !renames.contains(where: { rename in
                  rename.old.caseInsensitiveCompare(rename.new) != .orderedSame
                      && groups.contains(where: { existingGroup in
                          existingGroup.caseInsensitiveCompare(rename.new) == .orderedSame
                              && !movingGroups.contains(where: { root in
                                  Self.isGroup(existingGroup, within: root)
                              })
                      })
              }) else {
            throw ConnectionMoveError.groupNameConflict
        }

        let movableIDs = Set(connections.filter {
            connectionIDs.contains($0.id) && $0.kind != .localShell
        }.map(\.id))
        guard !movableIDs.isEmpty || !renames.isEmpty else {
            throw ConnectionMoveError.noMovableConnections
        }

        let previousConnections = connections
        let previousGroups = groups
        for index in connections.indices {
            if let renamedGroup = Self.replacingGroupPrefix(connections[index].group, using: renames) {
                connections[index].group = renamedGroup
            } else if movableIDs.contains(connections[index].id) {
                connections[index].group = destination
                connections[index].isFavorite = false
            }
        }
        groups = Self.normalizedGroups(groups.map { group in
            Self.replacingGroupPrefix(group, using: renames) ?? group
        } + (movableIDs.isEmpty ? [] : [destination]))
        do {
            try persist()
            groupStore.save(groups)
        } catch {
            connections = previousConnections
            groups = previousGroups
            groupStore.save(previousGroups)
            throw error
        }
    }

    func addConnectionsToFavorites(withIDs ids: Set<UUID>) throws {
        let movableIDs = Set(connections.filter {
            ids.contains($0.id) && $0.kind != .localShell
        }.map(\.id))
        guard !movableIDs.isEmpty else { throw ConnectionMoveError.noMovableConnections }

        let previousConnections = connections
        for index in connections.indices where movableIDs.contains(connections[index].id) {
            connections[index].isFavorite = true
        }
        do {
            try persist()
        } catch {
            connections = previousConnections
            throw error
        }
    }

    func password(for connection: RemoteConnection) throws -> String? {
        if let profileID = connection.credentialProfileID {
            guard credentialProfiles.contains(where: { $0.id == profileID }) else {
                throw CredentialProfileError.unavailable
            }
            return try credentialVault.password(for: profileID)
        }
        return try credentialVault.password(for: connection.id)
    }

    func hasSavedPassword(for connection: RemoteConnection) throws -> Bool {
        try credentialVault.containsPassword(for: connection.credentialProfileID ?? connection.id)
    }

    func savePassword(_ password: String, for connection: RemoteConnection) throws {
        try credentialVault.save(password: password, for: connection.credentialProfileID ?? connection.id)
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
        // An interactive RDP login is specific to this connection; never change
        // a shared profile (and therefore other devices) implicitly.
        connection.credentialProfileID = nil
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
        let profileCredentials: [CredentialProfileSecret]
        if includeCredentials {
            credentials = try exportedConnections.compactMap { connection in
                guard connection.kind != .serial, connection.credentialProfileID == nil else { return nil }
                guard let password = try credentialVault.password(for: connection.id) else { return nil }
                return ConnectionArchiveCredential(connectionID: connection.id, password: password)
            }
            profileCredentials = try credentialProfiles.compactMap { profile in
                guard let password = try credentialVault.password(for: profile.id) else { return nil }
                return CredentialProfileSecret(profileID: profile.id, password: password)
            }
        } else {
            credentials = []
            profileCredentials = []
        }
        return ConnectionArchive(
            groups: Self.normalizedGroups(groups + exportedConnections.map(\.group)),
            connections: exportedConnections,
            credentials: credentials,
            profiles: credentialProfiles,
            profileCredentials: profileCredentials
        )
    }

    func importConnectionArchive(
        _ archive: ConnectionArchive,
        conflictPolicy: ConnectionImportConflictPolicy
    ) throws -> ConnectionImportSummary {
        let previousConnections = connections
        let previousGroups = groups
        let previousProfiles = credentialProfiles
        let previousSelectedConnectionID = selectedConnectionID
        var mergedConnections = connections
        var mergedProfiles = credentialProfiles
        var appliedConnectionIDs = Set<UUID>()
        var appliedProfileIDs = Set<UUID>()
        var added = 0
        var replaced = 0
        var skipped = 0
        var profilesAdded = 0
        var profilesReplaced = 0

        for imported in archive.profiles {
            if let index = mergedProfiles.firstIndex(where: { $0.id == imported.id }) {
                if conflictPolicy == .replaceExisting {
                    mergedProfiles[index] = imported
                    appliedProfileIDs.insert(imported.id)
                    profilesReplaced += 1
                }
            } else {
                mergedProfiles.append(imported)
                appliedProfileIDs.insert(imported.id)
                profilesAdded += 1
            }
        }

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
        let profileCredentialsToImport = archive.profileCredentials.filter {
            appliedProfileIDs.contains($0.profileID)
        }
        let credentialIDs = credentialsToImport.map(\.connectionID)
            + profileCredentialsToImport.map(\.profileID)
        let previousCredentials = try Dictionary(uniqueKeysWithValues: credentialIDs.map {
            ($0, try credentialVault.password(for: $0))
        })

        connections = mergedConnections
        credentialProfiles = mergedProfiles.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
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
            try profileStore.save(credentialProfiles)
            for credential in credentialsToImport {
                try credentialVault.save(
                    password: credential.password,
                    for: credential.connectionID
                )
            }
            for credential in profileCredentialsToImport {
                try credentialVault.save(password: credential.password, for: credential.profileID)
            }
        } catch {
            connections = previousConnections
            groups = previousGroups
            credentialProfiles = previousProfiles
            selectedConnectionID = previousSelectedConnectionID
            try? persist()
            groupStore.save(previousGroups)
            try? profileStore.save(previousProfiles)
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
            credentialsImported: credentialsToImport.count + profileCredentialsToImport.count,
            profilesAdded: profilesAdded,
            profilesReplaced: profilesReplaced
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
            for group in groupPathPrefixes(normalizedGroupName(name)) {
                guard !result.contains(where: {
                    $0.caseInsensitiveCompare(group) == .orderedSame
                }) else { continue }
                result.append(group)
            }
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private static func groupPathPrefixes(_ path: String) -> [String] {
        let parts = path.split(separator: "/").map(String.init)
        return parts.indices.map { parts[0...$0].joined(separator: "/") }
    }

    private static func isGroup(_ candidate: String, within parent: String) -> Bool {
        candidate.caseInsensitiveCompare(parent) == .orderedSame
            || candidate.lowercased().hasPrefix(parent.lowercased() + "/")
    }

    private static func replacingGroupPrefix(
        _ path: String,
        using renames: [(old: String, new: String)]
    ) -> String? {
        guard let rename = renames.first(where: { isGroup(path, within: $0.old) }) else { return nil }
        return rename.new + path.dropFirst(rename.old.count)
    }

    private static func normalizedGroupName(_ name: String) -> String {
        let segments = name.split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return segments.isEmpty ? "Ungrouped" : segments.joined(separator: "/")
    }
}
