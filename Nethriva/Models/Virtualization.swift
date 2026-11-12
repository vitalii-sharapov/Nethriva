import Foundation

enum VirtualizationPlatform: String, Codable, CaseIterable, Identifiable {
    case proxmox, vmware, libvirt, hyperv, xenOrchestra, nutanix
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .proxmox: "Proxmox VE"
        case .vmware: "VMware ESXi / vCenter"
        case .libvirt: "QEMU / KVM (libvirt)"
        case .hyperv: "Microsoft Hyper-V"
        case .xenOrchestra: "XCP-ng / XenServer (Xen Orchestra)"
        case .nutanix: "Nutanix AHV (Prism Central)"
        }
    }
    var usesSSH: Bool { self == .libvirt || self == .hyperv }
    var defaultPort: Int {
        switch self {
        case .proxmox: 8006
        case .nutanix: 9440
        case .libvirt, .hyperv: 22
        default: 443
        }
    }
}

enum ConsoleTransport: String, Codable, CaseIterable, Identifiable {
    case tcp, tls, webSocket
    var id: String { rawValue }
    var displayName: String {
        switch self { case .tcp: "Direct TCP"; case .tls: "TLS-wrapped TCP"; case .webSocket: "Secure WebSocket" }
    }
}

/// Persisted configuration contains no passwords, API tokens, or console tickets.
struct VirtualizationConfiguration: Codable, Hashable {
    var platform: VirtualizationPlatform = .proxmox
    var certificatePolicy: RDPCertificatePolicy?
    var toolsImage: String?
    var libvirtURI: String?
    var consoleTransport: ConsoleTransport?
    var consolePath: String?
    var tunnelConnectionID: UUID?
    var viewOnly: Bool?
    var shareClipboard: Bool?
    var useBearerToken: Bool?
    var federation: VMFederationConfiguration?

    var effectiveCertificatePolicy: RDPCertificatePolicy { certificatePolicy ?? .systemValidation }
    var effectiveLibvirtURI: String { libvirtURI ?? "qemu:///system" }

    func validate() throws {
        try federation?.validate()
        let values = [toolsImage, libvirtURI, consolePath].compactMap { $0 }
        guard values.allSatisfy({ $0.count <= 4096 && $0.rangeOfCharacter(from: .controlCharacters) == nil }) else {
            throw VirtualizationError.invalidConfiguration
        }
        if let libvirtURI {
            guard ["qemu:///system", "qemu:///session"].contains(libvirtURI) else {
                throw VirtualizationError.message("Choose the system or session libvirt connection.")
            }
        }
        if let consolePath, !consolePath.hasPrefix("/") {
            throw VirtualizationError.message("The console WebSocket path must start with a slash.")
        }
    }
}

enum VMPowerState: String, Hashable {
    case running, stopped, suspended, unknown
    var displayName: String { rawValue.capitalized }
    static func parse(_ value: String) -> Self {
        switch value.lowercased().replacingOccurrences(of: " ", with: "") {
        case "on", "running", "poweredon", "2": .running
        case "off", "stopped", "shutoff", "poweredoff", "3": .stopped
        case "paused", "suspended", "saved", "6", "9": .suspended
        default: .unknown
        }
    }
}

struct VirtualMachine: Identifiable, Hashable {
    var id: String
    var name: String
    var node: String = ""
    var state: VMPowerState = .unknown
    var guestTools: String = "Unknown"
    var isContainer: Bool = false
    var cdromDevice: String?
    var guestIPs: [String] = []
    var operatingSystem: String = "Not reported"
    var cpuCount: Int?
    var memoryMiB: Int?
}

struct VMSnapshot: Identifiable, Hashable {
    var id: String
    var name: String
    var created: String = "Not reported"
    var current: Bool = false
}

enum VMSnapshotAction: String, CaseIterable {
    case create, delete, revert
    var title: String { rawValue.capitalized + " Snapshot" }
}

struct VMTaskProgress: Equatable {
    var phase: String
    var percent: Int?
    init(_ phase: String, percent: Int? = nil) {
        self.phase = phase; self.percent = percent.map { min(100, max(0, $0)) }
    }
}

enum VMAction: String, CaseIterable, Identifiable {
    case start, shutdown, reboot, suspend, resume, reset, powerOff, mountTools, ejectTools, attachISO, ejectISO
    var id: String { rawValue }
    var title: String {
        switch self {
        case .start: "Start"
        case .shutdown: "Shut Down Guest"
        case .reboot: "Restart Guest"
        case .suspend: "Suspend"
        case .resume: "Resume"
        case .reset: "Force Reset"
        case .powerOff: "Force Power Off"
        case .mountTools: "Mount Guest Tools…"
        case .ejectTools: "Eject Guest Tools"
        case .attachISO: "Mount ISO…"
        case .ejectISO: "Eject ISO"
        }
    }
    var requiresConfirmation: Bool { self != .start && self != .resume }
    static func available(for vm: VirtualMachine, platform: VirtualizationPlatform) -> [Self] {
        var result: [Self] = vm.state == .stopped ? [.start] :
            (vm.state == .suspended ? [.resume, .powerOff] :
                (vm.state == .running ? [.shutdown, .reboot, .suspend, .reset, .powerOff] : []))
        if platform == .nutanix { result.removeAll { $0 == .suspend || $0 == .resume } }
        if vm.isContainer { result.removeAll { $0 == .reset } }
        if !vm.isContainer {
            if platform == .vmware && vm.state == .running { result += [.mountTools, .ejectTools] }
            result += [.attachISO, .ejectISO]
            if platform == .libvirt || platform == .proxmox || platform == .hyperv || platform == .xenOrchestra || platform == .nutanix {
                result += [.mountTools]
            }
        }
        return result
    }
}

/// Short-lived authorization exists only in memory and is deliberately not Codable.
struct VMConsoleDescriptor {
    enum Renderer: Equatable { case vnc, spice, hostWeb, hyperv }
    var renderer: Renderer
    var host: String = ""
    var port: Int = 0
    var webSocketURL: URL?
    var certificatePin: VMConsoleCertificatePin?
    var singleUseTicket = false
    var webURL: URL?
    var headers: [String: String] = [:]
    var password: String?
    var username: String?
    var sshHost: RemoteConnection?
    var sshSocketPath: String?
    var vmID: String?
    var usesTLS = false
    var protectsCredentials: Bool {
        usesTLS || webSocketURL?.scheme?.lowercased() == "wss" || sshHost != nil
    }
}

enum VirtualizationError: LocalizedError {
    case invalidConfiguration, invalidResponse, authentication, forbidden, unavailable, cancelled
    case http(Int)
    case message(String)
    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Check the host address, port, and virtualization settings."
        case .invalidResponse: "The host returned an unexpected response. Check the selected platform and server version."
        case .authentication: "Authentication failed. Check the host credentials and account realm."
        case .forbidden: "This account does not have permission for the requested VM operation."
        case .unavailable: "This operation is not available for this platform or VM."
        case .cancelled: "The connection was cancelled."
        case .http(let code): "The host request failed (HTTP \(code))."
        case .message(let message): message
        }
    }
}

enum VMInput {
    static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 512
            && value.rangeOfCharacter(from: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_:.")).inverted) == nil
    }
    static func shellQuote(_ value: String) throws -> String {
        guard value.count <= 4096, value.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw VirtualizationError.invalidConfiguration
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
    static func xml(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
    static func endpoint(for connection: RemoteConnection) throws -> URL {
        let host = connection.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !host.contains("/"), !host.contains("@"), !host.hasPrefix("-"),
              host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              (1...65535).contains(connection.port) else { throw VirtualizationError.invalidConfiguration }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        components.port = connection.port
        guard let url = components.url else { throw VirtualizationError.invalidConfiguration }
        return url
    }
}
