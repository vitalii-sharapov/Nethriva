import AppKit
import SwiftTerm
import XCTest

@testable import Nethriva

final class LibraryToolsTests: XCTestCase {
  @MainActor func testSessionInheritanceIsFrozenForLiveTransportIdentity() throws {
    let fixture = Fixture()
    defer { fixture.clean() }
    var connection = RemoteConnection(
      name: "Synthetic", kind: .ssh, host: "host.example.invalid", group: "Example")
    connection.inheritedFields = [.port]
    fixture.store.items = [.localShell, connection]
    var data = fixture.tools.data
    data.groupDefaults["Example"] = ConnectionDefaults(ports: [.ssh: 2222])
    try fixture.tools.save(data)
    let state = fixture.state()
    state.open(connection)
    let snapshot = try XCTUnwrap(state.tabs.first?.connection)
    let key = SSHConnectionReuse.controlKey(for: snapshot)
    XCTAssertNil(snapshot.inheritedFields)
    data.groupDefaults["Example"] = ConnectionDefaults(ports: [.ssh: 2200])
    try fixture.tools.save(data)
    XCTAssertEqual(state.resolvedConnection(for: connection).port, 2200)
    XCTAssertEqual(state.resolvedConnection(for: snapshot).port, 2222)
    XCTAssertEqual(SSHConnectionReuse.controlKey(for: state.resolvedConnection(for: snapshot)), key)
  }
  @MainActor func testCredentialPromptStopsRecordingAndStalePromptsCannotStopNewCapture()
    async throws
  {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "NethrivaPromptLogs-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let experience = TerminalExperience(root: root)
    let id = UUID()
    let oldView = TerminalView(frame: .zero)
    let old = TerminalCapture(view: oldView, id: id, experience: experience)
    try await experience.start(id, retentionDays: 7)
    old.output(Array("Pass".utf8)[...])
    old.output(Array("word:".utf8)[...])
    XCTAssertFalse(experience.recording.contains(id))
    XCTAssertNotNil(experience.notice)
    let view = TerminalView(frame: .zero)
    let current = TerminalCapture(view: view, id: id, experience: experience)
    try await experience.start(id, retentionDays: 7)
    old.output(Array("Password:".utf8)[...])
    XCTAssertTrue(experience.recording.contains(id))
    current.close()
    XCTAssertFalse(experience.recording.contains(id))
  }
  @MainActor func testUngroupedIsAlwaysAValidBulkDestinationAndDefaultPickerOption() throws {
    let fixture = Fixture()
    defer { fixture.clean() }
    let connection = RemoteConnection(
      name: "Synthetic", kind: .ssh, host: "host.example.invalid", group: "Example")
    fixture.store.items = [.localShell, connection]
    let state = fixture.state()
    XCTAssertTrue(state.editableGroupPaths.contains("Ungrouped"))
    try state.applyBulk(BulkConnectionPatch(group: "Ungrouped"), ids: [connection.id])
    XCTAssertEqual(state.connections.first { $0.id == connection.id }?.group, "Ungrouped")
  }
  @MainActor func testReviewPayloadsPreserveExactValuesAndBulkRejectsStaleMetadata() throws {
    let router = TerminalCommandRouter()
    let id = UUID()
    let view = NSObject()
    router.register(id, identity: view) { _ in true }
    var command = "echo synthetic"
    let review = MultiCommandReview(
      command: command, recipients: try router.prepare([id], command: command), names: ["Synthetic"]
    )
    command = "changed draft"
    XCTAssertEqual(review.command, "echo synthetic")
    XCTAssertEqual(review.recipients.count, 1)
    XCTAssertEqual(review.names, ["Synthetic"])
    let fixture = Fixture()
    defer { fixture.clean() }
    let connection = RemoteConnection(name: "Synthetic", kind: .ssh, host: "host.example.invalid")
    fixture.store.items = [.localShell, connection]
    let state = fixture.state()
    let patch = BulkConnectionPatch(
      fields: [.port], defaults: ConnectionDefaults(ports: [.ssh: 2222]))
    var changed = connection
    changed.name = "Renamed"
    try state.update(changed, password: nil)
    XCTAssertThrowsError(try state.applyBulk(patch, ids: [connection.id], expected: [connection]))
    XCTAssertEqual(state.connections.first { $0.id == connection.id }?.port, 22)
    XCTAssertEqual(fixture.vault.calls, 0)
  }
  @MainActor func testTerminalProfileAppliesFontThemeCursorAndScrollback() {
    let profile = TerminalAppearance(
      name: "Synthetic", fontName: "Monaco", fontSize: 18, theme: .light, cursor: .bar,
      scrollback: 1000)
    let view = TerminalView(frame: .zero, options: profile.options)
    profile.apply(view)
    XCTAssertEqual(view.font.pointSize, 18)
    view.feed(text: String(repeating: "Synthetic line\r\n", count: 1100))
    let snapshot = view.terminalContentSnapshot(region: .all)
    XCTAssertLessThanOrEqual(snapshot?.rows.count ?? Int.max, 1000 + view.terminalStateSnapshot().dimensions.rows)
    XCTAssertGreaterThanOrEqual(snapshot?.rows.count ?? 0, 1000)
    XCTAssertEqual(view.terminalStateSnapshot().cursorStyle, .steadyBar)
    XCTAssertEqual(view.nativeForegroundColor, .black)
  }
  @MainActor func testCredentialProfilesReferencedByDefaultsCannotBeDeleted() throws {
    let fixture = Fixture()
    defer { fixture.clean() }
    let state = fixture.state()
    let profile = CredentialProfile(name: "Synthetic", username: "admin")
    try state.saveProfile(profile, password: nil)
    var data = fixture.tools.data
    data.groupDefaults["Org"] = ConnectionDefaults(credentialProfileID: profile.id)
    try fixture.tools.save(data)
    XCTAssertGreaterThan(state.profileUsageCount(profile.id), 0)
    XCTAssertThrowsError(try state.deleteProfile(profile))
    XCTAssertEqual(fixture.vault.calls, 0)
  }
  func testLogSizeLimitStopsWithoutExceedingEightMiB() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "NethrivaLogLimit-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("session-" + UUID().uuidString + ".log")
    let writer = try TerminalLogWriter(url: url)
    let failure = expectation(description: "size limit stops recording")
    writer.onFailure = { failure.fulfill() }
    let chunk = Array(String(repeating: String(repeating: "x", count: 1023) + "\n", count: 64).utf8)
    for _ in 0..<150 {
      writer.append(chunk[...])
      await writer.waitForPendingWrites()
    }
    writer.stop()
    await writer.waitForPendingWrites()
    await fulfillment(of: [failure], timeout: 2)
    let size =
      (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
      ?? 0
    XCTAssertGreaterThan(size, 7 * 1024 * 1024)
    XCTAssertLessThanOrEqual(size, 8 * 1024 * 1024)
  }
  func testOutputSearchReadOnlyNumberedBoundedAndCaseInsensitive() {
    XCTAssertEqual(TerminalOutputSearch.matches("one\nTWO\nthree", query: "two"), "2: TWO")
    XCTAssertEqual(TerminalOutputSearch.matches("one", query: "missing"), "No matching output.")
    XCTAssertEqual(
      TerminalOutputSearch.matches(
        (0..<1000).map { "line \($0)" }.joined(separator: "\n"), query: "line"
      ).split(separator: "\n").count, 500)
  }
  func testArchiveCannotEnableExistingLocalGroupInheritance() {
    var connection = RemoteConnection(
      name: "Synthetic", kind: .ssh, host: "host.example.invalid", group: "Example")
    connection.inheritedFields = [.credential]
    XCTAssertThrowsError(
      try ConnectionTransferService.encodePlain(
        ConnectionArchive(groups: ["Example"], connections: [connection])))
  }
  func testAppearanceBoundsAndLegacyConnectionDecode() throws {
    let legacy = RemoteConnection(name: "Synthetic", kind: .ssh, host: "host.example.invalid")
    let roundTrip = try JSONDecoder().decode(
      RemoteConnection.self, from: JSONEncoder().encode(legacy))
    XCTAssertNil(roundTrip.inheritedFields)
    XCTAssertNil(roundTrip.terminalProfileID)
    try TerminalAppearance.standard.validate()
    var invalid = TerminalAppearance.standard
    invalid.fontSize = 99
    XCTAssertThrowsError(try invalid.validate())
    invalid = .standard
    invalid.scrollback = 10001
    XCTAssertThrowsError(try invalid.validate())
  }
  @MainActor func testMultiSessionPreflightStaleTargetsAndPartialDelivery() throws {
    let router = TerminalCommandRouter()
    let a = UUID()
    let b = UUID()
    let c = UUID()
    let viewA = NSObject()
    let viewB = NSObject()
    let viewC = NSObject()
    var aReceived: [String] = []
    var bReceived: [String] = []
    var cReceived: [String] = []
    var ready = false
    router.register(a, identity: viewA) {
      aReceived.append($0)
      return true
    }
    router.register(b, identity: viewB, ready: { ready }) {
      bReceived.append($0)
      return false
    }
    router.register(c, identity: viewC) {
      cReceived.append($0)
      return true
    }
    XCTAssertThrowsError(try router.prepare([a, b], command: "echo synthetic"))
    XCTAssertTrue(aReceived.isEmpty)
    ready = true
    XCTAssertThrowsError(try router.prepare([], command: "echo synthetic"))
    for command in [
      "echo a\necho b", "\u{1b}[A", "echo a\r", "\0", String(repeating: "a", count: 32769),
    ] { XCTAssertThrowsError(try router.prepare([a], command: command)) }
    let targets = try router.prepare([a, b], command: "echo synthetic")
    // SwiftUI update for the same native view must not invalidate the preview.
    router.register(a, identity: viewA) {
      aReceived.append($0)
      return true
    }
    let result = try router.execute("echo synthetic", recipients: targets)
    XCTAssertEqual(result[a], true)
    XCTAssertEqual(result[b], false)
    XCTAssertEqual(aReceived, ["echo synthetic\r"])
    XCTAssertEqual(bReceived, ["echo synthetic\r"])
    XCTAssertTrue(cReceived.isEmpty)
    let stale = try router.prepare([a], command: "echo synthetic")
    let replacement = NSObject()
    router.register(a, identity: replacement) {
      aReceived.append($0)
      return true
    }
    XCTAssertThrowsError(try router.execute("echo synthetic", recipients: stale))
    XCTAssertEqual(aReceived.count, 1)
    let closed = try router.prepare([b], command: "echo synthetic")
    router.remove(b)
    XCTAssertThrowsError(try router.execute("echo synthetic", recipients: closed))
  }
  @MainActor func testGroupInheritanceIsOptInNearestParentAndProtocolSpecific() throws {
    let fixture = Fixture()
    defer { fixture.clean() }
    var data = fixture.tools.data
    let credential = UUID()
    let appearance = TerminalAppearance(name: "Synthetic Appearance")
    data.profiles = [appearance]
    data.groupDefaults["Org"] = ConnectionDefaults(
      credentialProfileID: credential, ports: [.ssh: 2222, .rdp: 3390],
      jumpHost: "hop.example.invalid", terminalProfileID: appearance.id, keepAlive: 45)
    data.groupDefaults["Org/Devices"] = ConnectionDefaults(
      ports: [.ssh: 2200], jumpHost: "", desktopScale: 140)
    try fixture.tools.save(data)
    var connection = RemoteConnection(
      name: "Synthetic", kind: .ssh, host: "host.example.invalid", port: 22,
      group: "Org/Devices/Child")
    XCTAssertEqual(fixture.tools.resolve(connection), connection)
    connection.inheritedFields = [.port, .jumpHost, .appearance, .credential, .desktopScale]
    let resolved = fixture.tools.resolve(connection)
    XCTAssertEqual(resolved.port, 2200)
    XCTAssertNil(resolved.sshJumpHost)
    XCTAssertEqual(resolved.credentialProfileID, credential)
    XCTAssertEqual(resolved.terminalProfileID, appearance.id)
    XCTAssertNil(resolved.rdpScale)
    connection.inheritedFields?.remove(.port)
    XCTAssertEqual(fixture.tools.resolve(connection).port, 22)
    XCTAssertEqual(fixture.tools.inheritedDefaults(for: "org/devices").ports[.ssh], 2200)
    XCTAssertEqual(fixture.tools.inheritedDefaults(for: "Org2").ports, [:])
  }
  @MainActor func testToolsRoundTripCorruptionAndGroupCollisionFailSafely() throws {
    let fixture = Fixture()
    defer { fixture.clean() }
    var data = fixture.tools.data
    data.profiles = [TerminalAppearance.standard]
    data.templates = [ConnectionTemplate(name: "Synthetic")]
    data.groupDefaults["Org/Devices"] = ConnectionDefaults(keepAlive: 45)
    try fixture.tools.save(data)
    XCTAssertEqual(LibraryTools(defaults: fixture.defaults).data.templates, data.templates)
    try fixture.tools.remapGroups([("Org", "New")])
    XCTAssertNotNil(fixture.tools.data.groupDefaults["New/Devices"])
    var collision = fixture.tools.data
    collision.groupDefaults["Destination/Devices"] = ConnectionDefaults(keepAlive: 60)
    try fixture.tools.save(collision)
    XCTAssertThrowsError(try fixture.tools.remapGroups([("New", "Destination")]))
    try fixture.tools.removeGroup("New")
    XCTAssertNil(fixture.tools.data.groupDefaults["New/Devices"])
    let corrupt = Data("invalid".utf8)
    fixture.defaults.set(corrupt, forKey: "library.tools.v1")
    let damaged = LibraryTools(defaults: fixture.defaults)
    XCTAssertNotNil(damaged.notice)
    XCTAssertThrowsError(try damaged.save(data))
    XCTAssertEqual(fixture.defaults.data(forKey: "library.tools.v1"), corrupt)
  }
  @MainActor func testBulkEditAtomicMetadataOnlyAndLiveSnapshotsUnchanged() throws {
    let fixture = Fixture()
    defer { fixture.clean() }
    let a = RemoteConnection(name: "Synthetic SSH", kind: .ssh, host: "ssh.example.invalid")
    let b = RemoteConnection(name: "Synthetic RDP", kind: .rdp, host: "rdp.example.invalid")
    fixture.store.items = [.localShell, a, b]
    let state = fixture.state()
    state.open(a)
    let patch = BulkConnectionPatch(
      fields: [.port, .keepAlive, .desktopScale],
      defaults: ConnectionDefaults(
        ports: [.ssh: 2222, .rdp: 3390], keepAlive: 60, desktopScale: 140))
    fixture.store.fail = true
    XCTAssertThrowsError(try state.applyBulk(patch, ids: [a.id, b.id]))
    XCTAssertEqual(state.connections, [.localShell, a, b])
    fixture.store.fail = false
    try state.applyBulk(patch, ids: [a.id, b.id])
    XCTAssertEqual(state.connections.first { $0.id == a.id }?.port, 2222)
    XCTAssertNil(state.connections.first { $0.id == b.id }?.sshKeepAliveInterval)
    XCTAssertEqual(state.tabs.first?.connection.port, 22)
    XCTAssertEqual(fixture.vault.calls, 0)
    XCTAssertThrowsError(try state.applyBulk(patch, ids: [UUID()]))
    XCTAssertThrowsError(try state.applyBulk(patch, ids: [RemoteConnection.localShell.id]))
  }
  func testBulkUnsetFieldsDoNotEraseInheritance() throws {
    var connection = RemoteConnection(name: "Synthetic", kind: .ssh, host: "host.example.invalid")
    connection.inheritedFields = [.port, .credential, .keepAlive]
    let patch = BulkConnectionPatch(
      fields: [.port, .credential, .keepAlive], defaults: ConnectionDefaults(keepAlive: 60))
    let result = try patch.apply(connection)
    XCTAssertEqual(result.inheritedFields, [.port, .credential])
    XCTAssertEqual(result.sshKeepAliveInterval, 60)
  }
  @MainActor func testGroupRenameMoveRemoveMaterializesSettingsAndRollsBackFailure() throws {
    let fixture = Fixture()
    defer { fixture.clean() }
    var connection = RemoteConnection(
      name: "Synthetic", kind: .ssh, host: "host.example.invalid", group: "Org/Devices")
    connection.inheritedFields = [.port, .keepAlive]
    fixture.store.items = [.localShell, connection]
    var data = fixture.tools.data
    data.groupDefaults["Org"] = ConnectionDefaults(ports: [.ssh: 2222], keepAlive: 60)
    try fixture.tools.save(data)
    let state = fixture.state()
    _ = state.addGroup("Destination")
    fixture.store.fail = true
    XCTAssertThrowsError(try state.renameGroup("Org", to: "New"))
    XCTAssertNotNil(fixture.tools.data.groupDefaults["Org"])
    fixture.store.fail = false
    _ = try state.renameGroup("Org", to: "New")
    XCTAssertNotNil(fixture.tools.data.groupDefaults["New"])
    try state.moveSidebarItems(withConnectionIDs: [], groupPaths: ["New"], toGroup: "Destination")
    XCTAssertEqual(
      state.resolvedConnection(for: state.connections.first { $0.id == connection.id }!).port, 2222)
    _ = try state.removeGroup("Destination/New")
    let moved = state.connections.first { $0.id == connection.id }!
    XCTAssertEqual(moved.group, "Ungrouped")
    XCTAssertEqual(moved.port, 2222)
    XCTAssertEqual(moved.sshKeepAliveInterval, 60)
    XCTAssertEqual(moved.inheritedFields, [])
    XCTAssertTrue(fixture.tools.data.groupDefaults.isEmpty)
    XCTAssertEqual(fixture.vault.calls, 0)
  }
  @MainActor func testArchiveMaterializesDefaultsAndAppearanceWithoutSecrets() throws {
    let fixture = Fixture()
    defer { fixture.clean() }
    var connection = RemoteConnection(
      name: "Synthetic", kind: .ssh, host: "host.example.invalid", group: "Org")
    connection.inheritedFields = [.port, .appearance]
    fixture.store.items = [.localShell, connection]
    var data = fixture.tools.data
    data.profiles = [TerminalAppearance.standard]
    data.groupDefaults["Org"] = ConnectionDefaults(
      ports: [.ssh: 2222], terminalProfileID: TerminalAppearance.standard.id)
    try fixture.tools.save(data)
    let state = fixture.state()
    let archive = try state.makeConnectionArchive(includeCredentials: false)
    XCTAssertEqual(archive.connections.first?.port, 2222)
    XCTAssertNil(archive.connections.first?.inheritedFields)
    XCTAssertEqual(archive.connections.first?.terminalAppearance, .standard)
    XCTAssertNil(archive.connections.first?.terminalProfileID)
    let inspection = try ConnectionTransferService.inspect(
      ConnectionTransferService.encodePlain(archive))
    guard case .plain(let restored) = inspection.content else {
      return XCTFail("Expected plain archive")
    }
    // Archive v1 deliberately stores dates with whole-second ISO-8601 precision.
    XCTAssertEqual(restored.groups, archive.groups)
    XCTAssertEqual(
      restored.connections.first?.terminalAppearance, archive.connections.first?.terminalAppearance)
    XCTAssertEqual(restored.connections.first?.port, archive.connections.first?.port)
    XCTAssertEqual(restored.connections.first?.id, archive.connections.first?.id)
    XCTAssertFalse(restored.includesCredentials)
    XCTAssertEqual(fixture.vault.calls, 0)
  }
  func testLogFilterHandlesFragmentedLabelsANSIAndOversizedLines() {
    var filter = TerminalLogFilter()
    XCTAssertTrue(filter.consume(Array("pass".utf8)[...]).isEmpty)
    XCTAssertEqual(
      filter.consume(Array("word: unit-test-placeholder\n".utf8)[...]),
      ["[sensitive output omitted]"])
    XCTAssertEqual(
      filter.consume(
        Array("\u{1b}[31mhello\u{1b}[0m\n\u{1b}]0;hidden title\u{7}visible\n".utf8)[...]),
      ["hello", "visible"])
    XCTAssertEqual(
      filter.consume(Array((String(repeating: "a", count: 16385) + "\n").utf8)[...]),
      ["[oversized output omitted]"])
    XCTAssertTrue(filter.consume(Array("no newline".utf8)[...]).isEmpty)
  }
  func testLogWriterTimestampPermissionsAndExclusiveCreation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "NethrivaLogs-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("session-" + UUID().uuidString + ".log")
    let writer = try TerminalLogWriter(url: url)
    XCTAssertThrowsError(try TerminalLogWriter(url: url))
    writer.append(
      Array("hello\npassword: unit-test-placeholder\n".utf8)[...],
      date: Date(timeIntervalSince1970: 0))
    writer.stop()
    await writer.waitForPendingWrites()
    let text = try String(contentsOf: url, encoding: .utf8)
    XCTAssertTrue(text.contains("1970-01-01T00:00:00Z"))
    XCTAssertTrue(text.contains("hello"))
    XCTAssertFalse(text.contains("unit-test-placeholder"))
    XCTAssertEqual(
      (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?
        .intValue, 0o600)
  }
  @MainActor func testLoggingOffByDefaultRestartStopsRecordingAndSearchSurvivesTrim() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "NethrivaCapture-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let experience = TerminalExperience(root: root)
    let id = UUID()
    let view = TerminalView(frame: .zero, options: TerminalOptions(scrollback: 100))
    let generation = experience.register(view, id: id)
    experience.output(Array("not recorded\n".utf8)[...], id: id, generation: generation)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    XCTAssertTrue(experience.recording.isEmpty)
    view.feed(text: (0..<300).map { "line \($0)\r\n" }.joined())
    XCTAssertTrue(experience.snapshot(id).contains("line 299"))
    try await experience.start(id, retentionDays: 7)
    XCTAssertTrue(experience.recording.contains(id))
    let second = TerminalView(frame: .zero)
    let replacement = experience.register(second, id: id)
    XCTAssertFalse(experience.recording.contains(id))
    experience.unregister(id, generation: generation)
    second.feed(text: "replacement\r\n")
    XCTAssertTrue(experience.snapshot(id).contains("replacement"))
    experience.unregister(id, generation: replacement)
    XCTAssertEqual(experience.snapshot(id), "")
  }
  @MainActor func testLogRetentionOnlyDeletesExpiredOwnedNamedRegularLogs() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "NethrivaRetention-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let old = root.appendingPathComponent("session-" + UUID().uuidString + ".log")
    let recent = root.appendingPathComponent("session-" + UUID().uuidString + ".log")
    let unrelated = root.appendingPathComponent("unrelated.txt")
    for url in [old, recent, unrelated] {
      _ = FileManager.default.createFile(atPath: url.path, contents: Data())
    }
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSinceNow: -20 * 86400)], ofItemAtPath: old.path)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSinceNow: -20 * 86400)], ofItemAtPath: unrelated.path)
    let link = root.appendingPathComponent("session-" + UUID().uuidString + ".log")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: unrelated)
    let experience = TerminalExperience(root: root)
    try await experience.prune(retentionDays: 7)
    XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
  }
  func testCSVQuotedFieldsGroupsAndPasswordsIgnored() throws {
    let text =
      "name,protocol,host,port,username,group,password,favorite\r\n\"Synthetic, device\",ssh,host.example.invalid,2222,admin,Org/Devices,unit-test-placeholder,true\r\n"
    let result = try MigrationImport.parse(Data(text.utf8), format: .csv)
    XCTAssertEqual(result.connections.first?.name, "Synthetic, device")
    XCTAssertEqual(result.connections.first?.port, 2222)
    XCTAssertEqual(result.connections.first?.group, "Org/Devices")
    XCTAssertEqual(result.connections.first?.isFavorite, true)
    XCTAssertFalse(
      String(decoding: try JSONEncoder().encode(result.connections), as: UTF8.self).contains(
        "unit-test-placeholder"))
    XCTAssertFalse(result.warnings.isEmpty)
    for bad in [
      "protocol,host,port\nssh,-bad,22", "protocol,host,port\nssh,host.example.invalid,notaport",
      "protocol,host\nssh,\"bad\npath\"", "host,host,protocol\na,b,ssh",
      "protocol,host\nssh,\"unclosed",
    ] {
      XCTAssertThrowsError(try MigrationImport.parse(Data(bad.utf8), format: .csv))
    }
    XCTAssertEqual(try MigrationImport.csvRows("a,b\n\"x\"\"y\",z"), [["a", "b"], ["x\"y", "z"]])
  }
  func testRDPUTF16AllowlistAndSecurityDefaults() throws {
    let text =
      "full address:s:[2001:db8::1]:3390\r\nusername:s:admin\r\ndomain:s:EXAMPLE\r\npassword 51:b:unit-test-placeholder\r\nalternate shell:s:ignored\r\nauthentication level:i:0\r\nredirectclipboard:i:1\r\ndesktopscalefactor:i:140\r\n"
    var raw = Data([0xff, 0xfe])
    raw.append(text.data(using: .utf16LittleEndian)!)
    let result = try MigrationImport.parse(raw, format: .rdp)
    let connection = try XCTUnwrap(result.connections.first)
    XCTAssertEqual(connection.host, "2001:db8::1")
    XCTAssertEqual(connection.port, 3390)
    XCTAssertEqual(connection.rdpDomain, "EXAMPLE")
    XCTAssertEqual(connection.rdpCertificatePolicy, .systemValidation)
    XCTAssertEqual(connection.rdpScale, 140)
    XCTAssertEqual(connection.rdpClipboard, true)
    XCTAssertFalse(
      String(decoding: try JSONEncoder().encode(connection), as: UTF8.self).contains(
        "unit-test-placeholder"))
    XCTAssertThrowsError(
      try MigrationImport.parse(Data("full address:i:host.example.invalid".utf8), format: .rdp))
    XCTAssertThrowsError(try MigrationImport.parse(Data("username:s:admin".utf8), format: .rdp))
  }
  func testSSHConfigExplicitAliasesQuotingAndNoExecutableDirectives() throws {
    let text =
      "User admin\nInclude /never/read\nHost first second\n HostName host.example.invalid\n Port 2222\n IdentityFile \"~/.ssh/example key\"\n ProxyJump hop.example.invalid\n ProxyCommand ignored\nHost *\n Port 2200\nHost third\n HostName other.example.invalid\nMatch exec ignored\n HostName ignored.example.invalid\n"
    let result = try MigrationImport.parse(Data(text.utf8), format: .sshConfig)
    XCTAssertEqual(result.connections.map(\.name), ["first", "second", "third"])
    XCTAssertEqual(result.connections[0].sshIdentityFile, "~/.ssh/example key")
    XCTAssertEqual(result.connections[0].sshJumpHost, "hop.example.invalid")
    XCTAssertEqual(result.connections[2].host, "other.example.invalid")
    XCTAssertEqual(result.connections[2].port, 22)
    XCTAssertEqual(result.connections[0].username, "admin")
    XCTAssertEqual(
      try MigrationImport.sshTokens("HostName=\"host.example.invalid\" # comment"),
      ["HostName", "host.example.invalid"])
    XCTAssertThrowsError(
      try MigrationImport.parse(Data("Host bad\nHostName -bad".utf8), format: .sshConfig))
  }
  func testConnectionXMLHierarchyAndNoEntitiesOrPasswords() throws {
    let text =
      "<Connections><Node Name=\"Org\" Type=\"Container\"><Node Name=\"Empty\" Type=\"Container\"/><Node Name=\"Synthetic\" Type=\"Connection\" Protocol=\"SSH2\" Hostname=\"host.example.invalid\" Username=\"admin\" Port=\"2222\" Password=\"unit-test-placeholder\"/></Node></Connections>"
    let result = try MigrationImport.parse(Data(text.utf8), format: .connectionXML)
    XCTAssertTrue(result.groups.contains("Imported/Org/Empty"))
    XCTAssertEqual(result.connections.first?.group, "Imported/Org")
    XCTAssertEqual(result.connections.first?.port, 2222)
    let namespaced = text.replacingOccurrences(
      of: "<Connections>", with: "<c:Connections xmlns:c='https://example.invalid/schema'>"
    ).replacingOccurrences(of: "</Connections>", with: "</c:Connections>")
    XCTAssertEqual(
      try MigrationImport.parse(Data(namespaced.utf8), format: .connectionXML).connections.count, 1)
    XCTAssertFalse(
      String(decoding: try JSONEncoder().encode(result.connections), as: UTF8.self).contains(
        "unit-test-placeholder"))
    for invalid in [
      "<!DOCTYPE Connections [<!ENTITY x SYSTEM 'file:///never/read'>]><Connections/>", "<Other/>",
      "<Connections FullFileEncryption='true'/>",
      "<Connections><Node Type='Container' Name='bad/path'/></Connections>",
    ] {
      XCTAssertThrowsError(try MigrationImport.parse(Data(invalid.utf8), format: .connectionXML))
    }
  }
  @MainActor func testMigrationIsAtomicAndDoesNotReadCredentialVault() throws {
    let fixture = Fixture()
    defer { fixture.clean() }
    let state = fixture.state()
    let imported = try MigrationImport.parse(
      Data("protocol,host,group\nssh,host.example.invalid,Org/Devices".utf8), format: .csv)
    fixture.store.fail = true
    XCTAssertThrowsError(
      try state.addMigratedConnections(imported.connections, groups: imported.groups))
    XCTAssertEqual(state.connections.count, 1)
    fixture.store.fail = false
    try state.addMigratedConnections(imported.connections, groups: imported.groups)
    XCTAssertEqual(state.connections.count, 2)
    XCTAssertTrue(state.groups.contains("Org/Devices"))
    XCTAssertEqual(fixture.vault.calls, 0)
    XCTAssertThrowsError(
      try state.addMigratedConnections(imported.connections, groups: imported.groups))
    XCTAssertThrowsError(
      try MigrationImport.parse(Data(repeating: 0, count: 4 * 1024 * 1024 + 1), format: .csv))
  }
}

@MainActor private final class Fixture {
  let suite = "LibraryToolsTests." + UUID().uuidString
  let defaults: UserDefaults
  let tools: LibraryTools
  let store = MemoryConnectionStore()
  let vault = NoAccessVault()
  init() {
    defaults = UserDefaults(suiteName: suite)!
    tools = LibraryTools(defaults: defaults)
  }
  func state() -> AppState {
    AppState(
      store: store, groupStore: UserDefaultsConnectionGroupStore(defaults: defaults),
      credentialVault: vault, libraryTools: tools)
  }
  func clean() { defaults.removePersistentDomain(forName: suite) }
}
private final class MemoryConnectionStore: ConnectionPersisting {
  var items: [RemoteConnection] = [.localShell]
  var fail = false
  func load() throws -> ConnectionLoadResult {
    ConnectionLoadResult(connections: items, recoveryNotice: nil)
  }
  func save(_ connections: [RemoteConnection]) throws {
    if fail { throw ConnectionStoreError.writeVerificationFailed }
    items = connections
  }
}
private final class NoAccessVault: CredentialVault {
  var calls = 0
  func save(password: String, for connectionID: UUID) throws {
    calls += 1
    throw KeychainError.invalidData
  }
  func password(for connectionID: UUID) throws -> String? {
    calls += 1
    throw KeychainError.invalidData
  }
  func deletePassword(for connectionID: UUID) throws {
    calls += 1
    throw KeychainError.invalidData
  }
  func containsPassword(for connectionID: UUID) throws -> Bool {
    calls += 1
    throw KeychainError.invalidData
  }
}
