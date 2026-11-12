import CryptoKit
import Darwin
import Foundation

/// Deliberate allowlist, not a sanitized full connection. No credential UUID,
/// username/domain, executable, key path, tunnel, clipboard or trust bypass.
struct SharedConnection: Codable, Equatable, Identifiable {
  var id: UUID
  var name: String
  var kind: ConnectionKind
  var host: String
  var port: Int
  var group: String
  var platform: VirtualizationPlatform?
  init(_ connection: RemoteConnection, sharedID: UUID? = nil) {
    id = sharedID ?? connection.id
    name = connection.name
    kind = connection.kind
    host = connection.host
    port = connection.port
    group = connection.group
    platform = connection.kind == .virtualization ? connection.virtualization?.platform : nil
  }
  func personalConnection(id: UUID = UUID()) -> RemoteConnection {
    var result = RemoteConnection(
      id: id, name: name, kind: kind, host: host, port: port, group: group)
    if let platform { result.virtualization = VirtualizationConfiguration(platform: platform) }
    // Shared files never enable access to local clipboard/folders/devices.
    result.rdpClipboard = false
    result.rdpCertificatePolicy = .systemValidation
    return result
  }
  enum Field: String, CaseIterable, Identifiable {
    case name, kind, host, port, group, platform
    var id: String { rawValue }
  }
  func value(_ field: Field) -> String {
    switch field {
    case .name: name
    case .kind: kind.rawValue
    case .host: host
    case .port: String(port)
    case .group: group
    case .platform: platform?.rawValue ?? ""
    }
  }
  func applying(_ field: Field, to result: inout RemoteConnection) {
    switch field {
    case .name: result.name = name
    case .kind: result.kind = kind
    case .host: result.host = host
    case .port:
      result.port = port
      result.inheritedFields?.remove(.port)
    case .group: result.group = group
    case .platform:
      if let platform {
        var config = result.virtualization ?? VirtualizationConfiguration()
        config.platform = platform
        result.virtualization = config
      }
    }
  }
}

struct SharedLibraryDocument: Codable, Equatable, Identifiable {
  var format = "com.vitalii.nethriva.shared-library"
  var version = 1
  var id = UUID()
  var name: String
  var groups: [String]
  var connections: [SharedConnection]
  func validate() throws {
    guard format == "com.vitalii.nethriva.shared-library", version == 1, !name.isEmpty,
      name.count <= 200,
      name.rangeOfCharacter(from: .controlCharacters) == nil,
      groups.count <= 10000, connections.count <= 10000,
      Set(connections.map(\.id)).count == connections.count,
      groups.allSatisfy(LibraryTools.validGroup)
    else { throw SharedLibraryError.invalid }
    for item in connections {
      guard item.kind != .localShell, item.kind != .serial, !item.name.isEmpty,
        item.name.count <= 200,
        item.name.rangeOfCharacter(from: .controlCharacters) == nil,
        LibraryTools.validGroup(item.group),
        !item.host.isEmpty, item.host.count <= 253, !item.host.hasPrefix("-"),
        item.host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
        !item.host.contains("@"), !item.host.contains("/"), (1...65535).contains(item.port),
        (item.kind == .virtualization) == (item.platform != nil)
      else { throw SharedLibraryError.invalid }
    }
  }
  static func decode(_ raw: Data) throws -> Self {
    guard raw.count <= 4 * 1024 * 1024 else { throw SharedLibraryError.invalid }
    // Reject unknown fields rather than silently accepting a file carrying
    // passwords/usernames/provider settings that a teammate thought safe.
    guard let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
      Set(json.keys).isSubset(of: ["format", "version", "id", "name", "groups", "connections"]),
      let items = json["connections"] as? [[String: Any]],
      items.allSatisfy({
        Set($0.keys).isSubset(of: ["id", "name", "kind", "host", "port", "group", "platform"])
      })
    else { throw SharedLibraryError.invalid }
    let decoded = try JSONDecoder().decode(Self.self, from: raw)
    try decoded.validate()
    return decoded
  }
  func encode() throws -> Data {
    try validate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let raw = try encoder.encode(self)
    guard raw.count <= 4 * 1024 * 1024 else { throw SharedLibraryError.invalid }
    return raw
  }
}

enum SharedLibraryError: LocalizedError {
  case invalid, replaced, changed, damaged
  var errorDescription: String? {
    switch self {
    case .invalid:
      "This is not a supported password-free shared library. Local/serial connections, credentials and unknown fields are not accepted."
    case .replaced:
      "The file belongs to another library. Link it separately instead of replacing this library’s baseline."
    case .changed:
      "The library or personal records changed after preview. Refresh and review again; nothing was merged."
    case .damaged: "Local library links could not be read and were preserved. Saving is disabled."
    }
  }
}

struct SharedLibraryLink: Codable, Equatable, Identifiable {
  var id: UUID { baseline.id }
  var path: String
  var baseline: SharedLibraryDocument
  var mapping: [UUID: UUID]  // Shared UUID -> private local UUID, never copied to a shared file.
  var fingerprint: Data
}

struct SharedMergeConflict: Identifiable {
  var id: String { "\(sharedID):\(field.rawValue)" }
  let sharedID: UUID
  let field: SharedConnection.Field
  let connectionName: String
  let personal: String
  let incoming: String
}

struct SharedLibraryReview: Identifiable {
  var id = UUID()
  let document: SharedLibraryDocument
  let path: String
  let fingerprint: Data
  let link: SharedLibraryLink?
  let originals: [RemoteConnection]
  var conflicts: [SharedMergeConflict] {
    guard let link else { return [] }
    let original = Dictionary(uniqueKeysWithValues: originals.map { ($0.id, $0) })
    let baseline = Dictionary(uniqueKeysWithValues: link.baseline.connections.map { ($0.id, $0) })
    return document.connections.flatMap { incoming -> [SharedMergeConflict] in
      guard let previous = baseline[incoming.id], let id = link.mapping[incoming.id],
        let local = original[id]
      else { return [] }
      let personal = SharedConnection(local, sharedID: incoming.id)
      return SharedConnection.Field.allCases.compactMap { field in
        let endpoint = [.host, .port, .kind, .platform].contains(field)
        guard incoming.value(field) != previous.value(field),
          personal.value(field) != incoming.value(field),
          endpoint || personal.value(field) != previous.value(field)
        else { return nil }
        return SharedMergeConflict(
          sharedID: incoming.id, field: field, connectionName: incoming.name,
          personal: personal.value(field), incoming: incoming.value(field))
      }
    }
  }
  /// Unrelated/personal configuration is retained, including credential UUIDs,
  /// profiles, appearance, flags and passwords (which this layer cannot read).
  func merged(takeShared: Set<String>) throws -> (
    connections: [RemoteConnection], link: SharedLibraryLink
  ) {
    try document.validate()
    var result = originals
    var mapping = link?.mapping ?? [:]
    let baseline = Dictionary(
      uniqueKeysWithValues: (link?.baseline.connections ?? []).map { ($0.id, $0) })
    for incoming in document.connections {
      if let localID = mapping[incoming.id] {
        // A personal deletion is a tombstone until the link is removed.
        guard let index = result.firstIndex(where: { $0.id == localID }),
          let previous = baseline[incoming.id]
        else { continue }
        let personal = SharedConnection(result[index], sharedID: incoming.id)
        var candidate = result[index]
        for field in SharedConnection.Field.allCases {
          let remoteChanged = incoming.value(field) != previous.value(field)
          let localChanged = personal.value(field) != previous.value(field)
          let conflictID = "\(incoming.id):\(field.rawValue)"
          let endpoint = [.host, .port, .kind, .platform].contains(field)
          if remoteChanged && ((!localChanged && !endpoint) || takeShared.contains(conflictID)) {
            incoming.applying(field, to: &candidate)
          }
        }
        let destination = SharedConnection(candidate, sharedID: incoming.id)
        try SharedLibraryDocument(name: "Review", groups: [], connections: [destination]).validate()
        if [.host, .port, .kind, .platform].contains(where: {
          personal.value($0) != destination.value($0)
        }) {
          // Never retarget a private password/profile to a changed
          // shared endpoint. Keep the old personal client independent
          // and create a new, credential-free client for that target.
          let fresh = destination.personalConnection()
          result.append(fresh)
          mapping[incoming.id] = fresh.id
        } else {
          result[index] = candidate
        }
      } else {
        let new = incoming.personalConnection()
        result.append(new)
        mapping[incoming.id] = new.id
      }
    }
    // Shared deletions never silently delete a personal client or password.
    // Its local copy becomes independent and remains in the current group.
    let ids = Set(document.connections.map(\.id))
    mapping = mapping.filter { ids.contains($0.key) }
    return (
      result, .init(path: path, baseline: document, mapping: mapping, fingerprint: fingerprint)
    )
  }
}

enum SharedLibraryFile {
  static func read(_ url: URL) throws -> (SharedLibraryDocument, Data) {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard descriptor >= 0 else { throw SharedLibraryError.invalid }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_size <= 4 * 1024 * 1024
    else { throw SharedLibraryError.invalid }
    var data = Data()
    while let chunk = try handle.read(upToCount: 65536), !chunk.isEmpty {
      guard data.count + chunk.count <= 4 * 1024 * 1024 else { throw SharedLibraryError.invalid }
      data.append(chunk)
    }
    return (try SharedLibraryDocument.decode(data), Data(SHA256.hash(data: data)))
  }
  /// Creating a new copy is intentional: refresh never writes teammates' files
  /// or publishes personal overrides automatically.
  static func create(_ document: SharedLibraryDocument, at url: URL) throws {
    let raw = try document.encode()
    let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw SharedLibraryError.invalid }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    do {
      try handle.write(contentsOf: raw)
      try handle.synchronize()
    } catch { throw SharedLibraryError.invalid }
  }
}

@MainActor
final class SharedLibraries: ObservableObject {
  @Published private(set) var links: [SharedLibraryLink] = []
  @Published private(set) var notice: String?
  private let defaults: UserDefaults
  private let key = "shared.libraries.v1"
  private var damaged = false
  init(defaults: UserDefaults = NethrivaDataProfile.defaults) {
    self.defaults = defaults
    guard let raw = defaults.data(forKey: key) else { return }
    do {
      guard raw.count <= 16 * 1024 * 1024 else { throw SharedLibraryError.invalid }
      let parsed = try JSONDecoder().decode([SharedLibraryLink].self, from: raw)
      guard parsed.count <= 100, Set(parsed.map(\.id)).count == parsed.count else {
        throw SharedLibraryError.invalid
      }
      for link in parsed {
        try link.baseline.validate()
        guard link.path.hasPrefix("/"), link.path.rangeOfCharacter(from: .controlCharacters) == nil,
          link.mapping.count <= 10000, Set(link.mapping.values).count == link.mapping.count,
          Set(link.mapping.keys).isSubset(of: Set(link.baseline.connections.map(\.id))),
          link.fingerprint.count == 32
        else { throw SharedLibraryError.invalid }
      }
      links = parsed
    } catch {
      damaged = true
      notice = SharedLibraryError.damaged.localizedDescription
    }
  }
  func save(_ link: SharedLibraryLink) throws {
    var next = links
    next.removeAll { $0.id == link.id }
    next.append(link)
    try persist(next)
  }
  func unlink(_ id: UUID) throws { try persist(links.filter { $0.id != id }) }
  private func persist(_ next: [SharedLibraryLink]) throws {
    guard !damaged, next.count <= 100 else { throw SharedLibraryError.damaged }
    let raw = try JSONEncoder().encode(next)
    guard raw.count <= 16 * 1024 * 1024 else { throw SharedLibraryError.invalid }
    defaults.set(raw, forKey: key)
    guard defaults.data(forKey: key) == raw else { throw SharedLibraryError.damaged }
    links = next
  }
  func review(_ url: URL, originals: [RemoteConnection]) async throws -> SharedLibraryReview {
    let (document, fingerprint) = try await Task.detached { try SharedLibraryFile.read(url) }.value
    let link = links.first { $0.id == document.id }
    if let existing = links.first(where: { $0.path == url.path }), existing.id != document.id {
      throw SharedLibraryError.replaced
    }
    return .init(
      document: document, path: url.path, fingerprint: fingerprint, link: link, originals: originals
    )
  }
}
