import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var currentCwd = ""
    @Published var showServerPicker = false
    @Published var selectedModel = ""
    @Published var reasoningEffort = "medium"
    @Published var showMcpServers = false
    @Published var showSkills = false
    @Published var showSettings = false
}
