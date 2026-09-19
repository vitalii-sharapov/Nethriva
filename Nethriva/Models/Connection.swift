import Foundation

enum ConnectionKind: String, Codable, CaseIterable, Identifiable {
    case localShell
    case ssh
    case rdp

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .localShell: "Local"
        case .ssh: "SSH"
        case .rdp: "RDP"
        }
    }

    var systemImage: String {
        switch self {
        case .localShell: "terminal"
        case .ssh: "chevron.left.forwardslash.chevron.right"
        case .rdp: "display"
        }
    }

    var defaultPort: Int {
        switch self {
        case .localShell: 0
        case .ssh: 22
        case .rdp: 3389
        }
    }
}

enum SSHAuthenticationMode: String, Codable, CaseIterable, Identifiable {
    case automatic
    case password
    case publicKey

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .password: "Password / Interactive"
        case .publicKey: "Public Key Only"
        }
    }
}

enum RDPDisplayMode: String, Codable, CaseIterable, Identifiable {
    case dynamicWindow
    case fullscreen
    case multiMonitor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dynamicWindow: "Resizable Window"
        case .fullscreen: "Full Screen"
        case .multiMonitor: "All Monitors"
        }
    }
}

enum RDPAudioMode: String, Codable, CaseIterable, Identifiable {
    case local
    case remote
    case disabled

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local: "Play on This Mac"
        case .remote: "Play on Remote PC"
        case .disabled: "Disabled"
        }
    }
}

enum RDPCertificatePolicy: String, Codable, CaseIterable, Identifiable {
    case trustOnFirstUse
    case systemValidation
    case ignore

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .trustOnFirstUse: "Trust on First Use"
        case .systemValidation: "Require Valid Certificate"
        case .ignore: "Ignore Certificate Warnings"
        }
    }
}

enum RDPNetworkProfile: String, Codable, CaseIterable, Identifiable {
    case automatic = "auto"
    case lan
    case broadbandHigh = "broadband-high"
    case broadbandLow = "broadband-low"
    case wan
    case modem

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .lan: "LAN"
        case .broadbandHigh: "Fast Broadband"
        case .broadbandLow: "Limited Broadband"
        case .wan: "WAN"
        case .modem: "Very Slow Link"
        }
    }
}

struct RemoteConnection: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var kind: ConnectionKind
    var host: String
    var port: Int
    var username: String
    var group: String
    var isFavorite: Bool
    var createdAt: Date
    var sshAuthentication: SSHAuthenticationMode?
    var sshIdentityFile: String?
    var sshJumpHost: String?
    var sshForwardAgent: Bool?
    var sshCompression: Bool?
    var sshKeepAliveInterval: Int?
    var rdpDomain: String?
    var rdpGatewayHost: String?
    var rdpGatewayUsername: String?
    var rdpDisplayMode: RDPDisplayMode?
    var rdpWidth: Int?
    var rdpHeight: Int?
    var rdpScale: Int?
    var rdpClipboard: Bool?
    var rdpAudioMode: RDPAudioMode?
    var rdpMicrophone: Bool?
    var rdpRedirectHome: Bool?
    var rdpSharedFolder: String?
    var rdpPrinters: Bool?
    var rdpSmartCards: Bool?
    var rdpUSBDevices: Bool?
    var rdpNetworkProfile: RDPNetworkProfile?
    var rdpGraphicsAcceleration: Bool?
    var rdpCertificatePolicy: RDPCertificatePolicy?
    var rdpAdminSession: Bool?
    var rdpAutoReconnect: Bool?
    var rdpReconnectRetries: Int?

    init(
        id: UUID = UUID(),
        name: String,
        kind: ConnectionKind,
        host: String = "",
        port: Int? = nil,
        username: String = "",
        group: String = "Ungrouped",
        isFavorite: Bool = false,
        createdAt: Date = Date(),
        sshAuthentication: SSHAuthenticationMode? = nil,
        sshIdentityFile: String? = nil,
        sshJumpHost: String? = nil,
        sshForwardAgent: Bool? = nil,
        sshCompression: Bool? = nil,
        sshKeepAliveInterval: Int? = nil,
        rdpDomain: String? = nil,
        rdpGatewayHost: String? = nil,
        rdpGatewayUsername: String? = nil,
        rdpDisplayMode: RDPDisplayMode? = nil,
        rdpWidth: Int? = nil,
        rdpHeight: Int? = nil,
        rdpScale: Int? = nil,
        rdpClipboard: Bool? = nil,
        rdpAudioMode: RDPAudioMode? = nil,
        rdpMicrophone: Bool? = nil,
        rdpRedirectHome: Bool? = nil,
        rdpSharedFolder: String? = nil,
        rdpPrinters: Bool? = nil,
        rdpSmartCards: Bool? = nil,
        rdpUSBDevices: Bool? = nil,
        rdpNetworkProfile: RDPNetworkProfile? = nil,
        rdpGraphicsAcceleration: Bool? = nil,
        rdpCertificatePolicy: RDPCertificatePolicy? = nil,
        rdpAdminSession: Bool? = nil,
        rdpAutoReconnect: Bool? = nil,
        rdpReconnectRetries: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.host = host
        self.port = port ?? kind.defaultPort
        self.username = username
        self.group = group.isEmpty ? "Ungrouped" : group
        self.isFavorite = isFavorite
        self.createdAt = createdAt
        self.sshAuthentication = sshAuthentication
        self.sshIdentityFile = sshIdentityFile
        self.sshJumpHost = sshJumpHost
        self.sshForwardAgent = sshForwardAgent
        self.sshCompression = sshCompression
        self.sshKeepAliveInterval = sshKeepAliveInterval
        self.rdpDomain = rdpDomain
        self.rdpGatewayHost = rdpGatewayHost
        self.rdpGatewayUsername = rdpGatewayUsername
        self.rdpDisplayMode = rdpDisplayMode
        self.rdpWidth = rdpWidth
        self.rdpHeight = rdpHeight
        self.rdpScale = rdpScale
        self.rdpClipboard = rdpClipboard
        self.rdpAudioMode = rdpAudioMode
        self.rdpMicrophone = rdpMicrophone
        self.rdpRedirectHome = rdpRedirectHome
        self.rdpSharedFolder = rdpSharedFolder
        self.rdpPrinters = rdpPrinters
        self.rdpSmartCards = rdpSmartCards
        self.rdpUSBDevices = rdpUSBDevices
        self.rdpNetworkProfile = rdpNetworkProfile
        self.rdpGraphicsAcceleration = rdpGraphicsAcceleration
        self.rdpCertificatePolicy = rdpCertificatePolicy
        self.rdpAdminSession = rdpAdminSession
        self.rdpAutoReconnect = rdpAutoReconnect
        self.rdpReconnectRetries = rdpReconnectRetries
    }

    var effectiveSSHAuthentication: SSHAuthenticationMode {
        sshAuthentication ?? .automatic
    }

    var effectiveSSHKeepAliveInterval: Int {
        min(max(sshKeepAliveInterval ?? 30, 0), 3600)
    }

    var effectiveRDPDisplayMode: RDPDisplayMode { rdpDisplayMode ?? .dynamicWindow }
    var effectiveRDPWidth: Int { min(max(rdpWidth ?? 1600, 640), 7680) }
    var effectiveRDPHeight: Int { min(max(rdpHeight ?? 1000, 480), 4320) }
    var effectiveRDPScale: Int { [100, 140, 180].contains(rdpScale ?? 100) ? (rdpScale ?? 100) : 100 }
    var effectiveRDPClipboard: Bool { rdpClipboard ?? true }
    var effectiveRDPAudioMode: RDPAudioMode { rdpAudioMode ?? .local }
    var effectiveRDPNetworkProfile: RDPNetworkProfile { rdpNetworkProfile ?? .automatic }
    var effectiveRDPGraphicsAcceleration: Bool { rdpGraphicsAcceleration ?? true }
    var effectiveRDPCertificatePolicy: RDPCertificatePolicy { rdpCertificatePolicy ?? .trustOnFirstUse }
    var effectiveRDPAutoReconnect: Bool { rdpAutoReconnect ?? true }
    var effectiveRDPReconnectRetries: Int { min(max(rdpReconnectRetries ?? 10, 0), 1000) }

    var endpointDescription: String {
        guard kind != .localShell else { return "This Mac" }
        let userPrefix = username.isEmpty ? "" : "\(username)@"
        return "\(userPrefix)\(host):\(port)"
    }

    static let localShell = RemoteConnection(
        id: UUID(uuidString: "CCB07181-71B7-4B40-B9E3-F5F99392662D")!,
        name: "Local Terminal",
        kind: .localShell,
        group: "Local",
        isFavorite: true
    )
}
