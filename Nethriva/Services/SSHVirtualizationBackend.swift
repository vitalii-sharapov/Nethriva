import Foundation

final class VMProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func attach(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        self.process = process
        try process.run()
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if process?.isRunning == true { process?.terminate() }
    }
}

enum VMSSHCommand {
    static func arguments(for connection: RemoteConnection, command: String? = nil) throws -> [String] {
        _ = try VMInput.endpoint(for: connection)
        try SSHInputValidation.validate(connection)
        var args = ["-T", "-p", String(connection.port), "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=yes", "-o", "NumberOfPasswordPrompts=1",
            "-o", "PermitLocalCommand=no", "-o", "ForwardAgent=no", "-o", "ForwardX11=no",
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2"] + (try SSHConnectionReuse.arguments(for: connection))
        if let file = connection.sshIdentityFile, !file.isEmpty {
            args += ["-i", (file as NSString).expandingTildeInPath]
        }
        if let jump = connection.sshJumpHost, !jump.isEmpty { args += ["-J", jump] }
        args += ["--", connection.username.isEmpty ? connection.host : "\(connection.username)@\(connection.host)"]
        if let command { args.append(command) }
        return args
    }

    static func execute(_ command: String, on connection: RemoteConnection, password: String?) async throws -> String {
        try SSHCredentialPromptGuard.validate(password)
        let wrapped = connection.virtualization?.platform == .hyperv ? command : "printf '\\n__NETHRIVA_VM_BEGIN__\\n'; " + command +
            "; nethriva_status=$?; printf '\\n__NETHRIVA_VM_END__:%s\\n' \"$nethriva_status\"; exit \"$nethriva_status\""
        let args = try arguments(for: connection, command: wrapped)
        let cancellation = VMProcessCancellation()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                let process = Process()
                let input = Pipe()
                let output = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/expect")
                process.arguments = ["-c", expectScript]
                process.standardInput = input
                process.standardOutput = output
                process.standardError = output
                var environment = ProcessInfo.processInfo.environment
                environment["NETHRIVA_VM_ARG_COUNT"] = String(args.count)
                for (index, argument) in args.enumerated() { environment["NETHRIVA_VM_ARG_\(index)"] = argument }
                environment["NETHRIVA_VM_PASSWORD_LENGTH"] = String(password?.utf8.count ?? 0)
                process.environment = environment
                defer {
                    try? input.fileHandleForWriting.close()
                    try? output.fileHandleForReading.close()
                }
                try cancellation.attach(process)
                if let password { try input.fileHandleForWriting.write(contentsOf: Data(password.utf8)) }
                try input.fileHandleForWriting.close()
                var data = Data()
                while let chunk = try output.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
                    guard data.count + chunk.count <= 16 * 1024 * 1024 else {
                        cancellation.cancel()
                        throw VirtualizationError.invalidResponse
                    }
                    data += chunk
                }
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw VirtualizationError.message("The host SSH command failed. Open Host SSH to verify its host key and authentication, then check host permissions and installed management tools.")
                }
                let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
                guard let begin = text.range(of: "\n__NETHRIVA_VM_BEGIN__\n"),
                      let end = text.range(of: "\n__NETHRIVA_VM_END__:", options: .backwards),
                      begin.upperBound <= end.lowerBound else { throw VirtualizationError.invalidResponse }
                return String(text[begin.upperBound..<end.lowerBound])
            }.value
        } onCancel: { cancellation.cancel() }
    }

    // Password bytes enter through stdin, never an argument or an environment value.
    private static let expectScript = #"""
    set timeout 45
    log_user 0
    fconfigure stdin -translation binary -encoding binary
    set length $env(NETHRIVA_VM_PASSWORD_LENGTH)
    set password [read stdin $length]
    set args {}
    for {set i 0} {$i < $env(NETHRIVA_VM_ARG_COUNT)} {incr i} {
        lappend args $env(NETHRIVA_VM_ARG_$i)
    }
    set attempts 0
    match_max -d 16777216
    spawn -noecho /usr/bin/ssh {*}$args
    """# + "\n" + SSHCredentialPromptGuard.expectScript + "\n" + #"""
    expect {
        -re {(?i)(password|passphrase)[^\r\n]*: *$} {
            if {![nethriva_credential_prompt]} { close; exit 24 }
            incr attempts
            if {$attempts > 1 || $length == 0} { close; exit 24 }
            send -- "$password\r"
            set password ""
            exp_continue
        }
        eof {
            puts -nonewline $expect_out(buffer)
            set result [wait]
            exit [lindex $result 3]
        }
        timeout { close; exit 25 }
    }
    """#
}

@MainActor
final class SSHVirtualizationBackend: VirtualizationBackend {
    var taskProgress: ((VMTaskProgress) -> Void)?
    var supportsSnapshots: Bool { true }
    private let connection: RemoteConnection
    private let password: String?
    private var platform: VirtualizationPlatform { connection.virtualization?.platform ?? .libvirt }
    private var uri: String { connection.virtualization?.effectiveLibvirtURI ?? "qemu:///system" }
    init(connection: RemoteConnection, password: String?) { self.connection = connection; self.password = password }

    private func virsh(_ arguments: [String]) throws -> String {
        let values = ["virsh", "-c", uri] + arguments
        return "LC_ALL=C " + (try values.map(VMInput.shellQuote).joined(separator: " "))
    }
    private func run(_ command: String) async throws -> String {
        try await VMSSHCommand.execute(command, on: connection, password: password)
    }

    func machines() async throws -> [VirtualMachine] {
        if platform == .hyperv {
            let script = """
            $ErrorActionPreference='Stop'; @(Get-VM | ForEach-Object {
              [pscustomobject]@{id=$_.Id.ToString();name=$_.Name;state=$_.State.ToString();tools=$_.IntegrationServicesState.ToString();cpu=$_.ProcessorCount;memory=[int]($_.MemoryAssigned/1MB);ips=@(($_ | Get-VMNetworkAdapter).IPAddresses)}
            }) | ConvertTo-Json -Compress -Depth 4
            """
            return try Self.hyperVMachines(await run(try powershell(script)))
        }
        let list = try await run(try virsh(["list", "--all", "--uuid"]))
        let ids = list.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard ids.count <= 100_000, ids.allSatisfy({ UUID(uuidString: $0) != nil }) else { throw VirtualizationError.invalidResponse }
        var result: [VirtualMachine] = []
        // Small batches prevent hundreds of parallel SSH processes on a busy host.
        for start in stride(from: 0, to: ids.count, by: 4) {
            let batch = Array(ids[start..<min(start + 4, ids.count)])
            result += try await withThrowingTaskGroup(of: VirtualMachine.self) { group in
                for id in batch {
                    let command = try virsh(["dumpxml", "--domain", id]) + "; printf '\\n__NETHRIVA_VM_STATE__\\n'; " + virsh(["domstate", "--domain", id])
                    group.addTask { [connection, password] in
                        let output = try await VMSSHCommand.execute(command, on: connection, password: password)
                        return try Self.libvirtMachine(id: id, output: output)
                    }
                }
                var values: [VirtualMachine] = []
                for try await machine in group { values.append(machine) }
                return values
            }
        }
        return result
    }

    nonisolated static func libvirtMachine(id: String, output: String) throws -> VirtualMachine {
        guard let separator = output.range(of: "\n__NETHRIVA_VM_STATE__\n", options: .backwards) else {
            throw VirtualizationError.invalidResponse
        }
        let xml = try VMXMLDocument.parse(Data(output[..<separator.lowerBound].utf8))
        let state = String(output[separator.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let cdrom = xml.descendants("disk").first { $0.attributes["device"] == "cdrom" }?.child("target")?.attributes["dev"]
        return VirtualMachine(id: id, name: xml.child("name")?.text ?? "VM", state: .parse(state),
            guestTools: xml.descendants("channel").contains { $0.child("target")?.attributes["name"] == "org.qemu.guest_agent.0" }
                ? "Agent channel configured" : "Agent channel not configured", cdromDevice: cdrom,
            operatingSystem: xml.child("os")?.child("type")?.text ?? "Not reported",
            cpuCount: VMGuestAddress.cpu(xml.child("vcpu").flatMap { Int($0.text) }),
            memoryMiB: VMGuestAddress.memoryMiB(xml.child("memory").flatMap { Int($0.text) }, unit: xml.child("memory")?.attributes["unit"] ?? "KiB"))
    }

    // Unlike Restart-VM (hard reset), this waits for a guest shutdown before starting.
    nonisolated static let hyperVGracefulRestartCommand = "$vm | Stop-VM -Passthru -Confirm:$false | Start-VM"

    nonisolated static func hyperVMachines(_ output: String) throws -> [VirtualMachine] {
        guard let data = output.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else {
            throw VirtualizationError.invalidResponse
        }
        let entries = (object as? [[String: Any]]) ?? (object as? [String: Any]).map { [$0] } ?? []
        return try entries.map {
            guard let id = $0["id"] as? String, UUID(uuidString: id) != nil else { throw VirtualizationError.invalidResponse }
            return VirtualMachine(id: id, name: $0["name"] as? String ?? "VM", state: .parse($0["state"] as? String ?? ""),
                guestTools: $0["tools"] as? String ?? "Unknown",
                guestIPs: VMGuestAddress.usable($0["ips"] as? [String] ?? []),
                cpuCount: VMGuestAddress.cpu($0["cpu"] as? Int), memoryMiB: VMGuestAddress.memoryMiB($0["memory"] as? Int))
        }
    }

    func details(for vm: VirtualMachine) async throws -> VirtualMachine {
        guard UUID(uuidString: vm.id) != nil else { throw VirtualizationError.invalidResponse }
        guard platform == .libvirt, vm.state == .running else { return vm }
        var detail = vm
        if let output = try? await run(virsh(["domifaddr", "--domain", vm.id, "--source", "agent"])) {
            detail.guestIPs = VMGuestAddress.usable(output.split(whereSeparator: \.isWhitespace).map { String($0).components(separatedBy: "/")[0] })
        }
        return detail
    }

    func snapshots(for vm: VirtualMachine) async throws -> [VMSnapshot] {
        guard UUID(uuidString: vm.id) != nil else { throw VirtualizationError.invalidResponse }
        if platform == .hyperv {
            let script = "$ErrorActionPreference='Stop'; @(Get-VM -Id '\(vm.id)' | Get-VMSnapshot | ForEach-Object { [pscustomobject]@{id=$_.Id.ToString();name=$_.Name;created=$_.CreationTime.ToString('o')} }) | ConvertTo-Json -Compress -Depth 3"
            let output = try await run(powershell(script))
            let object = try JSONSerialization.jsonObject(with: Data(output.utf8))
            let values = (object as? [[String: Any]]) ?? (object as? [String: Any]).map { [$0] } ?? []
            return try values.map {
                guard let id = $0["id"] as? String, UUID(uuidString: id) != nil else { throw VirtualizationError.invalidResponse }
                return VMSnapshot(id: id, name: $0["name"] as? String ?? "Checkpoint", created: $0["created"] as? String ?? "Not reported")
            }
        }
        let names = try await run(virsh(["snapshot-list", "--domain", vm.id, "--name"]))
        return names.components(separatedBy: .newlines).filter { !$0.isEmpty }.map { VMSnapshot(id: $0, name: $0) }
    }

    func snapshot(_ action: VMSnapshotAction, vm: VirtualMachine, snapshot: VMSnapshot?, name: String?) async throws {
        guard UUID(uuidString: vm.id) != nil else { throw VirtualizationError.invalidResponse }
        let snapshotName: String
        if action == .create { snapshotName = try VMSnapshotInput.name(name) }
        else {
            guard let snapshot, try await snapshots(for: vm).contains(where: { $0.id == snapshot.id }) else { throw VirtualizationError.invalidResponse }
            snapshotName = snapshot.id
        }
        taskProgress?(VMTaskProgress("Running on host"))
        if platform == .hyperv {
            let operation = action == .delete ? "Remove-VMSnapshot -Confirm:$false" : "Restore-VMSnapshot -Confirm:$false"
            let script = action == .create
                ? "$ErrorActionPreference='Stop'; Get-VM -Id '\(vm.id)' | Checkpoint-VM -SnapshotName '\(snapshotName)'"
                : "$ErrorActionPreference='Stop'; Get-VM -Id '\(vm.id)' | Get-VMSnapshot | Where-Object { $_.Id -eq '\(snapshotName)' } | \(operation)"
            _ = try await run(powershell(script))
        } else {
            // Conservative internal snapshots: powered-off domains only. No force, disk-only or recursive deletion flags.
            let state = try await run(virsh(["domstate", "--domain", vm.id]))
            guard VMPowerState.parse(state.trimmingCharacters(in: .whitespacesAndNewlines)) == .stopped else {
                throw VirtualizationError.message("libvirt snapshot changes require a powered-off VM in Nethriva. Shut down the guest safely first; running/disk-only/external snapshots must be managed on the host.")
            }
            let args = action == .create ? ["snapshot-create-as", "--domain", vm.id, "--name", snapshotName]
                : [action == .delete ? "snapshot-delete" : "snapshot-revert", "--domain", vm.id, "--snapshotname", snapshotName]
            _ = try await run(virsh(args))
        }
    }

    func perform(_ action: VMAction, on vm: VirtualMachine, media: String?) async throws {
        guard UUID(uuidString: vm.id) != nil, VMAction.available(for: vm, platform: platform).contains(action) else {
            throw VirtualizationError.unavailable
        }
        if platform == .hyperv {
            var script = "$ErrorActionPreference='Stop'; $vm=Get-VM -Id '\(vm.id)'; "
            switch action {
            case .start: script += "$vm | Start-VM"
            case .shutdown: script += "$vm | Stop-VM -Confirm:$false"
            case .powerOff: script += "$vm | Stop-VM -TurnOff -Confirm:$false"
            case .reboot: script += Self.hyperVGracefulRestartCommand
            case .reset: script += "$vm | Restart-VM -Force -Confirm:$false"
            case .suspend: script += "$vm | Save-VM"
            case .resume: script += "if ($vm.State -eq 'Paused') {$vm | Resume-VM} else {$vm | Start-VM}"
            case .mountTools, .attachISO, .ejectISO:
                let image = action == .mountTools ? connection.virtualization?.toolsImage : media
                if action != .ejectISO {
                    guard let image, !image.isEmpty, image.rangeOfCharacter(from: .controlCharacters) == nil else {
                        throw VirtualizationError.message("Choose an ISO path on the Hyper-V host. Modern Windows integration services are supplied through Windows Update.")
                    }
                }
                let value = (action == .ejectISO ? "" : image!).replacingOccurrences(of: "'", with: "''")
                script += "$dvd=@(Get-VMDvdDrive -VM $vm); if ($dvd.Count -eq 0) {throw 'No DVD drive'}; $dvd[0] | Set-VMDvdDrive -Path '\(value)'"
            default: throw VirtualizationError.unavailable
            }
            _ = try await run(try powershell(script))
            return
        }
        let command: [String]
        switch action {
        case .start: command = ["start", "--domain", vm.id]
        case .shutdown: command = ["shutdown", "--domain", vm.id]
        case .reboot: command = ["reboot", "--domain", vm.id]
        case .suspend: command = ["suspend", "--domain", vm.id]
        case .resume: command = ["resume", "--domain", vm.id]
        case .reset: command = ["reset", "--domain", vm.id]
        case .powerOff: command = ["destroy", "--domain", vm.id]
        case .mountTools, .attachISO, .ejectISO:
            guard let device = vm.cdromDevice, VMInput.validIdentifier(device) else {
                throw VirtualizationError.message("This VM has no virtual CD/DVD drive. Add one on the host, then refresh.")
            }
            if action == .ejectISO { command = ["change-media", vm.id, device, "--eject", "--config"] + (vm.state == .running ? ["--live"] : []) }
            else {
                guard let image = action == .mountTools ? connection.virtualization?.toolsImage : media,
                      image.hasPrefix("/") else { throw VirtualizationError.message("Choose an absolute ISO path on the libvirt host.") }
                command = ["change-media", vm.id, device, image, "--insert", "--config"] + (vm.state == .running ? ["--live"] : [])
            }
        default: throw VirtualizationError.unavailable
        }
        _ = try await run(try virsh(command))
    }

    nonisolated static func powershellCommand(_ script: String) -> String {
        let framed = "[Console]::OutputEncoding=[Text.UTF8Encoding]::new(); Write-Output ''; Write-Output '__NETHRIVA_VM_BEGIN__'; try { $ErrorActionPreference='Stop'; " + script +
            "; Write-Output '__NETHRIVA_VM_END__:0'; exit 0 } catch { Write-Output '__NETHRIVA_VM_END__:1'; exit 1 }"
        let encoded = framed.data(using: .utf16LittleEndian)!.base64EncodedString()
        // Base64 contains no shell metacharacters; this works with both cmd.exe and PowerShell SSH shells.
        return "powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand " + encoded
    }
    private func powershell(_ script: String) throws -> String {
        Self.powershellCommand(script)
    }

    func console(for vm: VirtualMachine) async throws -> VMConsoleDescriptor {
        guard UUID(uuidString: vm.id) != nil, vm.state == .running else {
            throw VirtualizationError.message("Start or resume the VM before opening its console.")
        }
        if platform == .hyperv {
            return VMConsoleDescriptor(renderer: .hyperv, host: connection.host, port: 2179, vmID: vm.id)
        }
        let output = try await run(try virsh(["dumpxml", "--domain", vm.id]))
        let xml = try VMXMLDocument.parse(Data(output.utf8))
        guard let graphics = xml.descendants("graphics").first(where: { ["vnc", "spice"].contains($0.attributes["type"] ?? "") }) else {
            throw VirtualizationError.message("Configure a VNC or SPICE graphics device for this VM on the libvirt host.")
        }
        var sshHost = connection
        sshHost.kind = .ssh
        let socket = graphics.attributes["socket"] ?? graphics.child("listen")?.attributes["socket"]
        let host = graphics.attributes["listen"] ?? graphics.child("listen")?.attributes["address"] ?? "127.0.0.1"
        let port = Int(graphics.attributes["port"] ?? "") ?? 0
        guard socket != nil || (1...65535).contains(port) else {
            throw VirtualizationError.message("The VM console has no active port or socket. Check its graphics configuration.")
        }
        return VMConsoleDescriptor(renderer: graphics.attributes["type"] == "spice" ? .spice : .vnc,
            host: ["0.0.0.0", "::"].contains(host) ? "127.0.0.1" : host,
            port: port, sshHost: sshHost, sshSocketPath: socket, vmID: vm.id)
    }

    func close() {}
}
