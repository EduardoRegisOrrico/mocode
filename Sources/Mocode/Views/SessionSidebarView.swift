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
    @State private var collapsedFolderIDs: Set<String> = []
    @State private var sessionSearchQuery = ""
    @State private var actionErrorMessage: String?
    @State private var archiveTargetKey: ThreadKey?

    private struct SessionFolderGroup: Identifiable {
        let id: String
        let title: String
        let quickStartServerId: String?
        let quickStartCwd: String?
        let threads: [ThreadState]
    }

    private var trimmedSessionQuery: String {
        sessionSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredThreads: [ThreadState] {
        guard !trimmedSessionQuery.isEmpty else { return serverManager.sortedThreads }
        return serverManager.sortedThreads.filter { thread in
            thread.preview.localizedCaseInsensitiveContains(trimmedSessionQuery) ||
                thread.cwd.localizedCaseInsensitiveContains(trimmedSessionQuery) ||
                thread.serverName.localizedCaseInsensitiveContains(trimmedSessionQuery) ||
                (thread.agentDisplayLabel ?? "").localizedCaseInsensitiveContains(trimmedSessionQuery)
        }
    }

    private var connectedServerOptions: [DirectoryPickerServerOption] {
        connectedServers
            .sorted { $0.server.name.localizedCaseInsensitiveCompare($1.server.name) == .orderedAscending }
            .map {
                DirectoryPickerServerOption(
                    id: $0.id,
                    name: backendLabel(for: $0),
                    sourceLabel: $0.server.source.rawString
                )
            }
    }

    private var archiveTargetThread: ThreadState? {
        guard let archiveTargetKey else { return nil }
        return serverManager.threads[archiveTargetKey]
    }

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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await loadSessions() }
                } label: {
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isLoading)
            }
        }
        .enableInjection()
        .task { await loadSessions() }
        .onChange(of: serverManager.hasAnyConnection) { _, connected in
            if connected { Task { await loadSessions() } }
        }
        .onChange(of: connectedServerIds) { _, ids in
            if let selectedServerId, !ids.contains(selectedServerId) {
                self.selectedServerId = ids.first
            }
        }
        .sheet(isPresented: $showDirectoryPicker) {
            NavigationStack {
                DirectoryPickerView(
                    servers: connectedServerOptions,
                    selectedServerId: Binding(
                        get: { selectedServerId ?? connectedServerIds.first ?? "" },
                        set: { selectedServerId = $0 }
                    ),
                    onServerChanged: { selectedServerId = $0 },
                    onDirectorySelected: { serverId, cwd in
                        showDirectoryPicker = false
                        Task { await startNewSession(serverId: serverId, cwd: cwd) }
                    }
                )
                .environmentObject(serverManager)
            }
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
        .alert("Session Action Failed", isPresented: Binding(
            get: { actionErrorMessage != nil },
            set: { if !$0 { actionErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { actionErrorMessage = nil }
        } message: {
            Text(actionErrorMessage ?? "Unknown error")
        }
        .confirmationDialog(
            "Delete session?",
            isPresented: Binding(
                get: { archiveTargetKey != nil },
                set: { if !$0 { archiveTargetKey = nil } }
            ),
            titleVisibility: .visible,
            presenting: archiveTargetThread
        ) { thread in
            Button("Delete \"\(thread.preview.isEmpty ? "Untitled session" : thread.preview)\"", role: .destructive) {
                Task {
                    guard let key = archiveTargetKey else { return }
                    let success = await serverManager.archiveThread(key)
                    archiveTargetKey = nil
                    if success {
                        selectedThread = serverManager.activeThreadKey
                    } else {
                        actionErrorMessage = "Failed to delete session."
                    }
                }
            }
            Button("Cancel", role: .cancel) { archiveTargetKey = nil }
        } message: { _ in
            Text("This removes the session from the sidebar list.")
        }
    }

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
        searchRow

        if isLoading {
            HStack {
                Spacer()
                ProgressView().tint(MocodeTheme.accent)
                Spacer()
            }
        } else if filteredThreads.isEmpty {
            HStack {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 20))
                        .foregroundColor(MocodeTheme.textMuted)
                    Text(trimmedSessionQuery.isEmpty ? "No sessions yet" : "No matches for \"\(trimmedSessionQuery)\"")
                        .font(.system(.subheadline))
                        .foregroundColor(MocodeTheme.textMuted)
                }
                Spacer()
            }
            .padding(.vertical, 20)
        } else {
            ForEach(groupedThreads) { group in
                DisclosureGroup(isExpanded: isGroupExpanded(group.id)) {
                    ForEach(group.threads) { thread in
                        sessionRow(thread)
                            .tag(thread.key)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .font(.system(.caption, weight: .semibold))
                            .foregroundColor(MocodeTheme.textMuted)
                        Text(group.title)
                            .font(.system(.caption, design: .rounded, weight: .semibold))
                            .foregroundColor(MocodeTheme.textSecondary)
                            .lineLimit(1)
                        Spacer()
                        if let quickServerId = group.quickStartServerId,
                           let quickStartCwd = group.quickStartCwd {
                            Button {
                                Task {
                                    let success = await startNewSession(serverId: quickServerId, cwd: quickStartCwd)
                                    if !success {
                                        actionErrorMessage = "Failed to start a session in \(group.title)."
                                    }
                                }
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(.caption, weight: .bold))
                                    .foregroundColor(MocodeTheme.accent)
                            }
                            .buttonStyle(.borderless)
                            .contentShape(Rectangle())
                            .help("New session in \(group.title)")
                        }
                        Text("\(group.threads.count)")
                            .font(.system(.caption2, design: .rounded, weight: .semibold))
                            .foregroundColor(MocodeTheme.textMuted)
                    }
                }
            }
        }
    }

    private var searchRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(MocodeTheme.textMuted)
            TextField("Search sessions", text: $sessionSearchQuery)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.caption, design: .rounded))
            if !trimmedSessionQuery.isEmpty {
                Button {
                    sessionSearchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(MocodeTheme.textMuted)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(MocodeTheme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var newSessionButton: some View {
        Button {
            let servers = connectedServers
            let machineGroups = connectedMachineGroups
            Task {
                let backendSummary = servers.map { "\($0.id):\($0.serverType.displayName)" }.joined(separator: ",")
                await DebugLog.shared.log("newSession tapped connectedServers=\(servers.count) machineGroups=\(machineGroups.count) backends=\(backendSummary)")
            }
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
    }

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
                    if let provider = sessionProviderInfo(thread) {
                        ProviderLogoView(brand: provider.brand, size: 10, tint: provider.color)
                        Text(provider.label)
                    }
                    Text((thread.cwd as NSString).lastPathComponent)
                }
                .font(.system(.caption2, design: .rounded))
                .foregroundColor(MocodeTheme.textSecondary)
                .lineLimit(1)

                if let agent = thread.agentDisplayLabel {
                    Text(agent)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(MocodeTheme.textMuted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contextMenu {
            Button {
                Task {
                    let key = thread.key
                    if let forked = await serverManager.forkThread(
                        key,
                        cwd: thread.cwd,
                        approvalPolicy: appState.resolvedApprovalPolicy,
                        sandboxMode: appState.resolvedSandboxMode
                    ) {
                        selectedThread = forked
                    } else {
                        actionErrorMessage = "Failed to fork session."
                    }
                }
            } label: {
                Label("Fork Session", systemImage: "arrow.triangle.branch")
            }

            Button {
                Task {
                    let success = await serverManager.rollbackThread(thread.key, numTurns: 1)
                    if !success {
                        actionErrorMessage = "Failed to roll back last turn."
                    }
                }
            } label: {
                Label("Rollback Last Turn", systemImage: "arrow.uturn.backward")
            }

            Button(role: .destructive) {
                archiveTargetKey = thread.key
            } label: {
                Label("Delete Session", systemImage: "trash")
            }
        }
    }

    private func sessionProviderInfo(_ thread: ThreadState) -> (brand: ProviderBrand, label: String, color: Color)? {
        let provider = thread.modelProvider.isEmpty
            ? ServerManager.providerFor(serverManager.connections[thread.serverId]?.serverType ?? .unknown)
            : thread.modelProvider
        switch provider {
        case "anthropic":
            return (.claude, "Claude", Color(hex: "#D86D22"))
        case "openai":
            return (.openAI, "OpenAI", MocodeTheme.accent)
        default:
            return nil
        }
    }

    private var connectedServerIds: [String] {
        serverManager.connections.values.filter { $0.isConnected }.map(\.id)
    }

    private var groupedThreads: [SessionFolderGroup] {
        let groups = Dictionary(grouping: filteredThreads) { thread -> String in
            let trimmed = thread.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "__unknown__" : trimmed
        }

        return groups.map { cwd, threads in
            let title: String
            if cwd == "__unknown__" {
                title = "Unknown Folder"
            } else {
                let last = (cwd as NSString).lastPathComponent
                title = last.isEmpty ? cwd : last
            }
            let sortedThreads = threads.sorted { $0.updatedAt > $1.updatedAt }
            let connectedThread = sortedThreads.first { thread in
                serverManager.connections[thread.serverId]?.isConnected == true
            }
            let quickThread = connectedThread
            let quickCwd = cwd == "__unknown__" ? nil : cwd
            return SessionFolderGroup(
                id: cwd,
                title: title,
                quickStartServerId: quickThread?.serverId,
                quickStartCwd: quickCwd,
                threads: sortedThreads
            )
        }
        .sorted { lhs, rhs in
            guard let l = lhs.threads.first?.updatedAt, let r = rhs.threads.first?.updatedAt else {
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            return l > r
        }
    }

    private func isGroupExpanded(_ groupId: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedFolderIDs.contains(groupId) },
            set: { isExpanded in
                if isExpanded {
                    collapsedFolderIDs.remove(groupId)
                } else {
                    collapsedFolderIDs.insert(groupId)
                }
            }
        )
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

    @discardableResult
    private func startNewSession(serverId: String, cwd: String) async -> Bool {
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
        if let key = await serverManager.startThread(
            serverId: serverId,
            cwd: cwd,
            model: model,
            approvalPolicy: appState.resolvedApprovalPolicy,
            sandboxMode: appState.resolvedSandboxMode
        ) {
            selectedThread = key
            return true
        }
        return false
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
