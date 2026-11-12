import Darwin
import Foundation

// SFTP v3 framing, not SSH cryptography: macOS OpenSSH owns authentication,
// encryption, config, jump hosts, agent and known_hosts. See docs/RELIABILITY.md.
enum SFTPConflictPolicy: String, CaseIterable { case ask, skip, rename, overwrite }

struct SFTPTransferProgress: Sendable {
    let bytes: Int64
    let total: Int64?
}

protocol SFTPTransferring: Sendable {
    func upload(localURLs: [URL], to directory: String, connection: RemoteConnection, password: String?, policy: SFTPConflictPolicy,
                progress: @escaping @Sendable (SFTPTransferProgress) -> Void) async throws
    func download(item: SFTPFileItem, to url: URL, connection: RemoteConnection, password: String?, policy: SFTPConflictPolicy,
                  progress: @escaping @Sendable (SFTPTransferProgress) -> Void) async throws
    func close()
}

final class SFTPCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?
    func check() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }
    func start(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        self.process = process
        try process.run()
    }
    func attach(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        self.process = process
    }
    func detach() { lock.lock(); process = nil; lock.unlock() }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if process?.isRunning == true { process?.terminate() }
    }
}

struct SFTPBytes {
    var data = Data()
    mutating func byte(_ value: UInt8) { data.append(value) }
    mutating func uint32(_ value: UInt32) {
        data.append(contentsOf: [UInt8(value >> 24), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)])
    }
    mutating func uint64(_ value: UInt64) { uint32(UInt32(value >> 32)); uint32(UInt32(value & 0xffffffff)) }
    mutating func string(_ value: Data) { uint32(UInt32(value.count)); data.append(value) }
    mutating func string(_ value: String) { string(Data(value.utf8)) }
}

struct SFTPReader {
    let data: Data
    var offset = 0
    var remaining: Int { data.count - offset }
    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw SFTPServiceError.invalidResponse }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }
    mutating func byte() throws -> UInt8 { try bytes(1)[0] }
    mutating func uint32() throws -> UInt32 { try bytes(4).reduce(0) { ($0 << 8) | UInt32($1) } }
    mutating func uint64() throws -> UInt64 { let high = try uint32(); return (UInt64(high) << 32) | UInt64(try uint32()) }
    mutating func string() throws -> Data { try bytes(Int(uint32())) }
    mutating func text() throws -> String {
        guard let value = String(data: try string(), encoding: .utf8) else { throw SFTPServiceError.invalidResponse }
        return value
    }
}

struct SFTPAttributes {
    var size: UInt64?
    var mode: UInt32?
    var modified: UInt32?
    var directory: Bool { mode.map { $0 & 0xf000 == 0x4000 } ?? false }
    var regular: Bool { mode.map { $0 & 0xf000 == 0x8000 } ?? false }
    var symbolicLink: Bool { mode.map { $0 & 0xf000 == 0xa000 } ?? false }
    static func decode(_ reader: inout SFTPReader) throws -> Self {
        let flags = try reader.uint32()
        guard flags & ~UInt32(0x8000000f) == 0 else { throw SFTPServiceError.invalidResponse }
        var value = Self()
        if flags & 1 != 0 { value.size = try reader.uint64(); guard value.size! <= UInt64(Int64.max) else { throw SFTPServiceError.invalidResponse } }
        if flags & 2 != 0 { _ = try reader.uint32(); _ = try reader.uint32() }
        if flags & 4 != 0 { value.mode = try reader.uint32() }
        if flags & 8 != 0 { _ = try reader.uint32(); value.modified = try reader.uint32() }
        if flags & 0x80000000 != 0 {
            let count = try reader.uint32()
            guard count <= 1024 else { throw SFTPServiceError.invalidResponse }
            for _ in 0..<count { _ = try reader.string(); _ = try reader.string() }
        }
        return value
    }
    var permissions: String {
        guard let mode else { return "—" }
        var result = directory ? "d" : symbolicLink ? "l" : "-"
        for bit in stride(from: 8, through: 0, by: -1) {
            result += mode & (1 << bit) == 0 ? "-" : ["r", "w", "x"][(8 - bit) % 3]
        }
        return result
    }
}

enum SFTPPath {
    static func validate(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 16384,
              value.rangeOfCharacter(from: .controlCharacters) == nil else { throw SFTPServiceError.unsafePath }
    }
    static func component(_ value: String) throws {
        try validate(value)
        guard value != ".", value != "..", !value.contains("/") else { throw SFTPServiceError.unsafePath }
    }
    static func join(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/" + name : directory == "." ? name : directory + "/" + name
    }
    static func renamed(_ path: String, index: Int) -> String {
        let directory = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let suffix = (name as NSString).pathExtension
        let base = suffix.isEmpty ? name : (name as NSString).deletingPathExtension
        return join(directory.isEmpty ? "." : directory, base + " (\(index))" + (suffix.isEmpty ? "" : "." + suffix))
    }
}

/// Count expanded metadata before constructing repeated canonical paths.
/// The same budget is shared across every recursive transfer descendant.
struct SFTPMetadataBudget {
    private(set) var remainingBytes: Int
    private(set) var remainingEntries: Int
    init(maximumBytes: Int = 16 * 1024 * 1024, maximumEntries: Int = 100_000) {
        remainingBytes = max(0, maximumBytes); remainingEntries = max(0, maximumEntries)
    }
    mutating func reserve(nameBytes: Int, pathBytes: Int) throws {
        guard remainingEntries > 0, nameBytes >= 0, pathBytes >= 0, remainingBytes >= 128,
              nameBytes <= remainingBytes - 128, pathBytes <= remainingBytes - 128 - nameBytes else {
            throw SFTPServiceError.invalidResponse
        }
        remainingBytes -= 128 + nameBytes + pathBytes; remainingEntries -= 1
    }
    mutating func reserve(name: String, parent: String, canonical: Bool = false) throws {
        let size = name.utf8.count
        try reserve(nameBytes: size, pathBytes: canonical ? size : parent.utf8.count + 1 + size)
    }
}

/// Open selected upload sources without following entries supplied by another
/// process. Recursive children stay relative to a held source directory.
final class SFTPLocalSource {
    let descriptor: Int32
    let initial: stat
    init(url: URL) throws {
        guard url.isFileURL else { throw SFTPServiceError.unsafePath }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw SFTPServiceError.unsupportedFile }
        do { initial = try Self.inspect(fd); descriptor = fd }
        catch { Darwin.close(fd); throw error }
    }
    private init(descriptor: Int32) throws {
        do { initial = try Self.inspect(descriptor); self.descriptor = descriptor }
        catch { Darwin.close(descriptor); throw error }
    }
    deinit { Darwin.close(descriptor) }
    private static func inspect(_ fd: Int32) throws -> stat {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size >= 0,
              info.st_mode & S_IFMT == S_IFDIR || (info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1) else {
            throw SFTPServiceError.unsupportedFile
        }
        return info
    }
    var isDirectory: Bool { initial.st_mode & S_IFMT == S_IFDIR }
    func child(_ name: String) throws -> SFTPLocalSource {
        try SFTPPath.component(name)
        let fd = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw SFTPServiceError.unsupportedFile }
        return try SFTPLocalSource(descriptor: fd)
    }
    func names() throws -> [String] {
        guard isDirectory else { throw SFTPServiceError.unsupportedFile }
        let copy = dup(descriptor)
        guard copy >= 0 else { throw SFTPServiceError.unsupportedFile }
        guard let stream = fdopendir(copy) else { Darwin.close(copy); throw SFTPServiceError.unsupportedFile }
        defer { closedir(stream) }
        var names: [String] = []
        errno = 0
        while let entry = readdir(stream) {
            let name: String? = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(validatingUTF8: $0) }
            }
            guard let name else { throw SFTPServiceError.unsafePath }
            if name == "." || name == ".." { continue }
            try SFTPPath.component(name)
            guard names.count < 100_000 else { throw SFTPServiceError.unsupportedFile }
            names.append(name)
            errno = 0
        }
        guard errno == 0 else { throw SFTPServiceError.unsupportedFile }
        return names.sorted()
    }
    func unchanged() throws -> Bool {
        let current = try Self.inspect(descriptor)
        return current.st_dev == initial.st_dev && current.st_ino == initial.st_ino && current.st_size == initial.st_size &&
            current.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec && current.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec &&
            current.st_ctimespec.tv_sec == initial.st_ctimespec.tv_sec && current.st_ctimespec.tv_nsec == initial.st_ctimespec.tv_nsec
    }
}

/// A download's selected directory is resolved once, then every child and
/// publication is relative to held directory descriptors, never remote paths.
final class SFTPLocalDirectory {
    let descriptor: Int32
    init(url: URL) throws {
        guard url.isFileURL else { throw SFTPServiceError.unsafePath }
        descriptor = Darwin.open(url.resolvingSymlinksInPath().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw SFTPServiceError.unsupportedFile }
    }
    private init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { Darwin.close(descriptor) }
    func attributes(_ name: String) throws -> stat? {
        try SFTPPath.component(name)
        var value = stat()
        if fstatat(descriptor, name, &value, AT_SYMLINK_NOFOLLOW) == 0 { return value }
        if errno == ENOENT { return nil }
        throw SFTPServiceError.unsupportedFile
    }
    func directory(_ name: String) throws -> SFTPLocalDirectory {
        try SFTPPath.component(name)
        if mkdirat(descriptor, name, 0o700) != 0, errno != EEXIST { throw SFTPServiceError.unsupportedFile }
        let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { throw SFTPServiceError.unsupportedFile }
        return SFTPLocalDirectory(descriptor: child)
    }
    func temporaryFile() throws -> (String, FileHandle) {
        let name = ".nethriva-\(UUID().uuidString).partial"
        let fd = openat(descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SFTPServiceError.unsupportedFile }
        return (name, FileHandle(fileDescriptor: fd, closeOnDealloc: true))
    }
    func remove(_ name: String) { _ = unlinkat(descriptor, name, 0) }
    func publish(_ temporary: String, to name: String, overwrite: Bool) throws {
        try SFTPPath.component(temporary); try SFTPPath.component(name)
        if let existing = try attributes(name) {
            guard existing.st_mode & S_IFMT == S_IFREG else { throw SFTPServiceError.unsupportedFile }
            guard overwrite else { throw SFTPServiceError.conflict }
        }
        let status = overwrite ? renameat(descriptor, temporary, descriptor, name)
            : renameatx_np(descriptor, temporary, descriptor, name, UInt32(RENAME_EXCL))
        guard status == 0 else {
            if errno == EEXIST { throw SFTPServiceError.conflict }
            throw SFTPServiceError.unsupportedFile
        }
    }
}

/// Serial worker per file surface. Directory reads reuse an open subsystem;
/// transfers use their own channel so navigation and terminal input stay independent.
final class SFTPService: SFTPTransferring, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.vitalii.nethriva.sftp", qos: .userInitiated)
    private let bootstrap: SFTPAuthenticationBootstrap
    private var channel: SFTPChannel?
    private var channelKey: String?
    private let lock = NSLock()
    private var active: [UUID: SFTPCancellation] = [:]
    init(sshExecutablePath: String = "/usr/bin/ssh") { bootstrap = SFTPAuthenticationBootstrap(sshExecutablePath: sshExecutablePath) }
    deinit { channel?.close() }
    func close() {
        lock.lock(); let tokens = Array(active.values); lock.unlock()
        tokens.forEach { $0.cancel() }
        queue.async { [self] in channel?.close(); channel = nil; channelKey = nil }
    }
    private func perform<T>(connection: RemoteConnection, password: String?, operation: @escaping (SFTPChannel) throws -> T) async throws -> T {
        let token = SFTPCancellation(), id = UUID()
        lock.withLock { active[id] = token }
        return try await withTaskCancellationHandler {
            return try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    defer { token.detach(); lock.lock(); active[id] = nil; lock.unlock() }
                    do {
                        try token.check()
                        let key = SSHConnectionReuse.controlKey(for: connection)
                        if channel?.isRunning != true || channelKey != key {
                            channel?.close(); channel = nil
                            _ = try SFTPChannel.arguments(for: connection)
                            // Expect authenticates an owned SSH master, never file commands.
                            try bootstrap.authenticate(connection: connection, password: password, cancellation: token)
                            channel = try SFTPChannel(connection: connection, cancellation: token)
                            channelKey = key
                        }
                        guard let channel else { throw SFTPServiceError.invalidResponse }
                        channel.cancellation = token
                        try token.attach(channel.process)
                        let result = try operation(channel)
                        try token.check()
                        continuation.resume(returning: result)
                    } catch {
                        // A cancelled/invalid channel cannot be reused or replay a write.
                        channel?.close(); channel = nil; channelKey = nil
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: { token.cancel() }
    }
    func list(connection: RemoteConnection, password: String?, path: String) async throws -> SFTPDirectoryListing {
        try SFTPPath.validate(path)
        return try await perform(connection: connection, password: password) { try $0.list(path) }
    }
    func readText(path: String, connection: RemoteConnection, password: String?) async throws -> RemoteTextSnapshot {
        try SFTPPath.validate(path)
        return try await perform(connection: connection, password: password) { try $0.readText(path) }
    }
    func saveText(_ text: String, path: String, baseline: RemoteTextSnapshot, overwriteChanged: Bool,
                  connection: RemoteConnection, password: String?) async throws -> RemoteTextSnapshot {
        try SFTPPath.validate(path)
        let data = try RemoteTextSnapshot.encode(text)
        return try await perform(connection: connection, password: password) { channel in
            try channel.saveText(data, path: path, baseline: baseline, overwriteChanged: overwriteChanged)
        }
    }
    func upload(localURLs: [URL], to directory: String, connection: RemoteConnection, password: String?, policy: SFTPConflictPolicy = .ask,
                progress: @escaping @Sendable (SFTPTransferProgress) -> Void = { _ in }) async throws {
        try SFTPPath.validate(directory)
        try await perform(connection: connection, password: password) { channel in
            for url in localURLs {
                try SFTPPath.component(url.lastPathComponent)
                try channel.upload(url, to: SFTPPath.join(directory, url.lastPathComponent), policy: policy, progress: progress)
            }
        }
    }
    func download(item: SFTPFileItem, to url: URL, connection: RemoteConnection, password: String?, policy: SFTPConflictPolicy = .ask,
                  progress: @escaping @Sendable (SFTPTransferProgress) -> Void = { _ in }) async throws {
        try SFTPPath.validate(item.path)
        try await perform(connection: connection, password: password) { try $0.download(item.path, to: url, policy: policy, progress: progress) }
    }
    func move(remotePath: String, to directory: String, connection: RemoteConnection, password: String?) async throws {
        let name = (remotePath as NSString).lastPathComponent
        try SFTPPath.validate(remotePath); try SFTPPath.validate(directory); try SFTPPath.component(name)
        try await perform(connection: connection, password: password) { try $0.rename(remotePath, SFTPPath.join(directory, name), overwrite: false) }
    }
    func createDirectory(named name: String, in directory: String, connection: RemoteConnection, password: String?) async throws {
        try SFTPPath.component(name); try SFTPPath.validate(directory)
        try await perform(connection: connection, password: password) { try $0.pathRequest(14, SFTPPath.join(directory, name), attributes: true) }
    }
    func rename(item: SFTPFileItem, to name: String, connection: RemoteConnection, password: String?) async throws {
        try SFTPPath.component(name); try SFTPPath.validate(item.path)
        try await perform(connection: connection, password: password) { try $0.rename(item.path, SFTPPath.join((item.path as NSString).deletingLastPathComponent, name), overwrite: false) }
    }
    func delete(item: SFTPFileItem, connection: RemoteConnection, password: String?) async throws {
        try SFTPPath.validate(item.path)
        try await perform(connection: connection, password: password) { try $0.pathRequest(item.isDirectory ? 15 : 13, item.path) }
    }
    // Compatibility helpers for existing bootstrap tests; never used for file operations.
    static func expectEnvironment(base: [String: String], sftpArguments: [String], commands: [String], passwordByteCount: Int = 0, executablePath: String = "/usr/bin/sftp") -> [String: String] {
        SFTPAuthenticationBootstrap.expectEnvironment(base: base, sftpArguments: sftpArguments, commands: commands, passwordByteCount: passwordByteCount, executablePath: executablePath)
    }
    static func validate(commands: [String]) throws { try SFTPAuthenticationBootstrap.validate(commands: commands) }
}

final class SFTPChannel {
    let process: Process
    var cancellation: SFTPCancellation
    private let input: FileHandle
    private let output: FileHandle
    private var requestID: UInt32 = 0
    private var pending: [UInt32: (UInt8, Data)] = [:]
    private var outstanding = Set<UInt32>()
    private var extensions = Set<String>()
    var isRunning: Bool { process.isRunning }

    static func arguments(for connection: RemoteConnection) throws -> [String] {
        try SSHInputValidation.validate(connection)
        var args = ["-T", "-p", String(connection.port), "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=15",
                    "-o", "PermitLocalCommand=no", "-o", "RemoteCommand=none", "-o", "ForwardX11=no", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2"] + (try SSHConnectionReuse.arguments(for: connection))
        switch connection.effectiveSSHAuthentication {
        case .password: args += ["-o", "PreferredAuthentications=keyboard-interactive,password", "-o", "PubkeyAuthentication=no"]
        case .publicKey: args += ["-o", "PreferredAuthentications=publickey", "-o", "PasswordAuthentication=no", "-o", "KbdInteractiveAuthentication=no"]
        case .automatic: break
        }
        if let identity = connection.sshIdentityFile, !identity.isEmpty { args += ["-i", (identity as NSString).expandingTildeInPath] }
        if let jump = connection.sshJumpHost, !jump.isEmpty { args += ["-J", jump] }
        if connection.sshForwardAgent == true { args.append("-A") } else { args += ["-o", "ForwardAgent=no"] }
        if connection.sshCompression == true { args.append("-C") }
        args += ["-s", "--", connection.username.isEmpty ? connection.host : "\(connection.username)@\(connection.host)", "sftp"]
        return args
    }
    convenience init(connection: RemoteConnection, cancellation: SFTPCancellation) throws {
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = try Self.arguments(for: connection)
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try cancellation.start(process)
        self.init(process: process, input: input.fileHandleForWriting, output: output.fileHandleForReading, cancellation: cancellation)
        do { try initialize() } catch { close(); throw error }
    }
    // Test seam: in-memory pipes or the system's local sftp-server; no remote credentials.
    init(process: Process, input: FileHandle, output: FileHandle, cancellation: SFTPCancellation) {
        self.process = process; self.input = input; self.output = output; self.cancellation = cancellation
        _ = fcntl(input.fileDescriptor, F_SETFL, O_NONBLOCK)
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
        _ = fcntl(output.fileDescriptor, F_SETFL, O_NONBLOCK)
    }
    deinit { close() }
    func close() {
        if process.isRunning { process.terminate() }
        try? input.close(); try? output.close()
    }
    func initialize() throws {
        var data = SFTPBytes(); data.uint32(3)
        try sendPacket(1, data.data)
        let (type, payload) = try receivePacket()
        var reader = SFTPReader(data: payload)
        guard type == 2, try reader.uint32() == 3 else { throw SFTPServiceError.invalidResponse }
        while reader.remaining > 0 { extensions.insert(try reader.text()); _ = try reader.string() }
    }
    private func io(_ data: Data?, count: Int) throws -> Data {
        let fd = data == nil ? output.fileDescriptor : input.fileDescriptor
        var result = Data(), offset = 0
        let deadline = Date().addingTimeInterval(30)
        while offset < count {
            try cancellation.check()
            guard Date() < deadline else { throw SFTPServiceError.timedOut }
            var descriptor = pollfd(fd: fd, events: Int16(data == nil ? POLLIN : POLLOUT), revents: 0)
            let status = poll(&descriptor, 1, 100)
            if status < 0 { if errno == EINTR { continue }; throw SFTPServiceError.invalidResponse }
            if status == 0 { continue }
            let transferred: Int
            if let data {
                transferred = data.withUnsafeBytes { buffer in Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), count - offset) }
            } else {
                var buffer = [UInt8](repeating: 0, count: min(count - offset, 65536))
                transferred = Darwin.read(fd, &buffer, buffer.count)
                if transferred > 0 { result.append(contentsOf: buffer.prefix(transferred)) }
            }
            if transferred < 0, errno == EAGAIN || errno == EINTR { continue }
            guard transferred > 0 else { throw SFTPServiceError.commandFailed("The SFTP channel disconnected. Check SSH authentication and subsystem support, then retry.") }
            offset += transferred
        }
        return result
    }
    private func sendPacket(_ type: UInt8, _ payload: Data) throws {
        var bytes = SFTPBytes(); bytes.uint32(UInt32(payload.count + 1)); bytes.byte(type); bytes.data.append(payload)
        _ = try io(bytes.data, count: bytes.data.count)
    }
    private func receivePacket() throws -> (UInt8, Data) {
        var header = SFTPReader(data: try io(nil, count: 4))
        let count = Int(try header.uint32())
        guard count >= 1, count <= 1024 * 1024 else { throw SFTPServiceError.invalidResponse }
        var reader = SFTPReader(data: try io(nil, count: count))
        let type = try reader.byte()
        return (type, try reader.bytes(reader.remaining))
    }
    private func send(_ type: UInt8, _ build: (inout SFTPBytes) -> Void) throws -> UInt32 {
        requestID &+= 1
        guard outstanding.count < 16 else { throw SFTPServiceError.invalidResponse }
        outstanding.insert(requestID)
        var bytes = SFTPBytes(); bytes.uint32(requestID); build(&bytes)
        try sendPacket(type, bytes.data)
        return requestID
    }
    private func response(_ id: UInt32, expected: UInt8, eof: Bool = false) throws -> Data? {
        var value = pending.removeValue(forKey: id)
        while value == nil {
            let (type, payload) = try receivePacket()
            var reader = SFTPReader(data: payload)
            let receivedID = try reader.uint32()
            guard outstanding.remove(receivedID) != nil else { throw SFTPServiceError.invalidResponse }
            let body = try reader.bytes(reader.remaining)
            if receivedID == id { value = (type, body) }
            else {
                guard pending.count < 16, pending[receivedID] == nil else { throw SFTPServiceError.invalidResponse }
                pending[receivedID] = (type, body)
            }
        }
        let (type, body) = value!
        if type == 101 {
            var reader = SFTPReader(data: body)
            let code = try reader.uint32()
            _ = try reader.string(); _ = try reader.string() // Never display server messages.
            if eof && code == 1 { return nil }
            guard code == 0, expected == 101 else { throw SFTPServiceError.status(code) }
        } else if type != expected { throw SFTPServiceError.invalidResponse }
        return body
    }
    private func handle(_ type: UInt8, path: String, flags: UInt32? = nil) throws -> Data {
        let id = try send(type) { bytes in
            bytes.string(path)
            if let flags { bytes.uint32(flags); bytes.uint32(4); bytes.uint32(0o600) }
        }
        var reader = SFTPReader(data: try response(id, expected: 102)!)
        let handle = try reader.string()
        guard !handle.isEmpty, handle.count <= 256 else { throw SFTPServiceError.invalidResponse }
        return handle
    }
    private func closeHandle(_ handle: Data) throws {
        let id = try send(4) { $0.string(handle) }; _ = try response(id, expected: 101)
    }
    func attributes(_ path: String) throws -> SFTPAttributes? {
        let id = try send(7) { $0.string(path) }
        do { var reader = SFTPReader(data: try response(id, expected: 105)!); return try SFTPAttributes.decode(&reader) }
        catch SFTPServiceError.status(2) { return nil }
    }
    static func names(_ body: Data, parent: String, canonical: Bool = false, budget: inout SFTPMetadataBudget) throws -> [SFTPFileItem] {
        var reader = SFTPReader(data: body)
        let count = try reader.uint32()
        guard body.count <= 1024 * 1024, count <= 100000, !canonical || count == 1 else { throw SFTPServiceError.invalidResponse }
        var items: [SFTPFileItem] = []
        for _ in 0..<count {
            let name = try reader.text(); _ = try reader.string() // Longname is not parsed.
            let attr = try SFTPAttributes.decode(&reader)
            if name == "." || name == ".." { continue }
            if canonical { try SFTPPath.validate(name) } else { try SFTPPath.component(name) }
            try budget.reserve(name: name, parent: parent, canonical: canonical)
            items.append(SFTPFileItem(name: name, path: canonical ? name : SFTPPath.join(parent, name), isDirectory: attr.directory,
                isSymbolicLink: attr.symbolicLink, size: attr.size.map(Int64.init), permissions: attr.permissions,
                modifiedText: attr.modified.map { Date(timeIntervalSince1970: TimeInterval($0)).formatted(date: .numeric, time: .shortened) } ?? "—"))
        }
        guard reader.remaining == 0 else { throw SFTPServiceError.invalidResponse }
        return items
    }
    func list(_ path: String) throws -> SFTPDirectoryListing {
        let id = try send(16) { $0.string(path) }
        var canonicalBudget = SFTPMetadataBudget(maximumBytes: 64 * 1024, maximumEntries: 1)
        guard let resolved = try Self.names(response(id, expected: 104)!, parent: "", canonical: true, budget: &canonicalBudget).first?.path else { throw SFTPServiceError.invalidResponse }
        let handle = try handle(11, path: resolved)
        defer { try? closeHandle(handle) }
        var result: [SFTPFileItem] = []
        var pages = 0
        var budget = SFTPMetadataBudget(), wireBytes = 0
        while true {
            pages += 1
            guard pages <= 10000 else { throw SFTPServiceError.invalidResponse }
            let id = try send(12) { $0.string(handle) }
            guard let body = try response(id, expected: 104, eof: true) else { break }
            guard body.count <= 16 * 1024 * 1024 - wireBytes else { throw SFTPServiceError.invalidResponse }
            wireBytes += body.count
            let page = try Self.names(body, parent: resolved, budget: &budget)
            guard result.count + page.count <= 100000 else { throw SFTPServiceError.invalidResponse }
            result += page
        }
        return SFTPDirectoryListing(path: resolved, items: result.sorted {
            $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        })
    }
    func pathRequest(_ type: UInt8, _ path: String, attributes: Bool = false) throws {
        let id = try send(type) { bytes in bytes.string(path); if attributes { bytes.uint32(0) } }
        _ = try response(id, expected: 101)
    }
    func readText(_ path: String) throws -> RemoteTextSnapshot {
        guard let before = try attributes(path), before.regular, !before.symbolicLink,
              let size = before.size, size <= RemoteTextSnapshot.maximumBytes else {
            throw WorkflowError.invalid("Edit supports regular UTF-8 files up to 2 MiB, not directories, links or binary files.")
        }
        let handle = try handle(3, path: path, flags: 1)
        defer { try? closeHandle(handle) }
        var data = Data()
        while UInt64(data.count) < size {
            let length = UInt32(min(32768, size - UInt64(data.count)))
            let id = try send(5) { $0.string(handle); $0.uint64(UInt64(data.count)); $0.uint32(length) }
            var reader = SFTPReader(data: try response(id, expected: 103)!)
            let bytes = try reader.string()
            guard !bytes.isEmpty, bytes.count <= Int(length) else { throw SFTPServiceError.invalidResponse }
            data += bytes
        }
        guard let after = try attributes(path), after.regular, after.size == before.size, after.modified == before.modified else {
            throw WorkflowError.invalid("The remote file changed while reading it. Reload when it is stable.")
        }
        return try RemoteTextSnapshot(data: data, mode: after.mode ?? 0o600)
    }
    func saveText(_ data: Data, path: String, baseline: RemoteTextSnapshot, overwriteChanged: Bool) throws -> RemoteTextSnapshot {
        try SFTPPath.validate(path)
        _ = try RemoteTextSnapshot(data: data, mode: baseline.mode)
        let current = try readText(path)
        guard overwriteChanged || current.fingerprint == baseline.fingerprint else { throw SFTPServiceError.conflict }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Nethriva-edit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let local = directory.appendingPathComponent("edited.txt")
        try data.write(to: local, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: current.mode & 0o777)], ofItemAtPath: local.path)
        try upload(local, to: path, policy: .overwrite, progress: { _ in })
        return try RemoteTextSnapshot(data: data, mode: current.mode)
    }
    private func permissions(_ path: String, mode: UInt32) throws {
        let id = try send(9) { $0.string(path); $0.uint32(4); $0.uint32(mode & 0o777) }
        _ = try response(id, expected: 101)
    }
    func rename(_ source: String, _ destination: String, overwrite: Bool) throws {
        if !overwrite, try attributes(destination) != nil { throw SFTPServiceError.conflict }
        if overwrite {
            // Never remove a target first: a failed publish must preserve the old file.
            guard extensions.contains("posix-rename@openssh.com") else { throw SFTPServiceError.commandFailed("This server cannot safely replace an existing file. Choose Rename instead.") }
            let id = try send(200) { $0.string("posix-rename@openssh.com"); $0.string(source); $0.string(destination) }
            _ = try response(id, expected: 101)
        } else {
            let id = try send(18) { $0.string(source); $0.string(destination) }; _ = try response(id, expected: 101)
        }
    }
    private func remoteDestination(_ path: String, policy: SFTPConflictPolicy) throws -> String? {
        guard try attributes(path) != nil else { return path }
        switch policy {
        case .ask: throw SFTPServiceError.conflict
        case .skip: return nil
        case .overwrite: return path
        case .rename:
            for index in 1...1000 { let candidate = SFTPPath.renamed(path, index: index); if try attributes(candidate) == nil { return candidate } }
            throw SFTPServiceError.conflict
        }
    }
    func upload(_ url: URL, to path: String, policy: SFTPConflictPolicy, progress: @escaping @Sendable (SFTPTransferProgress) -> Void, depth: Int = 0) throws {
        let source = try SFTPLocalSource(url: url)
        var budget = SFTPMetadataBudget(maximumBytes: 64 * 1024 * 1024)
        try budget.reserve(nameBytes: url.lastPathComponent.utf8.count, pathBytes: path.utf8.count)
        try upload(source, to: path, policy: policy, progress: progress, depth: depth, budget: &budget)
    }
    private func upload(_ source: SFTPLocalSource, to path: String, policy: SFTPConflictPolicy,
                        progress: @escaping @Sendable (SFTPTransferProgress) -> Void, depth: Int, budget: inout SFTPMetadataBudget) throws {
        try cancellation.check()
        guard depth < 64 else { throw SFTPServiceError.unsupportedFile }
        guard let target = try remoteDestination(path, policy: policy) else { return }
        if source.isDirectory {
            if let existing = try attributes(target) { guard existing.directory, policy == .overwrite else { throw SFTPServiceError.conflict } }
            else { try pathRequest(14, target, attributes: true) }
            let names = try source.names()
            for name in names { try budget.reserve(name: name, parent: target) }
            for name in names {
                try upload(source.child(name), to: SFTPPath.join(target, name), policy: policy == .rename ? .ask : policy,
                           progress: progress, depth: depth + 1, budget: &budget)
            }
            return
        }
        let parent = (target as NSString).deletingLastPathComponent
        let temporary = SFTPPath.join(parent.isEmpty ? "." : parent, ".nethriva-\(UUID().uuidString).partial")
        let copy = dup(source.descriptor)
        guard copy >= 0 else { throw SFTPServiceError.unsupportedFile }
        let file = FileHandle(fileDescriptor: copy, closeOnDealloc: true)
        defer { try? file.close() }
        let handle = try handle(3, path: temporary, flags: 2 | 8 | 16 | 32)
        var published = false
        defer { if !published { try? closeHandle(handle); try? pathRequest(13, temporary) } }
        var offset: UInt64 = 0, pendingWrites: [UInt32] = [], lastUpdate = Date.distantPast
        while let chunk = try file.read(upToCount: 32768), !chunk.isEmpty {
            let id = try send(6) { $0.string(handle); $0.uint64(offset); $0.string(chunk) }
            pendingWrites.append(id); offset += UInt64(chunk.count)
            if pendingWrites.count == 8 { for id in pendingWrites { _ = try response(id, expected: 101) }; pendingWrites.removeAll() }
            if Date().timeIntervalSince(lastUpdate) >= 0.1 {
                lastUpdate = Date(); progress(.init(bytes: Int64(offset), total: Int64(source.initial.st_size)))
            }
        }
        for id in pendingWrites { _ = try response(id, expected: 101) }
        try closeHandle(handle)
        guard try source.unchanged(), UInt64(source.initial.st_size) == offset else {
            throw SFTPServiceError.commandFailed("The local file changed during upload. The previous destination was preserved; retry when the file is stable.")
        }
        try permissions(temporary, mode: UInt32(source.initial.st_mode) & 0o777)
        let overwrite = try policy == .overwrite && attributes(target) != nil
        try rename(temporary, target, overwrite: overwrite)
        published = true
        progress(.init(bytes: Int64(offset), total: Int64(offset)))
    }
    func download(_ path: String, to url: URL, policy: SFTPConflictPolicy, progress: @escaping @Sendable (SFTPTransferProgress) -> Void, depth: Int = 0) throws {
        try SFTPPath.component(url.lastPathComponent)
        let parent = try SFTPLocalDirectory(url: url.deletingLastPathComponent())
        var budget = SFTPMetadataBudget(maximumBytes: 64 * 1024 * 1024)
        try budget.reserve(nameBytes: url.lastPathComponent.utf8.count, pathBytes: path.utf8.count)
        try download(path, parent: parent, name: url.lastPathComponent, policy: policy, progress: progress, depth: depth, budget: &budget)
    }
    private func download(_ path: String, parent: SFTPLocalDirectory, name: String, policy: SFTPConflictPolicy,
                          progress: @escaping @Sendable (SFTPTransferProgress) -> Void, depth: Int, budget: inout SFTPMetadataBudget) throws {
        try cancellation.check()
        guard depth < 64, let attr = try attributes(path), !attr.symbolicLink,
              attr.directory || attr.regular else { throw SFTPServiceError.unsupportedFile }
        var target = name
        if let existing = try parent.attributes(target) {
            guard existing.st_mode & S_IFMT != S_IFLNK else { throw SFTPServiceError.unsupportedFile }
            switch policy {
            case .ask: throw SFTPServiceError.conflict
            case .skip: return
            case .overwrite: break
            case .rename:
                var found = false
                for index in 1...1000 {
                    let candidate = SFTPPath.renamed(name, index: index)
                    if try parent.attributes(candidate) == nil { target = candidate; found = true; break }
                }
                guard found else { throw SFTPServiceError.conflict }
            }
        }
        if attr.directory {
            let directory = try parent.directory(target)
            let items = try list(path).items
            for item in items { try budget.reserve(nameBytes: item.name.utf8.count, pathBytes: item.path.utf8.count) }
            for item in items {
                try SFTPPath.component(item.name)
                try download(item.path, parent: directory, name: item.name, policy: policy == .rename ? .ask : policy,
                             progress: progress, depth: depth + 1, budget: &budget)
            }
            return
        }
        guard let size = attr.size else { throw SFTPServiceError.invalidResponse }
        let (temporary, file) = try parent.temporaryFile()
        var remoteHandle: Data?
        defer {
            try? file.close()
            if let remoteHandle { try? closeHandle(remoteHandle) }
            parent.remove(temporary)
        }
        let handle = try handle(3, path: path, flags: 1)
        remoteHandle = handle
        var offset: UInt64 = 0, completed: UInt64 = 0, lastUpdate = Date.distantPast
        while offset < size {
            var reads: [(UInt32, UInt64, UInt32)] = []
            for _ in 0..<8 where offset < size {
                let length = UInt32(min(32768, size - offset)), start = offset
                let id = try send(5) { $0.string(handle); $0.uint64(start); $0.uint32(length) }
                reads.append((id, start, length)); offset += UInt64(length)
            }
            for (id, start, length) in reads {
                var reader = SFTPReader(data: try response(id, expected: 103)!)
                var chunk = try reader.string()
                guard !chunk.isEmpty, chunk.count <= Int(length) else { throw SFTPServiceError.invalidResponse }
                while chunk.count < Int(length) {
                    let nextOffset = start + UInt64(chunk.count), needed = length - UInt32(chunk.count)
                    let next = try send(5) { $0.string(handle); $0.uint64(nextOffset); $0.uint32(needed) }
                    var tail = SFTPReader(data: try response(next, expected: 103)!)
                    let extra = try tail.string()
                    guard !extra.isEmpty, extra.count <= Int(needed) else { throw SFTPServiceError.invalidResponse }
                    chunk += extra
                }
                try file.write(contentsOf: chunk); completed += UInt64(chunk.count)
                if Date().timeIntervalSince(lastUpdate) >= 0.1 { lastUpdate = Date(); progress(.init(bytes: Int64(completed), total: Int64(size))) }
            }
        }
        guard let current = try attributes(path), current.size == attr.size, current.modified == attr.modified else {
            throw SFTPServiceError.commandFailed("The remote file changed during download. The previous destination was preserved; retry when the file is stable.")
        }
        // A remote server cannot grant other local users access to downloaded data.
        if let mode = attr.mode, fchmod(file.fileDescriptor, mode_t(mode & 0o700)) != 0 { throw SFTPServiceError.unsupportedFile }
        try file.close()
        try closeHandle(handle); remoteHandle = nil
        try parent.publish(temporary, to: target, overwrite: policy == .overwrite)
        progress(.init(bytes: Int64(size), total: Int64(size)))
    }

}
