import Darwin
import Foundation
import Security

enum ExternalCredentialKind: String, Codable, CaseIterable, Identifiable {
  case onePassword, vaultKV2
  var id: String { rawValue }
  var label: String { self == .onePassword ? "1Password CLI" : "HashiCorp Vault (KV v2)" }
}

/// Local, metadata-only configuration. Never included in connection exports.
struct ExternalCredentialReference: Codable, Equatable {
  var kind: ExternalCredentialKind = .onePassword
  var reference = ""  // op://vault/item/field, or Vault mount/path
  var field = "password"
  var server = ""
  var namespace = ""
  var executable = "/opt/homebrew/bin/op"
  func validate() throws {
    guard
      [reference, field, server, namespace, executable].allSatisfy({
        $0.count <= 2048 && $0.rangeOfCharacter(from: .controlCharacters) == nil
      })
    else { throw ExternalCredentialError.invalid }
    switch kind {
    case .onePassword:
      guard reference.hasPrefix("op://"), !reference.contains("?"),
        reference.split(separator: "/").count >= 4,
        ["/opt/homebrew/bin/op", "/usr/local/bin/op", "/usr/bin/op"].contains(executable)
      else { throw ExternalCredentialError.invalid }
    case .vaultKV2:
      guard let components = URLComponents(string: server), components.scheme == "https",
        components.host != nil,
        components.user == nil, components.password == nil, components.query == nil,
        components.fragment == nil,
        components.path.isEmpty || components.path == "/", !field.isEmpty,
        reference.split(separator: "/").count >= 2, !reference.hasPrefix("/"),
        !reference.hasSuffix("/"),
        reference.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
          !$0.isEmpty && $0 != "." && $0 != ".."
            && $0.rangeOfCharacter(
              from: CharacterSet.alphanumerics.union(.init(charactersIn: "-_ .")).inverted) == nil
        })
      else { throw ExternalCredentialError.invalid }
    }
  }
  func vaultURL() throws -> URL {
    try validate()
    let parts = reference.split(separator: "/").map(String.init)
    var components = URLComponents(string: server)!
    components.path = "/v1/" + parts[0] + "/data/" + parts.dropFirst().joined(separator: "/")
    guard let url = components.url else { throw ExternalCredentialError.invalid }
    return url
  }
}

enum ExternalCredentialError: LocalizedError {
  case invalid, unavailable, failed, tooLarge, tokenRequired, untrustedExecutable
  var errorDescription: String? {
    switch self {
    case .invalid:
      "Check the provider reference, field and HTTPS server. Use a supported 1Password CLI location."
    case .unavailable: "Install the official 1Password CLI and enable its desktop-app integration."
    case .untrustedExecutable:
      "The 1Password CLI could not be verified as an official, unmodified executable. Reinstall it from 1Password. No credential was requested."
    case .failed:
      "The credential provider could not supply this field. Check authentication, permissions and the item reference. No provider response is logged."
    case .tooLarge: "The provider response is oversized or is not a usable password."
    case .tokenRequired:
      "Authorize this Vault profile in Credential Profiles with a temporary Vault token first."
    }
  }
}

enum ExternalCredentialValue {
  static func validate(_ value: String) throws {
    guard !value.isEmpty, value.utf8.count <= 65536,
      value.rangeOfCharacter(from: .controlCharacters) == nil
    else { throw ExternalCredentialError.tooLarge }
  }
}

protocol ExternalCredentialReading: Sendable {
  func read(_ reference: ExternalCredentialReference, token: String?) async throws -> String
}

/// No shell, arbitrary command template, credential environment, stderr logs,
/// cache, disk secret, or automatic export. Values exist only in the session.
struct ExternalCredentialReader: ExternalCredentialReading {
  var vaultConfiguration: @Sendable () -> URLSessionConfiguration = { .ephemeral }
  func read(_ reference: ExternalCredentialReference, token: String?) async throws -> String {
    try reference.validate()
    try Task.checkCancellation()
    switch reference.kind {
    case .onePassword: return try await ProviderProcess.read(reference)
    case .vaultKV2:
      guard let token, !token.isEmpty, token.count <= 8192,
        token.rangeOfCharacter(from: .controlCharacters) == nil
      else { throw ExternalCredentialError.tokenRequired }
      return try await VaultFieldRequest.read(
        reference, token: token, configuration: vaultConfiguration())
    }
  }
}

/// Executes a private, signer-verified snapshot of the public CLI rather than a
/// mutable Homebrew path. No account database, key or credential is copied.
final class VerifiedProviderExecutable {
  static let maximumBytes = 128 * 1024 * 1024
  static let officialRequirement = "anchor apple generic and certificate leaf[subject.OU] = \"2BUA8C4S2C\" and identifier \"com.1password.op\""
  let url: URL
  private let directory: URL
  private var descriptor: Int32
  private let device: dev_t
  private let inode: ino_t
  private var snapshotDevice: dev_t = 0
  private var snapshotInode: ino_t = 0
  private var snapshotSize: off_t = 0

  init(source: URL, temporaryParent: URL = FileManager.default.temporaryDirectory,
       signatureVerifier: (URL) throws -> Void = VerifiedProviderExecutable.verifyOfficialSignature,
       checkCancellation: () throws -> Void = {}) throws {
    var template = Array(temporaryParent.appendingPathComponent("NethrivaProvider-XXXXXX").path.utf8CString)
    guard mkdtemp(&template) != nil else { throw ExternalCredentialError.untrustedExecutable }
    let root = URL(fileURLWithPath: String(cString: template), isDirectory: true)
    let held = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard held >= 0 else { _ = rmdir(root.path); throw ExternalCredentialError.untrustedExecutable }
    var info = stat()
    guard fstat(held, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
          info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
      Darwin.close(held); _ = rmdir(root.path); throw ExternalCredentialError.untrustedExecutable
    }
    directory = root; descriptor = held; device = info.st_dev; inode = info.st_ino
    url = root.appendingPathComponent("op")
    do {
      try checkCancellation()
      // Homebrew's op is normally a symlink. Resolve it, then open the actual
      // installed regular executable without following a replacement symlink.
      let original = source.resolvingSymlinksInPath()
      let inputFD = open(original.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
      guard inputFD >= 0 else { throw ExternalCredentialError.unavailable }
      let input = FileHandle(fileDescriptor: inputFD, closeOnDealloc: true)
      defer { try? input.close() }
      var before = stat()
      guard fstat(inputFD, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
            before.st_uid == 0 || before.st_uid == getuid(), before.st_mode & 0o111 != 0,
            before.st_mode & 0o002 == 0, before.st_size >= 4, before.st_size <= Self.maximumBytes else {
        throw ExternalCredentialError.untrustedExecutable
      }
      let header = try input.read(upToCount: 4) ?? Data()
      let macho = [Data([0xcf, 0xfa, 0xed, 0xfe]), Data([0xfe, 0xed, 0xfa, 0xcf]),
                   Data([0xca, 0xfe, 0xba, 0xbe]), Data([0xbe, 0xba, 0xfe, 0xca]),
                   Data([0xca, 0xfe, 0xba, 0xbf]), Data([0xbf, 0xba, 0xfe, 0xca])]
      guard macho.contains(header) else { throw ExternalCredentialError.untrustedExecutable }
      let outputFD = openat(descriptor, "op", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard outputFD >= 0 else { throw ExternalCredentialError.untrustedExecutable }
      let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
      defer { try? output.close() }
      try output.write(contentsOf: header)
      var count = header.count
      while let chunk = try input.read(upToCount: 65_536), !chunk.isEmpty {
        try checkCancellation()
        guard count + chunk.count <= Self.maximumBytes else { throw ExternalCredentialError.untrustedExecutable }
        try output.write(contentsOf: chunk); count += chunk.count
      }
      var after = stat(), copied = stat()
      guard fstat(inputFD, &after) == 0, before.st_size == after.st_size, count == before.st_size,
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
            before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
            before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
            before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
            fchmod(outputFD, 0o500) == 0, fstat(outputFD, &copied) == 0 else {
        throw ExternalCredentialError.untrustedExecutable
      }
      try output.synchronize(); try output.close()
      snapshotDevice = copied.st_dev; snapshotInode = copied.st_ino; snapshotSize = copied.st_size
      try validate()
      try signatureVerifier(url)
      try checkCancellation()
      try validate()
    } catch {
      clean()
      throw error
    }
  }

  static func verifyOfficialSignature(_ url: URL) throws {
    var code: SecStaticCode?, requirement: SecRequirement?
    guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code) == errSecSuccess,
          let code,
          SecRequirementCreateWithString(officialRequirement as CFString, SecCSFlags(), &requirement) == errSecSuccess,
          let requirement,
          SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), requirement) == errSecSuccess else {
      throw ExternalCredentialError.untrustedExecutable
    }
  }

  func validate() throws {
    var held = stat(), path = stat(), snapshot = stat()
    guard descriptor >= 0, fstat(descriptor, &held) == 0, lstat(directory.path, &path) == 0,
          path.st_mode & S_IFMT == S_IFDIR, path.st_uid == getuid(), path.st_mode & 0o777 == 0o700,
          held.st_dev == device, held.st_ino == inode, path.st_dev == device, path.st_ino == inode,
          fstatat(descriptor, "op", &snapshot, AT_SYMLINK_NOFOLLOW) == 0,
          snapshot.st_mode & S_IFMT == S_IFREG, snapshot.st_uid == getuid(), snapshot.st_mode & 0o777 == 0o500,
          snapshot.st_dev == snapshotDevice, snapshot.st_ino == snapshotInode, snapshot.st_size == snapshotSize else {
      throw ExternalCredentialError.untrustedExecutable
    }
  }

  func clean() {
    guard descriptor >= 0 else { return }
    _ = unlinkat(descriptor, "op", 0)
    var held = stat(), path = stat()
    if fstat(descriptor, &held) == 0, lstat(directory.path, &path) == 0,
       path.st_mode & S_IFMT == S_IFDIR, path.st_dev == device, path.st_ino == inode,
       held.st_dev == device, held.st_ino == inode { _ = rmdir(directory.path) }
    Darwin.close(descriptor); descriptor = -1
  }
  deinit { clean() }
}

private final class ProviderProcess: @unchecked Sendable {
  private let mutex = NSLock()
  private var process: Process?
  private var cancelled = false
  private func cancel() {
    mutex.lock()
    cancelled = true
    let process = process
    mutex.unlock()
    if let process, process.isRunning {
      process.terminate()
      DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
      }
    }
  }
  static func read(_ reference: ExternalCredentialReference) async throws -> String {
    let job = ProviderProcess()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
          do { continuation.resume(returning: try job.run(reference)) } catch {
            continuation.resume(throwing: error)
          }
        }
      }
    } onCancel: {
      job.cancel()
    }
  }
  private func run(_ reference: ExternalCredentialReference) throws -> String {
    let snapshot = try VerifiedProviderExecutable(source: URL(fileURLWithPath: reference.executable), checkCancellation: { [self] in
      mutex.lock(); let stopped = cancelled; mutex.unlock()
      if stopped { throw CancellationError() }
    })
    defer { snapshot.clean() }
    let child = Process()
    let pipe = Pipe()
    child.executableURL = snapshot.url
    child.arguments = ["read", "--no-newline", reference.reference]
    let environment = ProcessInfo.processInfo.environment
    child.environment = environment.filter {
      ["HOME", "TMPDIR", "LANG", "LC_ALL", "PATH"].contains($0.key)
    }
    child.environment?["OP_BIOMETRIC_UNLOCK_ENABLED"] = "true"
    child.standardInput = FileHandle.nullDevice
    child.standardOutput = pipe
    child.standardError = FileHandle.nullDevice
    mutex.lock()
    guard !cancelled else {
      mutex.unlock()
      throw CancellationError()
    }
    process = child
    do { try snapshot.validate(); try child.run() } catch {
      mutex.unlock()
      throw ExternalCredentialError.failed
    }
    mutex.unlock()
    try? pipe.fileHandleForWriting.close()
    let timeout = DispatchWorkItem { [weak self] in self?.cancel() }
    DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: timeout)
    defer {
      timeout.cancel()
      try? pipe.fileHandleForReading.close()
      cancel()
    }
    var data = Data()
    // A bounded pipe prevents large output from accumulating in memory.
    while let chunk = try pipe.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
      guard data.count + chunk.count <= 65536 else {
        cancel()
        throw ExternalCredentialError.tooLarge
      }
      data.append(chunk)
    }
    child.waitUntilExit()
    mutex.lock()
    let stopped = cancelled
    mutex.unlock()
    guard !stopped else { throw CancellationError() }
    guard child.terminationStatus == 0, let value = String(data: data, encoding: .utf8),
      !value.isEmpty, !value.contains("\0")
    else { throw ExternalCredentialError.failed }
    return value
  }
}

/// Ephemeral HTTPS with redirects refused before a token can reach another origin.
final class VaultFieldRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let mutex = NSLock()
  private var body = Data()
  private var continuation: CheckedContinuation<Data, Error>?
  private var task: URLSessionDataTask?
  private var session: URLSession?
  private var cancelled = false
  private var validResponse = false
  static func read(
    _ reference: ExternalCredentialReference, token: String,
    configuration: URLSessionConfiguration = .ephemeral
  ) async throws -> String {
    let job = VaultFieldRequest()
    var request = URLRequest(url: try reference.vaultURL())
    request.timeoutInterval = 30
    request.setValue(token, forHTTPHeaderField: "X-Vault-Token")
    if !reference.namespace.isEmpty {
      request.setValue(reference.namespace, forHTTPHeaderField: "X-Vault-Namespace")
    }
    let raw = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        job.start(request, configuration: configuration, continuation: continuation)
      }
    } onCancel: {
      job.cancel()
    }
    guard let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
      let outer = json["data"] as? [String: Any], let fields = outer["data"] as? [String: Any],
      let value = fields[reference.field] as? String, !value.isEmpty, !value.contains("\0"),
      value.utf8.count <= 65536
    else { throw ExternalCredentialError.failed }
    return value
  }
  private func start(
    _ request: URLRequest, configuration: URLSessionConfiguration,
    continuation: CheckedContinuation<Data, Error>
  ) {
    mutex.lock()
    defer { mutex.unlock() }
    guard !cancelled else {
      continuation.resume(throwing: CancellationError())
      return
    }
    self.continuation = continuation
    let config = configuration.copy() as! URLSessionConfiguration
    config.httpCookieStorage = nil
    config.urlCredentialStorage = nil
    config.urlCache = nil
    config.timeoutIntervalForResource = 30
    session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    task = session?.dataTask(with: request)
    task?.resume()
  }
  private func cancel() {
    mutex.lock()
    cancelled = true
    let task = task
    mutex.unlock()
    task?.cancel()
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) { completionHandler(nil) }
  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    validResponse =
      (response as? HTTPURLResponse)?.statusCode == 200 && response.expectedContentLength <= 262144
    completionHandler(validResponse ? .allow : .cancel)
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard body.count + data.count <= 262144 else {
      validResponse = false
      dataTask.cancel()
      return
    }
    body.append(data)
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    mutex.lock()
    let continuation = continuation
    self.continuation = nil
    let cancelled = cancelled
    mutex.unlock()
    if cancelled {
      continuation?.resume(throwing: CancellationError())
    } else if error != nil || !validResponse {
      continuation?.resume(throwing: ExternalCredentialError.failed)
    } else {
      continuation?.resume(returning: body)
    }
    body.removeAll()
    session.finishTasksAndInvalidate()
    self.session = nil
    self.task = nil
  }
}

@MainActor
final class ExternalCredentials: ObservableObject {
  @Published private(set) var references: [UUID: ExternalCredentialReference] = [:]
  @Published private(set) var notice: String?
  private let defaults: UserDefaults
  private let reader: any ExternalCredentialReading
  private let gate: CredentialAccessGate
  private var tokens: [UUID: String] = [:]
  private var pending: [UUID: Task<String, Error>] = [:]
  private let key = "external.credentials.v1"
  private var damaged = false
  init(
    defaults: UserDefaults = NethrivaDataProfile.defaults,
    reader: any ExternalCredentialReading = ExternalCredentialReader(),
    gate: CredentialAccessGate = .shared
  ) {
    self.defaults = defaults
    self.reader = reader
    self.gate = gate
    guard let raw = defaults.data(forKey: key) else { return }
    do {
      guard raw.count <= 1024 * 1024 else { throw ExternalCredentialError.invalid }
      let parsed = try JSONDecoder().decode([UUID: ExternalCredentialReference].self, from: raw)
      guard parsed.count <= 1000 else { throw ExternalCredentialError.invalid }
      try parsed.values.forEach { try $0.validate() }
      references = parsed
    } catch {
      damaged = true
      notice = "Provider settings are damaged and were preserved. Saving is disabled."
    }
  }
  func configure(_ reference: ExternalCredentialReference?, for profile: UUID) throws {
    _ = try gate.check()
    guard !damaged else { throw ExternalCredentialError.invalid }
    try reference?.validate()
    var next = references
    next[profile] = reference
    let raw = try JSONEncoder().encode(next)
    defaults.set(raw, forKey: key)
    guard defaults.data(forKey: key) == raw else { throw ExternalCredentialError.failed }
    references = next
    tokens[profile] = nil
    pending.values.forEach { $0.cancel() }
    pending.removeAll()
  }
  func authorize(_ profile: UUID, token: String) throws {
    _ = try gate.check()
    guard references[profile]?.kind == .vaultKV2, !token.isEmpty, token.count <= 8192,
      token.rangeOfCharacter(from: .controlCharacters) == nil
    else { throw ExternalCredentialError.invalid }
    tokens[profile] = token
  }
  func password(for profile: UUID) async throws -> String {
    let epoch = try gate.check()
    guard let reference = references[profile] else { throw ExternalCredentialError.invalid }
    let id = UUID()
    let token = tokens[profile]
    let reader = reader
    let task = Task { try await reader.read(reference, token: token) }
    pending[id] = task
    defer { pending[id] = nil }
    let value = try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
    guard !task.isCancelled else { throw CancellationError() }
    try Task.checkCancellation()
    try gate.check(epoch)
    guard references[profile] == reference else { throw ExternalCredentialError.failed }
    try ExternalCredentialValue.validate(value)
    return value
  }
  func clearAuthorization() {
    tokens.removeAll()
    pending.values.forEach { $0.cancel() }
    pending.removeAll()
  }
}
