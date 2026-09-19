import SwiftUI

struct SessionWorkspaceView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            if !appState.tabs.isEmpty {
                SessionTabBar()
                Divider()
            }

            if appState.selectedTab != nil {
                ZStack {
                    ForEach(appState.tabs) { tab in
                        sessionSurface(for: tab)
                            .opacity(appState.selectedTabID == tab.id ? 1 : 0)
                            .allowsHitTesting(appState.selectedTabID == tab.id)
                            .accessibilityHidden(appState.selectedTabID != tab.id)
                    }
                }
            } else {
                ContentUnavailableView {
                    VStack(spacing: 12) {
                        Image("NethrivaMark")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 76, height: 76)
                            .accessibilityHidden(true)

                        Text("No Open Sessions")
                    }
                } description: {
                    Text("Double-click a connection or select one and press Command-O.")
                } actions: {
                    if appState.selectedConnection != nil {
                        Button("Open Selected Connection") {
                            appState.openSelectedConnection()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sessionSurface(for tab: SessionTab) -> some View {
        if tab.tool == .sftp {
            SFTPBrowserView(connection: tab.connection)
        } else {
            switch tab.connection.kind {
            case .localShell:
                LocalTerminalSessionView()
            case .ssh:
                SSHSessionView(connection: tab.connection)
            case .rdp:
                RDPSessionView(connection: tab.connection)
            }
        }
    }
}
