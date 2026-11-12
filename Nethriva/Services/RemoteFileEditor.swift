import AppKit
import CryptoKit
import SwiftUI

struct RemoteTextSnapshot: Equatable {
    static let maximumBytes: UInt64 = 2 * 1024 * 1024
    let text: String
    let fingerprint: Data
    let mode: UInt32
    init(data: Data, mode: UInt32) throws {
        guard data.count <= Self.maximumBytes, !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw WorkflowError.invalid("Only UTF-8 text files up to 2 MiB can be edited.")
        }
        self.text = text; self.mode = mode; fingerprint = Data(SHA256.hash(data: data))
    }
    static func encode(_ text: String) throws -> Data {
        let data = Data(text.utf8)
        guard data.count <= maximumBytes, !data.contains(0) else { throw WorkflowError.invalid("The edited text exceeds 2 MiB or contains NUL characters.") }
        return data
    }
}

@MainActor
final class RemoteTextEditorModel: ObservableObject {
    @Published var text = ""
    @Published private(set) var baseline: RemoteTextSnapshot?
    @Published private(set) var busy = false
    @Published var error: String?
    @Published var conflict = false
    private let service = SFTPService()
    private let connection: RemoteConnection
    private let item: SFTPFileItem
    private weak var appState: AppState?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    var dirty: Bool { baseline.map { text != $0.text } ?? false }
    init(connection: RemoteConnection, item: SFTPFileItem, appState: AppState) {
        self.connection = connection; self.item = item; self.appState = appState
    }
    func load() {
        guard !busy else { return }
        busy = true; error = nil; conflict = false
        generation = UUID(); let generation = generation
        task = Task {
            defer { if self.generation == generation { busy = false } }
            do {
                let password = try await appState?.sessionPassword(for: connection)
                try Task.checkCancellation(); _ = try appState?.credentialGate.check()
                let snapshot = try await service.readText(path: item.path, connection: connection, password: password)
                try Task.checkCancellation(); guard self.generation == generation else { return }; baseline = snapshot; text = snapshot.text
            } catch { if self.generation == generation, !(error is CancellationError) { self.error = error.localizedDescription } }
        }
    }
    func save(overwriteChanged: Bool = false) {
        guard !busy, let baseline else { return }
        busy = true; error = nil; conflict = false
        generation = UUID(); let generation = generation
        let content = text
        task = Task {
            defer { if self.generation == generation { busy = false } }
            do {
                let password = try await appState?.sessionPassword(for: connection)
                try Task.checkCancellation(); _ = try appState?.credentialGate.check()
                let saved = try await service.saveText(content, path: item.path, baseline: baseline, overwriteChanged: overwriteChanged, connection: connection, password: password)
                try Task.checkCancellation(); guard self.generation == generation else { return }; self.baseline = saved
            } catch SFTPServiceError.conflict {
                guard self.generation == generation else { return }
                conflict = true; error = "The remote file changed. Reload it or explicitly overwrite its newer content."
            }
            catch { if self.generation == generation, !(error is CancellationError) { self.error = error.localizedDescription } }
        }
    }
    func cancel() {
        generation = UUID(); task?.cancel(); service.close(); busy = false
        error = "Cancelled. Unsaved edits were kept. If saving had begun, verify the remote file before retrying; a publish may already have reached the server."
    }
    func close() { cancel(); text = ""; baseline = nil }
}

@MainActor
final class RemoteFileEditors: ObservableObject {
    private var windows: [String: RemoteEditorWindow] = [:]
    private var connections: [String: RemoteConnection] = [:]
    var leases: [RemoteConnection] { Array(connections.values) }
    var busy: Bool { windows.values.contains { $0.model.busy } }
    var hasUnsavedChanges: Bool { windows.values.contains { $0.model.dirty } }
    var onReleased: ((RemoteConnection) -> Void)?
    func open(item: SFTPFileItem, connection: RemoteConnection, appState: AppState) {
        guard !appState.credentialGate.isLocked else { return }
        let key = connection.id.uuidString + "\n" + item.path
        if let existing = windows[key] { existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return }
        let resolved = appState.resolvedConnection(for: connection)
        connections[key] = resolved
        let model = RemoteTextEditorModel(connection: resolved, item: item, appState: appState)
        let controller = RemoteEditorWindow(model: model, title: item.name, onClose: { [weak self] in
            self?.windows[key] = nil; self?.connections[key] = nil; self?.onReleased?(resolved)
        })
        windows[key] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); model.load()
    }
    func suspendForPrivacy() { windows.values.forEach { $0.model.cancel() } }
}

final class WorkflowApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var editors: RemoteFileEditors?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if editors?.busy == true {
            let alert = NSAlert(); alert.messageText = "A remote editor operation is still in progress."; alert.informativeText = "Wait for it to finish before quitting."; alert.runModal()
            return .terminateCancel
        }
        guard editors?.hasUnsavedChanges == true else { return .terminateNow }
        let alert = NSAlert(); alert.messageText = "Discard unsaved remote file edits and quit?"; alert.addButton(withTitle: "Keep Editing"); alert.addButton(withTitle: "Discard and Quit")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}

private final class RemoteEditorWindow: NSWindowController, NSWindowDelegate {
    let model: RemoteTextEditorModel
    let onClose: () -> Void
    init(model: RemoteTextEditorModel, title: String, onClose: @escaping () -> Void) {
        self.model = model; self.onClose = onClose
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 640), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Edit Remote File — " + title; window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        window.contentView = NSHostingView(rootView: RemoteTextEditorView(model: model))
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.busy { return false }
        guard model.dirty else { return true }
        let alert = NSAlert(); alert.messageText = "Discard unsaved edits?"; alert.addButton(withTitle: "Keep Editing"); alert.addButton(withTitle: "Discard")
        return alert.runModal() == .alertSecondButtonReturn
    }
    func windowWillClose(_ notification: Notification) { model.close(); onClose() }
}

private struct RemoteTextEditorView: View {
    @ObservedObject var model: RemoteTextEditorModel
    @State private var confirmReload = false
    @State private var confirmOverwrite = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.dirty ? "Unsaved changes" : "Remote Text Editor").font(.headline)
                Spacer()
                if model.busy { ProgressView().controlSize(.small); Button("Cancel Operation") { model.cancel() } }
                Button("Reload") { if model.dirty { confirmReload = true } else { model.load() } }.disabled(model.busy)
                Button("Save") { model.save() }.keyboardShortcut("s").disabled(model.busy || !model.dirty)
            }
            TextEditor(text: $model.text).font(.system(.body, design: .monospaced)).disabled(model.busy || model.baseline == nil)
            if let error = model.error { Text(error).foregroundStyle(.red).font(.caption) }
            if model.conflict { Button("Overwrite Changed File…") { confirmOverwrite = true }.disabled(model.busy) }
            Text("UTF-8 · 2 MiB limit · Save checks the remote content, then publishes atomically when the server supports it. Concurrent edits in the final check-to-save interval cannot be locked. Ownership/ACLs may change on replacement.").font(.caption).foregroundStyle(.secondary)
        }.padding(16)
        .confirmationDialog("Discard your unsaved edits and reload?", isPresented: $confirmReload, titleVisibility: .visible) { Button("Reload", role: .destructive) { model.load() } }
        .confirmationDialog("Replace the newer remote content with your edits?", isPresented: $confirmOverwrite, titleVisibility: .visible) { Button("Overwrite", role: .destructive) { model.save(overwriteChanged: true) } }
    }
}
