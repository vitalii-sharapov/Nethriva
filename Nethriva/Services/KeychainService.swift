import Foundation
import Security

protocol CredentialVault {
    func save(password: String, for connectionID: UUID) throws
    func password(for connectionID: UUID) throws -> String?
    func deletePassword(for connectionID: UUID) throws
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
    static let shared = KeychainService()

    private let service = "com.vitalii.nethriva.credentials"
    private let legacyServices = ["com.remotedeck.credentials"]

    private init() {}

    func save(password: String, for connectionID: UUID) throws {
        let account = connectionID.uuidString
        let data = Data(password.utf8)
        let baseQuery = query(account: account, service: service)

        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    func password(for connectionID: UUID) throws -> String? {
        let account = connectionID.uuidString

        if let password = try password(account: account, service: service) {
            return password
        }

        for legacyService in legacyServices {
            if let password = try password(account: account, service: legacyService) {
                try save(password: password, for: connectionID)
                return password
            }
        }

        return nil
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
