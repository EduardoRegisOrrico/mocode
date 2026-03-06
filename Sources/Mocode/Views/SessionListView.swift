import SwiftUI

struct SessionListView: View {
    let server: DiscoveredServer
    let cwd: String
    var onSessionReady: ((DiscoveredServer, String) -> Void)?
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var appState: AppState
    @AppStorage("workDir") private var workDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "/"
    @State private var sessions: [ThreadSummary] = []
    @State private var nextCursor: String?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var resumingThreadId: String?
    @State private var navigateToConversation = false

    private var conn: ServerConnection? {
        serverManager.connections[server.id]
    }

    var body: some View {
        Group {
            if isLoading && sessions.isEmpty {
                ProgressView().tint(MocodeTheme.accent)
            } else if let err = errorMessage, sessions.isEmpty {
                VStack(spacing: 12) {
                    Text(err)
                        .font(.system(.caption, design: .rounded))
                        .foregroundColor(.red)
                    Button("Retry") { Task { await loadSessions() } }
                        .foregroundColor(MocodeTheme.accent)
                }
            } else {
                sessionList
            }
        }
        .navigationTitle(cwdLabel)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("New Session") {
                    Task { await startNew() }
                }
                .foregroundColor(MocodeTheme.accent)
                .font(.system(.footnote, design: .rounded))
            }
        }
        .navigationDestination(isPresented: $navigateToConversation) {
            ConversationView()
        }
        .task { await loadSessions() }
    }

    private var cwdLabel: String {
        (cwd as NSString).lastPathComponent
    }

    private var sessionList: some View {
        List {
            if let err = errorMessage {
                Text(err)
                    .font(.system(.caption, design: .rounded))
                    .foregroundColor(.red)
                    .padding(.vertical, 6)
            }

            if sessions.isEmpty {
                VStack(spacing: 12) {
                    Text("No previous sessions")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundColor(MocodeTheme.textMuted)
                    Text("Start a new session to begin")
                        .font(.system(.caption, design: .rounded))
                        .foregroundColor(MocodeTheme.textMuted)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .listRowBackground(Color.clear)
            }

            ForEach(sessions) { session in
                Button {
                    Task { await resumeSession(session) }
                } label: {
                    sessionRow(session)
                }
                .disabled(isResuming)
                .listRowBackground(MocodeTheme.surface.opacity(0.6))
            }

            if nextCursor != nil {
                Button("Load more") { Task { await loadMore() } }
                    .foregroundColor(MocodeTheme.accent)
                    .font(.system(.footnote, design: .rounded))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func sessionRow(_ session: ThreadSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(session.preview.isEmpty ? "Untitled session" : session.preview)
                    .font(.system(.footnote, design: .rounded))
                    .foregroundColor(MocodeTheme.textPrimary)
                    .lineLimit(2)
                Spacer(minLength: 0)
                if resumingThreadId == session.id {
                    ProgressView()
                        .controlSize(.small)
                        .tint(MocodeTheme.accent)
                }
            }
            HStack(spacing: 8) {
                Text(relativeDate(session.updatedAt))
                    .font(.system(.caption, design: .rounded))
                    .foregroundColor(MocodeTheme.textSecondary)
                Text(session.modelProvider)
                    .font(.system(.caption2, design: .rounded))
                    .foregroundColor(MocodeTheme.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(MocodeTheme.accent.opacity(0.15))
                    .cornerRadius(4)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func loadSessions() async {
        guard let conn else { return }
        isLoading = true
        errorMessage = nil
        do {
            let resp = try await conn.listThreads(cwd: cwd)
            sessions = resp.data
            nextCursor = resp.nextCursor
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func loadMore() async {
        guard let conn, let cursor = nextCursor else { return }
        do {
            let resp = try await conn.listThreads(cwd: cwd, cursor: cursor)
            sessions.append(contentsOf: resp.data)
            nextCursor = resp.nextCursor
        } catch {}
    }

    private func resumeSession(_ session: ThreadSummary) async {
        guard !isResuming else { return }
        errorMessage = nil
        resumingThreadId = session.id
        workDir = cwd
        let success = await serverManager.resumeThread(
            serverId: server.id,
            threadId: session.id,
            cwd: cwd,
            approvalPolicy: appState.resolvedApprovalPolicy,
            sandboxMode: appState.resolvedSandboxMode
        )
        resumingThreadId = nil
        if success {
            if let onSessionReady { onSessionReady(server, cwd) } else { navigateToConversation = true }
            return
        }
        if let thread = serverManager.threads[ThreadKey(serverId: server.id, threadId: session.id)],
           case .error(let message) = thread.status {
            errorMessage = message
        } else {
            errorMessage = "Failed to open conversation."
        }
    }

    private func startNew() async {
        guard !isResuming else { return }
        workDir = cwd
        let model = (serverManager.activeConnection?.models.first(where: { $0.isDefault })?.id)
        _ = await serverManager.startThread(
            serverId: server.id,
            cwd: cwd,
            model: model,
            approvalPolicy: appState.resolvedApprovalPolicy,
            sandboxMode: appState.resolvedSandboxMode
        )
        if let onSessionReady { onSessionReady(server, cwd) } else { navigateToConversation = true }
    }

    private var isResuming: Bool {
        resumingThreadId != nil
    }
}
