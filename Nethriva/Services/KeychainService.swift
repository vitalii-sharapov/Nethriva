import Foundation
import Security

protocol CredentialVault {
    func save(password: String, for connectionID: UUID) throws
    func password(for connectionID: UUID) throws -> String?
    func containsPassword(for connectionID: UUID) throws -> Bool
    func deletePassword(for connectionID: UUID) throws
}

extension CredentialVault {
    func containsPassword(for connectionID: UUID) throws -> Bool {
        try password(for: connectionID) != nil
    }
}

enum KeychainError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
        case .invalidData:
            "The saved Keychain item is not valid UTF-8 text."
        }
    }
}

final class KeychainService: CredentialVault {
    static let shared = KeychainService(
        service: NethrivaDataProfile.credentialService,
        legacyServices: NethrivaDataProfile.legacyCredentialServices
    )

    private let service: String
    private let legacyServices: [String]

    init(service: String, legacyServices: [String] = []) {
        self.service = service
        self.legacyServices = legacyServices
    }

    func save(password: String, for connectionID: UUID) throws {
        let account = connectionID.uuidString
        let data = Data(password.utf8)
        let baseQuery = query(account: account, service: service)

        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ] as CFDictionary
        )

        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    func password(for connectionID: UUID) throws -> String? {
        let account = connectionID.uuidString
        return try Self.resolvePassword(
            account: account,
            currentService: service,
            legacyServices: legacyServices,
            read: { account, service in
                try self.password(account: account, service: service)
            },
            migrate: { password in
                try self.save(password: password, for: connectionID)
            }
        )
    }

    static func resolvePassword(
        account: String,
        currentService: String,
        legacyServices: [String],
        read: (String, String) throws -> String?,
        migrate: (String) throws -> Void
    ) throws -> String? {
        // Reading an existing item must not update it. A write can prompt for
        // additional Keychain authorization on every connection attempt.
        if let password = try read(account, currentService) {
            return password
        }

        for legacyService in legacyServices {
            if let password = try read(account, legacyService) {
                try migrate(password)
                return password
            }
        }

        return nil
    }

    func containsPassword(for connectionID: UUID) throws -> Bool {
        let account = connectionID.uuidString
        for service in [service] + legacyServices {
            var lookup = query(account: account, service: service)
            // The editor needs only existence, not the protected password data.
            lookup[kSecReturnAttributes as String] = true
            lookup[kSecMatchLimit as String] = kSecMatchLimitOne

            var result: CFTypeRef?
            let status = SecItemCopyMatching(lookup as CFDictionary, &result)
            if status == errSecSuccess { return true }
            guard status == errSecItemNotFound else {
                throw KeychainError.unexpectedStatus(status)
            }
        }
        return false
    }

    func deletePassword(for connectionID: UUID) throws {
        let account = connectionID.uuidString
        let services = [service] + legacyServices

        for service in services {
            let status = SecItemDelete(query(account: account, service: service) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError.unexpectedStatus(status)
            }
        }
    }

    private func password(account: String, service: String) throws -> String? {
        var lookup = query(account: account, service: service)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard
            let data = result as? Data,
            let password = String(data: data, encoding: .utf8)
        else {
            throw KeychainError.invalidData
        }
        return password
    }

    private func query(account: String, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
