import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import Inject

struct ConversationView: View {
    @ObserveInjection var inject
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var appState: AppState
    @State private var inputText = ""
    @FocusState private var inputFocused: Bool
    @AppStorage("workDir") private var workDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "/"
    @State private var showAttachMenu = false
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var showFileImporter = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var attachedImage: UIImage?
    @State private var attachedFiles: [ComposerAttachedFile] = []
    @State private var showModelSelector = false
    @State private var isNearBottom = true
    @State private var unreadSinceAway = 0
    @State private var didInitialScroll = false
    @State private var pinchStartScale: CGFloat?
    @State private var showZoomHUD = false
    @State private var zoomHUDTask: Task<Void, Never>?
    @State private var composerAttachmentError: String?

    private struct ComposerAttachedFile: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let path: String
        let size: Int64
    }

    private var messages: [ChatMessage] {
        serverManager.activeThread?.messages ?? []
    }

    private var threadStatus: ConversationStatus {
        serverManager.activeThread?.status ?? .idle
    }

    private var activeConn: ServerConnection? {
        serverManager.activeConnection
    }

    private var effectiveCwd: String {
        if let cwd = serverManager.activeThread?.cwd, !cwd.isEmpty {
            return cwd
        }
        if !appState.currentCwd.isEmpty {
            return appState.currentCwd
        }
        return workDir
    }

    private var shortModelName: String {
        if appState.selectedModel.isEmpty { return "" }
        return appState.selectedModel
            .replacingOccurrences(of: "gpt-", with: "")
            .replacingOccurrences(of: "-codex", with: "")
    }

    private var backendBadge: (brand: ProviderBrand, label: String, color: Color)? {
        guard let conn = activeConn else { return nil }
        switch conn.serverType {
        case .claude:
            return (.claude, "Claude", Color(hex: "#D86D22"))
        case .codex:
            return (.openAI, "OpenAI", MocodeTheme.accent)
        case .unknown:
            return nil
        }
    }

    var body: some View {
        messageList
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                inputBar
            }
            .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button { showModelSelector = true } label: {
                    HStack(spacing: 6) {
                        Text(shortModelName.isEmpty ? "mocode" : shortModelName)
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundColor(MocodeTheme.textPrimary)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(MocodeTheme.textMuted)
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 8) {
                    if let badge = backendBadge {
                        HStack(spacing: 4) {
                            ProviderLogoView(brand: badge.brand, size: 12, tint: badge.color)
                            Text(badge.label)
                                .font(.system(.caption2, weight: .semibold))
                        }
                        .foregroundColor(badge.color)
                    }
                    statusGlyph
                }
            }
        }
        .onChange(of: serverManager.activeThreadKey) { _, _ in
            syncWorkDirFromActiveThread()
            didInitialScroll = false
            unreadSinceAway = 0
            isNearBottom = true
            Task { await loadModelsIfNeeded() }
        }
        .task {
            syncWorkDirFromActiveThread()
            await loadModelsIfNeeded()
        }
        .sheet(isPresented: $showModelSelector) {
            ModelSelectorView()
                .environmentObject(serverManager)
                .environmentObject(appState)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $appState.showMcpServers) {
            McpServersView()
                .environmentObject(serverManager)
                .onAppear {
                    serverManager.mcpServersLoaded = false
                    serverManager.mcpServers = []
                }
        }
        .sheet(isPresented: $appState.showSkills) {
            SkillsView()
                .environmentObject(serverManager)
                .onAppear {
                    serverManager.skillsLoaded = false
                    serverManager.skills = []
                }
        }
        .sheet(isPresented: $appState.showSettings) {
            SettingsView()
                .environmentObject(serverManager)
                .environmentObject(appState)
        }
        .enableInjection()
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch threadStatus {
        case .idle:
            Circle()
                .fill(serverManager.hasAnyConnection ? Color.green : MocodeTheme.textMuted)
                .frame(width: 7, height: 7)
        case .connecting:
            Circle()
                .fill(Color.orange)
                .frame(width: 7, height: 7)
        case .ready:
            Circle()
                .fill(Color.green)
                .frame(width: 7, height: 7)
        case .thinking:
            ProgressView()
                .scaleEffect(0.55)
                .tint(MocodeTheme.accent)
                .frame(width: 10, height: 10)
        case .error:
            Circle()
                .fill(Color.red)
                .frame(width: 7, height: 7)
        }
    }

    private func loadModelsIfNeeded() async {
        guard let conn = activeConn, conn.isConnected else { return }
        if !conn.modelsLoaded {
            do {
                let resp = try await conn.listModels()
                conn.models = resp.data
                conn.modelsLoaded = true
            } catch { return }
        }
        if !conn.models.contains(where: { $0.id == appState.selectedModel }) {
            if let defaultModel = conn.models.first(where: { $0.isDefault }) ?? conn.models.first {
                appState.selectedModel = defaultModel.id
                appState.reasoningEffort = defaultModel.defaultReasoningEffort
            }
        }
    }

    private func handleSlashCommand(_ text: String) {
        let remainder = text.dropFirst()
        let command = remainder
            .split(separator: " ", maxSplits: 1).first
            .map { String($0).lowercased() } ?? ""
        let query = remainder
            .split(separator: " ", maxSplits: 1)
            .dropFirst()
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        switch command {
        case "mcp", "plugin", "plugins":
            appState.showMcpServers = true
        case "skills", "skill":
            appState.showSkills = true
        case "settings":
            appState.showSettings = true
        case "files", "file", "search":
            guard !query.isEmpty else {
                let msg = ChatMessage(
                    role: .system,
                    text: "### File Search\nUsage: /files <query>"
                )
                serverManager.activeThread?.messages.append(msg)
                return
            }
            Task { await performFileSearch(query) }
        default:
            let msg = ChatMessage(
                role: .system,
                text: "Unknown command: /\(command). Available commands: /plugins, /skills, /mcp, /settings, /files"
            )
            serverManager.activeThread?.messages.append(msg)
        }
    }

    private func performFileSearch(_ query: String) async {
        guard let conn = activeConn, conn.isConnected else {
            serverManager.activeThread?.messages.append(
                ChatMessage(role: .system, text: "### File Search\nNot connected to a server.")
            )
            return
        }
        do {
            let root = effectiveCwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "/" : effectiveCwd
            let response = try await conn.fuzzyFileSearch(
                query: query,
                roots: [root],
                cancellationToken: "ios-composer-file-search"
            )
            let files = response.files.prefix(20).map { "- \($0.path)" }
            let body: String
            if files.isEmpty {
                body = "Query: \(query)\n\nNo files found."
            } else {
                body = "Query: \(query)\n\n\(files.joined(separator: "\n"))"
            }
            serverManager.activeThread?.messages.append(
                ChatMessage(role: .system, text: "### File Search\n\(body)")
            )
        } catch {
            serverManager.activeThread?.messages.append(
                ChatMessage(role: .system, text: "### File Search\nQuery: \(query)\n\nError: \(error.localizedDescription)")
            )
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(messages) { message in
                            MessageBubbleView(message: message)
                                .id(message.id)
                        }
                        if case .thinking = threadStatus {
                            TypingIndicator()
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                            .onAppear { isNearBottom = true }
                            .onDisappear { isNearBottom = false }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                }
                .onTapGesture { inputFocused = false }
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            if pinchStartScale == nil {
                                pinchStartScale = appState.chatTextScale
                            }
                            let base = pinchStartScale ?? appState.chatTextScale
                            appState.chatTextScale = min(max(base * value, 0.8), 1.8)
                            showZoomHUD = true
                            zoomHUDTask?.cancel()
                        }
                        .onEnded { _ in
                            pinchStartScale = nil
                            zoomHUDTask?.cancel()
                            zoomHUDTask = Task {
                                try? await Task.sleep(for: .milliseconds(700))
                                await MainActor.run {
                                    withAnimation(.easeOut(duration: 0.18)) {
                                        showZoomHUD = false
                                    }
                                }
                            }
                        }
                )
                .task(id: serverManager.activeThreadKey) {
                    // Ensure the first render of a loaded thread lands on latest.
                    guard !didInitialScroll else { return }
                    try? await Task.sleep(for: .milliseconds(80))
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    didInitialScroll = true
                }
                .onChange(of: messages.count) {
                    if isNearBottom {
                        unreadSinceAway = 0
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    } else {
                        unreadSinceAway += 1
                    }
                }

                if !isNearBottom && !messages.isEmpty {
                    Button {
                        unreadSinceAway = 0
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(unreadSinceAway > 0 ? "Latest (\(unreadSinceAway))" : "Latest")
                                .font(.system(.caption, weight: .semibold))
                            Image(systemName: "arrow.down")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .foregroundColor(MocodeTheme.accentForeground)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(MocodeTheme.accent, in: Capsule())
                    }
                    .padding(.trailing, 18)
                    .padding(.bottom, 14)
                }
                
                if showZoomHUD {
                    Text("\(Int((appState.chatTextScale * 100).rounded()))%")
                        .font(.system(.caption, weight: .semibold))
                        .foregroundColor(MocodeTheme.accentForeground)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(MocodeTheme.accent.opacity(0.95), in: Capsule())
                        .padding(.trailing, 18)
                        .padding(.bottom, isNearBottom ? 14 : 54)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
        }
    }

    private var hasText: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasAttachment: Bool {
        attachedImage != nil || !attachedFiles.isEmpty
    }

    private var canSend: Bool {
        hasText || hasAttachment
    }

    private var usesExpandedInputShape: Bool {
        inputText.contains("\n") || inputText.count > 42
    }

    private var inputBubbleCornerRadius: CGFloat {
        usesExpandedInputShape ? 18 : 24
    }

    private var inputBar: some View {
        VStack(spacing: 8) {
            if let img = attachedImage {
                HStack {
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 68, height: 68)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        Button {
                            attachedImage = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(.body))
                                .foregroundColor(MocodeTheme.textPrimary)
                                .background(Circle().fill(MocodeTheme.card.opacity(0.88)))
                        }
                        .offset(x: 4, y: -4)
                    }
                    Spacer()
                }
            }

            if !attachedFiles.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachedFiles) { file in
                            HStack(spacing: 6) {
                                Image(systemName: "doc")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(MocodeTheme.textSecondary)
                                Text(file.name)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(MocodeTheme.textPrimary)
                                    .lineLimit(1)
                                Text(fileSizeLabel(file.size))
                                    .font(.system(size: 11, design: .rounded))
                                    .foregroundColor(MocodeTheme.textMuted)
                                Button {
                                    removeAttachedFile(file)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 13))
                                        .foregroundColor(MocodeTheme.textMuted)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(MocodeTheme.surface.opacity(0.9), in: Capsule())
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                Button { showAttachMenu = true } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(MocodeTheme.textSecondary)
                        .frame(width: 42, height: 42)
                }
                .glassEffect(.regular.interactive(), in: .circle)

                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Message mocode...", text: $inputText, axis: .vertical)
                        .font(.system(size: 16))
                        .foregroundColor(MocodeTheme.textPrimary)
                        .lineLimit(1...5)
                        .focused($inputFocused)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 14)
                        .padding(.vertical, 12)
                        .padding(.trailing, 2)

                    Button {
                        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard canSend else { return }

                        if text.hasPrefix("/") && !hasAttachment {
                            inputText = ""
                            handleSlashCommand(text)
                        } else {
                            let additionalInput = buildAdditionalInputs()
                            let effectiveText = text.isEmpty ? "Attached files" : text
                            inputText = ""
                            attachedImage = nil
                            attachedFiles.removeAll()
                            let model = appState.selectedModel.isEmpty ? nil : appState.selectedModel
                            let effort = appState.reasoningEffort
                            Task {
                                await serverManager.send(
                                    effectiveText,
                                    additionalInput: additionalInput,
                                    cwd: effectiveCwd,
                                    model: model,
                                    effort: effort,
                                    approvalPolicy: appState.resolvedApprovalPolicy,
                                    sandboxMode: appState.resolvedSandboxMode
                                )
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(MocodeTheme.accentForeground)
                            .frame(width: 32, height: 32)
                            .background(MocodeTheme.accent, in: Circle())
                    }
                    .opacity(canSend ? 1 : 0.45)
                    .disabled(!canSend)
                    .padding(.trailing, 8)
                    .padding(.bottom, 6)
                }
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: inputBubbleCornerRadius, style: .continuous))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity)
        .confirmationDialog("Attach", isPresented: $showAttachMenu) {
            Button("Photo Library") { showPhotoPicker = true }
            Button("Take Photo") { showCamera = true }
            Button("File") { showFileImporter = true }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhoto, matching: .images)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            importFiles(result: result)
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    attachedImage = img
                }
            }
        }
        .alert("Attachment Error", isPresented: Binding(
            get: { composerAttachmentError != nil },
            set: { if !$0 { composerAttachmentError = nil } }
        )) {
            Button("OK", role: .cancel) { composerAttachmentError = nil }
        } message: {
            Text(composerAttachmentError ?? "Unknown attachment error")
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraView(image: $attachedImage)
                .ignoresSafeArea()
        }
    }

    private func fileSizeLabel(_ size: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private func removeAttachedFile(_ file: ComposerAttachedFile) {
        attachedFiles.removeAll { $0.id == file.id }
        try? FileManager.default.removeItem(atPath: file.path)
    }

    private func buildAdditionalInputs() -> [UserInput] {
        var inputs: [UserInput] = []

        if let image = attachedImage, let localImageInput = persistImageAttachment(image) {
            inputs.append(localImageInput)
        }

        for file in attachedFiles {
            inputs.append(UserInput(type: "mention", path: file.path, name: file.name))
        }

        return inputs
    }

    private func persistImageAttachment(_ image: UIImage) -> UserInput? {
        guard let directory = ensureComposerAttachmentDirectory() else { return nil }
        let imageData = image.jpegData(compressionQuality: 0.9) ?? image.pngData()
        guard let imageData else { return nil }
        let filename = "image-\(UUID().uuidString.prefix(8)).jpg"
        let destination = directory.appendingPathComponent(filename)
        do {
            try imageData.write(to: destination, options: [.atomic])
            return UserInput(type: "localImage", path: destination.path, name: filename)
        } catch {
            composerAttachmentError = "Failed to prepare image attachment."
            return nil
        }
    }

    private func importFiles(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            for url in urls {
                if let copied = copyFileToComposerAttachments(url) {
                    attachedFiles.append(copied)
                }
            }
        case .failure(let error):
            composerAttachmentError = error.localizedDescription
        }
    }

    private func copyFileToComposerAttachments(_ sourceURL: URL) -> ComposerAttachedFile? {
        let accessGranted = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessGranted {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        guard let directory = ensureComposerAttachmentDirectory() else {
            composerAttachmentError = "Failed to access attachment storage."
            return nil
        }

        let fileName = sourceURL.lastPathComponent.isEmpty ? "file" : sourceURL.lastPathComponent
        let destination = directory.appendingPathComponent("\(UUID().uuidString)-\(fileName)")

        do {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
            let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            return ComposerAttachedFile(name: fileName, path: destination.path, size: fileSize)
        } catch {
            composerAttachmentError = "Failed to import \(fileName)."
            return nil
        }
    }

    private func ensureComposerAttachmentDirectory() -> URL? {
        guard let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = cache.appendingPathComponent("MocodeComposerAttachments", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        } catch {
            return nil
        }
    }

    private func syncWorkDirFromActiveThread() {
        guard let cwd = serverManager.activeThread?.cwd, !cwd.isEmpty else { return }
        if appState.currentCwd != cwd {
            appState.currentCwd = cwd
        }
        if workDir != cwd {
            workDir = cwd
        }
    }
}

struct TypingIndicator: View {
    @State private var phase = 0
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(MocodeTheme.accent)
                    .frame(width: 6, height: 6)
                    .opacity(phase == i ? 1 : 0.3)
            }
        }
        .padding(.leading, 12)
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
                withAnimation { phase = (phase + 1) % 3 }
            }
        }
    }
}

// MARK: - Chat Input Bar (Extracted for Preview)

struct ChatInputBar: View {
    @Binding var inputText: String
    @Binding var attachedImage: UIImage?
    var onSend: (String) -> Void = { _ in }
    var onAttach: () -> Void = {}
    
    private var hasText: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var usesExpandedInputShape: Bool {
        inputText.contains("\n") || inputText.count > 42
    }

    private var inputBubbleCornerRadius: CGFloat {
        usesExpandedInputShape ? 18 : 24
    }
    
    var body: some View {
        VStack(spacing: 8) {
            if let img = attachedImage {
                HStack {
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 68, height: 68)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        Button {
                            attachedImage = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(.body))
                                .foregroundColor(MocodeTheme.textPrimary)
                                .background(Circle().fill(MocodeTheme.card.opacity(0.88)))
                        }
                        .offset(x: 4, y: -4)
                    }
                    Spacer()
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                Button { onAttach() } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(MocodeTheme.textSecondary)
                        .frame(width: 42, height: 42)
                }
                .glassEffect(.regular.interactive(), in: .circle)

                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Message mocode...", text: $inputText, axis: .vertical)
                        .font(.system(size: 16))
                        .foregroundColor(MocodeTheme.textPrimary)
                        .lineLimit(1...5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 14)
                        .padding(.vertical, 12)
                        .padding(.trailing, 2)

                    Button {
                        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        onSend(text)
                        inputText = ""
                        attachedImage = nil
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(MocodeTheme.accentForeground)
                            .frame(width: 32, height: 32)
                            .background(MocodeTheme.accent, in: Circle())
                    }
                    .opacity(hasText ? 1 : 0.45)
                    .disabled(!hasText)
                    .padding(.trailing, 8)
                    .padding(.bottom, 6)
                }
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: inputBubbleCornerRadius, style: .continuous))
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }
}

struct CameraView: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraView
        init(_ parent: CameraView) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage {
                parent.image = img
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

// MARK: - Previews

#Preview("Chat Input - Empty") {
    VStack {
        Spacer()
        ChatInputBar(
            inputText: .constant(""),
            attachedImage: .constant(nil)
        )
    }
    .background(Color(uiColor: .systemBackground))
}

#Preview("Chat Input - With Text") {
    VStack {
        Spacer()
        ChatInputBar(
            inputText: .constant("Hello, can you help me with SwiftUI?"),
            attachedImage: .constant(nil)
        )
    }
    .background(Color(uiColor: .systemBackground))
}

#Preview("Chat Input - Multiline") {
    VStack {
        Spacer()
        ChatInputBar(
            inputText: .constant("This is a longer message that spans multiple lines to show how the input field expands vertically when needed."),
            attachedImage: .constant(nil)
        )
    }
    .background(Color(uiColor: .systemBackground))
}

#Preview("Typing Indicator") {
    TypingIndicator()
        .padding()
}

#Preview("Conversation View") {
    NavigationStack {
        ConversationView()
            .environmentObject(ServerManager())
            .environmentObject(AppState())
    }
}
