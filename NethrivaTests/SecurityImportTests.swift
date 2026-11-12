import Darwin
import Foundation
import XCTest
@testable import Nethriva

final class SecurityImportTests: XCTestCase {
    @MainActor func testChangedDestinationKeepsOriginalSecretAndCreatesCredentialFreeCopy() throws {
        let fixture = ImportSecurityFixture(); defer { fixture.clean() }
        let original = fixture.connection()
        try fixture.state.add(original, password: "synthetic-original")
        var changed = original; changed.host = "changed.example.invalid"
        let summary = try fixture.state.importConnectionArchive(.init(groups: [], connections: [changed]), conflictPolicy: .replaceExisting)
        XCTAssertEqual(summary.isolatedConnections, 1)
        XCTAssertEqual(fixture.state.connections.first { $0.id == original.id }, original)
        let imported = try XCTUnwrap(fixture.state.connections.first { $0.host == changed.host })
        XCTAssertNotEqual(imported.id, original.id)
        XCTAssertNil(try fixture.state.password(for: imported))
        XCTAssertEqual(try fixture.state.password(for: original), "synthetic-original")
    }

    @MainActor func testBenignRenameKeepsIdentityAndSecret() throws {
        let fixture = ImportSecurityFixture(); defer { fixture.clean() }
        let original = fixture.connection(); try fixture.state.add(original, password: "synthetic-original")
        var renamed = original; renamed.name = "Renamed synthetic target"; renamed.group = "Reviewed"
        let summary = try fixture.state.importConnectionArchive(.init(groups: [], connections: [renamed]), conflictPolicy: .replaceExisting)
        XCTAssertEqual(summary.replaced, 1)
        XCTAssertEqual(summary.isolatedConnections, 0)
        XCTAssertEqual(fixture.state.connections.first { $0.id == original.id }?.name, renamed.name)
        XCTAssertEqual(try fixture.state.password(for: original), "synthetic-original")
    }

    @MainActor func testChangedAccountAndGatewayDoNotInheritSecret() throws {
        for gateway in [false, true] {
            let fixture = ImportSecurityFixture(); defer { fixture.clean() }
            let original = fixture.connection(); try fixture.state.add(original, password: "synthetic-original")
            var changed = original
            if gateway { changed.rdpGatewayHost = "gateway.example.invalid" }
            else { changed.username = "different-synthetic-account" }
            let summary = try fixture.state.importConnectionArchive(.init(groups: [], connections: [changed]), conflictPolicy: .replaceExisting)
            XCTAssertEqual(summary.isolatedConnections, 1)
            let imported = try XCTUnwrap(fixture.state.connections.first { $0.id != original.id && $0.kind != .localShell })
            XCTAssertNil(try fixture.state.password(for: imported))
        }
    }

    @MainActor func testConnectionCannotAliasExistingProfileCredentialUnderKeepExisting() throws {
        let fixture = ImportSecurityFixture(); defer { fixture.clean() }
        let profile = CredentialProfile(name: "Synthetic profile", username: "synthetic")
        try fixture.state.saveProfile(profile, password: "synthetic-profile-secret")
        var malicious = fixture.connection(); malicious.id = profile.id
        let before = fixture.state.connections
        XCTAssertThrowsError(try fixture.state.importConnectionArchive(.init(groups: [], connections: [malicious]), conflictPolicy: .keepExisting))
        XCTAssertEqual(fixture.state.connections, before)
        XCTAssertEqual(fixture.vault.values[profile.id], "synthetic-profile-secret")
    }

    @MainActor func testProfileCannotAliasExistingConnectionCredential() throws {
        let fixture = ImportSecurityFixture(); defer { fixture.clean() }
        let original = fixture.connection(); try fixture.state.add(original, password: "synthetic-original")
        let malicious = CredentialProfile(id: original.id, name: "Synthetic imported profile", username: "synthetic")
        var target = fixture.connection(); target.credentialProfileID = malicious.id
        XCTAssertThrowsError(try fixture.state.importConnectionArchive(.init(groups: [], connections: [target], profiles: [malicious]), conflictPolicy: .keepExisting))
        XCTAssertTrue(fixture.state.credentialProfiles.isEmpty)
        XCTAssertEqual(fixture.vault.values[original.id], "synthetic-original")
    }

    @MainActor func testNewTargetCannotBorrowExistingProfileWithoutLocalApproval() throws {
        let fixture = ImportSecurityFixture(); defer { fixture.clean() }
        let profile = CredentialProfile(name: "Synthetic profile", username: "synthetic")
        try fixture.state.saveProfile(profile, password: "synthetic-profile-secret")
        var target = fixture.connection(); target.credentialProfileID = profile.id
        let summary = try fixture.state.importConnectionArchive(.init(groups: [], connections: [target], profiles: [profile]), conflictPolicy: .keepExisting)
        let imported = try XCTUnwrap(fixture.state.connections.first { $0.id == target.id })
        XCTAssertNil(imported.credentialProfileID)
        XCTAssertNil(try fixture.state.password(for: imported))
        XCTAssertEqual(summary.detachedProfiles, 1)
        XCTAssertEqual(fixture.vault.values[profile.id], "synthetic-profile-secret")
    }

    @MainActor func testReviewedProfileReuseIsScopedToTheApprovedTarget() throws {
        let fixture = ImportSecurityFixture(); defer { fixture.clean() }
        let profile = CredentialProfile(name: "Synthetic profile", username: "synthetic")
        try fixture.state.saveProfile(profile, password: "synthetic-profile-secret")
        var first = fixture.connection(); first.credentialProfileID = profile.id
        var second = fixture.connection(); second.credentialProfileID = profile.id
        _ = try fixture.state.importConnectionArchive(.init(groups: [], connections: [first, second], profiles: [profile]), conflictPolicy: .keepExisting,
            options: ConnectionImportOptions(approvedCredentialReuse: [first.id]))
        let approved = try XCTUnwrap(fixture.state.connections.first { $0.id == first.id })
        let restricted = try XCTUnwrap(fixture.state.connections.first { $0.id == second.id })
        XCTAssertEqual(try fixture.state.password(for: approved), "synthetic-profile-secret")
        XCTAssertNil(restricted.credentialProfileID)
        XCTAssertNil(try fixture.state.password(for: restricted))
    }

    @MainActor func testOrphanedConnectionCredentialCannotBeClaimedByArchiveUUID() throws {
        let fixture = ImportSecurityFixture(); defer { fixture.clean() }
        let target = fixture.connection(); fixture.vault.values[target.id] = "synthetic-orphan"
        _ = try fixture.state.importConnectionArchive(.init(groups: [], connections: [target]), conflictPolicy: .keepExisting)
        let imported = try XCTUnwrap(fixture.state.connections.first { $0.kind != .localShell })
        XCTAssertNotEqual(imported.id, target.id)
        XCTAssertNil(try fixture.state.password(for: imported))
        XCTAssertEqual(fixture.vault.values[target.id], "synthetic-orphan")
    }

    @MainActor func testOrphanedProfileIdentityAndExplicitImportedSecretAreRemappedTogether() throws {
        let fixture = ImportSecurityFixture(); defer { fixture.clean() }
        let profile = CredentialProfile(name: "Synthetic orphan profile", username: "synthetic")
        fixture.vault.values[profile.id] = "synthetic-orphan"
        var target = fixture.connection(); target.credentialProfileID = profile.id
        _ = try fixture.state.importConnectionArchive(.init(groups: [], connections: [target], profiles: [profile],
            profileCredentials: [.init(profileID: profile.id, password: "synthetic-imported")]), conflictPolicy: .keepExisting)
        let imported = try XCTUnwrap(fixture.state.connections.first { $0.id == target.id })
        XCTAssertNotEqual(imported.credentialProfileID, profile.id)
        XCTAssertEqual(try fixture.state.password(for: imported), "synthetic-imported")
        XCTAssertEqual(fixture.vault.values[profile.id], "synthetic-orphan")
    }

    @MainActor func testProfileAccountChangePreservesExistingUsersAndSecret() throws {
        let fixture = ImportSecurityFixture(); defer { fixture.clean() }
        let profile = CredentialProfile(name: "Synthetic profile", username: "original-synthetic", domain: "OLD")
        try fixture.state.saveProfile(profile, password: "synthetic-original")
        var original = fixture.connection(); original.credentialProfileID = profile.id
        try fixture.state.add(original, password: nil)
        let changed = CredentialProfile(id: profile.id, name: profile.name, username: "changed-synthetic", domain: "NEW")
        var target = fixture.connection(); target.credentialProfileID = profile.id
        let summary = try fixture.state.importConnectionArchive(.init(groups: [], connections: [target], profiles: [changed]), conflictPolicy: .replaceExisting)
        let imported = try XCTUnwrap(fixture.state.connections.first { $0.id == target.id })
        XCTAssertEqual(summary.isolatedProfiles, 1)
        XCTAssertNotEqual(imported.credentialProfileID, profile.id)
        XCTAssertNil(try fixture.state.password(for: imported))
        XCTAssertEqual(fixture.state.resolvedConnection(for: original).username, profile.username)
        XCTAssertEqual(try fixture.state.password(for: original), "synthetic-original")
    }

    @MainActor func testImportedRDPAccessAndTrustSettingsRequireTargetApproval() throws {
        for approved in [false, true] {
            let fixture = ImportSecurityFixture(); defer { fixture.clean() }
            var target = fixture.connection()
            target.rdpRedirectHome = true; target.rdpSharedFolder = "/private/tmp/synthetic-folder"
            target.rdpMicrophone = true; target.rdpPrinters = true; target.rdpSmartCards = true; target.rdpUSBDevices = true
            target.rdpClipboard = true; target.rdpCertificatePolicy = .ignore; target.rdpSecurityMode = .legacyRDP
            _ = try fixture.state.importConnectionArchive(.init(groups: [], connections: [target]), conflictPolicy: .keepExisting,
                options: ConnectionImportOptions(approvedCapabilities: approved ? [target.id] : []))
            let imported = try XCTUnwrap(fixture.state.connections.first { $0.id == target.id })
            XCTAssertEqual(imported.rdpRedirectHome, approved)
            XCTAssertEqual(imported.rdpMicrophone, approved)
            XCTAssertEqual(imported.rdpPrinters, approved)
            XCTAssertEqual(imported.rdpSmartCards, approved)
            XCTAssertEqual(imported.rdpUSBDevices, approved)
            XCTAssertEqual(imported.effectiveRDPClipboard, approved)
            XCTAssertEqual(imported.rdpSharedFolder, approved ? target.rdpSharedFolder : nil)
            XCTAssertEqual(imported.effectiveRDPCertificatePolicy, approved ? .ignore : .systemValidation)
            XCTAssertEqual(imported.effectiveRDPSecurityMode, approved ? .legacyRDP : .nla)
        }
    }

    @MainActor func testImportedAgentIdentityAndX11SettingsDefaultToRestricted() throws {
        let fixture = ImportSecurityFixture(); defer { fixture.clean() }
        var target = fixture.connection(kind: .ssh)
        target.sshForwardAgent = true; target.sshIdentityFile = "/private/tmp/synthetic-identity"
        target.sshX11 = .init(mode: .trusted, display: ":0")
        _ = try fixture.state.importConnectionArchive(.init(groups: [], connections: [target]), conflictPolicy: .keepExisting)
        let imported = try XCTUnwrap(fixture.state.connections.first { $0.id == target.id })
        XCTAssertEqual(imported.sshForwardAgent, false)
        XCTAssertNil(imported.sshIdentityFile)
        XCTAssertNil(imported.sshX11)
    }

    @MainActor func testReviewedSSHAccessCanBeRestoredWithoutChangingOtherTargets() throws {
        let fixture = ImportSecurityFixture(); defer { fixture.clean() }
        var first = fixture.connection(kind: .ssh); first.sshForwardAgent = true
        var second = fixture.connection(kind: .ssh); second.sshForwardAgent = true
        _ = try fixture.state.importConnectionArchive(.init(groups: [], connections: [first, second]), conflictPolicy: .keepExisting,
            options: ConnectionImportOptions(approvedCapabilities: [first.id]))
        XCTAssertEqual(fixture.state.connections.first { $0.id == first.id }?.sshForwardAgent, true)
        XCTAssertEqual(fixture.state.connections.first { $0.id == second.id }?.sshForwardAgent, false)
    }

    @MainActor func testMalformedArchiveIsRejectedAtAppBoundaryBeforeMutation() throws {
        let fixture = ImportSecurityFixture(); defer { fixture.clean() }
        let target = fixture.connection(), before = fixture.state.connections
        XCTAssertThrowsError(try fixture.state.importConnectionArchive(.init(groups: [], connections: [target, target]), conflictPolicy: .replaceExisting))
        XCTAssertEqual(fixture.state.connections, before)
        XCTAssertTrue(fixture.vault.values.isEmpty)
    }

    @MainActor func testDirectCreationCannotCreateCrossNamespaceAliases() throws {
        let fixture = ImportSecurityFixture(); defer { fixture.clean() }
        let target = fixture.connection(); try fixture.state.add(target, password: "synthetic-original")
        XCTAssertThrowsError(try fixture.state.saveProfile(.init(id: target.id, name: "Alias", username: "synthetic"), password: "synthetic-overwrite"))
        let profile = CredentialProfile(name: "Profile", username: "synthetic")
        try fixture.state.saveProfile(profile, password: "synthetic-profile")
        var alias = fixture.connection(); alias.id = profile.id
        XCTAssertThrowsError(try fixture.state.add(alias, password: "synthetic-overwrite"))
        XCTAssertEqual(fixture.vault.values[target.id], "synthetic-original")
        XCTAssertEqual(fixture.vault.values[profile.id], "synthetic-profile")
    }

    @MainActor func testCredentialWriteFailureRollsBackMetadataAndSecrets() throws {
        let fixture = ImportSecurityFixture(); defer { fixture.clean() }
        let original = fixture.connection(); try fixture.state.add(original, password: "synthetic-original")
        let before = fixture.state.connections, values = fixture.vault.values
        var renamed = original; renamed.name = "Reviewed rename"
        let added = fixture.connection()
        fixture.vault.failOnWrite = fixture.vault.writes + 2
        XCTAssertThrowsError(try fixture.state.importConnectionArchive(.init(groups: ["New group"], connections: [renamed, added], credentials: [
            .init(connectionID: renamed.id, password: "synthetic-replacement"), .init(connectionID: added.id, password: "synthetic-new")]), conflictPolicy: .replaceExisting))
        XCTAssertEqual(fixture.state.connections, before)
        XCTAssertEqual(fixture.vault.values, values)
        XCTAssertFalse(fixture.state.groups.contains("New group"))
    }

    @MainActor func testLockedImportDoesNotInspectOrChangeCredentials() throws {
        let fixture = ImportSecurityFixture(); defer { fixture.clean() }
        fixture.gate.setLocked(true)
        let target = fixture.connection(), before = fixture.state.connections
        XCTAssertThrowsError(try fixture.state.importConnectionArchive(.init(groups: [], connections: [target]), conflictPolicy: .keepExisting))
        XCTAssertEqual(fixture.state.connections, before)
        XCTAssertEqual(fixture.vault.inspections, 0)
    }
    func testCommonCryptoPBKDF2MatchesRFC7914Vectors() throws {
        // RFC 7914 §11, first 32 octets of its published 64-byte outputs.
        for (password, salt, iterations, hex) in [
            ("passwd", "salt", 1, "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc"),
            ("Password", "NaCl", 80_000, "4ddcd8f60b98be21830cee5ef22701f9641a4418d04c0414aeff08876b34ab56")
        ] {
            let derived = try ConnectionArchiveKDF.derive(password: password, salt: Data(salt.utf8), iterations: iterations)
            XCTAssertEqual(derived.map { String(format: "%02x", $0) }.joined(), hex)
        }
    }

    func testLegacyEncryptedArchiveRemainsReadableWithOldShortPassphrase() throws {
        // Generated by the pre-hardening application module, not by this KDF.
        let data = try XCTUnwrap(Data(base64Encoded: legacyEncryptedFixture))
        let archive = try ConnectionTransferService.decodeEncrypted(data, password: "synthetic-old")
        XCTAssertEqual(archive.credentials.first?.password, "synthetic-legacy-secret")
        XCTAssertEqual(archive.connections.first?.host, "legacy.example.invalid")
        XCTAssertThrowsError(try ConnectionTransferService.encodeEncrypted(archive, password: "synthetic-old"))
    }

    func testNewEncryptedExportsHaveStrongerDefaultsAndFreshSaltAndNonce() throws {
        let archive = ConnectionArchive(exportedAt: Date(timeIntervalSince1970: 0), groups: [], connections: [])
        let password = "synthetic archive passphrase"
        let first = try ConnectionTransferService.encodeEncrypted(archive, password: password)
        let second = try ConnectionTransferService.encodeEncrypted(archive, password: password)
        let lhs = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
        let rhs = try XCTUnwrap(JSONSerialization.jsonObject(with: second) as? [String: Any])
        XCTAssertEqual(lhs["iterations"] as? Int, 600_000)
        XCTAssertNotEqual(lhs["salt"] as? String, rhs["salt"] as? String)
        let firstSealed = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(lhs["sealedPayload"] as? String)))
        let secondSealed = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(rhs["sealedPayload"] as? String)))
        XCTAssertNotEqual(firstSealed.prefix(12), secondSealed.prefix(12))
        XCTAssertEqual(try ConnectionTransferService.decodeEncrypted(first, password: password), archive)
        XCTAssertFalse(ConnectionTransferService.validExportPassword("short-pass"))
        XCTAssertTrue(ConnectionTransferService.validExportPassword("synthetic long passphrase"))
    }

    func testKDFPreservesCanonicalUnicodePasswordCompatibility() throws {
        let decomposed = "synthetic-e\u{301}-passphrase"
        let composed = decomposed.precomposedStringWithCanonicalMapping
        let salt = Data(repeating: 9, count: 16)
        XCTAssertEqual(try ConnectionArchiveKDF.derive(password: decomposed, salt: salt, iterations: 10_000),
            try ConnectionArchiveKDF.derive(password: composed, salt: salt, iterations: 10_000))
    }

    func testEncryptedHeaderAndAuthenticationTamperingAreRejected() throws {
        let archive = ConnectionArchive(exportedAt: Date(timeIntervalSince1970: 0), groups: [], connections: [])
        let password = "synthetic archive passphrase"
        let data = try ConnectionTransferService.encodeEncrypted(archive, password: password)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for (key, value) in [("iterations", 2_000_001 as Any), ("salt", Data([1]).base64EncodedString() as Any),
                             ("encryption", "unsupported" as Any), ("schemaVersion", 2 as Any)] {
            var changed = envelope; changed[key] = value
            XCTAssertThrowsError(try ConnectionTransferService.decodeEncrypted(JSONSerialization.data(withJSONObject: changed), password: password))
        }
        var changed = envelope
        var sealed = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(envelope["sealedPayload"] as? String)))
        sealed[sealed.count - 1] ^= 1; changed["sealedPayload"] = sealed.base64EncodedString()
        XCTAssertThrowsError(try ConnectionTransferService.decodeEncrypted(JSONSerialization.data(withJSONObject: changed), password: password))
        XCTAssertThrowsError(try ConnectionTransferService.decodeEncrypted(data, password: "wrong-synthetic-passphrase"))
    }

    func testArchiveReadsRefuseSymlinkFIFOAndOversizedRegularFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NethrivaArchiveIO-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("regular"), link = root.appendingPathComponent("link"), fifo = root.appendingPathComponent("fifo")
        try Data("synthetic".utf8).write(to: source)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try ConnectionTransferService.read(from: link))
        XCTAssertThrowsError(try ConnectionTransferService.read(from: fifo))
        XCTAssertThrowsError(try ConnectionTransferService.write(Data("replacement".utf8), to: link))
        XCTAssertEqual(try Data(contentsOf: source), Data("synthetic".utf8))
        let large = root.appendingPathComponent("large")
        XCTAssertTrue(FileManager.default.createFile(atPath: large.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: 26 * 1024 * 1024); try handle.close()
        XCTAssertThrowsError(try ConnectionTransferService.read(from: large))
    }

    func testArchiveWritesArePrivateAtomicAndLeaveNoStagingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NethrivaArchiveSave-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("synthetic.nethriva")
        try ConnectionTransferService.write(Data("first".utf8), to: destination)
        XCTAssertEqual(try ConnectionTransferService.read(from: destination), Data("first".utf8))
        try ConnectionTransferService.write(Data("second".utf8), to: destination)
        XCTAssertEqual(try ConnectionTransferService.read(from: destination), Data("second".utf8))
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o777, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [destination.lastPathComponent])
    }

    @MainActor func testControlCharactersCannotSpoofImportReview() throws {
        let fixture = ImportSecurityFixture(); defer { fixture.clean() }
        for text in ["line\nbreak", "nul\0text", "escape\u{1b}text"] {
            var target = fixture.connection(); target.name = text
            XCTAssertThrowsError(try ConnectionTransferService.encodePlain(.init(groups: [], connections: [target])))
        }
    }

    @MainActor func testOldSessionCannotReadNewCredentialAfterTargetEdit() async throws {
        let fixture = ImportSecurityFixture(); defer { fixture.clean() }
        let original = fixture.connection(); try fixture.state.add(original, password: "synthetic-old-target")
        let snapshot = fixture.state.resolvedConnection(for: original)
        var changed = original; changed.host = "changed.example.invalid"
        try fixture.state.update(changed, password: "synthetic-new-target")
        do { _ = try await fixture.state.sessionPassword(for: snapshot); XCTFail("Stale identity read a credential") }
        catch { XCTAssertTrue(error is CredentialBindingError) }
        let currentValue = try await fixture.state.sessionPassword(for: fixture.state.resolvedConnection(for: changed))
        XCTAssertEqual(currentValue, "synthetic-new-target")
    }

    @MainActor func testOldSessionCannotFollowChangedProfileAccount() async throws {
        let fixture = ImportSecurityFixture(); defer { fixture.clean() }
        let profile = CredentialProfile(name: "Synthetic profile", username: "old-synthetic")
        try fixture.state.saveProfile(profile, password: "synthetic-old-profile")
        var target = fixture.connection(); target.credentialProfileID = profile.id
        try fixture.state.add(target, password: nil)
        let snapshot = fixture.state.resolvedConnection(for: target)
        try fixture.state.saveProfile(.init(id: profile.id, name: profile.name, username: "new-synthetic"), password: "synthetic-new-profile")
        do { _ = try await fixture.state.sessionPassword(for: snapshot); XCTFail("Stale profile identity read a credential") }
        catch { XCTAssertTrue(error is CredentialBindingError) }
    }

    @MainActor func testPendingRDPCredentialSaveCannotWriteAfterTargetEdit() throws {
        let fixture = ImportSecurityFixture(); defer { fixture.clean() }
        let original = fixture.connection(); try fixture.state.add(original, password: "synthetic-original")
        let snapshot = fixture.state.resolvedConnection(for: original)
        var changed = original; changed.host = "changed.example.invalid"
        try fixture.state.update(changed, password: "synthetic-edited-target")
        XCTAssertThrowsError(try fixture.state.saveRDPLogin(.init(username: "synthetic", password: "synthetic-stale-candidate", domain: nil),
            for: original.id, expectedConnection: snapshot))
        XCTAssertEqual(fixture.vault.values[original.id], "synthetic-edited-target")
        XCTAssertEqual(fixture.state.connections.first { $0.id == original.id }?.host, changed.host)
    }

    @MainActor func testPendingRDPCredentialSaveCannotWriteAfterProfileAccountChange() throws {
        let fixture = ImportSecurityFixture(); defer { fixture.clean() }
        let profile = CredentialProfile(name: "Synthetic profile", username: "old-synthetic")
        try fixture.state.saveProfile(profile, password: "synthetic-profile")
        var target = fixture.connection(); target.credentialProfileID = profile.id
        try fixture.state.add(target, password: nil)
        let snapshot = fixture.state.resolvedConnection(for: target)
        try fixture.state.saveProfile(.init(id: profile.id, name: profile.name, username: "new-synthetic"), password: nil)
        XCTAssertThrowsError(try fixture.state.saveRDPLogin(.init(username: "synthetic", password: "synthetic-stale-candidate", domain: nil),
            for: target.id, expectedConnection: snapshot))
        XCTAssertNil(fixture.vault.values[target.id])
        XCTAssertEqual(fixture.state.connections.first { $0.id == target.id }?.credentialProfileID, profile.id)
    }

    @MainActor func testUnsavedSnapshotCannotReadProfileOrOrphanSecret() async throws {
        let fixture = ImportSecurityFixture(); defer { fixture.clean() }
        let profile = CredentialProfile(name: "Synthetic profile", username: "synthetic")
        try fixture.state.saveProfile(profile, password: "synthetic-profile")
        var target = fixture.connection(); target.credentialProfileID = profile.id
        fixture.vault.values[target.id] = "synthetic-orphan"
        XCTAssertNil(try fixture.state.password(for: target))
        let value = try await fixture.state.sessionPassword(for: fixture.state.resolvedConnection(for: target))
        XCTAssertNil(value)
    }

    @MainActor func testTemporaryVMLoginRemainsScopedAcrossEditedTarget() async throws {
        let fixture = ImportSecurityFixture(); defer { fixture.clean() }
        var host = fixture.connection(kind: .virtualization); host.virtualization = .init(platform: .vmware)
        try fixture.state.add(host, password: "synthetic-saved")
        fixture.state.open(host)
        fixture.state.useVMLogin(username: "temporary-synthetic", password: "synthetic-temporary", for: host)
        let temporary = fixture.state.resolvedConnection(for: host)
        let temporaryValue = try await fixture.state.sessionPassword(for: temporary)
        XCTAssertEqual(temporaryValue, "synthetic-temporary")
        var changed = host; changed.host = "changed.example.invalid"
        try fixture.state.update(changed, password: "synthetic-new-target")
        let current = fixture.state.resolvedConnection(for: changed)
        XCTAssertEqual(current.username, host.username)
        let currentValue = try await fixture.state.sessionPassword(for: current)
        XCTAssertEqual(currentValue, "synthetic-new-target")
        do { _ = try await fixture.state.sessionPassword(for: temporary); XCTFail("Temporary login escaped its approved target") }
        catch { XCTAssertTrue(error is CredentialBindingError) }
    }

    @MainActor func testOwnedHostSSHRouteRetainsCredentialsButCannotRetarget() async throws {
        let fixture = ImportSecurityFixture(); defer { fixture.clean() }
        var host = fixture.connection(kind: .virtualization); host.port = 22; host.virtualization = .init(platform: .libvirt)
        try fixture.state.add(host, password: "synthetic-host-ssh")
        fixture.state.openHostSSH(host)
        let snapshot = try XCTUnwrap(fixture.state.selectedTab?.connection)
        XCTAssertEqual(snapshot.kind, .ssh)
        let routeValue = try await fixture.state.sessionPassword(for: snapshot)
        XCTAssertEqual(routeValue, "synthetic-host-ssh")
        var changed = snapshot; changed.host = "changed.example.invalid"
        do { _ = try await fixture.state.sessionPassword(for: changed); XCTFail("Derived SSH route changed its target") }
        catch { XCTAssertTrue(error is CredentialBindingError) }
    }

    @MainActor func testOwnedHyperVConsoleCredentialsRequireExactHostPortAndVM() async throws {
        let fixture = ImportSecurityFixture(); defer { fixture.clean() }
        var host = fixture.connection(kind: .virtualization); host.port = 22; host.virtualization = .init(platform: .hyperv)
        try fixture.state.add(host, password: "synthetic-hyperv")
        let vm = VirtualMachine(id: "11111111-1111-4111-8111-111111111111", name: "Synthetic VM", state: .running)
        fixture.state.openVMConsole(vm, on: host)
        var snapshot = try XCTUnwrap(fixture.state.selectedTab?.connection)
        snapshot.kind = .rdp; snapshot.port = 2179; snapshot.rdpVirtualMachineID = vm.id
        snapshot.rdpCertificatePolicy = host.virtualization?.effectiveCertificatePolicy
        let routeValue = try await fixture.state.sessionPassword(for: snapshot)
        XCTAssertEqual(routeValue, "synthetic-hyperv")
        var changed = snapshot; changed.port = 2180
        do { _ = try await fixture.state.sessionPassword(for: changed); XCTFail("Derived console changed its port") }
        catch { XCTAssertTrue(error is CredentialBindingError) }
        changed = snapshot; changed.rdpVirtualMachineID = "22222222-2222-4222-8222-222222222222"
        do { _ = try await fixture.state.sessionPassword(for: changed); XCTFail("Derived console changed its VM") }
        catch { XCTAssertTrue(error is CredentialBindingError) }
    }

    @MainActor func testProviderResponseCannotReturnAfterTargetChangesWhileFetching() async throws {
        let provider = ImportSecurityProvider()
        let fixture = ImportSecurityFixture(reader: provider); defer { fixture.clean() }
        let profile = CredentialProfile(name: "Synthetic provider", username: "synthetic")
        try fixture.state.saveProfile(profile, password: nil)
        var reference = ExternalCredentialReference(); reference.reference = "op://Synthetic/Item/password"
        try fixture.state.externalCredentials.configure(reference, for: profile.id)
        var target = fixture.connection(); target.credentialProfileID = profile.id
        try fixture.state.add(target, password: nil)
        let snapshot = fixture.state.resolvedConnection(for: target)
        let task = Task { try await fixture.state.sessionPassword(for: snapshot) }
        for _ in 0..<100 { if await provider.waiting { break }; try await Task.sleep(for: .milliseconds(10)) }
        let providerWaiting = await provider.waiting
        XCTAssertTrue(providerWaiting)
        var changed = target; changed.host = "changed.example.invalid"
        try fixture.state.update(changed, password: nil)
        await provider.release()
        do { _ = try await task.value; XCTFail("Provider response escaped its approved target") }
        catch { XCTAssertTrue(error is CredentialBindingError) }
    }

    @MainActor func testExternalProfileRejectsImportedLocalSecretWithoutLosingAuthorization() async throws {
        let provider = ImportSecurityImmediateProvider()
        let fixture = ImportSecurityFixture(reader: provider); defer { fixture.clean() }
        let profile = CredentialProfile(name: "Synthetic external profile", username: "synthetic")
        try fixture.state.saveProfile(profile, password: nil)
        var reference = ExternalCredentialReference()
        reference.kind = .vaultKV2; reference.server = "https://vault.example.invalid"; reference.reference = "kv/synthetic"
        try fixture.state.externalCredentials.configure(reference, for: profile.id)
        try fixture.state.externalCredentials.authorize(profile.id, token: "synthetic-vault-token")
        var connection = fixture.connection(); connection.credentialProfileID = profile.id
        try fixture.state.add(connection, password: nil)
        let beforeProfiles = fixture.state.credentialProfiles, beforeConnections = fixture.state.connections
        let changed = CredentialProfile(id: profile.id, name: "Unapplied imported name", username: profile.username)
        XCTAssertThrowsError(try fixture.state.importConnectionArchive(.init(groups: ["Unapplied"], connections: [], profiles: [changed],
            profileCredentials: [.init(profileID: profile.id, password: "synthetic-imported-local-secret")]), conflictPolicy: .replaceExisting))
        XCTAssertEqual(fixture.state.credentialProfiles, beforeProfiles)
        XCTAssertEqual(fixture.state.connections, beforeConnections)
        XCTAssertFalse(fixture.state.groups.contains("Unapplied"))
        XCTAssertEqual(fixture.state.externalCredentials.references[profile.id], reference)
        XCTAssertTrue(fixture.vault.values.isEmpty)
        let value = try await fixture.state.sessionPassword(for: fixture.state.resolvedConnection(for: connection))
        XCTAssertEqual(value, "synthetic-provider-response")
        let token = await provider.receivedToken
        XCTAssertEqual(token, "synthetic-vault-token")
    }

    @MainActor func testChangedExternalAccountImportsAsSeparateLocalProfile() throws {
        let fixture = ImportSecurityFixture(); defer { fixture.clean() }
        let profile = CredentialProfile(name: "Synthetic external profile", username: "original-synthetic")
        try fixture.state.saveProfile(profile, password: nil)
        var reference = ExternalCredentialReference(); reference.reference = "op://Synthetic/Item/password"
        try fixture.state.externalCredentials.configure(reference, for: profile.id)
        let changed = CredentialProfile(id: profile.id, name: profile.name, username: "new-synthetic")
        var connection = fixture.connection(); connection.credentialProfileID = profile.id
        _ = try fixture.state.importConnectionArchive(.init(groups: [], connections: [connection], profiles: [changed],
            profileCredentials: [.init(profileID: profile.id, password: "synthetic-separate-local-secret")]), conflictPolicy: .replaceExisting)
        let imported = try XCTUnwrap(fixture.state.connections.first { $0.id == connection.id })
        XCTAssertNotEqual(imported.credentialProfileID, profile.id)
        XCTAssertEqual(try fixture.state.password(for: imported), "synthetic-separate-local-secret")
        XCTAssertNil(fixture.vault.values[profile.id])
        XCTAssertEqual(fixture.state.externalCredentials.references[profile.id], reference)
    }

    @MainActor func testCurrentRawProfileLookupSurvivesArchiveMaterializationWhileOldSessionFails() async throws {
        let fixture = ImportSecurityFixture(); defer { fixture.clean() }
        let profile = CredentialProfile(name: "Synthetic profile", username: "original-profile-user")
        try fixture.state.saveProfile(profile, password: "synthetic-original")
        var connection = fixture.connection(); connection.credentialProfileID = profile.id
        try fixture.state.add(connection, password: nil)
        let frozen = fixture.state.resolvedConnection(for: connection)
        try fixture.state.saveProfile(.init(id: profile.id, name: profile.name, username: "changed-profile-user"), password: "synthetic-rotated")
        XCTAssertEqual(try fixture.state.password(for: connection), "synthetic-rotated")
        do { _ = try await fixture.state.sessionPassword(for: frozen); XCTFail("Frozen old profile received a rotated credential") }
        catch { XCTAssertTrue(error is CredentialBindingError) }
        let archive = try fixture.state.makeConnectionArchive(includeCredentials: true)
        let encrypted = try ConnectionTransferService.encodeEncrypted(archive, password: "synthetic archive passphrase", iterations: 10_000)
        let decoded = try ConnectionTransferService.decodeEncrypted(encrypted, password: "synthetic archive passphrase")
        let restored = ImportSecurityFixture(); defer { restored.clean() }
        _ = try restored.state.importConnectionArchive(decoded, conflictPolicy: .keepExisting)
        XCTAssertEqual(try restored.state.password(for: connection), "synthetic-rotated")
    }

    @MainActor func testLegacySeededConnectionProfileAliasCannotUseOrAlterCredential() async throws {
        try await assertLegacyAmbiguityIsBlocked(profileAliasesOwnConnection: true)
    }

    @MainActor func testLegacySeededSelectedProfileAliasCannotUseOrAlterCredential() async throws {
        try await assertLegacyAmbiguityIsBlocked(profileAliasesOwnConnection: false)
    }

    @MainActor private func assertLegacyAmbiguityIsBlocked(profileAliasesOwnConnection: Bool) async throws {
        let fixture = ImportSecurityFixture(); defer { fixture.clean() }
        var connection = fixture.connection()
        let profile = CredentialProfile(id: profileAliasesOwnConnection ? connection.id : UUID(), name: "Synthetic legacy alias", username: "synthetic")
        var records = [RemoteConnection.localShell, connection]
        if !profileAliasesOwnConnection {
            connection.credentialProfileID = profile.id
            var other = fixture.connection(); other.id = profile.id
            records = [.localShell, other, connection]
        }
        // Simulate a saved library produced before namespace checks existed.
        try UserDefaultsConnectionStore(defaults: fixture.defaults, storageKey: "connections", legacyDefaults: nil).save(records)
        try fixture.profileStore.save([profile])
        fixture.vault.values[profile.id] = "synthetic-legacy-original"
        let state = fixture.state, before = state.connections
        XCTAssertThrowsError(try state.password(for: connection))
        do { _ = try await state.sessionPassword(for: state.resolvedConnection(for: connection)); XCTFail("Ambiguous legacy identity read a credential") }
        catch { XCTAssertTrue(error is CredentialBindingError) }
        XCTAssertThrowsError(try state.update(connection, password: "synthetic-unwanted-write"))
        XCTAssertThrowsError(try state.savePassword("synthetic-unwanted-write", for: connection))
        XCTAssertThrowsError(try state.removePassword(for: connection))
        XCTAssertThrowsError(try state.deleteProfile(profile))
        state.delete(connection)
        XCTAssertEqual(state.connections, before)
        XCTAssertEqual(state.credentialProfiles, [profile])
        XCTAssertEqual(fixture.vault.values, [profile.id: "synthetic-legacy-original"])
        XCTAssertEqual(fixture.vault.reads, 0)
        XCTAssertEqual(fixture.vault.writes, 0)
    }

    func testProviderSnapshotRejectsUnsignedScriptAndWrongPublisher() throws {
        let fixture = try ProviderExecutableFixture(); defer { fixture.clean() }
        let script = fixture.root.appendingPathComponent("unsigned-script")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        XCTAssertThrowsError(try VerifiedProviderExecutable(source: script, temporaryParent: fixture.root))
        XCTAssertThrowsError(try VerifiedProviderExecutable(source: URL(fileURLWithPath: "/bin/echo"), temporaryParent: fixture.root))
        XCTAssertFalse(try fixture.hasSnapshotDirectory())
    }

    func testProviderSnapshotCopiesOnlyRegularBoundedExecutable() throws {
        let fixture = try ProviderExecutableFixture(); defer { fixture.clean() }
        let fifo = fixture.root.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o700), 0)
        XCTAssertThrowsError(try VerifiedProviderExecutable(source: fifo, temporaryParent: fixture.root, signatureVerifier: { _ in }))
        let oversized = try fixture.executable()
        let file = try FileHandle(forWritingTo: oversized)
        try file.truncate(atOffset: UInt64(VerifiedProviderExecutable.maximumBytes + 1)); try file.close()
        XCTAssertThrowsError(try VerifiedProviderExecutable(source: oversized, temporaryParent: fixture.root, signatureVerifier: { _ in }))
        XCTAssertFalse(try fixture.hasSnapshotDirectory())
    }

    func testProviderSnapshotSupportsInstallSymlinkButIsIndependentAndPrivate() throws {
        let fixture = try ProviderExecutableFixture(); defer { fixture.clean() }
        let original = try fixture.executable(), alias = fixture.root.appendingPathComponent("installed-op-link")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)
        var verified = false
        let snapshot = try VerifiedProviderExecutable(source: alias, temporaryParent: fixture.root, signatureVerifier: { url in
            verified = true
            XCTAssertNotEqual(url, original)
            XCTAssertEqual(try Data(contentsOf: url), fixture.payload)
        })
        XCTAssertTrue(verified)
        try snapshot.validate()
        let privateMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: snapshot.url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)
        let executableMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: snapshot.url.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(privateMode.intValue & 0o777, 0o700)
        XCTAssertEqual(executableMode.intValue & 0o777, 0o500)
        try Data("changed public test source".utf8).write(to: original)
        XCTAssertEqual(try Data(contentsOf: snapshot.url), fixture.payload)
        snapshot.clean()
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: alias.path))
        XCTAssertFalse(try fixture.hasSnapshotDirectory())
    }

    func testProviderSnapshotRejectsVerifierFailureAndCleans() throws {
        let fixture = try ProviderExecutableFixture(); defer { fixture.clean() }
        let source = try fixture.executable()
        XCTAssertThrowsError(try VerifiedProviderExecutable(source: source, temporaryParent: fixture.root, signatureVerifier: { _ in
            throw ExternalCredentialError.untrustedExecutable
        }))
        XCTAssertFalse(try fixture.hasSnapshotDirectory())
    }

    func testProviderSnapshotCancellationCleansWithoutExecution() throws {
        let fixture = try ProviderExecutableFixture(); defer { fixture.clean() }
        let source = try fixture.executable()
        var checks = 0
        XCTAssertThrowsError(try VerifiedProviderExecutable(source: source, temporaryParent: fixture.root, signatureVerifier: { _ in }, checkCancellation: {
            checks += 1
            if checks == 2 { throw CancellationError() }
        })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(try fixture.hasSnapshotDirectory())
    }

    func testProviderSnapshotPathSwapCannotRedirectCleanup() throws {
        let fixture = try ProviderExecutableFixture(); defer { fixture.clean() }
        let source = try fixture.executable()
        let sentinel = fixture.root.appendingPathComponent("sentinel", isDirectory: true)
        try FileManager.default.createDirectory(at: sentinel, withIntermediateDirectories: false)
        let marker = sentinel.appendingPathComponent("keep")
        try Data("synthetic sentinel".utf8).write(to: marker)
        let moved = fixture.root.appendingPathComponent("moved-snapshot")
        XCTAssertThrowsError(try VerifiedProviderExecutable(source: source, temporaryParent: fixture.root, signatureVerifier: { url in
            let originalDirectory = url.deletingLastPathComponent()
            try FileManager.default.moveItem(at: originalDirectory, to: moved)
            try FileManager.default.createSymbolicLink(at: originalDirectory, withDestinationURL: sentinel)
        }))
        XCTAssertEqual(try Data(contentsOf: marker), Data("synthetic sentinel".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.appendingPathComponent("op").path))
    }

    private var legacyEncryptedFixture: String { "ewogICJlbmNyeXB0aW9uIiA6ICJBRVMtMjU2LUdDTSIsCiAgImZvcm1hdCIgOiAiY29tLnZpdGFsaWkubmV0aHJpdmEuY29ubmVjdGlvbnMuZW5jcnlwdGVkIiwKICAiaXRlcmF0aW9ucyIgOiAxMDAwMCwKICAia2V5RGVyaXZhdGlvbiIgOiAiUEJLREYyLUhNQUMtU0hBMjU2IiwKICAic2FsdCIgOiAiNmRQbE52dUxLeHp1amt5TitseGZmUT09IiwKICAic2NoZW1hVmVyc2lvbiIgOiAxLAogICJzZWFsZWRQYXlsb2FkIiA6ICIzS21lQWlnODB4SnVIMnErWFRkYkZ4N25xQkoxeDRjcXBFQWVxZHhUTFA0dUM4VXdvQXFFbnBvK2FRRUoySkVpeWNCVXN3aE9vWGxzamlJYVVZWkNCaDZqWlRza1RVaE9VMFp3OTFaOWtkNkJiWjFJOGgwODcybjJIVlN4eU5ySnk1VHFMYTJCaWNlNVVHUGZCVmw2SkxVWGNxTWZ4S2tmYWZZSC9hVitPZ2JOMnhEN0lMcU5BV21mYnlLT1lwUHd1MzlsamtSM3F5WElUTnpwYnljZ2ZRL2JRVG1ULzdmS3dJVzNJUzdJbm1sanZUTjJ1a3k1eHdrSzMyaExmSmJjcHV2enpIKzVSWmRxMHNjNHF3bGV1VmNWZEhUVG5OREVhZjh4alViaHV5VUdLeVZJK0swWC9IL3o2b0VRdUxPTjErZ0F6NEVkSUJQSXlaUStEd3ZtM1NvdDdzVzVjT01VSG5SRW14d3ZOK2RZRERLaDZzRk5sc01ZQ0JLYmZQdGNlWEkwemhsV1ZGWGQ3V0lSQkppU1FVSHJYNUtZNVZrS3dkcHZTb0h5R3ZJWHkxWVo5OVU2V29xay85Y0M1aFNkR0svR1hkOWkyYlJnVmRObFJLWDdrbkZGTmNQdUNkYlJ5bWJoMERJOTEweE1ZTWdnYzBoelVKSS9SOFZBRFhDTVcvZ3VlbWtCcndPWnNrN0wwYTdya1pLdS8zQUh2MkprZU1Hd21NN2dPd0NLaG5FOFJlVWx6SVZIaHZjNGRGdWd0ZWg5MGhxSWZ1alNwZUpRMzhOelphY1NkK1FMRmJnejE3enpsQTlIMlgzQWJmZFRQaThRWFpFU0tkNU9IZnlQUXJOSEJsek1wY2hYbWZGb2FUbFdNR0pUS3FTOFo3bDJUKzI4QUhsQVRsYUdKR1B1ZUlhZFRQMnpBaWhjMTMydENpQjhvd1ZnVnZvaGUydEczbmhSR0QyL2ZuTWsrSHhIQWVyWVIvWllSWjd1RGxnQ28yUVpZQW5CWVE4amZzbkx0SVZoU2gzZXV0a1h6cVBhb2NWenJiV2JMaHg5Y2l1Z2MvMmZMcWRNdTNQaDVYcHFkdnpoV3VqcVlWOUhXdFB1aFdQMDNxSS9Oek8ydVpma3k2L2Flc2FnWmFiNFJvcnExcUxCZ254S2Y0eEZURmRJR1pxdDdHbzRWd2lkaXN3MkVnd3lVVVV6K1MxQ2dBZzBmVVdTc0FKdkw1Z0czSllwVmJMaVRYVFVJaUpGT0V0Q2F2YjlyUT09Igp9" }

}

private final class ImportSecurityVault: CredentialVault {
    enum Failure: Error { case syntheticWrite }
    var values: [UUID: String] = [:]
    var failOnWrite: Int?
    var writes = 0, inspections = 0, reads = 0
    func save(password: String, for id: UUID) throws {
        writes += 1
        if writes == failOnWrite { throw Failure.syntheticWrite }
        values[id] = password
    }
    func password(for id: UUID) throws -> String? { reads += 1; return values[id] }
    func containsPassword(for id: UUID) throws -> Bool { inspections += 1; return values[id] != nil }
    func deletePassword(for id: UUID) throws { values[id] = nil }
}

@MainActor private final class ImportSecurityFixture {
    let suite = "NethrivaSecurityImport." + UUID().uuidString
    let defaults: UserDefaults
    let gate = CredentialAccessGate()
    let vault = ImportSecurityVault()
    let profileStore = InMemoryCredentialProfileStore()
    let reader: any ExternalCredentialReading
    lazy var state = AppState(store: UserDefaultsConnectionStore(defaults: defaults, storageKey: "connections", legacyDefaults: nil),
        groupStore: UserDefaultsConnectionGroupStore(defaults: defaults), profileStore: profileStore, credentialVault: vault,
        libraryTools: LibraryTools(defaults: defaults), sharedLibraries: SharedLibraries(defaults: defaults),
        externalCredentials: ExternalCredentials(defaults: defaults, reader: reader, gate: gate), credentialGate: gate)
    init(reader: any ExternalCredentialReading = ExternalCredentialReader()) {
        self.reader = reader; defaults = UserDefaults(suiteName: suite)!
    }
    func connection(kind: ConnectionKind = .rdp) -> RemoteConnection {
        RemoteConnection(name: "Synthetic target", kind: kind, host: "target.example.invalid", username: "synthetic")
    }
    func clean() { defaults.removePersistentDomain(forName: suite) }
}

private actor ImportSecurityProvider: ExternalCredentialReading {
    private var continuation: CheckedContinuation<String, Error>?
    var waiting: Bool { continuation != nil }
    func read(_ reference: ExternalCredentialReference, token: String?) async throws -> String {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(returning: "synthetic-provider-response"); continuation = nil }
}

private actor ImportSecurityImmediateProvider: ExternalCredentialReading {
    private(set) var receivedToken: String?
    func read(_ reference: ExternalCredentialReference, token: String?) async throws -> String {
        receivedToken = token
        return "synthetic-provider-response"
    }
}

private struct ProviderExecutableFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("NethrivaProviderTests-" + UUID().uuidString)
    let payload = Data([0xcf, 0xfa, 0xed, 0xfe] + Array(repeating: UInt8(0), count: 128))
    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
    func executable() throws -> URL {
        let url = root.appendingPathComponent("public-macho-fixture-" + UUID().uuidString)
        try payload.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
    func hasSnapshotDirectory() throws -> Bool {
        try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("NethrivaProvider-") }
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}
