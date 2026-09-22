import Foundation

enum NethrivaDataProfile {
#if DEBUG
    static let isDevelopment = true
    static let defaultsSuiteName: String? = "com.vitalii.Nethriva.Development"
    static let credentialService = "com.vitalii.nethriva.development.credentials"
    static let legacyCredentialServices: [String] = []
#else
    static let isDevelopment = false
    static let defaultsSuiteName: String? = nil
    static let credentialService = "com.vitalii.nethriva.credentials"
    static let legacyCredentialServices = ["com.remotedeck.credentials"]
#endif

    static var defaults: UserDefaults {
        guard let defaultsSuiteName,
              let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
            return .standard
        }
        return defaults
    }

    static var legacyDefaults: UserDefaults? {
        guard !isDevelopment else { return nil }
        return UserDefaults(suiteName: "com.vitalii.RemoteDeck")
    }
}
