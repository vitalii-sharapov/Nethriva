import XCTest
@testable import Nethriva

final class NethrivaTests: XCTestCase {
    func testBundledHelpCoversCoreWorkflows() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let helpURL = projectRoot
            .appendingPathComponent("Nethriva/Resources/Help/NethrivaHelp.html")
        let help = try String(contentsOf: helpURL, encoding: .utf8)

        for requiredTopic in [
            "Quick start",
            "Local Terminal",
            "SSH sessions",
            "Remote files beside SSH",
            "SFTP browser",
            "Embedded RDP",
            "Security and privacy",
            "Troubleshooting",
            "Current limitations",
        ] {
            XCTAssertTrue(help.contains(requiredTopic), "Missing help topic: \(requiredTopic)")
        }
    }

    func testConnectionUsesProtocolDefaultPort() {
        let ssh = RemoteConnection(name: "Server", kind: .ssh)
        let rdp = RemoteConnection(name: "Desktop", kind: .rdp)

        XCTAssertEqual(ssh.port, 22)
        XCTAssertEqual(rdp.port, 3389)
    }

    func testLegacyConnectionDataStillDecodes() throws {
        let json = Data("""
        {
          "id": "F3042600-C9F8-402A-BF7E-B344375EB68B",
          "name": "Legacy Server",
          "kind": "ssh",
          "host": "example.com",
          "port": 22,
          "username": "testuser",
          "group": "Ungrouped",
          "isFavorite": false,
          "createdAt": 0
        }
        """.utf8)

        let connection = try JSONDecoder().decode(RemoteConnection.self, from: json)

        XCTAssertEqual(connection.effectiveSSHAuthentication, .automatic)
        XCTAssertEqual(connection.effectiveSSHKeepAliveInterval, 30)
    }

    func testAdvancedSSHOptionsRoundTrip() throws {
        let original = RemoteConnection(
            name: "Production",
            kind: .ssh,
            host: "internal.example.com",
            sshAuthentication: .publicKey,
            sshIdentityFile: "/tmp/test-key",
            sshJumpHost: "jumpuser@bastion.example.com",
            sshForwardAgent: true,
            sshCompression: true,
            sshKeepAliveInterval: 45
        )

        let decoded = try JSONDecoder().decode(
            RemoteConnection.self,
            from: JSONEncoder().encode(original)
        )

        XCTAssertEqual(decoded, original)
    }

    func testLegacyRDPConnectionUsesSafeModernDefaults() throws {
        let json = Data("""
        {
          "id": "3D9BBCC9-665F-456D-95B6-2CA9B4094349",
          "name": "Legacy Desktop",
          "kind": "rdp",
          "host": "desktop.example.com",
          "port": 3389,
          "username": "testuser",
          "group": "Windows",
          "isFavorite": false,
          "createdAt": 0
        }
        """.utf8)

        let connection = try JSONDecoder().decode(RemoteConnection.self, from: json)

        XCTAssertEqual(connection.effectiveRDPDisplayMode, .dynamicWindow)
        XCTAssertEqual(connection.effectiveRDPWidth, 1600)
        XCTAssertEqual(connection.effectiveRDPHeight, 1000)
        XCTAssertEqual(connection.effectiveRDPScale, 100)
        XCTAssertTrue(connection.effectiveRDPClipboard)
        XCTAssertEqual(connection.effectiveRDPAudioMode, .local)
        XCTAssertEqual(connection.effectiveRDPCertificatePolicy, .trustOnFirstUse)
        XCTAssertTrue(connection.effectiveRDPAutoReconnect)
    }

    func testModernRDPArgumentsAndPasswordRedaction() throws {
        let connection = RemoteConnection(
            name: "Design Workstation",
            kind: .rdp,
            host: "rdp.example.com",
            username: "testuser",
            rdpDomain: "EXAMPLE",
            rdpGatewayHost: "gateway.example.com",
            rdpGatewayUsername: "gateway-user",
            rdpDisplayMode: .multiMonitor,
            rdpScale: 140,
            rdpClipboard: true,
            rdpAudioMode: .local,
            rdpMicrophone: true,
            rdpRedirectHome: true,
            rdpSharedFolder: "/Users/test/Share",
            rdpPrinters: true,
            rdpSmartCards: true,
            rdpUSBDevices: true,
            rdpNetworkProfile: .lan,
            rdpGraphicsAcceleration: true,
            rdpCertificatePolicy: .trustOnFirstUse,
            rdpAdminSession: true,
            rdpAutoReconnect: true,
            rdpReconnectRetries: 25
        )

        let arguments = try FreeRDPArgumentsBuilder.arguments(for: connection, password: "not-for-logs")

        XCTAssertTrue(arguments.contains("/v:rdp.example.com:3389"))
        XCTAssertTrue(arguments.contains("/multimon:force"))
        XCTAssertTrue(arguments.contains("/gfx:AVC444:on"))
        XCTAssertTrue(arguments.contains("+home-drive"))
        XCTAssertTrue(arguments.contains("/drive:Nethriva,/Users/test/Share"))
        XCTAssertTrue(arguments.contains("/cert:tofu"))
        XCTAssertTrue(arguments.contains("/auto-reconnect-max-retries:25"))
        XCTAssertTrue(arguments.contains("/gateway:g:gateway.example.com,u:gateway-user,usage-method:direct"))

        let redacted = FreeRDPArgumentsBuilder.redacted(arguments)
        XCTAssertFalse(redacted.joined().contains("not-for-logs"))
        XCTAssertTrue(redacted.contains("/p:••••••••"))
    }

    func testResizableRDPUsesOnlyDynamicResolution() throws {
        let connection = RemoteConnection(
            name: "Resizable Desktop",
            kind: .rdp,
            host: "desktop.example.com",
            rdpDisplayMode: .dynamicWindow
        )

        let arguments = try FreeRDPArgumentsBuilder.arguments(for: connection, password: nil)

        XCTAssertTrue(arguments.contains("+dynamic-resolution"))
        XCTAssertFalse(arguments.contains("/smart-sizing"))
    }

    func testEmbeddedRDPUsesTabViewportInsteadOfExternalWindowMode() throws {
        let connection = RemoteConnection(
            name: "Embedded Desktop",
            kind: .rdp,
            host: "desktop.example.com",
            rdpDisplayMode: .fullscreen
        )

        let arguments = try FreeRDPArgumentsBuilder.arguments(
            for: connection,
            password: nil,
            surface: .embedded(width: 1873, height: 1091)
        )

        XCTAssertTrue(arguments.contains("/size:1872x1090"))
        XCTAssertTrue(arguments.contains("+dynamic-resolution"))
        XCTAssertFalse(arguments.contains("/f"))
        XCTAssertFalse(arguments.contains("/multimon:force"))
    }

    func testEmbeddedRDPUsesLogicalTabSizeInsteadOfRetinaPixelSize() {
        let desktop = RDPViewportSizing.desktopSize(for: CGSize(width: 1728, height: 1084))

        XCTAssertEqual(desktop, CGSize(width: 1728, height: 1084))
        XCTAssertNotEqual(desktop, CGSize(width: 3456, height: 2168))
    }

    func testEmbeddedRDPCanOverrideDisplayScalePerSession() throws {
        let connection = RemoteConnection(
            name: "Readable Desktop",
            kind: .rdp,
            host: "desktop.example.com",
            rdpScale: 100
        )

        let arguments = try FreeRDPArgumentsBuilder.arguments(
            for: connection,
            password: nil,
            surface: .embedded(width: 1200, height: 800),
            displayScale: 140
        )

        XCTAssertTrue(arguments.contains("/scale:140"))
        XCTAssertFalse(arguments.contains("/scale:100"))
    }

    func testEmbeddedRDPEnablesClipboardWithoutAnAutomaticLocalDrive() throws {
        let connection = RemoteConnection(
            name: "Files Desktop",
            kind: .rdp,
            host: "desktop.example.com"
        )

        let arguments = try FreeRDPArgumentsBuilder.arguments(
            for: connection,
            password: nil,
            surface: .embedded(width: 1200, height: 800)
        )

        XCTAssertTrue(arguments.contains("+clipboard"))
        XCTAssertFalse(arguments.contains { $0.hasPrefix("/drive:NethrivaDrop,") })
    }

    func testWindowsStyleUsernameIsSeparatedIntoDomainAndAccount() throws {
        let connection = RemoteConnection(
            name: "Domain Controller",
            kind: .rdp,
            host: "rdp-host.example.invalid",
            username: "EXAMPLE\\testuser"
        )

        let arguments = try FreeRDPArgumentsBuilder.arguments(for: connection, password: nil)

        XCTAssertTrue(arguments.contains("/u:testuser"))
        XCTAssertTrue(arguments.contains("/d:EXAMPLE"))
        XCTAssertFalse(arguments.contains("/u:EXAMPLE\\testuser"))
    }

    func testBundledFreeRDPReceivesOpenSSLProviderLocation() {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let executable = projectRoot
            .appendingPathComponent("Nethriva/Resources/FreeRDP/MacOS/sdl-freerdp")
        let expectedModules = projectRoot
            .appendingPathComponent("Nethriva/Resources/FreeRDP/Frameworks/ossl-modules")

        let environment = FreeRDPService.processEnvironment(for: executable)

        XCTAssertEqual(environment["OPENSSL_MODULES"], expectedModules.path)
    }

    func testSFTPCommandsUseRecursiveFolderTransfers() {
        let localFolder = URL(fileURLWithPath: "/tmp/Project Files", isDirectory: true)
        let remoteFolder = SFTPFileItem(
            name: "Logs",
            path: "/srv/Logs",
            isDirectory: true,
            isSymbolicLink: false,
            size: 0,
            permissions: "drwxr-xr-x",
            modifiedText: "Sep 14 12:00"
        )

        XCTAssertEqual(
            SFTPCommandBuilder.upload(localURL: localFolder, to: "/srv", isDirectory: true),
            "put -pR \"/tmp/Project Files\" \"/srv/Project Files\""
        )
        XCTAssertEqual(
            SFTPCommandBuilder.download(item: remoteFolder, to: URL(fileURLWithPath: "/tmp/Logs")),
            "get -pR \"/srv/Logs\" \"/tmp/Logs\""
        )
        XCTAssertEqual(
            SFTPCommandBuilder.move(remotePath: "/srv/Logs", to: "/archive"),
            "rename \"/srv/Logs\" \"/archive/Logs\""
        )
    }

    func testSFTPArgumentsArePassedThroughExpectEnvironment() {
        let environment = SFTPService.expectEnvironment(
            base: [:],
            sftpArguments: ["-P", "2222", "testuser@example.com"],
            commands: ["pwd", "ls -la"],
            password: "unit-test-placeholder",
            executablePath: "/tmp/mock-sftp"
        )

        XCTAssertEqual(environment["NETHRIVA_SFTP_ARG_COUNT"], "3")
        XCTAssertEqual(environment["NETHRIVA_SFTP_ARG_0"], "-P")
        XCTAssertEqual(environment["NETHRIVA_SFTP_ARG_1"], "2222")
        XCTAssertEqual(environment["NETHRIVA_SFTP_ARG_2"], "testuser@example.com")
        XCTAssertEqual(environment["NETHRIVA_SFTP_COMMANDS"], "pwd\nls -la")
        XCTAssertEqual(environment["NETHRIVA_SFTP_PASSWORD"], "secret")
        XCTAssertEqual(environment["NETHRIVA_SFTP_EXECUTABLE"], "/tmp/mock-sftp")
    }

    func testSSHConnectionReuseUsesHashedOpenSSHControlSocket() {
        let arguments = SSHConnectionReuse.arguments

        XCTAssertTrue(arguments.contains("ControlMaster=auto"))
        XCTAssertTrue(arguments.contains("ControlPersist=600"))
        XCTAssertTrue(arguments.contains { $0.hasPrefix("ControlPath=/private/tmp/Nethriva-") })
        XCTAssertTrue(arguments.contains { $0.hasSuffix("/%C.socket") })
    }

    func testSFTPListingParsesCRLFOutput() {
        let output = """
        sftp> pwd\r
        Remote working directory: /home/testuser\r
        sftp> ls -lan\r
        drwxr-xr-x 3 1000 1000 4096 Sep 15 00:00 Documents\r
        -rw-r--r-- 1 1000 1000 128 Sep 15 00:01 notes.txt\r
        """
        let service = SFTPService()

        XCTAssertEqual(service.parseWorkingDirectory(from: output), "/home/testuser")
        let items = service.parseListing(output, parentPath: "/home/testuser")
        XCTAssertEqual(items.map(\.name), ["Documents", "notes.txt"])
        XCTAssertEqual(items.first?.path, "/home/testuser/Documents")
        XCTAssertTrue(items.first?.isDirectory == true)
    }

    func testSFTPTabHasDistinctIdentityAndTitle() {
        let connection = RemoteConnection(name: "Web Server", kind: .ssh, host: "example.com")
        let terminal = SessionTab(connection: connection)
        let files = SessionTab(connection: connection, tool: .sftp)

        XCTAssertEqual(terminal.title, "Web Server")
        XCTAssertEqual(files.title, "Web Server · SFTP")
        XCTAssertNotEqual(terminal.id, files.id)
    }

    @MainActor
    func testOpeningConnectionCreatesAndSelectsTab() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = UserDefaultsConnectionStore(defaults: defaults, storageKey: "test")
        let groupStore = UserDefaultsConnectionGroupStore(defaults: defaults, storageKey: "groups")
        let state = AppState(store: store, groupStore: groupStore, credentialVault: TestCredentialVault())

        state.open(.localShell)

        XCTAssertEqual(state.tabs.count, 1)
        XCTAssertEqual(state.selectedTabID, state.tabs.first?.id)
    }

    @MainActor
    func testFailedCredentialSaveDoesNotAddConnection() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = UserDefaultsConnectionStore(defaults: defaults, storageKey: "test")
        let groupStore = UserDefaultsConnectionGroupStore(defaults: defaults, storageKey: "groups")
        let state = AppState(store: store, groupStore: groupStore, credentialVault: FailingCredentialVault())
        let connection = RemoteConnection(name: "Server", kind: .ssh, host: "example.com")

        XCTAssertThrowsError(try state.add(connection, password: "unit-test-placeholder"))
        XCTAssertFalse(state.connections.contains { $0.id == connection.id })
    }

    @MainActor
    func testEmptyGroupIsPersisted() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = UserDefaultsConnectionStore(defaults: defaults, storageKey: "connections")
        let groupStore = UserDefaultsConnectionGroupStore(defaults: defaults, storageKey: "groups")
        let state = AppState(store: store, groupStore: groupStore, credentialVault: TestCredentialVault())

        XCTAssertTrue(state.addGroup("Production"))

        let reloadedState = AppState(store: store, groupStore: groupStore, credentialVault: TestCredentialVault())
        XCTAssertTrue(reloadedState.groups.contains("Production"))
    }

    @MainActor
    func testEditingConnectionKeepsItsIdentity() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = UserDefaultsConnectionStore(defaults: defaults, storageKey: "connections")
        let groupStore = UserDefaultsConnectionGroupStore(defaults: defaults, storageKey: "groups")
        let state = AppState(store: store, groupStore: groupStore, credentialVault: TestCredentialVault())
        var connection = RemoteConnection(name: "Server", kind: .ssh, host: "example.com")
        try state.add(connection, password: nil)

        connection.name = "Renamed Server"
        try state.update(connection, password: nil)

        XCTAssertEqual(state.connections.first(where: { $0.id == connection.id })?.name, "Renamed Server")
    }
}

private final class TestCredentialVault: CredentialVault {
    func save(password: String, for connectionID: UUID) throws {}
    func password(for connectionID: UUID) throws -> String? { nil }
    func deletePassword(for connectionID: UUID) throws {}
}

private final class FailingCredentialVault: CredentialVault {
    enum TestError: Error { case unavailable }

    func save(password: String, for connectionID: UUID) throws { throw TestError.unavailable }
    func password(for connectionID: UUID) throws -> String? { nil }
    func deletePassword(for connectionID: UUID) throws {}
}
