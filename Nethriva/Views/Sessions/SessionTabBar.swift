import SwiftUI

struct SessionTabBar: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var surfaces: SessionSurfaceStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(appState.tabs) { tab in
                    HStack(spacing: 6) {
                        Image(systemName: tab.systemImage)
                            .font(.caption)

                        Text(tab.title)
                            .lineLimit(1)

                        Button {
                            appState.close(tabID: tab.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2.weight(.semibold))
                                .frame(width: 20, height: 24)
                        }
                        .buttonStyle(.plain)
                        .help("Close session")
                        .accessibilityLabel("Close \(tab.title) session")
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .background(
                        appState.selectedTabID == tab.id
                            ? Color.accentColor.opacity(0.16)
                            : Color.clear
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if appState.layout.detached.contains(tab.id) { surfaces.detach(tab.id) }
                        else { appState.selectedTabID = tab.id }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("\(tab.title) session tab")
                    .accessibilityValue(appState.selectedTabID == tab.id ? "Selected" : "Not selected")
                    .accessibilityAddTraits(appState.selectedTabID == tab.id ? [.isSelected] : [])
                    .accessibilityAction(named: "Select session") { surfaces.activate(tab.id) }
                    .contextMenu {
                        Button("Detach to Window") { surfaces.detach(tab.id) }
                        Button("Return to Workspace") { surfaces.dock(tab.id) }.disabled(!appState.layout.detached.contains(tab.id))
                        Button("Show beside current session") {
                            appState.layout.showSplit(with: tab.id, tabs: appState.tabs, direction: .horizontal)
                            appState.selectedTabID = tab.id
                        }.disabled(!appState.layout.canSplit(tab.id, tabs: appState.tabs))
                        Button("Stack below current session") {
                            appState.layout.showSplit(with: tab.id, tabs: appState.tabs, direction: .vertical)
                            appState.selectedTabID = tab.id
                        }.disabled(!appState.layout.canSplit(tab.id, tabs: appState.tabs))
                        if tab.connection.kind == .ssh, tab.tool == .primary,
                           appState.layout.isSSHSplit(tabs: appState.tabs), !appState.layout.panes.contains(tab.id) {
                            Button("Add to SSH Split") {
                                appState.layout.addSSH(tab.id, tabs: appState.tabs)
                                appState.selectedTabID = tab.id
                            }.disabled(!appState.layout.canAddSSH(tab.id, tabs: appState.tabs))
                        }
                        if appState.layout.panes.contains(tab.id) {
                            Button("Equal Pane Sizes") { appState.layout.equalize() }
                            Button("Remove from Split") {
                                appState.layout.removePane(tab.id); appState.selectedTabID = tab.id
                            }
                        }
                        Button("Single Pane") { appState.layout.showSingle(tab.id); appState.selectedTabID = tab.id }
                        Divider()
                        Button("Close Session", role: .destructive) { appState.close(tabID: tab.id) }
                    }

                    Divider()
                        .frame(height: 16)
                }
            }
        }
        .background(.bar)
    }
}
