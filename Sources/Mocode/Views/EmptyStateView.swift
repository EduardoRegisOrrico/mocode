import SwiftUI

struct EmptyStateView: View {
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            VStack(spacing: 18) {
                BrandLogo(size: 112)
                Text("Start a new session")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(MocodeTheme.textMuted)
                    .multilineTextAlignment(.center)
                if !serverManager.hasAnyConnection {
                    Button("Connect to Server") {
                        appState.showServerPicker = true
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(MocodeTheme.accentForeground)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(MocodeTheme.accent, in: Capsule())
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Previews

#Preview("Empty State") {
    EmptyStateView()
        .environmentObject(ServerManager())
        .environmentObject(AppState())
}
