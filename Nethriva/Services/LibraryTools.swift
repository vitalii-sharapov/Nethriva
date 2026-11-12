import Foundation

enum DefaultField: String, Codable, CaseIterable, Identifiable {
  case credential, port, jumpHost, gateway, appearance, keepAlive, desktopScale
  var id: String { rawValue }
  var label: String {
    switch self {
    case .credential: "Credential profile"
    case .port: "Protocol port"
    case .jumpHost: "SSH jump chain"
    case .gateway: "RDP gateway"
    case .appearance: "Terminal appearance"
    case .keepAlive: "SSH keepalive"
    case .desktopScale: "RDP interface scale"
    }
  }
  func supports(_ kind: ConnectionKind) -> Bool {
    switch self {
    case .credential: [.ssh, .telnet, .rdp].contains(kind)
    case .port: [.ssh, .telnet, .rdp, .vnc, .spice].contains(kind)
    case .jumpHost, .keepAlive: kind == .ssh
    case .gateway, .desktopScale: kind == .rdp
    case .appearance: [.localShell, .ssh, .telnet, .serial].contains(kind)
    }
  }
}

/// References only metadata. No password or executable command is permitted.
struct ConnectionDefaults: Codable, Equatable {
  var credentialProfileID: UUID?
  var ports: [ConnectionKind: Int] = [:]
  var jumpHost: String?
  var gateway: String?
  var terminalProfileID: UUID?
  var keepAlive: Int?
  var desktopScale: Int?
  func validate() throws {
    guard ports.values.allSatisfy({ (1...65535).contains($0) }),
      keepAlive.map({ (0...3600).contains($0) }) ?? true,
      desktopScale.map({ [100, 140, 180].contains($0) }) ?? true,
      gateway.map({ $0.count <= 253 && $0.rangeOfCharacter(from: .controlCharacters) == nil })
        ?? true
    else {
      throw WorkflowError.invalid("Invalid connection defaults.")
    }
    if let jumpHost { _ = try SSHJumpChain.validate(jumpHost) }
  }
  mutating func overlay(_ other: Self) {
    if let value = other.credentialProfileID { credentialProfileID = value }
    ports.merge(other.ports) { _, new in new }
    if let value = other.jumpHost { jumpHost = value }
    if let value = other.gateway { gateway = value }
    if let value = other.terminalProfileID { terminalProfileID = value }
    if let value = other.keepAlive { keepAlive = value }
    if let value = other.desktopScale { desktopScale = value }
  }
  func applying(to original: RemoteConnection, fields: Set<DefaultField>) -> RemoteConnection {
    var result = original
    for field in fields where field.supports(result.kind) {
      switch field {
      case .credential:
        if let credentialProfileID { result.credentialProfileID = credentialProfileID }
      case .port: if let port = ports[result.kind] { result.port = port }
      case .jumpHost: if let jumpHost { result.sshJumpHost = jumpHost.isEmpty ? nil : jumpHost }
      case .gateway: if let gateway { result.rdpGatewayHost = gateway.isEmpty ? nil : gateway }
      case .appearance:
        if let terminalProfileID {
          result.terminalProfileID = terminalProfileID
          result.terminalAppearance = nil
        }
      case .keepAlive: if let keepAlive { result.sshKeepAliveInterval = keepAlive }
      case .desktopScale: if let desktopScale { result.rdpScale = desktopScale }
      }
    }
    return result
  }
  func populatedFields(for kind: ConnectionKind) -> Set<DefaultField> {
    var result = Set<DefaultField>()
    if credentialProfileID != nil { result.insert(.credential) }
    if ports[kind] != nil { result.insert(.port) }
    if jumpHost != nil { result.insert(.jumpHost) }
    if gateway != nil { result.insert(.gateway) }
    if terminalProfileID != nil { result.insert(.appearance) }
    if keepAlive != nil { result.insert(.keepAlive) }
    if desktopScale != nil { result.insert(.desktopScale) }
    return Set(result.filter { $0.supports(kind) })
  }
}

struct ConnectionTemplate: Codable, Equatable, Identifiable {
  var id = UUID()
  var name = "New Template"
  var kind: ConnectionKind = .ssh
  var defaults = ConnectionDefaults()
}

@MainActor
final class LibraryTools: ObservableObject {
  struct Archive: Codable {
    var version = 1
    var profiles: [TerminalAppearance] = []
    var templates: [ConnectionTemplate] = []
    var groupDefaults: [String: ConnectionDefaults] = [:]
    var defaultTerminalProfile: UUID?
    var retentionDays = 7
  }
  @Published private(set) var data = Archive()
  @Published private(set) var notice: String?
  private let defaults: UserDefaults
  private let key = "library.tools.v1"
  private var damaged = false
  init(defaults: UserDefaults = NethrivaDataProfile.defaults) {
    self.defaults = defaults
    guard let raw = defaults.data(forKey: key) else { return }
    do {
      guard raw.count <= 4 * 1024 * 1024 else {
        throw WorkflowError.invalid("Oversized defaults library.")
      }
      let decoded = try JSONDecoder().decode(Archive.self, from: raw)
      try Self.validate(decoded)
      data = decoded
    } catch {
      damaged = true
      notice =
        "Saved templates and appearance settings could not be read. Existing data was preserved; saving is disabled."
    }
  }
  nonisolated static func validate(_ data: Archive) throws {
    guard data.version == 1, data.profiles.count <= 100, data.templates.count <= 500,
      data.groupDefaults.count <= 10000, (1...90).contains(data.retentionDays),
      Set(data.profiles.map(\.id)).count == data.profiles.count,
      Set(data.templates.map(\.id)).count == data.templates.count
    else { throw WorkflowError.invalid("Invalid defaults library.") }
    for profile in data.profiles { try profile.validate() }
    for template in data.templates {
      guard !template.name.isEmpty, template.name.count <= 200 else {
        throw WorkflowError.invalid("Invalid template name.")
      }
      try template.defaults.validate()
    }
    for (group, value) in data.groupDefaults {
      guard validGroup(group) else { throw WorkflowError.invalid("Invalid group defaults.") }
      try value.validate()
    }
  }
  nonisolated static func validGroup(_ group: String) -> Bool {
    !group.isEmpty && group.count <= 1000 && group.rangeOfCharacter(from: .controlCharacters) == nil
      && group.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
        !$0.isEmpty && $0 != "." && $0 != ".."
      }
  }
  func save(_ next: Archive) throws {
    guard !damaged else {
      throw WorkflowError.invalid(
        "The saved defaults library needs recovery before it can be changed.")
    }
    try Self.validate(next)
    let raw = try JSONEncoder().encode(next)
    guard raw.count <= 4 * 1024 * 1024 else {
      throw WorkflowError.invalid("Defaults exceed the storage limit.")
    }
    if let old = defaults.data(forKey: key) { defaults.set(old, forKey: key + ".backup") }
    defaults.set(raw, forKey: key)
    guard defaults.data(forKey: key) == raw else {
      throw ConnectionStoreError.writeVerificationFailed
    }
    data = next
  }
  func inheritedDefaults(for group: String) -> ConnectionDefaults {
    var result = ConnectionDefaults()
    var prefix = ""
    for segment in group.split(separator: "/") {
      prefix = prefix.isEmpty ? String(segment) : prefix + "/" + segment
      if let value = data.groupDefaults.first(where: {
        $0.key.caseInsensitiveCompare(prefix) == .orderedSame
      })?.value {
        result.overlay(value)
      }
    }
    return result
  }
  func resolve(_ connection: RemoteConnection) -> RemoteConnection {
    inheritedDefaults(for: connection.group).applying(
      to: connection, fields: connection.inheritedFields ?? [])
  }
  func appearance(for connection: RemoteConnection) -> TerminalAppearance {
    if let embedded = connection.terminalAppearance { return embedded }
    let id = connection.terminalProfileID ?? data.defaultTerminalProfile
    return data.profiles.first { $0.id == id } ?? .standard
  }
  func remapGroups(_ mappings: [(old: String, new: String)]) throws {
    var next = data
    var remapped: [String: ConnectionDefaults] = [:]
    for (path, value) in data.groupDefaults {
      let mapped = mappings.first {
        path.caseInsensitiveCompare($0.old) == .orderedSame
          || path.lowercased().hasPrefix($0.old.lowercased() + "/")
      }
      let destination = mapped.map { $0.new + path.dropFirst($0.old.count) } ?? path
      guard
        !remapped.keys.contains(where: { $0.caseInsensitiveCompare(destination) == .orderedSame })
      else { throw WorkflowError.invalid("Group defaults would collide at the destination.") }
      remapped[destination] = value
    }
    next.groupDefaults = remapped
    if next.groupDefaults != data.groupDefaults { try save(next) }
  }
  func removeGroup(_ path: String) throws {
    var next = data
    next.groupDefaults = next.groupDefaults.filter {
      $0.key.caseInsensitiveCompare(path) != .orderedSame
        && !$0.key.lowercased().hasPrefix(path.lowercased() + "/")
    }
    if next.groupDefaults != data.groupDefaults { try save(next) }
  }
}

struct BulkConnectionPatch {
  var fields = Set<DefaultField>()
  var defaults = ConnectionDefaults()
  var group: String?
  func apply(_ original: RemoteConnection) throws -> RemoteConnection {
    try defaults.validate()
    guard original.kind != .localShell else {
      throw WorkflowError.invalid("Local Terminal cannot be bulk edited.")
    }
    var updated = defaults.applying(to: original, fields: fields)
    if let group {
      guard LibraryTools.validGroup(group) else {
        throw WorkflowError.invalid("Invalid destination group.")
      }
      updated.group = group
    }
    updated.inheritedFields = (updated.inheritedFields ?? []).subtracting(
      fields.intersection(defaults.populatedFields(for: original.kind)))
    return updated
  }
}

/// Presentation payloads are value snapshots, not a boolean plus lazily read
/// draft state; SwiftUI must see the reviewed values on the first presentation.
struct MultiCommandReview: Identifiable {
  let id = UUID()
  let command: String
  let recipients: [TerminalCommandRouter.Recipient]
  let names: [String]
}
struct BulkEditReview: Identifiable {
  let id = UUID()
  let originals: [RemoteConnection]
  let updated: [RemoteConnection]
  let patch: BulkConnectionPatch
  let rules: [String: ConnectionDefaults]
}
