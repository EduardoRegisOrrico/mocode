import Foundation

enum MessageRole: Equatable {
    case user
    case assistant
    case system
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: MessageRole
    var text: String
    var images: [ChatImage] = []
    var agentId: String? = nil
    var agentNickname: String? = nil
    var agentRole: String? = nil
    let timestamp = Date()
}

struct ChatImage: Identifiable {
    let id = UUID()
    let data: Data
}

enum ConversationStatus {
    case idle
    case connecting
    case ready
    case thinking
    case error(String)
}

enum AuthStatus: Equatable {
    case unknown
    case notLoggedIn
    case apiKey
    case chatgpt(email: String)
    case claude
}
