import CryptoKit
import Foundation
import Security

struct ConnectionArchiveCredential: Codable, Equatable {
    let connectionID: UUID
    let password: String
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

    init(
        exportedAt: Date = Date(),
        groups: [String],
        connections: [RemoteConnection],
        credentials: [ConnectionArchiveCredential] = []
    ) {
        format = Self.formatIdentifier
        schemaVersion = Self.currentSchemaVersion
        self.exportedAt = exportedAt
        self.groups = groups
        self.connections = connections
        self.credentials = credentials
    }

    var includesCredentials: Bool { !credentials.isEmpty }
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
            "Use an export password containing at least eight characters."
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
    static let defaultIterations = 250_000

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
        return try configuredEncoder().encode(archive)
    }

    static func encodeEncrypted(
        _ archive: ConnectionArchive,
        password: String,
        iterations: Int = defaultIterations
    ) throws -> Data {
        guard password.count >= 8 else { throw ConnectionTransferError.passwordTooShort }
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
        return try configuredEncoder().encode(envelope)
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

    static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
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
        guard allowsCredentials || archive.credentials.isEmpty else {
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
                (1...65_535).contains(connection.port)
        }) else {
            throw ConnectionTransferError.invalidArchiveContent("one or more connection records are malformed")
        }
        guard archive.groups.allSatisfy({ group in
            !group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && group.count <= 1_024
        }) else {
            throw ConnectionTransferError.invalidArchiveContent("one or more group names are malformed")
        }

        let credentialIDs = archive.credentials.map(\.connectionID)
        guard Set(credentialIDs).count == credentialIDs.count,
              Set(credentialIDs).isSubset(of: Set(connectionIDs)),
              archive.credentials.allSatisfy({ $0.password.utf8.count <= 65_536 }) else {
            throw ConnectionTransferError.invalidArchiveContent("the credential records do not match the connections")
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
        guard iterations > 0 else { throw ConnectionTransferError.invalidArchive }
        let normalizedPassword = password.precomposedStringWithCanonicalMapping
        let passwordKey = SymmetricKey(data: Data(normalizedPassword.utf8))
        var saltAndIndex = salt
        var blockIndex = UInt32(1).bigEndian
        withUnsafeBytes(of: &blockIndex) { saltAndIndex.append(contentsOf: $0) }

        var previous = Data(HMAC<SHA256>.authenticationCode(for: saltAndIndex, using: passwordKey))
        var result = [UInt8](previous)
        if iterations > 1 {
            for _ in 1..<iterations {
                previous = Data(HMAC<SHA256>.authenticationCode(for: previous, using: passwordKey))
                for index in result.indices {
                    result[index] ^= previous[index]
                }
            }
        }
        return SymmetricKey(data: Data(result.prefix(32)))
    }
}
