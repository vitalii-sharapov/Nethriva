import AppKit
import Darwin
import SwiftTerm
import XCTest
@testable import Nethriva

final class SecuritySSHTests: XCTestCase {
    @MainActor func testActualPTYOutputStillPassesIngressAndPromptGuards() async throws {
        let view = PasswordObservingTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        defer { view.terminate() }
        let ended = expectation(description: "Synthetic child ended")
        let delegate = SecurityPTYLifecycleProbe { ended.fulfill() }
        view.processDelegate = delegate
        var output = [UInt8]()
        view.outputObserver = { output += $0 }
        view.startProcess(executable: "/bin/sh", args: ["-c", #"printf 'visible\033Pq!999999999~\033\\password:'"#])
        await fulfillment(of: [ended], timeout: 10)
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "visiblepassword:")
        XCTAssertTrue(view.authenticationPrompt)
    }

    @MainActor func testActualPTYReceivesUserInputThroughNewTerminalAPI() async throws {
        let view = PasteableLocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        defer { view.terminate() }
        let ended = expectation(description: "Synthetic input echoed by child")
        let delegate = SecurityPTYLifecycleProbe { ended.fulfill() }
        view.processDelegate = delegate
        var output = "", sent = false
        view.outputObserver = { bytes in
            output += String(decoding: bytes, as: UTF8.self)
            if !sent && output.contains("READY") {
                sent = true
                view.send(txt: "synthetic-input\n")
            }
        }
        view.startProcess(executable: "/bin/sh", args: ["-c", #"/bin/stty -echo; printf READY; IFS= read -r value; printf 'RECEIVED:%s' "$value""#])
        await fulfillment(of: [ended], timeout: 10)
        XCTAssertTrue(sent)
        XCTAssertTrue(output.contains("RECEIVED:synthetic-input"))
    }

    @MainActor func testPTYBackpressurePreservesLargeOutputAndTerminationOrder() async throws {
        let view = PasteableLocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        defer { view.terminate() }
        let ended = expectation(description: "Bounded synthetic output ended")
        var count = 0
        view.outputObserver = { count += $0.filter { $0 == 65 }.count }
        let delegate = SecurityPTYLifecycleProbe { ended.fulfill() }
        view.processDelegate = delegate
        view.startProcess(executable: "/bin/sh", args: ["-c", #"/usr/bin/head -c 2097152 /dev/zero | /usr/bin/tr '\000' A"#])
        await fulfillment(of: [ended], timeout: 20)
        XCTAssertEqual(count, 2097152, "Backpressure must preserve bytes, not truncate or reorder termination")
    }

    private func connection() -> RemoteConnection {
        RemoteConnection(name: "Synthetic SSH", kind: .ssh, host: "host.example.invalid", username: "synthetic-user")
    }
    func testPrivateControlDirectoriesAreUnpredictableAndValidateTheirInode() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("NethrivaSecurity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let first = try SSHControlDirectory(parent: parent), second = try SSHControlDirectory(parent: parent)
        XCTAssertNotEqual(first.url, second.url)
        try first.validate(); try second.validate()
        let attributes = try FileManager.default.attributesOfItem(atPath: first.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let displaced = first.url.appendingPathExtension("displaced")
        try FileManager.default.moveItem(at: first.url, to: displaced)
        try FileManager.default.createSymbolicLink(at: first.url, withDestinationURL: second.url)
        XCTAssertThrowsError(try first.validate())
        first.removeIfEmpty()
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path))
        try second.validate()
    }
    func testPrivateDirectoryPermissionsFailClosedWithoutChangingOtherDirectory() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("NethrivaSecurity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = try SSHControlDirectory(parent: parent)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.url.path)
        XCTAssertThrowsError(try directory.validate())
        directory.removeIfEmpty()
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.url.path))
    }
    func testReuseDistinguishesCredentialKeyAuthenticationAndForwardingContexts() throws {
        let baseline = connection(), original = SSHConnectionReuse.controlKey(for: baseline)
        var variants: [RemoteConnection] = []
        var modified = baseline; modified.sshAuthentication = .password; variants.append(modified)
        modified = baseline; modified.sshIdentityFile = "/private/tmp/synthetic-key"; variants.append(modified)
        modified = baseline; modified.credentialProfileID = UUID(); variants.append(modified)
        modified = baseline; modified.sshForwardAgent = true; variants.append(modified)
        modified = baseline; modified.sshJumpHost = "jump.example.invalid"; variants.append(modified)
        modified = baseline; modified.username = "other-user"; variants.append(modified)
        for value in variants {
            XCTAssertNotEqual(SSHConnectionReuse.controlKey(for: value), original)
            XCTAssertNotEqual(try SSHConnectionReuse.controlPath(for: value), try SSHConnectionReuse.controlPath(for: baseline))
        }
        let resolved = try SSHConnectionReuse.controlPath(for: baseline).replacingOccurrences(of: "%C", with: String(repeating: "a", count: 40))
        XCTAssertLessThan(resolved.utf8.count, 104)
        XCTAssertTrue(SSHConnectionReuse.ownsControlSocket(resolved))
        XCTAssertFalse(SSHConnectionReuse.ownsControlSocket("/private/tmp/foreign.s"))
        let unregistered = URL(fileURLWithPath: resolved).deletingLastPathComponent()
            .appendingPathComponent("0000000000000000-" + String(repeating: "a", count: 40) + ".s").path
        XCTAssertFalse(SSHConnectionReuse.ownsControlSocket(unregistered))
    }
    func testExpandedMuxTemporarySocketFitsAndBinds() throws {
        let pattern = try SSHConnectionReuse.controlPath(for: connection())
        // Resolve tokens with the actual OpenSSH binary, without user config,
        // DNS, authentication, a remote connection or any remote command.
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G", "-F", "none", "-o", "ControlPath=\(pattern)", "--", "synthetic-user@host.example.invalid"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let configuration = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let line = try XCTUnwrap(String(decoding: configuration, as: UTF8.self).split(separator: "\n")
            .first { $0.hasPrefix("controlpath ") })
        let final = String(line.dropFirst("controlpath ".count))
        XCTAssertFalse(final.contains("%C"))
        XCTAssertTrue(SSHConnectionReuse.ownsControlSocket(final))
        // OpenSSH first binds <ControlPath>.<16 random characters>, then links
        // it into place. Checking only the final pathname misses this limit.
        let temporary = final + "." + String(repeating: "x", count: 16)
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard temporary.utf8.count < capacity else {
            XCTFail("Expanded temporary mux path uses \(temporary.utf8.count) bytes; macOS capacity including NUL is \(capacity)")
            return
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd); unlink(temporary) }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(temporary.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            bytes.withUnsafeBytes { target.copyBytes(from: $0) }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(result, 0, "Actual macOS temporary mux socket bind failed: \(errno)")
        XCTAssertEqual(Darwin.listen(fd, 1), 0)
    }

    func testSSHArgumentsRejectOptionJumpAndControlInjectionEverywhere() throws {
        for hostile in ["-oProxyCommand=bad", "host\nname", "host\0name", "user@host", "host/path"] {
            var value = connection(); value.host = hostile
            XCTAssertThrowsError(try SSHInputValidation.validate(value))
            XCTAssertThrowsError(try SFTPChannel.arguments(for: value))
            XCTAssertThrowsError(try SFTPAuthenticationBootstrap.sshArguments(for: value))
            XCTAssertThrowsError(try VMSSHCommand.arguments(for: value))
        }
        var value = connection(); value.sshJumpHost = "jump.example.invalid,-oProxyCommand=bad"
        XCTAssertThrowsError(try SFTPChannel.arguments(for: value))
        value = connection(); value.sshIdentityFile = "/private/tmp/key\nextra"
        XCTAssertThrowsError(try SFTPAuthenticationBootstrap.sshArguments(for: value))
        let arguments = try SFTPAuthenticationBootstrap.sshArguments(for: connection())
        XCTAssertEqual(Array(arguments.suffix(2)), ["--", "synthetic-user@host.example.invalid"])
        XCTAssertTrue(arguments.contains("ForwardAgent=no"))
        XCTAssertTrue(arguments.contains("PermitLocalCommand=no"))
    }
    func testChangedKeyFileCreatesFreshSocketContextWithoutLosingOldShutdownRegistration() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NethrivaSyntheticIdentity-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("first-synthetic-identity".utf8).write(to: url)
        var value = connection(); value.sshIdentityFile = url.path
        let stable = SSHConnectionReuse.controlKey(for: value)
        let original = try SSHConnectionReuse.controlPath(for: value)
        try Data("changed-synthetic-identity".utf8).write(to: url, options: .atomic)
        XCTAssertEqual(SSHConnectionReuse.controlKey(for: value), stable)
        let updated = try SSHConnectionReuse.controlPath(for: value)
        XCTAssertNotEqual(original, updated)
        XCTAssertTrue(SSHConnectionReuse.registeredControlPaths(for: value).contains(original))
        XCTAssertTrue(SSHConnectionReuse.registeredControlPaths(for: value).contains(updated))
    }
    @MainActor func testOSC52CannotReadOrModifyClipboardThroughRealLocalTerminalDelegate() {
        let terminal = PasteableLocalProcessTerminalView(frame: .zero)
        XCTAssertTrue(terminal.terminalDelegate is TerminalDelegateFirewall)
        XCTAssertNil(terminal.terminalDelegate?.clipboardRead(source: terminal))
        let probe = SecurityTerminalDelegateProbe()
        let firewall = TerminalDelegateFirewall(forwarding: probe)
        let raw = TerminalView(frame: .zero)
        raw.terminalDelegate = firewall
        let sequences = ["\u{1b}]52;c;?\u{7}", "\u{1b}]52;c;U1lOVEhFVElD\u{7}", "\u{1b}]52;c;?\u{1b}\\"]
        for sequence in sequences { raw.feed(byteArray: Array(sequence.utf8)[...]) }
        XCTAssertEqual(probe.clipboardReads, 0)
        XCTAssertEqual(probe.clipboardWrites, 0)
        XCTAssertTrue(probe.sent.isEmpty)
        // The firewall still forwards actual user input to the intended terminal.
        raw.send(txt: "synthetic-user-input")
        XCTAssertEqual(String(decoding: probe.sent, as: UTF8.self), "synthetic-user-input")
    }
    @MainActor func testHostilePasswordPromptDoesNotTransmitSavedCredential() async throws {
        let gate = CredentialAccessGate(), controller = OpenSSHInputController(credentialGate: gate)
        let view = SecurityPasswordTerminalProbe(frame: .zero)
        controller.attach(to: view); controller.setSavedPassword("SYNTHETIC-ONLY")
        controller.sendSavedPassword()
        XCTAssertTrue(view.sent.isEmpty)
        view.dataReceived(slice: Array("Untrusted output password:".utf8)[...])
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(controller.isAwaitingPassword)
        XCTAssertTrue(view.sent.isEmpty)
        gate.setLocked(true); controller.sendSavedPassword()
        XCTAssertTrue(view.sent.isEmpty)
        gate.setLocked(false); controller.sendSavedPassword()
        XCTAssertEqual(String(decoding: view.sent, as: UTF8.self), "SYNTHETIC-ONLY\r")
        view.sent.removeAll(); controller.setSavedPassword("bad\rcommand")
        view.dataReceived(slice: Array("password:".utf8)[...])
        try await Task.sleep(for: .milliseconds(20))
        controller.sendSavedPassword(); XCTAssertTrue(view.sent.isEmpty)
        controller.disconnect(); XCTAssertFalse(controller.hasSavedPassword)
    }
    func testPasteReviewRejectsOversizeAndPreservesOnlyApprovedText() {
        XCTAssertEqual(TerminalInputSecurity.pasteDecision("ordinary text"), .allow)
        for value in ["line1\nline2", "command\r", "\u{1b}[201~command", "indent\ttext"] {
            XCTAssertEqual(TerminalInputSecurity.pasteDecision(value), .confirm)
            XCTAssertNil(TerminalInputSecurity.approvedPaste(value, confirm: { false }))
            XCTAssertEqual(TerminalInputSecurity.approvedPaste(value, confirm: { true }), value)
        }
        for value in ["nul\0input", String(repeating: "x", count: TerminalInputSecurity.maximumPasteBytes + 1)] {
            XCTAssertEqual(TerminalInputSecurity.pasteDecision(value), .reject)
            XCTAssertNil(TerminalInputSecurity.approvedPaste(value, confirm: { XCTFail("Rejected paste must never reach consent"); return true }))
        }
    }
    func testAutomaticSSHCredentialGuardRejectsSpoofedEchoOnPromptAndSupportsEchoOffAuth() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NethrivaPrompt-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("synthetic-prompt.sh")
        try """
        #!/bin/sh
        if [ "$NETHRIVA_TEST_ECHO" = off ]; then /bin/stty -echo; fi
        printf 'password:'
        IFS= read -r value
        printf '%s' "$value" > "$NETHRIVA_TEST_CAPTURE"
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let script = """
        set timeout 2
        log_user 0
        set password [read stdin]
        spawn -noecho $env(NETHRIVA_TEST_EXECUTABLE)
        """ + "\n" + SSHCredentialPromptGuard.expectScript + "\n" + #"""
        expect {
            -re {password:} {
                if {![nethriva_credential_prompt]} { close; catch wait; exit 24 }
                send -- "$password\r"
                expect eof
                catch wait result
                exit [lindex $result 3]
            }
            timeout { close; catch wait; exit 25 }
        }
        """#
        for mode in ["on", "off"] {
            let capture = root.appendingPathComponent(mode + ".txt")
            let process = Process(), input = Pipe(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/expect")
            process.arguments = ["-c", script]
            process.standardInput = input; process.standardOutput = output; process.standardError = output
            process.environment = ["PATH": "/usr/bin:/bin", "NETHRIVA_TEST_ECHO": mode,
                "NETHRIVA_TEST_CAPTURE": capture.path, "NETHRIVA_TEST_EXECUTABLE": executable.path]
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: Data("SYNTHETIC-ONLY".utf8))
            try input.fileHandleForWriting.close()
            let data = try output.fileHandleForReading.readToEnd() ?? Data()
            process.waitUntilExit()
            XCTAssertTrue(data.isEmpty, "Private helper must not echo secrets or remote output")
            XCTAssertEqual(process.terminationStatus, mode == "off" ? 0 : 24)
            if mode == "off" { XCTAssertEqual(try Data(contentsOf: capture), Data("SYNTHETIC-ONLY".utf8)) }
            else { XCTAssertFalse(FileManager.default.fileExists(atPath: capture.path)) }
        }
        XCTAssertThrowsError(try SSHCredentialPromptGuard.validate("synthetic\rcommand"))
        XCTAssertThrowsError(try SSHCredentialPromptGuard.validate(String(repeating: "x", count: 65537)))
    }
    func testStreamingEscapeLimiterPreservesChunkedSequencesAndUnicode() {
        let value = "ordinary Ü雪\u{1b}[31mred\u{1b}[0m\u{1b}]0;title Ü\u{7}\u{1b}Pqgraphic\u{1b}\\tail"
        let bytes = Array(value.utf8)
        for chunk in [1, 2, 3, 7, 16, bytes.count] {
            var filter = TerminalEscapeLimiter(), output: [UInt8] = []
            for start in stride(from: 0, to: bytes.count, by: chunk) { output += filter.filter(bytes[start..<min(start + chunk, bytes.count)]) }
            XCTAssertEqual(output, bytes); XCTAssertEqual(filter.bufferedByteCount, 0)
            XCTAssertEqual(filter.discardedSequences, 0)
        }
    }
    func testStreamingEscapeLimiterBoundsAndDiscardsUnterminatedOSC_DCS_CSI() {
        for opening in [Array("\u{1b}]".utf8), Array("\u{1b}P".utf8), [UInt8(0x9d)], [UInt8(0x90)], Array("\u{1b}[".utf8)] {
            var filter = TerminalEscapeLimiter(controlLimit: 64, csiLimit: 32)
            var output = filter.filter(opening[...])
            for _ in 0..<1000 {
                output += filter.filter(Array(repeating: UInt8(ascii: "1"), count: 50)[...])
                XCTAssertLessThanOrEqual(filter.bufferedByteCount, 64)
            }
            XCTAssertTrue(output.isEmpty); XCTAssertEqual(filter.discardedSequences, 1)
            let ending = opening.last == UInt8(ascii: "[") ? "mVISIBLE" : "\u{1b}\\VISIBLE"
            XCTAssertEqual(String(decoding: filter.filter(Array(ending.utf8)[...]), as: UTF8.self), "VISIBLE")
            XCTAssertEqual(filter.bufferedByteCount, 0)
        }
    }
    func testRemoteLinksCannotSilentlyOpenLocalOrApplicationSchemes() {
        for link in ["https://docs.example.invalid/help", "http://docs.example.invalid/", "mailto:help@example.invalid"] { XCTAssertEqual(TerminalLinkSecurity.decision(link), .web) }
        for link in ["file:///private/tmp/synthetic.command", "ssh://synthetic@host.example.invalid", "custom-action://run"] { XCTAssertEqual(TerminalLinkSecurity.decision(link), .confirmation) }
        for link in ["javascript:alert(1)", "data:text/plain,synthetic", "https://user:password@example.invalid", "https://example.invalid/\npath"] { XCTAssertEqual(TerminalLinkSecurity.decision(link), .blocked) }
    }
    func testSixelIngressRejectsOverflowDimensionsAndExcessiveExpansionBeforeDependency() {
        let safe = "\u{1b}P0;0;0q#0;2;100;0;0!4~$#1;2;0;100;0!4@-\u{1b}\\"
        XCTAssertTrue(TerminalSixelSafety.allowsDCS(Array(safe.utf8)))
        var normal = TerminalEscapeLimiter()
        XCTAssertEqual(normal.filter(Array(safe.utf8)[...]), Array(safe.utf8))
        let payloads = [
            "#0;2;100;0;0!999999999999999999999999999999999999~",
            "#999999999999999999999999999999;2;0;0;0~",
            "#0;2;100;0;0!4097~",
            "#0;2;100;0;0" + String(repeating: "!4096~$", count: 1025),
            "#0;2;100;0;0" + String(repeating: "-", count: 684) + "~",
            "#0;2;100;0;0" + String(repeating: "!4096~-", count: 172),
        ]
        for payload in payloads {
            let sequence = Array(("\u{1b}Pq" + payload + "\u{1b}\\").utf8)
            XCTAssertFalse(TerminalSixelSafety.allowsDCS(sequence))
            var filter = TerminalEscapeLimiter()
            XCTAssertEqual(String(decoding: filter.filter((sequence + Array("SAFE".utf8))[...]), as: UTF8.self), "SAFE")
            XCTAssertEqual(filter.discardedSequences, 1)
        }
        XCTAssertTrue(TerminalSixelSafety.allowsDCS(Array("\u{1b}P$qm\u{1b}\\".utf8)), "Non-image DCS status queries remain supported")
    }
    func testSerialOnlyAcceptsActualCharacterTerminalDescriptors() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NethrivaSerial-" + UUID().uuidString)
        let descriptor = Darwin.open(url.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor); try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(SerialPortService.isTerminalDevice(descriptor))
        var master: Int32 = -1, slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else { throw XCTSkip("Synthetic PTY unavailable") }
        defer { Darwin.close(master); Darwin.close(slave) }
        XCTAssertTrue(SerialPortService.isTerminalDevice(slave))
    }
    func testSFTPUploadSourcesRejectLinksAndStayAnchoredAcrossDirectorySwap() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NethrivaSFTP-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("selected"), outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try Data("selected-content".utf8).write(to: selected.appendingPathComponent("data"))
        try Data("outside-content".utf8).write(to: outside.appendingPathComponent("data"))
        let source = try SFTPLocalSource(url: selected)
        let displaced = root.appendingPathComponent("displaced")
        try FileManager.default.moveItem(at: selected, to: displaced)
        try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: outside)
        let child = try source.child("data")
        let copy = dup(child.descriptor)
        let handle = FileHandle(fileDescriptor: copy, closeOnDealloc: true)
        defer { try? handle.close() }
        XCTAssertEqual(try String(data: handle.readToEnd() ?? Data(), encoding: .utf8), "selected-content")
        XCTAssertThrowsError(try SFTPLocalSource(url: selected))
        let hard = root.appendingPathComponent("hard")
        try FileManager.default.linkItem(at: outside.appendingPathComponent("data"), to: hard)
        XCTAssertThrowsError(try SFTPLocalSource(url: hard))
        let fifo = root.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try SFTPLocalSource(url: fifo))
    }
    func testSFTPDownloadPublicationDoesNotFollowSymlinksOrOverwriteOutsideHardlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NethrivaSFTP-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("selected"), outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let sentinel = outside.appendingPathComponent("sentinel")
        try Data("outside-unchanged".utf8).write(to: sentinel)
        let directory = try SFTPLocalDirectory(url: selected)
        try FileManager.default.createSymbolicLink(at: selected.appendingPathComponent("link"), withDestinationURL: outside)
        XCTAssertThrowsError(try directory.directory("link"))
        let (name, file) = try directory.temporaryFile()
        try file.write(contentsOf: Data("download".utf8)); try file.close()
        try FileManager.default.linkItem(at: sentinel, to: selected.appendingPathComponent("target"))
        XCTAssertThrowsError(try directory.publish(name, to: "target", overwrite: false))
        try directory.publish(name, to: "target", overwrite: true)
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "outside-unchanged")
        XCTAssertEqual(try String(contentsOf: selected.appendingPathComponent("target"), encoding: .utf8), "download")
        let displaced = root.appendingPathComponent("displaced")
        try FileManager.default.moveItem(at: selected, to: displaced)
        try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: outside)
        let (second, secondFile) = try directory.temporaryFile()
        try secondFile.write(contentsOf: Data("held-directory".utf8)); try secondFile.close()
        try directory.publish(second, to: "new", overwrite: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("new").path))
        XCTAssertEqual(try String(contentsOf: displaced.appendingPathComponent("new"), encoding: .utf8), "held-directory")
    }
    func testBoundedMalformedSFTPReaderCorpusDoesNotOverreadOrAllocateDeclaredLengths() {
        var random: UInt64 = 0x4e45544852495641
        for index in 0..<2000 {
            var data = Data()
            for _ in 0..<(index % 128) { random = random &* 6364136223846793005 &+ 1; data.append(UInt8(truncatingIfNeeded: random >> 32)) }
            var reader = SFTPReader(data: data)
            do { _ = try reader.uint32(); _ = try reader.string(); _ = try SFTPAttributes.decode(&reader) } catch {}
            XCTAssertGreaterThanOrEqual(reader.remaining, 0)
            XCTAssertLessThanOrEqual(reader.offset, data.count)
        }
        var reader = SFTPReader(data: Data([255, 255, 255, 255]))
        XCTAssertThrowsError(try reader.string())
    }
    func testSFTPMetadataBudgetBoundsCanonicalPathAmplificationAndAggregatePages() throws {
        func page(_ names: [String]) -> Data {
            var bytes = SFTPBytes(); bytes.uint32(UInt32(names.count))
            for name in names { bytes.string(name); bytes.string(""); bytes.uint32(4); bytes.uint32(0o100600) }
            return bytes.data
        }
        var budget = SFTPMetadataBudget(maximumBytes: 512)
        let parent = String(repeating: "p", count: 100)
        let first = try SFTPChannel.names(page(["a"]), parent: parent, budget: &budget)
        XCTAssertEqual(first.first?.path, parent + "/a")
        _ = try SFTPChannel.names(page(["b"]), parent: parent, budget: &budget)
        XCTAssertThrowsError(try SFTPChannel.names(page(["c"]), parent: parent, budget: &budget))
        var counts = SFTPMetadataBudget(maximumBytes: 1024, maximumEntries: 1)
        _ = try SFTPChannel.names(page(["one"]), parent: "/", budget: &counts)
        XCTAssertThrowsError(try SFTPChannel.names(page(["two"]), parent: "/", budget: &counts))
        var canonical = SFTPMetadataBudget()
        XCTAssertThrowsError(try SFTPChannel.names(page(["/one", "/two"]), parent: "", canonical: true, budget: &canonical))
        var transfer = SFTPMetadataBudget(maximumBytes: 300, maximumEntries: 10)
        try transfer.reserve(nameBytes: 20, pathBytes: 80)
        XCTAssertThrowsError(try transfer.reserve(nameBytes: 20, pathBytes: 80))
        XCTAssertThrowsError(try transfer.reserve(nameBytes: -1, pathBytes: 0))
    }
}

private final class SecurityPasswordTerminalProbe: PasswordObservingTerminalView {
    var sent: [UInt8] = []
    override func send(source: TerminalView, data: ArraySlice<UInt8>) { sent += data }
}
private final class SecurityTerminalDelegateProbe: TerminalViewDelegate {
    var clipboardReads = 0, clipboardWrites = 0, sent: [UInt8] = []
    func clipboardRead(source: TerminalView) -> Data? { clipboardReads += 1; return Data("SYNTHETIC-CLIPBOARD".utf8) }
    func clipboardCopy(source: TerminalView, content: Data) { clipboardWrites += 1 }
    func send(source: TerminalView, data: ArraySlice<UInt8>) { sent += data }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

@MainActor private final class SecurityPTYLifecycleProbe: ManagedProcessTerminalViewDelegate {
    let ended: () -> Void
    init(ended: @escaping () -> Void) { self.ended = ended }
    func sizeChanged(source: ManagedProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: ManagedProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) { ended() }
}
