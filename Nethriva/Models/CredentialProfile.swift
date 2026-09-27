import Foundation

/// Metadata only. The password is a separate macOS Keychain item keyed by `id`.
struct CredentialProfile: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var username: String
    var domain: String

    init(id: UUID = UUID(), name: String, username: String, domain: String = "") {
        self.id = id
        self.name = name
        self.username = username
        self.domain = domain
    }
}
