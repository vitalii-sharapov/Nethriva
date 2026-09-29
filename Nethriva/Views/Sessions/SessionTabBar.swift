import SwiftUI

struct SessionTabBar: View {
    @EnvironmentObject private var appState: AppState

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
                        appState.selectedTabID = tab.id
                    }

                    Divider()
                        .frame(height: 16)
                }
            }
        }
        .background(.bar)
    }
}
