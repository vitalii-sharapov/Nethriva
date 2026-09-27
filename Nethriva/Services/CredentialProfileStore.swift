import Foundation

protocol CredentialProfilePersisting {
    func load() throws -> [CredentialProfile]
    func save(_ profiles: [CredentialProfile]) throws
}

final class InMemoryCredentialProfileStore: CredentialProfilePersisting {
    private var profiles: [CredentialProfile] = []
    func load() throws -> [CredentialProfile] { profiles }
    func save(_ profiles: [CredentialProfile]) throws { self.profiles = profiles }
}

enum CredentialProfileStoreError: LocalizedError {
    case corruptedData
    case unsupportedSchema(Int)
    case writeVerificationFailed

    var errorDescription: String? {
        switch self {
        case .corruptedData:
            "Saved credential profiles could not be decoded. The original data was left untouched."
        case .unsupportedSchema(let version):
            "Saved credential profiles use unsupported schema version \(version)."
        case .writeVerificationFailed:
            "Nethriva could not verify the saved credential profiles."
        }
    }
}

private struct CredentialProfileEnvelope: Codable {
    let schemaVersion: Int
    let profiles: [CredentialProfile]
}

final class UserDefaultsCredentialProfileStore: CredentialProfilePersisting {
    private let defaults: UserDefaults
    private let key: String
    private let backupKey: String

    init(defaults: UserDefaults = NethrivaDataProfile.defaults, key: String = "credentialProfiles.v1") {
        self.defaults = defaults
        self.key = key
        backupKey = "\(key).lastKnownGood"
    }

    func load() throws -> [CredentialProfile] {
        if let data = defaults.data(forKey: key) {
            do { return try decode(data) }
            catch CredentialProfileStoreError.unsupportedSchema(let version) {
                throw CredentialProfileStoreError.unsupportedSchema(version)
            } catch {
                if let backup = defaults.data(forKey: backupKey),
                   let profiles = try? decode(backup) {
                    defaults.set(backup, forKey: key)
                    return profiles
                }
                throw error
            }
        }
        if let backup = defaults.data(forKey: backupKey),
           let profiles = try? decode(backup) {
            defaults.set(backup, forKey: key)
            return profiles
        }
        return []
    }

    func save(_ profiles: [CredentialProfile]) throws {
        let data = try JSONEncoder().encode(CredentialProfileEnvelope(schemaVersion: 1, profiles: profiles))
        defaults.set(data, forKey: key)
        guard let written = defaults.data(forKey: key),
              (try? decode(written)) == profiles else {
            throw CredentialProfileStoreError.writeVerificationFailed
        }
        defaults.set(data, forKey: backupKey)
    }

    private func decode(_ data: Data) throws -> [CredentialProfile] {
        guard let envelope = try? JSONDecoder().decode(CredentialProfileEnvelope.self, from: data) else {
            throw CredentialProfileStoreError.corruptedData
        }
        guard envelope.schemaVersion == 1 else {
            throw CredentialProfileStoreError.unsupportedSchema(envelope.schemaVersion)
        }
        return envelope.profiles
    }
}
