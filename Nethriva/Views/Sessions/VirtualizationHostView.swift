import AppKit
import SwiftUI

@MainActor
final class VirtualizationHostController: ObservableObject {
    @Published var machines: [VirtualMachine] = []
    @Published private(set) var visibleMachines: [VirtualMachine] = []
    private var searchWork: Task<Void, Never>?
    private var searchGeneration = UUID()
    private var query = ""
    @Published var busy = false
    @Published var error: String?
    @Published var notice: String?
    @Published var detail: VirtualMachine?
    @Published var snapshots: [VMSnapshot] = []
    @Published var detailBusy = false
    @Published var progress: VMTaskProgress?
    private var detailWork: Task<Void, Never>?
    private var detailGeneration = UUID()
    private var backend: (any VirtualizationBackend)?
    private var work: Task<Void, Never>?
    private var generation = UUID()
    let connection: RemoteConnection
    init(connection: RemoteConnection) { self.connection = connection }
    var isConnected: Bool { backend != nil }
    var supportsSnapshots: Bool { backend?.supportsSnapshots == true }

    func connect(password: String?, username: String? = nil) {
        guard !CredentialAccessGate.shared.isLocked else { return }
        stop()
        var host = connection
        if let username { host.username = username }
        do {
            backend = try VirtualizationBackendFactory.make(connection: host, password: password)
            let generation = generation
            backend?.taskProgress = { [weak self] progress in
                guard let self, self.busy, self.generation == generation, !CredentialAccessGate.shared.isLocked else { return }
                self.progress = progress
            }
            refresh()
        }
        catch { self.error = error.localizedDescription }
    }
    func refresh() {
        guard !busy, let backend else { return }
        let generation = generation
        busy = true; error = nil
        work = Task { [weak self] in
            do {
                let result = try await backend.machines()
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                let sorted = try await BackgroundWork.run { result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
                guard self.generation == generation, !Task.isCancelled else { return }
                machines = sorted
                updateSearch(query, debounce: false)
            } catch {
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            if let self, self.generation == generation { busy = false }
        }
    }
    func perform(_ action: VMAction, on vm: VirtualMachine) {
        guard !CredentialAccessGate.shared.isLocked else { return }
        guard !busy, let backend else { return }
        var media: String?
        if action == .attachISO {
            let alert = NSAlert()
            alert.messageText = "Mount ISO on \(vm.name)"
            alert.informativeText = Self.mediaHint(connection.virtualization?.platform ?? .proxmox)
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 430, height: 24))
            alert.accessoryView = field
            alert.addButton(withTitle: "Mount"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
            media = field.stringValue
        } else if action.requiresConfirmation {
            let alert = NSAlert()
            alert.messageText = "\(action.title.replacingOccurrences(of: "…", with: "")) — \(vm.name)?"
            alert.informativeText = [.powerOff, .reset].contains(action)
                ? "This interrupts the guest immediately and may lose unsaved data."
                : (action == .mountTools ? "Mounts guest-tools media only. Complete installation inside the guest OS. QEMU and Hyper-V do not provide a universal tools installer; configure a host ISO if needed." : "This changes the VM on its host. Continue only if you intend to perform this operation.")
            alert.addButton(withTitle: "Continue"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        guard !CredentialAccessGate.shared.isLocked else { return }
        busy = true; error = nil; notice = nil
        progress = VMTaskProgress("Submitting to host")
        let generation = generation
        work = Task { [weak self] in
            do {
                try await backend.perform(action, on: vm, media: media)
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                notice = "Host accepted the request. Refresh to check the guest's state and review any host task."
                busy = false; progress = nil
                refresh()
            } catch {
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                self.error = error.localizedDescription; busy = false; progress = nil
            }
        }
    }
    func inspect(_ vm: VirtualMachine?) {
        detailGeneration = UUID(); detailWork?.cancel(); detail = vm; snapshots = []; detailBusy = false
        guard let vm, let backend, !CredentialAccessGate.shared.isLocked else { return }
        let generation = detailGeneration
        detailBusy = true
        detailWork = Task { [weak self] in
            do {
                let details = try await backend.details(for: vm)
                guard let self, self.detailGeneration == generation, !Task.isCancelled else { return }
                detail = details
                if backend.supportsSnapshots { snapshots = try await backend.snapshots(for: vm) }
            } catch {
                guard let self, self.detailGeneration == generation, !Task.isCancelled else { return }
                self.error = "Could not refresh VM details or snapshots. Check host permissions and API support."
            }
            if let self, self.detailGeneration == generation { detailBusy = false }
        }
    }
    func changeSnapshot(_ action: VMSnapshotAction, vm: VirtualMachine, snapshot: VMSnapshot? = nil) {
        guard !busy, let backend, !CredentialAccessGate.shared.isLocked else { return }
        let alert = NSAlert()
        alert.messageText = "\(action.title) — \(vm.name)?"
        alert.informativeText = action == .create
            ? "Snapshots are not backups. VMware/Proxmox creation excludes guest memory and is not application-quiesced. libvirt changes require a stopped VM. Hyper-V uses its configured checkpoint policy. Storage and host permissions must support snapshots."
            : (action == .revert ? "Reversion discards changes made since this snapshot and can change the guest's power state. Unsaved data may be lost. A snapshot is not a backup."
                : "This permanently removes the selected snapshot's recovery point. No force or recursive-delete option is used.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        field.placeholderString = "snapshot_name"; field.setAccessibilityLabel("Snapshot name")
        if action == .create { alert.accessoryView = field }
        else if let snapshot { alert.informativeText += "\nSelected snapshot: " + snapshot.name }
        alert.addButton(withTitle: action.title); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, !CredentialAccessGate.shared.isLocked else { return }
        let name = action == .create ? field.stringValue : nil
        busy = true; error = nil; progress = VMTaskProgress("Submitting to host")
        let generation = generation
        work = Task { [weak self] in
            do {
                try await backend.snapshot(action, vm: vm, snapshot: snapshot, name: name)
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                busy = false; progress = nil; notice = "Snapshot operation completed on the host."
                inspect(vm); refresh()
            } catch {
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                busy = false; progress = nil; self.error = error.localizedDescription
            }
        }
    }
    func stopMonitoring() {
        work?.cancel(); work = nil; busy = false; progress = nil
        notice = "Monitoring stopped. Any operation already accepted by the host may still continue. No request will be replayed; refresh the host to check its state."
    }
    static func mediaHint(_ platform: VirtualizationPlatform) -> String {
        switch platform {
        case .proxmox: "Enter a host ISO volume, for example local:iso/installer.iso. The VM must already have a CD/DVD drive."
        case .vmware: "Enter a datastore ISO path, for example [datastore1] iso/installer.iso. The VM must already have a CD/DVD drive."
        case .libvirt: "Enter an absolute ISO path on the libvirt host, not a file path on this Mac."
        case .hyperv: "Enter an ISO path on the Hyper-V host. The VM must already have a DVD drive."
        case .xenOrchestra: "Enter the ISO VDI UUID from Xen Orchestra."
        case .nutanix: "Enter an ISO image UUID from Prism Central."
        }
    }
    func stop() {
        generation = UUID(); work?.cancel(); work = nil
        detailGeneration = UUID(); detailWork?.cancel(); detailWork = nil; detail = nil; snapshots = []; detailBusy = false; progress = nil
        backend?.close(); backend = nil; busy = false
        searchWork?.cancel()
    }
    func updateSearch(_ query: String, debounce: Bool = true) {
        self.query = query; searchGeneration = UUID(); searchWork?.cancel()
        let generation = searchGeneration, snapshot = machines
        searchWork = Task { [weak self] in
            do {
                if debounce { try await Task.sleep(for: .milliseconds(150)) }
                try Task.checkCancellation()
                let visible = try await BackgroundWork.run { VMInventorySearch.filter(snapshot, query: query) }
                guard let self, self.searchGeneration == generation, !Task.isCancelled else { return }
                visibleMachines = visible
            } catch {}
        }
    }
}

struct VirtualizationHostView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var recovery: SessionRecovery
    @Environment(\.sessionLifetime) private var lifetime
    @StateObject private var controller: VirtualizationHostController
    @ObservedObject private var federation = VMwareFederation.shared
    @State private var search = ""
    @State private var selection: String?
    @State private var showsCredentials = false
    @State private var recoveryPending = false
    @State private var showsDetails = true
    let connection: RemoteConnection
    private var platform: VirtualizationPlatform { connection.virtualization?.platform ?? .proxmox }
    private var usesFederation: Bool { platform == .vmware && connection.virtualization?.federation != nil }
    init(connection: RemoteConnection) {
        self.connection = connection
        _controller = StateObject(wrappedValue: VirtualizationHostController(connection: connection))
    }
    private var selected: VirtualMachine? { controller.machines.first { $0.id == selection } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(platform.displayName, systemImage: "server.rack").font(.headline)
                Spacer()
                ConnectionCheckButton(connection: connection).labelStyle(.iconOnly)
                if platform.usesSSH { Button("Host SSH") { appState.openHostSSH(connection) } }
                Button("Details", systemImage: "sidebar.right") { showsDetails.toggle() }
                if platform == .vmware, connection.virtualization?.federation != nil {
                    Button("Federated Sign In…") { signIn() }.disabled(controller.busy || federation.isSigningIn)
                }
                if !usesFederation { Button("Credentials…") { showsCredentials = true }.disabled(controller.busy) }
                Button("Refresh", systemImage: "arrow.clockwise") {
                    if controller.isConnected { controller.refresh() } else { reconnect() }
                }.disabled(controller.busy)
                if controller.isConnected {
                    Button("Disconnect") { recoveryPending = false; controller.stop() }
                } else { Button("Reconnect", action: reconnect) }
            }.padding(12).background(.bar)
            Divider()
            HStack {
                TextField("Search virtual machines", text: $search).textFieldStyle(.roundedBorder)
                Text("\(controller.machines.count) VMs").foregroundStyle(.secondary)
                if controller.busy { ProgressView().controlSize(.small) }
            }.padding(12)
            if let error = controller.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).padding(.horizontal).textSelection(.enabled) }
            if let notice = controller.notice { Text(notice).font(.caption).foregroundStyle(.secondary).padding(.horizontal) }
            if let progress = controller.progress {
                HStack {
                    if let percent = progress.percent { ProgressView(value: Double(percent), total: 100); Text("\(percent)%") }
                    else { ProgressView().controlSize(.small) }
                    Text(progress.phase)
                    Button("Stop Monitoring") { controller.stopMonitoring() }
                }.padding(.horizontal).accessibilityElement(children: .combine)
            }
            HSplitView {
            Table(controller.visibleMachines, selection: $selection) {
                TableColumn("Virtual Machine") { vm in
                    HStack { Image(systemName: vm.isContainer ? "shippingbox" : "desktopcomputer"); Text(vm.name) }
                        .contextMenu { vmMenu(vm) }
                        .onTapGesture(count: 2) { open(vm) }
                }
                TableColumn("State") { Text($0.state.displayName) }.width(90)
                TableColumn("Host / Node") { Text($0.node) }
                TableColumn("Guest Tools") { Text($0.guestTools) }
            }
            .accessibilityLabel("Virtual machine inventory")
            .onKeyPress(.return) {
                guard let selected, selected.state == .running, !controller.busy else { return .ignored }
                open(selected); return .handled
            }
            if showsDetails, let detail = controller.detail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(detail.name).font(.headline)
                        LabeledContent("Host", value: detail.node.isEmpty ? "Not reported" : detail.node)
                        LabeledContent("Guest OS", value: detail.operatingSystem)
                        LabeledContent("CPU", value: detail.cpuCount.map { "\($0) vCPU" } ?? "Not reported")
                        LabeledContent("Memory", value: detail.memoryMiB.map { "\($0) MiB" } ?? "Not reported")
                        LabeledContent("Tools", value: detail.guestTools)
                        if detail.guestIPs.isEmpty { Text("Guest IP addresses not reported. Guest tools / agent and host permissions may be required.").font(.caption) }
                        ForEach(detail.guestIPs, id: \.self) { address in
                            VStack(alignment: .leading) {
                                Text(address).textSelection(.enabled)
                                HStack {
                                    Button("SSH") { openGuest(address, kind: .ssh, vm: detail) }
                                    Button("RDP") { openGuest(address, kind: .rdp, vm: detail) }
                                }.accessibilityLabel("Guest connection for \(address)")
                            }
                        }
                        Text("Guest shortcuts use a separate, unsaved connection—not management-host credentials.").font(.caption).foregroundStyle(.secondary)
                        Divider()
                        Text("Snapshots / Checkpoints").font(.headline)
                        if controller.supportsSnapshots {
                            Button("Create Snapshot…") { controller.changeSnapshot(.create, vm: detail) }.disabled(controller.busy || controller.detailBusy)
                            ForEach(controller.snapshots) { snapshot in
                                VStack(alignment: .leading) {
                                    Text(snapshot.name + (snapshot.current ? " (current)" : ""))
                                    Text(snapshot.created).font(.caption)
                                    HStack {
                                        Button("Revert…") { controller.changeSnapshot(.revert, vm: detail, snapshot: snapshot) }
                                        Button("Delete…") { controller.changeSnapshot(.delete, vm: detail, snapshot: snapshot) }
                                    }.disabled(controller.busy || controller.detailBusy)
                                }
                            }
                        } else { Text("Snapshot management is not available through this adapter.").font(.caption) }
                        if controller.detailBusy { ProgressView("Loading details…") }
                        Button("Refresh Details") { controller.inspect(selected) }.disabled(controller.detailBusy || controller.busy)
                    }.padding(12)
                }.frame(minWidth: 260, idealWidth: 310, maxWidth: 400)
            }
            }
            .overlay {
                if controller.machines.isEmpty && !controller.busy && controller.error == nil {
                    ContentUnavailableView("No Virtual Machines", systemImage: "server.rack", description: Text("Check host permissions, or refresh after creating a VM."))
                }
            }
            Divider()
            HStack {
                Button("Open Console", systemImage: "desktopcomputer") { if let selected { open(selected) } }
                    .disabled(selected?.state != .running || controller.busy)
                Menu("VM Actions") { if let selected { vmActions(selected) } }
                    .disabled(selected == nil || controller.busy)
                Spacer()
                Text("Console and management access depend on host permissions.").font(.caption).foregroundStyle(.secondary)
            }.padding(12)
        }
        .task {
            lifetime?.own("vm-inventory") { [controller = controller] in controller.stop() }
            if lifetime?.claimStart("vm-inventory") == false { return }
            if usesFederation {
                if VMwareFederation.shared.assertion(for: connection) != nil { controller.connect(password: nil) }
                else { controller.notice = "Choose Federated Sign In to authorize this vCenter host. Saved passwords are not used in this mode." }
                return
            }
            do {
                let password = try await appState.sessionPassword(for: connection)
                try Task.checkCancellation(); _ = try appState.credentialGate.check()
                controller.connect(password: password)
            }
            catch { controller.error = "Could not read the saved host password. Use Credentials to reconnect." }
        }
        .onDisappear { if lifetime == nil { controller.stop() } }
        .onChange(of: controller.machines) { _, machines in appState.vmInventory[connection.id] = machines }
        .onChange(of: recovery.suspended) { _, suspended in
            if suspended, controller.isConnected {
                recoveryPending = true; controller.stop()
                controller.notice = "Connection interrupted. Reconnect or refresh when ready. Any host operation already accepted may continue; it will not be replayed."
            }
        }
        .onChange(of: recovery.epoch) { _, _ in
            if recoveryPending, settings.recoverNetworkSessions { reconnect() }
        }
        .onChange(of: search) { _, value in controller.updateSearch(value) }
        .onChange(of: selection) { _, _ in controller.inspect(selected) }
        .sheet(isPresented: $showsCredentials) {
            VMAuthenticationView(connection: connection) { username, password in
                appState.useVMLogin(username: username, password: password, for: connection)
                controller.connect(password: password, username: username)
            }
        }
    }
    private func openGuest(_ address: String, kind: ConnectionKind, vm: VirtualMachine) {
        do { appState.open(try VMGuestAddress.connection(address: address, kind: kind, name: vm.name)) }
        catch { controller.error = error.localizedDescription }
    }
    private func signIn() {
        Task {
            do {
                try await VMwareFederation.shared.signIn(connection: connection)
                try Task.checkCancellation(); _ = try appState.credentialGate.check()
                controller.connect(password: nil)
            } catch { if !appState.credentialGate.isLocked { controller.error = "Federated sign-in did not complete. Check the configured native-client registration and vCenter support." } }
        }
    }
    private func open(_ vm: VirtualMachine) { if vm.state == .running { appState.openVMConsole(vm, on: connection) } }
    private func reconnect() {
        recoveryPending = false
        if usesFederation { controller.connect(password: nil); return }
        Task {
            do {
                let password = try await appState.sessionPassword(for: connection)
                try Task.checkCancellation(); _ = try appState.credentialGate.check()
                controller.connect(password: password)
            }
            catch { controller.error = "Could not read the saved host password. Use Credentials to reconnect." }
        }
    }
    @ViewBuilder private func vmActions(_ vm: VirtualMachine) -> some View {
        ForEach(VMAction.available(for: vm, platform: platform)) { action in
            Button(action.title) { controller.perform(action, on: vm) }
        }
    }
    @ViewBuilder private func vmMenu(_ vm: VirtualMachine) -> some View {
        Button("Open Console") { open(vm) }.disabled(vm.state != .running || controller.busy)
        Divider()
        vmActions(vm).disabled(controller.busy)
    }
}

struct VMAuthenticationView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var username: String
    @State private var password = ""
    @State private var save = false
    @State private var error: String?
    let connection: RemoteConnection
    let completion: (String, String) -> Void
    init(connection: RemoteConnection, completion: @escaping (String, String) -> Void) {
        self.connection = connection; self.completion = completion
        _username = State(initialValue: connection.username)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Host Authentication").font(.title2)
            Text("Enter the management host login. Console passwords may be different.").font(.caption)
            TextField("Username", text: $username).textFieldStyle(.roundedBorder)
            SecureField("Password / API token", text: $password).textFieldStyle(.roundedBorder)
            Toggle("Save credentials in Keychain", isOn: $save)
            if connection.credentialProfileID != nil { Text("Saving updates the shared credential profile used by other connections.").font(.caption).foregroundStyle(.orange) }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Connect") {
                    do {
                        if save {
                            if let id = connection.credentialProfileID, var profile = appState.credentialProfiles.first(where: { $0.id == id }) {
                                profile.username = username
                                try appState.saveProfile(profile, password: password)
                            } else {
                                var updated = connection; updated.username = username
                                try appState.update(updated, password: password)
                            }
                        }
                        completion(username, password); dismiss()
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 460)
    }
}
