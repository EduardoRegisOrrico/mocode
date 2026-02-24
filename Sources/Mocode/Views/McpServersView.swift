import SwiftUI

struct McpServersView: View {
    @EnvironmentObject var serverManager: ServerManager
    @Environment(\.dismiss) private var dismiss
    @State private var expandedServer: String?
    @State private var oauthURL: URL?
    @State private var showOAuth = false
    @State private var isReloading = false

    private var groupedServers: [(provider: String, servers: [McpServerStatus], error: String?)] {
        let grouped = Dictionary(grouping: serverManager.mcpServers) { $0.provider }
        var sections: [(provider: String, servers: [McpServerStatus], error: String?)] = []
        var seen = Set<String>()
        for result in serverManager.backendResults {
            seen.insert(result.provider)
            let servers = grouped[result.provider]?
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } ?? []
            sections.append((provider: result.provider, servers: servers, error: result.mcpError))
        }
        for key in grouped.keys.sorted() where !seen.contains(key) {
            sections.append((provider: key, servers: grouped[key]!, error: nil))
        }
        return sections.sorted { $0.provider < $1.provider }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !serverManager.mcpServersLoaded {
                    loadingState
                } else if serverManager.mcpServers.isEmpty && serverManager.backendResults.isEmpty {
                    emptyState
                } else {
                    serverList
                }
            }
            .navigationTitle("MCP Servers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(MocodeTheme.accent)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task {
                            isReloading = true
                            await serverManager.reloadMcpServers()
                            isReloading = false
                        }
                    } label: {
                        if isReloading {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .foregroundColor(MocodeTheme.accent)
                    .disabled(isReloading)
                }
            }
        }
        .sheet(isPresented: $showOAuth) {
            oauthSheet
        }
        .task {
            if !serverManager.mcpServersLoaded {
                await serverManager.refreshMcpServers()
            }
        }
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .scaleEffect(1.2)
            Text("Loading MCP servers…")
                .font(.system(.subheadline, design: .rounded))
                .foregroundColor(MocodeTheme.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 40))
                .foregroundColor(MocodeTheme.textMuted)
            Text("No MCP servers configured")
                .font(.system(.headline, design: .rounded))
                .foregroundColor(MocodeTheme.textPrimary)
            Text("Configure MCP servers in your app-server settings, then reload.")
                .font(.system(.footnote, design: .rounded))
                .foregroundColor(MocodeTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                Task {
                    isReloading = true
                    await serverManager.reloadMcpServers()
                    isReloading = false
                }
            } label: {
                HStack(spacing: 6) {
                    if isReloading {
                        ProgressView().scaleEffect(0.7).tint(MocodeTheme.accentForeground)
                    }
                    Text("Reload")
                        .font(.system(.subheadline, design: .rounded))
                }
                .foregroundColor(MocodeTheme.accentForeground)
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .background(MocodeTheme.accent)
                .cornerRadius(8)
            }
            .disabled(isReloading)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Server List

    private var serverList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groupedServers, id: \.provider) { group in
                    sectionHeader(group.provider, count: group.servers.count, error: group.error)
                    if group.servers.isEmpty {
                        emptySection(error: group.error)
                    } else {
                        ForEach(group.servers) { server in
                            serverRow(server)
                            if server.id != group.servers.last?.id {
                                Divider().background(MocodeTheme.surfaceLight)
                                    .padding(.horizontal, 16)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func sectionHeader(_ provider: String, count: Int, error: String?) -> some View {
        HStack(spacing: 6) {
            providerIcon(provider)
            Text(provider)
                .font(.system(.caption, design: .rounded).bold())
                .foregroundColor(MocodeTheme.textSecondary)
                .textCase(.uppercase)
            Spacer()
            if let error {
                Text("error")
                    .font(.system(.caption2, design: .rounded).bold())
                    .foregroundColor(Color(hex: "#FF5555"))
            } else {
                Text("\(count) server\(count == 1 ? "" : "s")")
                    .font(.system(.caption2, design: .rounded))
                    .foregroundColor(MocodeTheme.textMuted)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 6)
    }

    private func emptySection(error: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundColor(Color(hex: "#FF5555"))
                    Text(error)
                        .font(.system(.caption, design: .rounded))
                        .foregroundColor(Color(hex: "#FF5555"))
                        .lineLimit(3)
                }
            } else {
                Text("No MCP servers configured")
                    .font(.system(.caption, design: .rounded))
                    .foregroundColor(MocodeTheme.textMuted)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func providerIcon(_ provider: String) -> some View {
        switch provider.lowercased() {
        case "claude":
            ProviderLogoView(brand: .claude, size: 12, tint: Color(hex: "#D86D22"))
        case "codex":
            ProviderLogoView(brand: .openAI, size: 12, tint: MocodeTheme.accent)
        default:
            Image(systemName: "server.rack")
                .font(.system(size: 10))
                .foregroundColor(MocodeTheme.textMuted)
        }
    }

    private func serverRow(_ server: McpServerStatus) -> some View {
        let isExpanded = expandedServer == server.id
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedServer = isExpanded ? nil : server.id
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "puzzlepiece.extension")
                        .foregroundColor(MocodeTheme.accent)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(server.name)
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundColor(MocodeTheme.textPrimary)
                        HStack(spacing: 8) {
                            if !server.tools.isEmpty {
                                Label("\(server.tools.count) tools", systemImage: "wrench")
                            }
                            if !server.resources.isEmpty {
                                Label("\(server.resources.count) resources", systemImage: "doc")
                            }
                            if !server.resourceTemplates.isEmpty {
                                Label("\(server.resourceTemplates.count) templates", systemImage: "doc.badge.plus")
                            }
                        }
                        .font(.system(.caption2, design: .rounded))
                        .foregroundColor(MocodeTheme.textMuted)
                    }
                    Spacer()
                    authBadge(server.authStatus)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundColor(MocodeTheme.textMuted)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                expandedContent(server)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Auth Badge

    private func authBadge(_ status: McpAuthStatus) -> some View {
        Group {
            switch status {
            case .oAuth, .bearerToken:
                Text("Authenticated")
                    .font(.system(.caption2, design: .rounded).bold())
                    .foregroundColor(Color(hex: "#0D0D0D"))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(MocodeTheme.accent)
                    .cornerRadius(4)
            case .notLoggedIn:
                Text("Login Required")
                    .font(.system(.caption2, design: .rounded).bold())
                    .foregroundColor(Color(hex: "#FF5555"))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color(hex: "#FF5555").opacity(0.15))
                    .cornerRadius(4)
            case .unsupported:
                EmptyView()
            }
        }
    }

    // MARK: - Expanded Content

    private func expandedContent(_ server: McpServerStatus) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if server.authStatus == .notLoggedIn {
                Button {
                    Task {
                        if let url = await serverManager.mcpOauthLogin(serverName: server.name, serverId: server.serverId) {
                            oauthURL = url
                            showOAuth = true
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: "person.badge.key")
                        Text("Login with OAuth")
                            .font(.system(.footnote, design: .rounded))
                    }
                    .foregroundColor(MocodeTheme.accentForeground)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(MocodeTheme.accent)
                    .cornerRadius(8)
                }
            }

            let tools = server.sortedTools
            if !tools.isEmpty {
                detailSection(title: "Tools", icon: "wrench") {
                    ForEach(tools) { tool in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tool.title ?? tool.name)
                                .font(.system(.caption, design: .rounded))
                                .foregroundColor(MocodeTheme.textPrimary)
                            if let desc = tool.description, !desc.isEmpty {
                                Text(desc)
                                    .font(.system(.caption2, design: .rounded))
                                    .foregroundColor(MocodeTheme.textSecondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            if !server.resources.isEmpty {
                detailSection(title: "Resources", icon: "doc") {
                    ForEach(server.resources) { resource in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(resource.name)
                                .font(.system(.caption, design: .rounded))
                                .foregroundColor(MocodeTheme.textPrimary)
                            Text(resource.uri)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(MocodeTheme.textMuted)
                                .lineLimit(1)
                            if let desc = resource.description, !desc.isEmpty {
                                Text(desc)
                                    .font(.system(.caption2, design: .rounded))
                                    .foregroundColor(MocodeTheme.textSecondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            if !server.resourceTemplates.isEmpty {
                detailSection(title: "Resource Templates", icon: "doc.badge.plus") {
                    ForEach(server.resourceTemplates) { template in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(template.name)
                                .font(.system(.caption, design: .rounded))
                                .foregroundColor(MocodeTheme.textPrimary)
                            Text(template.uriTemplate)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(MocodeTheme.textMuted)
                                .lineLimit(1)
                            if let desc = template.description, !desc.isEmpty {
                                Text(desc)
                                    .font(.system(.caption2, design: .rounded))
                                    .foregroundColor(MocodeTheme.textSecondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .padding(.leading, 36)
    }

    private func detailSection<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                Text(title)
                    .font(.system(.caption, design: .rounded).bold())
            }
            .foregroundColor(MocodeTheme.textSecondary)
            content()
        }
    }

    // MARK: - OAuth Sheet

    @ViewBuilder
    private var oauthSheet: some View {
        if let url = oauthURL {
            NavigationStack {
                SafariView(url: url) {
                    showOAuth = false
                    oauthURL = nil
                }
                .ignoresSafeArea()
                .navigationTitle("MCP OAuth Login")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") {
                            showOAuth = false
                            oauthURL = nil
                        }
                        .foregroundColor(Color(hex: "#FF5555"))
                    }
                }
            }
            .onDisappear {
                Task { await serverManager.refreshMcpServers() }
            }
        }
    }
}

// MARK: - Previews

#Preview("MCP Servers - Loading") {
    McpServersView()
        .environmentObject(ServerManager())
}

#Preview("MCP Servers - Empty") {
    let manager = ServerManager()
    manager.mcpServersLoaded = true
    return McpServersView()
        .environmentObject(manager)
}
