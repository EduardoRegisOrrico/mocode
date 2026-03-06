import Foundation

@MainActor
final class ServerConnection: ObservableObject, Identifiable {
    enum ServerType {
        case codex
        case claude
        case unknown

        var displayName: String {
            switch self {
            case .codex: return "Codex"
            case .claude: return "Claude"
            case .unknown: return "Unknown"
            }
        }
    }

    let id: String
    let server: DiscoveredServer
    let target: ConnectionTarget

    @Published var isConnected = false
    @Published var connectionPhase: String = ""
    @Published var authStatus: AuthStatus = .unknown
    @Published var oauthURL: URL? = nil
    @Published var loginCompleted = false
    @Published var models: [CodexModel] = []
    @Published var modelsLoaded = false
    @Published var serverType: ServerType = .unknown

    let client = JSONRPCClient()
    private var serverURL: URL?
    private var pendingLoginId: String?

    var onNotification: ((String, Data) -> Void)?
    var onDisconnect: (() -> Void)?

    init(server: DiscoveredServer, target: ConnectionTarget) {
        self.id = server.id
        self.server = server
        self.target = target
        if server.backendHint != .unknown {
            self.serverType = server.backendHint
        }
    }

    private struct ConnectionRetryPolicy {
        let maxAttempts: Int
        let retryDelay: Duration
        let initializeTimeout: Duration
        let attemptTimeout: Duration
    }

    func connect() async {
        guard !isConnected else { return }
        connectionPhase = "start"
        await DebugLog.shared.log("connect start serverId=\(server.id) host=\(server.hostname) target=\(String(describing: target)) hint=\(server.backendHint.displayName)")
        do {
            switch target {
            case .local:
                guard OnDeviceCodexFeature.isEnabled else {
                    connectionPhase = OnDeviceCodexFeature.compiledIn ? "local-disabled" : "local-unavailable"
                    return
                }
                connectionPhase = "local-starting"
                let port = try await CodexBridge.shared.ensureStarted()
                serverURL = URL(string: "ws://127.0.0.1:\(port)")!
                connectionPhase = "local-url"
            case .remote(let host, let port):
                guard let url = websocketURL(host: host, port: port) else {
                    connectionPhase = "invalid-url"
                    return
                }
                serverURL = url
                connectionPhase = "remote-url"
            case .sshThenRemote:
                connectionPhase = "sshThenRemote-not-supported"
                return
            }
            guard serverURL != nil else {
                connectionPhase = "no-url"
                return
            }
            connectionPhase = "setup-notifications"
            await setupNotifications()
            await setupDisconnectHandler()
            connectionPhase = "connect-and-initialize"
            try await connectAndInitialize()
            isConnected = true
            connectionPhase = "ready"
            NSLog("[SERVER_CONNECTION] connected %@ (%@)", server.id, serverType.displayName)
            await DebugLog.shared.log("connect ready serverId=\(server.id) serverType=\(serverType.displayName) url=\(serverURL?.absoluteString ?? "nil")")
            Task { [weak self] in
                await self?.checkAuth()
            }
        } catch {
            connectionPhase = "error: \(error.localizedDescription)"
            NSLog("[SERVER_CONNECTION] connect failed %@: %@", server.id, error.localizedDescription)
            await DebugLog.shared.log("connect failed serverId=\(server.id) error=\(error.localizedDescription)")
        }
    }

    func disconnect() {
        Task { await client.disconnect() }
        isConnected = false
        serverURL = nil
        if server.backendHint == .unknown {
            serverType = .unknown
        }
    }

    // MARK: - RPC Methods

    func listThreads(cwd: String? = nil, cursor: String? = nil, limit: Int? = 20) async throws -> ThreadListResponse {
        let sourceKinds: [String]?
        switch serverType {
        case .codex:
            sourceKinds = ["cli", "vscode", "appServer"]
        case .claude, .unknown:
            sourceKinds = nil
        }
        await DebugLog.shared.log("thread/list serverId=\(server.id) serverType=\(serverType.displayName) cwd=\(cwd ?? "nil") cursor=\(cursor ?? "nil") sourceKinds=\(sourceKinds?.joined(separator: ",") ?? "nil")")

        return try await client.sendRequest(
            method: "thread/list",
            params: ThreadListParams(
                cursor: cursor,
                limit: limit,
                sortKey: "updated_at",
                sourceKinds: sourceKinds,
                cwd: cwd
            ),
            responseType: ThreadListResponse.self
        )
    }

    func startThread(
        cwd: String,
        model: String? = nil,
        approvalPolicy: String? = nil,
        sandboxMode: String? = nil
    ) async throws -> ThreadStartResponse {
        try await startThread(
            cwd: cwd,
            model: model,
            approvalPolicy: approvalPolicy,
            sandbox: sandboxMode
        )
    }

    func resumeThread(
        threadId: String,
        cwd: String,
        approvalPolicy: String? = nil,
        sandboxMode: String? = nil
    ) async throws -> ThreadResumeResponse {
        try await resumeThread(
            threadId: threadId,
            cwd: cwd,
            approvalPolicy: approvalPolicy,
            sandbox: sandboxMode
        )
    }

    /// Lightweight state refresh that avoids mutating execution policy defaults.
    func syncThreadState(
        threadId: String,
        cwd: String?
    ) async throws -> ThreadResumeResponse {
        try await client.sendRequest(
            method: "thread/resume",
            params: ThreadResumeParams(threadId: threadId, cwd: cwd, approvalPolicy: nil, sandbox: nil),
            responseType: ThreadResumeResponse.self
        )
    }

    func forkThread(
        threadId: String,
        cwd: String? = nil,
        approvalPolicy: String? = nil,
        sandboxMode: String? = nil
    ) async throws -> ThreadForkResponse {
        try await forkThread(
            threadId: threadId,
            cwd: cwd,
            approvalPolicy: approvalPolicy,
            sandbox: sandboxMode
        )
    }

    private func startThread(
        cwd: String,
        model: String?,
        approvalPolicy: String?,
        sandbox: String?
    ) async throws -> ThreadStartResponse {
        try await client.sendRequest(
            method: "thread/start",
            params: ThreadStartParams(model: model, cwd: cwd, approvalPolicy: approvalPolicy, sandbox: sandbox),
            responseType: ThreadStartResponse.self
        )
    }

    private func resumeThread(
        threadId: String,
        cwd: String,
        approvalPolicy: String?,
        sandbox: String?
    ) async throws -> ThreadResumeResponse {
        try await client.sendRequest(
            method: "thread/resume",
            params: ThreadResumeParams(threadId: threadId, cwd: cwd, approvalPolicy: approvalPolicy, sandbox: sandbox),
            responseType: ThreadResumeResponse.self
        )
    }

    private func forkThread(
        threadId: String,
        cwd: String?,
        approvalPolicy: String?,
        sandbox: String?
    ) async throws -> ThreadForkResponse {
        try await client.sendRequest(
            method: "thread/fork",
            params: ThreadForkParams(threadId: threadId, cwd: cwd, approvalPolicy: approvalPolicy, sandbox: sandbox),
            responseType: ThreadForkResponse.self
        )
    }

    func sendTurn(
        threadId: String,
        text: String,
        model: String? = nil,
        effort: String? = nil,
        additionalInput: [UserInput] = []
    ) async throws {
        var inputs: [UserInput] = [UserInput(type: "text", text: text)]
        inputs.append(contentsOf: additionalInput)
        let _: TurnStartResponse = try await client.sendRequest(
            method: "turn/start",
            params: TurnStartParams(threadId: threadId, input: inputs, model: model, effort: effort),
            responseType: TurnStartResponse.self
        )
    }

    func interrupt(threadId: String) async {
        struct Empty: Decodable {}
        _ = try? await client.sendRequest(
            method: "turn/interrupt",
            params: TurnInterruptParams(threadId: threadId),
            responseType: Empty.self
        )
    }

    func rollbackThread(threadId: String, numTurns: Int) async throws -> ThreadRollbackResponse {
        try await client.sendRequest(
            method: "thread/rollback",
            params: ThreadRollbackParams(threadId: threadId, numTurns: numTurns),
            responseType: ThreadRollbackResponse.self
        )
    }

    func archiveThread(threadId: String) async throws {
        let _: ThreadArchiveResponse = try await client.sendRequest(
            method: "thread/archive",
            params: ThreadArchiveParams(threadId: threadId),
            responseType: ThreadArchiveResponse.self
        )
    }

    func listModels() async throws -> ModelListResponse {
        try await client.sendRequest(
            method: "model/list",
            params: ModelListParams(limit: 50, includeHidden: false),
            responseType: ModelListResponse.self
        )
    }

    func execCommand(_ command: [String], cwd: String? = nil, timeoutMs: Int? = nil) async throws -> CommandExecResponse {
        try await client.sendRequest(
            method: "command/exec",
            params: CommandExecParams(command: command, timeoutMs: timeoutMs, cwd: cwd),
            responseType: CommandExecResponse.self
        )
    }

    func fuzzyFileSearch(query: String, roots: [String], cancellationToken: String? = nil) async throws -> FuzzyFileSearchResponse {
        try await client.sendRequest(
            method: "fuzzyFileSearch",
            params: FuzzyFileSearchParams(query: query, roots: roots, cancellationToken: cancellationToken),
            responseType: FuzzyFileSearchResponse.self
        )
    }

    // MARK: - MCP Servers

    func listMcpServers() async throws -> McpServerStatusListResponse {
        try await client.sendRequest(
            method: "mcpServerStatus/list",
            params: McpServerStatusListParams(),
            responseType: McpServerStatusListResponse.self
        )
    }

    func mcpOauthLogin(serverName: String, scopes: [String]? = nil) async throws -> McpServerOauthLoginResponse {
        try await client.sendRequest(
            method: "mcpServer/oauth/login",
            params: McpServerOauthLoginParams(name: serverName, scopes: scopes),
            responseType: McpServerOauthLoginResponse.self
        )
    }

    func reloadMcpServers() async throws {
        let _: McpServerReloadResponse = try await client.sendRequest(
            method: "config/mcpServer/reload",
            params: McpServerReloadParams(),
            responseType: McpServerReloadResponse.self
        )
    }

    // MARK: - Skills

    func listSkills(cwds: [String]? = nil) async throws -> SkillsListResponse {
        try await client.sendRequest(
            method: "skills/list",
            params: SkillsListParams(cwds: cwds),
            responseType: SkillsListResponse.self
        )
    }

    // MARK: - Auth

    func checkAuth() async {
        do {
            let resp: GetAccountResponse = try await withThrowingTaskGroup(of: GetAccountResponse.self) { group in
                group.addTask {
                    try await self.client.sendRequest(
                        method: "account/read",
                        params: GetAccountParams(refreshToken: false),
                        responseType: GetAccountResponse.self
                    )
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(4))
                    throw URLError(.timedOut)
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
            if let account = resp.account {
                switch account.type {
                case "chatgpt": authStatus = .chatgpt(email: account.email ?? "")
                case "apiKey":  authStatus = .apiKey
                case "claude":  authStatus = .claude
                default:
                    if serverType == .claude {
                        authStatus = .notLoggedIn
                    } else {
                        authStatus = resp.requiresOpenaiAuth ? .notLoggedIn : .unknown
                    }
                }
            } else {
                if serverType == .claude {
                    authStatus = .notLoggedIn
                } else {
                    authStatus = resp.requiresOpenaiAuth ? .notLoggedIn : .unknown
                }
            }
        } catch {
            authStatus = .notLoggedIn
        }
    }

    func loginWithChatGPT() async {
        do {
            let resp: LoginStartResponse = try await client.sendRequest(
                method: "account/login/start",
                params: LoginStartChatGPTParams(),
                responseType: LoginStartResponse.self
            )
            guard resp.type == "chatgpt",
                  let urlStr = resp.authUrl,
                  let url = URL(string: urlStr) else { return }
            pendingLoginId = resp.loginId
            oauthURL = url
        } catch {}
    }

    func loginWithClaude(email: String? = nil) async {
        let trimmed = email?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEmail = (trimmed?.isEmpty == false) ? trimmed : nil
        do {
            let resp: LoginStartResponse = try await client.sendRequest(
                method: "account/login/start",
                params: LoginStartClaudeParams(email: normalizedEmail),
                responseType: LoginStartResponse.self
            )
            guard resp.type == "claude" else { return }
            pendingLoginId = resp.loginId
            if let urlStr = resp.authUrl, let url = URL(string: urlStr) {
                oauthURL = url
            } else {
                await checkAuth()
            }
        } catch {}
    }

    func loginWithApiKey(_ key: String) async {
        do {
            let _: LoginStartResponse = try await client.sendRequest(
                method: "account/login/start",
                params: LoginStartApiKeyParams(apiKey: key),
                responseType: LoginStartResponse.self
            )
            await checkAuth()
        } catch {}
    }

    func logout() async {
        struct Empty: Decodable {}
        struct EmptyParams: Encodable {}
        _ = try? await client.sendRequest(
            method: "account/logout",
            params: EmptyParams(),
            responseType: Empty.self
        )
        authStatus = .notLoggedIn
        oauthURL = nil
        pendingLoginId = nil
    }

    func cancelLogin() async {
        guard let loginId = pendingLoginId else { return }
        struct Empty: Decodable {}
        _ = try? await client.sendRequest(
            method: "account/login/cancel",
            params: CancelLoginParams(loginId: loginId),
            responseType: Empty.self
        )
        pendingLoginId = nil
        oauthURL = nil
    }

    // MARK: - Account Notifications

    func handleAccountNotification(method: String, data: Data) {
        switch method {
        case "account/login/completed":
            if let notif = try? JSONDecoder().decode(AccountLoginCompletedNotification.self, from: extractParams(data)),
               notif.success {
                oauthURL = nil
                pendingLoginId = nil
                loginCompleted = true
                Task { await self.checkAuth() }
            }
        case "account/updated":
            Task { await self.checkAuth() }
        default:
            break
        }
    }

    // MARK: - Connection Internals

    private func websocketURL(host: String, port: UInt16) -> URL? {
        var normalized = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        if !normalized.contains(":"), let pct = normalized.firstIndex(of: "%") {
            normalized = String(normalized[..<pct])
        }
        if normalized.contains(":") {
            let unbracketed = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            let escapedScope = unbracketed.replacingOccurrences(of: "%25", with: "%")
                .replacingOccurrences(of: "%", with: "%25")
            return URL(string: "ws://[\(escapedScope)]:\(port)")
        }
        return URL(string: "ws://\(normalized):\(port)")
    }

    private func connectAndInitialize() async throws {
        guard let url = serverURL else { throw URLError(.badURL) }
        let policy = retryPolicy()
        var lastError: Error = URLError(.cannotConnectToHost)
        for attempt in 0..<policy.maxAttempts {
            connectionPhase = "attempt \(attempt + 1)/\(policy.maxAttempts)"
            if attempt > 0 {
                try await Task.sleep(for: policy.retryDelay)
            }
            await client.disconnect()
            do {
                try await connectAndInitializeOnce(
                    url: url,
                    initializeTimeout: policy.initializeTimeout,
                    attemptTimeout: policy.attemptTimeout
                )
                return
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func retryPolicy() -> ConnectionRetryPolicy {
        switch target {
        case .remote:
            return ConnectionRetryPolicy(
                maxAttempts: 6,
                retryDelay: .milliseconds(500),
                initializeTimeout: .seconds(4),
                attemptTimeout: .seconds(6)
            )
        default:
            return ConnectionRetryPolicy(
                maxAttempts: 30,
                retryDelay: .milliseconds(800),
                initializeTimeout: .seconds(6),
                attemptTimeout: .seconds(12)
            )
        }
    }

    private func connectAndInitializeOnce(
        url: URL,
        initializeTimeout: Duration,
        attemptTimeout: Duration
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await MainActor.run { self.connectionPhase = "client-connect" }
                try await self.client.connect(url: url)
                await MainActor.run { self.connectionPhase = "initialize" }
                try await self.sendInitialize(timeout: initializeTimeout)
                await MainActor.run { self.connectionPhase = "initialized" }
            }
            group.addTask {
                try await Task.sleep(for: attemptTimeout)
                throw URLError(.timedOut)
            }
            _ = try await group.next()!
            group.cancelAll()
        }
    }

    private func sendInitialize(timeout: Duration) async throws {
        try await withThrowingTaskGroup(of: InitializeResponse.self) { group in
            group.addTask {
                try await self.client.sendRequest(
                    method: "initialize",
                    params: InitializeParams(clientInfo: .init(name: "Mocode", version: "1.0", title: nil)),
                    responseType: InitializeResponse.self
                )
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw URLError(.timedOut)
            }
            let response = try await group.next()!
            group.cancelAll()
            let userAgent = response.userAgent.lowercased()
            let detectedType: ServerType
            if userAgent.contains("claude-app-server") {
                detectedType = .claude
            } else if !userAgent.isEmpty {
                detectedType = .codex
            } else {
                detectedType = .unknown
            }
            await DebugLog.shared.log("initialize serverId=\(server.id) expected=\(server.backendHint.displayName) userAgent=\(response.userAgent) detected=\(detectedType.displayName)")

            // Always trust the actual server handshake over hints.
            if detectedType != .unknown {
                self.serverType = detectedType
            }

            let expectedType = self.server.backendHint
            if expectedType != .unknown,
               detectedType != .unknown,
               expectedType != detectedType {
                NSLog("[SERVER_CONNECTION] backend mismatch expected=%@ actual=%@", expectedType.displayName, detectedType.displayName)
                throw ServerConnectionError.backendMismatch(
                    expected: expectedType.displayName,
                    actual: detectedType.displayName
                )
            }
        }
    }

    private func setupDisconnectHandler() async {
        await client.setDisconnectHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isConnected else { return }
                self.isConnected = false
                self.onDisconnect?()
                do {
                    try await self.connectAndInitialize()
                    self.isConnected = true
                } catch {}
            }
        }
    }

    private func setupNotifications() async {
        await client.addNotificationHandler { [weak self] method, data in
            Task { @MainActor [weak self] in
                self?.onNotification?(method, data)
            }
        }
        await client.addRequestHandler { [weak self] id, method, data in
            Task { @MainActor [weak self] in
                self?.handleServerRequest(id: id, method: method)
            }
        }
    }

    private func handleServerRequest(id: String, method: String) {
        switch method {
        case "item/commandExecution/requestApproval",
             "item/fileChange/requestApproval":
            Task { await client.sendResult(id: id, result: ["decision": "accept"]) }
        default:
            Task { await client.sendResult(id: id, result: [:] as [String: String]) }
        }
    }

    private func extractParams(_ data: Data) -> Data {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let params = obj["params"] {
            return (try? JSONSerialization.data(withJSONObject: params)) ?? data
        }
        return data
    }
}

enum ServerConnectionError: LocalizedError {
    case backendMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .backendMismatch(let expected, let actual):
            return "Connected to \(actual) while \(expected) was selected. Reconnect and try again."
        }
    }
}
