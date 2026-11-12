import Darwin
import CryptoKit
import Foundation

/// An unpredictable, inode-bound directory. Never adopts or recursively removes
/// a path supplied by another process, including stale directories from other runs.
final class SSHControlDirectory {
    let url: URL
    private let descriptor: Int32
    private let device: dev_t
    private let inode: ino_t
    init(parent: URL = URL(fileURLWithPath: "/private/tmp")) throws {
        var template = Array(parent.appendingPathComponent("ns-XXXXXX").path.utf8CString)
        guard mkdtemp(&template) != nil else { throw SFTPServiceError.unsafePath }
        let path = String(cString: template)
        let fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { _ = rmdir(path); throw SFTPServiceError.unsafePath }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
            Darwin.close(fd); _ = rmdir(path); throw SFTPServiceError.unsafePath
        }
        url = URL(fileURLWithPath: path); descriptor = fd
        device = info.st_dev; inode = info.st_ino
    }
    deinit { Darwin.close(descriptor) }
    func validate() throws {
        var current = stat(), held = stat()
        guard lstat(url.path, &current) == 0, fstat(descriptor, &held) == 0,
              current.st_mode & S_IFMT == S_IFDIR, current.st_uid == getuid(),
              current.st_mode & 0o777 == 0o700, current.st_dev == device, current.st_ino == inode,
              held.st_dev == device, held.st_ino == inode else { throw SFTPServiceError.unsafePath }
    }
    func removeIfEmpty() {
        guard (try? validate()) != nil else { return }
        // rmdir cannot follow a symlink or recursively delete unexpected contents.
        _ = rmdir(url.path)
    }
}

enum SSHInputValidation {
    static func validate(_ connection: RemoteConnection) throws {
        let host = connection.host, user = connection.username
        guard !host.isEmpty, host.utf8.count <= 4096, !host.hasPrefix("-"),
              !host.contains("@"), !host.contains("/"),
              host.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              !user.hasPrefix("-"), user.utf8.count <= 4096,
              user.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              (1...65535).contains(connection.port) else { throw SFTPServiceError.unsafePath }
        if let identity = connection.sshIdentityFile {
            guard identity.utf8.count <= 4096, identity.rangeOfCharacter(from: .controlCharacters) == nil else { throw SFTPServiceError.unsafePath }
        }
        if let jump = connection.sshJumpHost, !jump.isEmpty { _ = try SSHJumpChain.validate(jump) }
    }
}

enum SSHCredentialPromptGuard {
    static func validate(_ value: String?) throws {
        guard let value else { return }
        guard value.utf8.count <= 65536, value.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw SFTPServiceError.commandFailed("The saved SSH password is too long or contains characters unsupported by the SSH password prompt.")
        }
    }
    // Only OpenSSH's local read_passphrase may authorize automatic secret
    // submission. Text printed by a banner or -T remote command cannot turn
    // off the local SSH-owned tty's ECHO flag. Failure to inspect it denies.
    static let expectScript = #"""
    set nethriva_credential_tty $spawn_out(slave,name)
    proc nethriva_credential_prompt {} {
        global nethriva_credential_tty
        if {[catch {exec /bin/stty -f $nethriva_credential_tty -a} attributes]} { return 0 }
        return [regexp -- {(^|[[:space:];])-echo($|[[:space:];])} $attributes]
    }
    """#
}

enum SSHConnectionReuse {
    private static let directory = Result { try SSHControlDirectory() }
    private static let registryLock = NSLock()
    private static var registered: [String: Set<String>] = [:]
    private static var contextTokens: [String: String] = [:]
    private static var lastContextToken: UInt64 = 0
    static func controlDirectory() throws -> URL {
        let value = try directory.get(); try value.validate(); return value.url
    }
    static func controlPath(for connection: RemoteConnection) throws -> String {
        let root = try controlDirectory()
        // %C also distinguishes the effective OpenSSH alias/jump target. A
        // separate identity hash prevents an authenticated master being reused
        // with another key, profile, auth policy or forwarding context.
        let key = controlKey(for: connection)
        let identity = ((connection.sshIdentityFile ?? "") as NSString).expandingTildeInPath
        let context = [key, fileIdentity(identity),
            fileIdentity(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config").path),
            fileIdentity("/etc/ssh/ssh_config")]
        let digest = SHA256.hash(data: try JSONEncoder().encode(context)).map { String(format: "%02x", $0) }.joined()
        return try registryLock.withLock {
            // Preserve the full identity/context hash in this process's map.
            // A short, never-reused token leaves room for OpenSSH's expanded
            // %C plus its temporary ".<16 random characters>" bind suffix.
            let token: String
            if let existing = contextTokens[digest] {
                token = existing
            } else {
                guard lastContextToken < UInt64.max else { throw SFTPServiceError.unsafePath }
                lastContextToken += 1
                token = String(format: "%016llx", lastContextToken)
                contextTokens[digest] = token
            }
            let path = root.appendingPathComponent(token + "-%C.s").path
            let expanded = path.replacingOccurrences(of: "%C", with: String(repeating: "0", count: 40))
            let capacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
            guard expanded.utf8.count + 17 < capacity else { throw SFTPServiceError.unsafePath }
            _ = registered[key, default: []].insert(path)
            return path
        }
    }
    static func registeredControlPaths(for connection: RemoteConnection) -> [String] {
        registryLock.withLock { Array(registered[controlKey(for: connection)] ?? []).sorted() }
    }

    static func ownsControlSocket(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let root = try? controlDirectory() else { return false }
        let name = url.deletingPathExtension().lastPathComponent.split(separator: "-", omittingEmptySubsequences: false)
        guard url.deletingLastPathComponent().path == root.path && url.pathExtension == "s" &&
            name.count == 2 && name[0].count == 16 && name[1].count == 40 &&
            name.allSatisfy({ $0.allSatisfy { "0123456789abcdef".contains($0) } }) else { return false }
        return registryLock.withLock { contextTokens.values.contains(String(name[0])) }
    }

    static func arguments(for connection: RemoteConnection) throws -> [String] {
        try SSHInputValidation.validate(connection)
        return [
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=600",
            "-o", "ControlPath=\(try controlPath(for: connection))",
            "-o", "ClearAllForwardings=yes",
        ]
    }

    static func controlKey(for connection: RemoteConnection) -> String {
        let identity = ((connection.sshIdentityFile ?? "") as NSString).expandingTildeInPath
        let fields = [
            connection.host,
            String(connection.port),
            connection.username,
            connection.sshJumpHost ?? "",
            connection.effectiveSSHAuthentication.rawValue, identity,
            String(connection.sshForwardAgent == true), String(connection.sshCompression == true),
            connection.sshX11?.mode.rawValue ?? "off", connection.sshX11?.display ?? "",
            (connection.credentialProfileID ?? connection.id).uuidString,
        ]
        let encoded = (try? JSONEncoder().encode(fields)) ?? Data()
        return SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
    }
    private static func fileIdentity(_ path: String) -> String {
        var info = stat()
        guard !path.isEmpty, stat(path, &info) == 0 else { return "absent" }
        return "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)"
    }

    static func shutdown(connection: RemoteConnection) {
        guard connection.kind == .ssh else { return }
        DispatchQueue.global(qos: .utility).async {
            _ = Self.performShutdown(connection: connection)
        }
    }

    @discardableResult
    static func shutdownAll(connections: [RemoteConnection], removeDirectory: Bool = true) -> Int {
        var seen = Set<String>()
        var unconfirmed = 0
        for connection in connections where connection.kind == .ssh {
            guard seen.insert(controlKey(for: connection)).inserted else { continue }
            if !performShutdown(connection: connection) { unconfirmed += 1 }
        }
        if removeDirectory { (try? directory.get())?.removeIfEmpty() }
        return unconfirmed
    }

    private static func performShutdown(connection: RemoteConnection) -> Bool {
        guard (try? SSHInputValidation.validate(connection)) != nil,
              let root = try? controlDirectory(), let entries = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return false }
        let patterns = registeredControlPaths(for: connection)
        var confirmed = true
        for name in entries {
            let path = root.appendingPathComponent(name).path
            guard ownsControlSocket(path) else { continue }
            let parts = name.dropLast(2).split(separator: "-")
            guard parts.count == 2, patterns.contains(where: { $0.replacingOccurrences(of: "%C", with: String(parts[1])) == path }) else { continue }
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else { confirmed = false; continue }
            if !shutdownSocket(path) { confirmed = false }
        }
        if confirmed { registryLock.withLock { _ = registered.removeValue(forKey: controlKey(for: connection)) } }
        return confirmed
    }
    private static func shutdownSocket(_ path: String) -> Bool {

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        // Control operations need neither user configuration nor a new login.
        process.arguments = ["-F", "none", "-S", path, "-o", "BatchMode=yes", "-O", "exit", "--", "nethriva-control.invalid"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: timeout)
        process.waitUntilExit()
        timeout.cancel()
        return process.terminationStatus == 0
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

enum SFTPServiceError: LocalizedError {
    case passwordRequired
    case authenticationFailed
    case hostKeyNotTrusted
    case timedOut
    case commandFailed(String)
    case invalidResponse
    case unsafePath
    case unsupportedFile
    case conflict
    case status(UInt32)

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
        case .unsupportedFile:
            "Only regular files and folders can be transferred. Symbolic links and special files are not followed."
        case .conflict:
            "An item already exists at the destination. Choose Skip, Rename, or Overwrite."
        case .status(let code):
            switch code {
            case 2: "The remote item no longer exists. Refresh the folder."
            case 3: "The server denied permission for this file operation."
            case 8: "The server does not support this file operation."
            default: "The server rejected the file operation (SFTP status \(code))."
            }
        }
    }
}

/// Establish an owned SSH master only; file operations use the binary subsystem.
/// OpenSSH 10's sftp client forces ControlMaster=no, so it cannot seed this master.
final class SFTPAuthenticationBootstrap: @unchecked Sendable {
    private let sshExecutablePath: String
    private let timeout: Int

    init(sshExecutablePath: String = "/usr/bin/ssh", timeout: Int = 30) {
        self.sshExecutablePath = sshExecutablePath
        self.timeout = min(120, max(1, timeout))
    }

    func authenticate(connection: RemoteConnection, password: String?, cancellation: SFTPCancellation) throws {
        try SSHCredentialPromptGuard.validate(password)
        _ = try runExpect(connection: connection, password: password, cancellation: cancellation)
    }

    private func runExpect(
        connection: RemoteConnection,
        password: String?,
        cancellation: SFTPCancellation = SFTPCancellation()
    ) throws -> String {
        let process = Process()
        let outputPipe = Pipe()
        let passwordPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/expect")
        process.arguments = ["-c", Self.expectScript]
        process.standardInput = passwordPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        let sshArguments = try Self.sshArguments(for: connection)
        process.environment = Self.expectEnvironment(
            base: ProcessInfo.processInfo.environment,
            sftpArguments: sshArguments,
            commands: [],
            passwordByteCount: password?.utf8.count ?? 0,
            executablePath: sshExecutablePath
        )
        process.environment?["NETHRIVA_SFTP_TIMEOUT"] = String(timeout)

        defer { cancellation.detach(); try? outputPipe.fileHandleForReading.close() }
        try cancellation.start(process)
        if let password {
            try passwordPipe.fileHandleForWriting.write(contentsOf: Data(password.utf8))
        }
        try passwordPipe.fileHandleForWriting.close()
        var outputData = Data()
        while let chunk = try outputPipe.fileHandleForReading.read(upToCount: 16384), !chunk.isEmpty {
            try cancellation.check()
            guard outputData.count + chunk.count <= 1024 * 1024 else {
                cancellation.cancel()
                throw SFTPServiceError.invalidResponse
            }
            outputData += chunk
        }
        process.waitUntilExit()
        try cancellation.check()
        let output = String(decoding: outputData, as: UTF8.self)

        if output.contains("__NETHRIVA_HOST_KEY__") || output.localizedCaseInsensitiveContains("host key verification failed") {
            throw SFTPServiceError.hostKeyNotTrusted
        }
        if output.contains("__NETHRIVA_PASSWORD_REQUIRED__") {
            throw SFTPServiceError.passwordRequired
        }
        if output.contains("__NETHRIVA_AUTH_FAILED__") || output.localizedCaseInsensitiveContains("permission denied") {
            throw SFTPServiceError.authenticationFailed
        }
        if output.contains("__NETHRIVA_TIMEOUT__") {
            throw SFTPServiceError.timedOut
        }

        guard process.terminationStatus == 0 else {
            throw SFTPServiceError.commandFailed("SFTP authentication could not start. Open SSH to verify host trust and authentication, then retry.")
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

    static func sshArguments(for connection: RemoteConnection) throws -> [String] {
        try SSHInputValidation.validate(connection)
        var arguments = [
            "-T", "-N", "-f",
            "-p", String(connection.port),
            "-o", "ForwardX11=no",
            "-o", "PermitLocalCommand=no",
            "-o", "RemoteCommand=none",
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
        } else {
            arguments += ["-o", "ForwardAgent=no"]
        }
        if connection.sshCompression == true {
            arguments.append("-C")
        }

        arguments += try SSHConnectionReuse.arguments(for: connection)

        let destination = connection.username.isEmpty
            ? connection.host
            : "\(connection.username)@\(connection.host)"
        arguments += ["--", destination]
        return arguments
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let expectScript = #"""
    set timeout $env(NETHRIVA_SFTP_TIMEOUT)
    log_user 0
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
    spawn -noecho $env(NETHRIVA_SFTP_EXECUTABLE) {*}$sftp_args
    """# + "\n" + SSHCredentialPromptGuard.expectScript + "\n" + #"""
    expect {
        -nocase -re {are you sure you want to continue connecting} {
            puts "__NETHRIVA_HOST_KEY__"
            send -- "no\r"
            exit 71
        }
        -nocase -re {host key verification failed} {
            puts "__NETHRIVA_HOST_KEY__"
            exit 71
        }
        -nocase -re {(password|passphrase).*:} {
            if {![nethriva_credential_prompt]} {
                puts "__NETHRIVA_AUTH_FAILED__"
                close
                exit 72
            }
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
            set password ""
            exp_continue
        }
        -nocase -re {permission denied} {
            puts "__NETHRIVA_AUTH_FAILED__"
            exit 72
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
