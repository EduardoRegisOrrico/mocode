import SwiftUI

struct DirectoryPickerServerOption: Identifiable, Hashable {
    let id: String
    let name: String
    let sourceLabel: String
}

private struct DirectoryPathSegment: Identifiable {
    let id: String
    let label: String
    let path: String
}

struct DirectoryPickerPreviewSeed {
    let currentPath: String
    let entries: [String]
    var searchQuery: String = ""
    var isLoading: Bool = false
    var errorMessage: String?
}

@MainActor
private final class DirectoryPickerSheetModel: ObservableObject {
    @Published var currentPath = ""
    @Published var allEntries: [String] = []
    @Published var isLoading = true
    @Published var errorMessage: String?
    @Published var searchQuery = ""

    private var lastLoadedServerId = ""

    var trimmedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canNavigateUp: Bool {
        currentPath != "/" && !currentPath.isEmpty
    }

    func visibleEntries() -> [String] {
        guard !trimmedSearchQuery.isEmpty else { return allEntries }
        let foldedQuery = trimmedSearchQuery.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return allEntries.filter {
            $0.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).contains(foldedQuery)
        }
    }

    func emptyMessage() -> String {
        if trimmedSearchQuery.isEmpty {
            return "No subdirectories"
        }
        return "No matches for \"\(trimmedSearchQuery)\""
    }

    func pathSegments() -> [DirectoryPathSegment] {
        segments(for: currentPath)
    }

    func handleServerSelectionChanged(_ serverId: String) {
        if lastLoadedServerId != serverId {
            searchQuery = ""
            currentPath = ""
            allEntries = []
            errorMessage = nil
            lastLoadedServerId = serverId
        }
    }

    func loadInitialPath(selectedServerId: String, serverManager: ServerManager) async {
        let targetServerId = selectedServerId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetServerId.isEmpty else {
            isLoading = false
            allEntries = []
            errorMessage = "No server selected"
            currentPath = ""
            return
        }

        isLoading = true
        errorMessage = nil
        allEntries = []
        currentPath = ""

        let home = await resolveHome(for: targetServerId, serverManager: serverManager)
        guard targetServerId == selectedServerId else { return }
        currentPath = home
        await listDirectory(for: targetServerId, path: home, serverManager: serverManager)
    }

    func listDirectory(for serverId: String, path: String, serverManager: ServerManager) async {
        guard let connection = serverManager.connections[serverId], connection.isConnected else {
            if serverId == lastLoadedServerId {
                isLoading = false
                allEntries = []
                errorMessage = "Selected server is not connected"
            }
            return
        }

        let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "/" : path
        isLoading = true
        errorMessage = nil

        do {
            let resp = try await connection.execCommand(
                ["/bin/ls", "-1ap", normalizedPath],
                cwd: normalizedPath
            )
            guard serverId == lastLoadedServerId else { return }

            if resp.exitCode != 0 {
                errorMessage = resp.stderr.isEmpty ? "ls failed with code \(resp.exitCode)" : resp.stderr
                isLoading = false
                return
            }

            let lines = resp.stdout.split(separator: "\n").map(String.init)
            let directories = lines
                .filter { $0.hasSuffix("/") && $0 != "./" && $0 != "../" }
                .map { String($0.dropLast()) }
                .sorted { lhs, rhs in
                    let lhsIsHidden = lhs.hasPrefix(".")
                    let rhsIsHidden = rhs.hasPrefix(".")
                    if lhsIsHidden != rhsIsHidden {
                        return rhsIsHidden
                    }
                    return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
                }
            allEntries = directories
            withAnimation(.easeInOut(duration: 0.18)) {
                currentPath = normalizedPath
            }
        } catch {
            guard serverId == lastLoadedServerId else { return }
            errorMessage = error.localizedDescription
        }

        if serverId == lastLoadedServerId {
            isLoading = false
        }
    }

    func navigateInto(_ name: String, selectedServerId: String, serverManager: ServerManager) async {
        var nextPath = currentPath
        if nextPath.hasSuffix("/") {
            nextPath += name
        } else {
            nextPath += "/\(name)"
        }
        await listDirectory(for: selectedServerId, path: nextPath, serverManager: serverManager)
    }

    func navigateUp(selectedServerId: String, serverManager: ServerManager) async {
        var nextPath = (currentPath as NSString).deletingLastPathComponent
        if nextPath.isEmpty { nextPath = "/" }
        await listDirectory(for: selectedServerId, path: nextPath, serverManager: serverManager)
    }

    func navigateToPath(_ path: String, selectedServerId: String, serverManager: ServerManager) async {
        await listDirectory(for: selectedServerId, path: path, serverManager: serverManager)
    }

    func applyPreviewSeed(_ seed: DirectoryPickerPreviewSeed, selectedServerId: String) {
        lastLoadedServerId = selectedServerId
        currentPath = seed.currentPath
        allEntries = seed.entries
        searchQuery = seed.searchQuery
        isLoading = seed.isLoading
        errorMessage = seed.errorMessage
    }

    private func resolveHome(for serverId: String, serverManager: ServerManager) async -> String {
        guard let connection = serverManager.connections[serverId], connection.isConnected else {
            return "/"
        }
        if connection.server.source == .local {
            return NSHomeDirectory()
        }
        do {
            let response = try await connection.execCommand(
                ["printenv", "HOME"],
                cwd: "/tmp"
            )
            if response.exitCode == 0 {
                let home = response.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if !home.isEmpty {
                    return home
                }
            }
        } catch {}
        return "/"
    }

    private func segments(for path: String) -> [DirectoryPathSegment] {
        let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty || normalized == "/" {
            return [DirectoryPathSegment(id: "/", label: "/", path: "/")]
        }

        var output: [DirectoryPathSegment] = [DirectoryPathSegment(id: "/", label: "/", path: "/")]
        var runningPath = ""
        for component in normalized.split(separator: "/").map(String.init).filter({ !$0.isEmpty }) {
            runningPath = runningPath.isEmpty ? "/\(component)" : "\(runningPath)/\(component)"
            output.append(DirectoryPathSegment(id: runningPath, label: component, path: runningPath))
        }
        return output
    }
}

struct DirectoryPickerView: View {
    let servers: [DirectoryPickerServerOption]
    @Binding var selectedServerId: String
    var onServerChanged: ((String) -> Void)?
    var onDirectorySelected: ((String, String) -> Void)?
    var previewSeed: DirectoryPickerPreviewSeed?

    @EnvironmentObject var serverManager: ServerManager
    @StateObject private var model = DirectoryPickerSheetModel()

    private var selectedServerOption: DirectoryPickerServerOption? {
        servers.first { $0.id == selectedServerId }
    }

    private var conn: ServerConnection? {
        serverManager.connections[selectedServerId]
    }

    private var canSelectPath: Bool {
        !model.currentPath.isEmpty && conn?.isConnected == true && selectedServerOption != nil
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                controls
                content
            }
        }
        .navigationTitle("Choose Directory")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: selectedServerId) {
            if let previewSeed {
                model.applyPreviewSeed(previewSeed, selectedServerId: selectedServerId)
                return
            }

            onServerChanged?(selectedServerId)
            model.handleServerSelectionChanged(selectedServerId)
            await model.loadInitialPath(
                selectedServerId: selectedServerId,
                serverManager: serverManager
            )
        }
        .onChange(of: servers.map(\.id)) { _, ids in
            if !ids.contains(selectedServerId), let fallback = ids.first {
                selectedServerId = fallback
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if servers.count > 1 {
                    Menu {
                        ForEach(servers) { server in
                            Button {
                                selectedServerId = server.id
                            } label: {
                                HStack {
                                    Text(server.name)
                                    if server.id == selectedServerId {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(selectedServerOption?.name ?? "Select server")
                                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundColor(MocodeTheme.textPrimary)
                    }
                }

                Spacer()
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(MocodeTheme.textMuted)

                TextField("Search folders", text: $model.searchQuery)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.subheadline, design: .rounded))

                if !model.trimmedSearchQuery.isEmpty {
                    Button {
                        model.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(MocodeTheme.textMuted)
                    }
                }

                Button {
                    onDirectorySelected?(selectedServerId, model.currentPath)
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(canSelectPath ? MocodeTheme.accent : MocodeTheme.textMuted.opacity(0.6))
                }
                .buttonStyle(.plain)
                .disabled(!canSelectPath)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .glassEffect(
                .regular,
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .stroke(MocodeTheme.border.opacity(0.28), lineWidth: 0.8)
            )

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.pathSegments()) { segment in
                        Button {
                            Task {
                                await model.navigateToPath(
                                    segment.path,
                                    selectedServerId: selectedServerId,
                                    serverManager: serverManager
                                )
                            }
                        } label: {
                            Text(segment.label)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(MocodeTheme.textSecondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(MocodeTheme.surface, in: Capsule())
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading {
            VStack {
                Spacer()
                ProgressView().tint(MocodeTheme.accent)
                Spacer()
            }
        } else if let errorMessage = model.errorMessage {
            VStack(spacing: 12) {
                Text(errorMessage)
                    .font(.system(.caption, design: .rounded))
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Button("Retry") {
                    Task {
                        await model.listDirectory(
                            for: selectedServerId,
                            path: model.currentPath.isEmpty ? "/" : model.currentPath,
                            serverManager: serverManager
                        )
                    }
                }
                .foregroundColor(MocodeTheme.accent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                List {
                    if model.canNavigateUp {
                        Button {
                            Task {
                                await model.navigateUp(
                                    selectedServerId: selectedServerId,
                                    serverManager: serverManager
                                )
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "arrow.turn.up.left")
                                    .foregroundColor(MocodeTheme.textSecondary)
                                    .frame(width: 20)
                                Text("..")
                                    .font(.system(.subheadline, design: .rounded))
                                    .foregroundColor(MocodeTheme.textSecondary)
                            }
                        }
                        .listRowBackground(Color.clear)
                    }

                    let entries = model.visibleEntries()
                    if entries.isEmpty {
                        HStack {
                            Spacer()
                            Text(model.emptyMessage())
                                .font(.system(.subheadline, design: .rounded))
                                .foregroundColor(MocodeTheme.textMuted)
                            Spacer()
                        }
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(entries, id: \.self) { entry in
                            Button {
                                Task {
                                    await model.navigateInto(
                                        entry,
                                        selectedServerId: selectedServerId,
                                        serverManager: serverManager
                                    )
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "folder.fill")
                                        .foregroundColor(MocodeTheme.accent)
                                        .frame(width: 20)
                                    Text(entry)
                                        .font(.system(.subheadline, design: .rounded))
                                        .foregroundColor(MocodeTheme.textPrimary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundColor(MocodeTheme.textMuted)
                                        .font(.caption)
                                }
                            }
                            .listRowBackground(Color.clear)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollDismissesKeyboard(.interactively)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 8)
            .glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(MocodeTheme.border.opacity(0.35), lineWidth: 0.8)
            )
            .padding(.horizontal, 18)
        }
    }
}

#Preview("Directory Picker") {
    NavigationStack {
        DirectoryPickerView(
            servers: [
                DirectoryPickerServerOption(id: "preview-server", name: "Preview Server", sourceLabel: "manual")
            ],
            selectedServerId: .constant("preview-server"),
            previewSeed: DirectoryPickerPreviewSeed(
                currentPath: "/workspace",
                entries: [
                    "apps",
                    "backend",
                    "design-system",
                    "experiments",
                    "ios-client",
                    "scripts",
                    "shared",
                    "tools"
                ]
            )
        )
        .environmentObject(ServerManager())
    }
}
