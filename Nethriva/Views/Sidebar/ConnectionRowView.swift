import SwiftUI

struct ConnectionRowView: View {
    @EnvironmentObject private var settings: AppSettings
    let connection: RemoteConnection

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: connection.kind.systemImage)
                .frame(width: 18)
                .foregroundStyle(connection.kind == .localShell ? Color.secondary : Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(connection.name)
                    .lineLimit(1)
                if let endpoint = settings.sidebarEndpoint(for: connection) {
                    Text(endpoint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if connection.isFavorite {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
            }
        }
        .padding(.vertical, 2)
    }
}
