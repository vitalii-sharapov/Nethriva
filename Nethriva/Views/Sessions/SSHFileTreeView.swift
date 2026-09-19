import AppKit
import SwiftUI
import UniformTypeIdentifiers

private let nethrivaTreeItemType = UTType(exportedAs: "com.vitalii.nethriva.remote-tree-item")

private struct RemoteTreeDragPayload: Codable {
    let connectionID: UUID
    let path: String
}

struct SSHFileTreeView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var model: SSHFileTreeModel

    let connection: RemoteConnection

    @State private var newFolderName = ""
    @State private var isCreatingFolder = false
    @State private var isRootDropTargeted = false

    init(connection: RemoteConnection) {
        self.connection = connection
        _model = StateObject(wrappedValue: SSHFileTreeModel(connection: connection))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let errorMessage = model.errorMessage {
                errorBanner(errorMessage)
                Divider()
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if model.nodes.isEmpty, !model.isLoading {
                        ContentUnavailableView {
                            Label("Empty Folder", systemImage: "folder")
                        } description: {
                            Text("Drop files or folders here to upload them.")
                        }
                        .frame(maxWidth: .infinity, minHeight: 180)
                    } else {
                        ForEach(model.nodes) { node in
                            SSHFileTreeNodeView(node: node, model: model, depth: 0)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(isRootDropTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
            .onDrop(
                of: [nethrivaTreeItemType, .fileURL],
                isTargeted: $isRootDropTargeted
            ) { providers in
                model.acceptDrop(providers, into: model.currentPath)
            }
            .overlay {
                if model.isLoading {
                    ProgressView(model.activityText)
                        .controlSize(.small)
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }

            Divider()
            statusBar
        }
        .frame(minWidth: 220, idealWidth: 270, maxWidth: 420, maxHeight: .infinity)
        .task {
            do {
                await model.start(password: try appState.password(for: connection))
            } catch {
                model.errorMessage = "Could not read the saved password: \(error.localizedDescription)"
            }
        }
        .alert("New Remote Folder", isPresented: $isCreatingFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                Task { await model.createDirectory(named: name, in: model.currentPath) }
            }
            .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Create a folder in \(model.currentPath).")
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 7) {
                Label("Remote Files", systemImage: "folder")
                    .font(.callout.weight(.semibold))

                Spacer()

                Button(action: goUp) {
                    Image(systemName: "arrow.up")
                }
                .help("Parent folder")
                .disabled(model.currentPath == "/" || model.isLoading)

                Button {
                    Task { await model.open(path: ".") }
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
            }

            HStack(spacing: 7) {
                Text(model.currentPath)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                Spacer()

                Button {
                    newFolderName = ""
                    isCreatingFolder = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .help("New remote folder")
                .disabled(model.isLoading)

                Button(action: chooseItemsToUpload) {
                    Image(systemName: "arrow.up.doc")
                }
                .help("Upload files or folders")
                .disabled(model.isLoading)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var statusBar: some View {
        HStack(spacing: 6) {
            if model.isLoading {
                ProgressView().controlSize(.small)
                Text(model.activityText)
            } else {
                Image(systemName: "arrow.up.arrow.down")
                Text("Drop to transfer")
            }
            Spacer()
            Text("\(model.nodes.count)")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .frame(height: 27)
        .background(.bar)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 2)
            Button {
                model.errorMessage = nil
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Retry")
            Button {
                model.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding(8)
        .background(Color.orange.opacity(0.08))
    }

    private func goUp() {
        let parent = (model.currentPath as NSString).deletingLastPathComponent
        Task { await model.open(path: parent.isEmpty ? "/" : parent) }
    }

    private func chooseItemsToUpload() {
        let panel = NSOpenPanel()
        panel.title = "Upload to \(model.currentPath)"
        panel.prompt = "Upload"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            Task { await model.upload(localURLs: panel.urls, to: model.currentPath) }
        }
    }
}

private struct SSHFileTreeNodeView: View {
    @ObservedObject var node: SSHFileTreeNode
    @ObservedObject var model: SSHFileTreeModel
    let depth: Int

    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row

            if node.isExpanded {
                if node.isLoading {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.mini)
                        Text("Loading…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, CGFloat(depth + 1) * 16 + 25)
                    .padding(.vertical, 4)
                } else if let children = node.children {
                    ForEach(children) { child in
                        SSHFileTreeNodeView(node: child, model: model, depth: depth + 1)
                    }
                }
            }
        }
    }

    private var row: some View {
        HStack(spacing: 5) {
            if node.item.isDirectory {
                Button {
                    Task { await model.toggle(node) }
                } label: {
                    Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 12, height: 1)
            }

            Image(systemName: iconName)
                .foregroundStyle(node.item.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 17)

            Text(node.item.name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 3)

            if !node.item.isDirectory {
                Text(node.item.displaySize)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, CGFloat(depth) * 16)
        .padding(.horizontal, 5)
        .frame(height: 25)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(rowBackground)
        )
        .onTapGesture(count: 2) {
            if node.item.isDirectory {
                Task { await model.open(path: node.item.path) }
            } else {
                chooseDownloadDestination()
            }
        }
        .onTapGesture {
            model.selectedPath = node.item.path
        }
        .onDrag {
            model.itemProvider(for: node.item)
        }
        .onDrop(
            of: node.item.isDirectory ? [nethrivaTreeItemType, .fileURL] : [],
            isTargeted: $isDropTargeted
        ) { providers in
            model.acceptDrop(providers, into: node.item.path)
        }
        .contextMenu {
            if node.item.isDirectory {
                Button("Open as Root") {
                    Task { await model.open(path: node.item.path) }
                }
            }
            Button("Download…", action: chooseDownloadDestination)
            Button("Copy Remote Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.item.path, forType: .string)
            }
        }
    }

    private var rowBackground: Color {
        if isDropTargeted { return Color.accentColor.opacity(0.2) }
        if model.selectedPath == node.item.path { return Color.accentColor.opacity(0.14) }
        return .clear
    }

    private var iconName: String {
        if node.item.isDirectory { return node.isExpanded ? "folder.fill.badge.minus" : "folder.fill" }
        if node.item.isSymbolicLink { return "link" }
        let ext = (node.item.name as NSString).pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "heic", "webp"].contains(ext) { return "photo" }
        if ["zip", "gz", "bz2", "xz", "tar", "7z"].contains(ext) { return "archivebox" }
        if ["sh", "zsh", "bash", "py", "js", "swift", "c", "cpp"].contains(ext) {
            return "chevron.left.forwardslash.chevron.right"
        }
        return "doc"
    }

    private func chooseDownloadDestination() {
        if node.item.isDirectory {
            let panel = NSOpenPanel()
            panel.title = "Download \(node.item.name)"
            panel.prompt = "Download Here"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let directory = panel.url else { return }
            Task {
                await model.download(
                    item: node.item,
                    to: directory.appendingPathComponent(node.item.name)
                )
            }
        } else {
            let panel = NSSavePanel()
            panel.title = "Download \(node.item.name)"
            panel.nameFieldStringValue = node.item.name
            panel.prompt = "Download"
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            Task { await model.download(item: node.item, to: destination) }
        }
    }
}

@MainActor
private final class SSHFileTreeNode: ObservableObject, Identifiable {
    nonisolated let id: String
    let item: SFTPFileItem
    @Published var children: [SSHFileTreeNode]?
    @Published var isExpanded = false
    @Published var isLoading = false

    init(item: SFTPFileItem) {
        id = item.id
        self.item = item
    }
}

@MainActor
private final class SSHFileTreeModel: ObservableObject {
    @Published var nodes: [SSHFileTreeNode] = []
    @Published var currentPath = "."
    @Published var selectedPath: String?
    @Published var isLoading = false
    @Published var activityText = "Connecting…"
    @Published var errorMessage: String?

    private let connection: RemoteConnection
    private let service = SFTPService()
    private var password: String?
    private var hasStarted = false

    init(connection: RemoteConnection) {
        self.connection = connection
    }

    func start(password: String?) async {
        self.password = password
        guard !hasStarted else { return }
        hasStarted = true
        await open(path: ".")
    }

    func open(path: String) async {
        await perform("Loading files…") {
            let listing = try await service.list(
                connection: connection,
                password: password,
                path: path
            )
            currentPath = listing.path
            nodes = listing.items.map(SSHFileTreeNode.init)
            selectedPath = nil
        }
    }

    func refresh() async {
        await open(path: currentPath)
    }

    func toggle(_ node: SSHFileTreeNode) async {
        guard node.item.isDirectory else { return }
        node.isExpanded.toggle()
        guard node.isExpanded, node.children == nil else { return }
        await loadChildren(of: node)
    }

    func upload(localURLs: [URL], to remoteDirectory: String) async {
        let urls = localURLs.filter(\.isFileURL)
        guard !urls.isEmpty else { return }
        await perform("Uploading \(urls.count) item\(urls.count == 1 ? "" : "s")…") {
            try await service.upload(
                localURLs: urls,
                to: remoteDirectory,
                connection: connection,
                password: password
            )
            try await reload(directory: remoteDirectory)
        }
    }

    func download(item: SFTPFileItem, to localURL: URL) async {
        await perform("Downloading \(item.name)…") {
            try await service.download(
                item: item,
                to: localURL,
                connection: connection,
                password: password
            )
        }
    }

    func createDirectory(named name: String, in remoteDirectory: String) async {
        await perform("Creating folder…") {
            try await service.createDirectory(
                named: name,
                in: remoteDirectory,
                connection: connection,
                password: password
            )
            try await reload(directory: remoteDirectory)
        }
    }

    func move(remotePath: String, to remoteDirectory: String) async {
        guard remotePath != remoteDirectory,
              (remotePath as NSString).deletingLastPathComponent != remoteDirectory else { return }
        await perform("Moving \((remotePath as NSString).lastPathComponent)…") {
            try await service.move(
                remotePath: remotePath,
                to: remoteDirectory,
                connection: connection,
                password: password
            )
            try await reload(directory: currentPath)
        }
    }

    func itemProvider(for item: SFTPFileItem) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = item.name

        let payload = RemoteTreeDragPayload(connectionID: connection.id, path: item.path)
        if let data = try? JSONEncoder().encode(payload) {
            provider.registerDataRepresentation(
                forTypeIdentifier: nethrivaTreeItemType.identifier,
                visibility: .ownProcess
            ) { completion in
                completion(data, nil)
                return nil
            }
        }

        let contentType = item.isDirectory ? UTType.folder : UTType.data
        let service = self.service
        let connection = self.connection
        let password = self.password
        provider.registerFileRepresentation(
            forTypeIdentifier: contentType.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            let progress = Progress(totalUnitCount: 1)
            Task {
                do {
                    let transferRoot = FileManager.default.temporaryDirectory
                        .appendingPathComponent("NethrivaDrag-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(
                        at: transferRoot,
                        withIntermediateDirectories: true
                    )
                    let localURL = transferRoot.appendingPathComponent(
                        item.name,
                        isDirectory: item.isDirectory
                    )
                    try await service.download(
                        item: item,
                        to: localURL,
                        connection: connection,
                        password: password
                    )
                    progress.completedUnitCount = 1
                    completion(localURL, false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return progress
        }

        return provider
    }

    func acceptDrop(_ providers: [NSItemProvider], into remoteDirectory: String) -> Bool {
        if let internalProvider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(nethrivaTreeItemType.identifier)
        }) {
            internalProvider.loadDataRepresentation(
                forTypeIdentifier: nethrivaTreeItemType.identifier
            ) { [weak self] data, error in
                guard let data,
                      error == nil,
                      let payload = try? JSONDecoder().decode(RemoteTreeDragPayload.self, from: data)
                else { return }
                Task { @MainActor [weak self] in
                    guard let self, payload.connectionID == self.connection.id else { return }
                    await self.move(remotePath: payload.path, to: remoteDirectory)
                }
            }
            return true
        }

        let localProviders = providers.filter { $0.canLoadObject(ofClass: NSURL.self) }
        guard !localProviders.isEmpty else { return false }
        Task { @MainActor [weak self] in
            guard let self else { return }
            var urls: [URL] = []
            for provider in localProviders {
                if let url = await Self.fileURL(from: provider) {
                    urls.append(url)
                }
            }
            await self.upload(localURLs: urls, to: remoteDirectory)
        }
        return true
    }

    private func loadChildren(of node: SSHFileTreeNode) async {
        node.isLoading = true
        defer { node.isLoading = false }
        do {
            let listing = try await service.list(
                connection: connection,
                password: password,
                path: node.item.path
            )
            node.children = listing.items.map(SSHFileTreeNode.init)
        } catch {
            node.isExpanded = false
            errorMessage = error.localizedDescription
        }
    }

    private func reload(directory: String) async throws {
        if directory == currentPath {
            let listing = try await service.list(
                connection: connection,
                password: password,
                path: currentPath
            )
            nodes = listing.items.map(SSHFileTreeNode.init)
            return
        }

        if let node = findNode(path: directory, in: nodes) {
            let listing = try await service.list(
                connection: connection,
                password: password,
                path: directory
            )
            node.children = listing.items.map(SSHFileTreeNode.init)
            node.isExpanded = true
        } else {
            let listing = try await service.list(
                connection: connection,
                password: password,
                path: currentPath
            )
            nodes = listing.items.map(SSHFileTreeNode.init)
        }
    }

    private func findNode(path: String, in nodes: [SSHFileTreeNode]) -> SSHFileTreeNode? {
        for node in nodes {
            if node.item.path == path { return node }
            if let children = node.children,
               let match = findNode(path: path, in: children) {
                return match
            }
        }
        return nil
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

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: NSURL.self) { object, _ in
                let url = (object as? NSURL).map { $0 as URL }
                continuation.resume(returning: url)
            }
        }
    }
}
