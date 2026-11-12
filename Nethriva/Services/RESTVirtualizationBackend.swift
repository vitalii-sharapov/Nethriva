import Foundation

@MainActor
final class RESTVirtualizationBackend: VirtualizationBackend {
    var taskProgress: ((VMTaskProgress) -> Void)?
    var supportsSnapshots: Bool { platform == .proxmox }
    let connection: RemoteConnection
    let http: VirtualizationHTTP
    private let password: String
    private var authenticated = false
    private var headers: [String: String] = [:]
    private var rpcSocket: URLSessionWebSocketTask?
    private var rpcID = 0
    private var xoToken: String?

    init(connection: RemoteConnection, password: String?) throws {
        self.connection = connection
        self.password = password ?? ""
        http = try VirtualizationHTTP(connection: connection)
    }

    private var platform: VirtualizationPlatform { connection.virtualization?.platform ?? .proxmox }
    private static let componentCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
    static func component(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: componentCharacters) ?? "" }

    private func authenticate() async throws {
        guard !authenticated else { return }
        guard (!connection.username.isEmpty || connection.virtualization?.useBearerToken == true), !password.isEmpty else { throw VirtualizationError.authentication }
        switch platform {
        case .proxmox:
            if connection.username.contains("!") {
                headers = ["Authorization": "PVEAPIToken=\(connection.username)=\(password)"]
            } else {
                let data = try await http.request("/api2/json/access/ticket", method: "POST",
                    headers: ["Content-Type": "application/x-www-form-urlencoded"],
                    body: VirtualizationHTTP.form(["username": connection.username, "password": password]))
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let result = object["data"] as? [String: Any],
                      let ticket = result["ticket"] as? String,
                      let csrf = result["CSRFPreventionToken"] as? String else { throw VirtualizationError.invalidResponse }
                headers = ["Cookie": "PVEAuthCookie=\(ticket)", "CSRFPreventionToken": csrf]
            }
        case .xenOrchestra:
            var components = URLComponents(url: http.origin, resolvingAgainstBaseURL: false)!
            components.scheme = "wss"
            components.path = "/api/"
            guard let url = components.url else { throw VirtualizationError.invalidConfiguration }
            let socket = http.socket(URLRequest(url: url))
            socket.resume()
            rpcSocket = socket
            _ = try await rpc("session.signIn", ["email": connection.username, "password": password])
            guard let token = try await rpc("token.create", ["description": "Nethriva console session", "expiresIn": "1h"]) as? String else {
                throw VirtualizationError.invalidResponse
            }
            xoToken = token
        case .nutanix:
            if connection.virtualization?.useBearerToken == true { headers = ["Authorization": "Bearer \(password)"] }
            else {
                let value = Data("\(connection.username):\(password)".utf8).base64EncodedString()
                headers = ["Authorization": "Basic \(value)"]
            }
        default: throw VirtualizationError.unavailable
        }
        authenticated = true
    }

    private func rpc(_ method: String, _ parameters: [String: Any] = [:]) async throws -> Any {
        guard let rpcSocket else { throw VirtualizationError.authentication }
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(120)); rpcSocket.cancel(with: .goingAway, reason: nil) }
            catch {}
        }
        defer { deadline.cancel() }
        rpcID += 1
        let id = rpcID
        let message = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": parameters])
        try await rpcSocket.send(.string(String(decoding: message, as: UTF8.self)))
        for _ in 0..<1000 {
            try Task.checkCancellation()
            let response = try await rpcSocket.receive()
            let data: Data
            switch response {
            case .data(let value): data = value
            case .string(let value): data = Data(value.utf8)
            @unknown default: throw VirtualizationError.invalidResponse
            }
            guard data.count <= 16 * 1024 * 1024,
                  let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw VirtualizationError.invalidResponse
            }
            guard (value["id"] as? Int) == id else { continue }
            if value["error"] != nil { throw VirtualizationError.message("Xen Orchestra rejected the operation. Check account permissions, VM state, and guest tools.") }
            return value["result"] ?? NSNull()
        }
        throw VirtualizationError.invalidResponse
    }

    func machines() async throws -> [VirtualMachine] {
        try await authenticate()
        switch platform {
        case .proxmox:
            let object = try await http.json("/api2/json/cluster/resources?type=vm", headers: headers)
            return try await BackgroundWork.run { try Self.proxmoxMachines(object) }
        case .xenOrchestra:
            let object = try await rpc("xo.getAllObjects")
            return try await BackgroundWork.run { try Self.xenMachines(object) }
        case .nutanix:
            var machines: [VirtualMachine] = []
            var offset = 0
            repeat {
                let object = try await http.json("/api/nutanix/v3/vms/list", method: "POST", headers: headers,
                    body: ["kind": "vm", "offset": offset, "length": 250])
                guard let root = object as? [String: Any], let entities = root["entities"] as? [[String: Any]] else {
                    throw VirtualizationError.invalidResponse
                }
                machines += try await BackgroundWork.run { try Self.nutanixMachines(entities) }
                offset += entities.count
                let total = (root["metadata"] as? [String: Any])?["total_matches"] as? Int ?? offset
                if entities.isEmpty || offset >= total { break }
            } while offset < 100_000
            return machines
        default: throw VirtualizationError.unavailable
        }
    }

    nonisolated static func proxmoxMachines(_ object: Any) throws -> [VirtualMachine] {
        guard let root = object as? [String: Any], let entries = root["data"] as? [[String: Any]] else {
            throw VirtualizationError.invalidResponse
        }
        return entries.compactMap {
            guard let vmid = $0["vmid"] as? Int, let node = $0["node"] as? String,
                  let type = $0["type"] as? String, ["qemu", "lxc"].contains(type) else { return nil }
            return VirtualMachine(id: String(vmid), name: $0["name"] as? String ?? "VM \(vmid)",
                node: node, state: .parse($0["status"] as? String ?? ""), isContainer: type == "lxc")
        }
    }

    nonisolated static func xenMachines(_ object: Any) throws -> [VirtualMachine] {
        guard let entries = object as? [String: [String: Any]] else { throw VirtualizationError.invalidResponse }
        return entries.compactMap { key, value in
            guard value["type"] as? String == "VM", value["is_a_template"] as? Bool != true else { return nil }
            return VirtualMachine(id: value["id"] as? String ?? key, name: value["name_label"] as? String ?? "VM",
                node: value["$container"] as? String ?? "", state: .parse(value["power_state"] as? String ?? ""),
                guestTools: value["PV_drivers_version"] != nil ? "Reported by host" : "Not reported")
        }
    }

    nonisolated static func nutanixMachines(_ entries: [[String: Any]]) throws -> [VirtualMachine] {
        try entries.map {
            guard let metadata = $0["metadata"] as? [String: Any], let id = metadata["uuid"] as? String,
                  let spec = ($0["status"] ?? $0["spec"]) as? [String: Any] else {
                throw VirtualizationError.invalidResponse
            }
            let resources = spec["resources"] as? [String: Any] ?? [:]
            return VirtualMachine(id: id, name: spec["name"] as? String ?? "VM",
                node: (resources["host_reference"] as? [String: Any])?["name"] as? String ?? "",
                state: .parse(resources["power_state"] as? String ?? ""),
                guestIPs: VMGuestAddress.usable((resources["nic_list"] as? [[String: Any]] ?? []).flatMap { ($0["ip_endpoint_list"] as? [[String: Any]] ?? []).compactMap { $0["ip"] as? String } }),
                cpuCount: VMGuestAddress.cpu(resources["num_vcpus_per_socket"] as? Int, sockets: (resources["num_sockets"] as? Int) ?? 1),
                memoryMiB: VMGuestAddress.memoryMiB(resources["memory_size_mib"] as? Int))
        }
    }

    private func proxmox(_ path: String, method: String = "GET", values: [String: String] = [:]) async throws -> Any {
        if method == "GET" { return try await http.json("/api2/json" + path, headers: headers) }
        var requestHeaders = headers
        requestHeaders["Content-Type"] = "application/x-www-form-urlencoded"
        let data = try await http.request("/api2/json" + path, method: method, headers: requestHeaders,
            body: VirtualizationHTTP.form(values))
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw VirtualizationError.invalidResponse }
        return value
    }

    private func proxmoxRoot(_ vm: VirtualMachine) throws -> String {
        guard VMInput.validIdentifier(vm.node), Int(vm.id) != nil else { throw VirtualizationError.invalidResponse }
        return "/nodes/\(Self.component(vm.node))/\(vm.isContainer ? "lxc" : "qemu")/\(Self.component(vm.id))"
    }

    func perform(_ action: VMAction, on vm: VirtualMachine, media: String?) async throws {
        try await authenticate()
        guard VMAction.available(for: vm, platform: platform).contains(action),
              VMInput.validIdentifier(vm.id) else { throw VirtualizationError.unavailable }
        switch platform {
        case .proxmox:
            let root = try proxmoxRoot(vm)
            if [.mountTools, .attachISO, .ejectISO].contains(action) {
                let volume = action == .mountTools ? connection.virtualization?.toolsImage : media
                if action != .ejectISO {
                    guard let volume, !volume.isEmpty, !volume.contains(","), volume.rangeOfCharacter(from: .controlCharacters) == nil else {
                        throw VirtualizationError.message("Select an ISO volume on the Proxmox host, or configure a guest-tools ISO in the host settings.")
                    }
                }
                let config = try await proxmox(root + "/config") as? [String: Any]
                let fields = config?["data"] as? [String: Any] ?? [:]
                guard let drive = fields.keys.sorted().first(where: {
                    $0.range(of: "^(ide|sata|scsi)[0-9]+$", options: .regularExpression) != nil
                        && (fields[$0] as? String)?.contains("media=cdrom") == true
                }) else {
                    throw VirtualizationError.message("This VM has no CD/DVD drive. Add one on the host, then refresh. Existing disks will not be replaced.")
                }
                _ = try await proxmox(root + "/config", method: "PUT",
                    values: [drive: "\(action == .ejectISO ? "none" : volume!),media=cdrom"])
            } else {
                let command: String
                switch action {
                case .start: command = "start"
                case .shutdown: command = "shutdown"
                case .reboot: command = "reboot"
                case .suspend: command = "suspend"
                case .resume: command = "resume"
                case .reset: command = "reset"
                case .powerOff: command = "stop"
                default: throw VirtualizationError.unavailable
                }
                let result = try await proxmox(root + "/status/" + command, method: "POST") as? [String: Any]
                if let task = result?["data"] as? String { try await waitForProxmoxTask(task, node: vm.node) }
            }
        case .xenOrchestra:
            var params: [String: Any] = ["id": vm.id]
            let method: String
            switch action {
            case .start: method = "vm.start"
            case .shutdown: method = "vm.stop"; params["force"] = false
            case .powerOff: method = "vm.stop"; params["force"] = true
            case .reboot: method = "vm.restart"; params["force"] = false
            case .reset: method = "vm.restart"; params["force"] = true
            case .suspend: method = "vm.suspend"
            case .resume: method = "vm.resume"
            case .ejectISO:
                method = "vm.ejectCd"; params = ["vm": vm.id]
            case .mountTools, .attachISO:
                guard let image = action == .mountTools ? connection.virtualization?.toolsImage : media,
                      VMInput.validIdentifier(image) else {
                    throw VirtualizationError.message("Enter the Xen Orchestra ISO VDI identifier, or configure the guest-tools ISO identifier in host settings.")
                }
                method = "vm.insertCd"; params = ["vm": vm.id, "vdi": image, "force": true]
            default: throw VirtualizationError.unavailable
            }
            _ = try await rpc(method, params)
        case .nutanix:
            guard UUID(uuidString: vm.id) != nil else { throw VirtualizationError.invalidResponse }
            if [.mountTools, .attachISO, .ejectISO].contains(action) {
                try await nutanixMedia(action, vm: vm, media: media)
            } else if action == .start || action == .powerOff {
                guard var current = try await http.json("/api/nutanix/v3/vms/\(vm.id)", headers: headers) as? [String: Any],
                      var spec = current["spec"] as? [String: Any],
                      var resources = spec["resources"] as? [String: Any] else { throw VirtualizationError.invalidResponse }
                resources["power_state"] = action == .start ? "ON" : "OFF"
                spec["resources"] = resources
                current["spec"] = spec
                current.removeValue(forKey: "status")
                _ = try await http.json("/api/nutanix/v3/vms/\(vm.id)", method: "PUT", headers: headers, body: current)
            } else {
                let operation: String
                switch action {
                case .shutdown: operation = "guest-shutdown"
                case .reboot: operation = "guest-reboot"
                case .reset: operation = "reset"
                default: throw VirtualizationError.unavailable
                }
                var headers = headers
                headers["Ntnx-Request-Id"] = UUID().uuidString
                _ = try await http.json("/api/vmm/v4.0/ahv/config/vms/\(vm.id)/$actions/\(operation)",
                    method: "POST", headers: headers, body: [:])
            }
        default: throw VirtualizationError.unavailable
        }
    }

    private func waitForProxmoxTask(_ id: String, node: String) async throws {
        for _ in 0..<90 {
            try Task.checkCancellation()
            let value = try await proxmox("/nodes/\(Self.component(node))/tasks/\(Self.component(id))/status") as? [String: Any]
            let data = value?["data"] as? [String: Any] ?? [:]
            taskProgress?(VMTaskProgress("Running on host"))
            if data["status"] as? String == "stopped" {
                guard data["exitstatus"] as? String == "OK" else {
                    throw VirtualizationError.message("Proxmox could not complete the operation. Review its task log and the VM state.")
                }
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw VirtualizationError.message("The host is still processing the request. Refresh the VM list to check its state.")
    }

    func details(for vm: VirtualMachine) async throws -> VirtualMachine {
        try await authenticate()
        guard platform == .proxmox else { return vm }
        let root = try proxmoxRoot(vm)
        guard let config = try await proxmox(root + "/config") as? [String: Any], let data = config["data"] as? [String: Any] else { throw VirtualizationError.invalidResponse }
        var detail = vm
        detail.cpuCount = VMGuestAddress.cpu(data["cores"] as? Int, sockets: (data["sockets"] as? Int) ?? 1)
        detail.memoryMiB = VMGuestAddress.memoryMiB(data["memory"] as? Int)
        detail.operatingSystem = data["ostype"] as? String ?? "Not reported"
        detail.guestTools = data["agent"] != nil ? "Guest agent configured" : "Not configured / not reported"
        if !vm.isContainer, vm.state == .running,
           let agent = try? await proxmox(root + "/agent/network-get-interfaces") as? [String: Any],
           let values = agent["data"] as? [String: Any], let interfaces = values["result"] as? [[String: Any]] {
            detail.guestIPs = VMGuestAddress.usable(interfaces.flatMap { ($0["ip-addresses"] as? [[String: Any]] ?? []).compactMap { $0["ip-address"] as? String } })
        }
        return detail
    }

    func snapshots(for vm: VirtualMachine) async throws -> [VMSnapshot] {
        try await authenticate()
        guard supportsSnapshots else { throw VirtualizationError.unavailable }
        guard let result = try await proxmox(proxmoxRoot(vm) + "/snapshot") as? [String: Any], let entries = result["data"] as? [[String: Any]] else { throw VirtualizationError.invalidResponse }
        return entries.compactMap {
            guard let name = $0["name"] as? String, name != "current" else { return nil }
            return VMSnapshot(id: name, name: name, created: ($0["snaptime"] as? Double).map { Date(timeIntervalSince1970: $0).formatted() } ?? "Not reported")
        }
    }

    func snapshot(_ action: VMSnapshotAction, vm: VirtualMachine, snapshot: VMSnapshot?, name: String?) async throws {
        try await authenticate()
        guard supportsSnapshots else { throw VirtualizationError.unavailable }
        let root = try proxmoxRoot(vm) + "/snapshot"
        let path: String, method: String, fields: [String: String]
        if action == .create {
            path = root; method = "POST"; fields = ["snapname": try VMSnapshotInput.name(name), "description": "Created with Nethriva"]
        } else {
            guard let snapshot, try await snapshots(for: vm).contains(where: { $0.id == snapshot.id }),
                  VMInput.validIdentifier(snapshot.id) else { throw VirtualizationError.invalidResponse }
            path = root + "/" + Self.component(snapshot.id) + (action == .revert ? "/rollback" : "")
            method = action == .revert ? "POST" : "DELETE"; fields = [:]
        }
        let result = try await proxmox(path, method: method, values: fields) as? [String: Any]
        guard let task = result?["data"] as? String else { throw VirtualizationError.invalidResponse }
        try await waitForProxmoxTask(task, node: vm.node)
    }

    func console(for vm: VirtualMachine) async throws -> VMConsoleDescriptor {
        try await authenticate()
        guard vm.state == .running else { throw VirtualizationError.message("Start or resume the VM before opening its console.") }
        switch platform {
        case .proxmox:
            if vm.isContainer {
                var components = URLComponents(url: http.origin, resolvingAgainstBaseURL: false)!
                components.queryItems = [URLQueryItem(name: "console", value: "lxc"), URLQueryItem(name: "novnc", value: "1"),
                    URLQueryItem(name: "vmid", value: vm.id), URLQueryItem(name: "node", value: vm.node),
                    URLQueryItem(name: "xtermjs", value: "1")]
                return VMConsoleDescriptor(renderer: .hostWeb, webURL: components.url)
            }
            let root = try proxmoxRoot(vm)
            guard let result = try await proxmox(root + "/vncproxy", method: "POST", values: ["websocket": "1"]) as? [String: Any],
                  let data = result["data"] as? [String: Any], let ticket = data["ticket"] as? String,
                  let port = data["port"] as? Int else { throw VirtualizationError.invalidResponse }
            var components = URLComponents(url: http.origin, resolvingAgainstBaseURL: false)!
            components.scheme = "wss"
            components.path = "/api2/json" + root + "/vncwebsocket"
            components.queryItems = [URLQueryItem(name: "port", value: String(port)), URLQueryItem(name: "vncticket", value: ticket)]
            return VMConsoleDescriptor(renderer: .vnc, webSocketURL: components.url, headers: headers, password: ticket)
        case .xenOrchestra:
            guard VMInput.validIdentifier(vm.id), let xoToken else { throw VirtualizationError.invalidResponse }
            var components = URLComponents(url: http.origin, resolvingAgainstBaseURL: false)!
            components.scheme = "wss"
            components.path = "/api/consoles/\(vm.id)"
            return VMConsoleDescriptor(renderer: .vnc, webSocketURL: components.url, headers: ["Cookie": "token=\(xoToken)"])
        case .nutanix:
            return try await nutanixConsole(vm)
        default: throw VirtualizationError.unavailable
        }
    }

    private func nutanixConsole(_ vm: VirtualMachine) async throws -> VMConsoleDescriptor {
        guard UUID(uuidString: vm.id) != nil else { throw VirtualizationError.invalidResponse }
        var requestHeaders = headers
        requestHeaders["Ntnx-Request-Id"] = UUID().uuidString
        let response = try await http.json("/api/vmm/v4.0/ahv/config/vms/\(vm.id)/$actions/generate-console-token",
            method: "POST", headers: requestHeaders, body: [:]) as? [String: Any]
        guard let task = response?["data"] as? [String: Any], let id = task["extId"] as? String,
              VMInput.validIdentifier(id) else { throw VirtualizationError.invalidResponse }
        for _ in 0..<30 {
            let response = try await http.json("/api/prism/v4.0/config/tasks/\(Self.component(id))", headers: headers) as? [String: Any]
            let data = response?["data"] as? [String: Any] ?? [:]
            if data["status"] as? String == "FAILED" { throw VirtualizationError.forbidden }
            if data["status"] as? String == "SUCCEEDED" {
                let details = data["completionDetails"] as? [[String: Any]] ?? []
                var fields = data["completionDetails"] as? [String: Any] ?? [:]
                for entry in details {
                    if let key = entry["name"] as? String { fields[key] = Self.taskString(entry["value"]) }
                }
                guard let token = (fields["VmConsoleToken"] ?? fields["console_token"]) as? String else {
                    throw VirtualizationError.invalidResponse
                }
                let path = (fields["WsUri"] ?? fields["console_websocket_uri"]) as? String ?? "/console/launch/\(vm.id)"
                guard path.count <= 4096, path.rangeOfCharacter(from: .controlCharacters) == nil,
                      !path.contains("://"), !path.contains("..") else { throw VirtualizationError.invalidResponse }
                var socketHeaders = headers
                let cookies = http.cookies(for: http.origin)
                if !cookies.isEmpty {
                    socketHeaders["Cookie"] = HTTPCookie.requestHeaderFields(with: cookies)["Cookie"]
                } else if connection.virtualization?.useBearerToken != true {
                    throw VirtualizationError.message("This Prism Central console requires an authenticated cookie or bearer token, not Basic authentication. Edit the host, enable bearer-token authentication, and place an authorized token in its Keychain password field.")
                }
                var components = URLComponents(url: http.origin, resolvingAgainstBaseURL: false)!
                components.scheme = "wss"
                components.path = path.hasPrefix("/") ? path : "/" + path
                components.queryItems = [URLQueryItem(name: "VmConsoleToken", value: token)]
                return VMConsoleDescriptor(renderer: .vnc, webSocketURL: components.url, headers: socketHeaders)
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw VirtualizationError.message("The console ticket is taking longer than expected. Try reconnecting.")
    }

    nonisolated static func taskString(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        guard let object = value as? [String: Any] else { return nil }
        if let value = object["value"] as? String { return value }
        return (object["String"] as? [String: Any])?["value"] as? String
    }

    private func nutanixMedia(_ action: VMAction, vm: VirtualMachine, media: String?) async throws {
        var requestHeaders = headers
        requestHeaders["Ntnx-Request-Id"] = UUID().uuidString
        let root = "/api/vmm/v4.0/ahv/config/vms/\(vm.id)"
        if action == .mountTools {
            _ = try await http.json(root + "/guest-tools/$actions/insert-iso", method: "POST", headers: requestHeaders,
                body: ["isConfigOnly": false])
            return
        }
        let response = try await http.json(root + "/cd-roms", headers: headers) as? [String: Any]
        guard let drives = response?["data"] as? [[String: Any]], let id = drives.first?["extId"] as? String,
              VMInput.validIdentifier(id) else {
            throw VirtualizationError.message("This VM has no CD/DVD drive, or the host does not expose its v4 CD-ROM API.")
        }
        if action == .ejectISO {
            _ = try await http.json(root + "/cd-roms/\(Self.component(id))/$actions/eject", method: "POST", headers: requestHeaders, body: [:])
        } else {
            guard let media, UUID(uuidString: media) != nil else {
                throw VirtualizationError.message("Enter the Prism Central ISO image UUID.")
            }
            _ = try await http.json(root + "/cd-roms/\(Self.component(id))/$actions/insert", method: "POST", headers: requestHeaders,
                body: ["backingInfo": ["dataSource": ["reference": ["$objectType": "vmm.v4.ahv.config.ImageReference", "imageExtId": media]]]])
        }
    }

    func close() {
        if let xoToken, let socket = rpcSocket {
            // Revoke our temporary token while the authenticated RPC session is still alive.
            let id = rpcID + 1
            if let data = try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id,
                "method": "token.deleteOwn", "params": ["tokens": [xoToken]]]) {
                Task {
                    try? await socket.send(.string(String(decoding: data, as: UTF8.self)))
                    socket.cancel(with: .normalClosure, reason: nil)
                    http.close()
                }
                return
            }
        }
        rpcSocket?.cancel(with: .normalClosure, reason: nil)
        http.close()
    }
}
