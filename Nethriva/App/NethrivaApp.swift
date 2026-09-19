import SwiftUI

@main
struct NethrivaApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .commands {
            NethrivaHelpCommands()

            CommandGroup(after: .newItem) {
                Button("Open Selected Connection") {
                    appState.openSelectedConnection()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("Open SFTP for Selected Connection") {
                    guard let connection = appState.selectedConnection else { return }
                    appState.openSFTP(connection)
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(appState.selectedConnection?.kind != .ssh)
            }
        }

        Window("Nethriva Help", id: NethrivaWindow.help) {
            NethrivaHelpView()
        }
        .defaultSize(width: 1040, height: 760)
        .windowResizability(.contentMinSize)
    }
}
