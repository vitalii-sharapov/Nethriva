import CommonCrypto
import CryptoKit
import Darwin
import Foundation
import Security

struct ConnectionArchiveCredential: Codable, Equatable {
    let connectionID: UUID
    let password: String
}

struct CredentialProfileSecret: Codable, Equatable {
    let profileID: UUID
    let password: String
}

/// Local review decisions, never decoded from an archive or exported.
struct ConnectionImportOptions {
    var approvedCapabilities: Set<UUID> = []
    var approvedCredentialReuse: Set<UUID> = []
}

enum ConnectionImportSecurity {
    static func capabilities(_ connection: RemoteConnection) -> [String] {
        var values: [String] = []
        if connection.sshForwardAgent == true { values.append("SSH agent forwarding") }
        if connection.sshIdentityFile?.isEmpty == false { values.append("Local SSH identity file: " + (connection.sshIdentityFile ?? "")) }
        if connection.sshX11?.mode != nil, connection.sshX11?.mode != .off { values.append("X11 forwarding") }
        if connection.kind == .rdp {
            if connection.effectiveRDPClipboard { values.append("Clipboard sharing") }
            if connection.rdpMicrophone == true { values.append("Microphone") }
            if connection.rdpRedirectHome == true { values.append("Home-folder access") }
            if let folder = connection.rdpSharedFolder, !folder.isEmpty { values.append("Local folder: " + folder) }
            if connection.rdpPrinters == true { values.append("Printers") }
            if connection.rdpSmartCards == true { values.append("Smart cards") }
            if connection.rdpUSBDevices == true { values.append("USB devices") }
            if connection.effectiveRDPCertificatePolicy != .systemValidation { values.append("Non-system RDP certificate trust") }
            if connection.effectiveRDPSecurityMode != .nla { values.append("RDP security compatibility mode") }
        }
        if let configuration = connection.virtualization {
            if configuration.shareClipboard == true { values.append("Console clipboard sharing") }
            if configuration.effectiveCertificatePolicy != .systemValidation { values.append("Non-system API certificate trust") }
            if configuration.tunnelConnectionID != nil { values.append("Tunnel through a saved SSH connection") }
            if configuration.federation != nil { values.append("External sign-in endpoints") }
        }
        return values
    }

    static func restricted(_ connection: RemoteConnection) -> RemoteConnection {
        var safe = connection
        safe.sshForwardAgent = false
        safe.sshIdentityFile = nil
        safe.sshX11 = nil
        if safe.kind == .rdp {
            safe.rdpClipboard = false
            safe.rdpMicrophone = false
            safe.rdpRedirectHome = false
            safe.rdpSharedFolder = nil
            safe.rdpPrinters = false
            safe.rdpSmartCards = false
            safe.rdpUSBDevices = false
            safe.rdpCertificatePolicy = .systemValidation
            safe.rdpSecurityMode = .nla
        }
        if var configuration = safe.virtualization {
            configuration.shareClipboard = false
            configuration.certificatePolicy = .systemValidation
            configuration.tunnelConnectionID = nil
            configuration.federation = nil
            safe.virtualization = configuration
        }
        return safe
    }

    /// Only benign presentation changes may retain a saved credential automatically.
    static func sameCredentialIdentity(_ lhs: RemoteConnection, _ rhs: RemoteConnection) -> Bool {
        let leftX11 = lhs.sshX11 ?? SSHX11Configuration()
        let rightX11 = rhs.sshX11 ?? SSHX11Configuration()
        return lhs.kind == rhs.kind && lhs.host == rhs.host && lhs.port == rhs.port
            && lhs.username == rhs.username && lhs.credentialProfileID == rhs.credentialProfileID
            && lhs.effectiveSSHAuthentication == rhs.effectiveSSHAuthentication && lhs.sshIdentityFile == rhs.sshIdentityFile
            && lhs.sshJumpHost == rhs.sshJumpHost && (lhs.sshForwardAgent == true) == (rhs.sshForwardAgent == true)
            && leftX11.mode == rightX11.mode && (leftX11.mode == .off || leftX11.display == rightX11.display)
            && lhs.rdpDomain == rhs.rdpDomain
            && lhs.rdpGatewayHost == rhs.rdpGatewayHost && lhs.rdpGatewayUsername == rhs.rdpGatewayUsername
            && lhs.effectiveRDPCertificatePolicy == rhs.effectiveRDPCertificatePolicy
            && lhs.effectiveRDPSecurityMode == rhs.effectiveRDPSecurityMode
            && lhs.rdpVirtualMachineID == rhs.rdpVirtualMachineID && sameVirtualizationIdentity(lhs.virtualization, rhs.virtualization)
    }

    private static func sameVirtualizationIdentity(_ lhs: VirtualizationConfiguration?, _ rhs: VirtualizationConfiguration?) -> Bool {
        guard let lhs, let rhs else { return lhs == rhs }
        return lhs.platform == rhs.platform && lhs.effectiveCertificatePolicy == rhs.effectiveCertificatePolicy
            && lhs.effectiveLibvirtURI == rhs.effectiveLibvirtURI && lhs.consoleTransport == rhs.consoleTransport
            && lhs.consolePath == rhs.consolePath && lhs.tunnelConnectionID == rhs.tunnelConnectionID
            && (lhs.useBearerToken == true) == (rhs.useBearerToken == true) && lhs.federation == rhs.federation
    }
}

struct ConnectionArchive: Codable, Equatable {
    static let formatIdentifier = "com.vitalii.nethriva.connections"
    static let currentSchemaVersion = 1

    let format: String
    let schemaVersion: Int
    let exportedAt: Date
    let groups: [String]
    let connections: [RemoteConnection]
    let credentials: [ConnectionArchiveCredential]
    let profiles: [CredentialProfile]
    let profileCredentials: [CredentialProfileSecret]

    private enum CodingKeys: String, CodingKey {
        case format, schemaVersion, exportedAt, groups, connections, credentials
        case profiles, profileCredentials
    }

    init(
        exportedAt: Date = Date(),
        groups: [String],
        connections: [RemoteConnection],
        credentials: [ConnectionArchiveCredential] = [],
        profiles: [CredentialProfile] = [],
        profileCredentials: [CredentialProfileSecret] = []
    ) {
        format = Self.formatIdentifier
        schemaVersion = Self.currentSchemaVersion
        self.exportedAt = exportedAt
        self.groups = groups
        self.connections = connections
        self.credentials = credentials
        self.profiles = profiles
        self.profileCredentials = profileCredentials
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(String.self, forKey: .format)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        exportedAt = try container.decode(Date.self, forKey: .exportedAt)
        groups = try container.decode([String].self, forKey: .groups)
        connections = try container.decode([RemoteConnection].self, forKey: .connections)
        credentials = try container.decodeIfPresent([ConnectionArchiveCredential].self, forKey: .credentials) ?? []
        profiles = try container.decodeIfPresent([CredentialProfile].self, forKey: .profiles) ?? []
        profileCredentials = try container.decodeIfPresent([CredentialProfileSecret].self, forKey: .profileCredentials) ?? []
    }

    var includesCredentials: Bool { !credentials.isEmpty || !profileCredentials.isEmpty }
}

struct ConnectionArchiveInspection {
    enum Content {
        case plain(ConnectionArchive)
        case encrypted
    }

    let content: Content
}

enum ConnectionTransferError: LocalizedError, Equatable {
    case fileTooLarge
    case invalidArchive
    case unsupportedSchema(Int)
    case plaintextCredentials
    case passwordRequired
    case passwordTooShort
    case incorrectPassword
    case invalidArchiveContent(String)
    case randomGenerationFailed

    var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            "The selected archive is too large to be a Nethriva connection export."
        case .invalidArchive:
            "The selected file is not a valid Nethriva connection archive."
        case .unsupportedSchema(let version):
            "This archive uses unsupported schema version \(version)."
        case .plaintextCredentials:
            "Nethriva will not write credentials to an unencrypted archive."
        case .passwordRequired:
            "Enter the archive password."
        case .passwordTooShort:
            "Use an export passphrase containing at least 15 characters."
        case .incorrectPassword:
            "The password is incorrect or the encrypted archive has been modified."
        case .invalidArchiveContent(let message):
            "The archive contains invalid data: \(message)"
        case .randomGenerationFailed:
            "Secure random data could not be generated for encryption."
        }
    }
}

enum ConnectionTransferService {
    static let plainFilenameExtension = "nethriva"
    static let encryptedFilenameExtension = "nethriva-secure"
    static let defaultIterations = 600_000
    static let minimumExportPasswordLength = 15

    static func validExportPassword(_ password: String) -> Bool {
        password.precomposedStringWithCanonicalMapping.unicodeScalars.count >= minimumExportPasswordLength
            && password.utf8.count <= 65_536
    }

    static func validateForImport(_ archive: ConnectionArchive) throws {
        try validate(archive, allowsCredentials: true)
    }

    private static let encryptedFormatIdentifier = "com.vitalii.nethriva.connections.encrypted"
    private static let maximumArchiveSize = 25 * 1_024 * 1_024
    private static let authenticatedData = Data("NethrivaConnectionArchive/v1".utf8)

    private struct ArchiveProbe: Decodable {
        let format: String
        let schemaVersion: Int
    }

    private struct EncryptedEnvelope: Codable {
        let format: String
        let schemaVersion: Int
        let encryption: String
        let keyDerivation: String
        let iterations: Int
        let salt: Data
        let sealedPayload: Data
    }

    static func inspect(_ data: Data) throws -> ConnectionArchiveInspection {
        try validateFileSize(data)
        let decoder = configuredDecoder()
        guard let probe = try? decoder.decode(ArchiveProbe.self, from: data) else {
            throw ConnectionTransferError.invalidArchive
        }

        switch probe.format {
        case ConnectionArchive.formatIdentifier:
            let archive = try decoder.decode(ConnectionArchive.self, from: data)
            try validate(archive, allowsCredentials: false)
            return ConnectionArchiveInspection(content: .plain(archive))
        case encryptedFormatIdentifier:
            guard probe.schemaVersion == ConnectionArchive.currentSchemaVersion else {
                throw ConnectionTransferError.unsupportedSchema(probe.schemaVersion)
            }
            guard (try? decoder.decode(EncryptedEnvelope.self, from: data)) != nil else {
                throw ConnectionTransferError.invalidArchive
            }
            return ConnectionArchiveInspection(content: .encrypted)
        default:
            throw ConnectionTransferError.invalidArchive
        }
    }

    static func encodePlain(_ archive: ConnectionArchive) throws -> Data {
        try validate(archive, allowsCredentials: false)
        let data = try configuredEncoder().encode(archive)
        try validateFileSize(data)
        return data
    }

    static func encodeEncrypted(
        _ archive: ConnectionArchive,
        password: String,
        iterations: Int = defaultIterations
    ) throws -> Data {
        guard validExportPassword(password) else { throw ConnectionTransferError.passwordTooShort }
        try validate(archive, allowsCredentials: true)
        let payload = try configuredEncoder().encode(archive)
        let salt = try secureRandomData(count: 16)
        let key = try deriveKey(password: password, salt: salt, iterations: iterations)
        let sealedBox = try AES.GCM.seal(payload, using: key, authenticating: authenticatedData)
        guard let combined = sealedBox.combined else {
            throw ConnectionTransferError.invalidArchive
        }
        let envelope = EncryptedEnvelope(
            format: encryptedFormatIdentifier,
            schemaVersion: ConnectionArchive.currentSchemaVersion,
            encryption: "AES-256-GCM",
            keyDerivation: "PBKDF2-HMAC-SHA256",
            iterations: iterations,
            salt: salt,
            sealedPayload: combined
        )
        let data = try configuredEncoder().encode(envelope)
        try validateFileSize(data)
        return data
    }

    static func decodeEncrypted(_ data: Data, password: String) throws -> ConnectionArchive {
        guard !password.isEmpty else { throw ConnectionTransferError.passwordRequired }
        try validateFileSize(data)
        let decoder = configuredDecoder()
        guard let envelope = try? decoder.decode(EncryptedEnvelope.self, from: data),
              envelope.format == encryptedFormatIdentifier,
              envelope.encryption == "AES-256-GCM",
              envelope.keyDerivation == "PBKDF2-HMAC-SHA256" else {
            throw ConnectionTransferError.invalidArchive
        }
        guard envelope.schemaVersion == ConnectionArchive.currentSchemaVersion else {
            throw ConnectionTransferError.unsupportedSchema(envelope.schemaVersion)
        }
        guard envelope.salt.count == 16,
              (10_000...2_000_000).contains(envelope.iterations) else {
            throw ConnectionTransferError.invalidArchive
        }

        do {
            let key = try deriveKey(
                password: password,
                salt: envelope.salt,
                iterations: envelope.iterations
            )
            let sealedBox = try AES.GCM.SealedBox(combined: envelope.sealedPayload)
            let payload = try AES.GCM.open(
                sealedBox,
                using: key,
                authenticating: authenticatedData
            )
            let archive = try decoder.decode(ConnectionArchive.self, from: payload)
            try validate(archive, allowsCredentials: true)
            return archive
        } catch let error as ConnectionTransferError {
            throw error
        } catch {
            throw ConnectionTransferError.incorrectPassword
        }
    }

    /// Only bounded regular files are imported. A path cannot turn into a FIFO,
    /// device or symlink between the type check and the read.
    static func read(from url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw ConnectionTransferError.invalidArchive }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0, before.st_size <= maximumArchiveSize else {
            throw ConnectionTransferError.fileTooLarge
        }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(65_536, maximumArchiveSize - data.count + 1)), !chunk.isEmpty {
            guard data.count + chunk.count <= maximumArchiveSize else { throw ConnectionTransferError.fileTooLarge }
            data.append(chunk)
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              data.count == before.st_size else { throw ConnectionTransferError.invalidArchive }
        return data
    }

    /// The save panel authorizes replacing its selected regular file. Keep the
    /// staged archive private from creation, never chmod or follow a destination
    /// symlink, and atomically rename within the held parent directory.
    static func write(_ data: Data, to url: URL) throws {
        try validateFileSize(data)
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw ConnectionTransferError.invalidArchive }
        defer { Darwin.close(parent) }
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { throw ConnectionTransferError.invalidArchive }
        var target = stat()
        if fstatat(parent, name, &target, AT_SYMLINK_NOFOLLOW) == 0 {
            guard target.st_mode & S_IFMT == S_IFREG else { throw ConnectionTransferError.invalidArchive }
        } else if errno != ENOENT { throw ConnectionTransferError.invalidArchive }
        let temporary = ".nethriva-archive-" + UUID().uuidString
        let descriptor = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ConnectionTransferError.invalidArchive }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); _ = unlinkat(parent, temporary, 0) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        // Replacing a symlink would not follow it, but refuse it rather than
        // silently changing the user's choice when another process swaps it.
        if fstatat(parent, name, &target, AT_SYMLINK_NOFOLLOW) == 0 {
            guard target.st_mode & S_IFMT == S_IFREG else { throw ConnectionTransferError.invalidArchive }
        } else if errno != ENOENT { throw ConnectionTransferError.invalidArchive }
        guard renameat(parent, temporary, parent, name) == 0 else { throw ConnectionTransferError.invalidArchive }
    }

    private static func validateFileSize(_ data: Data) throws {
        guard data.count <= maximumArchiveSize else {
            throw ConnectionTransferError.fileTooLarge
        }
    }

    private static func validate(
        _ archive: ConnectionArchive,
        allowsCredentials: Bool
    ) throws {
        guard archive.format == ConnectionArchive.formatIdentifier else {
            throw ConnectionTransferError.invalidArchive
        }
        guard archive.schemaVersion == ConnectionArchive.currentSchemaVersion else {
            throw ConnectionTransferError.unsupportedSchema(archive.schemaVersion)
        }
        guard archive.groups.count <= 10_000, archive.connections.count <= 100_000 else {
            throw ConnectionTransferError.invalidArchiveContent("too many groups or connections")
        }
        guard allowsCredentials || !archive.includesCredentials else {
            throw ConnectionTransferError.plaintextCredentials
        }

        let connectionIDs = archive.connections.map(\.id)
        guard Set(connectionIDs).count == connectionIDs.count else {
            throw ConnectionTransferError.invalidArchiveContent("duplicate connection identifiers")
        }
        guard archive.connections.allSatisfy({ connection in
            connection.kind != .localShell &&
                connection.id != RemoteConnection.localShell.id &&
                !connection.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !connection.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                connection.name.count <= 1_024 &&
                connection.host.count <= 4_096 &&
                connection.username.count <= 4_096 &&
                connection.group.count <= 1_024 &&
                [connection.name, connection.host, connection.username, connection.group].allSatisfy({ $0.rangeOfCharacter(from: .controlCharacters) == nil }) &&
                (connection.kind == .serial
                    ? connection.port == 0 && SerialPortDiscovery.isValidDevicePath(connection.host)
                        && SerialPortConfiguration(connection: connection).isValid
                    : (1...65_535).contains(connection.port))
        }) else {
            throw ConnectionTransferError.invalidArchiveContent("one or more connection records are malformed")
        }
        let profileIDs = archive.profiles.map(\.id)
        let profileIDSet = Set(profileIDs)
        for connection in archive.connections {
            let settings = [connection.sshIdentityFile, connection.sshJumpHost, connection.rdpDomain,
                connection.rdpGatewayHost, connection.rdpGatewayUsername, connection.rdpSharedFolder, connection.rdpVirtualMachineID].compactMap { $0 }
            guard settings.allSatisfy({ $0.utf8.count <= 16_384 && $0.rangeOfCharacter(from: .controlCharacters) == nil }) else {
                throw ConnectionTransferError.invalidArchiveContent("invalid connection option text")
            }
            if connection.kind == .ssh {
                do { try SSHInputValidation.validate(connection) }
                catch { throw ConnectionTransferError.invalidArchiveContent("invalid SSH connection options") }
            }
            if let x11 = connection.sshX11 {
                guard connection.kind == .ssh, x11.mode == .off || SSHX11Configuration.validDisplay(x11.display) else {
                    throw ConnectionTransferError.invalidArchiveContent("invalid local X11 display settings")
                }
            }
            guard connection.inheritedFields?.isEmpty != false else {
                throw ConnectionTransferError.invalidArchiveContent("archives must contain materialized settings, not live group-inheritance rules")
            }
            guard connection.terminalProfileID == nil else {
                throw ConnectionTransferError.invalidArchiveContent("archives must embed terminal appearance, not local profile references")
            }
            do { try connection.terminalAppearance?.validate() }
            catch { throw ConnectionTransferError.invalidArchiveContent("invalid terminal appearance") }
        }
        for connection in archive.connections where connection.virtualization != nil {
            do {
                try connection.virtualization?.validate()
                _ = try VMInput.endpoint(for: connection)
            } catch {
                throw ConnectionTransferError.invalidArchiveContent("invalid virtualization or console settings")
            }
        }
        guard archive.profiles.count <= 100_000,
              profileIDSet.count == profileIDs.count,
              profileIDSet.isDisjoint(with: Set(connectionIDs)),
              archive.profiles.allSatisfy({ profile in
                  !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !profile.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && profile.name.count <= 1_024
                    && profile.username.count <= 4_096
                    && profile.domain.count <= 4_096
                    && [profile.name, profile.username, profile.domain].allSatisfy({ $0.rangeOfCharacter(from: .controlCharacters) == nil })
              }),
              archive.connections.allSatisfy({ connection in
                  guard let profileID = connection.credentialProfileID else { return true }
                  return connection.kind != .serial && profileIDSet.contains(profileID)
              }) else {
            throw ConnectionTransferError.invalidArchiveContent("credential profiles or links are malformed")
        }
        guard archive.groups.allSatisfy({ group in
            !group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && group.count <= 1_024
                && group.rangeOfCharacter(from: .controlCharacters) == nil
        }) else {
            throw ConnectionTransferError.invalidArchiveContent("one or more group names are malformed")
        }

        let credentialIDs = archive.credentials.map(\.connectionID)
        let credentialEligibleIDs = Set(archive.connections.filter {
            $0.kind != .serial && $0.credentialProfileID == nil
        }.map(\.id))
        guard Set(credentialIDs).count == credentialIDs.count,
              Set(credentialIDs).isSubset(of: credentialEligibleIDs),
              archive.credentials.allSatisfy({ $0.password.utf8.count <= 65_536 }) else {
            throw ConnectionTransferError.invalidArchiveContent("the credential records do not match the connections")
        }
        let profileCredentialIDs = archive.profileCredentials.map(\.profileID)
        guard Set(profileCredentialIDs).count == profileCredentialIDs.count,
              Set(profileCredentialIDs).isSubset(of: Set(profileIDs)),
              archive.profileCredentials.allSatisfy({ $0.password.utf8.count <= 65_536 }) else {
            throw ConnectionTransferError.invalidArchiveContent("profile passwords do not match the profiles")
        }
    }

    private static func configuredEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func configuredDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func secureRandomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw ConnectionTransferError.randomGenerationFailed
        }
        return data
    }

    private static func deriveKey(
        password: String,
        salt: Data,
        iterations: Int
    ) throws -> SymmetricKey {
        guard (10_000...2_000_000).contains(iterations) else { throw ConnectionTransferError.invalidArchive }
        var key = try ConnectionArchiveKDF.derive(password: password, salt: salt, iterations: iterations)
        defer { key.resetBytes(in: 0..<key.count) }
        return SymmetricKey(data: key)
    }
}

/// PBKDF2 is supplied by macOS CommonCrypto. The archive format retains NFC
/// normalization and a 256-bit key for compatibility with older exports.
enum ConnectionArchiveKDF {
    static func derive(password: String, salt: Data, iterations: Int) throws -> Data {
        let passwordBytes = Array(password.precomposedStringWithCanonicalMapping.utf8)
        guard !passwordBytes.isEmpty, passwordBytes.count <= 65_536,
              !salt.isEmpty, salt.count <= 1024, (1...2_000_000).contains(iterations) else {
            throw ConnectionTransferError.invalidArchive
        }
        var output = Data(count: 32)
        let status = passwordBytes.withUnsafeBytes { passwordBuffer in
            salt.withUnsafeBytes { saltBuffer in
                output.withUnsafeMutableBytes { keyBuffer in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBuffer.baseAddress!.assumingMemoryBound(to: CChar.self), passwordBytes.count,
                        saltBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                        keyBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self), keyBuffer.count)
                }
            }
        }
        guard status == kCCSuccess else {
            output.resetBytes(in: 0..<output.count)
            throw ConnectionTransferError.invalidArchive
        }
        return output
    }
}
