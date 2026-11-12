import XCTest
import SwiftUI

@testable import Nethriva

final class SharingPrivacyTests: XCTestCase {
  @MainActor func testAuxiliaryHostingWindowShieldUsesPlainSiblingContainer() throws {
    let suite = "PrivacyHostingTests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let authentication = FakeDeviceAuthentication()
    let privacy = PrivacyLock(defaults: defaults, gate: CredentialAccessGate(), authentication: authentication)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let hosted = NSHostingView(rootView: Text("Synthetic private content"))
    window.contentView = hosted
    privacy.lock()
    let container = try XCTUnwrap(window.contentView)
    XCTAssertTrue(container.isMember(of: NSView.self))
    XCTAssertTrue(hosted.superview === container)
    XCTAssertTrue(hosted.isHidden)
    XCTAssertEqual(container.subviews.count, 2)
    privacy.shieldWindows()
    XCTAssertTrue(window.contentView === container, "Repeated covering must not nest containers or rebuild the hosting view")
    privacy.unlock(); authentication.completions[0](true)
    XCTAssertFalse(hosted.isHidden)
    XCTAssertTrue(hosted.superview === container)
  }
  @MainActor func testRepeatedLockCannotUnlockBeforeEveryShutdownCompletes() async throws {
    let fixture = SharingFixture()
    defer { fixture.clean() }
    let auth = FakeDeviceAuthentication()
    let privacy = PrivacyLock(
      defaults: fixture.defaults, gate: fixture.gate, authentication: auth, protectWindows: false)
    var stops: [CheckedContinuation<Void, Never>] = []
    privacy.onCleanup = { await withCheckedContinuation { stops.append($0) } }
    privacy.lock()
    while stops.count < 1 { await Task.yield() }
    privacy.lock()
    while stops.count < 2 { await Task.yield() }
    privacy.unlock()
    XCTAssertTrue(auth.completions.isEmpty)
    stops[0].resume()
    try await Task.sleep(for: .milliseconds(10))
    privacy.unlock()
    XCTAssertTrue(auth.completions.isEmpty)
    XCTAssertTrue(privacy.shutdownPending)
    stops[1].resume()
    for _ in 0..<100 where privacy.shutdownPending { try await Task.sleep(for: .milliseconds(1)) }
    XCTAssertFalse(privacy.shutdownPending)
    privacy.unlock()
    XCTAssertEqual(auth.completions.count, 1)
    auth.completions[0](true)
    XCTAssertFalse(privacy.isLocked)
  }
  func testPrivacyShutdownLeavesControlDirectoryUsableForFutureSSH() throws {
    let path = try SSHConnectionReuse.controlDirectory().path
    XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    SSHConnectionReuse.shutdownAll(connections: [], removeDirectory: false)
    XCTAssertTrue(FileManager.default.fileExists(atPath: path))
  }
  private func client() -> RemoteConnection {
    RemoteConnection(
      name: "Synthetic", kind: .ssh, host: "server.example.invalid", username: "unit-test-user",
      credentialProfileID: UUID(), group: "Team/Servers",
      sshIdentityFile: "/private/tmp/unit-test-key",
      sshJumpHost: "unit-test-user@jump.example.invalid")
  }
  func testSharedAllowlistNeverEncodesCredentialsOrPrivateSettings() throws {
    let shared = SharedConnection(client())
    let doc = SharedLibraryDocument(
      name: "Synthetic team", groups: ["Team", "Team/Servers", "Empty"], connections: [shared])
    let raw = try doc.encode()
    let text = String(decoding: raw, as: UTF8.self)
    XCTAssertFalse(text.contains("unit-test-user"))
    XCTAssertFalse(text.contains("credentialProfile"))
    XCTAssertFalse(text.contains("unit-test-key"))
    XCTAssertFalse(text.contains("jump.example.invalid"))
    XCTAssertEqual(try SharedLibraryDocument.decode(raw), doc)
    let imported = shared.personalConnection()
    XCTAssertEqual(imported.username, "")
    XCTAssertNil(imported.credentialProfileID)
    XCTAssertNil(imported.inheritedFields)
    XCTAssertEqual(imported.rdpClipboard, false)
    XCTAssertEqual(imported.rdpCertificatePolicy, .systemValidation)
  }
  func testSharedRejectsUnknownCredentialField() throws {
    let doc = SharedLibraryDocument(
      name: "Synthetic", groups: [], connections: [SharedConnection(client())])
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: doc.encode()) as? [String: Any])
    var rows = try XCTUnwrap(json["connections"] as? [[String: Any]])
    rows[0]["password"] = "unit-test-placeholder"
    json["connections"] = rows
    XCTAssertThrowsError(
      try SharedLibraryDocument.decode(JSONSerialization.data(withJSONObject: json)))
    json["connections"] = []
    json["profiles"] = []
    XCTAssertThrowsError(
      try SharedLibraryDocument.decode(JSONSerialization.data(withJSONObject: json)))
  }
  func testThreeWayMergePreservesPersonalOverridesAndDetectsConflict() throws {
    let original = client()
    let shared = SharedConnection(original)
    let baseline = SharedLibraryDocument(name: "Synthetic", groups: [], connections: [shared])
    let link = SharedLibraryLink(
      path: "/private/tmp/synthetic.nethriva-shared", baseline: baseline,
      mapping: [shared.id: original.id], fingerprint: Data())
    var personal = original
    personal.name = "Personal name"
    var incoming = baseline
    incoming.connections[0].name = "Team name"
    incoming.connections[0].group = "Team/New"
    let review = SharedLibraryReview(
      document: incoming, path: link.path, fingerprint: Data(), link: link, originals: [personal])
    XCTAssertEqual(review.conflicts.count, 1)
    let keep = try review.merged(takeShared: []).connections[0]
    XCTAssertEqual(keep.name, "Personal name")
    XCTAssertEqual(keep.group, "Team/New")
    XCTAssertEqual(keep.credentialProfileID, original.credentialProfileID)
    let accept = try review.merged(takeShared: Set(review.conflicts.map(\.id))).connections[0]
    XCTAssertEqual(accept.name, "Team name")
    XCTAssertEqual(accept.username, original.username)
    XCTAssertEqual(accept.sshIdentityFile, original.sshIdentityFile)
  }
  func testChangedSharedDestinationNeverRetargetsPersonalCredential() throws {
    let original = client()
    let baseline = SharedLibraryDocument(
      name: "Synthetic", groups: [], connections: [SharedConnection(original)])
    let link = SharedLibraryLink(
      path: "/private/tmp/synthetic", baseline: baseline, mapping: [original.id: original.id],
      fingerprint: Data())
    var incoming = baseline
    incoming.connections[0].host = "new.example.invalid"
    let review = SharedLibraryReview(
      document: incoming, path: link.path, fingerprint: Data(), link: link, originals: [original])
    XCTAssertEqual(review.conflicts.map(\.field), [.host])
    let keep = try review.merged(takeShared: [])
    XCTAssertEqual(keep.connections, [original])
    let accept = try review.merged(takeShared: Set(review.conflicts.map(\.id)))
    XCTAssertEqual(accept.connections.count, 2)
    XCTAssertEqual(accept.connections[0], original)
    XCTAssertEqual(accept.connections[1].host, "new.example.invalid")
    XCTAssertEqual(accept.connections[1].username, "")
    XCTAssertNil(accept.connections[1].credentialProfileID)
    XCTAssertNotEqual(accept.connections[1].id, original.id)
  }
  func testSharedRemovalKeepsPersonalClientAndPersonalDeletionIsNotResurrected() throws {
    let original = client()
    let baseline = SharedLibraryDocument(
      name: "Synthetic", groups: [], connections: [SharedConnection(original)])
    let link = SharedLibraryLink(
      path: "/private/tmp/synthetic", baseline: baseline, mapping: [original.id: original.id],
      fingerprint: Data())
    var incoming = baseline
    incoming.connections = []
    let removal = SharedLibraryReview(
      document: incoming, path: link.path, fingerprint: Data(), link: link, originals: [original])
    let result = try removal.merged(takeShared: [])
    XCTAssertEqual(result.connections, [original])
    XCTAssertTrue(result.link.mapping.isEmpty)
    let tombstone = SharedLibraryReview(
      document: baseline, path: link.path, fingerprint: Data(), link: link, originals: [])
    XCTAssertTrue(try tombstone.merged(takeShared: []).connections.isEmpty)
  }
  func testCredentialGateRejectsLockedAndOldEpochEvenAfterUnlock() throws {
    let gate = CredentialAccessGate()
    let epoch = try gate.check()
    gate.setLocked(true)
    XCTAssertThrowsError(try gate.check())
    XCTAssertThrowsError(try gate.check(epoch))
    gate.setLocked(false)
    XCTAssertNoThrow(try gate.check())
    XCTAssertThrowsError(try gate.check(epoch))
  }
  func testProviderReferencesValidateStrictly() throws {
    XCTAssertNoThrow(try ExternalCredentialValue.validate("unit-test-placeholder"))
    for invalid in [
      "", "value\ncommand", "value\rcommand", "value\0", "value\t",
      String(repeating: "a", count: 65537),
    ] {
      XCTAssertThrowsError(try ExternalCredentialValue.validate(invalid))
    }
    var op = ExternalCredentialReference()
    op.reference = "op://Synthetic/Item/password"
    XCTAssertNoThrow(try op.validate())
    op.executable = "/private/tmp/arbitrary-script"
    XCTAssertThrowsError(try op.validate())
    op.executable = "/opt/homebrew/bin/op"
    op.reference += "?attribute=otp"
    XCTAssertThrowsError(try op.validate())
    var vault = ExternalCredentialReference(
      kind: .vaultKV2, reference: "secret/network/admin", field: "password",
      server: "https://vault.example.invalid")
    XCTAssertEqual(try vault.vaultURL().path, "/v1/secret/data/network/admin")
    vault.server = "http://vault.example.invalid"
    XCTAssertThrowsError(try vault.validate())
    vault.server = "https://unit-test-user@vault.example.invalid"
    XCTAssertThrowsError(try vault.validate())
    vault.server = "https://vault.example.invalid"
    vault.reference = "secret/../admin"
    XCTAssertThrowsError(try vault.validate())
  }

  @MainActor func testGatedVaultCannotReadWriteDeleteOrInspectWhileLocked() throws {
    let base = SharingTestVault()
    let gate = CredentialAccessGate()
    let vault = GatedCredentialVault(base: base, gate: gate)
    gate.setLocked(true)
    let id = UUID()
    XCTAssertThrowsError(try vault.password(for: id))
    XCTAssertThrowsError(try vault.save(password: "unit-test-placeholder", for: id))
    XCTAssertThrowsError(try vault.deletePassword(for: id))
    XCTAssertThrowsError(try vault.containsPassword(for: id))
    XCTAssertEqual(base.calls, 0)
    gate.setLocked(false)
    XCTAssertEqual(try vault.password(for: id), "unit-test-placeholder")
    XCTAssertEqual(base.calls, 1)
  }
  @MainActor func testPrivacyAuthenticationCancellationAndStaleSuccessStayLocked() throws {
    let suite = "PrivacyAuthenticationTests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let gate = CredentialAccessGate()
    let authentication = FakeDeviceAuthentication()
    let privacy = PrivacyLock(
      defaults: defaults, gate: gate, authentication: authentication, protectWindows: false)
    var closed = 0
    privacy.onLock = { closed += 1 }
    privacy.lock()
    privacy.unlock()
    XCTAssertTrue(privacy.authenticating)
    privacy.lock()
    authentication.completions[0](true)
    XCTAssertTrue(privacy.isLocked)
    XCTAssertTrue(gate.isLocked)
    privacy.unlock()
    authentication.completions[1](false)
    XCTAssertTrue(privacy.isLocked)
    XCTAssertNotNil(privacy.message)
    privacy.unlock()
    authentication.completions[2](true)
    XCTAssertFalse(privacy.isLocked)
    XCTAssertFalse(gate.isLocked)
    XCTAssertEqual(closed, 2)
  }
  @MainActor func testNativePrivacyShieldCoversExistingAndNewSiblingWindowsAndRestoresViews() throws
  {
    let suite = "PrivacyWindowTests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let gate = CredentialAccessGate()
    let auth = FakeDeviceAuthentication()
    let privacy = PrivacyLock(defaults: defaults, gate: gate, authentication: auth)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "Synthetic private title"
    let first = NSTextField(labelWithString: "Synthetic private content")
    let second = NSView()
    window.contentView?.addSubview(first)
    window.contentView?.addSubview(second)
    second.isHidden = true
    privacy.lock()
    XCTAssertTrue(first.isHidden)
    XCTAssertTrue(second.isHidden)
    XCTAssertEqual(window.title, "Nethriva — Locked")
    let newWindow = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled],
      backing: .buffered, defer: false)
    newWindow.isReleasedWhenClosed = false
    let third = NSTextField(labelWithString: "Synthetic detached content")
    newWindow.contentView?.addSubview(third)
    privacy.shieldWindows()
    XCTAssertTrue(third.isHidden)
    privacy.unlock()
    auth.completions[0](true)
    XCTAssertFalse(first.isHidden)
    XCTAssertTrue(second.isHidden)
    XCTAssertFalse(third.isHidden)
    XCTAssertEqual(window.title, "Synthetic private title")
    window.close()
    newWindow.close()
  }
  @MainActor func testSharedLinkRoundTripCorruptionAndNewIdentityRejection() async throws {
    let fixture = SharingFixture()
    defer { fixture.clean() }
    let url = fixture.root.appendingPathComponent("test.nethriva-shared")
    let original = client()
    let doc = SharedLibraryDocument(
      name: "Synthetic", groups: ["Team/Servers", "Empty"],
      connections: [SharedConnection(original)])
    try SharedLibraryFile.create(doc, at: url)
    let review = try await fixture.libraries.review(url, originals: [.localShell])
    let merged = try review.merged(takeShared: [])
    try fixture.libraries.save(merged.link)
    XCTAssertEqual(SharedLibraries(defaults: fixture.defaults).links, [merged.link])
    var other = doc
    other.id = UUID()
    try other.encode().write(to: url)
    do {
      _ = try await fixture.libraries.review(url, originals: [])
      XCTFail("Changed identity must be rejected")
    } catch is SharedLibraryError {}
    fixture.defaults.set(Data("damaged".utf8), forKey: "shared.libraries.v1")
    let damaged = SharedLibraries(defaults: fixture.defaults)
    XCTAssertNotNil(damaged.notice)
    XCTAssertThrowsError(try damaged.unlink(UUID()))
    XCTAssertEqual(fixture.defaults.data(forKey: "shared.libraries.v1"), Data("damaged".utf8))
  }
  @MainActor func testSharedMergeStaleFileAndStoreFailureDoNotTouchPersonalClientsOrVault()
    async throws
  {
    let fixture = SharingFixture()
    defer { fixture.clean() }
    let url = fixture.root.appendingPathComponent("test.nethriva-shared")
    let doc = SharedLibraryDocument(
      name: "Synthetic", groups: ["Team/Servers", "Empty"],
      connections: [SharedConnection(client())])
    try SharedLibraryFile.create(doc, at: url)
    let state = fixture.state()
    let review = try await fixture.libraries.review(url, originals: state.connections)
    fixture.store.fail = true
    do {
      try await state.applySharedReview(review, takeShared: [])
      XCTFail("Write must fail")
    } catch {}
    XCTAssertEqual(state.connections, [.localShell])
    XCTAssertTrue(fixture.libraries.links.isEmpty)
    XCTAssertEqual(fixture.vault.calls, 0)
    fixture.store.fail = false
    try await state.applySharedReview(review, takeShared: [])
    XCTAssertEqual(state.connections.count, 2)
    XCTAssertTrue(state.groups.contains("Empty"))
    XCTAssertEqual(fixture.vault.calls, 0)
    let nextReview = try await fixture.libraries.review(url, originals: state.connections)
    var newer = doc
    newer.connections[0].name = "Another update"
    try newer.encode().write(to: url)
    do {
      try await state.applySharedReview(nextReview, takeShared: [])
      XCTFail("Stale preview must be rejected")
    } catch is SharedLibraryError {}
    XCTAssertEqual(state.connections[1].name, "Synthetic")
    XCTAssertEqual(fixture.vault.calls, 0)
  }
  @MainActor func testSharedRevisionPreservesIdentityAndExcludesUnrelatedGroups() async throws {
    let fixture = SharingFixture()
    defer { fixture.clean() }
    var original = client()
    original.credentialProfileID = nil
    fixture.store.items = [.localShell, original]
    let state = fixture.state()
    state.addGroup("UnrelatedEmpty")
    let copy = try state.makeSharedLibrary(name: "Synthetic", ids: [original.id])
    XCTAssertFalse(copy.groups.contains("UnrelatedEmpty"))
    XCTAssertTrue(
      try state.makeSharedLibrary(name: "Synthetic", ids: [original.id], includeEmptyGroups: true)
        .groups.contains("UnrelatedEmpty"))
    let url = fixture.root.appendingPathComponent("test.nethriva-shared")
    try SharedLibraryFile.create(copy, at: url)
    let review = try await fixture.libraries.review(url, originals: state.connections)
    try await state.applySharedReview(review, takeShared: [])
    let link = try XCTUnwrap(fixture.libraries.links.first)
    let revision = try state.makeSharedRevision(link)
    XCTAssertEqual(revision.id, copy.id)
    XCTAssertEqual(revision.connections.map(\.id), copy.connections.map(\.id))
    XCTAssertThrowsError(try SharedLibraryFile.create(revision, at: url))
    let mode =
      try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
    XCTAssertEqual(mode?.intValue, 0o600)
  }
  @MainActor func testProviderReadUsesNoKeychainAndExportsNoProviderSecrets() async throws {
    let fixture = SharingFixture()
    defer { fixture.clean() }
    let profile = CredentialProfile(name: "Synthetic account", username: "unit-test-user")
    let state = fixture.state()
    try state.saveProfile(profile, password: nil)
    var reference = ExternalCredentialReference()
    reference.reference = "op://Synthetic/Item/password"
    try fixture.providers.configure(reference, for: profile.id)
    var connection = client()
    connection.credentialProfileID = profile.id
    try state.add(connection, password: nil)
    let password = try await state.sessionPassword(for: state.resolvedConnection(for: connection))
    XCTAssertEqual(password, "unit-test-placeholder")
    XCTAssertEqual(fixture.vault.calls, 0)
    let archive = try state.makeConnectionArchive(includeCredentials: true)
    XCTAssertTrue(archive.profileCredentials.isEmpty)
    XCTAssertFalse(
      String(decoding: try JSONEncoder().encode(archive), as: UTF8.self).contains("op://"))
    let raw = try XCTUnwrap(fixture.defaults.data(forKey: "external.credentials.v1"))
    XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("unit-test-placeholder"))
  }
  @MainActor func testPendingProviderCannotReturnAfterLockUnlockOrAuthorizationClear() async throws
  {
    let fixture = SharingFixture()
    defer { fixture.clean() }
    var reference = ExternalCredentialReference()
    reference.reference = "op://Synthetic/Item/password"
    let id = UUID()
    try fixture.providers.configure(reference, for: id)
    await fixture.reader.setPaused()
    let read = Task { try await fixture.providers.password(for: id) }
    await fixture.reader.waitForRead()
    fixture.gate.setLocked(true)
    fixture.providers.clearAuthorization()
    fixture.gate.setLocked(false)
    await fixture.reader.finish()
    do {
      _ = try await read.value
      XCTFail("An old request must not cross lock/unlock")
    } catch {}
    let second = Task { try await fixture.providers.password(for: id) }
    await fixture.reader.waitForRead()
    fixture.providers.clearAuthorization()
    await fixture.reader.finish()
    do {
      _ = try await second.value
      XCTFail("Forgotten authorization must cancel a pending result")
    } catch {}
  }
  @MainActor func testLockPersistsAcrossRestartAndOpeningSessionsIsBlocked() throws {
    let fixture = SharingFixture()
    defer { fixture.clean() }
    let auth = FakeDeviceAuthentication()
    let privacy = PrivacyLock(
      defaults: fixture.defaults, gate: fixture.gate, authentication: auth, protectWindows: false)
    let state = fixture.state()
    state.open(.localShell)
    XCTAssertEqual(state.tabs.count, 1)
    privacy.onLock = { state.lockSessions() }
    privacy.lock()
    XCTAssertTrue(state.tabs.isEmpty)
    state.open(.localShell)
    XCTAssertTrue(state.tabs.isEmpty)
    let restored = PrivacyLock(
      defaults: fixture.defaults, gate: fixture.gate, authentication: auth, protectWindows: false)
    XCTAssertTrue(restored.isLocked)
    XCTAssertThrowsError(try state.makeConnectionArchive(includeCredentials: false))
    XCTAssertEqual(fixture.vault.calls, 0)
    restored.unlock()
    auth.completions[0](true)
    XCTAssertFalse(fixture.defaults.bool(forKey: "privacy.isLocked"))
    state.open(.localShell)
    XCTAssertEqual(state.tabs.count, 1)
  }
  @MainActor func testSharedGroupChangeFreezesOldInheritedCredentials() async throws {
    let fixture = SharingFixture()
    defer { fixture.clean() }
    var original = client()
    original.credentialProfileID = nil
    original.inheritedFields = [.credential, .port]
    fixture.store.items = [.localShell, original]
    let state = fixture.state()
    let profile = CredentialProfile(name: "Synthetic old group", username: "unit-test-user")
    try state.saveProfile(profile, password: nil)
    var tools = state.libraryTools.data
    tools.groupDefaults[original.group] = ConnectionDefaults(
      credentialProfileID: profile.id, ports: [.ssh: 2222])
    tools.groupDefaults["New"] = ConnectionDefaults(
      credentialProfileID: UUID(), ports: [.ssh: 9999])
    try state.libraryTools.save(tools)
    let baseline = SharedLibraryDocument(
      name: "Synthetic", groups: [], connections: [SharedConnection(original)])
    let url = fixture.root.appendingPathComponent("test.nethriva-shared")
    try SharedLibraryFile.create(baseline, at: url)
    let (_, fingerprint) = try SharedLibraryFile.read(url)
    try fixture.libraries.save(
      .init(
        path: url.path, baseline: baseline, mapping: [original.id: original.id],
        fingerprint: fingerprint))
    var incoming = baseline
    incoming.connections[0].group = "New"
    try incoming.encode().write(to: url)
    let review = try await fixture.libraries.review(url, originals: state.connections)
    try await state.applySharedReview(review, takeShared: [])
    let changed = try XCTUnwrap(state.connections.first { $0.id == original.id })
    XCTAssertNil(changed.inheritedFields)
    XCTAssertEqual(changed.credentialProfileID, profile.id)
    XCTAssertEqual(changed.port, 2222)
    XCTAssertEqual(changed.group, "New")
    XCTAssertEqual(fixture.vault.calls, 0)
  }
  func testVaultKV2ReadsOnlyRequestedFieldAndRejectsRedirectsAndOversizedResponses() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SyntheticVaultProtocol.self]
    let reference = ExternalCredentialReference(
      kind: .vaultKV2, reference: "secret/synthetic", server: "https://vault.example.invalid",
      namespace: "synthetic")
    let value = try await VaultFieldRequest.read(
      reference, token: "unit-test-token", configuration: configuration)
    XCTAssertEqual(value, "unit-test-placeholder")
    var oversized = reference
    oversized.reference = "secret/oversized"
    do {
      _ = try await VaultFieldRequest.read(
        oversized, token: "unit-test-token", configuration: configuration)
      XCTFail("Oversized response must fail")
    } catch {}
    var forbidden = reference
    forbidden.reference = "secret/forbidden"
    do {
      _ = try await VaultFieldRequest.read(
        forbidden, token: "unit-test-token", configuration: configuration)
      XCTFail("Permission error must fail")
    } catch { XCTAssertFalse(error.localizedDescription.contains("unit-test")) }
    let delegate = VaultFieldRequest()
    let session = URLSession(configuration: .ephemeral)
    let task = session.dataTask(with: URL(string: "https://vault.example.invalid")!)
    let response = HTTPURLResponse(
      url: task.originalRequest!.url!, statusCode: 302, httpVersion: nil,
      headerFields: ["Location": "https://other.example.invalid"])!
    var rejected = false
    delegate.urlSession(
      session, task: task, willPerformHTTPRedirection: response,
      newRequest: URLRequest(url: URL(string: "https://other.example.invalid")!)
    ) { rejected = $0 == nil }
    XCTAssertTrue(rejected)
    session.invalidateAndCancel()
  }
}

private final class SyntheticVaultProtocol: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    guard request.url?.host == "vault.example.invalid",
      request.value(forHTTPHeaderField: "X-Vault-Token") == "unit-test-token",
      request.value(forHTTPHeaderField: "X-Vault-Namespace") == "synthetic"
    else {
      client?.urlProtocol(self, didFailWithError: ExternalCredentialError.failed)
      return
    }
    let oversized = request.url?.path.hasSuffix("oversized") == true
    let forbidden = request.url?.path.hasSuffix("forbidden") == true
    let response = HTTPURLResponse(
      url: request.url!, statusCode: forbidden ? 403 : 200, httpVersion: nil,
      headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(
      self,
      didLoad: oversized
        ? Data(repeating: 65, count: 262145)
        : Data(
          "{\"data\":{\"data\":{\"password\":\"unit-test-placeholder\",\"unrequested\":\"not-returned\"}}}"
            .utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

@MainActor private final class FakeDeviceAuthentication: DeviceAuthenticating {
  var completions: [(Bool) -> Void] = []
  func authenticate(_ completion: @escaping (Bool) -> Void) { completions.append(completion) }
  func cancel() {}
}
private final class SharingTestVault: CredentialVault {
  var calls = 0
  func password(for connectionID: UUID) throws -> String? {
    calls += 1
    return "unit-test-placeholder"
  }
  func containsPassword(for connectionID: UUID) throws -> Bool {
    calls += 1
    return true
  }
  func save(password: String, for connectionID: UUID) throws { calls += 1 }
  func deletePassword(for connectionID: UUID) throws { calls += 1 }
}
private final class SharingTestStore: ConnectionPersisting {
  var items: [RemoteConnection] = [.localShell]
  var fail = false
  func load() throws -> ConnectionLoadResult { .init(connections: items, recoveryNotice: nil) }
  func save(_ connections: [RemoteConnection]) throws {
    if fail { throw ConnectionStoreError.writeVerificationFailed }
    items = connections
  }
}
private actor SharingTestProvider: ExternalCredentialReading {
  var paused = false
  var continuation: CheckedContinuation<String, Error>?
  func setPaused() { paused = true }
  func read(_ reference: ExternalCredentialReference, token: String?) async throws -> String {
    if paused { return try await withCheckedThrowingContinuation { continuation = $0 } }
    return "unit-test-placeholder"
  }
  func waitForRead() async {
    while continuation == nil { try? await Task.sleep(for: .milliseconds(1)) }
  }
  func finish() {
    let current = continuation
    continuation = nil
    current?.resume(returning: "unit-test-placeholder")
  }
}
@MainActor private final class SharingFixture {
  let suite = "SharingPrivacyTests." + UUID().uuidString
  let defaults: UserDefaults
  let root: URL
  let gate = CredentialAccessGate()
  let store = SharingTestStore()
  let vault = SharingTestVault()
  let reader = SharingTestProvider()
  let libraries: SharedLibraries
  let providers: ExternalCredentials
  init() {
    defaults = UserDefaults(suiteName: suite)!
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "NethrivaSharingTests-" + UUID().uuidString)
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    libraries = SharedLibraries(defaults: defaults)
    providers = ExternalCredentials(defaults: defaults, reader: reader, gate: gate)
  }
  func state() -> AppState {
    AppState(
      store: store, groupStore: UserDefaultsConnectionGroupStore(defaults: defaults),
      credentialVault: vault, libraryTools: LibraryTools(defaults: defaults),
      sharedLibraries: libraries, externalCredentials: providers, credentialGate: gate)
  }
  func clean() {
    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: root)
  }
}
