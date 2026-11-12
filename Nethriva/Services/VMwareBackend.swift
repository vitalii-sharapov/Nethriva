import Foundation
import CryptoKit
import Security

/// The stable vSphere SOAP API supports both stand-alone ESXi and vCenter.
@MainActor
final class VMwareBackend: VirtualizationBackend {
    var taskProgress: ((VMTaskProgress) -> Void)?
    var supportsSnapshots: Bool { true }
    enum TicketField: String {
        case token = "ticket token"
        case url = "WebSocket URL"
        case endpoint = "host/port endpoint"
        case thumbprint = "certificate thumbprint list"
        case legacyThumbprint = "legacy certificate thumbprint"
        case certificate = "PEM certificate"
        case origin = "API origin"
    }
    let connection: RemoteConnection
    let http: VirtualizationHTTP
    private let password: String
    private var managers: [String: String] = [:]
    private var authenticated = false
    private var apiVersion = "6.5"
    private var isStandaloneESXi = false

    init(connection: RemoteConnection, password: String?, http: VirtualizationHTTP? = nil) throws {
        self.connection = connection
        self.password = password ?? ""
        self.http = try http ?? VirtualizationHTTP(connection: connection)
    }

    private func call(_ method: String, _ body: String, assertion: String? = nil) async throws -> VMXMLNode {
        let security = assertion.map { "<soapenv:Header><wsse:Security xmlns:wsse=\"http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd\">\($0)</wsse:Security></soapenv:Header>" } ?? ""
        let envelope = """
        <?xml version="1.0" encoding="UTF-8"?>
        <soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          \(security)<soapenv:Body><\(method) xmlns="urn:vim25">\(body)</\(method)></soapenv:Body>
        </soapenv:Envelope>
        """
        let data = try await http.request("/sdk", method: "POST",
            headers: ["Content-Type": "text/xml; charset=utf-8", "Accept": "text/xml", "SOAPAction": "\"urn:vim25/\(apiVersion)\""],
            body: Data(envelope.utf8), acceptedErrorStatuses: [500])
        return try await BackgroundWork.run { try Self.parseResponse(data, method: method) }
    }

    nonisolated static func parseResponse(_ data: Data, method: String) throws -> VMXMLNode {
        let root: VMXMLNode
        do { root = try VMXMLDocument.parse(data) }
        catch {
            throw VirtualizationError.message("VMware returned unreadable SOAP XML during \(method). Confirm the ESXi/vCenter API endpoint and server version.")
        }
        if let fault = root.descendants("Fault").first {
            // Only use recognized fault types; arbitrary fault messages may contain
            // account names, object identifiers, or other private host information.
            let details = fault.descendants("detail").flatMap(\.children)
            let types = details.flatMap { [$0.name] + $0.attributes.values.map { $0.components(separatedBy: ":").last ?? $0 } }
            if types.contains(where: { $0 == "InvalidLogin" || $0 == "InvalidLoginFault" }) {
                throw VirtualizationError.authentication
            }
            if types.contains(where: { $0 == "NoPermission" || $0 == "NoPermissionFault" }) {
                throw VirtualizationError.forbidden
            }
            if types.contains(where: { $0 == "NotAuthenticated" || $0 == "NotAuthenticatedFault" }) {
                throw VirtualizationError.message("The VMware API session expired or was not retained during \(method). Reconnect to the host.")
            }
            throw VirtualizationError.message("VMware rejected \(method). Check the host task, account privileges, and API support.")
        }
        guard let response = (root.name == method + "Response" ? root : root.descendants(method + "Response").first) else {
            throw VirtualizationError.message("VMware returned no \(method)Response. Confirm the selected platform and that the address exposes the ESXi/vCenter SOAP API.")
        }
        return response
    }

    nonisolated static func isManagedReference(_ value: String) -> Bool {
        // VMware's session-scoped views use session[UUID]UUID, not a plain VM ID.
        // Keep a VMware-specific allowlist rather than weakening other platforms.
        !value.isEmpty && value.count <= 512
            && value.rangeOfCharacter(from: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_:.[]")).inverted) == nil
    }

    nonisolated static func managedReference(_ node: VMXMLNode?, operation: String) throws -> String {
        guard let value = node?.text, isManagedReference(value) else {
            throw VirtualizationError.message("VMware returned an invalid object reference during \(operation). Check host API compatibility.")
        }
        return value
    }

    private func authenticate() async throws {
        guard !authenticated else { return }
        let assertion = VMwareFederation.shared.assertion(for: connection)
        if connection.virtualization?.federation != nil, assertion == nil {
            throw VirtualizationError.message("Use Federated Sign In in the host inventory for a fresh API authorization. Password fallback is disabled for a federated connection.")
        }
        guard assertion != nil || (!connection.username.isEmpty && !password.isEmpty) else { throw VirtualizationError.authentication }
        let service = try await call("RetrieveServiceContent", "<_this type=\"ServiceInstance\">ServiceInstance</_this>")
        guard let content = service.child("returnval") else {
            throw VirtualizationError.message("VMware returned no service information during RetrieveServiceContent.")
        }
        isStandaloneESXi = content.child("about")?.child("apiType")?.text == "HostAgent"
        for name in ["sessionManager", "propertyCollector", "viewManager", "rootFolder"] {
            managers[name] = try Self.managedReference(content.child(name), operation: "RetrieveServiceContent (\(name))")
        }
        // Negotiate the host's schema so newer ticket thumbprint/PEM fields are returned.
        if let version = content.child("about")?.child("apiVersion")?.text {
            let pieces = version.split(separator: ".", omittingEmptySubsequences: false)
            if (2...5).contains(pieces.count), pieces.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.allSatisfy { "0123456789".contains($0) } }) {
                apiVersion = version
            }
        }
        if let assertion {
            guard !isStandaloneESXi else { throw VirtualizationError.message("Federated login is a vCenter feature. Use a local ESXi account for stand-alone hosts.") }
            _ = try await call("LoginByToken", "<_this type=\"SessionManager\">\(VMInput.xml(managers["sessionManager"]!))</_this>", assertion: assertion)
        } else {
            _ = try await call("Login", """
        <_this type="SessionManager">\(VMInput.xml(managers["sessionManager"]!))</_this>
        <userName>\(VMInput.xml(connection.username))</userName><password>\(VMInput.xml(password))</password>
        """)
        }
        authenticated = true
    }

    func machines() async throws -> [VirtualMachine] {
        try await authenticate()
        let response = try await call("CreateContainerView", """
        <_this type="ViewManager">\(managers["viewManager"]!)</_this>
        <container type="Folder">\(managers["rootFolder"]!)</container><type>VirtualMachine</type><recursive>true</recursive>
        """)
        let view = try Self.managedReference(response.child("returnval"), operation: "CreateContainerView")
        do {
            let properties = try await call("RetrievePropertiesEx", """
            <_this type="PropertyCollector">\(managers["propertyCollector"]!)</_this><specSet>
            <propSet><type>VirtualMachine</type><all>false</all><pathSet>name</pathSet>
            <pathSet>runtime.powerState</pathSet><pathSet>guest.toolsRunningStatus</pathSet><pathSet>config.hardware.device</pathSet>
            <pathSet>guest.ipAddress</pathSet><pathSet>guest.net</pathSet><pathSet>config.guestFullName</pathSet>
            <pathSet>config.hardware.numCPU</pathSet><pathSet>config.hardware.memoryMB</pathSet><pathSet>runtime.host</pathSet></propSet>
            <objectSet><obj type="ContainerView">\(VMInput.xml(view))</obj><skip>true</skip>
            <selectSet xsi:type="TraversalSpec"><name>viewTraversal</name><type>ContainerView</type><path>view</path><skip>false</skip></selectSet>
            </objectSet></specSet><options><maxObjects>500</maxObjects></options>
            """)
            var result = try await BackgroundWork.run { try Self.parseMachines(properties) }
            var token = properties.child("returnval")?.child("token")?.text
            while let current = token, !current.isEmpty, result.count < 100_000 {
                try Task.checkCancellation()
                let page = try await call("ContinueRetrievePropertiesEx", """
                <_this type="PropertyCollector">\(managers["propertyCollector"]!)</_this><token>\(VMInput.xml(current))</token>
                """)
                result += try await BackgroundWork.run { try Self.parseMachines(page) }
                token = page.child("returnval")?.child("token")?.text
            }
            _ = try? await call("DestroyView", "<_this type=\"ContainerView\">\(VMInput.xml(view))</_this>")
            return result
        } catch {
            _ = try? await call("DestroyView", "<_this type=\"ContainerView\">\(VMInput.xml(view))</_this>")
            throw error
        }
    }

    nonisolated static func parseMachines(_ root: VMXMLNode) throws -> [VirtualMachine] {
        try root.descendants("objects").map { object in
            let id = try managedReference(object.child("obj"), operation: "RetrievePropertiesEx")
            var values: [String: VMXMLNode] = [:]
            for property in object.children where property.name == "propSet" {
                if let name = property.child("name")?.text { values[name] = property.child("val") }
            }
            let cdrom = values["config.hardware.device"]?.children.first {
                $0.attributes.values.contains(where: { $0.hasSuffix("VirtualCdrom") })
            }
            let key = cdrom?.child("key")?.text
            let controller = cdrom?.child("controllerKey")?.text ?? ""
            let unit = cdrom?.child("unitNumber")?.text ?? ""
            return VirtualMachine(id: id, name: values["name"]?.text ?? "VM",
                node: values["runtime.host"]?.text ?? "",
                state: .parse(values["runtime.powerState"]?.text ?? ""),
                guestTools: values["guest.toolsRunningStatus"]?.text ?? "Not reported",
                cdromDevice: key.map { "\($0)|\(controller)|\(unit)" },
                guestIPs: VMGuestAddress.usable(([values["guest.ipAddress"]?.text].compactMap { $0 })
                    + (values["guest.net"]?.descendants("ipAddress").map(\.text) ?? [])),
                operatingSystem: values["config.guestFullName"]?.text ?? "Not reported",
                cpuCount: VMGuestAddress.cpu(values["config.hardware.numCPU"].flatMap { Int($0.text) }),
                memoryMiB: VMGuestAddress.memoryMiB(values["config.hardware.memoryMB"].flatMap { Int($0.text) }))
        }
    }

    func perform(_ action: VMAction, on vm: VirtualMachine, media: String?) async throws {
        try await authenticate()
        guard Self.isManagedReference(vm.id), VMAction.available(for: vm, platform: .vmware).contains(action) else {
            throw VirtualizationError.unavailable
        }
        let method: String
        var body = "<_this type=\"VirtualMachine\">\(VMInput.xml(vm.id))</_this>"
        switch action {
        case .start: method = "PowerOnVM_Task"
        case .shutdown: method = "ShutdownGuest"
        case .reboot: method = "RebootGuest"
        case .suspend: method = "SuspendVM_Task"
        case .resume: method = "PowerOnVM_Task"
        case .reset: method = "ResetVM_Task"
        case .powerOff: method = "PowerOffVM_Task"
        case .mountTools: method = "MountToolsInstaller"
        case .ejectTools: method = "UnmountToolsInstaller"
        case .attachISO, .ejectISO:
            guard let device = vm.cdromDevice else {
                throw VirtualizationError.message("This VM has no virtual CD/DVD drive. Add one on the host, then refresh.")
            }
            let fields = device.components(separatedBy: "|")
            guard fields.count == 3, let key = Int(fields[0]), let controller = Int(fields[1]), let unit = Int(fields[2]) else {
                throw VirtualizationError.invalidResponse
            }
            method = "ReconfigVM_Task"
            let backing: String
            if action == .attachISO {
                guard let media, media.hasPrefix("["), media.contains("]"), media.count <= 4096,
                      media.rangeOfCharacter(from: .controlCharacters) == nil else {
                    throw VirtualizationError.message("Enter an existing datastore ISO path, for example [datastore] iso/installer.iso.")
                }
                backing = "<backing xsi:type=\"VirtualCdromIsoBackingInfo\"><fileName>\(VMInput.xml(media))</fileName></backing>"
            } else {
                backing = "<backing xsi:type=\"VirtualCdromRemotePassthroughBackingInfo\"><deviceName></deviceName><useAutoDetect>true</useAutoDetect><exclusive>false</exclusive></backing>"
            }
            body += """
            <spec><deviceChange><operation>edit</operation><device xsi:type="VirtualCdrom"><key>\(key)</key>
            \(backing)<connectable><startConnected>\(action == .attachISO)</startConnected>
            <allowGuestControl>true</allowGuestControl><connected>\(action == .attachISO)</connected></connectable>
            <controllerKey>\(controller)</controllerKey><unitNumber>\(unit)</unitNumber></device></deviceChange></spec>
            """
        }
        let response = try await call(method, body)
        if method.hasSuffix("_Task"), let id = response.child("returnval")?.text {
            try await waitForTask(id)
        }
    }

    private func waitForTask(_ id: String) async throws {
        guard Self.isManagedReference(id) else { throw VirtualizationError.invalidResponse }
        for _ in 0..<90 {
            try Task.checkCancellation()
            let result = try await call("RetrievePropertiesEx", """
            <_this type="PropertyCollector">\(managers["propertyCollector"]!)</_this><specSet>
            <propSet><type>Task</type><all>false</all><pathSet>info.state</pathSet><pathSet>info.progress</pathSet></propSet>
            <objectSet><obj type="Task">\(VMInput.xml(id))</obj><skip>false</skip></objectSet>
            </specSet><options/>
            """)
            let state = result.descendants("propSet").first { $0.child("name")?.text == "info.state" }?.child("val")?.text
            let percent = result.descendants("propSet").first { $0.child("name")?.text == "info.progress" }?.child("val")?.text
            taskProgress?(VMTaskProgress(state == "queued" ? "Queued on host" : "Running on host", percent: percent.flatMap(Int.init)))
            if state == "success" { return }
            if state == "error" { throw VirtualizationError.message("The VMware task failed. Review its task details on the host.") }
            try await Task.sleep(for: .seconds(1))
        }
        throw VirtualizationError.message("The host is still processing the request. Refresh to check its state.")
    }

    func details(for vm: VirtualMachine) async throws -> VirtualMachine {
        try await authenticate()
        var detail = vm
        if Self.isManagedReference(vm.node) {
            let result = try await call("RetrievePropertiesEx", """
            <_this type="PropertyCollector">\(managers["propertyCollector"]!)</_this><specSet>
            <propSet><type>HostSystem</type><all>false</all><pathSet>name</pathSet></propSet>
            <objectSet><obj type="HostSystem">\(VMInput.xml(vm.node))</obj><skip>false</skip></objectSet>
            </specSet><options/>
            """)
            if let name = result.descendants("propSet").first(where: { $0.child("name")?.text == "name" })?.child("val")?.text { detail.node = name }
        }
        return detail
    }

    func snapshots(for vm: VirtualMachine) async throws -> [VMSnapshot] {
        try await authenticate()
        guard Self.isManagedReference(vm.id) else { throw VirtualizationError.invalidResponse }
        let result = try await call("RetrievePropertiesEx", """
        <_this type="PropertyCollector">\(managers["propertyCollector"]!)</_this><specSet>
        <propSet><type>VirtualMachine</type><all>false</all><pathSet>snapshot</pathSet></propSet>
        <objectSet><obj type="VirtualMachine">\(VMInput.xml(vm.id))</obj><skip>false</skip></objectSet>
        </specSet><options/>
        """)
        return try Self.parseSnapshots(result)
    }

    nonisolated static func parseSnapshots(_ root: VMXMLNode) throws -> [VMSnapshot] {
        let current = root.descendants("currentSnapshot").first?.text
        let nodes = root.descendants("rootSnapshotList") + root.descendants("childSnapshotList")
        return try nodes.map {
            let id = try managedReference($0.child("snapshot"), operation: "Snapshot inventory")
            return VMSnapshot(id: id, name: $0.child("name")?.text ?? "Snapshot",
                created: $0.child("createTime")?.text ?? "Not reported", current: id == current)
        }
    }

    func snapshot(_ action: VMSnapshotAction, vm: VirtualMachine, snapshot: VMSnapshot?, name: String?) async throws {
        try await authenticate()
        guard Self.isManagedReference(vm.id) else { throw VirtualizationError.invalidResponse }
        let method: String, body: String
        switch action {
        case .create:
            let name = try VMSnapshotInput.name(name)
            method = "CreateSnapshot_Task"
            body = "<_this type=\"VirtualMachine\">\(VMInput.xml(vm.id))</_this><name>\(VMInput.xml(name))</name><description>Created with Nethriva</description><memory>false</memory><quiesce>false</quiesce>"
        case .delete, .revert:
            guard let snapshot, try await snapshots(for: vm).contains(where: { $0.id == snapshot.id }) else { throw VirtualizationError.invalidResponse }
            method = action == .delete ? "RemoveSnapshot_Task" : "RevertToSnapshot_Task"
            body = "<_this type=\"VirtualMachineSnapshot\">\(VMInput.xml(snapshot.id))</_this>" + (action == .delete ? "<removeChildren>false</removeChildren>" : "")
        }
        let result = try await call(method, body)
        let id = try Self.managedReference(result.child("returnval"), operation: method)
        try await waitForTask(id)
    }

    func console(for vm: VirtualMachine) async throws -> VMConsoleDescriptor {
        try await authenticate()
        guard vm.state == .running, Self.isManagedReference(vm.id) else {
            throw VirtualizationError.message("Start or resume the VM before opening its console.")
        }
        let response = try await call("AcquireTicket", """
        <_this type="VirtualMachine">\(VMInput.xml(vm.id))</_this><ticketType>webmks</ticketType>
        """)
        return try Self.consoleDescriptor(response, apiOrigin: http.origin,
                                          standaloneEndpoint: isStandaloneESXi ? http.origin : nil)
    }

    static func consoleDescriptor(_ response: VMXMLNode, apiOrigin: URL, standaloneEndpoint: URL? = nil) throws -> VMConsoleDescriptor {
        func invalid(_ field: TicketField) -> VirtualizationError {
            // Fixed field labels only. Never echo ticket values, URLs, or host XML.
            .message("VMware returned an invalid WebMKS ticket: \(field.rawValue). Reconnect for a fresh ticket; if it persists, report this field and the ESXi/vCenter version, not the ticket contents.")
        }
        guard let ticket = response.child("returnval"), let token = ticket.child("ticket")?.text,
              !token.isEmpty, token.utf8.count <= 4096,
              token.rangeOfCharacter(from: .controlCharacters) == nil else { throw invalid(.token) }
        let host = ticket.child("host")?.text
        let port = ticket.child("port")?.text
        let socketURL: URL
        if let rawURL = ticket.child("url")?.text, !rawURL.isEmpty {
            guard rawURL.utf8.count <= 8192, rawURL.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                  rawURL.rangeOfCharacter(from: .controlCharacters) == nil,
                  let components = URLComponents(string: rawURL), components.scheme == "wss",
                  components.user == nil, components.password == nil, components.fragment == nil,
                  let target = components.host, !target.isEmpty, !components.path.isEmpty,
                  (1...65535).contains(components.port ?? 443), let url = components.url else { throw invalid(.url) }
            // VMware documents WebSocket tickets as best expressed by `url`.
            // Separate host/port metadata can name a different console route or
            // alias. The authenticated API delegates this exact WSS endpoint;
            // its certificate pin (or strict system trust) still authorizes TLS.
            socketURL = url
        } else {
            // HostAgent tickets may omit fields when the requester already knows
            // the standalone ESXi endpoint. Never substitute a vCenter address.
            if let standaloneEndpoint {
                guard standaloneEndpoint == apiOrigin, standaloneEndpoint.scheme == "https",
                      standaloneEndpoint.user == nil, standaloneEndpoint.password == nil else { throw invalid(.origin) }
            }
            let host = host.flatMap { $0.isEmpty ? nil : $0 } ?? standaloneEndpoint?.host
            let defaultPort = host?.lowercased() == standaloneEndpoint?.host?.lowercased() ? (standaloneEndpoint?.port ?? 443) : 443
            guard let host, !host.isEmpty, host.utf8.count <= 253,
                  host.rangeOfCharacter(from: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-:")).inverted) == nil,
                  let number = Int(port ?? String(defaultPort)), (1...65535).contains(number) else { throw invalid(.endpoint) }
            var components = URLComponents()
            components.scheme = "wss"; components.host = host; components.port = number
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            guard let encoded = token.addingPercentEncoding(withAllowedCharacters: allowed) else { throw invalid(.token) }
            components.percentEncodedPath = "/ticket/" + encoded
            guard let url = components.url else { throw invalid(.endpoint) }
            socketURL = url
        }
        var sha256 = Set<String>(), sha1 = Set<String>()
        for entry in ticket.children where entry.name == "certThumbprintList" {
            var algorithm = entry.child("hashAlgorithm")?.text.lowercased().replacingOccurrences(of: "-", with: "")
            guard let raw = entry.child("thumbprint")?.text else { throw invalid(.thumbprint) }
            // VMware declares hashAlgorithm optional. Infer only an omitted
            // algorithm from a strictly validated digest, not an unknown label.
            if algorithm == nil || algorithm == "" {
                if VMConsoleCertificatePin.normalize(raw, algorithm: .sha256) != nil { algorithm = "sha256" }
                else if VMConsoleCertificatePin.normalize(raw, algorithm: .sha1) != nil { algorithm = "sha1" }
                else { throw invalid(.thumbprint) }
            }
            if algorithm == "sha256" {
                guard let normalized = VMConsoleCertificatePin.normalize(raw, algorithm: .sha256) else { throw invalid(.thumbprint) }
                sha256.insert(normalized)
            } else if algorithm == "sha1" {
                guard let normalized = VMConsoleCertificatePin.normalize(raw, algorithm: .sha1) else { throw invalid(.thumbprint) }
                sha1.insert(normalized)
            }
        }
        if let raw = ticket.child("sslThumbprint")?.text, !raw.isEmpty {
            guard let normalized = VMConsoleCertificatePin.normalize(raw, algorithm: .sha1) else { throw invalid(.legacyThumbprint) }
            sha1.insert(normalized)
        }
        if let pem = ticket.child("sslCertificate")?.text, !pem.isEmpty {
            guard pem.utf8.count <= 65536, pem.contains("-----BEGIN CERTIFICATE-----"), pem.contains("-----END CERTIFICATE-----") else { throw invalid(.certificate) }
            let base64 = pem.replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
                .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "").filter { !$0.isWhitespace }
            guard let der = Data(base64Encoded: base64), SecCertificateCreateWithData(nil, der as CFData) != nil else { throw invalid(.certificate) }
            sha256.insert(SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined())
        }
        // Prefer SHA-256. A mismatched certificate must not fall back to SHA-1 or "ignore".
        let pin: VMConsoleCertificatePin? = !sha256.isEmpty ? .init(algorithm: .sha256, fingerprints: sha256) :
            (!sha1.isEmpty ? .init(algorithm: .sha1, fingerprints: sha1) : nil)
        guard var origin = URLComponents(url: apiOrigin, resolvingAgainstBaseURL: false), origin.scheme == "https",
              origin.host != nil, origin.user == nil, origin.password == nil else { throw invalid(.origin) }
        origin.path = ""; origin.query = nil; origin.fragment = nil
        guard let originHeader = origin.string else { throw invalid(.origin) }
        return VMConsoleDescriptor(renderer: .vnc, webSocketURL: socketURL, certificatePin: pin, singleUseTicket: true,
                                   headers: ["Sec-WebSocket-Protocol": "binary", "Origin": originHeader])
    }

    func close() {
        guard authenticated, let manager = managers["sessionManager"] else { http.close(); return }
        authenticated = false
        Task {
            _ = try? await call("Logout", "<_this type=\"SessionManager\">\(VMInput.xml(manager))</_this>")
            http.close()
        }
    }
}
