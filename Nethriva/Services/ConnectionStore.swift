import Foundation

protocol ConnectionPersisting {
    func load() throws -> ConnectionLoadResult
    func save(_ connections: [RemoteConnection]) throws
}

protocol ConnectionGroupPersisting {
    func load() -> [String]
    func save(_ groups: [String])
}

struct ConnectionLoadResult {
    let connections: [RemoteConnection]
    let recoveryNotice: String?
}

enum ConnectionStoreError: LocalizedError {
    case corruptedData
    case unsupportedSchema(Int)
    case writeVerificationFailed

    var errorDescription: String? {
        switch self {
        case .corruptedData:
            "Saved connections could not be decoded. Nethriva left the damaged data untouched so it can be recovered."
        case .unsupportedSchema(let version):
            "Saved connections use unsupported schema version \(version)."
        case .writeVerificationFailed:
            "Nethriva could not verify the saved connection data."
        }
    }
}

private struct ConnectionStoreEnvelope: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let connections: [RemoteConnection]
}

final class UserDefaultsConnectionStore: ConnectionPersisting {
    private let defaults: UserDefaults
    private let legacyDefaults: UserDefaults?
    private let storageKey: String
    private let backupKey: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        defaults: UserDefaults = NethrivaDataProfile.defaults,
        storageKey: String = "connections.v1",
        legacyDefaults: UserDefaults? = NethrivaDataProfile.legacyDefaults
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.backupKey = "\(storageKey).lastKnownGood"
        self.legacyDefaults = legacyDefaults
    }

    func load() throws -> ConnectionLoadResult {
        if let data = defaults.data(forKey: storageKey) {
            do {
                return ConnectionLoadResult(
                    connections: addingLocalShellIfNeeded(to: try decode(data)),
                    recoveryNotice: nil
                )
            } catch ConnectionStoreError.unsupportedSchema(let version) {
                throw ConnectionStoreError.unsupportedSchema(version)
            } catch {
                if let backup = defaults.data(forKey: backupKey),
                   let recovered = try? decode(backup) {
                    defaults.set(backup, forKey: storageKey)
                    return ConnectionLoadResult(
                        connections: addingLocalShellIfNeeded(to: recovered),
                        recoveryNotice: "Nethriva restored saved connections from the last-known-good backup."
                    )
                }
                throw error
            }
        }

        if let backup = defaults.data(forKey: backupKey),
           let recovered = try? decode(backup) {
            defaults.set(backup, forKey: storageKey)
            return ConnectionLoadResult(
                connections: addingLocalShellIfNeeded(to: recovered),
                recoveryNotice: "Nethriva restored saved connections from the last-known-good backup."
            )
        }

        if let legacyDefaults,
           let legacyData = legacyDefaults.data(forKey: storageKey),
           let migrated = try? decode(legacyData) {
            try save(migrated)
            return ConnectionLoadResult(
                connections: addingLocalShellIfNeeded(to: migrated),
                recoveryNotice: nil
            )
        }

        return ConnectionLoadResult(connections: [.localShell], recoveryNotice: nil)
    }

    func save(_ connections: [RemoteConnection]) throws {
        let envelope = ConnectionStoreEnvelope(
            schemaVersion: ConnectionStoreEnvelope.currentSchemaVersion,
            connections: connections
        )
        let data = try encoder.encode(envelope)
        defaults.set(data, forKey: storageKey)
        guard let writtenData = defaults.data(forKey: storageKey),
              (try? decode(writtenData)) != nil else {
            throw ConnectionStoreError.writeVerificationFailed
        }
        defaults.set(data, forKey: backupKey)
    }

    private func decode(_ data: Data) throws -> [RemoteConnection] {
        if let envelope = try? decoder.decode(ConnectionStoreEnvelope.self, from: data) {
            guard envelope.schemaVersion == ConnectionStoreEnvelope.currentSchemaVersion else {
                throw ConnectionStoreError.unsupportedSchema(envelope.schemaVersion)
            }
            return envelope.connections
        }
        if let legacyConnections = try? decoder.decode([RemoteConnection].self, from: data) {
            return legacyConnections
        }
        throw ConnectionStoreError.corruptedData
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
        defaults: UserDefaults = NethrivaDataProfile.defaults,
        storageKey: String = "connectionGroups.v1",
        legacyDefaults: UserDefaults? = NethrivaDataProfile.legacyDefaults
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
