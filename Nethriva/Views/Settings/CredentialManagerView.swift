import SwiftUI

struct CredentialManagerView: View {
    @EnvironmentObject private var appState: AppState

    @State private var selectedID: UUID?
    @State private var draftID = UUID()
    @State private var isCreating = false
    @State private var name = ""
    @State private var username = ""
    @State private var domain = ""
    @State private var newPassword = ""
    @State private var hasSavedPassword = false
    @State private var removeSavedPassword = false
    @State private var confirmDelete = false
    @State private var errorMessage: String?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selectedID) {
                    ForEach(appState.credentialProfiles) { profile in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name).fontWeight(.medium)
                            Text(profile.username)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(profile.id)
                    }
                }
                Divider()
                Button {
                    beginNew()
                } label: {
                    Label("New Profile", systemImage: "plus")
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 230)

            Divider()

            if isCreating || selectedID != nil {
                editor
            } else {
                ContentUnavailableView(
                    "Credential Profiles",
                    systemImage: "key.horizontal",
                    description: Text("Create a profile for accounts shared by multiple SSH, Telnet, or RDP connections.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 720, minHeight: 450)
        .navigationTitle("Credential Profiles")
        .onChange(of: selectedID) { _, newID in
            guard let newID, let profile = appState.credentialProfiles.first(where: { $0.id == newID }) else { return }
            load(profile)
        }
        .alert("Delete Credential Profile?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { deleteSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the profile and its Keychain password. It cannot be undone.")
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section(isCreating ? "New Profile" : "Edit Profile") {
                    TextField("Profile Name", text: $name, prompt: Text("Network admin"))
                    TextField("Username", text: $username)
                        .textContentType(.username)
                    TextField("Windows Domain (optional)", text: $domain)
                    SecureField("New Password", text: $newPassword)
                        .textContentType(.newPassword)
                        .onChange(of: newPassword) { _, value in
                            if !value.isEmpty { removeSavedPassword = false }
                        }
                    if hasSavedPassword {
                        if removeSavedPassword {
                            Label("Saved password will be removed when you save.", systemImage: "key.slash")
                                .foregroundStyle(.orange)
                            Button("Keep Saved Password") { removeSavedPassword = false }
                        } else {
                            Label("Password stored in macOS Keychain", systemImage: "key.fill")
                                .foregroundStyle(.secondary)
                            Button("Remove Saved Password", role: .destructive) {
                                newPassword = ""
                                removeSavedPassword = true
                            }
                        }
                    }
                }
                Section {
                    Text("The Windows domain applies to RDP only. Changing this profile will affect all linked connections the next time they open or reconnect. Existing sessions remain active.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if !isCreating, let selectedID {
                    let usage = appState.profileUsageCount(selectedID)
                    Button("Delete Profile", role: .destructive) { confirmDelete = true }
                        .disabled(usage > 0)
                    if usage > 0 {
                        Text("Used by \(usage) connection\(usage == 1 ? "" : "s"); unlink before deleting.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Button("Save Profile") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func beginNew() {
        selectedID = nil
        isCreating = true
        draftID = UUID()
        name = ""
        username = ""
        domain = ""
        newPassword = ""
        hasSavedPassword = false
        removeSavedPassword = false
        errorMessage = nil
    }

    private func load(_ profile: CredentialProfile) {
        isCreating = false
        draftID = profile.id
        name = profile.name
        username = profile.username
        domain = profile.domain
        newPassword = ""
        removeSavedPassword = false
        hasSavedPassword = (try? appState.hasSavedPassword(for: profile)) ?? false
        errorMessage = nil
    }

    private func save() {
        let profile = CredentialProfile(id: draftID, name: name, username: username, domain: domain)
        do {
            try appState.saveProfile(
                profile,
                password: newPassword.isEmpty ? nil : newPassword,
                removeSavedPassword: removeSavedPassword
            )
            selectedID = profile.id
            load(profile)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteSelected() {
        guard let selectedID,
              let profile = appState.credentialProfiles.first(where: { $0.id == selectedID }) else { return }
        do {
            try appState.deleteProfile(profile)
            self.selectedID = nil
            isCreating = false
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
