import Foundation

struct ThreadKey: Hashable {
    let serverId: String
    let threadId: String
}

@MainActor
final class ThreadState: ObservableObject, Identifiable {
    let key: ThreadKey
    let serverId: String
    let threadId: String
    var serverName: String
    var serverSource: ServerSource
    var modelProvider: String = ""

    @Published var messages: [ChatMessage] = []
    @Published var status: ConversationStatus = .ready
    @Published var preview: String = ""
    @Published var cwd: String = ""
    @Published var updatedAt: Date = Date()

    var id: ThreadKey { key }

    var hasTurnActive: Bool {
        if case .thinking = status { return true }
        return false
    }

    init(serverId: String, threadId: String, serverName: String, serverSource: ServerSource) {
        self.key = ThreadKey(serverId: serverId, threadId: threadId)
        self.serverId = serverId
        self.threadId = threadId
        self.serverName = serverName
        self.serverSource = serverSource
    }
}

struct SavedServer: Codable, Identifiable {
    let id: String
    let name: String
    let hostname: String
    let port: UInt16?
    let source: String
    let hasCodexServer: Bool
    var backendHint: String?
    var sshPort: UInt16?

    func toDiscoveredServer() -> DiscoveredServer {
        var server = DiscoveredServer(
            id: id,
            name: name,
            hostname: hostname,
            port: port,
            source: ServerSource.from(source),
            hasCodexServer: hasCodexServer
        )
        switch backendHint {
        case "codex": server.backendHint = .codex
        case "claude": server.backendHint = .claude
        default: break
        }
        server.sshPort = sshPort
        return server
    }

    static func from(_ server: DiscoveredServer) -> SavedServer {
        let hint: String?
        switch server.backendHint {
        case .codex: hint = "codex"
        case .claude: hint = "claude"
        case .unknown: hint = nil
        }
        return SavedServer(
            id: server.id,
            name: server.name,
            hostname: server.hostname,
            port: server.port,
            source: server.source.rawString,
            hasCodexServer: server.hasCodexServer,
            backendHint: hint,
            sshPort: server.sshPort
        )
    }
}
