import AppKit
import Darwin
import SwiftTerm
import SwiftUI

/// Validate compressed sixel dimensions/work before the dependency expands it.
/// Small input may otherwise contain overflowing integers or enormous repeats.
enum TerminalSixelSafety {
    static let maximumDimension = 4096
    static let maximumPixels = 4 * 1024 * 1024
    static let maximumColumns = 4 * 1024 * 1024
    static func allowsDCS(_ bytes: [UInt8]) -> Bool {
        let start: Int
        if bytes.starts(with: [0x1b, 0x50]) { start = 2 }
        else if bytes.first == 0x90 { start = 1 }
        else { return true }
        var header = start, intermediate = false
        while header < bytes.count && !(0x40...0x7e).contains(bytes[header]) {
            if (0x20...0x2f).contains(bytes[header]) { intermediate = true }
            header += 1
        }
        guard header < bytes.count, bytes[header] == 0x71, !intermediate else { return true }
        // The parser's nextInt() is used for both repeat counts and palettes.
        // Bound every decimal run, including ignored raster/header parameters.
        var decimal = 0
        for byte in bytes[start...] {
            if (48...57).contains(byte) {
                let digit = Int(byte - 48)
                guard decimal <= (1_000_000 - digit) / 10 else { return false }
                decimal = decimal * 10 + digit
            } else { decimal = 0 }
        }
        let end = bytes.last == 0x9c ? bytes.count - 1 : max(header + 1, bytes.count - 2)
        var position = header + 1
        // The current renderer starts drawing at its first palette command.
        while position < end && bytes[position] != 0x23 { position += 1 }
        var x = 0, y = 0, width = 0, height = 0, repeats = 1, columns = 0, paletteCommands = 0
        while position < end {
            let byte = bytes[position]; position += 1
            switch byte {
            case 0x23:
                paletteCommands += 1
                guard paletteCommands <= 4096 else { return false }
                var parameters = 0, inNumber = false
                while position < end && ((48...57).contains(bytes[position]) || bytes[position] == 59) {
                    if (48...57).contains(bytes[position]) {
                        if !inNumber { parameters += 1; inNumber = true }
                    } else { inNumber = false }
                    guard parameters <= 16 else { return false }
                    position += 1
                }
            case 0x21:
                var value = 0, digits = 0
                while position < end && (48...57).contains(bytes[position]) {
                    value = value * 10 + Int(bytes[position] - 48); digits += 1; position += 1
                }
                if digits > 0 { repeats = value }
            case 0x24:
                width = max(width, x); x = 0
            case 0x2d:
                width = max(width, x); x = 0
                guard y <= maximumDimension else { return false }
                y += 6
            case 0x3f...0x7e:
                guard repeats <= maximumDimension - x, repeats <= maximumColumns - columns else { return false }
                columns += repeats; x += repeats
                var bits = Int(byte - 0x3f), rows = 0
                while bits > 0 { rows += 1; bits >>= 1 }
                if rows > 0 && repeats > 0 {
                    guard y <= maximumDimension - rows else { return false }
                    height = max(height, y + rows)
                }
                width = max(width, x)
                guard width <= maximumDimension, height == 0 || width <= maximumPixels / height else { return false }
                repeats = 1
            default: break
            }
        }
        return true
    }
}

/// Holds incomplete escape strings outside SwiftTerm so a peer cannot grow
/// its parser buffer indefinitely. Complete ordinary sequences are unchanged.
struct TerminalEscapeLimiter {
    private enum Mode { case text, escape, string, csi }
    private var mode: Mode = .text
    private var pending: [UInt8] = []
    private var dropping = false, osc = false, escaped = false
    private var utf8Continuation = 0
    private let controlLimit: Int
    private let csiLimit: Int
    private(set) var discardedSequences = 0
    var bufferedByteCount: Int { pending.count }
    init(controlLimit: Int = 8 * 1024 * 1024, csiLimit: Int = 4096) {
        self.controlLimit = max(8, controlLimit); self.csiLimit = max(8, csiLimit)
    }
    private mutating func reset() {
        mode = .text; pending.removeAll(keepingCapacity: false)
        dropping = false; escaped = false; osc = false
    }
    private mutating func append(_ byte: UInt8, limit: Int) {
        guard !dropping else { return }
        guard pending.count < limit else {
            pending.removeAll(keepingCapacity: false); dropping = true; discardedSequences += 1; return
        }
        pending.append(byte)
    }
    mutating func filter(_ input: ArraySlice<UInt8>) -> [UInt8] {
        var output: [UInt8] = []; output.reserveCapacity(input.count)
        for byte in input {
            let rawC1 = utf8Continuation == 0 && (0x80...0x9f).contains(byte)
            if utf8Continuation > 0 && byte & 0xc0 == 0x80 { utf8Continuation -= 1 }
            else {
                switch byte {
                case 0xc2...0xdf: utf8Continuation = 1
                case 0xe0...0xef: utf8Continuation = 2
                case 0xf0...0xf4: utf8Continuation = 3
                default: utf8Continuation = 0
                }
            }
            switch mode {
            case .text:
                if byte == 0x1b { pending = [byte]; mode = .escape }
                else if rawC1 && [0x90, 0x98, 0x9b, 0x9d, 0x9e, 0x9f].contains(byte) {
                    pending = [byte]; osc = byte == 0x9d; mode = byte == 0x9b ? .csi : .string
                } else { output.append(byte) }
            case .escape:
                if byte == 0x1b { output += pending; pending = [byte] }
                else if [0x50, 0x58, 0x5d, 0x5e, 0x5f].contains(byte) {
                    append(byte, limit: controlLimit); osc = byte == 0x5d; mode = .string
                } else if byte == 0x5b { append(byte, limit: csiLimit); mode = .csi }
                else if (0x20...0x2f).contains(byte) { append(byte, limit: csiLimit) }
                else {
                    append(byte, limit: csiLimit); if !dropping { output += pending }; reset()
                }
            case .string:
                if byte == 0x18 || byte == 0x1a { reset(); continue }
                let end = (osc && byte == 7) || (rawC1 && byte == 0x9c) || (escaped && byte == 0x5c)
                append(byte, limit: controlLimit)
                if end {
                    if !dropping {
                        if TerminalSixelSafety.allowsDCS(pending) { output += pending }
                        else { discardedSequences += 1 }
                    }
                    reset()
                }
                else { escaped = byte == 0x1b }
            case .csi:
                if byte == 0x18 || byte == 0x1a { reset(); continue }
                if byte == 0x1b { reset(); pending = [byte]; mode = .escape; continue }
                append(byte, limit: csiLimit)
                if (0x40...0x7e).contains(byte) { if !dropping { output += pending }; reset() }
            }
        }
        return output
    }
}

enum TerminalInputSecurity {
    enum PasteDecision: Equatable { case allow, confirm, reject }
    static let maximumPasteBytes = 1024 * 1024
    static func pasteDecision(_ value: String) -> PasteDecision {
        guard value.utf8.count <= maximumPasteBytes, !value.contains("\0") else { return .reject }
        return value.rangeOfCharacter(from: .controlCharacters) == nil ? .allow : .confirm
    }
    static func approvedPaste(_ value: String, confirm: () -> Bool) -> String? {
        switch pasteDecision(value) {
        case .allow: return value
        case .confirm: return confirm() ? value : nil
        case .reject: return nil
        }
    }
    @MainActor static func paste(into terminal: TerminalView) {
        guard !CredentialAccessGate.shared.isLocked, let text = NSPasteboard.general.string(forType: .string) else { return }
        let approved = approvedPaste(text) {
            let alert = NSAlert()
            alert.messageText = "Paste Text That May Execute Commands?"
            alert.informativeText = "This text contains line breaks or control characters. It may execute commands immediately. Review it before pasting.\n\n" +
                text.unicodeScalars.prefix(2000).map { CharacterSet.controlCharacters.contains($0) ? "\\u{\(String($0.value, radix: 16))}" : String($0) }.joined()
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Paste Reviewed Text")
            return alert.runModal() == .alertSecondButtonReturn
        }
        guard let approved, !CredentialAccessGate.shared.isLocked else { return }
        // Read once so a pasteboard change during review cannot replace the
        // approved text. Use SwiftTerm's public input API with paste framing.
        let bracketed = terminal.terminalInputStateSnapshot()?.bracketedPasteMode ?? false
        if bracketed { terminal.send(data: Array("\u{1b}[200~".utf8)[...]) }
        terminal.send(txt: approved)
        if bracketed { terminal.send(data: Array("\u{1b}[201~".utf8)[...]) }
    }
}

enum TerminalLinkSecurity {
    enum Decision: Equatable { case blocked, web, confirmation }
    static func decision(_ value: String) -> Decision {
        guard value.utf8.count <= 8192, value.rangeOfCharacter(from: .controlCharacters) == nil,
              let parts = URLComponents(string: value), let scheme = parts.scheme?.lowercased(), parts.password == nil,
              parts.url != nil, !["javascript", "data", "blob", "about"].contains(scheme) else { return .blocked }
        if ["http", "https"].contains(scheme) { return parts.host?.isEmpty == false && parts.user == nil ? .web : .blocked }
        if scheme == "mailto" { return parts.path.isEmpty ? .blocked : .web }
        return .confirmation
    }
    static func open(_ value: String) {
        guard !CredentialAccessGate.shared.isLocked, let url = URL(string: value) else { return }
        switch decision(value) {
        case .blocked: return
        case .web: break
        case .confirmation:
            let alert = NSAlert()
            alert.messageText = "Open a Local File or Application Link?"
            alert.informativeText = "This link came from terminal output. Opening it can launch another application or open a local file.\n\n" + value
            alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Open Reviewed Link")
            guard alert.runModal() == .alertSecondButtonReturn, !CredentialAccessGate.shared.isLocked else { return }
        }
        NSWorkspace.shared.open(url)
    }
}

/// SwiftTerm's ManagedProcessTerminalView otherwise handles OSC 52 using the
/// system clipboard. Remote output must never read or replace that clipboard.
/// User-initiated Copy/Paste remains on TerminalView's native action methods.
final class TerminalDelegateFirewall: TerminalViewDelegate {
    private weak var forwarding: (any TerminalViewDelegate)?
    init(forwarding: any TerminalViewDelegate) { self.forwarding = forwarding }
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func clipboardCopy(source: TerminalView, content: Data) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) { TerminalLinkSecurity.open(link) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { forwarding?.sizeChanged(source: source, newCols: newCols, newRows: newRows) }
    func setTerminalTitle(source: TerminalView, title: String) { forwarding?.setTerminalTitle(source: source, title: title) }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) { forwarding?.hostCurrentDirectoryUpdate(source: source, directory: directory) }
    func send(source: TerminalView, data: ArraySlice<UInt8>) { forwarding?.send(source: source, data: data) }
    func scrolled(source: TerminalView, position: Double) { forwarding?.scrolled(source: source, position: position) }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) { forwarding?.rangeChanged(source: source, startY: startY, endY: endY) }
    func bell(source: TerminalView) { forwarding?.bell(source: source) }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) { forwarding?.iTermContent(source: source, content: content) }
}

/// A native AppKit SwiftTerm surface hosted inside the SwiftUI session workspace.
/// SwiftTerm owns the pseudo-terminal, ANSI/xterm parsing, selection, resizing,
/// and direct keyboard input for this local session.
struct LocalTerminalSessionView: View {
    @StateObject private var control = LocalTerminalControl()
    @State private var generation = UUID()
    @State private var ended = false
    var body: some View {
        let current = generation
        return VStack(spacing: 0) {
            HStack {
                Label("Local Terminal", systemImage: "terminal").font(.subheadline.weight(.semibold))
                Spacer()
                if ended {
                    Button("Restart") { ended = false; generation = UUID() }
                } else {
                    Button("Disconnect") { control.stop(); ended = true }
                }
            }.controlSize(.small).padding(.horizontal, 12).frame(height: 34).background(.bar)
            Divider()
            LocalTerminalSurface(control: control, onTermination: { if current == generation { ended = true; control.terminal = nil } }).id(generation)
        }
    }
}

/// Nethriva owns the PTY delivery path so untrusted bytes always pass through
/// its ingress guard before SwiftTerm parses them. SwiftTerm's convenience
/// process view now parses directly on an internal I/O adapter.
@MainActor protocol ManagedProcessTerminalViewDelegate: AnyObject {
    func sizeChanged(source: ManagedProcessTerminalView, newCols: Int, newRows: Int)
    func setTerminalTitle(source: ManagedProcessTerminalView, title: String)
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?)
    func requestOpenLink(source: TerminalView, link: String, params: [String: String])
    func processTerminated(source: TerminalView, exitCode: Int32?)
}

private final class ManagedPTYDelivery: LocalProcessDelegate, @unchecked Sendable {
    private let condition = NSCondition()
    private var size = winsize()
    private var pending: [[UInt8]] = []
    private var pendingBytes = 0
    private var scheduled = false
    private var closed = false
    private let capacity = 1024 * 1024
    weak var view: ManagedProcessTerminalView?

    func updateSize(_ value: winsize) { condition.lock(); size = value; condition.unlock() }
    func getWindowSize() -> winsize { condition.lock(); defer { condition.unlock() }; return size }
    func close() {
        condition.lock(); closed = true; pending.removeAll(); pendingBytes = 0
        condition.broadcast(); condition.unlock()
    }
    func dataReceived(slice: ArraySlice<UInt8>) {
        // Apply backpressure on the I/O queue rather than dropping output or
        // retaining unlimited main-queue closures while a modal UI is open.
        var start = slice.startIndex
        while start < slice.endIndex {
            let end = min(slice.endIndex, start + 65536)
            let bytes = Array(slice[start..<end])
            condition.lock()
            while !closed && pendingBytes + bytes.count > capacity { condition.wait() }
            guard !closed else { condition.unlock(); return }
            pending.append(bytes); pendingBytes += bytes.count
            let needsDrain = !scheduled; scheduled = true
            condition.unlock()
            if needsDrain { DispatchQueue.main.async { [weak self] in self?.drain() } }
            start = end
        }
    }
    @MainActor private func drain() {
        condition.lock()
        let chunks = pending; pending.removeAll(keepingCapacity: true); pendingBytes = 0
        scheduled = false; let shouldDeliver = !closed
        condition.broadcast(); condition.unlock()
        guard shouldDeliver, let view else { return }
        for chunk in chunks { view.dataReceived(slice: chunk[...]) }
    }
    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            guard let view = self?.view else { return }
            view.processDelegate?.processTerminated(source: view, exitCode: exitCode)
        }
    }
    func processFailedToStart(_ source: LocalProcess, error: LocalProcessError) {
        DispatchQueue.main.async { [weak self] in
            guard let view = self?.view else { return }
            view.feed(text: "\r\nProcess could not start.\r\n")
            view.processDelegate?.processTerminated(source: view, exitCode: nil)
        }
    }
}

class ManagedProcessTerminalView: TerminalView, TerminalViewDelegate {
    private let delivery = ManagedPTYDelivery()
    private(set) var process: LocalProcess!
    weak var processDelegate: ManagedProcessTerminalViewDelegate?
    override init(frame: CGRect) { super.init(frame: frame); setupProcess() }
    override init(frame: CGRect, font: NSFont? = nil, options: TerminalOptions) {
        super.init(frame: frame, font: font, options: options); setupProcess()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); setupProcess() }
    private func setupProcess() {
        terminalDelegate = self
        resolvesLinksAgainstShellDirectory = true
        delivery.view = self
        process = LocalProcess(delegate: delivery, dispatchQueue: .main, directDelivery: true)
        delivery.updateSize(getWindowSize())
    }
    func getWindowSize() -> winsize {
        let dimensions = terminalInputStateSnapshot()?.dimensions ?? TerminalDimensions(cols: 80, rows: 24)
        let pixels = convertToBacking(bounds).size
        return winsize(ws_row: UInt16(clamping: dimensions.rows), ws_col: UInt16(clamping: dimensions.cols),
                       ws_xpixel: UInt16(clamping: max(0, Int(pixels.width))), ws_ypixel: UInt16(clamping: max(0, Int(pixels.height))))
    }
    private func updateProcessSize() {
        guard let process else { return }
        var size = getWindowSize(); delivery.updateSize(size); _ = process.updateWindowSize(&size)
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateProcessSize() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateProcessSize() }
    func startProcess(executable: String = "/bin/zsh", args: [String] = [], environment: [String]? = nil,
                      execName: String? = nil, currentDirectory: String? = nil) {
        delivery.updateSize(getWindowSize())
        process.startProcess(executable: executable, args: args, environment: environment, execName: execName, currentDirectory: currentDirectory)
    }
    func terminate() { delivery.close(); process?.terminate() }
    deinit { delivery.close(); process?.terminate() }
    func dataReceived(slice: ArraySlice<UInt8>) { feed(byteArray: slice) }
    func send(source: TerminalView, data: ArraySlice<UInt8>) { process.send(data: data) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        updateProcessSize(); processDelegate?.sizeChanged(source: self, newCols: newCols, newRows: newRows)
    }
    func setTerminalTitle(source: TerminalView, title: String) { processDelegate?.setTerminalTitle(source: self, title: title) }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) { processDelegate?.hostCurrentDirectoryUpdate(source: source, directory: directory) }
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) { TerminalLinkSecurity.open(link) }
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

@MainActor private final class LocalTerminalControl: ObservableObject {
    weak var terminal: ManagedProcessTerminalView?
    var canInsert: Bool { terminal != nil }
    func stop() { terminal?.terminate(); terminal = nil }
    func insert(_ text: String) -> Bool {
        guard let terminal else { return false }
        terminal.send(source: terminal, data: Array(text.utf8)[...]); return true
    }
}

private struct LocalTerminalSurface: NSViewRepresentable {
    let control: LocalTerminalControl
    let onTermination: () -> Void
    func makeCoordinator() -> Coordinator {
        Coordinator(onTermination: onTermination)
    }

    func makeNSView(context: Context) -> ManagedProcessTerminalView {
        let terminalView = PasteableLocalProcessTerminalView(frame: .zero, options: context.environment.terminalAppearance.options)
        context.environment.terminalAppearance.apply(terminalView)
        context.coordinator.capture = TerminalCapture(view: terminalView, id: context.environment.sessionTabID, experience: context.environment.terminalExperience)
        terminalView.processDelegate = context.coordinator
        control.terminal = terminalView
        context.environment.sessionLifetime?.focus = { [weak terminalView] in if let terminalView { terminalView.window?.makeFirstResponder(terminalView) } }
        context.environment.commandRouter?.register(context.environment.sessionTabID, identity: terminalView, ready: { [weak control] in control?.canInsert == true }) { [weak control] in control?.insert($0) ?? false }
        terminalView.startProcess(
            executable: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
            args: ["-l"],
            currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        )

        context.coordinator.focus.update(context.environment.sessionIsActive) {
            terminalView.window?.makeFirstResponder(terminalView)
        }
        return terminalView
    }

    func updateNSView(_ terminalView: ManagedProcessTerminalView, context: Context) {
        context.environment.commandRouter?.register(context.environment.sessionTabID, identity: terminalView, ready: { [weak control] in control?.canInsert == true }) { [weak control] in control?.insert($0) ?? false }
        context.coordinator.onTermination = onTermination
        context.coordinator.focus.update(context.environment.sessionIsActive) { terminalView.window?.makeFirstResponder(terminalView) }
    }

    static func dismantleNSView(_ terminalView: ManagedProcessTerminalView, coordinator: Coordinator) {
        terminalView.processDelegate = nil
        coordinator.capture?.close()
        terminalView.terminate()
    }

    final class Coordinator: NSObject, ManagedProcessTerminalViewDelegate {
        var capture: TerminalCapture?
        let focus = SessionFocusGate()
        var onTermination: () -> Void
        init(onTermination: @escaping () -> Void) { self.onTermination = onTermination }
        func sizeChanged(source: ManagedProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: ManagedProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) { TerminalLinkSecurity.open(link) }
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            DispatchQueue.main.async { [weak self, onTermination] in self?.capture?.close(); onTermination() }
        }
    }
}

/// A trackpad secondary click (two-finger click) or mouse right-click pastes
/// directly into the terminal.
class PasteableLocalProcessTerminalView: ManagedProcessTerminalView {
    private var outputLimiter = TerminalEscapeLimiter()
    private var securityDelegate: TerminalDelegateFirewall!
    private func guardTerminalDelegate() {
        securityDelegate = TerminalDelegateFirewall(forwarding: self)
        terminalDelegate = securityDelegate
    }
    override init(frame: CGRect) { super.init(frame: frame); guardTerminalDelegate() }
    override init(frame: CGRect, font: NSFont? = nil, options: TerminalOptions) {
        super.init(frame: frame, font: font, options: options); guardTerminalDelegate()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); guardTerminalDelegate() }
    override func paste(_ sender: Any) { TerminalInputSecurity.paste(into: self) }
    var outputObserver: ((ArraySlice<UInt8>) -> Void)?
    override func dataReceived(slice: ArraySlice<UInt8>) {
        let bounded = outputLimiter.filter(slice)
        guard !bounded.isEmpty else { return }
        super.dataReceived(slice: bounded[...])
        outputObserver?(bounded[...])
    }
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        paste(self)
    }
}
