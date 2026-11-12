import Foundation

enum MigrationFormat: String, CaseIterable, Identifiable {
  case sshConfig, rdp, csv, connectionXML
  var id: String { rawValue }
  var label: String {
    switch self {
    case .sshConfig: "OpenSSH config"
    case .rdp: "Remote Desktop (.rdp)"
    case .csv: "Connection CSV"
    case .connectionXML: "Connection-tree XML"
    }
  }
}
struct MigrationPreview {
  var connections: [RemoteConnection]
  var groups: [String]
  var warnings: [String]
}

/// Pure parsing only: never executes configuration, accesses Keychain, connects,
/// follows Include directives, or accepts imported passwords.
enum MigrationImport {
  static func parse(_ data: Data, format: MigrationFormat) throws -> MigrationPreview {
    guard data.count <= 4 * 1024 * 1024 else {
      throw WorkflowError.invalid("Import files must be at most 4 MiB.")
    }
    let text: String?
    if data.starts(with: [0xff, 0xfe]) {
      text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
    } else if data.starts(with: [0xfe, 0xff]) {
      text = String(data: data.dropFirst(2), encoding: .utf16BigEndian)
    } else {
      text = String(data: data, encoding: .utf8)?.replacingOccurrences(of: "\u{feff}", with: "")
    }
    guard let text, !text.contains("\0") else {
      throw WorkflowError.invalid("Use UTF-8 or BOM-marked UTF-16 text.")
    }
    var result: MigrationPreview
    switch format {
    case .sshConfig: result = try ssh(text)
    case .rdp: result = try rdp(text)
    case .csv: result = try csv(text)
    case .connectionXML: result = try xml(text)
    }
    guard result.connections.count <= 10000, result.groups.count <= 10000 else {
      throw WorkflowError.invalid("Import exceeds 10,000 items.")
    }
    for connection in result.connections { try validate(connection) }
    guard result.groups.allSatisfy(LibraryTools.validGroup) else {
      throw WorkflowError.invalid("Invalid group path in import.")
    }
    result.warnings = Array(Set(result.warnings)).sorted()
    return result
  }
  static func validate(_ connection: RemoteConnection) throws {
    guard [.ssh, .rdp, .telnet, .vnc].contains(connection.kind),
      !connection.name.isEmpty, connection.name.count <= 200,
      connection.name.rangeOfCharacter(from: .controlCharacters) == nil,
      !connection.host.isEmpty, connection.host.count <= 253, !connection.host.hasPrefix("-"),
      connection.host.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters))
        == nil,
      !connection.host.contains("/"), !connection.host.contains("@"),
      (1...65535).contains(connection.port), connection.username.count <= 200,
      connection.username.rangeOfCharacter(from: .controlCharacters) == nil,
      LibraryTools.validGroup(connection.group), connection.credentialProfileID == nil
    else {
      throw WorkflowError.invalid("Import contains an invalid connection field. Nothing was saved.")
    }
    if let jump = connection.sshJumpHost { _ = try SSHJumpChain.validate(jump) }
    for value in [connection.sshIdentityFile, connection.rdpGatewayHost, connection.rdpDomain]
      .compactMap({ $0 })
    {
      guard value.count <= 1000, value.rangeOfCharacter(from: .controlCharacters) == nil else {
        throw WorkflowError.invalid("Import contains invalid connection options.")
      }
    }
  }
  static func endpoint(_ text: String, defaultPort: Int) throws -> (String, Int) {
    if text.hasPrefix("[") {
      guard let close = text.firstIndex(of: "]") else {
        throw WorkflowError.invalid("Invalid bracketed endpoint.")
      }
      let host = String(text[text.index(after: text.startIndex)..<close])
      let suffix = String(text[text.index(after: close)...])
      guard suffix.isEmpty || suffix.hasPrefix(":"),
        suffix.isEmpty || Int(suffix.dropFirst()) != nil
      else { throw WorkflowError.invalid("Invalid endpoint port.") }
      return (host, suffix.isEmpty ? defaultPort : Int(suffix.dropFirst())!)
    }
    if text.filter({ $0 == ":" }).count == 1 {
      let parts = text.split(separator: ":", omittingEmptySubsequences: false)
      guard let port = Int(parts[1]) else { throw WorkflowError.invalid("Invalid endpoint port.") }
      return (String(parts[0]), port)
    }
    return (text, defaultPort)
  }
  private static func rdp(_ text: String) throws -> MigrationPreview {
    var values: [String: String] = [:]
    var warnings = [
      "Passwords, device redirection, automatic programs and unsupported RDP properties are not imported. Review authentication and redirection in the connection editor."
    ]
    let allowed: Set<String> = [
      "full address", "server port", "username", "domain", "gatewayhostname", "redirectclipboard",
      "desktopscalefactor", "autoreconnection enabled", "administrative session",
    ]
    for line in text.components(separatedBy: .newlines) where !line.isEmpty {
      let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
      guard parts.count == 3 else { throw WorkflowError.invalid("Invalid RDP property line.") }
      let key = parts[0].lowercased()
      guard allowed.contains(key) else { continue }
      let expected =
        ["full address", "username", "domain", "gatewayhostname"].contains(key) ? "s" : "i"
      guard parts[1] == expected else { throw WorkflowError.invalid("Invalid RDP property type.") }
      values[key] = String(parts[2])
    }
    guard let address = values["full address"] else {
      throw WorkflowError.invalid("RDP file has no full address.")
    }
    let endpoint = try endpoint(address, defaultPort: 3389)
    var connection = RemoteConnection(
      name: endpoint.0, kind: .rdp, host: endpoint.0, port: endpoint.1,
      username: values["username"] ?? "", group: "Imported")
    if let port = values["server port"] {
      guard let value = Int(port) else { throw WorkflowError.invalid("Invalid RDP port.") }
      connection.port = value
    }
    connection.rdpDomain = values["domain"]
    connection.rdpGatewayHost = values["gatewayhostname"]
    connection.rdpCertificatePolicy = .systemValidation
    if let scale = values["desktopscalefactor"], let value = Int(scale),
      [100, 140, 180].contains(value)
    {
      connection.rdpScale = value
    }
    for key in ["redirectclipboard", "autoreconnection enabled", "administrative session"] {
      guard let raw = values[key] else { continue }
      guard ["0", "1"].contains(raw) else {
        throw WorkflowError.invalid("Invalid RDP boolean property.")
      }
      if key == "redirectclipboard" { connection.rdpClipboard = raw == "1" }
      if key == "autoreconnection enabled" { connection.rdpAutoReconnect = raw == "1" }
      if key == "administrative session" { connection.rdpAdminSession = raw == "1" }
    }
    if !values.keys.contains("redirectclipboard") { connection.rdpClipboard = false }
    warnings.append(
      "RDP certificate checking defaults to Require Valid Certificate; imported authentication exceptions are ignored."
    )
    return MigrationPreview(connections: [connection], groups: ["Imported"], warnings: warnings)
  }
  static func csvRows(_ text: String) throws -> [[String]] {
    var rows: [[String]] = []
    var row: [String] = []
    var field = ""
    var quoted = false
    var closed = false
    var fieldBytes = 0
    let chars = Array(text)
    var index = 0
    func finishField() {
      row.append(field)
      field = ""
      closed = false
      fieldBytes = 0
    }
    func append(_ char: Character) {
      field.append(char)
      fieldBytes += char.utf8.count
    }
    while index < chars.count {
      let char = chars[index]
      if quoted {
        if char == "\"" {
          if index + 1 < chars.count && chars[index + 1] == "\"" {
            append("\"")
            index += 1
          } else {
            quoted = false
            closed = true
          }
        } else {
          append(char)
        }
      } else if char == "\"" {
        guard field.isEmpty, !closed else { throw WorkflowError.invalid("Invalid CSV quoting.") }
        quoted = true
      } else if char == "," {
        finishField()
      } else if char == "\n" || char == "\r" || char == "\r\n" {
        finishField()
        if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
        row = []
        if char == "\r", index + 1 < chars.count, chars[index + 1] == "\n" { index += 1 }
      } else {
        guard !closed else {
          throw WorkflowError.invalid("Invalid characters after a quoted CSV field.")
        }
        append(char)
      }
      guard fieldBytes <= 16384, row.count <= 32, rows.count <= 10000 else {
        throw WorkflowError.invalid("CSV exceeds field or record limits.")
      }
      index += 1
    }
    guard !quoted else { throw WorkflowError.invalid("Unclosed CSV field.") }
    finishField()
    if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
    return rows
  }
  private static func csv(_ text: String) throws -> MigrationPreview {
    let rows = try csvRows(text)
    guard let header = rows.first else { throw WorkflowError.invalid("CSV is empty.") }
    let keys = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    guard Set(keys).count == keys.count, keys.contains("host"), keys.contains("protocol") else {
      throw WorkflowError.invalid("CSV requires unique headers including host and protocol.")
    }
    let supported: Set<String> = [
      "name", "protocol", "host", "port", "username", "group", "domain", "gateway", "favorite",
    ]
    var connections: [RemoteConnection] = []
    for row in rows.dropFirst() {
      guard row.count == keys.count else {
        throw WorkflowError.invalid("CSV row length does not match its header.")
      }
      let values = Dictionary(uniqueKeysWithValues: zip(keys, row))
      guard let kind = ConnectionKind(rawValue: values["protocol"]!.lowercased()),
        [.ssh, .telnet, .rdp, .vnc].contains(kind)
      else { throw WorkflowError.invalid("CSV protocol must be ssh, telnet, rdp or vnc.") }
      let port: Int
      if let raw = values["port"], !raw.isEmpty {
        guard let value = Int(raw) else { throw WorkflowError.invalid("Invalid CSV port.") }
        port = value
      } else {
        port = kind.defaultPort
      }
      let host = values["host"]!
      var connection = RemoteConnection(
        name: values["name"].flatMap { $0.isEmpty ? nil : $0 } ?? host, kind: kind, host: host,
        port: port, username: values["username"] ?? "",
        group: values["group"].flatMap { $0.isEmpty ? nil : $0 } ?? "Imported")
      if let favorite = values["favorite"], !favorite.isEmpty {
        guard ["true", "false", "1", "0"].contains(favorite.lowercased()) else {
          throw WorkflowError.invalid("Invalid CSV favorite value.")
        }
        connection.isFavorite = ["true", "1"].contains(favorite.lowercased())
      }
      if kind == .rdp {
        connection.rdpDomain = values["domain"]
        connection.rdpGatewayHost = values["gateway"]
        connection.rdpClipboard = false
        connection.rdpCertificatePolicy = .systemValidation
      }
      connections.append(connection)
    }
    return MigrationPreview(
      connections: connections, groups: Array(Set(connections.map(\.group))),
      warnings: keys.contains(where: { !supported.contains($0) })
        ? ["Unknown columns, including any passwords, are ignored and never saved."] : [])
  }
  static func sshTokens(_ line: String) throws -> [String] {
    var tokens: [String] = []
    var token = ""
    var quote: Character?
    var escaped = false
    for char in line {
      if escaped {
        token.append(char)
        escaped = false
      } else if char == "\\" {
        escaped = true
      } else if let active = quote {
        if char == active { quote = nil } else { token.append(char) }
      } else if char == "\"" || char == "'" {
        quote = char
      } else if char == "#" {
        break
      } else if char == "=", tokens.count == 1, token.isEmpty {
        continue
      } else if char.isWhitespace || (char == "=" && tokens.isEmpty) {
        if !token.isEmpty {
          tokens.append(token)
          token = ""
        }
      } else {
        token.append(char)
      }
    }
    guard !escaped, quote == nil else {
      throw WorkflowError.invalid("Invalid SSH configuration quoting.")
    }
    if !token.isEmpty { tokens.append(token) }
    return tokens
  }
  private static func ssh(_ text: String) throws -> MigrationPreview {
    struct Block {
      var aliases: [String]
      var values: [String: String]
    }
    var blocks: [Block] = []
    var current = Block(aliases: [], values: [:])
    var global: [String: String] = [:]
    var matching = false
    var sawHost = false
    var warnings = [
      "Include/Match, wildcard hosts and command/forwarding directives are not imported. Review aliases and authentication options; your Mac’s existing SSH config still applies at session time."
    ]
    let supported: Set<String> = [
      "hostname", "user", "port", "identityfile", "proxyjump", "forwardagent", "compression",
      "serveraliveinterval",
    ]
    for line in text.components(separatedBy: .newlines) {
      let tokens = try sshTokens(line)
      guard let first = tokens.first else { continue }
      let key = first.lowercased()
      if key == "host" {
        sawHost = true
        if !current.aliases.isEmpty { blocks.append(current) }
        current = Block(
          aliases: Array(tokens.dropFirst()).filter { !$0.contains(where: { "*?!".contains($0) }) },
          values: [:])
        matching = false
      } else if key == "match" {
        matching = true
      } else if !matching, supported.contains(key), tokens.count >= 2 {
        let value = tokens.dropFirst().joined(separator: " ")
        if !sawHost {
          if global[key] == nil { global[key] = value }
        } else if current.values[key] == nil {
          current.values[key] = value
        }
      }
    }
    if !current.aliases.isEmpty { blocks.append(current) }
    var connections: [RemoteConnection] = []
    var seen = Set<String>()
    for block in blocks {
      let values = global.merging(block.values) { earlier, _ in earlier }
      for alias in block.aliases where seen.insert(alias).inserted {
        guard !alias.contains("%") else { continue }
        var connection = RemoteConnection(
          name: alias, kind: .ssh, host: values["hostname"] ?? alias,
          username: values["user"] ?? "", group: "Imported/SSH")
        if let port = values["port"] {
          guard let value = Int(port) else { throw WorkflowError.invalid("Invalid SSH port.") }
          connection.port = value
        }
        if connection.host.contains("%") {
          throw WorkflowError.invalid(
            "SSH hostname tokens are not supported; replace them with an explicit host before importing."
          )
        }
        if let identity = values["identityfile"], !identity.contains("%") {
          connection.sshIdentityFile = identity
        }
        if let jump = values["proxyjump"], jump.lowercased() != "none" {
          connection.sshJumpHost = jump
        }
        for key in ["forwardagent", "compression"] {
          if let value = values[key] {
            guard ["yes", "no"].contains(value.lowercased()) else {
              throw WorkflowError.invalid("Unsupported SSH boolean option.")
            }
            if key == "forwardagent" {
              connection.sshForwardAgent = value.lowercased() == "yes"
            } else {
              connection.sshCompression = value.lowercased() == "yes"
            }
          }
        }
        if let value = values["serveraliveinterval"] {
          guard let interval = Int(value), (0...3600).contains(interval) else {
            throw WorkflowError.invalid("Invalid SSH keepalive.")
          }
          connection.sshKeepAliveInterval = interval
        }
        connections.append(connection)
      }
    }
    if connections.isEmpty { warnings.append("No explicit supported Host entries were found.") }
    return MigrationPreview(
      connections: connections, groups: ["Imported", "Imported/SSH"], warnings: warnings)
  }
  private static func xml(_ text: String) throws -> MigrationPreview {
    guard !text.localizedCaseInsensitiveContains("<!DOCTYPE"),
      !text.localizedCaseInsensitiveContains("<!ENTITY")
    else { throw WorkflowError.invalid("XML declarations with DTDs or entities are not accepted.") }
    let delegate = ConnectionXMLReader()
    let parser = XMLParser(data: Data(text.utf8))
    parser.shouldResolveExternalEntities = false
    parser.shouldProcessNamespaces = true
    parser.delegate = delegate
    guard parser.parse(), !delegate.failed, delegate.validRoot else {
      throw WorkflowError.invalid("Unsupported or invalid connection-tree XML.")
    }
    return MigrationPreview(
      connections: delegate.connections, groups: Array(delegate.groups),
      warnings: [
        "Only Node/Connection attributes for RDP, SSH2, Telnet and VNC are imported. Passwords, encryption settings, inherited fields and unsupported protocols/options are ignored. Review each preview before saving."
      ])
  }
}

/// Node-based connection-tree export. Attribute allowlist; no entity resolution.
private final class ConnectionXMLReader: NSObject, XMLParserDelegate {
  var connections: [RemoteConnection] = []
  var groups = Set<String>()
  var failed = false, validRoot = false
  private var stack: [(element: String, group: String)] = []
  func parser(
    _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
    qualifiedName: String?, attributes: [String: String]
  ) {
    guard stack.count < 64, connections.count < 10000 else {
      failed = true
      parser.abortParsing()
      return
    }
    if stack.isEmpty {
      validRoot = ["Connections", "ConnectionTree"].contains(elementName)
      if attributes["FullFileEncryption"]?.lowercased() == "true" { validRoot = false }
      if !validRoot {
        failed = true
        parser.abortParsing()
        return
      }
    }
    let parent = stack.last?.group ?? "Imported"
    let name = attributes["Name"] ?? ""
    var group = parent
    if (elementName == "Node" && attributes["Type"] == "Container") || elementName == "Group" {
      guard !name.isEmpty, !name.contains("/"),
        name.rangeOfCharacter(from: .controlCharacters) == nil
      else {
        failed = true
        parser.abortParsing()
        return
      }
      group = parent + "/" + name
      groups.insert(group)
    } else if ["Node", "Connection"].contains(elementName),
      let host = attributes["Hostname"] ?? attributes["Host"]
    {
      let kinds: [String: ConnectionKind] = [
        "RDP": .rdp, "SSH2": .ssh, "SSH": .ssh, "Telnet": .telnet, "VNC": .vnc,
      ]
      if let kind = kinds[attributes["Protocol"] ?? ""] {
        let rawPort = attributes["Port"] ?? String(kind.defaultPort)
        guard let port = Int(rawPort) else {
          failed = true
          parser.abortParsing()
          return
        }
        var connection = RemoteConnection(
          name: name.isEmpty ? host : name, kind: kind, host: host, port: port,
          username: attributes["Username"] ?? "", group: group)
        if kind == .rdp {
          connection.rdpDomain = attributes["Domain"]
          connection.rdpClipboard = false
          connection.rdpCertificatePolicy = .systemValidation
        }
        connections.append(connection)
      }
    }
    stack.append((elementName, group))
  }
  func parser(
    _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
    qualifiedName: String?
  ) { if !stack.isEmpty { stack.removeLast() } }
  func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?)
    -> Data?
  {
    failed = true
    parser.abortParsing()
    return nil
  }
}
