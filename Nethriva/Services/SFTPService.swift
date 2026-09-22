import Darwin
import Foundation

enum SSHConnectionReuse {
    private static let controlDirectoryPath: String = {
        cleanupStaleDirectories()
        let path = "/private/tmp/Nethriva-\(ProcessInfo.processInfo.processIdentifier)"
        do {
            try FileManager.default.createDirectory(
                atPath: path,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        } catch {
            assertionFailure("Could not prepare the SSH control directory: \(error)")
        }
        return path
    }()

    private static var controlPath: String {
        "\(controlDirectoryPath)/%C.socket"
    }

    static var arguments: [String] {
        _ = controlDirectoryPath
        return [
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=600",
            "-o", "ControlPath=\(controlPath)",
        ]
    }

    static func controlKey(for connection: RemoteConnection) -> String {
        [
            connection.host,
            String(connection.port),
            connection.username,
            connection.sshJumpHost ?? "",
        ].joined(separator: "\u{1f}")
    }

    static func shutdown(connection: RemoteConnection) {
        guard connection.kind == .ssh else { return }
        DispatchQueue.global(qos: .utility).async {
            Self.performShutdown(connection: connection)
        }
    }

    static func shutdownAll(connections: [RemoteConnection]) {
        var seen = Set<String>()
        for connection in connections where connection.kind == .ssh {
            guard seen.insert(controlKey(for: connection)).inserted else { continue }
            performShutdown(connection: connection)
        }
        try? FileManager.default.removeItem(atPath: controlDirectoryPath)
    }

    private static func performShutdown(connection: RemoteConnection) {
        let destination = connection.username.isEmpty
            ? connection.host
            : "\(connection.username)@\(connection.host)"
        var arguments = [
            "-p", String(connection.port),
            "-o", "ControlPath=\(controlPath)",
        ]
        if let jumpHost = normalized(connection.sshJumpHost) {
            arguments += ["-J", jumpHost]
        }
        arguments += ["-O", "exit", destination]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    private static func cleanupStaleDirectories() {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: URL(fileURLWithPath: "/private/tmp", isDirectory: true),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        for entry in entries where entry.lastPathComponent.hasPrefix("Nethriva-") {
            let suffix = entry.lastPathComponent.dropFirst("Nethriva-".count)
            guard let pid = Int32(suffix), pid != currentPID else { continue }
            errno = 0
            let processIsAlive = kill(pid, 0) == 0 || errno == EPERM
            guard !processIsAlive else { continue }
            try? fileManager.removeItem(at: entry)
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct SFTPDirectoryListing {
    let path: String
    let items: [SFTPFileItem]
}

struct SFTPFileItem: Identifiable, Hashable {
    let name: String
    let path: String
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let size: Int64?
    let permissions: String
    let modifiedText: String

    var id: String { path }

    var displaySize: String {
        guard !isDirectory, let size else { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

struct SFTPCommandBuilder {
    static func upload(localURL: URL, to remoteDirectory: String, isDirectory: Bool) -> String {
        let options = isDirectory ? "-pR" : "-p"
        return "put \(options) \(quote(localURL.path)) \(quote(join(remoteDirectory, localURL.lastPathComponent)))"
    }

    static func download(item: SFTPFileItem, to localURL: URL) -> String {
        let options = item.isDirectory ? "-pR" : "-p"
        return "get \(options) \(quote(item.path)) \(quote(localURL.path))"
    }

    static func move(remotePath: String, to remoteDirectory: String) -> String {
        "rename \(quote(remotePath)) \(quote(join(remoteDirectory, (remotePath as NSString).lastPathComponent)))"
    }

    private static func join(_ directory: String, _ name: String) -> String {
        guard directory != "/" else { return "/\(name)" }
        guard directory != "." else { return name }
        return (directory as NSString).appendingPathComponent(name)
    }

    private static func quote(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

enum SFTPServiceError: LocalizedError {
    case passwordRequired
    case authenticationFailed
    case hostKeyNotTrusted
    case timedOut
    case commandFailed(String)
    case invalidResponse
    case unsafePath

    var errorDescription: String? {
        switch self {
        case .passwordRequired:
            "This SFTP connection needs a password. Edit the connection and save its password in Keychain."
        case .authenticationFailed:
            "SFTP authentication failed. Check the username, password, key, and authentication mode."
        case .hostKeyNotTrusted:
            "The server identity is not trusted yet. Open its SSH terminal once, verify the fingerprint, and then retry SFTP."
        case .timedOut:
            "The SFTP operation timed out. Check the network and server address."
        case .commandFailed(let message):
            message
        case .invalidResponse:
            "The SFTP server returned a response Nethriva could not understand."
        case .unsafePath:
            "The selected file or folder name contains a control character that cannot be sent safely through SFTP."
        }
    }
}

final class SFTPService: @unchecked Sendable {
    private let sftpExecutablePath: String

    init(sftpExecutablePath: String = "/usr/bin/sftp") {
        self.sftpExecutablePath = sftpExecutablePath
    }

    func list(
        connection: RemoteConnection,
        password: String?,
        path: String
    ) async throws -> SFTPDirectoryListing {
        let output = try await execute(
            connection: connection,
            password: password,
            commands: ["cd \(quote(path))", "pwd", "ls -lan"]
        )

        guard let resolvedPath = parseWorkingDirectory(from: output) else {
            throw SFTPServiceError.invalidResponse
        }
        let items = parseListing(output, parentPath: resolvedPath)
        return SFTPDirectoryListing(path: resolvedPath, items: items)
    }

    func upload(
        localURLs: [URL],
        to remoteDirectory: String,
        connection: RemoteConnection,
        password: String?
    ) async throws {
        let commands = localURLs.map { url in
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            return SFTPCommandBuilder.upload(
                localURL: url,
                to: remoteDirectory,
                isDirectory: isDirectory.boolValue
            )
        }
        _ = try await execute(connection: connection, password: password, commands: commands)
    }

    func download(
        item: SFTPFileItem,
        to localURL: URL,
        connection: RemoteConnection,
        password: String?
    ) async throws {
        _ = try await execute(
            connection: connection,
            password: password,
            commands: [SFTPCommandBuilder.download(item: item, to: localURL)]
        )
    }

    func move(
        remotePath: String,
        to remoteDirectory: String,
        connection: RemoteConnection,
        password: String?
    ) async throws {
        _ = try await execute(
            connection: connection,
            password: password,
            commands: [SFTPCommandBuilder.move(remotePath: remotePath, to: remoteDirectory)]
        )
    }

    func createDirectory(
        named name: String,
        in remoteDirectory: String,
        connection: RemoteConnection,
        password: String?
    ) async throws {
        _ = try await execute(
            connection: connection,
            password: password,
            commands: ["mkdir \(quote(join(remoteDirectory, name)))"]
        )
    }

    func rename(
        item: SFTPFileItem,
        to newName: String,
        connection: RemoteConnection,
        password: String?
    ) async throws {
        let parent = (item.path as NSString).deletingLastPathComponent
        _ = try await execute(
            connection: connection,
            password: password,
            commands: ["rename \(quote(item.path)) \(quote(join(parent, newName)))"]
        )
    }

    func delete(
        item: SFTPFileItem,
        connection: RemoteConnection,
        password: String?
    ) async throws {
        let command = item.isDirectory ? "rmdir" : "rm"
        _ = try await execute(
            connection: connection,
            password: password,
            commands: ["\(command) \(quote(item.path))"]
        )
    }

    private func execute(
        connection: RemoteConnection,
        password: String?,
        commands: [String]
    ) async throws -> String {
        try Self.validate(commands: commands)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try self.runExpect(
                        connection: connection,
                        password: password,
                        commands: commands
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func runExpect(
        connection: RemoteConnection,
        password: String?,
        commands: [String]
    ) throws -> String {
        let process = Process()
        let outputPipe = Pipe()
        let passwordPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/expect")
        process.arguments = ["-c", Self.expectScript]
        process.standardInput = passwordPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        let sftpArguments = sftpArguments(for: connection)
        process.environment = Self.expectEnvironment(
            base: ProcessInfo.processInfo.environment,
            sftpArguments: sftpArguments,
            commands: commands,
            passwordByteCount: password?.utf8.count ?? 0,
            executablePath: sftpExecutablePath
        )

        try process.run()
        if let password {
            try passwordPipe.fileHandleForWriting.write(contentsOf: Data(password.utf8))
        }
        try passwordPipe.fileHandleForWriting.close()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: outputData, as: UTF8.self)

        if output.contains("__NETHRIVA_HOST_KEY__") {
            throw SFTPServiceError.hostKeyNotTrusted
        }
        if output.contains("__NETHRIVA_PASSWORD_REQUIRED__") {
            throw SFTPServiceError.passwordRequired
        }
        if output.contains("__NETHRIVA_AUTH_FAILED__") {
            throw SFTPServiceError.authenticationFailed
        }
        if output.contains("__NETHRIVA_TIMEOUT__") {
            throw SFTPServiceError.timedOut
        }

        if let message = commandFailure(in: output) {
            throw SFTPServiceError.commandFailed(message)
        }
        guard process.terminationStatus == 0 else {
            let readable = output
                .components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .suffix(3)
                .joined(separator: " ")
            throw SFTPServiceError.commandFailed(readable.isEmpty ? "SFTP exited unexpectedly." : readable)
        }
        return output
    }

    static func expectEnvironment(
        base: [String: String],
        sftpArguments: [String],
        commands: [String],
        passwordByteCount: Int = 0,
        executablePath: String = "/usr/bin/sftp"
    ) -> [String: String] {
        var environment = base
        environment["NETHRIVA_SFTP_COMMAND_COUNT"] = String(commands.count)
        for (index, command) in commands.enumerated() {
            environment["NETHRIVA_SFTP_COMMAND_\(index)"] = command
        }
        environment["NETHRIVA_SFTP_PASSWORD_LENGTH"] = String(passwordByteCount)
        environment["NETHRIVA_SFTP_EXECUTABLE"] = executablePath
        environment["NETHRIVA_SFTP_ARG_COUNT"] = String(sftpArguments.count)
        for (index, argument) in sftpArguments.enumerated() {
            environment["NETHRIVA_SFTP_ARG_\(index)"] = argument
        }
        return environment
    }

    static func validate(commands: [String]) throws {
        for command in commands {
            if command.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                throw SFTPServiceError.unsafePath
            }
        }
    }

    private func sftpArguments(for connection: RemoteConnection) -> [String] {
        var arguments = [
            "-P", String(connection.port),
            "-o", "ConnectTimeout=20",
            "-o", "StrictHostKeyChecking=ask",
        ]

        switch connection.effectiveSSHAuthentication {
        case .automatic:
            break
        case .password:
            arguments += [
                "-o", "PreferredAuthentications=keyboard-interactive,password",
                "-o", "PubkeyAuthentication=no",
            ]
        case .publicKey:
            arguments += [
                "-o", "PreferredAuthentications=publickey",
                "-o", "PasswordAuthentication=no",
                "-o", "KbdInteractiveAuthentication=no",
            ]
        }

        if let identityFile = normalized(connection.sshIdentityFile) {
            arguments += ["-i", (identityFile as NSString).expandingTildeInPath]
        }
        if let jumpHost = normalized(connection.sshJumpHost) {
            arguments += ["-J", jumpHost]
        }
        if connection.sshForwardAgent == true {
            arguments.append("-A")
        }
        if connection.sshCompression == true {
            arguments.append("-C")
        }

        arguments += SSHConnectionReuse.arguments

        let destination = connection.username.isEmpty
            ? connection.host
            : "\(connection.username)@\(connection.host)"
        arguments.append(destination)
        return arguments
    }

    func parseWorkingDirectory(from output: String) -> String? {
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = "Remote working directory: "
            guard line.hasPrefix(prefix) else { continue }
            return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    func parseListing(_ output: String, parentPath: String) -> [SFTPFileItem] {
        output.components(separatedBy: .newlines).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let first = line.first, "-dlcbps".contains(first) else { return nil }
            let fields = line.split(maxSplits: 8, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard fields.count == 9 else { return nil }

            let permissions = String(fields[0])
            var name = String(fields[8])
            if permissions.first == "l", let arrow = name.range(of: " -> ") {
                name = String(name[..<arrow.lowerBound])
            }
            guard name != ".", name != ".." else { return nil }

            return SFTPFileItem(
                name: name,
                path: join(parentPath, name),
                isDirectory: permissions.first == "d",
                isSymbolicLink: permissions.first == "l",
                size: Int64(fields[4]),
                permissions: permissions,
                modifiedText: "\(fields[5]) \(fields[6]) \(fields[7])"
            )
        }
        .sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func commandFailure(in output: String) -> String? {
        let failureMarkers = [
            "Permission denied",
            "No such file or directory",
            "Couldn't canonicalize",
            "Couldn't stat",
            "Failure",
        ]
        for line in output.components(separatedBy: .newlines) {
            if failureMarkers.contains(where: { line.localizedCaseInsensitiveContains($0) }) {
                return line.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedRemotePath(_ path: String) -> String {
        if path == "." || path.isEmpty { return "." }
        return (path as NSString).standardizingPath
    }

    private func join(_ directory: String, _ name: String) -> String {
        guard directory != "/" else { return "/\(name)" }
        guard directory != "." else { return name }
        return (directory as NSString).appendingPathComponent(name)
    }

    private func quote(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static let expectScript = #"""
    set timeout 60
    log_user 1
    set password_attempts 0
    fconfigure stdin -translation binary -encoding binary
    set password_length $env(NETHRIVA_SFTP_PASSWORD_LENGTH)
    set password ""
    if {$password_length > 0} {
        set password [read stdin $password_length]
    }
    set sftp_args {}
    for {set index 0} {$index < $env(NETHRIVA_SFTP_ARG_COUNT)} {incr index} {
        set key "NETHRIVA_SFTP_ARG_$index"
        lappend sftp_args $env($key)
    }
    set commands {}
    for {set index 0} {$index < $env(NETHRIVA_SFTP_COMMAND_COUNT)} {incr index} {
        set key "NETHRIVA_SFTP_COMMAND_$index"
        lappend commands $env($key)
    }
    set command_index 0
    set sent_quit 0
    spawn -noecho $env(NETHRIVA_SFTP_EXECUTABLE) {*}$sftp_args
    expect {
        -re "(?i)are you sure you want to continue connecting" {
            puts "__NETHRIVA_HOST_KEY__"
            send -- "no\r"
            exit 71
        }
        -re "(?i)host key verification failed" {
            puts "__NETHRIVA_HOST_KEY__"
            exit 71
        }
        -re "(?i)(password|passphrase).*:" {
            incr password_attempts
            if {$password_attempts > 1} {
                puts "__NETHRIVA_AUTH_FAILED__"
                exit 72
            }
            if {$password eq ""} {
                puts "__NETHRIVA_PASSWORD_REQUIRED__"
                exit 73
            }
            send -- "$password\r"
            exp_continue
        }
        -re "(?i)permission denied" {
            puts "__NETHRIVA_AUTH_FAILED__"
            exit 72
        }
        -re "sftp> $" {
            if {$command_index < [llength $commands]} {
                set command [lindex $commands $command_index]
                incr command_index
                send -- "$command\r"
                exp_continue
            }
            if {!$sent_quit} {
                set sent_quit 1
                send -- "quit\r"
                exp_continue
            }
        }
        timeout {
            puts "__NETHRIVA_TIMEOUT__"
            exit 74
        }
        eof {}
    }
    catch wait result
    exit [lindex $result 3]
    """#
}
