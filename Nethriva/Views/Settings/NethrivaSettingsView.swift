import SwiftUI

struct NethrivaSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: LibraryTools
    @EnvironmentObject private var surfaces: SessionSurfaceStore
    @EnvironmentObject private var privacy: PrivacyLock
    @Environment(\.openWindow) private var openWindow
    @State private var logNotice: String?
    @State private var confirmsCleanup = false

    var body: some View {
        Form {
            Section("Privacy Lock") {
                Button("Lock & Disconnect Sessions Now") { privacy.lock() }
                Toggle("Lock when Mac sleeps or its screen locks", isOn: $privacy.lockOnSleep)
                Picker("Lock after no activity in Nethriva", selection: $privacy.idleMinutes) {
                    Text("Never").tag(0); Text("5 minutes").tag(5); Text("15 minutes").tag(15); Text("30 minutes").tag(30); Text("1 hour").tag(60)
                }
                Text("Unlock with Touch ID or your Mac login password. Locking hides all Nethriva windows, disconnects sessions, stops recording/tunnels and clears temporary vault authorization. Reopen connections explicitly after unlocking. Automatic lock is off by default.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Sidebar") {
                Toggle("Show host addresses", isOn: $settings.showSidebarAddresses)
                Toggle("Show usernames", isOn: $settings.showSidebarUsernames)
                    .disabled(!settings.showSidebarAddresses)
            }

            Section("Sessions") {
                Toggle("Reconnect interrupted network sessions after sleep or network changes", isOn: $settings.recoverNetworkSessions)
                Text("Off by default. Reconnect may start a new shell or request login. Commands and interrupted file transfers are never replayed automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show host addresses in session headers", isOn: $settings.showSessionAddresses)
                Toggle("Show usernames in session headers", isOn: $settings.showSessionUsernames)
                    .disabled(!settings.showSessionAddresses)
            }

            Section("Terminal & Workflow") {
                Button("Terminal Profiles, Templates & Group Defaults…") { openWindow(id: "library-tools") }
                Text("Logging is off until started per terminal. Retention: \(library.data.retentionDays) days. Logs may contain private output; never share them without review.").font(.caption)
                HStack {
                    Button("Show Private Log Folder") { NSWorkspace.shared.open(surfaces.terminalTools.root) }
                        .disabled(!FileManager.default.fileExists(atPath: surfaces.terminalTools.root.path))
                    Button("Remove Expired Logs") { confirmsCleanup = true }
                }
                if let logNotice { Text(logNotice).font(.caption) }
                if let notice = surfaces.terminalTools.notice { Text(notice).foregroundStyle(.orange).font(.caption) }
            }
            Section {
                Text("Usernames are hidden by default. These controls affect Nethriva’s labels; connection names and text sent by a remote system, including shell prompts, remain unchanged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 650, height: 630)
        .confirmationDialog("Permanently remove expired session logs?", isPresented: $confirmsCleanup, titleVisibility: .visible) {
            Button("Remove Expired Logs", role: .destructive) {
                Task { @MainActor in
                    do { try await surfaces.terminalTools.prune(retentionDays: library.data.retentionDays); logNotice = "Expired app-owned logs removed. Active logs are retained." }
                    catch { logNotice = "The private log folder could not be cleaned." }
                }
            }
        } message: { Text("App-owned logs older than \(library.data.retentionDays) days will be permanently deleted, not moved to Trash. Active recordings and unrelated files are retained.") }
    }
}
