import AppKit
import CoreTransferable
import XCTest
@testable import Nethriva

final class NethrivaTests: XCTestCase {
    func testAppExportsSidebarDragType() {
        let declarations = Bundle.main.infoDictionary?["UTExportedTypeDeclarations"] as? [[String: Any]]
        let sidebarType = declarations?.first {
            $0["UTTypeIdentifier"] as? String == "com.vitalii.nethriva.sidebar-items"
        }
        XCTAssertNotNil(sidebarType)
        XCTAssertTrue((sidebarType?["UTTypeConformsTo"] as? [String])?.contains("public.data") == true)
    }

    func testSidebarDragPayloadTransfersSelectedConnections() {
        let selectedIDs = [UUID(), UUID(), UUID()]
        let payload = SidebarDragPayload(connectionIDs: selectedIDs, groupPaths: [])
        let provider = payload.itemProvider
        let loaded = expectation(description: "Sidebar drag payload loads")

        _ = provider.loadTransferable(type: SidebarDragPayload.self) { result in
            switch result {
            case .success(let decoded):
                XCTAssertEqual(decoded, payload)
            case .failure(let error):
                XCTFail("Could not load sidebar drag payload: \(error)")
            }
            loaded.fulfill()
        }

        wait(for: [loaded], timeout: 5)
    }

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
            "Telnet sessions",
            "Serial sessions",
            "Credential profiles",
            "Remote files beside SSH",
            "SFTP browser",
            "Embedded RDP",
            "Import and export",
            "Security and privacy",
            "Troubleshooting",
            "Current limitations",
        ] {
            XCTAssertTrue(help.contains(requiredTopic), "Missing help topic: \(requiredTopic)")
        }
    }

    func testConnectionUsesProtocolDefaultPort() {
        let ssh = RemoteConnection(name: "Server", kind: .ssh)
        let telnet = RemoteConnection(name: "Switch", kind: .telnet)
        let rdp = RemoteConnection(name: "Desktop", kind: .rdp)
        let serial = RemoteConnection(name: "Console", kind: .serial)

        XCTAssertEqual(ssh.port, 22)
        XCTAssertEqual(telnet.port, 23)
        XCTAssertEqual(rdp.port, 3389)
        XCTAssertEqual(serial.port, 0)
    }

    func testSerialSettingsRoundTripAndValidateDevicePaths() throws {
        let original = RemoteConnection(
            name: "Fictional switch console",
            kind: .serial,
            host: "/dev/cu.usbserial-example",
            serialBaudRate: 9_600,
            serialDataBits: 7,
            serialParity: .even,
            serialStopBits: 2,
            serialFlowControl: .hardware,
            serialLocalEcho: true
        )
        let decoded = try JSONDecoder().decode(RemoteConnection.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertTrue(SerialPortConfiguration(connection: decoded).isValid)
        XCTAssertEqual(decoded.endpointDescription, "/dev/cu.usbserial-example")
        XCTAssertFalse(SerialPortDiscovery.isValidDevicePath("/dev/cu."))
        XCTAssertFalse(SerialPortDiscovery.isValidDevicePath("/dev/tty."))
        XCTAssertFalse(SerialPortDiscovery.isValidDevicePath("/dev/cu.foo/../../private"))
        XCTAssertFalse(SerialPortDiscovery.isValidDevicePath("/tmp/cu.example"))
    }

    func testSerialPortDiscoveryListsOnlyCalloutDevices() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["cu.usbserial-B", "cu.usbmodem-A", "tty.usbserial-B", "notes.txt"] {
            XCTAssertTrue(FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: Data()))
        }
        XCTAssertEqual(SerialPortDiscovery.availablePorts(in: directory.path), [
            directory.appendingPathComponent("cu.usbmodem-A").path,
            directory.appendingPathComponent("cu.usbserial-B").path,
        ])
    }

    func testSerialConnectionArchivePreservesSettingsWithoutCredentials() throws {
        let connection = RemoteConnection(
            name: "Fictional console",
            kind: .serial,
            host: "/dev/cu.usbserial-example",
            group: "Lab/Consoles",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            serialBaudRate: 9_600,
            serialFlowControl: SerialFlowControl.none
        )
        let archive = ConnectionArchive(
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            groups: ["Lab", "Lab/Consoles"],
            connections: [connection]
        )
        let data = try ConnectionTransferService.encodePlain(archive)
        guard case .plain(let decoded) = try ConnectionTransferService.inspect(data).content else {
            return XCTFail("Expected serial connection in plain archive")
        }
        XCTAssertEqual(decoded, archive)

        let invalid = ConnectionArchive(
            groups: [],
            connections: [connection],
            credentials: [.init(connectionID: connection.id, password: "unit-test-placeholder")]
        )
        XCTAssertThrowsError(try ConnectionTransferService.encodeEncrypted(invalid, password: "example-password"))
    }

    @MainActor
    func testSharedCredentialProfileResolvesAcrossConnectionsAndSurvivesExport() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }
        let vault = TestCredentialVault()
        let profileStore = UserDefaultsCredentialProfileStore(defaults: defaults, key: "profiles")
        let state = AppState(
            store: UserDefaultsConnectionStore(defaults: defaults, storageKey: "connections"),
            groupStore: UserDefaultsConnectionGroupStore(defaults: defaults, storageKey: "groups"),
            profileStore: profileStore,
            credentialVault: vault
        )
        let profile = CredentialProfile(name: "Fictional network team", username: "operator", domain: "EXAMPLE")
        try state.saveProfile(profile, password: "unit-test-placeholder")
        let ssh = RemoteConnection(
            name: "Fictional router", kind: .ssh, host: "router.example.invalid",
            credentialProfileID: profile.id
        )
        let rdp = RemoteConnection(
            name: "Fictional desktop", kind: .rdp, host: "desktop.example.invalid",
            credentialProfileID: profile.id
        )
        try state.add(ssh, password: nil)
        try state.add(rdp, password: nil)
        XCTAssertEqual(state.resolvedConnection(for: ssh).username, "operator")
        XCTAssertEqual(state.resolvedConnection(for: rdp).rdpDomain, "EXAMPLE")
        XCTAssertEqual(try state.password(for: ssh), "unit-test-placeholder")
        XCTAssertEqual(try state.password(for: rdp), "unit-test-placeholder")
        XCTAssertThrowsError(try state.deleteProfile(profile))

        let updated = CredentialProfile(id: profile.id, name: profile.name, username: "new-operator", domain: "EXAMPLE")
        try state.saveProfile(updated, password: "rotated-unit-test-placeholder")
        XCTAssertEqual(state.resolvedConnection(for: ssh).username, "new-operator")
        XCTAssertEqual(try state.password(for: rdp), "rotated-unit-test-placeholder")

        let plain = try state.makeConnectionArchive(includeCredentials: false)
        XCTAssertEqual(plain.profiles, [updated])
        XCTAssertTrue(plain.profileCredentials.isEmpty)
        let plainData = try ConnectionTransferService.encodePlain(plain)
        XCTAssertFalse(String(decoding: plainData, as: UTF8.self).contains("rotated-unit-test-placeholder"))
        let secure = try state.makeConnectionArchive(includeCredentials: true)
        XCTAssertEqual(secure.profileCredentials.count, 1)
        XCTAssertTrue(secure.credentials.isEmpty)
        let encrypted = try ConnectionTransferService.encodeEncrypted(
            secure, password: "archive-test-password", iterations: 10_000
        )
        let decoded = try ConnectionTransferService.decodeEncrypted(encrypted, password: "archive-test-password")
        XCTAssertEqual(decoded.profileCredentials.first?.password, "rotated-unit-test-placeholder")

        let restoredDefaults = UserDefaults(suiteName: #function + ".restored")!
        restoredDefaults.removePersistentDomain(forName: #function + ".restored")
        defer { restoredDefaults.removePersistentDomain(forName: #function + ".restored") }
        let restoredVault = TestCredentialVault()
        let restored = AppState(
            store: UserDefaultsConnectionStore(defaults: restoredDefaults, storageKey: "connections"),
            groupStore: UserDefaultsConnectionGroupStore(defaults: restoredDefaults, storageKey: "groups"),
            profileStore: UserDefaultsCredentialProfileStore(defaults: restoredDefaults, key: "profiles"),
            credentialVault: restoredVault
        )
        let summary = try restored.importConnectionArchive(decoded, conflictPolicy: .keepExisting)
        XCTAssertEqual(summary.profilesAdded, 1)
        XCTAssertEqual(summary.credentialsImported, 1)
        XCTAssertEqual(try restored.password(for: ssh), "rotated-unit-test-placeholder")
    }

    @MainActor
    func testRDPInteractiveSaveDoesNotChangeSharedProfile() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }
        let vault = TestCredentialVault()
        let state = AppState(
            store: UserDefaultsConnectionStore(defaults: defaults, storageKey: "connections"),
            groupStore: UserDefaultsConnectionGroupStore(defaults: defaults, storageKey: "groups"),
            credentialVault: vault
        )
        let profile = CredentialProfile(name: "Fictional domain admin", username: "shared", domain: "EXAMPLE")
        try state.saveProfile(profile, password: "shared-placeholder")
        let first = RemoteConnection(name: "First", kind: .rdp, host: "first.example.invalid", credentialProfileID: profile.id)
        let second = RemoteConnection(name: "Second", kind: .rdp, host: "second.example.invalid", credentialProfileID: profile.id)
        try state.add(first, password: nil)
        try state.add(second, password: nil)

        let saved = try state.saveRDPLogin(
            .init(username: "individual", password: "individual-placeholder", domain: "OTHER"),
            for: first.id
        )
        XCTAssertNil(saved.credentialProfileID)
        XCTAssertEqual(try state.password(for: saved), "individual-placeholder")
        XCTAssertEqual(try state.password(for: second), "shared-placeholder")
        XCTAssertEqual(state.resolvedConnection(for: second).username, "shared")
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

    func testRDPWithoutSavedUsernameCanRequestCredentialsInteractively() throws {
        let connection = RemoteConnection(
            name: "Lab Desktop",
            kind: .rdp,
            host: "rdp.example.com",
            username: ""
        )

        let arguments = try FreeRDPArgumentsBuilder.arguments(
            for: connection,
            password: nil,
            surface: .embedded(width: 1280, height: 800)
        )

        XCTAssertFalse(arguments.contains { $0.hasPrefix("/u:") })
        XCTAssertFalse(arguments.contains { $0.hasPrefix("/p:") })
        XCTAssertTrue(arguments.contains("/size:1280x800"))
    }

    @MainActor
    func testOptInRDPLoginSavesUsernameDomainAndPasswordSeparately() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = UserDefaultsConnectionStore(defaults: defaults, storageKey: "connections")
        let groups = UserDefaultsConnectionGroupStore(defaults: defaults, storageKey: "groups")
        let vault = TestCredentialVault()
        let state = AppState(store: store, groupStore: groups, credentialVault: vault)
        let connection = RemoteConnection(
            name: "Lab Desktop",
            kind: .rdp,
            host: "rdp.example.invalid"
        )
        try state.add(connection, password: nil)

        let saved = try state.saveRDPLogin(
            RDPCredentialCandidate(
                username: "operator",
                password: "unit-test-placeholder",
                domain: "LAB"
            ),
            for: connection.id
        )

        XCTAssertEqual(saved.username, "operator")
        XCTAssertEqual(saved.rdpDomain, "LAB")
        XCTAssertEqual(state.connections.first(where: { $0.id == connection.id })?.username, "operator")
        XCTAssertEqual(try vault.password(for: connection.id), "unit-test-placeholder")
        XCTAssertFalse(String(decoding: defaults.data(forKey: "connections")!, as: UTF8.self)
            .contains("unit-test-placeholder"))
    }

    @MainActor
    func testFailedRDPKeychainSaveRestoresPreviousUsername() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = UserDefaultsConnectionStore(defaults: defaults, storageKey: "connections")
        let groups = UserDefaultsConnectionGroupStore(defaults: defaults, storageKey: "groups")
        let state = AppState(store: store, groupStore: groups, credentialVault: FailingCredentialVault())
        let connection = RemoteConnection(
            name: "Lab Desktop",
            kind: .rdp,
            host: "rdp.example.invalid"
        )
        try state.add(connection, password: nil)

        XCTAssertThrowsError(try state.saveRDPLogin(
            RDPCredentialCandidate(
                username: "operator",
                password: "unit-test-placeholder",
                domain: nil
            ),
            for: connection.id
        ))
        XCTAssertEqual(state.connections.first(where: { $0.id == connection.id })?.username, "")
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
            passwordByteCount: "unit-test-placeholder".utf8.count,
            executablePath: "/tmp/mock-sftp"
        )

        XCTAssertEqual(environment["NETHRIVA_SFTP_ARG_COUNT"], "3")
        XCTAssertEqual(environment["NETHRIVA_SFTP_ARG_0"], "-P")
        XCTAssertEqual(environment["NETHRIVA_SFTP_ARG_1"], "2222")
        XCTAssertEqual(environment["NETHRIVA_SFTP_ARG_2"], "testuser@example.com")
        XCTAssertEqual(environment["NETHRIVA_SFTP_COMMAND_COUNT"], "2")
        XCTAssertEqual(environment["NETHRIVA_SFTP_COMMAND_0"], "pwd")
        XCTAssertEqual(environment["NETHRIVA_SFTP_COMMAND_1"], "ls -la")
        XCTAssertEqual(environment["NETHRIVA_SFTP_PASSWORD_LENGTH"], "21")
        XCTAssertNil(environment["NETHRIVA_SFTP_PASSWORD"])
        XCTAssertFalse(environment.values.contains("unit-test-placeholder"))
        XCTAssertEqual(environment["NETHRIVA_SFTP_EXECUTABLE"], "/tmp/mock-sftp")
    }

    func testSFTPRejectsControlCharactersInCommandStream() {
        XCTAssertNoThrow(try SFTPService.validate(commands: ["cd \"/safe path\"", "ls -lan"]))
        XCTAssertThrowsError(try SFTPService.validate(commands: ["put \"unsafe\nname\""]))
        XCTAssertThrowsError(try SFTPService.validate(commands: ["rename \"old\rname\" \"new\""]))
    }

    func testSSHConnectionReuseUsesHashedOpenSSHControlSocket() {
        let arguments = SSHConnectionReuse.arguments

        XCTAssertTrue(arguments.contains("ControlMaster=auto"))
        XCTAssertTrue(arguments.contains("ControlPersist=600"))
        XCTAssertTrue(arguments.contains { $0.hasPrefix("ControlPath=/private/tmp/Nethriva-") })
        XCTAssertTrue(arguments.contains { $0.hasSuffix("/%C.socket") })
    }

    func testTelnetNegotiationIsRemovedFromTerminalOutput() {
        var parser = TelnetProtocolParser()
        let result = parser.process([255, 251, 1, 72, 105])

        XCTAssertEqual(result.display, Array("Hi".utf8))
        XCTAssertEqual(result.responses, [[255, 253, 1]])
    }

    func testTelnetEscapesLiteralIACBytes() {
        XCTAssertEqual(
            TelnetProtocolParser.escapeOutgoing([65, 255, 66]),
            [65, 255, 255, 66]
        )
    }

    func testCorruptConnectionDataRestoresLastKnownGoodBackup() throws {
        let suite = #function
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = UserDefaultsConnectionStore(
            defaults: defaults,
            storageKey: "connections",
            legacyDefaults: nil
        )
        let connection = RemoteConnection(
            name: "Fictional Server",
            kind: .ssh,
            host: "host.example.invalid"
        )

        try store.save([connection])
        defaults.set(Data("not-json".utf8), forKey: "connections")

        let result = try store.load()
        XCTAssertNotNil(result.recoveryNotice)
        XCTAssertTrue(result.connections.contains { $0.id == connection.id })
    }

    func testFutureConnectionSchemaIsNotOverwrittenByAnOlderBackup() throws {
        let suite = #function
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = UserDefaultsConnectionStore(
            defaults: defaults,
            storageKey: "connections",
            legacyDefaults: nil
        )
        try store.save([.localShell])
        let futureData = Data(#"{"schemaVersion":999,"connections":[]}"#.utf8)
        defaults.set(futureData, forKey: "connections")

        XCTAssertThrowsError(try store.load()) { error in
            guard case ConnectionStoreError.unsupportedSchema(999) = error else {
                return XCTFail("Expected the unsupported schema error, received \(error)")
            }
        }
        XCTAssertEqual(defaults.data(forKey: "connections"), futureData)
    }

    func testPlainConnectionArchiveRoundTripsWithoutCredentials() throws {
        let connection = RemoteConnection(
            name: "Fictional Router",
            kind: .ssh,
            host: "router.example.invalid",
            username: "testuser",
            group: "Lab",
            isFavorite: true,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let archive = ConnectionArchive(
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            groups: ["Empty Group", "Lab"],
            connections: [connection]
        )

        let data = try ConnectionTransferService.encodePlain(archive)
        let inspection = try ConnectionTransferService.inspect(data)
        guard case .plain(let decoded) = inspection.content else {
            return XCTFail("Expected a plain connection archive")
        }

        XCTAssertEqual(decoded, archive)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("password"))
    }

    func testPlainConnectionArchiveRejectsCredentials() {
        let connection = RemoteConnection(
            name: "Fictional Server",
            kind: .ssh,
            host: "server.example.invalid"
        )
        let archive = ConnectionArchive(
            groups: ["Lab"],
            connections: [connection],
            credentials: [
                ConnectionArchiveCredential(
                    connectionID: connection.id,
                    password: "unit-test-placeholder"
                ),
            ]
        )

        XCTAssertThrowsError(try ConnectionTransferService.encodePlain(archive)) { error in
            XCTAssertEqual(error as? ConnectionTransferError, .plaintextCredentials)
        }
    }

    func testConnectionArchiveCannotReplaceTheBuiltInLocalTerminal() {
        let connection = RemoteConnection(
            id: RemoteConnection.localShell.id,
            name: "Imposter",
            kind: .ssh,
            host: "imposter.example.invalid"
        )
        let archive = ConnectionArchive(groups: [], connections: [connection])

        XCTAssertThrowsError(try ConnectionTransferService.encodePlain(archive)) { error in
            guard let transferError = error as? ConnectionTransferError,
                  case .invalidArchiveContent = transferError else {
                return XCTFail("Expected invalid archive content, received \(error)")
            }
        }
    }

    func testEncryptedConnectionArchiveRoundTripsCredentials() throws {
        let connection = RemoteConnection(
            name: "Fictional Desktop",
            kind: .rdp,
            host: "desktop.example.invalid",
            group: "Windows",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let archive = ConnectionArchive(
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            groups: ["Windows"],
            connections: [connection],
            credentials: [
                ConnectionArchiveCredential(
                    connectionID: connection.id,
                    password: "unit-test-placeholder"
                ),
            ]
        )

        let data = try ConnectionTransferService.encodeEncrypted(
            archive,
            password: "archive-password",
            iterations: 10_000
        )
        let inspection = try ConnectionTransferService.inspect(data)
        guard case .encrypted = inspection.content else {
            return XCTFail("Expected an encrypted connection archive")
        }

        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("unit-test-placeholder"))
        XCTAssertEqual(
            try ConnectionTransferService.decodeEncrypted(data, password: "archive-password"),
            archive
        )
        XCTAssertThrowsError(
            try ConnectionTransferService.decodeEncrypted(data, password: "wrong-password")
        ) { error in
            XCTAssertEqual(error as? ConnectionTransferError, .incorrectPassword)
        }
    }

    @MainActor
    func testConnectionImportPreservesGroupsAndCredentials() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = UserDefaultsConnectionStore(defaults: defaults, storageKey: "connections")
        let groupStore = UserDefaultsConnectionGroupStore(defaults: defaults, storageKey: "groups")
        let credentialVault = TestCredentialVault()
        let state = AppState(
            store: store,
            groupStore: groupStore,
            credentialVault: credentialVault
        )
        let connection = RemoteConnection(
            name: "Fictional Switch",
            kind: .telnet,
            host: "switch.example.invalid",
            group: "Network"
        )
        let archive = ConnectionArchive(
            groups: ["Empty Group", "Network"],
            connections: [connection],
            credentials: [
                ConnectionArchiveCredential(
                    connectionID: connection.id,
                    password: "unit-test-placeholder"
                ),
            ]
        )

        let summary = try state.importConnectionArchive(archive, conflictPolicy: .keepExisting)

        XCTAssertEqual(summary.added, 1)
        XCTAssertEqual(summary.credentialsImported, 1)
        XCTAssertTrue(state.groups.contains("Empty Group"))
        XCTAssertTrue(state.connections.contains { $0.id == connection.id })
        XCTAssertEqual(try credentialVault.password(for: connection.id), "unit-test-placeholder")
    }

    @MainActor
    func testConnectionImportConflictPolicyCanKeepOrReplaceExistingRecord() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = UserDefaultsConnectionStore(defaults: defaults, storageKey: "connections")
        let groupStore = UserDefaultsConnectionGroupStore(defaults: defaults, storageKey: "groups")
        let state = AppState(
            store: store,
            groupStore: groupStore,
            credentialVault: TestCredentialVault()
        )
        let id = UUID()
        let original = RemoteConnection(
            id: id,
            name: "Original Name",
            kind: .ssh,
            host: "original.example.invalid"
        )
        try state.add(original, password: nil)
        let replacement = RemoteConnection(
            id: id,
            name: "Replacement Name",
            kind: .ssh,
            host: "replacement.example.invalid"
        )
        let archive = ConnectionArchive(groups: [], connections: [replacement])

        let kept = try state.importConnectionArchive(archive, conflictPolicy: .keepExisting)
        XCTAssertEqual(kept.skipped, 1)
        XCTAssertEqual(state.connections.first { $0.id == id }?.name, "Original Name")

        let replaced = try state.importConnectionArchive(archive, conflictPolicy: .replaceExisting)
        XCTAssertEqual(replaced.replaced, 1)
        XCTAssertEqual(state.connections.first { $0.id == id }?.name, "Replacement Name")
    }

    func testDebugBuildUsesAnIsolatedConnectionLibraryAndKeychainService() {
#if DEBUG
        XCTAssertTrue(NethrivaDataProfile.isDevelopment)
        XCTAssertEqual(NethrivaDataProfile.defaultsSuiteName, "com.vitalii.Nethriva.Development")
        XCTAssertEqual(
            NethrivaDataProfile.credentialService,
            "com.vitalii.nethriva.development.credentials"
        )
        XCTAssertTrue(NethrivaDataProfile.legacyCredentialServices.isEmpty)
#else
        XCTFail("This isolation test must run in the Debug configuration")
#endif
    }

    func testReadingCurrentKeychainPasswordDoesNotRewriteIt() throws {
        var servicesRead: [String] = []
        var migrationCount = 0
        let result = try KeychainService.resolvePassword(
            account: "fictional-connection",
            currentService: "test.current.credentials",
            legacyServices: ["test.legacy.credentials"],
            read: { _, service in
                servicesRead.append(service)
                return service == "test.current.credentials" ? "unit-test-placeholder" : nil
            },
            migrate: { _ in migrationCount += 1 }
        )

        XCTAssertEqual(result, "unit-test-placeholder")
        XCTAssertEqual(servicesRead, ["test.current.credentials"])
        XCTAssertEqual(migrationCount, 0)
    }

    func testLegacyKeychainPasswordMigratesOnlyWhenCurrentItemIsMissing() throws {
        var servicesRead: [String] = []
        var migratedPassword: String?
        let result = try KeychainService.resolvePassword(
            account: "fictional-connection",
            currentService: "test.current.credentials",
            legacyServices: ["test.legacy.credentials"],
            read: { _, service in
                servicesRead.append(service)
                return service == "test.legacy.credentials" ? "unit-test-placeholder" : nil
            },
            migrate: { migratedPassword = $0 }
        )

        XCTAssertEqual(result, "unit-test-placeholder")
        XCTAssertEqual(servicesRead, ["test.current.credentials", "test.legacy.credentials"])
        XCTAssertEqual(migratedPassword, "unit-test-placeholder")
    }

    @MainActor
    func testDisplaySettingsHideUsernamesByDefaultAndPersistChoices() {
        let suite = #function
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = RemoteConnection(
            name: "Fictional Server",
            kind: .ssh,
            host: "server.example.invalid",
            username: "testuser"
        )
        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.sidebarEndpoint(for: connection), "server.example.invalid:22")
        XCTAssertEqual(settings.sessionEndpoint(for: connection), "server.example.invalid:22")

        settings.showSidebarUsernames = true
        settings.showSessionUsernames = true
        XCTAssertEqual(settings.sessionEndpoint(for: connection), "testuser@server.example.invalid:22")
        settings.showSessionAddresses = false
        let reloaded = AppSettings(defaults: defaults)

        XCTAssertEqual(reloaded.sidebarEndpoint(for: connection), "testuser@server.example.invalid:22")
        XCTAssertNil(reloaded.sessionEndpoint(for: connection))
    }

    func testDiagnosticReportDoesNotContainConnectionDetails() {
        let connection = RemoteConnection(
            name: "Sensitive Client Name",
            kind: .ssh,
            host: "private.example.invalid",
            username: "private-user",
            group: "Sensitive Group"
        )

        let report = DiagnosticReportService.makeReport(connections: [connection])

        XCTAssertTrue(report.contains("SSH: 1"))
        XCTAssertFalse(report.contains(connection.name))
        XCTAssertFalse(report.contains(connection.host))
        XCTAssertFalse(report.contains(connection.username))
        XCTAssertFalse(report.contains(connection.group))
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
    func testFailedConnectionDeleteRestoresConnectionAndOpenTab() {
        let connection = RemoteConnection(name: "Server", kind: .ssh, host: "example.com")
        let store = FailOnSaveConnectionStore(connections: [.localShell, connection])
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let groupStore = UserDefaultsConnectionGroupStore(defaults: defaults, storageKey: "groups")
        let state = AppState(store: store, groupStore: groupStore, credentialVault: TestCredentialVault())
        state.open(connection)
        store.shouldFail = true

        state.delete(connection)

        XCTAssertTrue(state.connections.contains { $0.id == connection.id })
        XCTAssertTrue(state.tabs.contains { $0.connection.id == connection.id })
        XCTAssertNotNil(state.persistenceNotice)
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
    func testNestedGroupsPersistAndCannotDeleteNonemptyParent() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = UserDefaultsConnectionStore(defaults: defaults, storageKey: "connections")
        let groupStore = UserDefaultsConnectionGroupStore(defaults: defaults, storageKey: "groups")
        let state = AppState(store: store, groupStore: groupStore, credentialVault: TestCredentialVault())

        XCTAssertTrue(state.addGroup("Production"))
        XCTAssertTrue(state.addSubgroup("Servers", under: "Production"))
        XCTAssertTrue(state.addSubgroup("Linux", under: "Production/Servers"))
        XCTAssertFalse(state.addSubgroup("Invalid/Name", under: "Production"))
        XCTAssertEqual(state.groups, ["Production", "Production/Servers", "Production/Servers/Linux"])

        let connection = RemoteConnection(
            name: "Web Server",
            kind: .ssh,
            host: "192.0.2.10",
            group: "Production/Servers/Linux"
        )
        try state.add(connection, password: nil)
        state.deleteGroup("Production")
        state.deleteGroup("Production/Servers/Linux")
        XCTAssertTrue(state.groups.contains("Production"))
        XCTAssertTrue(state.groups.contains("Production/Servers/Linux"))

        let reloaded = AppState(store: store, groupStore: groupStore, credentialVault: TestCredentialVault())
        XCTAssertEqual(reloaded.connections.first(where: { $0.id == connection.id })?.group,
                       "Production/Servers/Linux")
        XCTAssertTrue(reloaded.groups.contains("Production/Servers"))
    }

    @MainActor
    func testQuickRenameUpdatesSavedConnectionAndOpenTab() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = UserDefaultsConnectionStore(defaults: defaults, storageKey: "connections")
        let groupStore = UserDefaultsConnectionGroupStore(defaults: defaults, storageKey: "groups")
        let state = AppState(store: store, groupStore: groupStore, credentialVault: TestCredentialVault())
        let connection = RemoteConnection(name: "Old Name", kind: .ssh, host: "192.0.2.20")
        try state.add(connection, password: nil)
        state.open(connection)

        try state.rename(connection, to: "  New Name  ")

        XCTAssertEqual(state.connections.first(where: { $0.id == connection.id })?.name, "New Name")
        XCTAssertEqual(state.tabs.first?.title, "New Name")
        XCTAssertEqual(try store.load().connections.first(where: { $0.id == connection.id })?.name,
                       "New Name")
    }

    func testSearchMatchesNameHostGroupAndMultipleTerms() {
        let connection = RemoteConnection(
            name: "Core Router",
            kind: .ssh,
            host: "192.0.2.30",
            group: "Network/Edge"
        )

        XCTAssertTrue(ConnectionSearch.matches(connection, query: "router"))
        XCTAssertTrue(ConnectionSearch.matches(connection, query: "192.0.2"))
        XCTAssertTrue(ConnectionSearch.matches(connection, query: "edge 192.0.2"))
        XCTAssertFalse(ConnectionSearch.matches(connection, query: "router 203.0.113"))
    }

    @MainActor
    func testMovingMultipleConnectionsIntoNestedGroupPersistsTogether() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = UserDefaultsConnectionStore(defaults: defaults, storageKey: "connections")
        let groupStore = UserDefaultsConnectionGroupStore(defaults: defaults, storageKey: "groups")
        let state = AppState(store: store, groupStore: groupStore, credentialVault: TestCredentialVault())
        let first = RemoteConnection(name: "First", kind: .ssh, host: "192.0.2.41")
        let second = RemoteConnection(name: "Second", kind: .rdp, host: "192.0.2.42")
        try state.add(first, password: nil)
        try state.add(second, password: nil)
        XCTAssertTrue(state.addGroup("Lab/Servers"))
        state.toggleFavorite(first)

        try state.moveConnections(withIDs: [first.id, second.id], toGroup: "Lab/Servers")

        let moved = try store.load().connections.filter { [first.id, second.id].contains($0.id) }
        XCTAssertEqual(moved.count, 2)
        XCTAssertTrue(moved.allSatisfy { $0.group == "Lab/Servers" && !$0.isFavorite })
        XCTAssertEqual(state.selectedConnectionID, second.id)

        try state.addConnectionsToFavorites(withIDs: [first.id, second.id])
        let favorited = try store.load().connections.filter { [first.id, second.id].contains($0.id) }
        XCTAssertTrue(favorited.allSatisfy(\.isFavorite))
        XCTAssertTrue(favorited.allSatisfy { $0.group == "Lab/Servers" })
    }

    @MainActor
    func testFailedBatchMoveRestoresEveryConnection() {
        let first = RemoteConnection(name: "First", kind: .ssh, host: "192.0.2.51")
        let second = RemoteConnection(name: "Second", kind: .ssh, host: "192.0.2.52")
        let store = FailOnSaveConnectionStore(connections: [.localShell, first, second])
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let groupStore = UserDefaultsConnectionGroupStore(defaults: defaults, storageKey: "groups")
        let state = AppState(store: store, groupStore: groupStore, credentialVault: TestCredentialVault())
        XCTAssertTrue(state.addGroup("Other"))
        store.shouldFail = true

        XCTAssertThrowsError(try state.moveConnections(withIDs: [first.id, second.id], toGroup: "Other"))
        XCTAssertTrue(state.connections.filter { [first.id, second.id].contains($0.id) }
            .allSatisfy { $0.group == "Ungrouped" && !$0.isFavorite })
        XCTAssertThrowsError(try state.addConnectionsToFavorites(withIDs: [first.id, second.id]))
        XCTAssertTrue(state.connections.filter { [first.id, second.id].contains($0.id) }
            .allSatisfy { !$0.isFavorite })
    }

    func testSidebarCommandAndShiftSelectionForConnectionsAndFolders() {
        let first = SidebarSelectionItem.connection(UUID())
        let second = SidebarSelectionItem.connection(UUID())
        let third = SidebarSelectionItem.connection(UUID())
        let firstGroup = SidebarSelectionItem.group("Lab")
        let secondGroup = SidebarSelectionItem.group("Production")
        let visible = [firstGroup, first, second, secondGroup, third]

        let initial = SidebarSelection.update(
            selected: [], anchor: nil, clicked: first, visible: visible, modifiers: []
        )
        let range = SidebarSelection.update(
            selected: initial.selected, anchor: initial.anchor,
            clicked: third, visible: visible, modifiers: [.shift]
        )
        XCTAssertEqual(range.selected, [first, second, third])
        let toggled = SidebarSelection.update(
            selected: range.selected, anchor: range.anchor,
            clicked: second, visible: visible, modifiers: [.command]
        )
        XCTAssertEqual(toggled.selected, [first, third])

        let groupStart = SidebarSelection.update(
            selected: [], anchor: nil, clicked: firstGroup, visible: visible, modifiers: []
        )
        let groupRange = SidebarSelection.update(
            selected: groupStart.selected, anchor: groupStart.anchor,
            clicked: secondGroup, visible: visible, modifiers: [.shift]
        )
        XCTAssertEqual(groupRange.selected, [firstGroup, secondGroup])
    }

    @MainActor
    func testMovingFolderPreservesSubfoldersAndConnections() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = UserDefaultsConnectionStore(defaults: defaults, storageKey: "connections")
        let groupStore = UserDefaultsConnectionGroupStore(defaults: defaults, storageKey: "groups")
        let state = AppState(store: store, groupStore: groupStore, credentialVault: TestCredentialVault())
        XCTAssertTrue(state.addGroup("Lab/Servers/Linux"))
        XCTAssertTrue(state.addGroup("Lab/Servers/Empty"))
        XCTAssertTrue(state.addGroup("Production"))
        let first = RemoteConnection(name: "One", kind: .ssh, host: "192.0.2.61", group: "Lab/Servers")
        let second = RemoteConnection(name: "Two", kind: .rdp, host: "192.0.2.62", group: "Lab/Servers/Linux", isFavorite: true)
        let third = RemoteConnection(name: "Three", kind: .ssh, host: "192.0.2.63", group: "Lab")
        try state.add(first, password: nil)
        try state.add(second, password: nil)
        try state.add(third, password: nil)

        try state.moveSidebarItems(
            withConnectionIDs: [third.id],
            groupPaths: ["Lab/Servers", "Lab/Servers/Linux"],
            toGroup: "Production"
        )

        XCTAssertTrue(state.groups.contains("Production/Servers"))
        XCTAssertTrue(state.groups.contains("Production/Servers/Linux"))
        XCTAssertTrue(state.groups.contains("Production/Servers/Empty"))
        XCTAssertFalse(state.groups.contains("Lab/Servers"))
        XCTAssertEqual(state.connections.first(where: { $0.id == first.id })?.group, "Production/Servers")
        XCTAssertEqual(state.connections.first(where: { $0.id == second.id })?.group, "Production/Servers/Linux")
        XCTAssertTrue(state.connections.first(where: { $0.id == second.id })?.isFavorite == true)
        XCTAssertEqual(state.connections.first(where: { $0.id == third.id })?.group, "Production")
        let reloaded = AppState(store: store, groupStore: groupStore, credentialVault: TestCredentialVault())
        XCTAssertTrue(reloaded.groups.contains("Production/Servers/Empty"))
        XCTAssertEqual(reloaded.connections.first(where: { $0.id == first.id })?.group,
                       "Production/Servers")
    }

    @MainActor
    func testFolderCannotMoveIntoItselfOrOverExistingFolder() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = UserDefaultsConnectionStore(defaults: defaults, storageKey: "connections")
        let groupStore = UserDefaultsConnectionGroupStore(defaults: defaults, storageKey: "groups")
        let state = AppState(store: store, groupStore: groupStore, credentialVault: TestCredentialVault())
        XCTAssertTrue(state.addGroup("Lab/Servers/Linux"))
        XCTAssertTrue(state.addGroup("Production/Servers"))
        let previousGroups = state.groups

        XCTAssertThrowsError(try state.moveSidebarItems(
            withConnectionIDs: [], groupPaths: ["Lab/Servers"], toGroup: "Lab/Servers/Linux"
        ))
        XCTAssertThrowsError(try state.moveSidebarItems(
            withConnectionIDs: [], groupPaths: ["Lab/Servers"], toGroup: "Production"
        ))
        XCTAssertEqual(state.groups, previousGroups)
    }

    @MainActor
    func testMultipleFoldersMoveTogether() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = UserDefaultsConnectionStore(defaults: defaults, storageKey: "connections")
        let groupStore = UserDefaultsConnectionGroupStore(defaults: defaults, storageKey: "groups")
        let state = AppState(store: store, groupStore: groupStore, credentialVault: TestCredentialVault())
        XCTAssertTrue(state.addGroup("Lab/Switches"))
        XCTAssertTrue(state.addGroup("Lab/Servers/Empty"))
        XCTAssertTrue(state.addGroup("Production"))

        try state.moveSidebarItems(
            withConnectionIDs: [],
            groupPaths: ["Lab/Switches", "Lab/Servers"],
            toGroup: "Production"
        )

        XCTAssertTrue(state.groups.contains("Production/Switches"))
        XCTAssertTrue(state.groups.contains("Production/Servers/Empty"))
        XCTAssertFalse(state.groups.contains("Lab/Switches"))
        XCTAssertFalse(state.groups.contains("Lab/Servers"))
    }

    @MainActor
    func testFailedFolderMoveRestoresGroupHierarchy() {
        let store = FailOnSaveConnectionStore(connections: [.localShell])
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let groupStore = UserDefaultsConnectionGroupStore(defaults: defaults, storageKey: "groups")
        let state = AppState(store: store, groupStore: groupStore, credentialVault: TestCredentialVault())
        XCTAssertTrue(state.addGroup("Lab/Servers/Empty"))
        XCTAssertTrue(state.addGroup("Production"))
        let originalGroups = state.groups
        store.shouldFail = true

        XCTAssertThrowsError(try state.moveSidebarItems(
            withConnectionIDs: [], groupPaths: ["Lab/Servers"], toGroup: "Production"
        ))

        XCTAssertEqual(state.groups, originalGroups)
        XCTAssertEqual(groupStore.load(), originalGroups)
    }

    @MainActor
    func testRenamingGroupPreservesNestedClientsAndCredentials() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = UserDefaultsConnectionStore(defaults: defaults, storageKey: "connections")
        let groupStore = UserDefaultsConnectionGroupStore(defaults: defaults, storageKey: "groups")
        let vault = TestCredentialVault()
        let state = AppState(store: store, groupStore: groupStore, credentialVault: vault)
        XCTAssertTrue(state.addGroup("Lab/Servers/Empty"))
        let connection = RemoteConnection(
            name: "Test Server", kind: .ssh, host: "192.0.2.71", group: "Lab/Servers"
        )
        try state.add(connection, password: "unit-test-placeholder")

        let path = try state.renameGroup("Lab/Servers", to: "Hosts")

        XCTAssertEqual(path, "Lab/Hosts")
        XCTAssertTrue(state.groups.contains("Lab/Hosts/Empty"))
        XCTAssertFalse(state.groups.contains("Lab/Servers"))
        XCTAssertEqual(state.connections.first(where: { $0.id == connection.id })?.group, "Lab/Hosts")
        XCTAssertEqual(try vault.password(for: connection.id), "unit-test-placeholder")
        let reloaded = AppState(store: store, groupStore: groupStore, credentialVault: vault)
        XCTAssertEqual(reloaded.connections.first(where: { $0.id == connection.id })?.group,
                       "Lab/Hosts")
        XCTAssertTrue(reloaded.groups.contains("Lab/Hosts/Empty"))
    }

    @MainActor
    func testGroupRenameRejectsConflictAndBuiltInGroup() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = UserDefaultsConnectionStore(defaults: defaults, storageKey: "connections")
        let groupStore = UserDefaultsConnectionGroupStore(defaults: defaults, storageKey: "groups")
        let state = AppState(store: store, groupStore: groupStore, credentialVault: TestCredentialVault())
        XCTAssertTrue(state.addGroup("Lab/Servers"))
        XCTAssertTrue(state.addGroup("Lab/Hosts"))
        XCTAssertTrue(state.addGroup("Ungrouped"))
        let originalGroups = state.groups

        XCTAssertThrowsError(try state.renameGroup("Lab/Servers", to: "Hosts"))
        XCTAssertThrowsError(try state.renameGroup("Lab/Servers", to: "Bad/Name"))
        XCTAssertThrowsError(try state.renameGroup("Ungrouped", to: "Other"))
        XCTAssertEqual(state.groups, originalGroups)
    }

    @MainActor
    func testFailedGroupRenameRestoresNamesAndClients() {
        let connection = RemoteConnection(
            name: "Test Server", kind: .ssh, host: "192.0.2.72", group: "Lab/Servers"
        )
        let store = FailOnSaveConnectionStore(connections: [.localShell, connection])
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let groupStore = UserDefaultsConnectionGroupStore(defaults: defaults, storageKey: "groups")
        let state = AppState(store: store, groupStore: groupStore, credentialVault: TestCredentialVault())
        let originalGroups = state.groups
        store.shouldFail = true

        XCTAssertThrowsError(try state.renameGroup("Lab/Servers", to: "Hosts"))

        XCTAssertEqual(state.groups, originalGroups)
        XCTAssertEqual(groupStore.load(), originalGroups)
        XCTAssertEqual(state.connections.first(where: { $0.id == connection.id })?.group,
                       "Lab/Servers")
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
    private var passwords: [UUID: String] = [:]

    func save(password: String, for connectionID: UUID) throws {
        passwords[connectionID] = password
    }

    func password(for connectionID: UUID) throws -> String? {
        passwords[connectionID]
    }

    func deletePassword(for connectionID: UUID) throws {
        passwords.removeValue(forKey: connectionID)
    }
}

private final class FailingCredentialVault: CredentialVault {
    enum TestError: Error { case unavailable }

    func save(password: String, for connectionID: UUID) throws { throw TestError.unavailable }
    func password(for connectionID: UUID) throws -> String? { nil }
    func deletePassword(for connectionID: UUID) throws {}
}

private final class FailOnSaveConnectionStore: ConnectionPersisting {
    enum TestError: Error { case unavailable }

    let connections: [RemoteConnection]
    var shouldFail = false

    init(connections: [RemoteConnection]) {
        self.connections = connections
    }

    func load() throws -> ConnectionLoadResult {
        ConnectionLoadResult(connections: connections, recoveryNotice: nil)
    }

    func save(_ connections: [RemoteConnection]) throws {
        if shouldFail { throw TestError.unavailable }
    }
}
