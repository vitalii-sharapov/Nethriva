import Foundation

protocol ConnectionPersisting {
    func load() -> [RemoteConnection]
    func save(_ connections: [RemoteConnection])
}

protocol ConnectionGroupPersisting {
    func load() -> [String]
    func save(_ groups: [String])
}

final class UserDefaultsConnectionStore: ConnectionPersisting {
    private let defaults: UserDefaults
    private let legacyDefaults: UserDefaults?
    private let storageKey: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "connections.v1",
        legacyDefaults: UserDefaults? = UserDefaults(suiteName: "com.vitalii.RemoteDeck")
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.legacyDefaults = legacyDefaults
    }

    func load() -> [RemoteConnection] {
        if let decoded = decode(from: defaults) {
            return addingLocalShellIfNeeded(to: decoded)
        }

        if let legacyDefaults, let migrated = decode(from: legacyDefaults) {
            save(migrated)
            return addingLocalShellIfNeeded(to: migrated)
        }

        return [.localShell]
    }

    func save(_ connections: [RemoteConnection]) {
        guard let data = try? encoder.encode(connections) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private func decode(from defaults: UserDefaults) -> [RemoteConnection]? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? decoder.decode([RemoteConnection].self, from: data)
    }

    private func addingLocalShellIfNeeded(to connections: [RemoteConnection]) -> [RemoteConnection] {
        connections.contains(where: { $0.kind == .localShell })
            ? connections
            : [.localShell] + connections
    }
}

final class UserDefaultsConnectionGroupStore: ConnectionGroupPersisting {
    private let defaults: UserDefaults
    private let legacyDefaults: UserDefaults?
    private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "connectionGroups.v1",
        legacyDefaults: UserDefaults? = UserDefaults(suiteName: "com.vitalii.RemoteDeck")
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.legacyDefaults = legacyDefaults
    }

    func load() -> [String] {
        if let groups = defaults.stringArray(forKey: storageKey) {
            return groups
        }

        if let groups = legacyDefaults?.stringArray(forKey: storageKey) {
            save(groups)
            return groups
        }

        return []
    }

    func save(_ groups: [String]) {
        defaults.set(groups, forKey: storageKey)
    }
}
