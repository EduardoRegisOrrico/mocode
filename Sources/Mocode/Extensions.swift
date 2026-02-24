import SwiftUI
import UIKit

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }

    static func dynamic(light: String, dark: String) -> Color {
        Color(
            UIColor { trait in
                UIColor(hex: trait.userInterfaceStyle == .dark ? dark : light)
            }
        )
    }
}

extension UIColor {
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = CGFloat((int >> 16) & 0xFF) / 255
        let g = CGFloat((int >> 8) & 0xFF) / 255
        let b = CGFloat(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}

// MARK: - Central Theme

enum MocodeTheme {
    static let accent       = Color.dynamic(light: "#007AFF", dark: "#0A84FF")
    static let accentForeground = Color.dynamic(light: "#FFFFFF", dark: "#FFFFFF")
    static let textPrimary  = Color(uiColor: .label)
    static let textSecondary = Color(uiColor: .secondaryLabel)
    static let textMuted    = Color(uiColor: .tertiaryLabel)
    static let textBody     = Color(uiColor: .label)
    static let textSystem   = Color(uiColor: .secondaryLabel)
    static let surface      = Color(uiColor: .secondarySystemGroupedBackground)
    static let surfaceLight = Color(uiColor: .tertiarySystemFill)
    static let card         = Color(uiColor: .systemBackground)
    static let cardMuted    = Color(uiColor: .secondarySystemGroupedBackground)
    static let border       = Color(uiColor: .separator)

}

func serverIconName(for source: ServerSource) -> String {
    switch source {
    case .local: return "iphone"
    case .bonjour: return "desktopcomputer"
    case .ssh: return "terminal"
    case .tailscale: return "network"
    case .manual: return "server.rack"
    }
}

func relativeDate(_ timestamp: Int64) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}

enum ProviderBrand {
    case openAI
    case claude
}

struct ProviderLogoView: View {
    let brand: ProviderBrand
    var size: CGFloat = 14
    var tint: Color = .primary

    private var logo: UIImage? {
        switch brand {
        case .openAI:
            return UIImage(named: "openai_logo") ?? UIImage(named: "openai_logo.png")
        case .claude:
            return UIImage(named: "claude_logo") ?? UIImage(named: "claude_logo.png")
        }
    }

    private var fallbackSymbol: String {
        switch brand {
        case .openAI: return "chevron.left.forwardslash.chevron.right"
        case .claude: return "sparkles"
        }
    }

    var body: some View {
        Group {
            if let logo {
                switch brand {
                case .openAI:
                    Image(uiImage: logo)
                        .resizable()
                        .interpolation(.high)
                        .renderingMode(.template)
                        .scaledToFit()
                case .claude:
                    Image(uiImage: logo)
                        .resizable()
                        .interpolation(.high)
                        .renderingMode(.template)
                        .scaledToFit()
                }
            } else {
                Image(systemName: fallbackSymbol)
                    .font(.system(size: size * 0.92, weight: .semibold))
            }
        }
        .frame(width: size, height: size)
        .foregroundColor(tint)
        .accessibilityHidden(true)
    }
}

