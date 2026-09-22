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
            "Telnet sessions",
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

        XCTAssertEqual(ssh.port, 22)
        XCTAssertEqual(telnet.port, 23)
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
