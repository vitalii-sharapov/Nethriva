import SwiftUI

struct SessionTabBar: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(appState.tabs) { tab in
                    HStack(spacing: 7) {
                        Image(systemName: tab.systemImage)
                            .font(.caption)

                        Text(tab.title)
                            .lineLimit(1)

                        Button {
                            appState.close(tabID: tab.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .help("Close session")
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 36)
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
                        .frame(height: 20)
                }
            }
        }
        .background(.bar)
    }
}
