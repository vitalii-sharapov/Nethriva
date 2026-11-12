import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ConnectionTransferRequest: Codable, Hashable, Identifiable {
    enum Operation: Codable, Hashable {
        case export
        case importFile(URL)
    }

    let id: UUID
    let operation: Operation

    init(operation: Operation) {
        self.id = UUID()
        self.operation = operation
    }
}

struct ConnectionTransferView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    let request: ConnectionTransferRequest

    @State private var includeCredentials = false
    @State private var exportPassword = ""
    @State private var confirmPassword = ""
    @State private var importPassword = ""
    @State private var archiveData: Data?
    @State private var archive: ConnectionArchive?
    @State private var requiresPassword = false
    @State private var conflictPolicy: ConnectionImportConflictPolicy = .keepExisting
    @State private var approvedCapabilities = Set<UUID>()
    @State private var approvedCredentialReuse = Set<UUID>()
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var completionMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.title2.bold())
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            Divider()

            if let completionMessage {
                ContentUnavailableView(
                    "Complete",
                    systemImage: "checkmark.circle.fill",
                    description: Text(completionMessage)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch request.operation {
                case .export:
                    exportContent
                case .importFile:
                    importContent
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(width: 680, height: 680)
        .navigationTitle(title)
        .task { await prepareImportIfNeeded() }
        .onDisappear {
            exportPassword = ""
            confirmPassword = ""
            importPassword = ""
            archiveData = nil
            archive = nil
        }
    }

    private var title: String {
        switch request.operation {
        case .export: "Export Connections"
        case .importFile: "Import Connections"
        }
    }

    private var icon: String {
        switch request.operation {
        case .export: "square.and.arrow.up"
        case .importFile: "square.and.arrow.down"
        }
    }

    @ViewBuilder
    private var exportContent: some View {
        Form {
            Section("Contents") {
                LabeledContent("Connections", value: "\(exportConnectionCount)")
                LabeledContent("Groups", value: "\(appState.groups.count)")
                LabeledContent("Credential profiles", value: "\(appState.credentialProfiles.count)")
                Toggle("Include saved credentials", isOn: $includeCredentials)
            }

            if includeCredentials {
                Section("Encryption") {
                    SecureField("Export password", text: $exportPassword)
                        .textContentType(.newPassword)
                    SecureField("Confirm password", text: $confirmPassword)
                        .textContentType(.newPassword)
                    Text("Use a unique passphrase of at least 15 characters. Credentials use AES-256-GCM with PBKDF2-HMAC-SHA256. This passphrase cannot be recovered.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Text("The export contains connections, groups, and credential-profile names, usernames, and domains. It contains no passwords.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)

        Spacer()

        HStack {
            Spacer()
            if isBusy { ProgressView().controlSize(.small) }
            Button("Export…") {
                Task { await exportConnections() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isBusy || (exportConnectionCount == 0 && appState.credentialProfiles.isEmpty) || !exportPasswordIsValid)
        }
    }

    @ViewBuilder
    private var importContent: some View {
        if isBusy && archive == nil {
            VStack(spacing: 14) {
                ProgressView()
                Text(requiresPassword ? "Decrypting archive…" : "Reading archive…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if requiresPassword && archive == nil {
            Form {
                Section("Encrypted archive") {
                    SecureField("Archive password", text: $importPassword)
                        .textContentType(.password)
                    Text("Enter the password chosen when this credential export was created.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Spacer()
            HStack {
                Spacer()
                Button("Unlock") {
                    Task { await unlockImport() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(importPassword.isEmpty || isBusy)
            }
        } else if let archive {
            importPreview(archive)
        } else {
            ContentUnavailableView(
                "Archive unavailable",
                systemImage: "doc.badge.ellipsis",
                description: Text("Select Import Connections again to choose another archive.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func importPreview(_ archive: ConnectionArchive) -> some View {
        let currentConnectionIDs = Set(appState.connections.map(\.id))
        let currentProfileIDs = Set(appState.credentialProfiles.map(\.id))
        let duplicateCount = archive.connections.filter { currentConnectionIDs.contains($0.id) }.count
        let duplicateProfileCount = archive.profiles.filter { currentProfileIDs.contains($0.id) }.count

        return VStack(alignment: .leading, spacing: 16) {
            GroupBox("Archive Preview") {
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 9) {
                    previewRow("Connections", "\(archive.connections.count)")
                    previewRow("Groups", "\(archive.groups.count)")
                    previewRow("Credential profiles", "\(archive.profiles.count)")
                    previewRow("Saved credentials", "\(archive.credentials.count + archive.profileCredentials.count)")
                    previewRow("Already in library", "\(duplicateCount)")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            if !archive.groups.isEmpty {
                GroupBox("Groups") {
                    Text(archive.groups.joined(separator: ", "))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(4)
                        .padding(.vertical, 4)
                }
            }

            importSecurityReview(archive)

            if duplicateCount + duplicateProfileCount > 0 {
                Picker("Matching connections or profiles", selection: $conflictPolicy) {
                    ForEach(ConnectionImportConflictPolicy.allCases) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                Text(conflictPolicy.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack {
                Spacer()
                if isBusy { ProgressView().controlSize(.small) }
                Button("Import") {
                    importConnections(archive)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isBusy)
            }
        }
    }

    private func importSecurityReview(_ archive: ConnectionArchive) -> some View {
        GroupBox("Review targets and local access") {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    Text("Existing credentials stay with their original login identity. Changed targets become separate items. Access settings from the file are disabled unless you approve the listed settings below.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(archive.connections) { connection in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(connection.name).font(.callout.bold())
                            Text("\(connection.kind.rawValue) · \(connection.host):\(connection.port)")
                                .font(.caption.monospaced()).textSelection(.enabled)
                            if !connection.username.isEmpty {
                                Text("Imported account: \(connection.username)").font(.caption)
                            }
                            let capabilities = ConnectionImportSecurity.capabilities(connection)
                            if !capabilities.isEmpty {
                                Text(capabilities.joined(separator: "; ")).font(.caption).foregroundStyle(.secondary)
                                Toggle("Restore these access settings for this target", isOn: Binding(
                                    get: { approvedCapabilities.contains(connection.id) },
                                    set: { if $0 { approvedCapabilities.insert(connection.id) } else { approvedCapabilities.remove(connection.id) } }
                                )).font(.caption)
                            }
                            if let profileID = connection.credentialProfileID,
                               let current = appState.credentialProfiles.first(where: { $0.id == profileID }) {
                                Text("Current saved profile: \(current.name) — \(current.username)\(current.domain.isEmpty ? "" : " (" + current.domain + ")")")
                                    .font(.caption).foregroundStyle(.secondary)
                                Toggle("Allow this current credential profile for this target", isOn: Binding(
                                    get: { approvedCredentialReuse.contains(connection.id) },
                                    set: { if $0 { approvedCredentialReuse.insert(connection.id) } else { approvedCredentialReuse.remove(connection.id) } }
                                )).font(.caption)
                            }
                        }
                        Divider()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }.frame(minHeight: 110, maxHeight: .infinity)
        }
    }

    private func previewRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).bold()
        }
    }

    private var exportConnectionCount: Int {
        appState.connections.filter { $0.kind != .localShell }.count
    }

    private var exportPasswordIsValid: Bool {
        !includeCredentials || (ConnectionTransferService.validExportPassword(exportPassword) && exportPassword == confirmPassword)
    }

    @MainActor
    private func exportConnections() async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        do {
            let archive = try appState.makeConnectionArchive(includeCredentials: includeCredentials)
            let password = exportPassword
            let shouldIncludeCredentials = includeCredentials
            let data = try await Task.detached(priority: .userInitiated) {
                if shouldIncludeCredentials {
                    return try ConnectionTransferService.encodeEncrypted(archive, password: password)
                }
                return try ConnectionTransferService.encodePlain(archive)
            }.value

            let panel = NSSavePanel()
            panel.title = "Export Nethriva Connections"
            panel.canCreateDirectories = true
            let fileExtension = shouldIncludeCredentials
                ? ConnectionTransferService.encryptedFilenameExtension
                : ConnectionTransferService.plainFilenameExtension
            panel.allowedContentTypes = [UTType(filenameExtension: fileExtension) ?? .data]
            panel.nameFieldStringValue = "Nethriva Connections"
            guard panel.runModal() == .OK, let url = panel.url else { return }

            try ConnectionTransferService.write(data, to: url)
            completionMessage = shouldIncludeCredentials
                ? "The encrypted connection archive was saved. Keep its password somewhere safe."
                : "The credential-free connection archive was saved."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func prepareImportIfNeeded() async {
        guard case .importFile(let url) = request.operation, archiveData == nil else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let (data, inspection) = try await Task.detached(priority: .userInitiated) {
                let data = try ConnectionTransferService.read(from: url)
                return (data, try ConnectionTransferService.inspect(data))
            }.value
            archiveData = data
            switch inspection.content {
            case .plain(let archive):
                self.archive = archive
            case .encrypted:
                requiresPassword = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func unlockImport() async {
        guard let archiveData else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let password = importPassword
            archive = try await Task.detached(priority: .userInitiated) {
                try ConnectionTransferService.decodeEncrypted(archiveData, password: password)
            }.value
            importPassword = ""
            requiresPassword = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func importConnections(_ archive: ConnectionArchive) {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let summary = try appState.importConnectionArchive(
                archive,
                conflictPolicy: conflictPolicy,
                options: ConnectionImportOptions(approvedCapabilities: approvedCapabilities,
                    approvedCredentialReuse: approvedCredentialReuse)
            )
            completionMessage = summary.message
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
