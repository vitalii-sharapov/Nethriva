import Foundation

enum NethrivaDataProfile {
    // Hosted XCTest must not read or rewrite the user's Debug/Release library.
    static let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil
    private static let testSuite = "com.vitalii.Nethriva.Tests.\(ProcessInfo.processInfo.processIdentifier)"
    static var effectiveCredentialService: String {
        isTesting ? testSuite + ".credentials" : credentialService
    }
    static var effectiveLegacyCredentialServices: [String] { isTesting ? [] : legacyCredentialServices }
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
        if isTesting, let defaults = UserDefaults(suiteName: testSuite) { return defaults }
        guard let defaultsSuiteName,
              let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
            return .standard
        }
        return defaults
    }

    static var legacyDefaults: UserDefaults? {
        guard !isDevelopment, !isTesting else { return nil }
        return UserDefaults(suiteName: "com.vitalii.RemoteDeck")
    }
}
