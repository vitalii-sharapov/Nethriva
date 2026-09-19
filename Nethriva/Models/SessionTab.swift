import Foundation

enum SessionTool: String, Hashable {
    case primary
    case sftp

    var titleSuffix: String? {
        switch self {
        case .primary: nil
        case .sftp: "SFTP"
        }
    }

    var systemImage: String? {
        switch self {
        case .primary: nil
        case .sftp: "arrow.up.arrow.down.square"
        }
    }
}

struct SessionTab: Identifiable, Hashable {
    let id: UUID
    let connection: RemoteConnection
    let tool: SessionTool
    let openedAt: Date

    init(
        id: UUID = UUID(),
        connection: RemoteConnection,
        tool: SessionTool = .primary,
        openedAt: Date = Date()
    ) {
        self.id = id
        self.connection = connection
        self.tool = tool
        self.openedAt = openedAt
    }

    var title: String {
        guard let suffix = tool.titleSuffix else { return connection.name }
        return "\(connection.name) · \(suffix)"
    }

    var systemImage: String {
        tool.systemImage ?? connection.kind.systemImage
    }
}
