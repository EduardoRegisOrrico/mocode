import SwiftUI

@MainActor
final class AppState: ObservableObject {
    private static let approvalPolicyKey = "mocode.approvalPolicy"
    private static let sandboxModeKey = "mocode.sandboxMode"
    private static let tailscaleAPIKeyKey = "tailscale.apiKey"
    private static let chatTextScaleKey = "chat.textScale"
    static let desktopDefaultValue = "__desktop_default__"

    @Published var currentCwd = ""
    @Published var showServerPicker = false
    @Published var selectedModel = ""
    @Published var reasoningEffort = "medium"
    @Published var showMcpServers = false
    @Published var showSkills = false
    @Published var showSettings = false
    @Published var approvalPolicy: String = UserDefaults.standard.string(forKey: approvalPolicyKey) ?? desktopDefaultValue {
        didSet {
            UserDefaults.standard.set(approvalPolicy, forKey: Self.approvalPolicyKey)
        }
    }
    @Published var sandboxMode: String = UserDefaults.standard.string(forKey: sandboxModeKey) ?? desktopDefaultValue {
        didSet {
            UserDefaults.standard.set(sandboxMode, forKey: Self.sandboxModeKey)
        }
    }
    @Published var chatTextScale: CGFloat = {
        let value = UserDefaults.standard.double(forKey: chatTextScaleKey)
        if value == 0 { return 1.0 }
        return min(max(CGFloat(value), 0.8), 1.8)
    }() {
        didSet {
            let clamped = min(max(chatTextScale, 0.8), 1.8)
            if clamped != chatTextScale {
                chatTextScale = clamped
                return
            }
            UserDefaults.standard.set(Double(clamped), forKey: Self.chatTextScaleKey)
        }
    }
    @Published var tailscaleAPIKey: String = UserDefaults.standard.string(forKey: tailscaleAPIKeyKey) ?? "" {
        didSet {
            UserDefaults.standard.set(tailscaleAPIKey, forKey: Self.tailscaleAPIKeyKey)
        }
    }

    var resolvedApprovalPolicy: String? {
        approvalPolicy == Self.desktopDefaultValue ? nil : approvalPolicy
    }

    var resolvedSandboxMode: String? {
        sandboxMode == Self.desktopDefaultValue ? nil : sandboxMode
    }
}
