import AppKit
import SwiftTerm
import SwiftUI

/// A native AppKit SwiftTerm surface hosted inside the SwiftUI session workspace.
/// SwiftTerm owns the pseudo-terminal, ANSI/xterm parsing, selection, resizing,
/// and direct keyboard input for this local session.
struct LocalTerminalSessionView: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminalView = PasteableLocalProcessTerminalView(frame: .zero)
        terminalView.processDelegate = context.coordinator
        terminalView.startProcess(
            executable: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
            args: ["-l"],
            currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        )

        DispatchQueue.main.async {
            terminalView.window?.makeFirstResponder(terminalView)
        }
        return terminalView
    }

    func updateNSView(_ terminalView: LocalProcessTerminalView, context: Context) {}

    static func dismantleNSView(_ terminalView: LocalProcessTerminalView, coordinator: Coordinator) {
        terminalView.processDelegate = nil
        terminalView.terminate()
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {}
    }
}

/// A trackpad secondary click (two-finger click) or mouse right-click pastes
/// directly into the terminal.
class PasteableLocalProcessTerminalView: LocalProcessTerminalView {
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        paste(self)
    }
}
