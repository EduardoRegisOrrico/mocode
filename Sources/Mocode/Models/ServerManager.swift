import Foundation
import Combine

struct BackendFetchResult: Identifiable {
    let id: String        // connection ID
    let provider: String  // "Claude" / "Codex"
    var mcpCount: Int = 0
    var skillsCount: Int = 0
    var mcpUnsupported: Bool = false
    var skillsUnsupported: Bool = false
    var mcpError: String?
    var skillsError: String?
}

@MainActor
final class ServerManager: ObservableObject {
    @Published var connections: [String: ServerConnection] = [:]
    @Published var threads: [ThreadKey: ThreadState] = [:]
    @Published var activeThreadKey: ThreadKey?
    @Published var mcpServers: [McpServerStatus] = []
    @Published var mcpServersLoaded = false
    @Published var skills: [SkillMetadata] = []
    @Published var skillsLoaded = false
    @Published var backendResults: [BackendFetchResult] = []

    private let savedServersKey = "codex_saved_servers"
    private var threadSubscriptions: [ThreadKey: AnyCancellable] = [:]

    /// Call after inserting a new ThreadState into `threads` to forward its changes.
    private func observeThread(_ thread: ThreadState) {
        threadSubscriptions[thread.key] = thread.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var sortedThreads: [ThreadState] {
        threads.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    var activeThread: ThreadState? {
        activeThreadKey.flatMap { threads[$0] }
    }

    var activeConnection: ServerConnection? {
        activeThreadKey.flatMap { connections[$0.serverId] }
    }

    var hasAnyConnection: Bool {
        connections.values.contains { $0.isConnected }
    }

    // MARK: - Server Lifecycle

    func addServer(_ server: DiscoveredServer, target: ConnectionTarget) async {
        if let existing = connections[server.id] {
            // Replace stale connection records when SSH startup chose a new port/host.
            if !targetsMatch(existing.target, target) {
                existing.disconnect()
                connections.removeValue(forKey: server.id)
            } else {
                if !existing.isConnected {
                    await existing.connect()
                    if existing.isConnected {
                        await refreshSessions(for: server.id)
                    }
                }
                return
            }
        }

        let conn = ServerConnection(server: server, target: target)
        conn.onNotification = { [weak self] method, data in
            self?.handleNotification(serverId: server.id, method: method, data: data)
        }
        conn.onDisconnect = { [weak self] in
            self?.objectWillChange.send()
        }
        connections[server.id] = conn
        saveServerList()
        await conn.connect()
        if conn.isConnected {
            await refreshSessions(for: server.id)
        }
    }

    private func targetsMatch(_ lhs: ConnectionTarget, _ rhs: ConnectionTarget) -> Bool {
        switch (lhs, rhs) {
        case (.local, .local):
            return true
        case (.remote(let lHost, let lPort), .remote(let rHost, let rPort)):
            return lHost == rHost && lPort == rPort
        case (.sshThenRemote(let lHost, _), .sshThenRemote(let rHost, _)):
            return lHost == rHost
        default:
            return false
        }
    }

    func removeServer(id: String) {
        connections[id]?.disconnect()
        connections.removeValue(forKey: id)
        for key in threads.keys where key.serverId == id {
            threadSubscriptions.removeValue(forKey: key)
        }
        threads = threads.filter { $0.key.serverId != id }
        if activeThreadKey?.serverId == id {
            activeThreadKey = nil
        }
        saveServerList()
    }

    func reconnectAll() async {
        let saved = loadSavedServers()

        var directServers: [SavedServer] = []
        var sshServers: [SavedServer] = []

        for s in saved {
            if s.sshPort != nil {
                sshServers.append(s)
            } else {
                directServers.append(s)
            }
        }

        await withTaskGroup(of: Void.self) { group in
            for s in directServers {
                let server = s.toDiscoveredServer()
                if server.source == .local && !OnDeviceCodexFeature.isEnabled {
                    continue
                }
                guard let target = server.connectionTarget else { continue }
                group.addTask { @MainActor in
                    await self.addServer(server, target: target)
                }
            }

            if !sshServers.isEmpty {
                group.addTask { @MainActor in
                    await self.reconnectSSHServers(sshServers)
                }
            }
        }
    }

    private func reconnectSSHServers(_ servers: [SavedServer]) async {
        struct SSHEndpoint: Hashable {
            let host: String
            let port: UInt16
        }

        var groups: [SSHEndpoint: [SavedServer]] = [:]
        for s in servers {
            guard let sshPort = s.sshPort else { continue }
            let key = SSHEndpoint(host: s.hostname, port: sshPort)
            groups[key, default: []].append(s)
        }

        let ssh = SSHSessionManager.shared

        for (endpoint, serversInGroup) in groups {
            guard let savedCred = try? SSHCredentialStore.shared.load(
                host: endpoint.host,
                port: Int(endpoint.port)
            ) else {
                NSLog("[RECONNECT] no saved credentials for %@:%d, skipping", endpoint.host, Int(endpoint.port))
                continue
            }

            guard let credentials = sshCredentials(from: savedCred) else {
                NSLog("[RECONNECT] incomplete saved credentials for %@:%d, skipping", endpoint.host, Int(endpoint.port))
                continue
            }

            do {
                try await ssh.connect(host: endpoint.host, port: Int(endpoint.port), credentials: credentials)
                NSLog("[RECONNECT] SSH connected to %@:%d", endpoint.host, Int(endpoint.port))
            } catch {
                NSLog("[RECONNECT] SSH connect failed for %@:%d — %@", endpoint.host, Int(endpoint.port), error.localizedDescription)
                continue
            }

            for s in serversInGroup {
                await reconnectSSHBackend(s, ssh: ssh)
            }

            // SSHSessionManager supports one connection at a time
            break
        }
    }

    private func reconnectSSHBackend(_ saved: SavedServer, ssh: SSHSessionManager) async {
        let server = saved.toDiscoveredServer()
        let backend: SSHSessionManager.AvailableBackend = server.backendHint == .claude ? .claude : .codex

        do {
            let wsPort = try await ssh.startRemoteServer(backend: backend)
            NSLog("[RECONNECT] %@ backend ready on port %d", backend.rawValue, Int(wsPort))

            var reconnected = DiscoveredServer(
                id: server.id,
                name: server.name,
                hostname: server.hostname,
                port: wsPort,
                source: server.source,
                hasCodexServer: true
            )
            reconnected.backendHint = server.backendHint
            reconnected.sshPort = server.sshPort

            await addServer(reconnected, target: .remote(host: server.hostname, port: wsPort))
        } catch {
            NSLog("[RECONNECT] %@ backend start failed — %@", backend.rawValue, error.localizedDescription)
        }
    }

    private func sshCredentials(from saved: SavedSSHCredential) -> SSHCredentials? {
        switch saved.method {
        case .password:
            guard let password = saved.password else { return nil }
            return .password(username: saved.username, password: password)
        case .key:
            guard let privateKey = saved.privateKey else { return nil }
            return .key(username: saved.username, privateKey: privateKey, passphrase: saved.passphrase)
        }
    }

    // MARK: - Thread Lifecycle

    func startThread(serverId: String, cwd: String, model: String? = nil) async -> ThreadKey? {
        guard let conn = connections[serverId] else { return nil }
        do {
            let resp = try await conn.startThread(cwd: cwd, model: model)
            let threadId = resp.thread.id
            let key = ThreadKey(serverId: serverId, threadId: threadId)
            let state = ThreadState(
                serverId: serverId,
                threadId: threadId,
                serverName: conn.server.name,
                serverSource: conn.server.source
            )
            state.cwd = cwd
            state.modelProvider = Self.providerFor(conn.serverType)
            state.updatedAt = Date()
            threads[key] = state
            observeThread(state)
            activeThreadKey = key
            return key
        } catch {
            return nil
        }
    }

    func resumeThread(serverId: String, threadId: String, cwd: String) async -> Bool {
        guard let conn = connections[serverId] else { return false }
        let key = ThreadKey(serverId: serverId, threadId: threadId)
        let state = threads[key] ?? ThreadState(
            serverId: serverId,
            threadId: threadId,
            serverName: conn.server.name,
            serverSource: conn.server.source
        )
        state.status = .connecting
        threads[key] = state
        observeThread(state)
        do {
            let resp = try await conn.resumeThread(threadId: threadId, cwd: cwd)
            state.messages = restoredMessages(from: resp.thread.turns)
            state.cwd = cwd
            state.modelProvider = Self.providerFor(conn.serverType)
            state.status = .ready
            state.updatedAt = Date()
            activeThreadKey = key
            return true
        } catch {
            state.status = .error(error.localizedDescription)
            return false
        }
    }

    func viewThread(_ key: ThreadKey) async {
        if threads[key]?.messages.isEmpty == true {
            let cwd = threads[key]?.cwd ?? "/tmp"
            _ = await resumeThread(serverId: key.serverId, threadId: key.threadId, cwd: cwd)
        } else {
            activeThreadKey = key
        }
    }

    // MARK: - Send / Interrupt

    func send(_ text: String, cwd: String, model: String? = nil, effort: String? = nil) async {
        var key = activeThreadKey
        if key == nil {
            if let serverId = connections.values.first(where: { $0.isConnected })?.id {
                key = await startThread(serverId: serverId, cwd: cwd, model: model)
            }
        }
        guard let key, let thread = threads[key], let conn = connections[key.serverId] else { return }
        thread.messages.append(ChatMessage(role: .user, text: text))
        thread.status = .thinking
        thread.updatedAt = Date()
        do {
            try await conn.sendTurn(threadId: key.threadId, text: text, model: model, effort: effort)
        } catch {
            thread.status = .error(error.localizedDescription)
        }
    }

    func interrupt() async {
        guard let key = activeThreadKey, let conn = connections[key.serverId] else { return }
        await conn.interrupt(threadId: key.threadId)
        threads[key]?.status = .ready
    }

    // MARK: - Session Refresh

    func refreshAllSessions() async {
        await withTaskGroup(of: Void.self) { group in
            for serverId in connections.keys {
                group.addTask { @MainActor in
                    await self.refreshSessions(for: serverId)
                }
            }
        }
    }

    func refreshSessions(for serverId: String) async {
        guard let conn = connections[serverId], conn.isConnected else { return }
        do {
            let resp = try await conn.listThreads()
            for summary in resp.data {
                let key = ThreadKey(serverId: serverId, threadId: summary.id)
                if let existing = threads[key] {
                    existing.preview = summary.preview
                    existing.cwd = summary.cwd
                    existing.modelProvider = summary.modelProvider
                    existing.updatedAt = Date(timeIntervalSince1970: TimeInterval(summary.updatedAt))
                } else {
                    let state = ThreadState(
                        serverId: serverId,
                        threadId: summary.id,
                        serverName: conn.server.name,
                        serverSource: conn.server.source
                    )
                    state.preview = summary.preview
                    state.cwd = summary.cwd
                    state.modelProvider = summary.modelProvider
                    state.updatedAt = Date(timeIntervalSince1970: TimeInterval(summary.updatedAt))
                    threads[key] = state
                    observeThread(state)
                }
            }
        } catch {}
    }

    // MARK: - Notification Routing

    func handleNotification(serverId: String, method: String, data: Data) {
        switch method {
        case "account/login/completed", "account/updated":
            connections[serverId]?.handleAccountNotification(method: method, data: data)

        case "turn/started":
            if let threadId = extractThreadId(from: data) {
                let key = ThreadKey(serverId: serverId, threadId: threadId)
                threads[key]?.status = .thinking
            }

        case "item/agentMessage/delta":
            struct DeltaParams: Decodable { let delta: String; let threadId: String? }
            struct DeltaNotif: Decodable { let params: DeltaParams }
            guard let notif = try? JSONDecoder().decode(DeltaNotif.self, from: data),
                  !notif.params.delta.isEmpty else { return }
            let key = resolveThreadKey(serverId: serverId, threadId: notif.params.threadId)
            guard let thread = threads[key] else { return }
            if let last = thread.messages.last, last.role == .assistant {
                thread.messages[thread.messages.count - 1].text += notif.params.delta
            } else {
                thread.messages.append(ChatMessage(role: .assistant, text: notif.params.delta))
            }
            thread.updatedAt = Date()

        case "turn/completed", "codex/event/task_complete":
            if let threadId = extractThreadId(from: data) {
                let key = ThreadKey(serverId: serverId, threadId: threadId)
                threads[key]?.status = .ready
                threads[key]?.updatedAt = Date()
            } else {
                // Fallback: mark any thinking thread on this server as ready
                for (_, thread) in threads where thread.serverId == serverId && thread.hasTurnActive {
                    thread.status = .ready
                    thread.updatedAt = Date()
                }
            }

        default:
            if method.hasPrefix("item/") {
                handleItemNotification(serverId: serverId, method: method, data: data)
            }
        }
    }

    private func handleItemNotification(serverId: String, method: String, data: Data) {
        // Format: item/started or item/completed → params.item has the ThreadItem with "type"
        //         item/agentMessage/delta etc. → streaming deltas, skip (agentMessage/delta handled above)
        struct ItemNotification: Decodable { let params: AnyCodable? }
        guard let raw = try? JSONDecoder().decode(ItemNotification.self, from: data),
              let paramsDict = raw.params?.value as? [String: Any] else { return }

        let threadId = paramsDict["threadId"] as? String

        // Only show completed items — started has incomplete data and would duplicate
        guard method == "item/completed" else { return }
        guard let itemDict = paramsDict["item"] as? [String: Any] else { return }

        // agentMessage is streamed via delta; userMessage is added locally in send()
        if let itemType = itemDict["type"] as? String,
           itemType == "agentMessage" || itemType == "userMessage" { return }

        guard let itemData = try? JSONSerialization.data(withJSONObject: itemDict),
              let item = try? JSONDecoder().decode(ResumedThreadItem.self, from: itemData),
              let msg = chatMessage(from: item) else { return }
        let key = resolveThreadKey(serverId: serverId, threadId: threadId)
        guard let thread = threads[key] else { return }
        thread.messages.append(msg)
        thread.updatedAt = Date()
    }

    private func extractThreadId(from data: Data) -> String? {
        struct Wrapper: Decodable {
            struct Params: Decodable { let threadId: String? }
            let params: Params?
        }
        return (try? JSONDecoder().decode(Wrapper.self, from: data))?.params?.threadId
    }

    private func resolveThreadKey(serverId: String, threadId: String?) -> ThreadKey {
        if let threadId {
            return ThreadKey(serverId: serverId, threadId: threadId)
        }
        return threads.values
            .first { $0.serverId == serverId && $0.hasTurnActive }?
            .key ?? ThreadKey(serverId: serverId, threadId: "")
    }

    static func providerFor(_ serverType: ServerConnection.ServerType) -> String {
        switch serverType {
        case .claude: return "anthropic"
        case .codex: return "openai"
        case .unknown: return ""
        }
    }

    // MARK: - MCP Servers

    func refreshMcpServers() async {
        var all: [McpServerStatus] = []
        var results = backendResults
        for conn in connections.values where conn.isConnected {
            let label = conn.serverType.displayName
            if !results.contains(where: { $0.id == conn.id }) {
                results.append(BackendFetchResult(id: conn.id, provider: label))
            }
            let idx = results.firstIndex(where: { $0.id == conn.id })!
            do {
                let resp = try await conn.listMcpServers()
                let tagged = resp.data.map { server -> McpServerStatus in
                    var s = server
                    s.provider = label
                    s.serverId = conn.id
                    return s
                }
                all.append(contentsOf: tagged)
                results[idx].mcpCount = tagged.count
                results[idx].mcpError = nil
                results[idx].mcpUnsupported = false
            } catch let rpcError {
                if conn.serverType == .claude {
                    // Backward compatibility for older claude-app-server versions.
                    do {
                        let servers = try await fetchClaudeMcpServers(connection: conn)
                        all.append(contentsOf: servers)
                        results[idx].mcpCount = servers.count
                        results[idx].mcpError = nil
                        results[idx].mcpUnsupported = false
                    } catch let fallbackError {
                        results[idx].mcpCount = 0
                        if isMethodUnsupported(rpcError) {
                            results[idx].mcpUnsupported = true
                            results[idx].mcpError = nil
                        } else {
                            results[idx].mcpUnsupported = false
                            results[idx].mcpError = fallbackError.localizedDescription
                        }
                        NSLog("[SERVER_MANAGER] refreshMcpServers failed for %@: %@", conn.id, fallbackError.localizedDescription)
                    }
                } else {
                    results[idx].mcpCount = 0
                    results[idx].mcpUnsupported = false
                    results[idx].mcpError = rpcError.localizedDescription
                    NSLog("[SERVER_MANAGER] refreshMcpServers failed for %@: %@", conn.id, rpcError.localizedDescription)
                }
            }
        }
        mcpServers = all.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        backendResults = results
        mcpServersLoaded = true
    }

    private func isMethodUnsupported(_ error: Error) -> Bool {
        guard case let JSONRPCClientError.serverError(code, message) = error else {
            return false
        }
        let lower = message.lowercased()
        return code == -32601 || lower.contains("method not found") || lower.contains("not supported")
    }

    func mcpOauthLogin(serverName: String, serverId: String) async -> URL? {
        guard let conn = connections[serverId], conn.isConnected else { return nil }
        do {
            let resp = try await conn.mcpOauthLogin(serverName: serverName)
            guard !resp.authorizationUrl.isEmpty else { return nil }
            return URL(string: resp.authorizationUrl)
        } catch {
            NSLog("[SERVER_MANAGER] mcpOauthLogin failed: %@", error.localizedDescription)
            return nil
        }
    }

    func reloadMcpServers() async {
        for conn in connections.values where conn.isConnected {
            do {
                try await conn.reloadMcpServers()
            } catch {
                NSLog("[SERVER_MANAGER] reloadMcpServers failed for %@: %@", conn.id, error.localizedDescription)
            }
        }
        await refreshMcpServers()
    }

    // MARK: - Skills

    func refreshSkills() async {
        var all: [SkillMetadata] = []
        var results = backendResults
        for conn in connections.values where conn.isConnected {
            let label = conn.serverType.displayName
            let cwds = skillLookupCwds(for: conn.id)
            if !results.contains(where: { $0.id == conn.id }) {
                results.append(BackendFetchResult(id: conn.id, provider: label))
            }
            let idx = results.firstIndex(where: { $0.id == conn.id })!
            do {
                let resp = try await conn.listSkills(cwds: cwds.isEmpty ? nil : cwds)
                var rpcSkills: [SkillMetadata] = []
                var seenSkillKeys = Set<String>()
                for entry in resp.data {
                    for skill in entry.skills {
                        var tagged = skill
                        tagged.provider = label
                        tagged.serverId = conn.id
                        if seenSkillKeys.insert(skillIdentityKey(tagged)).inserted {
                            rpcSkills.append(tagged)
                        }
                    }
                }

                var merged = rpcSkills
                if conn.serverType == .claude {
                    // Claude bridge support for skills can vary by version/config; merge with file scan.
                    do {
                        let fallbackSkills = try await fetchClaudeSkills(connection: conn, cwds: cwds)
                        merged = mergeSkills(primary: rpcSkills, supplemental: fallbackSkills)
                    } catch {
                        if rpcSkills.isEmpty {
                            NSLog("[SERVER_MANAGER] Claude skills fallback failed for %@: %@", conn.id, error.localizedDescription)
                        }
                    }
                }

                all.append(contentsOf: merged)
                results[idx].skillsCount = merged.count
                results[idx].skillsError = nil
                results[idx].skillsUnsupported = false
            } catch let rpcError {
                if conn.serverType == .claude {
                    // Backward compatibility for older claude-app-server versions.
                    do {
                        let skills = try await fetchClaudeSkills(connection: conn, cwds: cwds)
                        let deduped = dedupeSkills(skills)
                        all.append(contentsOf: deduped)
                        results[idx].skillsCount = deduped.count
                        results[idx].skillsError = nil
                        results[idx].skillsUnsupported = false
                    } catch let fallbackError {
                        results[idx].skillsCount = 0
                        if isMethodUnsupported(rpcError) {
                            results[idx].skillsUnsupported = true
                            results[idx].skillsError = nil
                        } else {
                            results[idx].skillsUnsupported = false
                            results[idx].skillsError = fallbackError.localizedDescription
                        }
                        NSLog("[SERVER_MANAGER] refreshSkills failed for %@: %@", conn.id, fallbackError.localizedDescription)
                    }
                } else {
                    results[idx].skillsCount = 0
                    results[idx].skillsUnsupported = false
                    results[idx].skillsError = rpcError.localizedDescription
                    NSLog("[SERVER_MANAGER] refreshSkills failed for %@: %@", conn.id, rpcError.localizedDescription)
                }
            }
        }
        let dedupedAll = dedupeSkills(all)
        skills = dedupedAll.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        backendResults = results
        skillsLoaded = true
    }

    private func skillIdentityKey(_ skill: SkillMetadata) -> String {
        let path = skill.path.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !path.isEmpty {
            return "\(skill.serverId):path:\(path)"
        }
        let display = skill.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !display.isEmpty {
            return "\(skill.serverId):name:\(display)"
        }
        let summary = skill.summary.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(skill.serverId):scope:\(skill.scope.rawValue):\(summary)"
    }

    private func dedupeSkills(_ input: [SkillMetadata]) -> [SkillMetadata] {
        var seen = Set<String>()
        var output: [SkillMetadata] = []
        output.reserveCapacity(input.count)
        for skill in input {
            if seen.insert(skillIdentityKey(skill)).inserted {
                output.append(skill)
            }
        }
        return output
    }

    private func mergeSkills(primary: [SkillMetadata], supplemental: [SkillMetadata]) -> [SkillMetadata] {
        dedupeSkills(primary + supplemental)
    }

    private func skillLookupCwds(for serverId: String) -> [String] {
        var seen = Set<String>()
        var cwds: [String] = []
        for thread in threads.values where thread.serverId == serverId {
            let cwd = thread.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cwd.isEmpty else { continue }
            if seen.insert(cwd).inserted {
                cwds.append(cwd)
            }
        }
        return cwds
    }

    // MARK: - Claude Config via SSH

    /// Read MCP servers from Claude's ~/.claude.json and .mcp.json on the remote machine.
    private func fetchClaudeMcpServers(connection conn: ServerConnection) async throws -> [McpServerStatus] {
        let script = """
        cat ~/.claude.json 2>/dev/null || echo '{}'
        echo '---MCP_SEPARATOR---'
        cat .mcp.json 2>/dev/null || echo '{}'
        """
        let output = try await executeClaudeScript(script, connection: conn)
        let parts = output.components(separatedBy: "---MCP_SEPARATOR---")
        var servers: [McpServerStatus] = []
        for jsonStr in parts {
            let trimmed = jsonStr.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let mcpServers = root["mcpServers"] as? [String: Any] else { continue }
            for (name, _) in mcpServers {
                servers.append(McpServerStatus.claudeStub(
                    name: name,
                    provider: "Claude",
                    serverId: conn.id
                ))
            }
        }
        return servers
    }

    /// Read skills from Claude's ~/.claude/* and repo-local .claude/* folders.
    private func fetchClaudeSkills(connection conn: ServerConnection, cwds: [String]) async throws -> [SkillMetadata] {
        // Output format per file: FILE_PATH\n<frontmatter>\n---END_SKILL---
        let script = """
        roots_tmp="$(mktemp -t mocode-skills-roots.XXXXXX 2>/dev/null || echo /tmp/mocode-skills-roots.$$)"
        files_tmp="$(mktemp -t mocode-skills-files.XXXXXX 2>/dev/null || echo /tmp/mocode-skills-files.$$)"
        trap 'rm -f "$roots_tmp" "$files_tmp"' EXIT

        for base in \
          ~/.claude/skills \
          ~/.claude/commands \
          "$HOME/.claude/skills" \
          "$HOME/.claude/commands" \
          .claude/skills \
          .claude/commands
        do
          [ -d "$base" ] && printf '%s\n' "$base" >>"$roots_tmp"
        done

        plugins_file="$HOME/.claude/plugins/installed_plugins.json"
        if [ -f "$plugins_file" ]; then
          sed -n 's/.*"installPath"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' "$plugins_file" | while IFS= read -r install_path; do
            [ -d "$install_path/skills" ] && printf '%s\n' "$install_path/skills" >>"$roots_tmp"
          done
        fi

        dir="$PWD"
        while [ -n "$dir" ] && [ "$dir" != "/" ]; do
          [ -d "$dir/.claude/skills" ] && printf '%s\n' "$dir/.claude/skills" >>"$roots_tmp"
          [ -d "$dir/.claude/commands" ] && printf '%s\n' "$dir/.claude/commands" >>"$roots_tmp"
          next="$(dirname "$dir")"
          [ "$next" = "$dir" ] && break
          dir="$next"
        done

        sort -u "$roots_tmp" 2>/dev/null | while IFS= read -r base; do
          [ -d "$base" ] || continue
          case "$base" in
            */commands)
              find -L "$base" -type f -name "*.md" 2>/dev/null
              ;;
            *)
              find -L "$base" -type f \\( -name "SKILL.md" -o -name "skill.md" \\) 2>/dev/null
              ;;
          esac
        done | sort -u >"$files_tmp"

        while IFS= read -r f; do
          [ -f "$f" ] || continue
          echo "FILE_PATH:$f"
          awk '/^---$/{n++; if(n==2) exit; next} n==1{print}' "$f" 2>/dev/null
          echo "---END_SKILL---"
        done <"$files_tmp"
        """
        let executionCwds = cwds.isEmpty ? [nil] : cwds.map { Optional($0) }
        var blocks: [String] = []
        for cwd in executionCwds {
            let output = try await executeClaudeScript(script, connection: conn, cwd: cwd)
            blocks.append(contentsOf: output.components(separatedBy: "---END_SKILL---"))
        }

        var seenPaths = Set<String>()
        var skills: [SkillMetadata] = []
        for block in blocks {
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let lines = trimmed.components(separatedBy: "\n")
            guard let pathLine = lines.first, pathLine.hasPrefix("FILE_PATH:") else { continue }
            let path = String(pathLine.dropFirst("FILE_PATH:".count))
            if !seenPaths.insert(path).inserted { continue }
            let frontmatter = lines.dropFirst().joined(separator: "\n")
            let meta = parseSkillFrontmatter(frontmatter, path: path, connId: conn.id)
            skills.append(meta)
        }
        return skills
    }

    private func executeClaudeScript(_ script: String, connection conn: ServerConnection, cwd: String? = nil) async throws -> String {
        do {
            let response = try await conn.execCommand(["sh", "-lc", script], cwd: cwd)
            if response.exitCode == 0 {
                return response.stdout
            }
            if !response.stderr.isEmpty {
                throw NSError(domain: "ClaudeScript", code: Int(response.exitCode), userInfo: [
                    NSLocalizedDescriptionKey: response.stderr
                ])
            }
            throw NSError(domain: "ClaudeScript", code: Int(response.exitCode), userInfo: [
                NSLocalizedDescriptionKey: "Remote script failed with exit code \(response.exitCode)"
            ])
        } catch {
            // Final fallback path for sessions created via SSH.
            return try await SSHSessionManager.shared.executeCommand(script)
        }
    }

    /// Parse simple YAML frontmatter key: value pairs from a skill file.
    private func parseSkillFrontmatter(_ yaml: String, path: String, connId: String) -> SkillMetadata {
        var fields: [String: String] = [:]
        for line in yaml.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let colonIdx = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colonIdx]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty && !value.isEmpty { fields[key] = value }
        }
        // Derive name from frontmatter or directory/file name
        let name: String
        if let fm = fields["name"], !fm.isEmpty {
            name = fm
        } else {
            let url = URL(fileURLWithPath: path)
            if url.lastPathComponent == "SKILL.md" {
                name = url.deletingLastPathComponent().lastPathComponent
            } else {
                name = url.deletingPathExtension().lastPathComponent
            }
        }
        return SkillMetadata.claudeStub(
            name: name,
            description: fields["description"] ?? "",
            path: path,
            provider: "Claude",
            serverId: connId,
            userInvocable: fields["user-invocable"] != "false",
            disableModelInvocation: fields["disable-model-invocation"] == "true"
        )
    }

    // MARK: - Persistence

    func saveServerList() {
        let saved = connections.values.map { SavedServer.from($0.server) }
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: savedServersKey)
        }
    }

    func loadSavedServers() -> [SavedServer] {
        guard let data = UserDefaults.standard.data(forKey: savedServersKey) else { return [] }
        return (try? JSONDecoder().decode([SavedServer].self, from: data)) ?? []
    }

    // MARK: - Message Restoration

    func restoredMessages(from turns: [ResumedTurn]) -> [ChatMessage] {
        var restored: [ChatMessage] = []
        restored.reserveCapacity(turns.count * 3)
        for turn in turns {
            for item in turn.items {
                if let msg = chatMessage(from: item) {
                    restored.append(msg)
                }
            }
        }
        return restored
    }

    private func chatMessage(from item: ResumedThreadItem) -> ChatMessage? {
        switch item {
        case .userMessage(let content):
            let (text, images) = renderUserInput(content)
            if text.isEmpty && images.isEmpty { return nil }
            return ChatMessage(role: .user, text: text, images: images)
        case .agentMessage(let text, _):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            return ChatMessage(role: .assistant, text: trimmed)
        case .plan(let text):
            return systemMessage(title: "Plan", body: text.trimmingCharacters(in: .whitespacesAndNewlines))
        case .reasoning(let summary, let content):
            let summaryText = summary
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            let detailText = content
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            var sections: [String] = []
            if !summaryText.isEmpty { sections.append(summaryText) }
            if !detailText.isEmpty { sections.append(detailText) }
            return systemMessage(title: "Reasoning", body: sections.joined(separator: "\n\n"))
        case .commandExecution(let command, let cwd, let status, let output, let exitCode, let durationMs):
            var lines: [String] = ["Status: \(status)"]
            if !cwd.isEmpty { lines.append("Directory: \(cwd)") }
            if let exitCode { lines.append("Exit code: \(exitCode)") }
            if let durationMs { lines.append("Duration: \(durationMs) ms") }
            var body = lines.joined(separator: "\n")
            if !command.isEmpty { body += "\n\nCommand:\n```bash\n\(command)\n```" }
            if let output {
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { body += "\n\nOutput:\n```text\n\(trimmed)\n```" }
            }
            return systemMessage(title: "Command Execution", body: body)
        case .fileChange(let changes, let status):
            if changes.isEmpty {
                return systemMessage(title: "File Change", body: "Status: \(status)")
            }
            var parts: [String] = []
            for change in changes {
                var body = "Path: \(change.path)\nKind: \(change.kind)"
                let diff = change.diff.trimmingCharacters(in: .whitespacesAndNewlines)
                if !diff.isEmpty { body += "\n\n```diff\n\(diff)\n```" }
                parts.append(body)
            }
            return systemMessage(title: "File Change", body: "Status: \(status)\n\n" + parts.joined(separator: "\n\n---\n\n"))
        case .mcpToolCall(let server, let tool, let status, let result, let error, let durationMs):
            var lines: [String] = ["Status: \(status)"]
            if !server.isEmpty || !tool.isEmpty {
                lines.append("Tool: \(server.isEmpty ? tool : "\(server)/\(tool)")")
            }
            if let durationMs { lines.append("Duration: \(durationMs) ms") }
            if let errorMessage = error?.message, !errorMessage.isEmpty {
                lines.append("Error: \(errorMessage)")
            }
            var body = lines.joined(separator: "\n")
            if let result {
                let resultObject: [String: Any] = [
                    "content": result.content.map { $0.value },
                    "structuredContent": result.structuredContent?.value ?? NSNull()
                ]
                if let pretty = prettyJSON(resultObject) {
                    body += "\n\nResult:\n```json\n\(pretty)\n```"
                }
            }
            return systemMessage(title: "MCP Tool Call", body: body)
        case .collabAgentToolCall(let tool, let status, let receiverThreadIds, let prompt):
            var lines: [String] = ["Status: \(status)", "Tool: \(tool)"]
            if !receiverThreadIds.isEmpty {
                lines.append("Targets: \(receiverThreadIds.joined(separator: ", "))")
            }
            if let prompt {
                let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    lines.append("")
                    lines.append("Prompt:")
                    lines.append(trimmed)
                }
            }
            return systemMessage(title: "Collaboration", body: lines.joined(separator: "\n"))
        case .webSearch(let query, let action):
            var lines: [String] = []
            if !query.isEmpty { lines.append("Query: \(query)") }
            if let action, let pretty = prettyJSON(action.value) {
                lines.append("")
                lines.append("Action:")
                lines.append("```json\n\(pretty)\n```")
            }
            return systemMessage(title: "Web Search", body: lines.joined(separator: "\n"))
        case .imageView(let path):
            return systemMessage(title: "Image View", body: "Path: \(path)")
        case .enteredReviewMode(let review):
            return systemMessage(title: "Review Mode", body: "Entered review: \(review)")
        case .exitedReviewMode(let review):
            return systemMessage(title: "Review Mode", body: "Exited review: \(review)")
        case .contextCompaction:
            return systemMessage(title: "Context", body: "Context compaction occurred.")
        case .unknown(let type):
            return systemMessage(title: "Event", body: "Unhandled item type: \(type)")
        case .ignored:
            return nil
        }
    }

    private func systemMessage(title: String, body: String) -> ChatMessage? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return ChatMessage(role: .system, text: "### \(title)\n\(trimmed)")
    }

    private func renderUserInput(_ content: [ResumedUserInput]) -> (String, [ChatImage]) {
        var textParts: [String] = []
        var images: [ChatImage] = []
        for input in content {
            switch input.type {
            case "text":
                let trimmed = input.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !trimmed.isEmpty { textParts.append(trimmed) }
            case "image":
                if let url = input.url, let imageData = decodeBase64DataURI(url) {
                    images.append(ChatImage(data: imageData))
                }
            case "localImage":
                if let path = input.path, let data = FileManager.default.contents(atPath: path) {
                    images.append(ChatImage(data: data))
                }
            case "skill":
                let name = (input.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let path = (input.path ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty && !path.isEmpty { textParts.append("[Skill] \(name) (\(path))") }
                else if !name.isEmpty { textParts.append("[Skill] \(name)") }
                else if !path.isEmpty { textParts.append("[Skill] \(path)") }
            case "mention":
                let name = (input.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let path = (input.path ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty && !path.isEmpty { textParts.append("[Mention] \(name) (\(path))") }
                else if !name.isEmpty { textParts.append("[Mention] \(name)") }
                else if !path.isEmpty { textParts.append("[Mention] \(path)") }
            default:
                break
            }
        }
        return (textParts.joined(separator: "\n"), images)
    }

    private func decodeBase64DataURI(_ uri: String) -> Data? {
        guard uri.hasPrefix("data:") else { return nil }
        guard let commaIndex = uri.firstIndex(of: ",") else { return nil }
        let base64 = String(uri[uri.index(after: commaIndex)...])
        return Data(base64Encoded: base64, options: .ignoreUnknownCharacters)
    }

    private func prettyJSON(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              var text = String(data: data, encoding: .utf8) else {
            return nil
        }
        if text.hasSuffix("\n") { text.removeLast() }
        return text
    }
}
