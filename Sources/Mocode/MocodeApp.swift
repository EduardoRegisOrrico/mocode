import SwiftUI
import Inject

@main
struct MocodeApp: App {
    @StateObject private var serverManager = ServerManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(serverManager)
                .task {
                    await DebugLog.shared.reset()
                    await DebugLog.shared.log("app launch")
                    await serverManager.reconnectAll()
                }
        }
    }
}

struct ContentView: View {
    @ObserveInjection var inject
    @EnvironmentObject var serverManager: ServerManager
    @StateObject private var appState = AppState()
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            ChatTab()
                .environmentObject(appState)
                .tabItem {
                    Label("Chat", systemImage: "bubble.left.and.bubble.right")
                }
                .tag(0)

            SettingsTab()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(1)
        }
        .environmentObject(appState)
        .task {
            await liveSyncLoop()
        }
        .enableInjection()
    }

    private func liveSyncLoop() async {
        while !Task.isCancelled {
            if serverManager.hasAnyConnection {
                await serverManager.performLiveSyncPass()
            }
            let delay: Duration = serverManager.activeThreadKey == nil ? .seconds(5) : .seconds(2)
            try? await Task.sleep(for: delay)
        }
    }
}

struct ChatTab: View {
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var appState: AppState
    @State private var showAccount = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var selectedThread: ThreadKey?

    private var activeAuthStatus: AuthStatus {
        serverManager.activeConnection?.authStatus ?? .unknown
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SessionSidebarView(selectedThread: $selectedThread)
        } detail: {
            if serverManager.activeThreadKey != nil {
                ConversationView()
            } else {
                EmptyStateView()
            }
        }
        .onChange(of: selectedThread) { _, newKey in
            guard let key = newKey else { return }
            if serverManager.activeThreadKey != key {
                Task {
                    if let thread = serverManager.threads[key] {
                        appState.currentCwd = thread.cwd
                        await serverManager.viewThread(
                            key,
                            approvalPolicy: appState.resolvedApprovalPolicy,
                            sandboxMode: appState.resolvedSandboxMode
                        )
                    }
                }
            }
        }
        .onChange(of: serverManager.activeThreadKey) { _, newKey in
            if selectedThread != newKey {
                selectedThread = newKey
            }
        }
        .onAppear {
            if !serverManager.hasAnyConnection {
                appState.showServerPicker = true
            }
        }
        .onChange(of: activeAuthStatus) { _, newStatus in
            if case .notLoggedIn = newStatus {
                showAccount = true
            }
        }
        .sheet(isPresented: $showAccount) {
            AccountView().environmentObject(serverManager)
        }
        .sheet(isPresented: $appState.showServerPicker) {
            NavigationStack {
                DiscoveryView(onServerSelected: { server in
                    appState.showServerPicker = false
                    columnVisibility = .automatic
                })
                .environmentObject(serverManager)
            }
        }
    }
}

struct SettingsTab: View {
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var appState: AppState
    @State private var showAccount = false
    @State private var showMcpServers = false

    private struct ConnectedMachineGroup: Identifiable {
        let id: String
        let name: String
        let host: String
        let connections: [ServerConnection]
    }

    private var connectedServerGroups: [ConnectedMachineGroup] {
        let connected = serverManager.connections.values.filter { $0.isConnected }
        let grouped = Dictionary(grouping: connected) { connection in
            machineGroupingKey(name: connection.server.name, host: connection.server.hostname)
        }
        return grouped.map { key, connections in
            ConnectedMachineGroup(
                id: key,
                name: connections.first?.server.name ?? "Server",
                host: connections.first?.server.hostname ?? "",
                connections: connections.sorted { lhs, rhs in
                    backendSortRank(lhs.serverType) < backendSortRank(rhs.serverType)
                }
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func machineGroupingKey(name: String, host: String) -> String {
        "\(normalizeIdentity(name))|\(normalizeIdentity(host))"
    }

    private func normalizeIdentity(_ value: String) -> String {
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

    private func backendLabel(for type: ServerConnection.ServerType) -> String {
        switch type {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .unknown: return "Default"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        showAccount = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Account")
                                    .foregroundColor(MocodeTheme.textPrimary)
                                    .font(.system(.subheadline, design: .rounded))
                                Text(accountSummary)
                                    .font(.system(.caption, design: .rounded))
                                    .foregroundColor(MocodeTheme.textSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundColor(MocodeTheme.textMuted)
                                .font(.caption)
                        }
                    }
                } header: {
                    Text("Authentication")
                        .foregroundColor(MocodeTheme.textSecondary)
                }

                Section {
                    Button {
                        showMcpServers = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("MCP Servers")
                                    .foregroundColor(MocodeTheme.textPrimary)
                                    .font(.system(.subheadline, design: .rounded))
                                Text(mcpSummary)
                                    .font(.system(.caption, design: .rounded))
                                    .foregroundColor(MocodeTheme.textSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundColor(MocodeTheme.textMuted)
                                .font(.caption)
                        }
                    }
                } header: {
                    Text("Plugins")
                        .foregroundColor(MocodeTheme.textSecondary)
                }

                Section {
                    Picker("Approval Policy", selection: $appState.approvalPolicy) {
                        Text("Desktop Default").tag(AppState.desktopDefaultValue)
                        Text("Never").tag("never")
                        Text("On Request").tag("on-request")
                        Text("On Failure").tag("on-failure")
                        Text("Untrusted").tag("untrusted")
                    }
                    Picker("Sandbox", selection: $appState.sandboxMode) {
                        Text("Desktop Default").tag(AppState.desktopDefaultValue)
                        Text("Workspace Write").tag("workspace-write")
                        Text("Read Only").tag("read-only")
                        Text("Danger Full Access").tag("danger-full-access")
                    }
                } header: {
                    Text("Execution Policy")
                        .foregroundColor(MocodeTheme.textSecondary)
                } footer: {
                    Text("Applied to new/resumed/forked sessions and turn execution defaults.")
                        .font(.system(.caption2, design: .rounded))
                        .foregroundColor(MocodeTheme.textMuted)
                }

                Section {
                    let groups = connectedServerGroups
                    if groups.isEmpty {
                        Text("No servers connected")
                            .font(.system(.footnote, design: .rounded))
                            .foregroundColor(MocodeTheme.textMuted)
                    } else {
                        ForEach(groups) { group in
                            HStack {
                                Image(systemName: serverIconName(for: group.connections.first?.server.source ?? .manual))
                                    .foregroundColor(MocodeTheme.accent)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.name)
                                        .font(.system(.footnote, design: .rounded))
                                        .foregroundColor(MocodeTheme.textPrimary)
                                    Text(group.host)
                                        .font(.system(.caption2, design: .rounded))
                                        .foregroundColor(MocodeTheme.textMuted)
                                    Text("Connected · \(group.connections.map { backendLabel(for: $0.serverType) }.joined(separator: ", "))")
                                        .font(.system(.caption, design: .rounded))
                                        .foregroundColor(MocodeTheme.accent)
                                }
                                Spacer()
                                Button("Remove") {
                                    for connection in group.connections {
                                        serverManager.removeServer(id: connection.id)
                                    }
                                }
                                .font(.system(.caption, design: .rounded))
                                .foregroundColor(Color(hex: "#FF5555"))
                            }
                        }
                    }
                } header: {
                    Text("Servers")
                        .foregroundColor(MocodeTheme.textSecondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: $showAccount) {
            AccountView()
                .environmentObject(serverManager)
        }
        .sheet(isPresented: $showMcpServers) {
            McpServersView()
                .environmentObject(serverManager)
        }
    }

    private var mcpSummary: String {
        let servers = serverManager.mcpServers
        if !serverManager.mcpServersLoaded { return "Tap to view" }
        if servers.isEmpty { return "No servers" }
        let toolCount = servers.reduce(0) { $0 + $1.tools.count }
        let parts = [
            "\(servers.count) server\(servers.count == 1 ? "" : "s")",
            "\(toolCount) tool\(toolCount == 1 ? "" : "s")"
        ]
        return parts.joined(separator: " · ")
    }

    private var accountSummary: String {
        let conn = serverManager.activeConnection ?? serverManager.connections.values.first(where: { $0.isConnected })
        guard let conn else { return "Connect first" }
        switch conn.authStatus {
        case .chatgpt(let email): return email.isEmpty ? "ChatGPT" : email
        case .apiKey: return "API Key"
        case .claude: return "Claude CLI"
        case .notLoggedIn: return "Not logged in"
        case .unknown: return conn.isConnected ? "Checking…" : "Connect first"
        }
    }
}

struct LaunchView: View {
    var body: some View {
        VStack(spacing: 24) {
            BrandLogo(size: 132)
            Text("AI coding agent on iOS")
                .font(.system(.body, design: .rounded))
                .foregroundColor(MocodeTheme.textMuted)
        }
    }
}

// MARK: - Previews

#Preview("App with Tabs") {
    ContentView()
        .environmentObject(ServerManager())
}

#Preview("Settings Tab") {
    SettingsTab()
        .environmentObject(ServerManager())
}
