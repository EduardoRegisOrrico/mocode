import Foundation
import Citadel
import Crypto

actor SSHSessionManager {
    static let shared = SSHSessionManager()
    private var client: SSHClient?
    private var connectedHost: String?
    private let defaultRemotePort: UInt16 = 8390

    enum AvailableBackend: String, Identifiable, CaseIterable {
        case codex
        case claude

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .codex: return "Codex"
            case .claude: return "Claude"
            }
        }

        var iconName: String {
            switch self {
            case .codex: return "chevron.left.forwardslash.chevron.right"
            case .claude: return "sparkles"
            }
        }

        var accentColor: String {
            switch self {
            case .codex: return "green"
            case .claude: return "orange"
            }
        }
    }

    private enum ServerLaunchCommand {
        case codex(executable: String)
        case codexAppServer(executable: String)
        case claude(executable: String)
        case claudeAppServer(executable: String)
    }

    var isConnected: Bool { client != nil }

    func connect(host: String, port: Int = 22, credentials: SSHCredentials) async throws {
        var normalizedHost = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .replacingOccurrences(of: "%25", with: "%")
        if !normalizedHost.contains(":"), let pct = normalizedHost.firstIndex(of: "%") {
            normalizedHost = String(normalizedHost[..<pct])
        }

        let auth: SSHAuthenticationMethod
        switch credentials {
        case .password(let username, let password):
            auth = .passwordBased(username: username, password: password)
        case .key(let username, let privateKeyPEM, let passphrase):
            let decryptionKey = passphrase?.data(using: .utf8)
            let keyType = try SSHKeyDetection.detectPrivateKeyType(from: privateKeyPEM)
            switch keyType {
            case .rsa:
                let key = try Insecure.RSA.PrivateKey(sshRsa: privateKeyPEM, decryptionKey: decryptionKey)
                auth = .rsa(username: username, privateKey: key)
            case .ed25519:
                let key = try Curve25519.Signing.PrivateKey(sshEd25519: privateKeyPEM, decryptionKey: decryptionKey)
                auth = .ed25519(username: username, privateKey: key)
            default:
                throw SSHError.unsupportedKeyType
            }
        }

        do {
            client = try await SSHClient.connect(
                host: normalizedHost,
                port: port,
                authenticationMethod: auth,
                hostKeyValidator: .acceptAnything(),
                reconnect: .never
            )
            connectedHost = normalizedHost
        } catch {
            let detail = SSHError.connectionErrorDetail(error)
            let lower = detail.lowercased()
            if lower.contains("permission denied") ||
                lower.contains("authentication") ||
                lower.contains("auth fail") ||
                lower.contains("publickey") {
                throw SSHError.authenticationFailed(detail: detail)
            }
            throw SSHError.connectionFailed(host: normalizedHost, port: port, underlying: error)
        }
    }

    func startRemoteServer() async throws -> UInt16 {
        guard let client else { throw SSHError.notConnected }
        let wantsIPv6 = (connectedHost ?? "").contains(":")

        guard let launchCommand = try await resolveServerLaunchCommand(client: client) else {
            throw SSHError.serverBinaryMissing
        }

        var lastFailure = "Timed out waiting for remote server to start."
        for port in candidatePorts() {
            let listenAddr = wantsIPv6 ? "[::]:\(port)" : "0.0.0.0:\(port)"
            let logPath = "/tmp/codex-ios-app-server-\(port).log"

            // Check if already running on this port
            if let listening = try? await isPortListening(client: client, port: port), listening {
                return port
            }

            // Start server in background on selected port.
            let launchOutput = String(
                buffer: try await client.executeCommand(
                    try startServerCommand(for: launchCommand, listenAddr: listenAddr, logPath: logPath)
                )
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let launchedPID = Int(launchOutput)

            // Poll until reachable.
            for attempt in 0..<60 {
                try await Task.sleep(for: .milliseconds(500))
                if let listening = try? await isPortListening(client: client, port: port), listening {
                    return port
                }
                if let pid = launchedPID, let alive = try? await isProcessAlive(client: client, pid: pid), !alive {
                    let detail = (try? await fetchServerLogTail(client: client, logPath: logPath)) ?? ""
                    if detail.localizedCaseInsensitiveContains("address already in use") {
                        lastFailure = detail
                        break
                    }
                    throw SSHError.serverStartFailed(
                        message: detail.isEmpty ? "Server process exited immediately." : detail
                    )
                }
            }
            let detail = (try? await fetchServerLogTail(client: client, logPath: logPath)) ?? ""
            if detail.localizedCaseInsensitiveContains("address already in use") {
                lastFailure = detail
                continue
            }
            lastFailure = detail.isEmpty ? lastFailure : detail
            break
        }
        throw SSHError.serverStartFailed(
            message: lastFailure
        )
    }

    func resolveAvailableBackends() async throws -> [AvailableBackend] {
        guard let client else { throw SSHError.notConnected }
        let script = """
        for f in "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.bashrc" "$HOME/.zprofile" "$HOME/.zshrc"; do
          [ -f "$f" ] && . "$f" 2>/dev/null
        done
        found=""
        if command -v codex >/dev/null 2>&1 || [ -x "$HOME/.volta/bin/codex" ] || [ -x "$HOME/.cargo/bin/codex" ] || command -v codex-app-server >/dev/null 2>&1 || [ -x "$HOME/.cargo/bin/codex-app-server" ]; then
          found="${found}codex\\n"
        fi
        if command -v claude-app-server >/dev/null 2>&1 || [ -x "$HOME/.cargo/bin/claude-app-server" ] || command -v claude >/dev/null 2>&1 || [ -x "$HOME/.local/bin/claude" ]; then
          found="${found}claude\\n"
        fi
        printf '%b' "$found"
        """
        let output = String(buffer: try await client.executeCommand(script))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return [] }
        return output.split(separator: "\n").compactMap { line in
            AvailableBackend(rawValue: String(line).trimmingCharacters(in: .whitespaces))
        }
    }

    func startRemoteServer(backend: AvailableBackend) async throws -> UInt16 {
        guard let client else { throw SSHError.notConnected }
        let wantsIPv6 = (connectedHost ?? "").contains(":")

        guard let launchCommand = try await resolveServerLaunchCommand(client: client, backend: backend) else {
            throw SSHError.serverBinaryMissing
        }

        var lastFailure = "Timed out waiting for remote server to start."
        portLoop: for port in candidatePorts() {
            let listenAddr = wantsIPv6 ? "[::]:\(port)" : "0.0.0.0:\(port)"
            let logPath = "/tmp/codex-ios-app-server-\(port).log"

            if let listening = try? await isPortListening(client: client, port: port), listening {
                if let matchesBackend = try? await isRequestedBackendListening(client: client, port: port, backend: backend),
                   matchesBackend {
                    return port
                }
                // Port is occupied by another process/backend; try next candidate.
                continue
            }

            let launchOutput = String(
                buffer: try await client.executeCommand(
                    try startServerCommand(for: launchCommand, listenAddr: listenAddr, logPath: logPath)
                )
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let launchedPID = Int(launchOutput)

            for attempt in 0..<60 {
                try await Task.sleep(for: .milliseconds(500))
                if let listening = try? await isPortListening(client: client, port: port), listening {
                    if let matchesBackend = try? await isRequestedBackendListening(client: client, port: port, backend: backend),
                       matchesBackend {
                        return port
                    }
                    // Port became occupied by an unexpected process/backend; try next port.
                    continue portLoop
                }
                if let pid = launchedPID, let alive = try? await isProcessAlive(client: client, pid: pid), !alive {
                    let detail = (try? await fetchServerLogTail(client: client, logPath: logPath)) ?? ""
                    if detail.localizedCaseInsensitiveContains("address already in use") {
                        lastFailure = detail
                        break
                    }
                    throw SSHError.serverStartFailed(
                        message: detail.isEmpty ? "Server process exited immediately." : detail
                    )
                }
            }
            let detail = (try? await fetchServerLogTail(client: client, logPath: logPath)) ?? ""
            if detail.localizedCaseInsensitiveContains("address already in use") {
                lastFailure = detail
                continue
            }
            lastFailure = detail.isEmpty ? lastFailure : detail
            break
        }
        throw SSHError.serverStartFailed(
            message: lastFailure
        )
    }

    private func isRequestedBackendListening(client: SSHClient, port: UInt16, backend: AvailableBackend) async throws -> Bool {
        let script = """
        pid="$(lsof -nP -iTCP:\(port) -sTCP:LISTEN -t 2>/dev/null | head -n 1)"
        if [ -z "$pid" ]; then
          exit 0
        fi
        ps -p "$pid" -o command= 2>/dev/null
        """
        let raw = try await client.executeCommand(script)
        let commandLine = String(buffer: raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !commandLine.isEmpty else { return false }

        return matchesBackend(commandLine: commandLine, backend: backend)
    }

    private func isProcessMatchingBackend(client: SSHClient, pid: Int, backend: AvailableBackend) async throws -> Bool {
        let script = "ps -p \(pid) -o command= 2>/dev/null"
        let raw = try await client.executeCommand(script)
        let commandLine = String(buffer: raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !commandLine.isEmpty else { return false }
        return matchesBackend(commandLine: commandLine, backend: backend)
    }

    private func matchesBackend(commandLine: String, backend: AvailableBackend) -> Bool {
        switch backend {
        case .codex:
            return commandLine.contains("codex-app-server") ||
                (commandLine.contains("codex") && commandLine.contains("app-server"))
        case .claude:
            return commandLine.contains("claude-app-server")
        }
    }

    private func resolveServerLaunchCommand(client: SSHClient, backend: AvailableBackend) async throws -> ServerLaunchCommand? {
        let script: String
        switch backend {
        case .codex:
            script = """
            for f in "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.bashrc" "$HOME/.zprofile" "$HOME/.zshrc"; do
              [ -f "$f" ] && . "$f" 2>/dev/null
            done
            if command -v codex >/dev/null 2>&1; then
              printf 'codex:%s' "$(command -v codex)"
            elif [ -x "$HOME/.volta/bin/codex" ]; then
              printf 'codex:%s' "$HOME/.volta/bin/codex"
            elif [ -x "$HOME/.cargo/bin/codex" ]; then
              printf 'codex:%s' "$HOME/.cargo/bin/codex"
            elif command -v codex-app-server >/dev/null 2>&1; then
              printf 'codex-app-server:%s' "$(command -v codex-app-server)"
            elif [ -x "$HOME/.cargo/bin/codex-app-server" ]; then
              printf 'codex-app-server:%s' "$HOME/.cargo/bin/codex-app-server"
            fi
            """
        case .claude:
            script = """
            for f in "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.bashrc" "$HOME/.zprofile" "$HOME/.zshrc"; do
              [ -f "$f" ] && . "$f" 2>/dev/null
            done
            if command -v claude-app-server >/dev/null 2>&1; then
              printf 'claude-app-server:%s' "$(command -v claude-app-server)"
            elif [ -x "$HOME/.cargo/bin/claude-app-server" ]; then
              printf 'claude-app-server:%s' "$HOME/.cargo/bin/claude-app-server"
            elif command -v claude >/dev/null 2>&1; then
              printf 'claude:%s' "$(command -v claude)"
            elif [ -x "$HOME/.local/bin/claude" ]; then
              printf 'claude:%s' "$HOME/.local/bin/claude"
            fi
            """
        }
        let output = String(buffer: try await client.executeCommand(script))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return nil }
        let parts = output.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "codex": return .codex(executable: parts[1])
        case "codex-app-server": return .codexAppServer(executable: parts[1])
        case "claude-app-server": return .claudeAppServer(executable: parts[1])
        case "claude": return .claude(executable: parts[1])
        default: return nil
        }
    }

    private func candidatePorts() -> [UInt16] {
        var ports: [UInt16] = [defaultRemotePort]
        ports.append(contentsOf: (1...20).compactMap { UInt16(exactly: Int(defaultRemotePort) + $0) })
        return ports
    }

    private func resolveServerLaunchCommand(client: SSHClient) async throws -> ServerLaunchCommand? {
        let script = """
        for f in "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.bashrc" "$HOME/.zprofile" "$HOME/.zshrc"; do
          [ -f "$f" ] && . "$f" 2>/dev/null
        done
        if command -v codex >/dev/null 2>&1; then
          printf 'codex:%s' "$(command -v codex)"
        elif [ -x "$HOME/.volta/bin/codex" ]; then
          printf 'codex:%s' "$HOME/.volta/bin/codex"
        elif [ -x "$HOME/.cargo/bin/codex" ]; then
          printf 'codex:%s' "$HOME/.cargo/bin/codex"
        elif command -v codex-app-server >/dev/null 2>&1; then
          printf 'codex-app-server:%s' "$(command -v codex-app-server)"
        elif [ -x "$HOME/.cargo/bin/codex-app-server" ]; then
          printf 'codex-app-server:%s' "$HOME/.cargo/bin/codex-app-server"
        elif command -v claude-app-server >/dev/null 2>&1; then
          printf 'claude-app-server:%s' "$(command -v claude-app-server)"
        elif [ -x "$HOME/.cargo/bin/claude-app-server" ]; then
          printf 'claude-app-server:%s' "$HOME/.cargo/bin/claude-app-server"
        elif command -v claude >/dev/null 2>&1; then
          printf 'claude:%s' "$(command -v claude)"
        elif [ -x "$HOME/.local/bin/claude" ]; then
          printf 'claude:%s' "$HOME/.local/bin/claude"
        fi
        """
        let output = String(buffer: try await client.executeCommand(script))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return nil }
        let parts = output.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "codex": return .codex(executable: parts[1])
        case "codex-app-server": return .codexAppServer(executable: parts[1])
        case "claude-app-server": return .claudeAppServer(executable: parts[1])
        case "claude": return .claude(executable: parts[1])
        default: return nil
        }
    }

    private func startServerCommand(for command: ServerLaunchCommand, listenAddr: String, logPath: String) throws -> String {
        let listenArg = shellQuote("ws://\(listenAddr)")
        let launch: String
        switch command {
        case .codex(let executable):
            launch = "\(shellQuote(executable)) app-server --listen \(listenArg)"
        case .codexAppServer(let executable):
            launch = "\(shellQuote(executable)) --listen \(listenArg)"
        case .claudeAppServer(let executable):
            launch = "\(shellQuote(executable)) --listen \(listenArg)"
        case .claude:
            throw SSHError.claudeBridgeMissing
        }
        let profileInit = "for f in \"$HOME/.profile\" \"$HOME/.bash_profile\" \"$HOME/.bashrc\" \"$HOME/.zprofile\" \"$HOME/.zshrc\"; do [ -f \"$f\" ] && . \"$f\" 2>/dev/null; done;"
        return "\(profileInit) nohup \(launch) </dev/null >\(shellQuote(logPath)) 2>&1 & echo $!"
    }

    private func isPortListening(client: SSHClient, port: UInt16) async throws -> Bool {
        let out = try await client.executeCommand(
            "lsof -nP -iTCP:\(port) -sTCP:LISTEN -t 2>/dev/null | head -n 1"
        )
        return !String(buffer: out).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private func isProcessAlive(client: SSHClient, pid: Int) async throws -> Bool {
        let out = try await client.executeCommand("kill -0 \(pid) >/dev/null 2>&1 && echo alive || echo dead")
        return String(buffer: out).trimmingCharacters(in: .whitespacesAndNewlines) == "alive"
    }

    private func fetchServerLogTail(client: SSHClient, logPath: String) async throws -> String {
        let out = try await client.executeCommand("tail -n 25 \(shellQuote(logPath)) 2>/dev/null")
        return String(buffer: out).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func executeCommand(_ command: String) async throws -> String {
        guard let client else { throw SSHError.notConnected }
        let result = try await client.executeCommand(command)
        return String(buffer: result)
    }

    func disconnect() async {
        try? await client?.close()
        client = nil
        connectedHost = nil
    }
}

enum SSHError: LocalizedError {
    case notConnected
    case serverStartTimeout
    case serverBinaryMissing
    case claudeBridgeMissing
    case serverStartFailed(message: String)
    case unsupportedKeyType
    case authenticationFailed(detail: String)
    case connectionFailed(host: String, port: Int, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "SSH not connected"
        case .serverStartTimeout: return "Timed out waiting for remote server to start"
        case .serverBinaryMissing: return "Remote host is missing `codex`, `codex-app-server`, and `claude-app-server` in PATH"
        case .claudeBridgeMissing: return "Found `claude` CLI, but `claude-app-server` is missing. Install the bridge binary and retry."
        case .serverStartFailed(let message): return message
        case .unsupportedKeyType: return "Unsupported SSH key type (only RSA and ED25519 are supported)"
        case .authenticationFailed(let detail):
            return "SSH authentication failed — verify username/password or key. \(detail)"
        case .connectionFailed(let host, let port, let underlying):
            let detail = Self.connectionErrorDetail(underlying)
            let lower = detail.lowercased()
            if lower.contains("connect timeout") || lower.contains("timed out") {
                return "Could not connect to \(host):\(port) — connection timed out. Selected network path is unreachable from this device right now (Tailscale/LAN). \(detail)"
            }
            if lower.contains("operation not permitted") || lower.contains("local network") {
                return "Could not connect to \(host):\(port) — local network access may be blocked for this app in iOS Settings. \(detail)"
            }
            if lower.contains("no route to host") || lower.contains("network is unreachable") {
                return "Could not connect to \(host):\(port) — host is not reachable from this device/network. \(detail)"
            }
            if lower.contains("connection refused") {
                return "Could not connect to \(host):\(port) — SSH is not accepting connections on that host/port. \(detail)"
            }
            return "Could not connect to \(host):\(port). \(detail)"
        }
    }

    static func connectionErrorDetail(_ error: Error) -> String {
        let candidates = [
            error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines),
            String(describing: error).trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        var parts: [String] = []
        for candidate in candidates where !candidate.isEmpty {
            if !parts.contains(candidate) {
                parts.append(candidate)
            }
        }
        return parts.joined(separator: " | ")
    }
}
