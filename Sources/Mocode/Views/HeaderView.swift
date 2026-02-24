import SwiftUI

// MARK: - Model Selector (presented as a sheet from the toolbar)

struct ModelSelectorView: View {
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var appState: AppState
    @State private var loadError: String?

    private var models: [CodexModel] {
        serverManager.activeConnection?.models ?? []
    }

    private var currentModel: CodexModel? {
        models.first { $0.id == appState.selectedModel }
    }

    var body: some View {
        VStack(spacing: 14) {
            Capsule()
                .fill(MocodeTheme.border.opacity(0.7))
                .frame(width: 36, height: 5)
                .padding(.top, 8)

            Text("Models")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(MocodeTheme.textPrimary)

            if models.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    if let err = loadError {
                        Text(err)
                            .font(.system(size: 14))
                            .foregroundColor(MocodeTheme.textSecondary)
                            .multilineTextAlignment(.center)
                        Button("Retry") {
                            loadError = nil
                            Task { await loadModels() }
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        ProgressView().tint(MocodeTheme.accent)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(models) { model in
                            Button {
                                appState.selectedModel = model.id
                                appState.reasoningEffort = model.defaultReasoningEffort
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 6) {
                                            Text(model.displayName)
                                                .font(.system(size: 15, weight: .semibold))
                                                .foregroundColor(MocodeTheme.textPrimary)
                                            if model.isDefault {
                                                Text("default")
                                                    .font(.system(size: 10, weight: .semibold))
                                                    .foregroundColor(MocodeTheme.accent)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(MocodeTheme.accent.opacity(0.15), in: Capsule())
                                            }
                                        }
                                        Text(model.description)
                                            .font(.system(size: 12))
                                            .foregroundColor(MocodeTheme.textSecondary)
                                            .multilineTextAlignment(.leading)
                                    }
                                    Spacer()
                                    if model.id == appState.selectedModel {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 16))
                                            .foregroundColor(MocodeTheme.accent)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(model.id == appState.selectedModel ? MocodeTheme.accent.opacity(0.12) : Color.clear)
                                )
                            }
                        }

                        if let info = currentModel, !info.supportedReasoningEfforts.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Reasoning Effort")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(MocodeTheme.textPrimary)
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(info.supportedReasoningEfforts) { effort in
                                            let selected = effort.reasoningEffort == appState.reasoningEffort
                                            Button {
                                                appState.reasoningEffort = effort.reasoningEffort
                                            } label: {
                                                Text(effort.reasoningEffort)
                                                    .font(.system(size: 12, weight: .semibold))
                                                    .foregroundColor(selected ? MocodeTheme.accentForeground : MocodeTheme.textPrimary)
                                                    .padding(.horizontal, 10)
                                                    .padding(.vertical, 7)
                                                    .background(selected ? MocodeTheme.accent : MocodeTheme.surface)
                                                    .clipShape(Capsule())
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 18)
                }
            }
        }
        .task {
            if models.isEmpty { await loadModels() }
        }
    }

    private func loadModels() async {
        guard let conn = serverManager.activeConnection, conn.isConnected else {
            loadError = "Not connected to a server"
            return
        }
        do {
            let resp = try await conn.listModels()
            conn.models = resp.data
            conn.modelsLoaded = true
            if appState.selectedModel.isEmpty || !models.contains(where: { $0.id == appState.selectedModel }) {
                if let defaultModel = models.first(where: { $0.isDefault }) ?? models.first {
                    appState.selectedModel = defaultModel.id
                    appState.reasoningEffort = defaultModel.defaultReasoningEffort
                }
            }
        } catch {
            loadError = error.localizedDescription
        }
    }
}

// MARK: - Previews

#Preview("Model Selector - Empty") {
    ModelSelectorView()
        .environmentObject(ServerManager())
        .environmentObject(AppState())
        .presentationDetents([.medium])
}
