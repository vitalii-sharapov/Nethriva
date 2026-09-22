import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ConnectionTransferRequest: Identifiable {
    enum Operation {
        case export
        case importFile(URL)
    }

    let id = UUID()
    let operation: Operation
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
        .frame(width: 560, height: 500)
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
                Toggle("Include saved credentials", isOn: $includeCredentials)
            }

            if includeCredentials {
                Section("Encryption") {
                    SecureField("Export password", text: $exportPassword)
                        .textContentType(.newPassword)
                    SecureField("Confirm password", text: $confirmPassword)
                        .textContentType(.newPassword)
                    Text("Credentials are protected with password-based AES-256-GCM encryption. This password cannot be recovered.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Text("The export contains connection settings, favorites, groups, and empty groups. It contains no passwords.")
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
            .disabled(isBusy || exportConnectionCount == 0 || !exportPasswordIsValid)
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
        let duplicateCount = archive.connections.filter { imported in
            appState.connections.contains { $0.id == imported.id }
        }.count

        return VStack(alignment: .leading, spacing: 16) {
            GroupBox("Archive Preview") {
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 9) {
                    previewRow("Connections", "\(archive.connections.count)")
                    previewRow("Groups", "\(archive.groups.count)")
                    previewRow("Saved credentials", "\(archive.credentials.count)")
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

            if duplicateCount > 0 {
                Picker("Matching connections", selection: $conflictPolicy) {
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
        !includeCredentials || (exportPassword.count >= 8 && exportPassword == confirmPassword)
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
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            archiveData = data
            let inspection = try ConnectionTransferService.inspect(data)
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
                conflictPolicy: conflictPolicy
            )
            completionMessage = summary.message
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
