import AppKit
import Network
import XCTest
@testable import Nethriva

final class ReliabilityTests: XCTestCase {
    func testHostedTestsCannotUsePersonalDataProfile() {
        XCTAssertTrue(NethrivaDataProfile.isTesting)
        XCTAssertNotEqual(NethrivaDataProfile.effectiveCredentialService, NethrivaDataProfile.credentialService)
        XCTAssertTrue(NethrivaDataProfile.effectiveLegacyCredentialServices.isEmpty)
        XCTAssertNil(NethrivaDataProfile.legacyDefaults)
    }
    func testBinarySFTPListsLiteralNamesAndReusesChannel() async throws {
        try await Task.detached {
            let fixture = try LocalSFTPFixture()
            defer { fixture.close() }
            for name in ["space name.txt", "quote\"name.txt", "star*.txt", "日本語.txt"] {
                try Data("fixture".utf8).write(to: fixture.root.appendingPathComponent(name))
            }
            let first = try fixture.channel.list(fixture.root.path)
            XCTAssertEqual(Set(first.items.map(\.name)), ["space name.txt", "quote\"name.txt", "star*.txt", "日本語.txt"])
            let second = try fixture.channel.list(fixture.root.path)
            XCTAssertEqual(first.items, second.items)
            XCTAssertTrue(fixture.channel.isRunning)
        }.value
    }

    func testBinarySFTPPipelinedUploadDownloadRenameAndDelete() async throws {
        try await Task.detached {
            let fixture = try LocalSFTPFixture()
            defer { fixture.close() }
            let source = fixture.root.appendingPathComponent("source.bin")
            let data = Data((0..<400000).map { UInt8($0 % 251) })
            try data.write(to: source)
            let remote = fixture.root.appendingPathComponent("remote.bin")
            let progress = LockedProgress()
            try fixture.channel.upload(source, to: remote.path, policy: .ask) { progress.record($0) }
            XCTAssertEqual(try Data(contentsOf: remote), data)
            XCTAssertEqual(progress.last?.bytes, Int64(data.count))
            let destination = fixture.root.appendingPathComponent("download.bin")
            try fixture.channel.download(remote.path, to: destination, policy: .ask) { _ in }
            XCTAssertEqual(try Data(contentsOf: destination), data)
            let moved = fixture.root.appendingPathComponent("renamed.bin")
            try fixture.channel.rename(remote.path, moved.path, overwrite: false)
            XCTAssertNil(try fixture.channel.attributes(remote.path))
            try fixture.channel.pathRequest(13, moved.path)
            XCTAssertNil(try fixture.channel.attributes(moved.path))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).contains { $0.hasSuffix(".partial") })
        }.value
    }

    func testTransferConflictsPreserveFilesAndSupportRenameSkipOverwrite() async throws {
        try await Task.detached {
            let fixture = try LocalSFTPFixture()
            defer { fixture.close() }
            let source = fixture.root.appendingPathComponent("source.txt"), target = fixture.root.appendingPathComponent("target.txt")
            try Data("new".utf8).write(to: source); try Data("old".utf8).write(to: target)
            XCTAssertThrowsError(try fixture.channel.upload(source, to: target.path, policy: .ask) { _ in })
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "old")
            try fixture.channel.upload(source, to: target.path, policy: .skip) { _ in }
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "old")
            try fixture.channel.upload(source, to: target.path, policy: .rename) { _ in }
            XCTAssertEqual(try String(contentsOf: fixture.root.appendingPathComponent("target (1).txt"), encoding: .utf8), "new")
            try fixture.channel.upload(source, to: target.path, policy: .overwrite) { _ in }
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "new")
            let destination = fixture.root.appendingPathComponent("destination.txt")
            try Data("previous".utf8).write(to: destination)
            XCTAssertThrowsError(try fixture.channel.download(target.path, to: destination, policy: .ask) { _ in })
            XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "previous")
            try fixture.channel.download(target.path, to: destination, policy: .overwrite) { _ in }
            XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "new")
        }.value
    }

    func testUploadReusesURLAfterSourceChangesBetweenTransfers() async throws {
        try await Task.detached {
            let fixture = try LocalSFTPFixture()
            defer { fixture.close() }
            let source = fixture.root.appendingPathComponent("source.txt")
            let target = fixture.root.appendingPathComponent("target.txt")
            try Data("original".utf8).write(to: source)
            try fixture.channel.upload(source, to: target.path, policy: .ask) { _ in }
            try Data("replacement".utf8).write(to: source)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_010)], ofItemAtPath: source.path)
            try fixture.channel.upload(source, to: target.path, policy: .rename) { _ in }
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "original")
            XCTAssertEqual(try String(contentsOf: fixture.root.appendingPathComponent("target (1).txt"), encoding: .utf8), "replacement")
            try fixture.channel.upload(source, to: target.path, policy: .overwrite) { _ in }
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "replacement")
        }.value
    }

    func testUploadRejectsSameSizeSourceMutationBeforePublish() async throws {
        try await Task.detached {
            let fixture = try LocalSFTPFixture()
            defer { fixture.close() }
            let source = fixture.root.appendingPathComponent("source.bin")
            let target = fixture.root.appendingPathComponent("target.bin")
            try Data(repeating: 7, count: 1_000_000).write(to: source)
            try Data("original-destination".utf8).write(to: target)
            XCTAssertThrowsError(try fixture.channel.upload(source, to: target.path, policy: .overwrite) { progress in
                guard progress.bytes < 1_000_000 else { return }
                try? Data(repeating: 9, count: 1_000_000).write(to: source)
                try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_020)], ofItemAtPath: source.path)
            })
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "original-destination")
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).contains { $0.hasSuffix(".partial") })
        }.value
    }

    func testRecursiveTransfersDoNotFollowSymbolicLinks() async throws {
        try await Task.detached {
            let fixture = try LocalSFTPFixture()
            defer { fixture.close() }
            let source = fixture.root.appendingPathComponent("folder")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            try Data("child".utf8).write(to: source.appendingPathComponent("child.txt"))
            let remote = fixture.root.appendingPathComponent("remote-folder")
            try fixture.channel.upload(source, to: remote.path, policy: .ask) { _ in }
            let destination = fixture.root.appendingPathComponent("download-folder")
            try fixture.channel.download(remote.path, to: destination, policy: .ask) { _ in }
            XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("child.txt"), encoding: .utf8), "child")
            let link = fixture.root.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
            XCTAssertThrowsError(try fixture.channel.upload(link, to: remote.path, policy: .overwrite) { _ in })
            XCTAssertThrowsError(try fixture.channel.download(link.path, to: fixture.root.appendingPathComponent("bad"), policy: .ask) { _ in })
        }.value
    }

    func testCancellationDoesNotPublishPartialUpload() async throws {
        try await Task.detached {
            let fixture = try LocalSFTPFixture()
            defer { fixture.close() }
            let source = fixture.root.appendingPathComponent("source.bin"), target = fixture.root.appendingPathComponent("target.bin")
            try Data(repeating: 7, count: 1000000).write(to: source)
            try Data("original".utf8).write(to: target)
            let token = fixture.channel.cancellation
            XCTAssertThrowsError(try fixture.channel.upload(source, to: target.path, policy: .overwrite) { _ in token.cancel() })
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "original")
        }.value
    }

    func testSFTPRejectsOversizedPacketAndWrongRequestID() throws {
        let input = Pipe(), output = Pipe()
        let process = Process(), token = SFTPCancellation()
        let channel = SFTPChannel(process: process, input: input.fileHandleForWriting, output: output.fileHandleForReading, cancellation: token)
        defer { channel.close(); try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close() }
        var oversized = SFTPBytes(); oversized.uint32(1024 * 1024 + 1)
        try output.fileHandleForWriting.write(contentsOf: oversized.data)
        XCTAssertThrowsError(try channel.initialize())
        var version = SFTPBytes(); version.uint32(3)
        var framed = SFTPBytes(); framed.uint32(5); framed.byte(2); framed.data += version.data
        var wrong = SFTPBytes(); wrong.uint32(999); wrong.uint32(0)
        framed.uint32(UInt32(wrong.data.count + 1)); framed.byte(104); framed.data += wrong.data
        try output.fileHandleForWriting.write(contentsOf: framed.data)
        try channel.initialize()
        XCTAssertThrowsError(try channel.list("/"))
    }

    func testSFTPArgumentsKeepSecretsOutAndRejectOptionInjection() throws {
        var connection = RemoteConnection(name: "Test", kind: .ssh, host: "host.example.invalid", username: "test-user")
        connection.sshJumpHost = "bastion.example.invalid"
        let arguments = try SFTPChannel.arguments(for: connection)
        XCTAssertTrue(arguments.contains("BatchMode=yes")); XCTAssertTrue(arguments.contains("StrictHostKeyChecking=yes"))
        XCTAssertEqual(Array(arguments.suffix(4)), ["-s", "--", "test-user@host.example.invalid", "sftp"])
        connection.host = "-oProxyCommand=bad"
        XCTAssertThrowsError(try SFTPChannel.arguments(for: connection))
        for value in ["bad\nname", "bad\rname", "bad\0name", "../escape", "a/b", ".", ".."] { XCTAssertThrowsError(try SFTPPath.component(value)) }
    }

    func testSFTPBootstrapCreatesOwnedCommandFreeSSHMaster() throws {
        let connection = RemoteConnection(name: "Test", kind: .ssh, host: "host.example.invalid", port: 2222,
            username: "test-user", sshAuthentication: .password, sshIdentityFile: "/tmp/synthetic-key", sshJumpHost: "jump.example.invalid")
        let arguments = try SFTPAuthenticationBootstrap.sshArguments(for: connection)
        XCTAssertEqual(Array(arguments.prefix(5)), ["-T", "-N", "-f", "-p", "2222"])
        for option in ["ControlMaster=auto", "ControlPersist=600", "ClearAllForwardings=yes", "PermitLocalCommand=no", "RemoteCommand=none", "ForwardX11=no", "StrictHostKeyChecking=ask", "PubkeyAuthentication=no"] {
            XCTAssertTrue(arguments.contains(option), option)
        }
        XCTAssertTrue(arguments.contains("ControlPath=\(try SSHConnectionReuse.controlPath(for: connection))"))
        XCTAssertTrue(arguments.contains("/tmp/synthetic-key"))
        XCTAssertTrue(arguments.contains("jump.example.invalid"))
        XCTAssertEqual(arguments.last, "test-user@host.example.invalid")
        XCTAssertFalse(arguments.contains("pwd"))
        XCTAssertFalse(arguments.contains("sftp"))
    }

    @MainActor func testRecoveryRequiresAvailableNetworkAndDoesNotRepeatEpoch() {
        let recovery = SessionRecovery(observeSystem: false)
        recovery.network(available: true, signature: "test-a")
        XCTAssertFalse(recovery.suspended); XCTAssertEqual(recovery.epoch, 0)
        recovery.sleep(); recovery.finishRecovery()
        XCTAssertTrue(recovery.suspended); XCTAssertEqual(recovery.epoch, 0)
        recovery.network(available: false, signature: "test-a"); recovery.wake(); recovery.finishRecovery()
        XCTAssertEqual(recovery.epoch, 0)
        recovery.network(available: true, signature: "test-a"); recovery.finishRecovery()
        XCTAssertFalse(recovery.suspended); XCTAssertEqual(recovery.epoch, 1)
        recovery.finishRecovery(); XCTAssertEqual(recovery.epoch, 1)
        recovery.network(available: true, signature: "test-b"); XCTAssertTrue(recovery.suspended)
        recovery.finishRecovery(); XCTAssertEqual(recovery.epoch, 2)
    }

    @MainActor func testTransfersDoNotReplayOnNetworkRecovery() {
        let connection = RemoteConnection(name: "Test", kind: .ssh, host: "host.example.invalid")
        let queue = SFTPTransferQueue(connection: connection)
        queue.suspend()
        queue.upload([URL(fileURLWithPath: "/tmp/synthetic.txt")], to: "/tmp")
        queue.suspend()
        XCTAssertEqual(queue.jobs.first?.state, .interrupted)
        queue.resume()
        XCTAssertEqual(queue.jobs.first?.state, .interrupted)
        queue.close()
    }

    func testProbeCancellationAndExactlyOnceCompletion() async throws {
        let completion = ProbeCompletion<Int>()
        completion.finish(.success(1)); completion.finish(.success(2))
        let value = try await withCheckedThrowingContinuation { completion.install($0) }
        XCTAssertEqual(value, 1)
        let task = Task { try await ConnectionCheckService.tcp(host: "192.0.2.1", port: 65535, timeout: 5) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled probe must not succeed") } catch is CancellationError {} catch { XCTFail("Unexpected error") }
        let invalidPort = try await ConnectionCheckService.tcp(host: "localhost", port: 0)
        XCTAssertFalse(invalidPort)
    }

    func testConnectionCheckReportContainsOnlySafeStageResults() {
        let report = ConnectionCheckService.report([.init(stage: "Authentication", outcome: .failed, detail: SFTPServiceError.authenticationFailed.localizedDescription)])
        XCTAssertTrue(report.contains("Authentication: failed"))
        XCTAssertFalse(report.contains("host.example.invalid")); XCTAssertFalse(report.contains("test-user"))
    }

    func testLargeStructuredAttributeDecodingHasBoundedWork() throws {
        var bytes = SFTPBytes(); bytes.uint32(1 | 4); bytes.uint64(123); bytes.uint32(0o100644)
        let fixture = bytes.data
        measure {
            for _ in 0..<10000 { var reader = SFTPReader(data: fixture); _ = try? SFTPAttributes.decode(&reader) }
        }
    }

    @MainActor func testInactiveTabCannotStealKeyboardFocus() async {
        let gate = SessionFocusGate()
        var calls = 0
        gate.update(true) { calls += 1 }
        gate.update(false) { calls += 100 }
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(calls, 0)
        gate.update(true) { calls += 1 }
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(calls, 1)
        gate.update(true) { calls += 100 }
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(calls, 1)
    }

    @MainActor func testRDPStoppedControllerDoesNotReconnectOnViewportChange() {
        let controller = RDPSessionController(connection: RemoteConnection(name: "Test", kind: .rdp, host: "desktop.example.invalid"))
        controller.stop()
        controller.setDisplayScale(140)
        controller.fitToScreen(); controller.restoreFocus(); controller.setSurfaceActive(false)
        XCTAssertEqual(controller.phase, .stopped)
        XCTAssertFalse(controller.canDisconnect); XCTAssertTrue(controller.canReconnect)
        controller.reconnect()
        XCTAssertEqual(controller.phase, .idle)
        controller.stop()
    }

    @MainActor func testTransferQueueConflictRequiresExplicitResolution() async {
        let fake = FakeTransferService()
        let queue = SFTPTransferQueue(connection: RemoteConnection(name: "Test", kind: .ssh, host: "host.example.invalid"), service: fake)
        queue.upload([URL(fileURLWithPath: "/tmp/synthetic.txt")], to: "/tmp")
        for _ in 0..<100 { if queue.jobs.first?.state == .conflict { break }; await Task.yield() }
        XCTAssertEqual(queue.jobs.first?.state, .conflict)
        XCTAssertEqual(fake.attempts, 1)
        queue.resume()
        XCTAssertEqual(fake.attempts, 1)
        let done = expectation(description: "Explicit transfer retry")
        queue.onUploadFinished = { done.fulfill() }
        queue.retry(queue.jobs[0].id, policy: .rename)
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(queue.jobs.first?.state, .completed)
        XCTAssertEqual(fake.attempts, 2)
        queue.close()
    }

    @MainActor func testLargeInventoryWorkRunsOutsideTheUIThread() async throws {
        let machines = (0..<10000).map { VirtualMachine(id: String($0), name: "Synthetic VM \($0)", state: .running) }
        let result = try await BackgroundWork.run {
            XCTAssertFalse(Thread.isMainThread)
            return VMInventorySearch.filter(machines, query: "VM 999")
        }
        XCTAssertEqual(result.count, 11)
    }

    func testAuthenticationBootstrapRejectsBadPasswordAndNeverAutoTrusts() async throws {
        try await Task.detached {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("NethrivaAuthTest-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: root) }
            let script = root.appendingPathComponent("mock-auth")
            let text = """
            #!/bin/sh
            /bin/stty -echo
            printf 'Password: '
            IFS= read -r password
            if [ "$password" != 'unit-test-placeholder' ]; then printf '\\nPermission denied\\n'; exit 1; fi
            exit 0
            """
            try text.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            let bootstrap = SFTPAuthenticationBootstrap(sshExecutablePath: script.path, timeout: 2)
            let connection = RemoteConnection(name: "Test", kind: .ssh, host: "host.example.invalid")
            XCTAssertNoThrow(try bootstrap.authenticate(connection: connection, password: "unit-test-placeholder", cancellation: SFTPCancellation()))
            XCTAssertThrowsError(try bootstrap.authenticate(connection: connection, password: "incorrect-test-value", cancellation: SFTPCancellation())) {
                guard case SFTPServiceError.authenticationFailed = $0 else { return XCTFail("Wrong authentication classification") }
            }
            XCTAssertThrowsError(try bootstrap.authenticate(connection: connection, password: nil, cancellation: SFTPCancellation())) {
                guard case SFTPServiceError.passwordRequired = $0 else { return XCTFail("Wrong missing-password classification") }
            }
            try "#!/bin/sh\nprintf 'Are you sure you want to continue connecting (yes/no)? '\nread answer\nexit 1\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            XCTAssertThrowsError(try bootstrap.authenticate(connection: connection, password: "unit-test-placeholder", cancellation: SFTPCancellation())) {
                guard case SFTPServiceError.hostKeyNotTrusted = $0 else { return XCTFail("Unknown hosts must not be accepted automatically") }
            }
        }.value
    }

    func testAuthenticationHelperCancellationStopsPromptWait() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NethrivaCancelTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("mock-wait")
        try "#!/bin/sh\nprintf 'Connecting...\\n'\nsleep 10\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let token = SFTPCancellation(), bootstrap = SFTPAuthenticationBootstrap(sshExecutablePath: script.path)
        let started = Date()
        let worker = Task.detached {
            try bootstrap.authenticate(connection: RemoteConnection(name: "Test", kind: .ssh, host: "host.example.invalid"), password: nil, cancellation: token)
        }
        try await Task.sleep(for: .milliseconds(150)); token.cancel()
        do { try await worker.value; XCTFail("Prompt wait must be cancellable") } catch is CancellationError {} catch { XCTFail("Unexpected cancellation classification") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }
}

private final class FakeTransferService: SFTPTransferring, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var attempts: Int { lock.withLock { count } }
    func close() {}
    func upload(localURLs: [URL], to directory: String, connection: RemoteConnection, password: String?, policy: SFTPConflictPolicy,
                progress: @escaping @Sendable (SFTPTransferProgress) -> Void) async throws {
        lock.withLock { count += 1 }
        if policy == .ask { throw SFTPServiceError.conflict }
        progress(.init(bytes: 1, total: 1))
    }
    func download(item: SFTPFileItem, to url: URL, connection: RemoteConnection, password: String?, policy: SFTPConflictPolicy,
                  progress: @escaping @Sendable (SFTPTransferProgress) -> Void) async throws {}
}

private final class LockedProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var value: SFTPTransferProgress?
    var last: SFTPTransferProgress? { lock.withLock { value } }
    func record(_ progress: SFTPTransferProgress) { lock.withLock { value = progress } }
}

final class LocalSFTPFixture {
    let root: URL
    let channel: SFTPChannel
    init() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/libexec/sftp-server") else { throw XCTSkip("System local SFTP server is unavailable") }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("NethrivaSFTPTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let process = Process(), input = Pipe(), output = Pipe(), cancellation = SFTPCancellation()
        process.executableURL = URL(fileURLWithPath: "/usr/libexec/sftp-server")
        process.arguments = ["-d", root.path]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try cancellation.start(process)
        channel = SFTPChannel(process: process, input: input.fileHandleForWriting, output: output.fileHandleForReading, cancellation: cancellation)
        try channel.initialize()
    }
    func close() { channel.close(); try? FileManager.default.removeItem(at: root) }
}
