import Foundation

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let showSidebarAddresses = "settings.showSidebarAddresses"
        static let showSidebarUsernames = "settings.showSidebarUsernames"
        static let showSessionAddresses = "settings.showSessionAddresses"
        static let showSessionUsernames = "settings.showSessionUsernames"
    }

    private let defaults: UserDefaults

    @Published var showSidebarAddresses: Bool {
        didSet { defaults.set(showSidebarAddresses, forKey: Key.showSidebarAddresses) }
    }

    @Published var showSidebarUsernames: Bool {
        didSet { defaults.set(showSidebarUsernames, forKey: Key.showSidebarUsernames) }
    }

    @Published var showSessionAddresses: Bool {
        didSet { defaults.set(showSessionAddresses, forKey: Key.showSessionAddresses) }
    }

    @Published var showSessionUsernames: Bool {
        didSet { defaults.set(showSessionUsernames, forKey: Key.showSessionUsernames) }
    }

    init(defaults: UserDefaults = NethrivaDataProfile.defaults) {
        self.defaults = defaults
        showSidebarAddresses = defaults.object(forKey: Key.showSidebarAddresses) as? Bool ?? true
        showSidebarUsernames = defaults.bool(forKey: Key.showSidebarUsernames)
        showSessionAddresses = defaults.object(forKey: Key.showSessionAddresses) as? Bool ?? true
        showSessionUsernames = defaults.bool(forKey: Key.showSessionUsernames)
    }

    func sidebarEndpoint(for connection: RemoteConnection) -> String? {
        guard showSidebarAddresses else { return nil }
        return endpoint(for: connection, showUsername: showSidebarUsernames)
    }

    func sessionEndpoint(for connection: RemoteConnection) -> String? {
        guard showSessionAddresses else { return nil }
        return endpoint(for: connection, showUsername: showSessionUsernames)
    }

    private func endpoint(for connection: RemoteConnection, showUsername: Bool) -> String {
        guard connection.kind != .localShell else { return "This Mac" }
        let username = showUsername && !connection.username.isEmpty
            ? "\(connection.username)@"
            : ""
        return "\(username)\(connection.host):\(connection.port)"
    }
}
