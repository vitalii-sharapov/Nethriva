import AppKit
import Combine
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
            "Matching metadata may be replaced. Changed destinations or login identities become separate items so existing saved credentials stay with their original target."
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
    var isolatedConnections = 0
    var isolatedProfiles = 0
    var restrictedConnections = 0
    var detachedProfiles = 0

    var message: String {
        var parts = ["Added \(added) connection\(added == 1 ? "" : "s")"]
        if replaced > 0 { parts.append("replaced \(replaced)") }
        if skipped > 0 { parts.append("skipped \(skipped)") }
        if profilesAdded > 0 { parts.append("added \(profilesAdded) credential profile\(profilesAdded == 1 ? "" : "s")") }
        if profilesReplaced > 0 { parts.append("replaced \(profilesReplaced) profile\(profilesReplaced == 1 ? "" : "s")") }
        if credentialsImported > 0 {
            parts.append("saved \(credentialsImported) credential\(credentialsImported == 1 ? "" : "s") in Keychain")
        }
        if isolatedConnections + isolatedProfiles > 0 { parts.append("kept \(isolatedConnections + isolatedProfiles) changed identities separate from existing credentials") }
        if restrictedConnections > 0 { parts.append("restricted access settings on \(restrictedConnections) imported connection(s)") }
        if detachedProfiles > 0 { parts.append("left existing credential profiles unassigned on \(detachedProfiles) new target(s)") }
        return parts.joined(separator: ", ") + "."
    }
}

enum CredentialBindingError: LocalizedError {
    case changed
    var errorDescription: String? {
        "This connection's login identity changed. Reopen the session and review its target before using saved credentials."
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
        case .inUse(let count): "This profile has \(count) saved reference\(count == 1 ? "" : "s") in connections, templates or group defaults. Unlink them before deleting it."
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
        case .protectedGroup: "Ungrouped is a built-in destination and cannot be renamed or removed."
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
    @Published var selectedTabID: SessionTab.ID? { didSet { layout.select(selectedTabID) } }
    @Published var layout = SessionLayout()
    var extraSSHConnections: (() -> [RemoteConnection])?
    @Published var vmInventory: [UUID: [VirtualMachine]] = [:]
    @Published var persistenceNotice: String?
    @Published var connectionTransferRequest: ConnectionTransferRequest?
    @Published var connectionSearchFocusRequest = UUID()
    let libraryTools: LibraryTools
    let sharedLibraries: SharedLibraries
    let externalCredentials: ExternalCredentials
    let credentialGate: CredentialAccessGate
    @Published var bulkEditIDs = Set<UUID>()
    @Published var toolsGroupRequest: String?
    var editableGroupPaths: [String] {
        Array(Set(groups.filter { $0.caseInsensitiveCompare("Ungrouped") != .orderedSame } + ["Ungrouped"])).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private let store: ConnectionPersisting
    private let groupStore: ConnectionGroupPersisting
    private let profileStore: CredentialProfilePersisting
    private let credentialVault: CredentialVault
    private var toolsObservation: AnyCancellable?
    private var providerObservation: AnyCancellable?
    private var privacyTransports: [RemoteConnection] = []
    // Session-only host logins never enter connection JSON, archives, or diagnostic exports.
    private var temporaryVMLogins: [UUID: (connection: RemoteConnection, username: String, password: String)] = [:]

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
        credentialVault: CredentialVault = KeychainService.shared,
        libraryTools: LibraryTools? = nil,
        sharedLibraries: SharedLibraries? = nil,
        externalCredentials: ExternalCredentials? = nil,
        credentialGate: CredentialAccessGate = .shared
    ) {
        self.store = store
        self.groupStore = groupStore
        self.profileStore = profileStore
        self.credentialGate = credentialGate
        self.credentialVault = GatedCredentialVault(base: credentialVault, gate: credentialGate)
        self.libraryTools = libraryTools ?? LibraryTools()
        self.sharedLibraries = sharedLibraries ?? SharedLibraries()
        self.externalCredentials = externalCredentials ?? ExternalCredentials(gate: credentialGate)
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
        toolsObservation = self.libraryTools.objectWillChange.sink { [weak self] in
            Task { @MainActor in self?.objectWillChange.send() }
        }
        providerObservation = self.externalCredentials.objectWillChange.sink { [weak self] in
            Task { @MainActor in self?.objectWillChange.send() }
        }
    }

    func open(_ connection: RemoteConnection) {
        guard !credentialGate.isLocked else { return }
        let tab = SessionTab(connection: resolvedConnection(for: connection))
        tabs.append(tab)
        selectedTabID = tab.id
    }

    func openSFTP(_ connection: RemoteConnection) {
        guard !credentialGate.isLocked else { return }
        guard connection.kind == .ssh else { return }
        let tab = SessionTab(connection: resolvedConnection(for: connection), tool: .sftp)
        tabs.append(tab)
        selectedTabID = tab.id
    }

    func openVMConsole(_ vm: VirtualMachine, on host: RemoteConnection) {
        guard !credentialGate.isLocked else { return }
        let tab = SessionTab(connection: resolvedConnection(for: host), tool: .virtualMachine, virtualMachine: vm)
        tabs.append(tab)
        selectedTabID = tab.id
    }

    func openHostSSH(_ host: RemoteConnection) {
        var connection = resolvedConnection(for: host)
        connection.kind = .ssh
        open(connection)
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

        layout.prune(Set(tabs.map(\.id)))

        closeSSHTransportIfUnused(for: closedConnection)
        if !tabs.contains(where: { $0.connection.id == closedConnection.id }) {
            temporaryVMLogins.removeValue(forKey: closedConnection.id)
            VMwareFederation.shared.discard(for: closedConnection.id)
        }
    }

    func add(_ connection: RemoteConnection, password: String?) throws {
        _ = try credentialGate.check()
        guard !connections.contains(where: { $0.id == connection.id }), !credentialProfiles.contains(where: { $0.id == connection.id }) else {
            throw ConnectionTransferError.invalidArchiveContent("connection identity is already in use")
        }
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
        guard !credentialGate.isLocked else { return false }
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
    func removeGroup(_ path: String) throws -> Int {
        guard let existing = groups.first(where: {
            $0.caseInsensitiveCompare(path) == .orderedSame
        }) else { throw ConnectionGroupError.unavailable }
        guard existing.caseInsensitiveCompare("Ungrouped") != .orderedSame else {
            throw ConnectionGroupError.protectedGroup
        }

        let previousConnections = connections
        let previousGroups = groups
        let previousTools = libraryTools.data
        var movedCount = 0
        for index in connections.indices where connections[index].kind != .localShell {
            guard Self.isGroup(connections[index].group, within: existing) else { continue }
            var materialized = libraryTools.resolve(connections[index])
            materialized.terminalAppearance = libraryTools.appearance(for: materialized)
            materialized.terminalProfileID = nil
            materialized.inheritedFields = []
            connections[index] = materialized
            connections[index].group = "Ungrouped"
            connections[index].isFavorite = false
            movedCount += 1
        }
        groups = Self.normalizedGroups(
            groups.filter { !Self.isGroup($0, within: existing) } + ["Ungrouped"]
        )
        do {
            try libraryTools.removeGroup(existing)
            if movedCount > 0 { try persist() }
            groupStore.save(groups)
        } catch {
            connections = previousConnections
            groups = previousGroups
            if libraryTools.data.groupDefaults != previousTools.groupDefaults { try? libraryTools.save(previousTools) }
            groupStore.save(previousGroups)
            throw error
        }
        return movedCount
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
        let previousTools = libraryTools.data
        for index in connections.indices {
            if let updated = Self.replacingGroupPrefix(connections[index].group, using: rename) {
                connections[index].group = updated
            }
        }
        groups = Self.normalizedGroups(groups.map { group in
            Self.replacingGroupPrefix(group, using: rename) ?? group
        })
        do {
            try libraryTools.remapGroups(rename)
            try persist()
            groupStore.save(groups)
        } catch {
            connections = previousConnections
            groups = previousGroups
            if libraryTools.data.groupDefaults != previousTools.groupDefaults { try? libraryTools.save(previousTools) }
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
                openedAt: tab.openedAt,
                virtualMachine: tab.virtualMachine
            )
        }
    }

    func focusConnectionSearch() {
        connectionSearchFocusRequest = UUID()
    }

    func resolvedConnection(for connection: RemoteConnection) -> RemoteConnection {
        applyingTemporaryLogin(to: baseResolvedConnection(for: connection))
    }

    func profileUsageCount(_ profileID: UUID) -> Int {
        connections.filter { $0.credentialProfileID == profileID || libraryTools.resolve($0).credentialProfileID == profileID }.count
            + libraryTools.data.groupDefaults.values.filter { $0.credentialProfileID == profileID }.count
            + libraryTools.data.templates.filter { $0.defaults.credentialProfileID == profileID }.count
    }

    func hasSavedPassword(for profile: CredentialProfile) throws -> Bool {
        _ = try credentialGate.check()
        return try credentialVault.containsPassword(for: profile.id)
    }

    func saveProfile(
        _ profile: CredentialProfile,
        password: String?,
        removeSavedPassword: Bool = false
    ) throws {
        _ = try credentialGate.check()
        if externalCredentials.references[profile.id] != nil, password?.isEmpty == false { throw ExternalCredentialError.invalid }
        let normalized = CredentialProfile(
            id: profile.id,
            name: profile.name.trimmingCharacters(in: .whitespacesAndNewlines),
            username: profile.username.trimmingCharacters(in: .whitespacesAndNewlines),
            domain: profile.domain.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !connections.contains(where: { $0.id == normalized.id }) else {
            throw ConnectionTransferError.invalidArchiveContent("credential-profile identity is already used by a connection")
        }
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
        _ = try credentialGate.check()
        guard !connections.contains(where: { $0.id == profile.id }) else { throw CredentialBindingError.changed }
        let usage = profileUsageCount(profile.id)
        guard usage == 0 else { throw CredentialProfileError.inUse(usage) }
        let previous = credentialProfiles
        credentialProfiles.removeAll { $0.id == profile.id }
        do {
            try profileStore.save(credentialProfiles)
            try credentialVault.deletePassword(for: profile.id)
            try externalCredentials.configure(nil, for: profile.id)
        } catch {
            credentialProfiles = previous
            try? profileStore.save(previous)
            throw error
        }
    }

    private func validateProfileReference(for connection: RemoteConnection) throws {
        try validateCredentialNamespaces(for: connection)
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
            sshX11: connection.sshX11,
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
        var configuredCopy = copy
        configuredCopy.virtualization = connection.virtualization
        configuredCopy.rdpVirtualMachineID = connection.rdpVirtualMachineID
        configuredCopy.terminalProfileID = connection.terminalProfileID
        configuredCopy.terminalAppearance = connection.terminalAppearance
        configuredCopy.inheritedFields = connection.inheritedFields
        try add(configuredCopy, password: (connection.kind == .serial || connection.credentialProfileID != nil)
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
        let previousTools = libraryTools.data
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
            try libraryTools.remapGroups(renames)
            try persist()
            groupStore.save(groups)
        } catch {
            connections = previousConnections
            groups = previousGroups
            if libraryTools.data.groupDefaults != previousTools.groupDefaults { try? libraryTools.save(previousTools) }
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

    private func baseResolvedConnection(for original: RemoteConnection) -> RemoteConnection {
        var connection = libraryTools.resolve(original)
        connection.inheritedFields = nil
        if let id = connection.credentialProfileID, let profile = credentialProfiles.first(where: { $0.id == id }) {
            connection.username = profile.username
            if connection.kind == .rdp { connection.rdpDomain = profile.domain.isEmpty ? nil : profile.domain }
        }
        return connection
    }

    /// Host SSH and Hyper-V consoles intentionally use a management connection's
    /// credentials. Only a corresponding active, app-owned tab can authorize
    /// those fixed routes; an arbitrary snapshot sharing its UUID cannot.
    private func derivedCredentialConnection(_ source: RemoteConnection, for requested: RemoteConnection) -> RemoteConnection? {
        if source.kind == requested.kind { return source }
        guard source.kind == .virtualization else { return nil }
        if requested.kind == .ssh, source.virtualization?.platform.usesSSH == true,
           tabs.contains(where: { $0.connection.id == source.id && $0.connection.kind == .ssh
                && ConnectionImportSecurity.sameCredentialIdentity($0.connection, requested) }) {
            var derived = source; derived.kind = .ssh; return derived
        }
        if requested.kind == .rdp, source.virtualization?.platform == .hyperv,
           let vmID = requested.rdpVirtualMachineID, UUID(uuidString: vmID) != nil,
           tabs.contains(where: { $0.connection.id == source.id && $0.tool == .virtualMachine && $0.virtualMachine?.id == vmID }) {
            var derived = source
            derived.kind = .rdp; derived.port = 2179; derived.rdpVirtualMachineID = vmID
            derived.rdpCertificatePolicy = source.virtualization?.effectiveCertificatePolicy
            derived.rdpDisplayMode = .dynamicWindow
            return derived
        }
        return nil
    }

    private func matchingTemporaryLogin(for connection: RemoteConnection) -> (username: String, password: String)? {
        guard let login = temporaryVMLogins[connection.id],
              var expected = derivedCredentialConnection(login.connection, for: connection) else { return nil }
        if ConnectionImportSecurity.sameCredentialIdentity(expected, connection) { return (login.username, login.password) }
        expected.username = login.username; expected.credentialProfileID = nil
        return ConnectionImportSecurity.sameCredentialIdentity(expected, connection) ? (login.username, login.password) : nil
    }

    private func applyingTemporaryLogin(to connection: RemoteConnection) -> RemoteConnection {
        guard let login = matchingTemporaryLogin(for: connection) else { return connection }
        var temporary = connection
        temporary.username = login.username; temporary.credentialProfileID = nil
        return temporary
    }

    private func validateCredentialNamespaces(for connection: RemoteConnection) throws {
        guard !credentialProfiles.contains(where: { $0.id == connection.id }) else { throw CredentialBindingError.changed }
        if let profileID = connection.credentialProfileID,
           connections.contains(where: { $0.id == profileID }) { throw CredentialBindingError.changed }
    }

    private func authorizedCredentialConnection(_ requested: RemoteConnection, allowStoredRecord: Bool) throws -> RemoteConnection? {
        try validateCredentialNamespaces(for: requested)
        guard let stored = connections.first(where: { $0.id == requested.id }) else {
            // Unsaved guest shortcuts never inherit an orphaned UUID/profile secret.
            // A user-entered temporary VM login remains available only to its tab.
            guard matchingTemporaryLogin(for: requested) != nil,
                  tabs.contains(where: { $0.connection.id == requested.id }) else { return nil }
            return applyingTemporaryLogin(to: requested)
        }
        var storedIdentity = libraryTools.resolve(stored)
        storedIdentity.inheritedFields = nil
        // A current-record lookup may resolve its current profile after a
        // metadata-only restore. A live session always uses the frozen path.
        let currentRecordLookup = allowStoredRecord && (requested == stored
            || ConnectionImportSecurity.sameCredentialIdentity(storedIdentity, requested))
        let snapshot = currentRecordLookup ? resolvedConnection(for: stored) : applyingTemporaryLogin(to: requested)
        guard let current = derivedCredentialConnection(resolvedConnection(for: stored), for: snapshot),
              ConnectionImportSecurity.sameCredentialIdentity(current, snapshot) else {
            throw CredentialBindingError.changed
        }
        try validateCredentialNamespaces(for: current)
        return current
    }

    func password(for connection: RemoteConnection) throws -> String? {
        let epoch = try credentialGate.check()
        guard let target = try authorizedCredentialConnection(connection, allowStoredRecord: true) else { return nil }
        if let login = matchingTemporaryLogin(for: target) {
            try credentialGate.check(epoch); return login.password
        }
        let value: String?
        if let profileID = target.credentialProfileID {
            if externalCredentials.references[profileID] != nil { throw ExternalCredentialError.failed }
            value = try credentialVault.password(for: profileID)
        } else { value = try credentialVault.password(for: target.id) }
        try credentialGate.check(epoch)
        guard let current = try authorizedCredentialConnection(connection, allowStoredRecord: true),
              ConnectionImportSecurity.sameCredentialIdentity(current, target) else { throw CredentialBindingError.changed }
        return value
    }

    func sessionPassword(for connection: RemoteConnection) async throws -> String? {
        let epoch = try credentialGate.check()
        guard let target = try authorizedCredentialConnection(connection, allowStoredRecord: false) else { return nil }
        if let login = matchingTemporaryLogin(for: target) {
            try credentialGate.check(epoch); return login.password
        }
        let value: String?
        if let profile = target.credentialProfileID, externalCredentials.references[profile] != nil {
            value = try await externalCredentials.password(for: profile)
        } else { value = try credentialVault.password(for: target.credentialProfileID ?? target.id) }
        try credentialGate.check(epoch)
        guard let current = try authorizedCredentialConnection(connection, allowStoredRecord: false),
              ConnectionImportSecurity.sameCredentialIdentity(current, target) else { throw CredentialBindingError.changed }
        return value
    }

    func hasSavedPassword(for connection: RemoteConnection) throws -> Bool {
        _ = try credentialGate.check()
        try validateCredentialNamespaces(for: connection)
        if let profile = connection.credentialProfileID, externalCredentials.references[profile] != nil { return true }
        return try credentialVault.containsPassword(for: connection.credentialProfileID ?? connection.id)
    }

    func savePassword(_ password: String, for connection: RemoteConnection) throws {
        _ = try credentialGate.check()
        guard let target = try authorizedCredentialConnection(connection, allowStoredRecord: true) else { throw CredentialBindingError.changed }
        if let profile = target.credentialProfileID, externalCredentials.references[profile] != nil { throw ExternalCredentialError.invalid }
        try credentialVault.save(password: password, for: target.credentialProfileID ?? target.id)
    }

    @discardableResult
    func saveRDPLogin(
        _ credentials: RDPCredentialCandidate,
        for connectionID: RemoteConnection.ID,
        expectedConnection: RemoteConnection? = nil
    ) throws -> RemoteConnection {
        guard var connection = connections.first(where: {
            $0.id == connectionID && $0.kind == .rdp
        }) else {
            throw RDPLoginStorageError.connectionUnavailable
        }
        _ = try credentialGate.check()
        try validateCredentialNamespaces(for: connection)
        if let expectedConnection {
            guard expectedConnection.id == connectionID,
                  ConnectionImportSecurity.sameCredentialIdentity(resolvedConnection(for: connection), expectedConnection) else {
                throw CredentialBindingError.changed
            }
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
        _ = try credentialGate.check()
        guard try authorizedCredentialConnection(connection, allowStoredRecord: true) != nil else { throw CredentialBindingError.changed }
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
        do { try validateCredentialNamespaces(for: connection) }
        catch { report(error); return }
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
        for tab in previousTabs where tab.connection.id == connection.id {
            closeSSHTransportIfUnused(for: tab.connection)
        }
        VMwareFederation.shared.discard(for: connection.id)
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
        VMwareFederation.shared.clear()
        SSHConnectionReuse.shutdownAll(connections: tabs.flatMap { sshTransports(for: $0.connection) } + (extraSSHConnections?() ?? []))
        temporaryVMLogins.removeAll()
    }

    func lockSessions() {
        VMwareFederation.shared.clear()
        privacyTransports += tabs.flatMap { sshTransports(for: $0.connection) } + (extraSSHConnections?() ?? [])
        externalCredentials.clearAuthorization(); temporaryVMLogins.removeAll()
        // Removing tabs makes their retained lifetimes close synchronously in
        // the owner. Do not reconnect/replay when the user unlocks the app.
        tabs.removeAll(); selectedTabID = nil; layout = SessionLayout(); vmInventory.removeAll()
    }

    func finishPrivacyShutdown() async {
        let pending = privacyTransports; privacyTransports = []
        let unconfirmed = (try? await BackgroundWork.run {
            SSHConnectionReuse.shutdownAll(connections: pending, removeDirectory: false)
        }) ?? pending.count
        if unconfirmed > 0 { persistenceNotice = "Sessions were closed, but some SSH master exit requests were not confirmed (a master may already have ended). Check tunnel status and your host before assuming every forward stopped." }
    }

    func makeSharedLibrary(name: String, ids: Set<UUID>, includeEmptyGroups: Bool = false) throws -> SharedLibraryDocument {
        _ = try credentialGate.check()
        let selected = connections.filter { ids.contains($0.id) && $0.kind != .localShell && $0.kind != .serial }
        guard !selected.isEmpty else { throw SharedLibraryError.invalid }
        let selectedGroups = Set(selected.map(\.group))
        let exportedGroups = includeEmptyGroups ? groups : groups.filter { group in selectedGroups.contains(where: { $0 == group || $0.hasPrefix(group + "/") }) }
        let document = SharedLibraryDocument(name: name, groups: exportedGroups, connections: selected.map { SharedConnection($0) })
        try document.validate(); return document
    }

    func makeSharedRevision(_ link: SharedLibraryLink, additionalIDs: Set<UUID> = [], includeEmptyGroups: Bool = false) throws -> SharedLibraryDocument {
        guard sharedLibraries.links.contains(link) else { throw SharedLibraryError.changed }
        let selectedIDs = Set(link.mapping.values).union(additionalIDs)
        var document = try makeSharedLibrary(name: link.baseline.name, ids: selectedIDs, includeEmptyGroups: includeEmptyGroups)
        document.id = link.id
        document.groups = Array(Set(document.groups + link.baseline.groups.filter { groups.contains($0) })).sorted()
        let reverse = Dictionary(uniqueKeysWithValues: link.mapping.map { ($0.value, $0.key) })
        document.connections = document.connections.map { item in
            var shared = item; shared.id = reverse[item.id] ?? item.id; return shared
        }
        try document.validate(); return document
    }

    func applySharedReview(_ review: SharedLibraryReview, takeShared: Set<String>) async throws {
        let epoch = try credentialGate.check()
        let (_, fingerprint) = try await Task.detached { try SharedLibraryFile.read(URL(fileURLWithPath: review.path)) }.value
        try credentialGate.check(epoch)
        guard fingerprint == review.fingerprint, connections == review.originals,
              sharedLibraries.links.first(where: { $0.id == review.document.id }) == review.link else { throw SharedLibraryError.changed }
        var merged = try review.merged(takeShared: takeShared)
        for index in merged.connections.indices {
            guard let previous = connections.first(where: { $0.id == merged.connections[index].id }),
                  previous.group != merged.connections[index].group, previous.inheritedFields?.isEmpty == false else { continue }
            let metadata = SharedConnection(merged.connections[index])
            let previousMetadata = SharedConnection(previous)
            var frozen = libraryTools.resolve(previous)
            if DefaultField.appearance.supports(frozen.kind) { frozen.terminalAppearance = libraryTools.appearance(for: frozen); frozen.terminalProfileID = nil }
            frozen.inheritedFields = nil
            for field in SharedConnection.Field.allCases where metadata.value(field) != previousMetadata.value(field) { metadata.applying(field, to: &frozen) }
            merged.connections[index] = frozen
        }
        guard merged.connections.count <= 10001 else { throw SharedLibraryError.invalid }
        try store.save(merged.connections)
        do { try sharedLibraries.save(merged.link) }
        catch {
            do { try store.save(connections) }
            catch { persistenceNotice = "The shared merge could not be rolled back on disk. Keep the app open and back up your current library before restarting." }
            throw error
        }
        connections = merged.connections
        groups = Self.normalizedGroups(groups + review.document.groups + connections.filter { $0.kind != .localShell }.map(\.group))
        groupStore.save(groups)
    }

    func useVMLogin(username: String, password: String, for connection: RemoteConnection) {
        guard !credentialGate.isLocked else { return }
        guard connection.kind == .virtualization else { return }
        temporaryVMLogins[connection.id] = (baseResolvedConnection(for: connection), username, password)
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
        _ = try credentialGate.check()
        let exportedConnections = connections.filter { $0.kind != .localShell }.map { original in
            var materialized = libraryTools.resolve(original)
            materialized.inheritedFields = nil
            if DefaultField.appearance.supports(original.kind) {
                materialized.terminalAppearance = libraryTools.appearance(for: materialized)
                materialized.terminalProfileID = nil
            }
            return materialized
        }
        let credentials: [ConnectionArchiveCredential]
        let profileCredentials: [CredentialProfileSecret]
        if includeCredentials {
            credentials = try exportedConnections.compactMap { connection in
                guard connection.kind != .serial, connection.credentialProfileID == nil else { return nil }
                guard let password = try credentialVault.password(for: connection.id) else { return nil }
                return ConnectionArchiveCredential(connectionID: connection.id, password: password)
            }
            profileCredentials = try credentialProfiles.compactMap { profile in
                guard externalCredentials.references[profile.id] == nil else { return nil }
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
        conflictPolicy: ConnectionImportConflictPolicy,
        options: ConnectionImportOptions = ConnectionImportOptions()
    ) throws -> ConnectionImportSummary {
        _ = try credentialGate.check()
        try ConnectionTransferService.validateForImport(archive)
        let existingConnectionIDs = Set(connections.map(\.id))
        let existingProfileIDs = Set(credentialProfiles.map(\.id))
        guard Set(archive.connections.map(\.id)).isDisjoint(with: existingProfileIDs),
              Set(archive.profiles.map(\.id)).isDisjoint(with: existingConnectionIDs),
              existingConnectionIDs.isDisjoint(with: existingProfileIDs),
              existingConnectionIDs.count == connections.count, existingProfileIDs.count == credentialProfiles.count else {
            throw ConnectionTransferError.invalidArchiveContent("connection and credential-profile identities conflict with the current library")
        }
        let previousConnections = connections
        let previousGroups = groups
        let previousProfiles = credentialProfiles
        let previousSelectedConnectionID = selectedConnectionID
        var mergedConnections = connections
        var mergedProfiles = credentialProfiles
        let existingConnectionIndices = Dictionary(uniqueKeysWithValues: connections.enumerated().map { ($0.element.id, $0.offset) })
        let existingProfileIndices = Dictionary(uniqueKeysWithValues: credentialProfiles.enumerated().map { ($0.element.id, $0.offset) })
        let importedProfiles = Dictionary(uniqueKeysWithValues: archive.profiles.map { ($0.id, $0) })
        var appliedConnectionIDs: [UUID: UUID] = [:]
        var appliedProfileIDs: [UUID: UUID] = [:]
        var profileIDs: [UUID: UUID] = [:]
        var reserved = existingConnectionIDs.union(existingProfileIDs)
            .union(archive.connections.map(\.id)).union(archive.profiles.map(\.id))
        func freshIdentity() throws -> UUID {
            while true {
                let candidate = UUID()
                guard !reserved.contains(candidate) else { continue }
                if try credentialVault.containsPassword(for: candidate) { continue }
                reserved.insert(candidate)
                return candidate
            }
        }
        var added = 0, replaced = 0, skipped = 0, profilesAdded = 0, profilesReplaced = 0
        var isolatedConnections = 0, isolatedProfiles = 0, restrictedConnections = 0, detachedProfiles = 0

        for imported in archive.profiles {
            var candidate = imported
            if let index = existingProfileIndices[imported.id] {
                let previous = mergedProfiles[index]
                if conflictPolicy == .keepExisting {
                    profileIDs[imported.id] = imported.id
                    continue
                }
                if previous.username != imported.username || previous.domain != imported.domain {
                    candidate = CredentialProfile(id: try freshIdentity(), name: String(imported.name.prefix(1000)) + " (Imported)",
                        username: imported.username, domain: imported.domain)
                    mergedProfiles.append(candidate)
                    profilesAdded += 1; isolatedProfiles += 1
                } else {
                    mergedProfiles[index] = candidate
                    profilesReplaced += 1
                }
            } else {
                // A stale Keychain item is not proof that a file owns that identity.
                if try credentialVault.containsPassword(for: imported.id) {
                    candidate = CredentialProfile(id: try freshIdentity(), name: imported.name,
                        username: imported.username, domain: imported.domain)
                    isolatedProfiles += 1
                }
                mergedProfiles.append(candidate)
                profilesAdded += 1
            }
            profileIDs[imported.id] = candidate.id
            appliedProfileIDs[imported.id] = candidate.id
        }

        for imported in archive.connections {
            let existingIndex = existingConnectionIndices[imported.id]
            if existingIndex != nil && conflictPolicy == .keepExisting { skipped += 1; continue }
            var candidate = imported
            if !options.approvedCapabilities.contains(imported.id) {
                if !ConnectionImportSecurity.capabilities(imported).isEmpty { restrictedConnections += 1 }
                candidate = ConnectionImportSecurity.restricted(candidate)
            }
            if let profile = candidate.credentialProfileID { candidate.credentialProfileID = profileIDs[profile] }
            let sameIdentity = existingIndex.map {
                ConnectionImportSecurity.sameCredentialIdentity(mergedConnections[$0], candidate)
            } ?? false
            if !sameIdentity, let profile = candidate.credentialProfileID,
               existingProfileIDs.contains(profile), !options.approvedCredentialReuse.contains(imported.id) {
                // Importing a profile reference must not authorize a new target to use its secret/provider.
                if let id = imported.credentialProfileID, let metadata = importedProfiles[id] {
                    candidate.username = metadata.username
                    if candidate.kind == .rdp { candidate.rdpDomain = metadata.domain.isEmpty ? nil : metadata.domain }
                }
                candidate.credentialProfileID = nil
                detachedProfiles += 1
            }
            if let index = existingIndex, sameIdentity {
                mergedConnections[index] = candidate
                replaced += 1
            } else {
                if try existingIndex != nil || credentialVault.containsPassword(for: candidate.id) {
                    candidate.id = try freshIdentity()
                    isolatedConnections += 1
                }
                mergedConnections.append(candidate)
                added += 1
            }
            appliedConnectionIDs[imported.id] = candidate.id
        }

        let credentialsToImport = archive.credentials.compactMap { credential -> ConnectionArchiveCredential? in
            guard let id = appliedConnectionIDs[credential.connectionID] else { return nil }
            return ConnectionArchiveCredential(connectionID: id, password: credential.password)
        }
        let profileCredentialsToImport = archive.profileCredentials.compactMap { credential -> CredentialProfileSecret? in
            guard let id = appliedProfileIDs[credential.profileID] else { return nil }
            return CredentialProfileSecret(profileID: id, password: credential.password)
        }
        guard profileCredentialsToImport.allSatisfy({ externalCredentials.references[$0.profileID] == nil }) else {
            throw ConnectionTransferError.invalidArchiveContent("an externally managed profile cannot receive an imported local password")
        }
        let credentialIDs = credentialsToImport.map(\.connectionID) + profileCredentialsToImport.map(\.profileID)
        let previousCredentials = try Dictionary(uniqueKeysWithValues: credentialIDs.map {
            ($0, try credentialVault.password(for: $0))
        })
        connections = mergedConnections
        credentialProfiles = mergedProfiles.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        groups = Self.normalizedGroups(previousGroups + archive.groups + mergedConnections.filter { $0.kind != .localShell }.map(\.group))
        if let selectedConnectionID, !connections.contains(where: { $0.id == selectedConnectionID }) {
            self.selectedConnectionID = connections.first?.id
        }
        do {
            try persist()
            groupStore.save(groups)
            try profileStore.save(credentialProfiles)
            for credential in credentialsToImport { try credentialVault.save(password: credential.password, for: credential.connectionID) }
            for credential in profileCredentialsToImport { try credentialVault.save(password: credential.password, for: credential.profileID) }
        } catch {
            connections = previousConnections; groups = previousGroups; credentialProfiles = previousProfiles
            selectedConnectionID = previousSelectedConnectionID
            try? persist(); groupStore.save(previousGroups); try? profileStore.save(previousProfiles)
            for (id, password) in previousCredentials {
                if let password { try? credentialVault.save(password: password, for: id) }
                else { try? credentialVault.deletePassword(for: id) }
            }
            throw error
        }
        if selectedConnectionID == nil { selectedConnectionID = connections.first?.id }
        return ConnectionImportSummary(added: added, replaced: replaced, skipped: skipped,
            credentialsImported: credentialsToImport.count + profileCredentialsToImport.count,
            profilesAdded: profilesAdded, profilesReplaced: profilesReplaced,
            isolatedConnections: isolatedConnections, isolatedProfiles: isolatedProfiles,
            restrictedConnections: restrictedConnections, detachedProfiles: detachedProfiles)
    }

    private func persist() throws {
        _ = try credentialGate.check()
        try store.save(connections)
    }

    /// One metadata write; no password access and no mutation of live session snapshots.
    func applyBulk(_ patch: BulkConnectionPatch, ids: Set<UUID>, expected: [RemoteConnection]? = nil) throws {
        _ = try credentialGate.check()
        guard !ids.isEmpty, ids.count <= 10000,
              ids.isSubset(of: Set(connections.filter { $0.kind != .localShell }.map(\.id))) else {
            throw WorkflowError.invalid("The selected clients changed. Select them again before applying edits.")
        }
        if let expected {
            let current = connections.filter { ids.contains($0.id) }
            guard Set(expected.map(\.id)) == ids, Set(current) == Set(expected) else {
                throw WorkflowError.invalid("A selected client changed after preview. Review the changes again.")
            }
        }
        if let group = patch.group, !editableGroupPaths.contains(group) { throw ConnectionMoveError.unknownGroup }
        let next = try connections.map { connection in
            guard ids.contains(connection.id) else { return connection }
            let updated = try patch.apply(connection)
            try validateProfileReference(for: updated)
            if let id = updated.terminalProfileID, !libraryTools.data.profiles.contains(where: { $0.id == id }) {
                throw WorkflowError.invalid("The terminal profile is no longer available.")
            }
            return updated
        }
        try store.save(next)
        connections = next
        if let group = patch.group { addGroupIfNeeded(group) }
    }

    func addMigratedConnections(_ imported: [RemoteConnection], groups importedGroups: [String]) throws {
        _ = try credentialGate.check()
        guard !imported.isEmpty, imported.count <= 10000, Set(imported.map(\.id)).count == imported.count,
              Set(imported.map(\.id)).isDisjoint(with: Set(connections.map(\.id))) else {
            throw WorkflowError.invalid("No valid new connections were selected for import.")
        }
        let archive = ConnectionArchive(groups: importedGroups, connections: imported)
        _ = try ConnectionTransferService.encodePlain(archive)
        let next = connections + imported
        try store.save(next)
        connections = next
        for group in importedGroups + imported.map(\.group) { addGroupIfNeeded(group) }
    }

    private func addGroupIfNeeded(_ name: String) {
        _ = addGroup(name)
    }

    func closeSSHTransportIfUnused(for connection: RemoteConnection) {
        for transport in sshTransports(for: connection) {
            let key = SSHConnectionReuse.controlKey(for: transport)
            guard !(tabs.flatMap({ sshTransports(for: $0.connection) }) + (extraSSHConnections?() ?? [])).contains(where: {
                SSHConnectionReuse.controlKey(for: $0) == key
            }) else { continue }
            SSHConnectionReuse.shutdown(connection: transport)
        }
    }

    private func sshTransports(for connection: RemoteConnection) -> [RemoteConnection] {
        if connection.kind == .ssh || (connection.kind == .virtualization && connection.virtualization?.platform.usesSSH == true) {
            var transport = connection
            transport.kind = .ssh
            return [transport]
        }
        if let id = connection.virtualization?.tunnelConnectionID,
           let host = connections.first(where: { $0.id == id && $0.kind == .ssh }) {
            return [resolvedConnection(for: host)]
        }
        return []
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
