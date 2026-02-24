import SwiftUI
import Network

struct SSHLoginSheet: View {
    let server: DiscoveredServer
    let fallbackServers: [DiscoveredServer]
    let onConnect: ([(ConnectionTarget, SSHSessionManager.AvailableBackend)]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var useKey = false
    @State private var privateKey = ""
    @State private var passphrase = ""
    @State private var rememberCredentials = true
    @State private var hasSavedCredentials = false
    @State private var loadedSavedCredentials = false
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var isProbing = false
    @State private var detectedBackends: [SSHSessionManager.AvailableBackend] = []
    @State private var showBackendPicker = false
    @State private var connectedServerHost: String?

    private struct SSHHostCandidate: Hashable {
        let host: String
        let port: Int
        let source: ServerSource
    }

    private var sshPort: Int {
        Int(server.port ?? 22)
    }

    private var sshCandidates: [SSHHostCandidate] {
        var seen = Set<String>()
        var candidates: [SSHHostCandidate] = []
        for serverCandidate in [server] + fallbackServers {
            let port = Int(serverCandidate.port ?? 22)
            let direct = SSHHostCandidate(
                host: serverCandidate.hostname,
                port: port,
                source: serverCandidate.source
            )
            let directKey = "\(direct.host.lowercased()):\(direct.port)"
            if seen.insert(directKey).inserted {
                candidates.append(direct)
            }

            for alias in tailscaleAliases(for: serverCandidate) {
                let aliasCandidate = SSHHostCandidate(
                    host: alias,
                    port: port,
                    source: .tailscale
                )
                let aliasKey = "\(aliasCandidate.host.lowercased()):\(aliasCandidate.port)"
                if seen.insert(aliasKey).inserted {
                    candidates.append(aliasCandidate)
                }
            }
        }
        return candidates
    }

    var body: some View {
        NavigationStack {
            Form {
                    Section {
                        HStack(spacing: 12) {
                            Image(systemName: "terminal")
                                .foregroundColor(MocodeTheme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name)
                                    .font(.system(.subheadline, design: .rounded))
                                    .foregroundColor(MocodeTheme.textPrimary)
                                Text(server.hostname)
                                    .font(.system(.caption, design: .rounded))
                                    .foregroundColor(MocodeTheme.textSecondary)
                                if server.port != nil {
                                    Text("SSH :\(sshPort)")
                                        .font(.system(.caption2, design: .rounded))
                                        .foregroundColor(MocodeTheme.textMuted)
                                }
                            }
                        }
                    }

                    Section {
                        TextField("username", text: $username)
                            .font(.system(.footnote, design: .rounded))
                            .foregroundColor(MocodeTheme.textPrimary)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    } header: {
                        Text("Username")
                            .foregroundColor(MocodeTheme.textSecondary)
                    }

                    Section {
                        Picker("Method", selection: $useKey) {
                            Text("Password").tag(false)
                            Text("SSH Key").tag(true)
                        }
                        .pickerStyle(.segmented)
    
                        if useKey {
                            TextEditor(text: $privateKey)
                                .font(.system(.caption, design: .rounded))
                                .foregroundColor(MocodeTheme.textPrimary)
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 100)
                                .overlay(alignment: .topLeading) {
                                    if privateKey.isEmpty {
                                        Text("Paste private key here...")
                                            .font(.system(.caption, design: .rounded))
                                            .foregroundColor(MocodeTheme.textMuted)
                                            .padding(.top, 8)
                                            .padding(.leading, 4)
                                            .allowsHitTesting(false)
                                    }
                                }
                            SecureField("passphrase (optional)", text: $passphrase)
                                .font(.system(.footnote, design: .rounded))
                                .foregroundColor(MocodeTheme.textPrimary)
                        } else {
                            SecureField("password", text: $password)
                                .font(.system(.footnote, design: .rounded))
                                .foregroundColor(MocodeTheme.textPrimary)
                        }
                    } header: {
                        Text("Authentication")
                            .foregroundColor(MocodeTheme.textSecondary)
                    }

                    Section {
                        Toggle(isOn: $rememberCredentials) {
                            Text("Remember credentials on this device")
                                .font(.system(.footnote, design: .rounded))
                                .foregroundColor(MocodeTheme.textPrimary)
                        }
                        .tint(MocodeTheme.accent)

                        if hasSavedCredentials {
                            Button(role: .destructive) {
                                forgetSavedCredentials()
                            } label: {
                                Text("Forget saved credentials")
                                    .font(.system(.footnote, design: .rounded))
                            }
                        }
                    } header: {
                        Text("Saved Credentials")
                            .foregroundColor(MocodeTheme.textSecondary)
                    }

                    Section {
                        Button {
                            connect()
                        } label: {
                            HStack {
                                if isConnecting || isProbing {
                                    ProgressView().tint(MocodeTheme.accent)
                                }
                                Text(isProbing ? "Detecting backends…" : "Connect")
                                    .foregroundColor(MocodeTheme.accent)
                                    .font(.system(.subheadline, design: .rounded))
                            }
                        }
                        .disabled(isConnecting || isProbing || username.isEmpty || (!useKey && password.isEmpty) || (useKey && privateKey.isEmpty))
                    }

                    if let err = errorMessage {
                        Section {
                            Text(err)
                                .foregroundColor(.red)
                                .font(.system(.caption, design: .rounded))
                        }
                    }
                }
            .navigationTitle("SSH Login")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(MocodeTheme.accent)
                }
            }
        }
        .task {
            loadSavedCredentialsIfNeeded()
        }
        .confirmationDialog("Choose Backend", isPresented: $showBackendPicker, titleVisibility: .visible) {
            ForEach(detectedBackends) { backend in
                Button(backend.displayName) {
                    Task { await startAllServers(backends: [backend]) }
                }
            }
            if detectedBackends.count > 1 {
                Button("Start All") {
                    Task { await startAllServers(backends: detectedBackends) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Both Codex and Claude are available on this machine.")
        }
    }

    private func connect() {
        let credentials = buildCredentials()
        isProbing = true
        errorMessage = nil
        connectedServerHost = nil

        Task {
            let ssh = SSHSessionManager.shared
            var lastError: Error?
            var connectedCandidate: SSHHostCandidate?
            var unreachableCandidates: [String] = []

            for candidate in sshCandidates {
                let port = candidate.port
                let host = candidate.host
                let shouldPreflight = isIPv4Address(host) || host.contains(":")
                if shouldPreflight {
                    let reachable = await isTCPReachable(host: host, port: port, timeout: 2.5)
                    if !reachable {
                        unreachableCandidates.append("\(host):\(port)")
                        NSLog("[SSH_LOGIN] preflight unreachable %@:%d (%@)", host, port, candidate.source.rawString)
                        continue
                    }
                }
                do {
                    await ssh.disconnect()
                    NSLog("[SSH_LOGIN] trying %@:%d (%@)", host, port, candidate.source.rawString)
                    try await ssh.connect(host: host, port: port, credentials: credentials)
                    connectedCandidate = candidate
                    connectedServerHost = host
                    NSLog("[SSH_LOGIN] connected %@:%d", host, port)
                    break
                } catch {
                    NSLog("[SSH_LOGIN] failed %@:%d — %@", host, port, error.localizedDescription)
                    lastError = error
                }
            }

            guard connectedCandidate != nil else {
                isProbing = false
                if let lastError {
                    errorMessage = lastError.localizedDescription
                } else if !unreachableCandidates.isEmpty {
                    errorMessage = "No reachable SSH path found. Tried: \(unreachableCandidates.joined(separator: ", "))"
                } else {
                    errorMessage = "Unable to connect to any SSH endpoint"
                }
                return
            }

            do {
                let backends = try await ssh.resolveAvailableBackends()
                NSLog("[SSH_LOGIN] detected backends: %@", backends.map(\.rawValue).joined(separator: ","))

                guard !backends.isEmpty else {
                    isProbing = false
                    errorMessage = SSHError.serverBinaryMissing.localizedDescription
                    return
                }

                isProbing = false
                NSLog("[SSH_LOGIN] auto-starting all backends: %@", backends.map(\.rawValue).joined(separator: ","))
                await startAllServers(backends: backends)
            } catch {
                isProbing = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func startAllServers(backends: [SSHSessionManager.AvailableBackend]) async {
        isConnecting = true
        errorMessage = nil

        let ssh = SSHSessionManager.shared
        var remoteHost = (connectedServerHost ?? server.hostname)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .replacingOccurrences(of: "%25", with: "%")
        if !remoteHost.contains(":"), let pct = remoteHost.firstIndex(of: "%") {
            remoteHost = String(remoteHost[..<pct])
        }

        var results: [(ConnectionTarget, SSHSessionManager.AvailableBackend)] = []
        var failures: [String] = []

        for backend in backends {
            do {
                NSLog("[SSH_LOGIN] starting backend: %@", backend.rawValue)
                let port = try await ssh.startRemoteServer(backend: backend)
                let target = ConnectionTarget.remote(host: remoteHost, port: port)
                NSLog("[SSH_LOGIN] backend %@ ready on %@:%d", backend.rawValue, remoteHost, Int(port))
                results.append((target, backend))
            } catch {
                NSLog("[SSH_LOGIN] backend %@ failed: %@", backend.rawValue, error.localizedDescription)
                failures.append("\(backend.displayName): \(error.localizedDescription)")
            }
        }

        isConnecting = false

        if results.isEmpty {
            errorMessage = failures.isEmpty
                ? "Failed to start any backend server"
                : failures.joined(separator: "\n")
        } else {
            saveOrDeleteCredentials()
            clearSensitiveInput()
            onConnect(results)
        }
    }

    private func buildCredentials() -> SSHCredentials {
        if useKey {
            return .key(
                username: username,
                privateKey: privateKey,
                passphrase: passphrase.isEmpty ? nil : passphrase
            )
        } else {
            return .password(username: username, password: password)
        }
    }

    private func saveOrDeleteCredentials() {
        do {
            if rememberCredentials {
                try SSHCredentialStore.shared.save(savedCredential(from: buildCredentials()), host: server.hostname, port: sshPort)
                hasSavedCredentials = true
            } else {
                try SSHCredentialStore.shared.delete(host: server.hostname, port: sshPort)
                hasSavedCredentials = false
            }
        } catch {
            NSLog("[SSH_CREDENTIALS] keychain update failed: %@", error.localizedDescription)
        }
    }

    private func loadSavedCredentialsIfNeeded() {
        guard !loadedSavedCredentials else { return }
        loadedSavedCredentials = true

        do {
            guard let saved = try SSHCredentialStore.shared.load(host: server.hostname, port: sshPort) else {
                hasSavedCredentials = false
                return
            }
            hasSavedCredentials = true
            rememberCredentials = true
            username = saved.username
            useKey = saved.method == .key
            if saved.method == .key {
                privateKey = saved.privateKey ?? ""
                passphrase = saved.passphrase ?? ""
                password = ""
            } else {
                password = saved.password ?? ""
                privateKey = ""
                passphrase = ""
            }
        } catch {
            NSLog("[SSH_CREDENTIALS] failed to load: %@", error.localizedDescription)
        }
    }

    private func forgetSavedCredentials() {
        do {
            try SSHCredentialStore.shared.delete(host: server.hostname, port: sshPort)
            hasSavedCredentials = false
            rememberCredentials = false
            clearSensitiveInput()
        } catch {
            NSLog("[SSH_CREDENTIALS] failed to delete: %@", error.localizedDescription)
        }
    }

    private func savedCredential(from credentials: SSHCredentials) -> SavedSSHCredential {
        switch credentials {
        case .password(let username, let password):
            return SavedSSHCredential(
                username: username,
                method: .password,
                password: password,
                privateKey: nil,
                passphrase: nil
            )
        case .key(let username, let privateKey, let passphrase):
            return SavedSSHCredential(
                username: username,
                method: .key,
                password: nil,
                privateKey: privateKey,
                passphrase: passphrase
            )
        }
    }

    private func clearSensitiveInput() {
        password = ""
        privateKey = ""
        passphrase = ""
    }

    private func tailscaleAliases(for candidate: DiscoveredServer) -> [String] {
        var aliases: [String] = []

        let rawHost = candidate.hostname
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .replacingOccurrences(of: "%25", with: "%")
        if !rawHost.isEmpty && !rawHost.contains(":") && !isIPv4Address(rawHost) {
            aliases.append(rawHost.lowercased())
        }

        let normalizedName = normalizedHostLabel(candidate.name)
        if !normalizedName.isEmpty {
            aliases.append(normalizedName)
        }

        var seen = Set<String>()
        return aliases.filter { alias in
            let key = alias.lowercased()
            return seen.insert(key).inserted
        }
    }

    private func normalizedHostLabel(_ value: String) -> String {
        var value = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if value.hasSuffix(".local") {
            value.removeLast(6)
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.")
        let scalarView = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(scalarView)
            .replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return collapsed
    }

    private func isIPv4Address(_ host: String) -> Bool {
        var addr = in_addr()
        return host.withCString { cstr in
            inet_pton(AF_INET, cstr, &addr) == 1
        }
    }

    private func isTCPReachable(host: String, port: Int, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
                continuation.resume(returning: false)
                return
            }

            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let lock = NSLock()
            var finished = false

            @Sendable func complete(_ value: Bool) {
                lock.lock()
                let shouldComplete = !finished
                finished = true
                lock.unlock()
                guard shouldComplete else { return }
                connection.cancel()
                continuation.resume(returning: value)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    complete(true)
                case .failed, .cancelled:
                    complete(false)
                default:
                    break
                }
            }

            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                complete(false)
            }
        }
    }
}

// MARK: - Previews

#Preview("SSH Login - Bonjour") {
    SSHLoginSheet(
        server: DiscoveredServer(
            id: "preview-bonjour",
            name: "MacBook Pro",
            hostname: "macbook-pro.local",
            port: 22,
            source: .bonjour,
            hasCodexServer: false
        ),
        fallbackServers: [],
        onConnect: { _ in }
    )
}

#Preview("SSH Login - Tailscale") {
    SSHLoginSheet(
        server: DiscoveredServer(
            id: "preview-tailscale",
            name: "dev-server",
            hostname: "dev-server.tail12345.ts.net",
            port: 22,
            source: .tailscale,
            hasCodexServer: false
        ),
        fallbackServers: [],
        onConnect: { _ in }
    )
}

#Preview("SSH Login - Manual") {
    SSHLoginSheet(
        server: DiscoveredServer(
            id: "preview-manual",
            name: "192.168.1.100",
            hostname: "192.168.1.100",
            port: 22,
            source: .manual,
            hasCodexServer: false
        ),
        fallbackServers: [],
        onConnect: { _ in }
    )
}
