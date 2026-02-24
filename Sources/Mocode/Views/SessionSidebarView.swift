import SwiftUI
import Inject

struct SessionSidebarView: View {
    @ObserveInjection var inject
    @Binding var selectedThread: ThreadKey?
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var appState: AppState
    @State private var isLoading = true
    @State private var showDirectoryPicker = false
    @State private var showBackendPicker = false
    @State private var selectedServerId: String?

    var body: some View {
        List(selection: $selectedThread) {
            Section {
                newSessionButton
            }

            Section("Servers") {
                serversContent
            }

            Section("Recent Sessions") {
                sessionsContent
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Sessions")
        .enableInjection()
        .task { await loadSessions() }
        .onChange(of: serverManager.hasAnyConnection) { _, connected in
            if connected { Task { await loadSessions() } }
        }
        .sheet(isPresented: $showDirectoryPicker) {
            NavigationStack {
                DirectoryPickerView(
                    serverId: selectedServerId ?? connectedServerIds.first ?? "",
                    onDirectorySelected: { cwd in
                        showDirectoryPicker = false
                        let serverId = selectedServerId ?? connectedServerIds.first ?? ""
                        Task { await startNewSession(serverId: serverId, cwd: cwd) }
                    }
                )
                .environmentObject(serverManager)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { showDirectoryPicker = false }
                    }
                }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var serversContent: some View {
        let connected = connectedServers
        let machineCount = connectedMachineGroups.count
        if connected.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "xmark.circle")
                    .foregroundColor(MocodeTheme.textMuted)
                Text("Not connected")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundColor(MocodeTheme.textMuted)
                Spacer()
                Button("Connect") {
                    appState.showServerPicker = true
                }
                .font(.system(.caption, weight: .semibold))
            }
        } else {
            HStack(spacing: 10) {
                Image(systemName: "server.rack")
                    .foregroundColor(MocodeTheme.accent)
                Text("\(machineCount) server\(machineCount == 1 ? "" : "s")")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundColor(MocodeTheme.textPrimary)
                Spacer()
                Button("Add") {
                    appState.showServerPicker = true
                }
                .font(.system(.caption, weight: .semibold))
            }
        }
    }

    @ViewBuilder
    private var sessionsContent: some View {
        if isLoading {
            HStack {
                Spacer()
                ProgressView().tint(MocodeTheme.accent)
                Spacer()
            }
        } else if serverManager.sortedThreads.isEmpty {
            HStack {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 20))
                        .foregroundColor(MocodeTheme.textMuted)
                    Text("No sessions yet")
                        .font(.system(.subheadline))
                        .foregroundColor(MocodeTheme.textMuted)
                }
                Spacer()
            }
            .padding(.vertical, 20)
        } else {
            ForEach(serverManager.sortedThreads) { thread in
                sessionRow(thread)
                    .tag(thread.key)
            }
        }
    }

    // MARK: - New Session Button

    private var newSessionButton: some View {
        Button {
            let servers = connectedServers
            let machineGroups = connectedMachineGroups
            if servers.isEmpty {
                appState.showServerPicker = true
            } else if machineGroups.count == 1, let group = machineGroups.first {
                if group.connections.count == 1 {
                    selectedServerId = group.connections.first?.id
                    showDirectoryPicker = true
                } else {
                    showBackendPicker = true
                }
            } else {
                showBackendPicker = true
            }
        } label: {
            Label("New Session", systemImage: "plus")
                .font(.system(.body, weight: .semibold))
                .foregroundColor(MocodeTheme.accent)
        }
        .confirmationDialog("Choose Backend", isPresented: $showBackendPicker, titleVisibility: .visible) {
            ForEach(connectedServers, id: \.id) { conn in
                Button(backendLabel(for: conn)) {
                    selectedServerId = conn.id
                    showDirectoryPicker = true
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Session Row

    private func sessionRow(_ thread: ThreadState) -> some View {
        HStack(spacing: 8) {
            if thread.hasTurnActive {
                PulsingDot()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(thread.preview.isEmpty ? "Untitled session" : thread.preview)
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundColor(MocodeTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    Text(relativeDate(thread.updatedAt))
                        .font(.system(.caption))
                        .foregroundColor(MocodeTheme.textSecondary)
                    backendBadge(for: thread)
                    Text((thread.cwd as NSString).lastPathComponent)
                        .font(.system(.caption2))
                        .foregroundColor(MocodeTheme.textMuted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func backendBadge(for thread: ThreadState) -> some View {
        let provider = thread.modelProvider.isEmpty
            ? ServerManager.providerFor(serverManager.connections[thread.serverId]?.serverType ?? .unknown)
            : thread.modelProvider
        let (brand, fallbackIcon, label, color): (ProviderBrand?, String, String, Color) = {
            switch provider {
            case "anthropic":
                return (.claude, "sparkles", "Claude", Color.orange)
            case "openai":
                return (.openAI, "chevron.left.forwardslash.chevron.right", "OpenAI", MocodeTheme.accent)
            default:
                return (nil, serverIconName(for: thread.serverSource), thread.serverName, MocodeTheme.accent)
            }
        }()
        HStack(spacing: 3) {
            if let brand {
                ProviderLogoView(brand: brand, size: 10, tint: color)
            } else {
                Image(systemName: fallbackIcon)
                    .font(.system(.caption2))
            }
            Text(label)
                .font(.system(.caption2, design: .rounded, weight: .medium))
        }
        .foregroundColor(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
    }

    // MARK: - Helpers

    private var connectedServerIds: [String] {
        serverManager.connections.values.filter { $0.isConnected }.map(\.id)
    }

    private var connectedServers: [ServerConnection] {
        serverManager.connections.values.filter { $0.isConnected }
    }

    private struct ConnectedMachineGroup: Identifiable {
        let id: String
        let name: String
        let connections: [ServerConnection]
    }

    private var connectedMachineGroups: [ConnectedMachineGroup] {
        let connected = connectedServers
        let grouped = Dictionary(grouping: connected) { connection in
            machineGroupingKey(name: connection.server.name, host: connection.server.hostname)
        }
        return grouped.map { key, items in
            let preferredName = items.first?.server.name ?? items.first?.server.hostname ?? key
            return ConnectedMachineGroup(
                id: key,
                name: preferredName,
                connections: items.sorted { lhs, rhs in
                    backendSortRank(lhs.serverType) < backendSortRank(rhs.serverType)
                }
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func machineGroupingKey(name: String, host: String) -> String {
        let normalizedName = normalizedMachineIdentity(name)
        let normalizedHost = normalizedMachineIdentity(host)
        return "\(normalizedName)|\(normalizedHost)"
    }

    private func normalizedMachineIdentity(_ value: String) -> String {
        var normalized = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasSuffix(".local") {
            normalized.removeLast(6)
        }
        if normalized.hasSuffix(".ts.net") {
            normalized.removeLast(7)
        }
        if normalized.hasSuffix(".") {
            normalized.removeLast()
        }
        normalized = String(normalized.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        return normalized
    }

    private func backendSortRank(_ type: ServerConnection.ServerType) -> Int {
        switch type {
        case .claude: return 0
        case .codex: return 1
        case .unknown: return 2
        }
    }

    private func backendLabel(for conn: ServerConnection) -> String {
        let backend: String = {
        switch conn.serverType {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .unknown: return "Default"
        }
        }()
        if connectedMachineGroups.count > 1 {
            return "\(backend) · \(conn.server.name)"
        }
        return backend
    }

    @AppStorage("workDir") private var workDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "/"

    private func loadSessions() async {
        guard serverManager.hasAnyConnection else {
            isLoading = false
            return
        }
        isLoading = true
        await serverManager.refreshAllSessions()
        isLoading = false
    }

    private func startNewSession(serverId: String, cwd: String) async {
        workDir = cwd
        appState.currentCwd = cwd
        var model: String? = nil
        if let conn = serverManager.connections[serverId] {
            if !conn.modelsLoaded {
                if let resp = try? await conn.listModels() {
                    conn.models = resp.data
                    conn.modelsLoaded = true
                }
            }
            if let defaultModel = conn.models.first(where: { $0.isDefault }) ?? conn.models.first {
                model = defaultModel.id
                appState.selectedModel = defaultModel.id
                appState.reasoningEffort = defaultModel.defaultReasoningEffort
            }
        }
        if let key = await serverManager.startThread(serverId: serverId, cwd: cwd, model: model) {
            selectedThread = key
        }
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct PulsingDot: View {
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(MocodeTheme.accent)
            .frame(width: 8, height: 8)
            .scaleEffect(pulse ? 1.3 : 1.0)
            .opacity(pulse ? 0.6 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
    }
}

// MARK: - Previews

#Preview("Session Sidebar - Empty") {
    NavigationStack {
        SessionSidebarView(selectedThread: .constant(nil))
            .environmentObject(ServerManager())
            .environmentObject(AppState())
    }
}

#Preview("Pulsing Dot") {
    PulsingDot()
        .padding()
}
