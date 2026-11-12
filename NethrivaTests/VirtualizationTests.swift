import AppKit
import CryptoKit
import Network
import Security
import WebKit
import XCTest
@testable import Nethriva

final class VirtualizationTests: XCTestCase {
    @MainActor func testFitScreenReappliesLocalScalingWithoutEnablingGuestResize() {
        let connection = RemoteConnection(name: "Test Console", kind: .vnc, host: "console.example.invalid", port: 5900)
        let controller = VMConsoleController(connection: connection, machine: nil)
        XCTAssertFalse(controller.resizeGuest)
        controller.fit = false
        controller.fitToScreen()
        XCTAssertTrue(controller.fit)
        XCTAssertEqual(controller.bridge.options["fit"] as? Bool, true)
        XCTAssertFalse(controller.resizeGuest)
        // A repeated button press must also send the scale action when the
        // published fit value did not change.
        controller.bridge.options["fit"] = false
        controller.fitToScreen()
        XCTAssertEqual(controller.bridge.options["fit"] as? Bool, true)
        XCTAssertFalse(controller.resizeGuest)
    }
    func testPlatformDefaultsAndPowerStates() {
        XCTAssertEqual(VirtualizationPlatform.proxmox.defaultPort, 8006)
        XCTAssertTrue(VirtualizationPlatform.libvirt.usesSSH)
        XCTAssertEqual(VMPowerState.parse("poweredOn"), .running)
        XCTAssertEqual(VMPowerState.parse("shut off"), .stopped)
        XCTAssertEqual(VMPowerState.parse("Saved"), .suspended)
    }
    func testVMEndpointsRejectShellAndURLAmbiguity() throws {
        for host in ["-oProxyCommand=bad", "good.example/bad", "user@host", "host\nother"] {
            let connection = RemoteConnection(name: "Test", kind: .virtualization, host: host, port: 443)
            XCTAssertThrowsError(try VMInput.endpoint(for: connection))
        }
        let connection = RemoteConnection(name: "Test", kind: .virtualization, host: "host.example.test", port: 443)
        XCTAssertEqual(try VMInput.endpoint(for: connection).host, "host.example.test")
    }
    func testShellQuotingAndXMLRejectEntityExpansion() throws {
        XCTAssertEqual(try VMInput.shellQuote("a'b"), "'a'\"'\"'b'")
        XCTAssertThrowsError(try VMInput.shellQuote("disk\r\ncommand"))
        XCTAssertEqual(VMInput.xml("<&\"'"), "&lt;&amp;&quot;&apos;")
        XCTAssertThrowsError(try VMXMLDocument.parse(Data("<!DOCTYPE x [<!ENTITY a 'expand'>]><x>&a;</x>".utf8)))
        let utf16XML = "<?xml version='1.0' encoding='UTF-16'?><!DOCTYPE x [<!ENTITY a 'expand'>]><x>&a;</x>"
        XCTAssertThrowsError(try VMXMLDocument.parse(try XCTUnwrap(utf16XML.data(using: .utf16))))
    }
    func testVMConfigurationValidationAndSerialization() throws {
        var config = VirtualizationConfiguration()
        config.platform = .libvirt; config.libvirtURI = "qemu+ssh://unsafe/system"
        XCTAssertThrowsError(try config.validate())
        config.libvirtURI = "qemu:///system"; config.toolsImage = "/var/lib/libvirt/images/tools.iso"
        try config.validate()
        var host = RemoteConnection(name: "Test", kind: .virtualization, host: "hv.example.test", port: 22)
        host.virtualization = config
        let decoded = try JSONDecoder().decode(RemoteConnection.self, from: JSONEncoder().encode(host))
        XCTAssertEqual(decoded.virtualization, config)
        XCTAssertEqual(decoded.kind, .virtualization)
    }
    @MainActor func testInventoryParsers() throws {
        let pve = try RESTVirtualizationBackend.proxmoxMachines(["data": [
            ["vmid": 100, "node": "node1", "type": "qemu", "name": "Test", "status": "running"],
            ["vmid": 101, "node": "node1", "type": "lxc", "status": "stopped"]]])
        XCTAssertEqual(pve.count, 2); XCTAssertTrue(pve[1].isContainer)
        let xo = try RESTVirtualizationBackend.xenMachines([
            "vm-id": ["type": "VM", "name_label": "Test", "power_state": "Running"],
            "template": ["type": "VM", "is_a_template": true]])
        XCTAssertEqual(xo.count, 1); XCTAssertEqual(xo[0].state, .running)
        XCTAssertThrowsError(try RESTVirtualizationBackend.proxmoxMachines([:]))
    }
    func testLibvirtXMLAndHyperVInventory() throws {
        let id = "11111111-1111-4111-8111-111111111111"
        let output = "<domain><name>Test &amp; VM</name><devices><disk device='cdrom'><target dev='sda'/></disk><channel><target name='org.qemu.guest_agent.0'/></channel></devices></domain>\n__NETHRIVA_VM_STATE__\nrunning\n"
        let vm = try SSHVirtualizationBackend.libvirtMachine(id: id, output: output)
        XCTAssertEqual(vm.name, "Test & VM"); XCTAssertEqual(vm.cdromDevice, "sda"); XCTAssertEqual(vm.state, .running)
        let hyperv = try SSHVirtualizationBackend.hyperVMachines("[{\"id\":\"\(id)\",\"name\":\"Test\",\"state\":\"Running\"}]")
        XCTAssertEqual(hyperv.count, 1); XCTAssertEqual(hyperv[0].state, .running)
        XCTAssertThrowsError(try SSHVirtualizationBackend.hyperVMachines("not JSON"))
    }
    func testPowerShellEncodingIsSafeAndFramed() throws {
        let script = "Write-Output 'test & $value'"
        let command = SSHVirtualizationBackend.powershellCommand(script)
        let encoded = String(command.split(separator: " ").last!)
        let decoded = String(data: try XCTUnwrap(Data(base64Encoded: encoded)), encoding: .utf16LittleEndian)!
        XCTAssertTrue(decoded.contains(script)); XCTAssertTrue(decoded.contains("__NETHRIVA_VM_BEGIN__"))
        XCTAssertTrue(decoded.contains("__NETHRIVA_VM_END__:1"))
        XCTAssertFalse(command.contains("$value")); XCTAssertFalse(command.contains("&"))
        XCTAssertTrue(SSHVirtualizationBackend.hyperVGracefulRestartCommand.contains("Stop-VM -Passthru"))
        XCTAssertFalse(SSHVirtualizationBackend.hyperVGracefulRestartCommand.contains("Restart-VM"))
    }
    func testCapabilitiesExcludeUnavailableAndUnsafeOperations() {
        let vm = VirtualMachine(id: "test", name: "Test", state: .running)
        XCTAssertFalse(VMAction.available(for: vm, platform: .nutanix).contains(.suspend))
        XCTAssertTrue(VMAction.available(for: vm, platform: .vmware).contains(.mountTools))
        XCTAssertTrue(VMAction.reset.requiresConfirmation)
        XCTAssertTrue(VMAction.shutdown.requiresConfirmation)
        XCTAssertFalse(VMAction.start.requiresConfirmation)
    }
    func testHyperVVMConnectArgumentValidation() throws {
        var connection = RemoteConnection(name: "Test", kind: .rdp, host: "host.example.test", port: 2179)
        connection.rdpVirtualMachineID = "11111111-1111-4111-8111-111111111111"
        XCTAssertTrue(try FreeRDPArgumentsBuilder.arguments(for: connection, password: nil).contains("/vmconnect:11111111-1111-4111-8111-111111111111"))
        connection.rdpVirtualMachineID = "invalid"
        XCTAssertThrowsError(try FreeRDPArgumentsBuilder.arguments(for: connection, password: nil))
    }
    @MainActor func testBundledConsoleModulesLoadInWebKit() async throws {
        let root = try XCTUnwrap(Bundle.main.resourceURL?.appendingPathComponent("Consoles"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("noVNC/core/rfb.js").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("spice/src/main.js").path))
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(VMConsoleAssets(root: root), forURLScheme: "nethriva-console")
        let handler = ConsoleReadyHandler(expectation: expectation(description: "Console JavaScript modules loaded"))
        config.userContentController.add(handler, name: "vmConsole")
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        // Match the app's hosted surface. An unattached WKWebView can remain
        // background-throttled during a cold WebContent process launch in CI.
        let window = NSWindow(contentRect: webView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = webView
        webView.navigationDelegate = handler
        defer {
            webView.stopLoading(); webView.navigationDelegate = nil
            config.userContentController.removeScriptMessageHandler(forName: "vmConsole")
            window.contentView = nil
        }
        webView.load(URLRequest(url: URL(string: "nethriva-console://bundle/console.html")!))
        await fulfillment(of: [handler.expectation], timeout: 30)
        guard handler.ready else {
            XCTFail(handler.navigationFailure ?? "Console module readiness was not received")
            return
        }
        let ready = try await webView.evaluateJavaScript("typeof window.startConsole === 'function' && typeof window.consoleAction === 'function'") as? Bool
        XCTAssertEqual(ready, true)
        let modes = try await webView.evaluateJavaScript("""
        (() => {
            const spice = document.getElementById('spice-screen');
            window.startConsole({renderer: 'vnc', fit: true, viewOnly: true, clipboard: false});
            const vncHidesSpice = spice.hidden && getComputedStyle(spice).display === 'none';
            window.stopConsole();
            window.startConsole({renderer: 'spice', fit: true, viewOnly: true, clipboard: false});
            const spiceShowsHost = !spice.hidden && getComputedStyle(spice).display !== 'none';
            window.stopConsole();
            return [vncHidesSpice, spiceShowsHost];
        })()
        """) as? [Bool]
        XCTAssertEqual(modes, [true, true], "Only the selected renderer may occupy the visible console area")
    }

    @MainActor func testVNCConsoleConnectsOverNativeTCPAndSendsCtrlAltDel() async throws {
        let server = try MockVNCServer()
        defer { server.stop() }
        let started = expectation(description: "Mock VNC listening")
        server.start { started.fulfill() }
        await fulfillment(of: [started], timeout: 5)
        let port = try XCTUnwrap(server.listener.port).rawValue
        let bridge = VMConsoleWebBridge()
        let connected = expectation(description: "VNC handshake completed in WebKit")
        bridge.onState = { value in
            if value == "connected" { connected.fulfill() }
            else { XCTFail("VNC initialization failed: \(value)") }
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(VMConsoleAssets(root: try XCTUnwrap(Bundle.main.resourceURL?.appendingPathComponent("Consoles"))), forURLScheme: "nethriva-console")
        configuration.userContentController.add(bridge, name: "vmConsole")
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let window = NSWindow(contentRect: webView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = webView
        bridge.webView = webView; webView.navigationDelegate = bridge
        let http = try VirtualizationHTTP(connection: RemoteConnection(name: "Local mock", kind: .vnc, host: "127.0.0.1", port: Int(port)))
        defer {
            bridge.stop(); http.close(); webView.navigationDelegate = nil
            configuration.userContentController.removeScriptMessageHandler(forName: "vmConsole")
            window.contentView = nil
        }
        bridge.configure(VMConsoleDescriptor(renderer: .vnc, host: "127.0.0.1", port: Int(port)), http: http,
                         options: ["fit": true, "viewOnly": false, "clipboard": false])
        webView.load(URLRequest(url: URL(string: "nethriva-console://bundle/console.html")!))
        await fulfillment(of: [connected], timeout: 10)
        let displaySize = try await webView.evaluateJavaScript("document.querySelector('canvas').width") as? Int
        XCTAssertEqual(displaySize, 640)
        let delete = expectation(description: "Ctrl Alt Delete reached remote transport")
        server.onDelete = { delete.fulfill() }
        bridge.action("cad")
        await fulfillment(of: [delete], timeout: 5)
    }

    func testNutanixTaskStringWrappers() {
        XCTAssertEqual(RESTVirtualizationBackend.taskString(["String": ["value": "test-token"]]), "test-token")
        XCTAssertEqual(RESTVirtualizationBackend.taskString(["value": "test-uri"]), "test-uri")
        XCTAssertNil(RESTVirtualizationBackend.taskString(123))
    }

    @MainActor func testVMwareSOAPInventoryRetainsCDROMDevice() throws {
        let xml = """
        <RetrievePropertiesExResponse xmlns="urn:vim25" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><returnval><objects>
          <obj type="VirtualMachine">vm-101</obj>
          <propSet><name>name</name><val>Test &amp; Guest</val></propSet>
          <propSet><name>runtime.powerState</name><val>poweredOn</val></propSet>
          <propSet><name>guest.toolsRunningStatus</name><val>guestToolsRunning</val></propSet>
          <propSet><name>config.hardware.device</name><val xsi:type="ArrayOfVirtualDevice">
            <VirtualDevice xsi:type="VirtualDisk"><key>2000</key></VirtualDevice>
            <VirtualDevice xsi:type="VirtualCdrom"><key>3000</key><controllerKey>200</controllerKey><unitNumber>0</unitNumber></VirtualDevice>
          </val></propSet>
        </objects></returnval></RetrievePropertiesExResponse>
        """
        let vm = try XCTUnwrap(VMwareBackend.parseMachines(VMXMLDocument.parse(Data(xml.utf8))).first)
        XCTAssertEqual(vm.name, "Test & Guest")
        XCTAssertEqual(vm.state, .running)
        XCTAssertEqual(vm.cdromDevice, "3000|200|0")
        XCTAssertEqual(vm.guestTools, "guestToolsRunning")
    }

    @MainActor func testVMwareSessionScopedManagedReferences() throws {
        let reference = MockVMwareProtocol.viewReference
        let response = try VMwareBackend.parseResponse(Data(MockVMwareProtocol.envelope(
            "CreateContainerView", "<returnval type='ContainerView'>\(reference)</returnval>"
        ).utf8), method: "CreateContainerView")
        XCTAssertEqual(try VMwareBackend.managedReference(response.child("returnval"), operation: "CreateContainerView"), reference)
        XCTAssertFalse(VMInput.validIdentifier(reference), "Other platforms retain their stricter identifier validation")
        XCTAssertTrue(VMwareBackend.isManagedReference("ha-vm-101"))
        for invalid in ["", "session[bad]\n", "has space", "<injected/>", "bad&reference", String(repeating: "a", count: 513)] {
            XCTAssertFalse(VMwareBackend.isManagedReference(invalid))
        }
    }

    @MainActor func testVMwareSOAPFaultClassificationAndRedaction() throws {
        for (type, expected) in [("InvalidLoginFault", "authentication"), ("NoPermissionFault", "forbidden")] {
            XCTAssertThrowsError(try VMwareBackend.parseResponse(Data(MockVMwareProtocol.fault(type).utf8), method: "Login")) { error in
                switch (expected, error) {
                case ("authentication", VirtualizationError.authentication), ("forbidden", VirtualizationError.forbidden): break
                default: XCTFail("Unexpected VMware fault classification")
                }
            }
        }
        for xml in [MockVMwareProtocol.fault("NotAuthenticatedFault"), MockVMwareProtocol.fault("UnknownFault"),
                    "<html>private-fixture-detail</html>", "<broken>private-fixture-detail"] {
            XCTAssertThrowsError(try VMwareBackend.parseResponse(Data(xml.utf8), method: "RetrievePropertiesEx")) { error in
                XCTAssertTrue(error.localizedDescription.contains("RetrievePropertiesEx"))
                XCTAssertFalse(error.localizedDescription.contains("private-fixture-detail"))
            }
        }
    }

    @MainActor func testVMwareSOAPInventoryWorkflowAcceptsSessionView() async throws {
        MockVMwareProtocol.fixture.reset()
        let connection = RemoteConnection(name: "Mock VMware", kind: .virtualization, host: "vmware.example.invalid", port: 443,
                                          username: "unit-test-user")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockVMwareProtocol.self]
        let http = try VirtualizationHTTP(connection: connection, configuration: configuration)
        defer { http.close() }
        let backend = try VMwareBackend(connection: connection, password: "unit-test-placeholder", http: http)
        let machines = try await backend.machines()
        XCTAssertEqual(machines.count, 1)
        XCTAssertEqual(machines.first?.id, "ha-vm-101")
        XCTAssertEqual(machines.first?.name, "Test Guest")
        XCTAssertEqual(machines.first?.state, .running)
        let calls = MockVMwareProtocol.fixture.calls
        XCTAssertEqual(calls.map(\.method), ["RetrieveServiceContent", "Login", "CreateContainerView", "RetrievePropertiesEx", "DestroyView"])
        for call in calls where ["RetrievePropertiesEx", "DestroyView"].contains(call.method) {
            XCTAssertTrue(call.body.contains(MockVMwareProtocol.viewReference))
        }
    }

    @MainActor func testVMwareHTTP500LoginFaultIsRecognized() async throws {
        MockVMwareProtocol.fixture.reset(loginFault: true)
        defer { MockVMwareProtocol.fixture.reset() }
        let connection = RemoteConnection(name: "Mock VMware", kind: .virtualization, host: "vmware.example.invalid", port: 443,
                                          username: "unit-test-user")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockVMwareProtocol.self]
        let http = try VirtualizationHTTP(connection: connection, configuration: configuration)
        defer { http.close() }
        let backend = try VMwareBackend(connection: connection, password: "unit-test-placeholder", http: http)
        do {
            _ = try await backend.machines()
            XCTFail("Expected a structured login fault")
        } catch VirtualizationError.authentication {
            XCTAssertEqual(MockVMwareProtocol.fixture.calls.map(\.method), ["RetrieveServiceContent", "Login"])
        }
    }

    @MainActor func testVMwareConsoleRequestsFreshTicketsWithoutWebUI() async throws {
        MockVMwareProtocol.fixture.reset()
        let connection = RemoteConnection(name: "Mock VMware", kind: .virtualization, host: "vmware.example.invalid", port: 443,
                                          username: "unit-test-user")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockVMwareProtocol.self]
        let http = try VirtualizationHTTP(connection: connection, configuration: configuration)
        defer { http.close() }
        let backend = try VMwareBackend(connection: connection, password: "unit-test-placeholder", http: http)
        let vm = VirtualMachine(id: "vm-101", name: "Test Guest", state: .running)
        for _ in 0..<2 {
            let descriptor = try await backend.console(for: vm)
            XCTAssertEqual(descriptor.renderer, .vnc)
            XCTAssertTrue(descriptor.singleUseTicket)
            XCTAssertEqual(descriptor.webSocketURL?.host, "esxi.example.invalid")
            XCTAssertEqual(descriptor.webSocketURL?.path, "/ticket/synthetic-ticket")
            XCTAssertNil(descriptor.webURL)
            XCTAssertNil(descriptor.password); XCTAssertNil(descriptor.username)
            XCTAssertEqual(descriptor.headers["Sec-WebSocket-Protocol"], "binary")
            XCTAssertNil(descriptor.headers["Cookie"]); XCTAssertNil(descriptor.headers["Authorization"])
        }
        let calls = MockVMwareProtocol.fixture.calls
        XCTAssertEqual(calls.map(\.method), ["RetrieveServiceContent", "Login", "AcquireTicket", "AcquireTicket"])
        XCTAssertTrue(calls.last!.body.contains("<ticketType>webmks</ticketType>"))
        XCTAssertEqual(MockVMwareProtocol.fixture.actions.first, "\"urn:vim25/6.5\"")
        XCTAssertTrue(MockVMwareProtocol.fixture.actions.dropFirst().allSatisfy { $0 == "\"urn:vim25/8.0.3.0\"" })
    }

    @MainActor func testVMwareTicketValidationAndStrongerCertificatePins() throws {
        func descriptor(_ fields: String) throws -> VMConsoleDescriptor {
            let xml = "<AcquireTicketResponse><returnval><ticket>synthetic-ticket</ticket>\(fields)</returnval></AcquireTicketResponse>"
            return try VMwareBackend.consoleDescriptor(VMXMLDocument.parse(Data(xml.utf8)), apiOrigin: URL(string: "https://vc.example.invalid")!)
        }
        let sha256 = String(repeating: "a", count: 64), sha1 = String(repeating: "b", count: 40)
        let fields = "<host>esxi.example.invalid</host><port>443</port>"
        let value = try descriptor(fields + "<sslThumbprint>\(sha1)</sslThumbprint><certThumbprintList><hashAlgorithm>SHA-256</hashAlgorithm><thumbprint>\(sha256)</thumbprint></certThumbprintList>")
        XCTAssertEqual(value.certificatePin?.algorithm, .sha256)
        XCTAssertEqual(value.certificatePin?.fingerprints, [sha256])
        XCTAssertEqual(try descriptor(fields + "<sslThumbprint>\(sha1)</sslThumbprint>").certificatePin?.algorithm, .sha1)
        XCTAssertEqual(try descriptor(fields + "<certThumbprintList><thumbprint>\(sha256)</thumbprint></certThumbprintList>").certificatePin?.algorithm, .sha256)
        XCTAssertEqual(try descriptor(fields + "<certThumbprintList><thumbprint>\(sha1)</thumbprint></certThumbprintList>").certificatePin?.algorithm, .sha1)
        XCTAssertNil(try descriptor(fields + "<certThumbprintList><hashAlgorithm>unknown</hashAlgorithm><thumbprint>\(sha256)</thumbprint></certThumbprintList>").certificatePin)
        XCTAssertNil(try descriptor(fields).certificatePin, "Missing pin requires system certificate validation")
        XCTAssertEqual(try descriptor("<url>wss://esxi.example.invalid/ticket/synthetic-ticket</url>").webSocketURL?.scheme, "wss")
        for invalid in ["<host>bad/target</host>", fields + "<sslThumbprint>bad</sslThumbprint>",
                        "<url>ws://esxi.example.invalid/ticket/synthetic-ticket</url>",
                        "<url>wss://user:password@esxi.example.invalid/ticket/synthetic-ticket</url>",
                        "<host>esxi.example.invalid</host><port>70000</port>",
                        fields + "<sslCertificate>not a certificate</sslCertificate>",
                        fields + "<certThumbprintList><thumbprint>bad</thumbprint></certThumbprintList>"] {
            XCTAssertThrowsError(try descriptor(invalid)) { error in
                XCTAssertFalse(error.localizedDescription.contains("synthetic-ticket"))
                XCTAssertFalse(error.localizedDescription.contains("esxi.example.invalid"))
            }
        }
    }

    @MainActor func testVMwareTicketURLTakesPrecedenceOverSeparateEndpointMetadata() throws {
        let sha256 = String(repeating: "a", count: 64)
        let xml = """
        <AcquireTicketResponse><returnval><ticket>synthetic-ticket</ticket>
        <host>legacy-route.example.invalid</host><port>902</port>
        <url>wss://console-route.example.invalid:443/ticket/synthetic-url-ticket</url>
        <certThumbprintList><hashAlgorithm>sha256</hashAlgorithm><thumbprint>\(sha256)</thumbprint></certThumbprintList>
        </returnval></AcquireTicketResponse>
        """
        let descriptor = try VMwareBackend.consoleDescriptor(VMXMLDocument.parse(Data(xml.utf8)), apiOrigin: URL(string: "https://vc.example.invalid")!)
        XCTAssertEqual(descriptor.webSocketURL?.host, "console-route.example.invalid")
        XCTAssertEqual(descriptor.webSocketURL?.port, 443)
        XCTAssertEqual(descriptor.webSocketURL?.path, "/ticket/synthetic-url-ticket")
        XCTAssertEqual(descriptor.certificatePin?.fingerprints, [sha256])
        XCTAssertTrue(descriptor.singleUseTicket)
    }

    @MainActor func testVMwareTicketFieldErrorsNeverRevealValues() throws {
        let origin = URL(string: "https://vc.example.invalid")!
        let fields: [(String, VMwareBackend.TicketField)] = [
            ("<ticket>bad&#10;synthetic-ticket</ticket><host>esxi.example.invalid</host>", .token),
            ("<ticket>synthetic-ticket</ticket><url>ws://esxi.example.invalid/ticket/private-token</url>", .url),
            ("<ticket>synthetic-ticket</ticket><host>bad/private-host</host>", .endpoint),
            ("<ticket>synthetic-ticket</ticket><host>esxi.example.invalid</host><certThumbprintList><thumbprint>private-invalid-hash</thumbprint></certThumbprintList>", .thumbprint),
            ("<ticket>synthetic-ticket</ticket><host>esxi.example.invalid</host><sslThumbprint>private-invalid-hash</sslThumbprint>", .legacyThumbprint),
            ("<ticket>synthetic-ticket</ticket><host>esxi.example.invalid</host><sslCertificate>private-invalid-pem</sslCertificate>", .certificate)
        ]
        for (body, field) in fields {
            let response = try VMXMLDocument.parse(Data("<AcquireTicketResponse><returnval>\(body)</returnval></AcquireTicketResponse>".utf8))
            XCTAssertThrowsError(try VMwareBackend.consoleDescriptor(response, apiOrigin: origin)) { error in
                let message = error.localizedDescription
                XCTAssertTrue(message.contains(field.rawValue))
                for forbidden in ["synthetic-ticket", "private-token", "esxi.example.invalid", "private-invalid", "private-host"] {
                    XCTAssertFalse(message.contains(forbidden))
                }
            }
        }
    }

    @MainActor func testVMwareStandaloneTicketCanOmitKnownEndpointButVCenterCannot() throws {
        let endpoint = URL(string: "https://standalone.example.invalid:8443/")!
        let response = try VMXMLDocument.parse(Data("<AcquireTicketResponse><returnval><ticket>synthetic-ticket</ticket></returnval></AcquireTicketResponse>".utf8))
        let descriptor = try VMwareBackend.consoleDescriptor(response, apiOrigin: endpoint, standaloneEndpoint: endpoint)
        XCTAssertEqual(descriptor.webSocketURL?.host, "standalone.example.invalid")
        XCTAssertEqual(descriptor.webSocketURL?.port, 8443)
        XCTAssertThrowsError(try VMwareBackend.consoleDescriptor(response, apiOrigin: URL(string: "https://vc.example.invalid")!))
        XCTAssertThrowsError(try VMwareBackend.consoleDescriptor(response, apiOrigin: endpoint, standaloneEndpoint: URL(string: "https://other.example.invalid")!))
    }

    func testVMwareCertificatePinsMatchOnlyExpectedDER() throws {
        let certificate = Data("synthetic-certificate-data".utf8)
        let hash = SHA256.hash(data: certificate).map { String(format: "%02x", $0) }.joined()
        let pin = VMConsoleCertificatePin(algorithm: .sha256, fingerprints: [hash])
        XCTAssertTrue(pin.matches(certificate)); XCTAssertFalse(pin.matches(Data("other-certificate".utf8)))
        XCTAssertEqual(VMConsoleCertificatePin.normalize(hash.uppercased(), algorithm: .sha256), hash)
        XCTAssertNil(VMConsoleCertificatePin.normalize("\n" + hash, algorithm: .sha256))
    }

    func testVMwareConsoleFailureMessagesAreSpecificAndRedacted() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: [
            NSLocalizedDescriptionKey: "private-password synthetic-ticket esxi.example.invalid",
            NSURLErrorFailingURLErrorKey: URL(string: "wss://esxi.example.invalid/ticket/synthetic-ticket")!
        ])
        XCTAssertTrue(VMConsoleTrustResult.pinMismatch.failureMessage(error).contains("does not match"))
        XCTAssertTrue(VMConsoleTrustResult.pinVerified.failureMessage(error).contains("matched"))
        XCTAssertFalse(VMConsoleTrustResult.notChallenged.failureMessage(error).contains("certificate"), "Cancellation is not proof of certificate rejection")
        XCTAssertTrue(VMConsoleTrustResult.unexpectedAuthentication.failureMessage(error).contains("HTTP authentication"))
        XCTAssertTrue(VMConsoleTrustResult.redirectRejected.failureMessage(error).contains("redirected"))
        let tls = NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed)
        XCTAssertTrue(VMConsoleTrustResult.notChallenged.failureMessage(tls).contains("before a certificate"))
        XCTAssertTrue(VMConsoleTrustResult.systemTrust.failureMessage(tls).contains("no supported certificate identity"))
        for result: VMConsoleTrustResult in [.notChallenged, .systemTrust, .pinVerified, .pinMismatch, .endpointMismatch,
                                           .missingCertificate, .unexpectedAuthentication, .redirectRejected] {
            let message = result.failureMessage(error)
            XCTAssertTrue(message.contains("network code -999"))
            XCTAssertFalse(message.contains("private-password")); XCTAssertFalse(message.contains("synthetic-ticket"))
            XCTAssertFalse(message.contains("esxi.example.invalid")); XCTAssertFalse(message.contains("wss://"))
        }
        XCTAssertFalse(VMConsoleTrustResult.notChallenged.failureMessage(NSError(domain: "untrusted-server-text", code: -1200)).contains("TLS handshake"))
    }

    @MainActor func testWebMKSTLSAcceptsLegacyAndOmittedAlgorithmPins() async throws {
        let identity = try await Task.detached { try MockTLSIdentity() }.value
        let sha1 = Insecure.SHA1.hash(data: identity.der).map { String(format: "%02x", $0) }.joined(separator: ":")
        for fields in ["<sslThumbprint>\(sha1)</sslThumbprint>",
                       "<certThumbprintList><thumbprint>\(identity.sha256)</thumbprint></certThumbprintList>"] {
            let server = try MockVNCServer(tls: identity.identity, webSocket: true)
            defer { server.stop() }
            let started = expectation(description: "Legacy ticket TLS server listening")
            server.start { started.fulfill() }
            await fulfillment(of: [started], timeout: 5)
            let port = try XCTUnwrap(server.listener.port).rawValue
            let response = try VMXMLDocument.parse(Data("<AcquireTicketResponse><returnval><ticket>synthetic-ticket</ticket><host>localhost</host><port>\(port)</port>\(fields)</returnval></AcquireTicketResponse>".utf8))
            let descriptor = try VMwareBackend.consoleDescriptor(response, apiOrigin: URL(string: "https://vc.example.invalid")!)
            let url = try XCTUnwrap(descriptor.webSocketURL)
            XCTAssertEqual(url.scheme, "wss")
            let transport = try VMConsoleTicketTLS(descriptor: descriptor)
            defer { transport.connection.cancel() }
            let probe = MockTicketProbe()
            let received = expectation(description: "Native ticket transport received RFB greeting")
            probe.start(transport) { received.fulfill() }
            await fulfillment(of: [received], timeout: 5)
            XCTAssertNil(probe.error)
            XCTAssertEqual(String(data: probe.data ?? Data(), encoding: .utf8), "RFB 003.008\n")
            XCTAssertTrue(transport.failureMessage(nil).contains("matched"))
        }
    }

    @MainActor func testVMwareConsoleTLSIsolationAndRedirectRejection() throws {
        let configuration = URLSessionConfiguration.ephemeral
        let url = URL(string: "wss://esxi.example.invalid/ticket/synthetic-ticket")!
        let http = try VirtualizationHTTP(consoleURL: url, certificatePin: nil, configuration: configuration)
        defer { http.close() }
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://esxi.example.invalid/")!)
        let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil)!
        var allowed = true
        http.urlSession(session, task: task, willPerformHTTPRedirection: response,
                        newRequest: URLRequest(url: URL(string: "https://esxi.example.invalid/redirect")!)) { allowed = $0 != nil }
        XCTAssertFalse(allowed, "Single-use console tickets cannot follow even same-origin redirects")
        XCTAssertTrue(http.consoleFailureMessage(nil).contains("redirected"))
        let space = URLProtectionSpace(host: "esxi.example.invalid", port: 443, protocol: "https", realm: nil,
                                       authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: 0,
                                                  failureResponse: nil, error: nil, sender: MockChallengeSender())
        http.urlSession(session, task: task, didReceive: challenge) { disposition, credential in
            XCTAssertEqual(disposition, .cancelAuthenticationChallenge)
            XCTAssertNil(credential)
        }
        XCTAssertTrue(http.consoleFailureMessage(nil).contains("HTTP authentication"))
        XCTAssertThrowsError(try VirtualizationHTTP(consoleURL: URL(string: "ws://esxi.example.invalid/ticket/test")!, certificatePin: nil))
    }

    @MainActor func testWebMKSTicketConsoleOverPinnedTLSAndCtrlAltDel() async throws {
        let identity = try await Task.detached { try MockTLSIdentity() }.value
        let server = try MockVNCServer(tls: identity.identity, webSocket: true)
        defer { server.stop() }
        let started = expectation(description: "Synthetic encrypted WebMKS server listening")
        server.start { started.fulfill() }
        await fulfillment(of: [started], timeout: 5)
        let port = try XCTUnwrap(server.listener.port).rawValue
        let response = try VMXMLDocument.parse(Data("""
        <AcquireTicketResponse><returnval><ticket>synthetic-ticket</ticket><host>legacy-route.example.invalid</host><port>902</port>
        <url>wss://localhost:\(port)/ticket/synthetic-ticket</url>
        <certThumbprintList><hashAlgorithm>sha256</hashAlgorithm><thumbprint>\(identity.sha256)</thumbprint></certThumbprintList>
        </returnval></AcquireTicketResponse>
        """.utf8))
        let descriptor = try VMwareBackend.consoleDescriptor(response, apiOrigin: URL(string: "https://vc.example.invalid")!)
        let bridge = VMConsoleWebBridge()
        let connected = expectation(description: "Ticket-authorized console initialized in bundled noVNC")
        bridge.onState = { value in
            if value == "connected" { connected.fulfill() }
            else { XCTFail("Synthetic WebMKS connection failed") }
        }
        bridge.onError = { _ in XCTFail("Synthetic pinned TLS connection was rejected") }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(VMConsoleAssets(root: try XCTUnwrap(Bundle.main.resourceURL?.appendingPathComponent("Consoles"))), forURLScheme: "nethriva-console")
        config.userContentController.add(bridge, name: "vmConsole")
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        let window = NSWindow(contentRect: webView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = webView; bridge.webView = webView; webView.navigationDelegate = bridge
        let http = try VirtualizationHTTP(connection: RemoteConnection(name: "Mock", kind: .virtualization, host: "vc.example.invalid", port: 443))
        defer {
            bridge.stop(); http.close(); webView.navigationDelegate = nil
            config.userContentController.removeScriptMessageHandler(forName: "vmConsole"); window.contentView = nil
        }
        bridge.configure(descriptor, http: http, options: ["fit": true, "viewOnly": false, "clipboard": false])
        webView.load(URLRequest(url: URL(string: "nethriva-console://bundle/console.html")!))
        await fulfillment(of: [connected], timeout: 10)
        XCTAssertTrue(server.upgradeRequest.hasPrefix("GET /ticket/synthetic-ticket HTTP/1.1"))
        XCTAssertTrue(server.upgradeRequest.lowercased().contains("sec-websocket-protocol: binary"))
        XCTAssertFalse(server.upgradeRequest.lowercased().contains("cookie:"))
        XCTAssertFalse(server.upgradeRequest.lowercased().contains("authorization:"))
        var pixel: [Int] = []
        for _ in 0..<20 {
            pixel = try await webView.evaluateJavaScript("Array.from(document.querySelector('#screen canvas').getContext('2d').getImageData(0,0,1,1).data)") as? [Int] ?? []
            if pixel == [32, 128, 224, 255] { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(pixel, [32, 128, 224, 255], "Framebuffers must render over the encrypted WebMKS transport")
        let visible = try await webView.evaluateJavaScript("""
        (() => {
            const canvas = document.querySelector('#screen canvas');
            const rect = canvas.getBoundingClientRect();
            return rect.width > 0 && rect.height > 0 && rect.top < innerHeight && rect.bottom > 0 &&
                   rect.left < innerWidth && rect.right > 0;
        })()
        """) as? Bool
        XCTAssertEqual(visible, true, "Decoded pixels are insufficient: the VNC canvas must be visible in the tab, not below a full-height SPICE placeholder")
        let placeholderHidden = try await webView.evaluateJavaScript("document.getElementById('spice-screen').hidden") as? Bool
        XCTAssertEqual(placeholderHidden, true)
        window.setContentSize(NSSize(width: 320, height: 240))
        let fitted = try await webView.callAsyncJavaScript("""
        await new Promise(resolve => setTimeout(resolve, 50));
        window.consoleAction('fit', false);
        window.consoleAction('fit', true);
        const canvas = document.querySelector('#screen canvas');
        const rect = canvas.getBoundingClientRect();
        return rect.width > 0 && rect.height > 0 && rect.width <= innerWidth + 1 && rect.height <= innerHeight + 1 &&
               Math.abs(rect.width / rect.height - 640 / 480) < 0.01 && canvas.width === 640 && canvas.height === 480;
        """, arguments: [:], in: nil, contentWorld: .page) as? Bool
        XCTAssertEqual(fitted, true, "Fit must scale to the available tab, preserve proportions, and leave guest resolution unchanged")
        let delete = expectation(description: "Ctrl Alt Delete reached encrypted VMware-style transport")
        server.onDelete = { delete.fulfill() }; bridge.action("cad")
        await fulfillment(of: [delete], timeout: 5)
        // Ticket endpoints are held only by Swift; never exposed in page navigation/config.
        XCTAssertEqual(webView.url?.scheme, "nethriva-console")
        let pageContainsTicket = try await webView.evaluateJavaScript("document.documentElement.outerHTML.includes('synthetic-ticket') || location.href.includes('synthetic-ticket')") as? Bool
        XCTAssertEqual(pageContainsTicket, false)
    }

    @MainActor func testWebMKSTLSRejectsWrongTicketCertificate() async throws {
        let identity = try await Task.detached { try MockTLSIdentity() }.value
        let server = try MockVNCServer(tls: identity.identity, webSocket: true)
        defer { server.stop() }
        let started = expectation(description: "TLS rejection server listening")
        server.start { started.fulfill() }
        await fulfillment(of: [started], timeout: 5)
        let port = try XCTUnwrap(server.listener.port).rawValue
        let url = URL(string: "wss://127.0.0.1:\(port)/ticket/synthetic-ticket")!
        let transport = try VMConsoleTicketTLS(descriptor: .init(renderer: .vnc, webSocketURL: url,
            certificatePin: .init(algorithm: .sha256, fingerprints: [String(repeating: "a", count: 64)]), singleUseTicket: true))
        defer { transport.connection.cancel() }
        let probe = MockTicketProbe(), rejected = expectation(description: "Native ticket rejects wrong certificate")
        probe.start(transport) { rejected.fulfill() }
        await fulfillment(of: [rejected], timeout: 5)
        XCTAssertNotNil(probe.error)
        XCTAssertTrue(server.upgradeRequest.isEmpty, "No ticket may be sent before its certificate is verified")
        XCTAssertTrue(transport.failureMessage(probe.error).contains("does not match"))
    }

    @MainActor func testWebMKSTLSWithoutPinRequiresSystemTrust() async throws {
        let identity = try await Task.detached { try MockTLSIdentity() }.value
        let server = try MockVNCServer(tls: identity.identity, webSocket: true)
        defer { server.stop() }
        let started = expectation(description: "Untrusted console TLS server listening")
        server.start { started.fulfill() }
        await fulfillment(of: [started], timeout: 5)
        let port = try XCTUnwrap(server.listener.port).rawValue
        let url = URL(string: "wss://127.0.0.1:\(port)/ticket/synthetic-ticket")!
        let transport = try VMConsoleTicketTLS(descriptor: .init(renderer: .vnc, webSocketURL: url, singleUseTicket: true))
        defer { transport.connection.cancel() }
        let probe = MockTicketProbe(), rejected = expectation(description: "Native ticket requires system trust without pin")
        probe.start(transport) { rejected.fulfill() }
        await fulfillment(of: [rejected], timeout: 5)
        XCTAssertNotNil(probe.error)
        XCTAssertTrue(server.upgradeRequest.isEmpty)
        XCTAssertTrue(transport.failureMessage(probe.error).contains("no supported certificate identity"))
    }

    @MainActor func testNativeWebMKSTransportRejectsRedirectsAndGlobalATSExceptions() async throws {
        let ats = Bundle.main.infoDictionary?["NSAppTransportSecurity"] as? [String: Any]
        XCTAssertNotEqual(ats?["NSAllowsArbitraryLoads"] as? Bool, true)
        let identity = try await Task.detached { try MockTLSIdentity() }.value
        let server = try MockVNCServer(tls: identity.identity, webSocket: true, redirect: true)
        defer { server.stop() }
        let started = expectation(description: "Redirecting TLS console listening")
        server.start { started.fulfill() }
        await fulfillment(of: [started], timeout: 5)
        let port = try XCTUnwrap(server.listener.port).rawValue
        let transport = try VMConsoleTicketTLS(descriptor: .init(renderer: .vnc,
            webSocketURL: URL(string: "wss://localhost:\(port)/ticket/synthetic-ticket")!,
            certificatePin: .init(algorithm: .sha256, fingerprints: [identity.sha256]), singleUseTicket: true,
            headers: ["Origin": "https://vc.example.invalid", "Cookie": "must-not-send", "Authorization": "must-not-send"]))
        defer { transport.connection.cancel() }
        let probe = MockTicketProbe(), rejected = expectation(description: "Native WebSocket refuses redirects")
        probe.start(transport) { rejected.fulfill() }
        await fulfillment(of: [rejected], timeout: 5)
        XCTAssertNotNil(probe.error)
        XCTAssertEqual(server.acceptedConnections, 1)
        XCTAssertTrue(server.upgradeRequest.hasPrefix("GET /ticket/synthetic-ticket "))
        XCTAssertFalse(server.upgradeRequest.lowercased().contains("cookie:"))
        XCTAssertFalse(server.upgradeRequest.lowercased().contains("authorization:"))
        XCTAssertTrue(server.upgradeRequest.contains("https://vc.example.invalid"))
    }

    @MainActor func testNutanixInventoryUsesReportedPowerState() throws {
        let entries: [[String: Any]] = [[
            "metadata": ["uuid": "11111111-1111-4111-8111-111111111111"],
            "spec": ["name": "Desired", "resources": ["power_state": "OFF"]],
            "status": ["name": "Reported", "resources": ["power_state": "ON"]]
        ]]
        let vm = try XCTUnwrap(RESTVirtualizationBackend.nutanixMachines(entries).first)
        XCTAssertEqual(vm.name, "Reported"); XCTAssertEqual(vm.state, .running)
        XCTAssertThrowsError(try RESTVirtualizationBackend.nutanixMachines([[:]]))
    }

    func testVMConsoleSettingsSurviveCredentialFreeArchive() throws {
        var host = RemoteConnection(name: "Test host", kind: .ssh, host: "host.example.test", port: 22)
        host.group = "Lab/Hosts"
        var console = RemoteConnection(name: "Test console", kind: .vnc, host: "127.0.0.1", port: 5901)
        console.virtualization = VirtualizationConfiguration(consoleTransport: .tcp, tunnelConnectionID: host.id,
                                                            viewOnly: true, shareClipboard: false)
        let archive = ConnectionArchive(groups: ["Lab/Hosts"], connections: [host, console], credentials: [])
        let data = try ConnectionTransferService.encodePlain(archive)
        guard case .plain(let decoded) = try ConnectionTransferService.inspect(data).content else {
            return XCTFail("Expected a credential-free console archive")
        }
        XCTAssertEqual(decoded.connections.last?.virtualization, console.virtualization)
        XCTAssertTrue(decoded.credentials.isEmpty)
    }
}

/// Entirely synthetic SOAP transport; never contacts a private host or logs passwords.
    private final class MockVMwareProtocol: URLProtocol {
    static let viewReference = "session[11111111-1111-4111-8111-111111111111]22222222-2222-4222-8222-222222222222"
    static let fixture = Fixture()

    final class Fixture: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [(method: String, body: String)] = []
        private var loginFault = false
        private var recordedActions: [String] = []
        var calls: [(method: String, body: String)] { lock.withLock { recorded } }
        var actions: [String] { lock.withLock { recordedActions } }
        func reset(loginFault: Bool = false) {
            lock.withLock { recorded = []; recordedActions = []; self.loginFault = loginFault }
        }
        func record(_ method: String, _ body: String, action: String) -> Bool {
            lock.withLock {
                // Avoid retaining the synthetic login password even in test diagnostics.
                recorded.append((method, method == "Login" ? "" : body))
                recordedActions.append(action)
                return loginFault
            }
        }
    }

    static func envelope(_ method: String, _ body: String) -> String {
        "<soap:Envelope xmlns:soap='http://schemas.xmlsoap.org/soap/envelope/'><soap:Body><\(method)Response xmlns='urn:vim25'>\(body)</\(method)Response></soap:Body></soap:Envelope>"
    }
    static func fault(_ type: String) -> String {
        "<soap:Envelope xmlns:soap='http://schemas.xmlsoap.org/soap/envelope/' xmlns:xsi='http://www.w3.org/2001/XMLSchema-instance'><soap:Body><soap:Fault><faultcode>ServerFaultCode</faultcode><faultstring>private-fixture-detail</faultstring><detail><fault xsi:type='\(type)'/></detail></soap:Fault></soap:Body></soap:Envelope>"
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "vmware.example.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count >= 0 else { throw URLError(.cannotDecodeContentData) }
                    if count == 0 { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
            }
            let root = try VMXMLDocument.parse(body)
            let method = root.child("Body")?.children.first?.name ?? ""
            let loginFault = Self.fixture.record(method, String(data: body, encoding: .utf8) ?? "", action: request.value(forHTTPHeaderField: "SOAPAction") ?? "")
            let result: String
            var status = 200
            switch method {
            case "RetrieveServiceContent":
                result = Self.envelope(method, """
                <returnval><sessionManager type='SessionManager'>ha-sessionmgr</sessionManager>
                <propertyCollector type='PropertyCollector'>ha-property-collector</propertyCollector>
                <viewManager type='ViewManager'>ha-viewmgr</viewManager><rootFolder type='Folder'>ha-folder-root</rootFolder>
                <about><apiType>HostAgent</apiType><apiVersion>8.0.3.0</apiVersion></about></returnval>
                """)
            case "Login" where loginFault: result = Self.fault("InvalidLoginFault"); status = 500
            case "Login": result = Self.envelope(method, "<returnval><key>synthetic-session</key></returnval>")
            case "CreateContainerView": result = Self.envelope(method, "<returnval type='ContainerView'>\(Self.viewReference)</returnval>")
            case "AcquireTicket":
                result = Self.envelope(method, "<returnval><ticket>synthetic-ticket</ticket><host>esxi.example.invalid</host><port>443</port><sslThumbprint>\(String(repeating: "a", count: 40))</sslThumbprint></returnval>")
            case "RetrievePropertiesEx":
                result = Self.envelope(method, """
                <returnval><objects><obj type='VirtualMachine'>ha-vm-101</obj>
                <propSet><name>name</name><val>Test Guest</val></propSet>
                <propSet><name>runtime.powerState</name><val>poweredOn</val></propSet></objects></returnval>
                """)
            case "DestroyView": result = Self.envelope(method, "")
            default: throw URLError(.unsupportedURL)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/xml"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(result.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor private final class ConsoleReadyHandler: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let expectation: XCTestExpectation
    init(expectation: XCTestExpectation) { self.expectation = expectation }
    private(set) var ready = false
    private(set) var navigationFailure: String?
    private var completed = false
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !completed, (message.body as? [String: Any])?["kind"] as? String == "ready" else { return }
        ready = true; complete()
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failNavigation(error.localizedDescription)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failNavigation(error.localizedDescription)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        failNavigation("Console WebContent process terminated before module readiness")
    }
    private func failNavigation(_ message: String) {
        guard !completed else { return }; navigationFailure = message; complete()
    }
    private func complete() {
        guard !completed else { return }; completed = true; expectation.fulfill()
    }
}

/// Local, unauthenticated synthetic RFB server: no guest OS, private host, or real credentials.
private final class MockTicketProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var resultData: Data?
    private var resultError: Error?
    var data: Data? { lock.withLock { resultData } }
    var error: Error? { lock.withLock { resultError } }
    func start(_ transport: VMConsoleTicketTLS, done: @escaping @Sendable () -> Void) {
        let connection = transport.connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                connection.stateUpdateHandler = nil
                connection.receiveMessage { [weak self] data, _, _, error in self?.finish(data, error, done) }
            case .failed(let error), .waiting(let error): connection.stateUpdateHandler = nil; self.finish(nil, error, done)
            default: break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
    }
    private func finish(_ data: Data?, _ error: Error?, _ done: () -> Void) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true; resultData = data; resultError = error
        lock.unlock(); done()
    }
}

private final class MockVNCServer: @unchecked Sendable {
    let listener: NWListener
    var onDelete: (() -> Void)?
    private let queue = DispatchQueue(label: "test.vnc")
    private var connection: NWConnection?
    private var input = Data()
    private var stage = 0
    private var reportedDelete = false
    private let webSocket: Bool
    private let redirect: Bool
    private var upgraded = false
    private var frameInput = Data()
    private let lock = NSLock()
    private var requestText = ""
    private var connectionCount = 0
    var upgradeRequest: String { lock.withLock { requestText } }
    var acceptedConnections: Int { lock.withLock { connectionCount } }
    init(tls: sec_identity_t? = nil, webSocket: Bool = false, redirect: Bool = false) throws {
        self.webSocket = webSocket
        self.redirect = redirect
        let parameters: NWParameters
        if let tls {
            let options = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(options.securityProtocolOptions, tls)
            parameters = NWParameters(tls: options, tcp: NWProtocolTCP.Options())
        } else { parameters = .tcp }
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start(ready: @escaping () -> Void) {
        listener.stateUpdateHandler = { state in if case .ready = state { ready() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.lock.withLock { self.connectionCount += 1 }
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                if case .ready = state {
                    if self?.webSocket == false { self?.write(Data("RFB 003.008\n".utf8)) }
                    self?.receive()
                }
            }
            connection.start(queue: queue)
        }
        listener.start(queue: queue)
    }
    private func write(_ data: Data) {
        var framed = Data([0x82])
        if data.count < 126 { framed.append(UInt8(data.count)) }
        else { framed += Data([126, UInt8(data.count >> 8), UInt8(data.count & 255)]) }
        connection?.send(content: webSocket ? framed + data : data, completion: .contentProcessed { _ in })
    }
    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] bytes, _, done, error in
            guard let self else { return }
            if let bytes {
                if webSocket { frameInput += bytes; consumeWebSocket() }
                else { input += bytes; consume() }
            }
            if !done && error == nil { receive() }
        }
    }
    private func consumeWebSocket() {
        if !upgraded {
            guard let end = frameInput.range(of: Data("\r\n\r\n".utf8)),
                  let text = String(data: frameInput.prefix(end.upperBound), encoding: .utf8) else { return }
            let key = text.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("sec-websocket-key:") }?
                .components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces) ?? ""
            guard !key.isEmpty else { return }
            lock.withLock { requestText = text }
            if redirect {
                let location = "https://localhost:\(listener.port!.rawValue)/redirect"
                connection?.send(content: Data("HTTP/1.1 302 Found\r\nLocation: \(location)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { [weak self] _ in self?.connection?.cancel() })
                frameInput.removeAll(); return
            }
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\nSec-WebSocket-Protocol: binary\r\n\r\n"
            connection?.send(content: Data(response.utf8), completion: .contentProcessed { _ in })
            frameInput.removeSubrange(..<end.upperBound); upgraded = true
            write(Data("RFB 003.008\n".utf8))
        }
        while frameInput.count >= 2 {
            let bytes = [UInt8](frameInput)
            let opcode = bytes[0] & 15, masked = bytes[1] & 128 != 0
            var count = Int(bytes[1] & 127), offset = 2
            if count == 126 {
                guard bytes.count >= 4 else { return }
                count = Int(bytes[2]) * 256 + Int(bytes[3]); offset = 4
            } else if count == 127 { stop(); return }
            let maskOffset = offset
            if masked { offset += 4 }
            guard count <= 65536, bytes.count >= offset + count else { return }
            var payload = Array(bytes[offset..<(offset + count)])
            if masked { for index in payload.indices { payload[index] ^= bytes[maskOffset + index % 4] } }
            frameInput.removeFirst(offset + count)
            if opcode == 8 { return }
            if opcode == 2 || opcode == 0 { input += Data(payload); consume() }
        }
    }
    private func consume() {
        if stage == 0 && input.count >= 12 { input.removeFirst(12); stage = 1; write(Data([1, 1])) }
        if stage == 1 && !input.isEmpty { input.removeFirst(); stage = 2; write(Data([0, 0, 0, 0])) }
        if stage == 2 && !input.isEmpty {
            input.removeFirst(); stage = 3
            var header = Data([2, 128, 1, 224, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])
            let name = Data("Test VM".utf8)
            header += Data([0, 0, 0, UInt8(name.count)]); header += name; write(header)
            if webSocket {
                // Raw framebuffer rectangle followed by VMware's alpha-cursor pseudo-encoding.
                write(Data([0, 0, 0, 2,
                            0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 32, 128, 224, 0,
                            0, 0, 0, 0, 0, 1, 0, 1, 0x57, 0x4d, 0x56, 0x64, 1, 0, 255, 0, 0, 255]))
            }
        }
        if stage == 3, !reportedDelete, input.range(of: Data([4, 1, 0, 0, 0, 0, 255, 255])) != nil {
            reportedDelete = true; onDelete?()
        }
    }
    func stop() { listener.cancel(); connection?.cancel() }
}

/// A throwaway test identity generated locally, never checked in or used on a real server.
private final class MockChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}

private final class MockTLSIdentity: @unchecked Sendable {
    let identity: sec_identity_t
    let der: Data
    let sha256: String
    init() throws {
        guard #available(macOS 15, *) else {
            throw XCTSkip("Memory-only PKCS#12 test identity import requires macOS 15; do not modify the user's Keychain")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Nethriva-TLS-Test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        func openssl(_ arguments: [String]) throws {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            process.arguments = arguments; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw VirtualizationError.message("Synthetic TLS fixture generation failed") }
        }
        let key = folder.appendingPathComponent("key.pem").path, cert = folder.appendingPathComponent("cert.pem").path
        let p12 = folder.appendingPathComponent("identity.p12")
        try openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert, "-days", "1", "-subj", "/CN=localhost", "-sha256"])
        try openssl(["pkcs12", "-export", "-inkey", key, "-in", cert, "-out", p12.path, "-passout", "pass:unit-test-placeholder"])
        var imported: CFArray?
        let status = SecPKCS12Import(try Data(contentsOf: p12) as CFData,
                                    [kSecImportExportPassphrase as String: "unit-test-placeholder",
                                     kSecImportToMemoryOnly as String: true] as CFDictionary, &imported)
        guard status == errSecSuccess, let item = (imported as? [[String: Any]])?.first,
              let value = item[kSecImportItemIdentity as String] else { throw VirtualizationError.unavailable }
        let importedIdentity = value as! SecIdentity
        guard let identity = sec_identity_create(importedIdentity) else { throw VirtualizationError.unavailable }
        self.identity = identity
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(importedIdentity, &certificate) == errSecSuccess, let certificate else { throw VirtualizationError.unavailable }
        der = SecCertificateCopyData(certificate) as Data
        sha256 = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }
}
