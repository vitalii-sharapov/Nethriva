import SwiftUI

struct NethrivaSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("Sidebar") {
                Toggle("Show host addresses", isOn: $settings.showSidebarAddresses)
                Toggle("Show usernames", isOn: $settings.showSidebarUsernames)
                    .disabled(!settings.showSidebarAddresses)
            }

            Section("Sessions") {
                Toggle("Show host addresses in session headers", isOn: $settings.showSessionAddresses)
                Toggle("Show usernames in session headers", isOn: $settings.showSessionUsernames)
                    .disabled(!settings.showSessionAddresses)
            }

            Section {
                Text("Usernames are hidden by default. These controls affect Nethriva’s labels; connection names and text sent by a remote system, including shell prompts, remain unchanged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 300)
    }
}
