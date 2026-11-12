import Foundation

enum SessionTool: String, Hashable {
    case primary
    case sftp
    case virtualMachine

    var titleSuffix: String? {
        switch self {
        case .primary: nil
        case .sftp: "SFTP"
        case .virtualMachine: "Console"
        }
    }

    var systemImage: String? {
        switch self {
        case .primary: nil
        case .sftp: "arrow.up.arrow.down.square"
        case .virtualMachine: "desktopcomputer"
        }
    }
}

struct SessionTab: Identifiable, Hashable {
    let id: UUID
    let connection: RemoteConnection
    let tool: SessionTool
    let openedAt: Date
    let virtualMachine: VirtualMachine?

    init(
        id: UUID = UUID(),
        connection: RemoteConnection,
        tool: SessionTool = .primary,
        openedAt: Date = Date(),
        virtualMachine: VirtualMachine? = nil
    ) {
        self.id = id
        self.connection = connection
        self.tool = tool
        self.openedAt = openedAt
        self.virtualMachine = virtualMachine
    }

    var title: String {
        if let virtualMachine { return virtualMachine.name }
        guard let suffix = tool.titleSuffix else { return connection.name }
        return "\(connection.name) · \(suffix)"
    }

    var systemImage: String {
        tool.systemImage ?? connection.kind.systemImage
    }
}
