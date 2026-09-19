import CryptoKit
import Foundation
import NIOSSH

struct SSHHostKeyChallenge: Identifiable, Equatable {
    let id = UUID()
    let endpoint: String
    let algorithm: String
    let fingerprint: String
    let isChangedKey: Bool
}

struct SSHHostKeyIdentity: Equatable {
    let openSSH: String
    let algorithm: String
    let fingerprint: String

    init(hostKey: NIOSSHPublicKey) {
        let openSSH = String(openSSHPublicKey: hostKey)
        let fields = openSSH.split(separator: " ", maxSplits: 2)
        let algorithm = fields.first.map(String.init) ?? "Unknown"
        let keyData = fields.count > 1
            ? Data(base64Encoded: String(fields[1])) ?? Data(openSSH.utf8)
            : Data(openSSH.utf8)
        let digest = Data(SHA256.hash(data: keyData))
        let fingerprint = digest.base64EncodedString().replacingOccurrences(of: "=", with: "")

        self.openSSH = openSSH
        self.algorithm = algorithm
        self.fingerprint = "SHA256:\(fingerprint)"
    }
}

final class SSHHostKeyStore {
    static let shared = SSHHostKeyStore()

    private let defaults: UserDefaults
    private let storageKey = "trustedSSHHostKeys.v1"
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func trustedKey(for endpoint: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storedKeys()[endpoint]
    }

    func trust(_ identity: SSHHostKeyIdentity, for endpoint: String) {
        lock.lock()
        defer { lock.unlock() }
        var keys = storedKeys()
        keys[endpoint] = identity.openSSH
        defaults.set(keys, forKey: storageKey)
    }

    private func storedKeys() -> [String: String] {
        defaults.dictionary(forKey: storageKey) as? [String: String] ?? [:]
    }
}
