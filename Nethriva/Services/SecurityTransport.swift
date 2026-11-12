import AppKit
import Darwin
import Foundation

enum ConsoleCredentialPolicy {
    static func permitsAutomaticCredentials(for connection: RemoteConnection) -> Bool {
        guard connection.kind == .vnc || connection.kind == .spice else { return true }
        let config = connection.virtualization
        return config?.consoleTransport == .tls || config?.consoleTransport == .webSocket
            || config?.tunnelConnectionID != nil
    }
}

@MainActor
enum ConnectionSecurityConsent {
    static func requiresRDPConfirmation(_ connection: RemoteConnection) -> Bool {
        connection.effectiveRDPCertificatePolicy == .ignore || connection.effectiveRDPSecurityMode == .legacyRDP
    }
    static func confirmRDP(_ connection: RemoteConnection) -> Bool {
        guard requiresRDPConfirmation(connection) else { return !CredentialAccessGate.shared.isLocked }
        return confirm(title: "Connect without verified server identity?",
            message: "This connection uses ignored certificate checks or legacy RDP security. An impostor could receive your authentication and session data. Use only with a separately verified, protected route. This approval applies only to this session.",
            action: "Connect This Session")
    }
    static func confirmUnverifiedHost(_ connection: RemoteConnection) -> Bool {
        guard connection.virtualization?.effectiveCertificatePolicy == .ignore else { return !CredentialAccessGate.shared.isLocked }
        return confirm(title: "Connect without verifying this host?",
            message: "Certificate verification is disabled. An impostor could receive this host's credentials. This approval applies only to this session.", action: "Connect This Session")
    }
    static func confirmUnencryptedCredential() -> Bool {
        confirm(title: "Send a password without encryption?",
            message: "This direct console transport is unencrypted. Anyone observing the exposed network path may obtain the password and session data. The password will be sent once and will not be saved. Prefer verified TLS, secure WebSocket or an appropriate SSH tunnel.",
            action: "Send Once Without Encryption")
    }
    private static func confirm(title: String, message: String, action: String) -> Bool {
        guard !CredentialAccessGate.shared.isLocked else { return false }
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: action)
        return alert.runModal() == .alertSecondButtonReturn && !CredentialAccessGate.shared.isLocked
    }
}

enum RDPCertificateStorage {
    static func directory() throws -> URL {
        let base: URL
        if NethrivaDataProfile.isTesting {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("Nethriva-RDP-Tests-\(ProcessInfo.processInfo.processIdentifier)")
        } else {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
            base = support.appendingPathComponent(NethrivaDataProfile.isDevelopment ? "NethrivaDevelopment" : "Nethriva")
        }
        try prepare(base, requiresPrivateAccess: false)
        let directory = base.appendingPathComponent("RDPCertificates", isDirectory: true)
        try prepare(directory)
        return directory
    }
    /// Never chmod or follow a pre-existing link. Refuse unsafe ownership/modes.
    static func prepare(_ directory: URL, requiresPrivateAccess: Bool = true) throws {
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { throw EmbeddedRDPError.loadFailed("The private RDP certificate directory could not be created.") }
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw EmbeddedRDPError.loadFailed("The RDP certificate directory is not a safe private folder.") }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o022 == 0, (!requiresPrivateAccess || info.st_mode & 0o077 == 0),
              info.st_mode & 0o700 == 0o700 else {
            throw EmbeddedRDPError.loadFailed("The RDP certificate directory must be owned by you with private read/write access. Existing trust records were preserved.")
        }
    }
}
