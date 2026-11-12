import SwiftUI

@main
struct NethrivaApp: App {
    @NSApplicationDelegateAdaptor(WorkflowApplicationDelegate.self) private var applicationDelegate
    @Environment(\.openWindow) private var openWindow
    @StateObject private var appState = AppState()
    @StateObject private var settings = AppSettings()
    @StateObject private var recovery = SessionRecovery()
    @StateObject private var surfaces = SessionSurfaceStore()
    @StateObject private var workflows = WorkflowLibrary()
    @StateObject private var tunnels = TunnelManager()
    @StateObject private var editors = RemoteFileEditors()
    @StateObject private var privacy = PrivacyLock.shared

    var body: some Scene {
        Window("Nethriva", id: "workspace") {
            Group {
                if privacy.isLocked {
                    VStack(spacing: 16) {
                        Text("Nethriva is locked").font(.title.bold())
                        Button("Unlock with Touch ID or Mac Password") { privacy.unlock() }
                        if let message = privacy.message { Text(message).font(.caption) }
                    }
                } else { ContentView() }
            }
                .environmentObject(appState)
                .environmentObject(settings)
                .environmentObject(recovery)
                .environmentObject(surfaces)
                .environmentObject(editors)
                .task {
                    surfaces.configure(state: appState, settings: settings, recovery: recovery, editors: editors)
                    appState.extraSSHConnections = { [weak tunnels = tunnels, weak editors = editors] in (tunnels?.leases ?? []) + (editors?.leases ?? []) }
                    tunnels.onReleased = { [weak appState = appState] in appState?.closeSSHTransportIfUnused(for: $0) }
                    editors.onReleased = { [weak appState = appState] in appState?.closeSSHTransportIfUnused(for: $0) }
                    applicationDelegate.editors = editors
                    privacy.onLock = { [weak appState = appState, weak surfaces = surfaces, weak tunnels = tunnels, weak editors = editors] in
                        editors?.suspendForPrivacy(); tunnels?.stopAll()
                        appState?.lockSessions(); surfaces?.sync()
                    }
                    privacy.onCleanup = { [weak appState = appState] in await appState?.finishPrivacyShutdown() }
                    privacy.install()
                }
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            NethrivaHelpCommands()

            CommandMenu("Sessions") {
                Button("Next Session") { switchSession(offset: 1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift]).disabled(appState.tabs.isEmpty || privacy.isLocked)
                Button("Previous Session") { switchSession(offset: -1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift]).disabled(appState.tabs.isEmpty || privacy.isLocked)
                Button("Close Current Session") { if let id = appState.selectedTabID { appState.close(tabID: id) } }
                    .keyboardShortcut("w", modifiers: [.command, .shift]).disabled(appState.selectedTabID == nil || privacy.isLocked)
                Divider()
                ForEach(1...9, id: \.self) { number in
                    Button("Session \(number)") {
                        if appState.tabs.count >= number { surfaces.activate(appState.tabs[number - 1].id) }
                    }.keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
                        .disabled(appState.tabs.count < number || privacy.isLocked)
                }
            }

            CommandGroup(after: .newItem) {
                Button("Lock & Disconnect Sessions") { privacy.lock() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(privacy.isLocked)
                Button("Unlock Nethriva") { privacy.unlock() }.disabled(!privacy.isLocked)
                Button("Shared Connection Libraries…") { openWindow(id: "shared-libraries") }.disabled(privacy.isLocked)
                Divider()
                Button("Quick Connect…") { openWindow(id: "quick-connect") }
                    .keyboardShortcut("k", modifiers: [.command])
                Button("SSH Tunnels…") { openWindow(id: "ssh-tunnels") }
                Button("Command Snippets…") { openWindow(id: "command-snippets") }
                Button("Multi-Session Command…") { openWindow(id: "multi-session-command") }
                Button("Terminal Profiles & Templates…") { openWindow(id: "library-tools") }
                Button("Bulk Edit Connections…") { openWindow(id: "bulk-edit") }
                Divider()
                Button("Find Connection…") {
                    appState.focusConnectionSearch()
                }
                .keyboardShortcut("f", modifiers: [.command])

                Divider()

                Button("Open Selected Connection") {
                    appState.openSelectedConnection()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("Open SFTP for Selected Connection") {
                    guard let connection = appState.selectedConnection else { return }
                    appState.openSFTP(connection)
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(appState.selectedConnection?.kind != .ssh)

                Button("Connection Check…") {
                    guard let connection = appState.selectedConnection else { return }
                    openWindow(id: "connection-check", value: ConnectionEditorRequest(connection: connection))
                }
                .disabled(appState.selectedConnection == nil)

                Divider()

                Button("Import Connections…") {
                    appState.chooseConnectionArchiveToImport()
                }
                Button("Import Other Formats…") { openWindow(id: "migration-import") }

                Button("Export Connections…") {
                    appState.requestConnectionExport()
                }

                Button("Manage Credential Profiles…") {
                    openWindow(id: "credential-manager")
                }

                Divider()

                Button("Export Redacted Diagnostics…") {
                    appState.exportDiagnostics()
                }
            }
        }

        WindowGroup("Connection", id: "connection-editor", for: ConnectionEditorRequest.self) { request in
            if let request = request.wrappedValue {
                ConnectionEditorView(
                    connection: request.connectionID.flatMap { connectionID in
                        appState.connections.first { $0.id == connectionID }
                    },
                    initialGroup: request.initialGroup
                )
                .environmentObject(appState)
                .environmentObject(appState.libraryTools)
                .modifier(PrivacyProtectedView(privacy: privacy))
            } else {
                ConnectionEditorView()
                    .environmentObject(appState)
                    .environmentObject(appState.libraryTools)
                    .modifier(PrivacyProtectedView(privacy: privacy))
            }
        }
        .windowResizability(.contentSize)

        WindowGroup("Connection Library", id: "connection-transfer", for: ConnectionTransferRequest.self) { request in
            if let request = request.wrappedValue {
                ConnectionTransferView(request: request)
                    .environmentObject(appState)
                    .modifier(PrivacyProtectedView(privacy: privacy))
            } else {
                ContentUnavailableView("No transfer selected", systemImage: "arrow.left.arrow.right")
                    .frame(width: 560, height: 500)
            }
        }
        .windowResizability(.contentSize)

        Window("Nethriva Help", id: NethrivaWindow.help) {
            NethrivaHelpView()
        }
        .defaultSize(width: 1040, height: 760)
        .windowResizability(.contentMinSize)

        Window("Nethriva Updates", id: "verified-updates") { VerifiedUpdatesView() }
            .windowResizability(.contentSize)

        WindowGroup("Connection Check", id: "connection-check", for: ConnectionEditorRequest.self) { request in
            if let id = request.wrappedValue?.connectionID, let connection = appState.connections.first(where: { $0.id == id }) {
                ConnectionCheckView(connection: connection).environmentObject(appState)
                    .modifier(PrivacyProtectedView(privacy: privacy))
            } else {
                ContentUnavailableView("Select an existing connection", systemImage: "stethoscope")
            }
        }
        .defaultSize(width: 700, height: 500)

        Window("Credential Profiles", id: "credential-manager") {
            CredentialManagerView()
                .environmentObject(appState)
                .modifier(PrivacyProtectedView(privacy: privacy))
        }
        .defaultSize(width: 780, height: 510)

        Window("Quick Connect", id: "quick-connect") {
            QuickConnectView().environmentObject(appState).environmentObject(settings).modifier(PrivacyProtectedView(privacy: privacy))
        }.windowResizability(.contentSize)
        Window("SSH Tunnels", id: "ssh-tunnels") {
            TunnelManagerView().environmentObject(appState).environmentObject(workflows).environmentObject(tunnels).modifier(PrivacyProtectedView(privacy: privacy))
        }.defaultSize(width: 780, height: 580)
        Window("Command Snippets", id: "command-snippets") {
            SnippetManagerView(router: surfaces.router).environmentObject(appState).environmentObject(workflows).modifier(PrivacyProtectedView(privacy: privacy))
        }.defaultSize(width: 800, height: 620)
        Window("Multi-Session Command", id: "multi-session-command") {
            MultiSessionCommandView(router: surfaces.router).environmentObject(appState).modifier(PrivacyProtectedView(privacy: privacy))
        }.defaultSize(width: 780, height: 560)
        Window("Terminal Profiles & Templates", id: "library-tools") {
            LibraryToolsView(library: appState.libraryTools).environmentObject(appState).modifier(PrivacyProtectedView(privacy: privacy))
        }.defaultSize(width: 760, height: 650)
        Window("Bulk Edit Connections", id: "bulk-edit") {
            BulkConnectionEditView(library: appState.libraryTools).environmentObject(appState).modifier(PrivacyProtectedView(privacy: privacy))
        }.defaultSize(width: 940, height: 700)
        Window("Import Other Formats", id: "migration-import") {
            MigrationImportView().environmentObject(appState).environmentObject(settings).modifier(PrivacyProtectedView(privacy: privacy))
        }.defaultSize(width: 850, height: 700)

        Window("Shared Connection Libraries", id: "shared-libraries") {
            SharedLibrariesView(library: appState.sharedLibraries).environmentObject(appState).modifier(PrivacyProtectedView(privacy: privacy))
        }.defaultSize(width: 850, height: 640)

        Settings {
            NethrivaSettingsView()
                .environmentObject(settings)
                .environmentObject(appState.libraryTools)
                .environmentObject(surfaces)
                .environmentObject(privacy)
                .modifier(PrivacyProtectedView(privacy: privacy))
        }
    }
    private func switchSession(offset: Int) {
        if let id = SessionKeyboardNavigation.next(ids: appState.tabs.map(\.id), selected: appState.selectedTabID, offset: offset) { surfaces.activate(id) }
    }
}
