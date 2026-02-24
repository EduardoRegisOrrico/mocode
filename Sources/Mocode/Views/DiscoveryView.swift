import SwiftUI
import Network

struct DiscoveryView: View {
    var onServerSelected: ((DiscoveredServer) -> Void)?
    @EnvironmentObject var serverManager: ServerManager
    @StateObject private var discovery = NetworkDiscovery()
    @State private var sshServer: DiscoveredServer?
    @State private var sshFallbackServers: [DiscoveredServer] = []
    @State private var showManualEntry = false
    @State private var manualHost = ""
    @State private var manualPort = "22"
    @State private var autoSSHStarted = false
    @State private var connectingServer: DiscoveredServer?
    @State private var connectError: String?

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
            networkSection
            manualSection
        }
        .refreshable { discovery.startScanning() }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    discovery.startScanning()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(MocodeTheme.accent)
                }
                .disabled(discovery.isScanning)
            }
        }
        .onAppear {
            discovery.startScanning()
            maybeStartSimulatorAutoSSH()
        }
        .onDisappear { discovery.stopScanning() }
        .sheet(item: $sshServer) { server in
            SSHLoginSheet(server: server, fallbackServers: sshFallbackServers) { results in
                sshServer = nil
                sshFallbackServers = []
                Task {
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
                            await connectToServer(resolved)
                        default:
                            await connectToServer(server)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showManualEntry) {
            manualEntrySheet
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

    private var networkSection: some View {
        Section {
            let networkServers = discovery.servers.filter { $0.source != .local }
            if networkServers.isEmpty {
                if discovery.isScanning {
                    HStack {
                        ProgressView().tint(MocodeTheme.textMuted).scaleEffect(0.7)
                        Text("Scanning Bonjour + Tailscale...")
                            .font(.system(.footnote, design: .rounded))
                            .foregroundColor(MocodeTheme.textMuted)
                    }
                            } else {
                    Text("No IPv4 SSH hosts found via Bonjour/Tailscale")
                        .font(.system(.footnote, design: .rounded))
                        .foregroundColor(MocodeTheme.textMuted)
                                }
            } else {
                ForEach(networkServers) { server in
                    serverRow(server)
                }
            }
        } header: {
            Text("Network")
                .foregroundColor(MocodeTheme.textSecondary)
        }
    }

    private var manualSection: some View {
        Section {
            Button {
                showManualEntry = true
            } label: {
                HStack {
                    Image(systemName: "plus.circle")
                        .foregroundColor(MocodeTheme.accent)
                    Text("Add Server")
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
            parts.append(" - SSH (\(server.source.rawString))")
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
                let ordered = candidateServers(for: server)
                    .sorted { sourcePriority($0.source) < sourcePriority($1.source) }
                sshFallbackServers = ordered.filter { $0.id != preferred.id }
                sshServer = preferred
            }
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
        case .bonjour: return 1
        case .manual: return 2
        case .ssh: return 3
        case .local: return 4
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

        if matches.allSatisfy({ $0.source != .tailscale }) {
            let tailscaleCandidates = discovery.servers.filter { $0.source == .tailscale }
            if tailscaleCandidates.count == 1, let only = tailscaleCandidates.first {
                matches.append(only)
            }
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
                    TextField("hostname or IP", text: $manualHost)
                        .font(.system(.footnote, design: .rounded))
                        .foregroundColor(MocodeTheme.textPrimary)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("SSH port", text: $manualPort)
                        .font(.system(.footnote, design: .rounded))
                        .foregroundColor(MocodeTheme.textPrimary)
                        .keyboardType(.numberPad)
                }

                Section {
                    Button("Connect") {
                        guard !manualHost.isEmpty else { return }
                        let maybePort = UInt16(manualPort)
                        let server = DiscoveredServer(
                            id: "manual-\(manualHost):\(manualPort)",
                            name: manualHost, hostname: manualHost,
                            port: maybePort, source: .manual, hasCodexServer: false
                        )
                        showManualEntry = false
                        sshFallbackServers = []
                        sshServer = server
                    }
                    .foregroundColor(MocodeTheme.accent)
                    .font(.system(.subheadline, design: .rounded))
                }
            }
            .navigationTitle("Add Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { showManualEntry = false }
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
    }
}
