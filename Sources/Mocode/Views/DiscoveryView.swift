import Foundation
import SwiftUI
import Network

struct DiscoveryView: View {
    var onServerSelected: ((DiscoveredServer) -> Void)?
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var appState: AppState
    @StateObject private var discovery = NetworkDiscovery()
    @State private var sshServer: DiscoveredServer?
    @State private var sshFallbackServers: [DiscoveredServer] = []
    @State private var showManualEntry = false
    @State private var manualHost = ""
    @State private var showAPIKeyEntry = false
    @State private var apiKeyDraft = ""
    @State private var autoSSHStarted = false
    @State private var connectingServer: DiscoveredServer?
    @State private var connectError: String?

    private var hasAPIKey: Bool { !appState.tailscaleAPIKey.isEmpty }

    var body: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    BrandLogo(size: 86)
                    Spacer()
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            if discovery.servers.contains(where: { $0.source == .local }) {
                localSection
            }
            tailscaleSection
            addServerSection
        }
        .refreshable {
            if hasAPIKey { discovery.startScanning(apiKey: appState.tailscaleAPIKey) }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if hasAPIKey {
                    Button {
                        discovery.startScanning(apiKey: appState.tailscaleAPIKey)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundColor(MocodeTheme.accent)
                    }
                    .disabled(discovery.isScanning)
                }
            }
        }
        .onAppear {
            if hasAPIKey {
                discovery.startScanning(apiKey: appState.tailscaleAPIKey)
            }
            maybeStartSimulatorAutoSSH()
        }
        .onDisappear { discovery.stopScanning() }
        .sheet(item: $sshServer) { server in
            SSHLoginSheet(server: server, fallbackServers: sshFallbackServers) { results in
                sshServer = nil
                sshFallbackServers = []
                Task {
                    var lastConnected: DiscoveredServer?
                    for (target, backend) in results {
                        switch target {
                        case .remote(let host, let port):
                            let backendSuffix = backend == .claude ? "claude" : "codex"
                            var resolved = DiscoveredServer(
                                id: "\(server.id)-\(backendSuffix)",
                                name: server.name,
                                hostname: host,
                                port: port,
                                source: server.source,
                                hasCodexServer: true
                            )
                            resolved.backendHint = backend == .claude ? .claude : .codex
                            resolved.sshPort = server.port ?? 22
                            await addServerWithoutSelecting(resolved)
                            lastConnected = resolved
                        default:
                            await addServerWithoutSelecting(server)
                            lastConnected = server
                        }
                    }
                    if let server = lastConnected {
                        onServerSelected?(server)
                    }
                }
            }
        }
        .sheet(isPresented: $showManualEntry) {
            manualEntrySheet
        }
        .sheet(isPresented: $showAPIKeyEntry) {
            apiKeyEntrySheet
        }
        .alert("Connection Failed", isPresented: showConnectError, actions: {
            Button("OK") { connectError = nil }
        }, message: {
            Text(connectError ?? "Unable to connect.")
        })
    }

    // MARK: - Sections

    private var localSection: some View {
        Section {
            ForEach(discovery.servers.filter { $0.source == .local }) { server in
                serverRow(server)
            }
        } header: {
            Text("This Device")
                .foregroundColor(MocodeTheme.textSecondary)
        }
    }

    private var tailscaleSection: some View {
        Section {
            if !hasAPIKey {
                Button {
                    apiKeyDraft = ""
                    showAPIKeyEntry = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "key")
                            .foregroundColor(MocodeTheme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Set Tailscale API Key")
                                .font(.system(.subheadline, design: .rounded))
                                .foregroundColor(MocodeTheme.accent)
                            Text("Required to scan your tailnet")
                                .font(.system(.caption, design: .rounded))
                                .foregroundColor(MocodeTheme.textMuted)
                        }
                    }
                }
            } else {
                let networkServers = discovery.servers.filter { $0.source != .local }
                if discovery.isScanning {
                    HStack {
                        ProgressView().tint(MocodeTheme.textMuted).scaleEffect(0.7)
                        Text("Scanning tailnet...")
                            .font(.system(.footnote, design: .rounded))
                            .foregroundColor(MocodeTheme.textMuted)
                    }
                } else if let error = discovery.scanError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                            .font(.caption)
                        Text(error)
                            .font(.system(.caption, design: .rounded))
                            .foregroundColor(.orange)
                    }
                } else if networkServers.isEmpty {
                    Text("No devices found in tailnet")
                        .font(.system(.footnote, design: .rounded))
                        .foregroundColor(MocodeTheme.textMuted)
                }

                ForEach(discovery.servers.filter { $0.source != .local }) { server in
                    serverRow(server)
                }
            }
        } header: {
            HStack {
                Text("Tailscale")
                    .foregroundColor(MocodeTheme.textSecondary)
                Spacer()
                if hasAPIKey {
                    Button {
                        apiKeyDraft = appState.tailscaleAPIKey
                        showAPIKeyEntry = true
                    } label: {
                        Image(systemName: "key")
                            .font(.caption2)
                            .foregroundColor(MocodeTheme.textMuted)
                    }
                }
            }
        }
    }

    private var addServerSection: some View {
        Section {
            Button {
                showManualEntry = true
            } label: {
                HStack {
                    Image(systemName: "plus.circle")
                        .foregroundColor(MocodeTheme.accent)
                    Text("Add Tailscale Host")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundColor(MocodeTheme.accent)
                }
            }
        }
    }

    // MARK: - Row

    private func serverRow(_ server: DiscoveredServer) -> some View {
        Button {
            handleTap(server)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: serverIconName(for: server.source))
                    .foregroundColor(server.hasCodexServer ? MocodeTheme.accent : MocodeTheme.textSecondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundColor(MocodeTheme.textPrimary)
                    Text(serverSubtitle(server))
                        .font(.system(.caption, design: .rounded))
                        .foregroundColor(MocodeTheme.textSecondary)
                }
                Spacer()
                if serverManager.connections[server.id]?.isConnected == true {
                    Text("connected")
                        .font(.system(.caption2, design: .rounded))
                        .foregroundColor(MocodeTheme.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(MocodeTheme.accent.opacity(0.15))
                        .cornerRadius(4)
                } else if connectingServer?.id == server.id {
                    ProgressView().controlSize(.small).tint(MocodeTheme.accent)
                } else {
                    Image(systemName: "chevron.right")
                        .foregroundColor(MocodeTheme.textMuted)
                        .font(.caption)
                }
            }
        }
        .disabled(connectingServer != nil)
    }

    private func serverSubtitle(_ server: DiscoveredServer) -> String {
        if server.source == .local { return "In-process server" }
        var parts = [server.hostname]
        if let port = server.port { parts.append(":\(port)") }
        if server.hasCodexServer {
            parts.append(" - codex running")
        } else {
            parts.append(" - SSH (tailscale)")
        }
        return parts.joined()
    }

    // MARK: - Actions

    private func handleTap(_ server: DiscoveredServer) {
        Task {
            let preferred = await preferredServer(for: server)
            if serverManager.connections[preferred.id]?.isConnected == true {
                onServerSelected?(preferred)
                return
            }
            if preferred.hasCodexServer {
                await connectToServer(preferred)
            } else {
                // Try auto-connect with saved credentials before showing the login sheet.
                if let result = await tryAutoConnect(server: preferred, fallbackServers: candidateServers(for: server).filter { $0.id != preferred.id }) {
                    var lastConnected: DiscoveredServer?
                    for (target, backend) in result {
                        switch target {
                        case .remote(let host, let port):
                            let backendSuffix = backend == .claude ? "claude" : "codex"
                            var resolved = DiscoveredServer(
                                id: "\(preferred.id)-\(backendSuffix)",
                                name: preferred.name,
                                hostname: host,
                                port: port,
                                source: preferred.source,
                                hasCodexServer: true
                            )
                            resolved.backendHint = backend == .claude ? .claude : .codex
                            resolved.sshPort = preferred.port ?? 22
                            await addServerWithoutSelecting(resolved)
                            lastConnected = resolved
                        default:
                            await addServerWithoutSelecting(preferred)
                            lastConnected = preferred
                        }
                    }
                    if let server = lastConnected {
                        onServerSelected?(server)
                    }
                } else {
                    let ordered = candidateServers(for: server)
                        .sorted { sourcePriority($0.source) < sourcePriority($1.source) }
                    sshFallbackServers = ordered.filter { $0.id != preferred.id }
                    sshServer = preferred
                }
            }
        }
    }

    /// Attempt SSH connection using saved keychain credentials.
    /// Returns the connection results on success, or nil if no saved credentials
    /// or if the connection fails (caller should fall back to showing SSHLoginSheet).
    private func tryAutoConnect(server: DiscoveredServer, fallbackServers: [DiscoveredServer]) async -> [(ConnectionTarget, SSHSessionManager.AvailableBackend)]? {
        let sshPort = Int(server.port ?? 22)
        guard let saved = try? SSHCredentialStore.shared.load(host: server.hostname, port: sshPort) else {
            await DebugLog.shared.log("autoSSH no saved credentials host=\(server.hostname) port=\(sshPort)")
            return nil
        }

        let credentials: SSHCredentials
        switch saved.method {
        case .password:
            guard let password = saved.password else { return nil }
            credentials = .password(username: saved.username, password: password)
        case .key:
            guard let privateKey = saved.privateKey else { return nil }
            credentials = .key(username: saved.username, privateKey: privateKey, passphrase: saved.passphrase)
        }

        connectingServer = server

        // Build candidate list same as SSHLoginSheet does.
        let allServers = [server] + fallbackServers
        let ssh = SSHSessionManager.shared
        var connected = false
        var connectedHost: String?

        for candidate in allServers {
            let port = Int(candidate.port ?? 22)
            let host = candidate.hostname
            do {
                await ssh.disconnect()
                NSLog("[AUTO_SSH] trying saved credentials %@:%d", host, port)
                try await ssh.connect(host: host, port: port, credentials: credentials)
                connected = true
                connectedHost = host
                NSLog("[AUTO_SSH] connected %@:%d with saved credentials", host, port)
                await DebugLog.shared.log("autoSSH connected host=\(host) port=\(port)")
                break
            } catch {
                NSLog("[AUTO_SSH] saved credentials failed %@:%d — %@", host, port, error.localizedDescription)
                await DebugLog.shared.log("autoSSH failed host=\(host) port=\(port) error=\(error.localizedDescription)")
            }
        }

        guard connected else {
            connectingServer = nil
            return nil
        }

        do {
            let backends = try await ssh.resolveAvailableBackends()
            await DebugLog.shared.log("autoSSH detected backends=\(backends.map(\.rawValue).joined(separator: ","))")
            guard !backends.isEmpty else {
                connectingServer = nil
                return nil
            }

            var remoteHost = (connectedHost ?? server.hostname)
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                .replacingOccurrences(of: "%25", with: "%")
            if !remoteHost.contains(":"), let pct = remoteHost.firstIndex(of: "%") {
                remoteHost = String(remoteHost[..<pct])
            }

            var results: [(ConnectionTarget, SSHSessionManager.AvailableBackend)] = []
            for backend in backends {
                do {
                    let port = try await ssh.startRemoteServer(backend: backend)
                    let target = ConnectionTarget.remote(host: remoteHost, port: port)
                    await DebugLog.shared.log("autoSSH backend ready backend=\(backend.rawValue) host=\(remoteHost) port=\(port)")
                    results.append((target, backend))
                } catch {
                    NSLog("[AUTO_SSH] backend %@ failed: %@", backend.rawValue, error.localizedDescription)
                    await DebugLog.shared.log("autoSSH backend failed backend=\(backend.rawValue) error=\(error.localizedDescription)")
                }
            }

            connectingServer = nil
            return results.isEmpty ? nil : results
        } catch {
            connectingServer = nil
            return nil
        }
    }


    private func preferredServer(for server: DiscoveredServer) async -> DiscoveredServer {
        let candidates = candidateServers(for: server)
            .sorted { sourcePriority($0.source) < sourcePriority($1.source) }

        for candidate in candidates {
            let port = candidate.connectionTargetPort
            if await isTCPReachable(host: candidate.hostname, port: port, timeout: 1.2) {
                return candidate
            }
        }
        return candidates.first ?? server
    }

    private func normalizeServerIdentity(_ value: String) -> String {
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

    private func sourcePriority(_ source: ServerSource) -> Int {
        switch source {
        case .tailscale: return 0
        case .local: return 1
        case .manual: return 2
        case .bonjour: return 3
        case .ssh: return 4
        }
    }

    private func candidateServers(for server: DiscoveredServer) -> [DiscoveredServer] {
        let identityA = normalizeServerIdentity(server.name)
        let identityB = normalizeServerIdentity(server.hostname)
        let identities = Set([identityA, identityB].filter { !$0.isEmpty })

        var matches = discovery.servers.filter { candidate in
            let candidateA = normalizeServerIdentity(candidate.name)
            let candidateB = normalizeServerIdentity(candidate.hostname)
            return !identities.isDisjoint(with: [candidateA, candidateB].filter { !$0.isEmpty })
        }
        if !matches.contains(server) {
            matches.append(server)
        }

        var seen = Set<String>()
        return matches.filter { seen.insert($0.id).inserted }
    }

    private func isTCPReachable(host: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                continuation.resume(returning: false)
                return
            }

            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let lock = NSLock()
            var finished = false

            func complete(_ value: Bool) {
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

    /// Connect a backend server without dismissing the sheet.
    /// Used when connecting multiple backends in sequence.
    private func addServerWithoutSelecting(_ server: DiscoveredServer) async {
        guard let target = server.connectionTarget else { return }
        await serverManager.addServer(server, target: target)
    }

    private func connectToServer(_ server: DiscoveredServer) async {
        guard connectingServer == nil else { return }
        connectingServer = server
        connectError = nil

        guard let target = server.connectionTarget else {
            connectError = "Server requires SSH login"
            connectingServer = nil
            return
        }

        await serverManager.addServer(server, target: target)

        let connected = serverManager.connections[server.id]?.isConnected == true
        connectingServer = nil
        if connected {
            onServerSelected?(server)
        } else {
            let phase = serverManager.connections[server.id]?.connectionPhase
            connectError = phase?.isEmpty == false ? phase : "Failed to connect"
        }
    }

    // MARK: - Manual Entry

    private var manualEntrySheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("hostname or Tailscale IP", text: $manualHost)
                        .font(.system(.footnote, design: .rounded))
                        .foregroundColor(MocodeTheme.textPrimary)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                } footer: {
                    Text("e.g. my-mac.tail1234.ts.net or 100.x.x.x")
                        .font(.system(.caption2, design: .rounded))
                        .foregroundColor(MocodeTheme.textMuted)
                }

                Section {
                    Button("Connect") {
                        guard !manualHost.isEmpty else { return }
                        let server = DiscoveredServer(
                            id: "tailscale-\(manualHost)",
                            name: manualHost,
                            hostname: manualHost,
                            port: nil,
                            source: .tailscale,
                            hasCodexServer: false
                        )
                        showManualEntry = false
                        sshFallbackServers = []
                        sshServer = server
                    }
                    .foregroundColor(MocodeTheme.accent)
                    .font(.system(.subheadline, design: .rounded))
                }
            }
            .navigationTitle("Add Tailscale Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { showManualEntry = false }
                        .foregroundColor(MocodeTheme.accent)
                }
            }
        }
    }

    // MARK: - API Key Entry

    private var apiKeyEntrySheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("tskey-api-...", text: $apiKeyDraft)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(MocodeTheme.textPrimary)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                } footer: {
                    Text("Generate at tailscale.com/admin/settings/keys")
                        .font(.system(.caption2, design: .rounded))
                        .foregroundColor(MocodeTheme.textMuted)
                }

                Section {
                    Button("Save") {
                        let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !key.isEmpty else { return }
                        appState.tailscaleAPIKey = key
                        showAPIKeyEntry = false
                        discovery.startScanning(apiKey: key)
                    }
                    .foregroundColor(MocodeTheme.accent)
                    .font(.system(.subheadline, design: .rounded))

                    if hasAPIKey {
                        Button("Remove Key") {
                            appState.tailscaleAPIKey = ""
                            showAPIKeyEntry = false
                        }
                        .foregroundColor(.red)
                        .font(.system(.subheadline, design: .rounded))
                    }
                }
            }
            .navigationTitle("Tailscale API Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { showAPIKeyEntry = false }
                        .foregroundColor(MocodeTheme.accent)
                }
            }
        }
    }

    private func maybeStartSimulatorAutoSSH() {
#if DEBUG
        guard !autoSSHStarted else { return }
        let env = ProcessInfo.processInfo.environment
        guard env["CODEXIOS_SIM_AUTO_SSH"] == "1",
              let host = env["CODEXIOS_SIM_AUTO_SSH_HOST"], !host.isEmpty,
              let user = env["CODEXIOS_SIM_AUTO_SSH_USER"], !user.isEmpty,
              let pass = env["CODEXIOS_SIM_AUTO_SSH_PASS"], !pass.isEmpty else {
            return
        }
        autoSSHStarted = true

        Task {
            do {
                NSLog("[AUTO_SSH] connecting to %@ as %@", host, user)
                let ssh = SSHSessionManager.shared
                try await ssh.connect(host: host, credentials: .password(username: user, password: pass))
                let port = try await ssh.startRemoteServer()
                NSLog("[AUTO_SSH] remote app-server port %d", Int(port))
                let server = DiscoveredServer(
                    id: "auto-ssh-\(host):\(port)",
                    name: host,
                    hostname: host,
                    port: port,
                    source: .manual,
                    hasCodexServer: true
                )
                await connectToServer(server)
            } catch {
                NSLog("[AUTO_SSH] failed: %@", error.localizedDescription)
            }
        }
#endif
    }

    private var showConnectError: Binding<Bool> {
        Binding(
            get: { connectError != nil },
            set: { newValue in
                if !newValue {
                    connectError = nil
                }
            }
        )
    }
}

// MARK: - Previews

#Preview("Discovery View") {
    NavigationStack {
        DiscoveryView()
            .environmentObject(ServerManager())
            .environmentObject(AppState())
    }
}
