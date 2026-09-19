import AppKit
import SwiftUI

struct SFTPBrowserView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var model: SFTPBrowserModel

    let connection: RemoteConnection

    @State private var namePrompt: NamePrompt?
    @State private var nameInput = ""
    @State private var pendingDeletion: SFTPFileItem?

    init(connection: RemoteConnection) {
        self.connection = connection
        _model = StateObject(wrappedValue: SFTPBrowserModel(connection: connection))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if model.items.isEmpty, !model.isLoading {
                ContentUnavailableView {
                    Label("Empty Folder", systemImage: "folder")
                } description: {
                    Text(model.currentPath)
                } actions: {
                    Button("Upload Files…", action: chooseFilesToUpload)
                }
                .dropDestination(for: URL.self, action: acceptDrop)
            } else {
                fileList
            }

            Divider()
            statusBar
        }
        .task {
            do {
                model.password = try appState.password(for: connection)
                await model.load(path: ".")
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
        .alert(namePrompt?.title ?? "SFTP Action", isPresented: Binding(
            get: { namePrompt != nil },
            set: { if !$0 { namePrompt = nil } }
        )) {
            TextField("Name", text: $nameInput)
            Button("Cancel", role: .cancel) {
                namePrompt = nil
            }
            Button(namePrompt?.actionTitle ?? "Save") {
                guard let prompt = namePrompt else { return }
                let value = nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                namePrompt = nil
                guard !value.isEmpty else { return }
                Task {
                    switch prompt {
                    case .newFolder:
                        await model.createDirectory(named: value)
                    case .rename(let item):
                        await model.rename(item: item, to: value)
                    }
                }
            }
            .disabled(nameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text(namePrompt?.message ?? "")
        }
        .confirmationDialog(
            "Delete \(pendingDeletion?.name ?? "item")?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let item = pendingDeletion else { return }
                pendingDeletion = nil
                Task { await model.delete(item: item) }
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            Text(pendingDeletion?.isDirectory == true
                ? "Only empty remote folders can be deleted."
                : "This permanently deletes the remote file.")
        }
        .alert("SFTP Error", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("Open SSH Session") {
                appState.open(connection)
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 9) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(connection.name)
                    .font(.callout.weight(.semibold))
                Text(model.currentPath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }

            Spacer()

            Button(action: goUp) {
                Image(systemName: "arrow.up")
            }
            .help("Parent folder")
            .disabled(model.currentPath == "/" || model.isLoading)

            Button {
                Task { await model.load(path: ".") }
            } label: {
                Image(systemName: "house")
            }
            .help("Home folder")
            .disabled(model.isLoading)

            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")
            .disabled(model.isLoading)

            Divider().frame(height: 18)

            Button(action: promptForNewFolder) {
                Image(systemName: "folder.badge.plus")
            }
            .help("New remote folder")
            .disabled(model.isLoading)

            Button(action: chooseFilesToUpload) {
                Image(systemName: "arrow.up.doc")
            }
            .help("Upload files")
            .disabled(model.isLoading)

            Button(action: chooseDownloadDestination) {
                Image(systemName: "arrow.down.doc")
            }
            .help("Download selected file or folder")
            .disabled(model.selectedItem == nil || model.isLoading)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(.bar)
    }

    private var fileList: some View {
        List(selection: $model.selectedID) {
            ForEach(model.items) { item in
                HStack(spacing: 10) {
                    Image(systemName: item.isDirectory ? "folder.fill" : fileIcon(for: item))
                        .foregroundStyle(item.isDirectory ? Color.accentColor : Color.secondary)
                        .frame(width: 20)

                    Text(item.name)
                        .lineLimit(1)

                    Spacer()

                    Text(item.displaySize)
                        .frame(width: 90, alignment: .trailing)
                        .foregroundStyle(.secondary)

                    Text(item.modifiedText)
                        .frame(width: 115, alignment: .leading)
                        .foregroundStyle(.secondary)

                    Text(item.permissions)
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 86, alignment: .leading)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
                .tag(item.id)
                .simultaneousGesture(
                    TapGesture(count: 1).onEnded {
                        model.selectedID = item.id
                    }
                )
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        activate(item)
                    }
                )
                .contextMenu {
                    if item.isDirectory {
                        Button("Open") { activate(item) }
                    }
                    Button("Download…") {
                        model.selectedID = item.id
                        chooseDownloadDestination()
                    }
                    Button("Rename…") { promptForRename(item) }
                    Divider()
                    Button("Delete", role: .destructive) {
                        pendingDeletion = item
                    }
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if model.isLoading {
                ProgressView(model.activityText)
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .dropDestination(for: URL.self, action: acceptDrop)
    }

    private var statusBar: some View {
        HStack {
            if model.isLoading {
                ProgressView().controlSize(.small)
                Text(model.activityText)
            } else {
                Text("\(model.items.count) item\(model.items.count == 1 ? "" : "s")")
            }
            Spacer()
            Text(connection.endpointDescription)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(.bar)
    }

    private func activate(_ item: SFTPFileItem) {
        model.selectedID = item.id
        guard item.isDirectory else { return }
        Task { await model.load(path: item.path) }
    }

    private func goUp() {
        let parent = (model.currentPath as NSString).deletingLastPathComponent
        Task { await model.load(path: parent.isEmpty ? "/" : parent) }
    }

    private func promptForNewFolder() {
        nameInput = ""
        namePrompt = .newFolder
    }

    private func promptForRename(_ item: SFTPFileItem) {
        nameInput = item.name
        namePrompt = .rename(item)
    }

    private func chooseFilesToUpload() {
        let panel = NSOpenPanel()
        panel.title = "Upload Files to \(model.currentPath)"
        panel.prompt = "Upload"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            let urls = panel.urls
            Task { await model.upload(urls: urls) }
        }
    }

    private func chooseDownloadDestination() {
        guard let item = model.selectedItem else { return }
        if item.isDirectory {
            let panel = NSOpenPanel()
            panel.title = "Download \(item.name)"
            panel.prompt = "Download Here"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            if panel.runModal() == .OK, let directory = panel.url {
                let destination = directory.appendingPathComponent(item.name, isDirectory: true)
                Task { await model.download(item: item, to: destination) }
            }
        } else {
            let panel = NSSavePanel()
            panel.title = "Download \(item.name)"
            panel.nameFieldStringValue = item.name
            panel.prompt = "Download"
            if panel.runModal() == .OK, let url = panel.url {
                Task { await model.download(item: item, to: url) }
            }
        }
    }

    private func acceptDrop(_ urls: [URL], _ location: CGPoint) -> Bool {
        let files = urls.filter { $0.isFileURL }
        guard !files.isEmpty else { return false }
        Task { await model.upload(urls: files) }
        return true
    }

    private func fileIcon(for item: SFTPFileItem) -> String {
        if item.isSymbolicLink { return "link" }
        let ext = (item.name as NSString).pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "heic", "webp"].contains(ext) { return "photo" }
        if ["zip", "gz", "bz2", "xz", "tar", "7z"].contains(ext) { return "archivebox" }
        if ["sh", "zsh", "bash", "py", "js", "swift", "c", "cpp"].contains(ext) { return "chevron.left.forwardslash.chevron.right" }
        return "doc"
    }
}

private enum NamePrompt: Identifiable {
    case newFolder
    case rename(SFTPFileItem)

    var id: String {
        switch self {
        case .newFolder: "new-folder"
        case .rename(let item): "rename-\(item.id)"
        }
    }

    var title: String {
        switch self {
        case .newFolder: "New Remote Folder"
        case .rename: "Rename Remote Item"
        }
    }

    var message: String {
        switch self {
        case .newFolder: "Enter a name for the new folder."
        case .rename: "Enter the new name."
        }
    }

    var actionTitle: String {
        switch self {
        case .newFolder: "Create"
        case .rename: "Rename"
        }
    }
}

@MainActor
final class SFTPBrowserModel: ObservableObject {
    @Published var items: [SFTPFileItem] = []
    @Published var currentPath = "."
    @Published var selectedID: SFTPFileItem.ID?
    @Published var isLoading = false
    @Published var activityText = "Connecting…"
    @Published var errorMessage: String?

    var password: String?

    private let connection: RemoteConnection
    private let service = SFTPService()

    init(connection: RemoteConnection) {
        self.connection = connection
    }

    var selectedItem: SFTPFileItem? {
        guard let selectedID else { return nil }
        return items.first { $0.id == selectedID }
    }

    func load(path: String) async {
        await perform("Loading \(path)…") {
            let listing = try await service.list(
                connection: connection,
                password: password,
                path: path
            )
            currentPath = listing.path
            items = listing.items
            selectedID = nil
        }
    }

    func refresh() async {
        await load(path: currentPath)
    }

    func upload(urls: [URL]) async {
        guard !urls.isEmpty else { return }
        await perform("Uploading \(urls.count) item\(urls.count == 1 ? "" : "s")…") {
            try await service.upload(
                localURLs: urls,
                to: currentPath,
                connection: connection,
                password: password
            )
            try await reloadCurrentDirectory()
        }
    }

    func download(item: SFTPFileItem, to url: URL) async {
        await perform("Downloading \(item.name)…") {
            try await service.download(
                item: item,
                to: url,
                connection: connection,
                password: password
            )
        }
    }

    func createDirectory(named name: String) async {
        await perform("Creating folder…") {
            try await service.createDirectory(
                named: name,
                in: currentPath,
                connection: connection,
                password: password
            )
            try await reloadCurrentDirectory()
        }
    }

    func rename(item: SFTPFileItem, to newName: String) async {
        await perform("Renaming \(item.name)…") {
            try await service.rename(
                item: item,
                to: newName,
                connection: connection,
                password: password
            )
            try await reloadCurrentDirectory()
        }
    }

    func delete(item: SFTPFileItem) async {
        await perform("Deleting \(item.name)…") {
            try await service.delete(item: item, connection: connection, password: password)
            try await reloadCurrentDirectory()
        }
    }

    private func reloadCurrentDirectory() async throws {
        let listing = try await service.list(
            connection: connection,
            password: password,
            path: currentPath
        )
        currentPath = listing.path
        items = listing.items
        selectedID = nil
    }

    private func perform(_ activity: String, operation: () async throws -> Void) async {
        guard !isLoading else { return }
        isLoading = true
        activityText = activity
        errorMessage = nil
        defer { isLoading = false }

        do {
            try await operation()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
