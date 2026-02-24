import SwiftUI
import PhotosUI
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
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var attachedImage: UIImage?
    @State private var showModelSelector = false

    private var messages: [ChatMessage] {
        serverManager.activeThread?.messages ?? []
    }

    private var threadStatus: ConversationStatus {
        serverManager.activeThread?.status ?? .idle
    }

    private var activeConn: ServerConnection? {
        serverManager.activeConnection
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
            Task { await loadModelsIfNeeded() }
        }
        .task {
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
        let command = text.dropFirst()
            .split(separator: " ", maxSplits: 1).first
            .map { String($0).lowercased() } ?? ""

        switch command {
        case "mcp", "plugin", "plugins":
            appState.showMcpServers = true
        case "skills", "skill":
            appState.showSkills = true
        case "settings":
            appState.showSettings = true
        default:
            let msg = ChatMessage(
                role: .system,
                text: "Unknown command: /\(command). Available commands: /plugins, /skills, /mcp, /settings"
            )
            serverManager.activeThread?.messages.append(msg)
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(messages) { message in
                        MessageBubbleView(message: message)
                            .id(message.id)
                    }
                    if case .thinking = threadStatus {
                        TypingIndicator()
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 8)
            }
            .onTapGesture { inputFocused = false }
            .onChange(of: messages.count) {
                withAnimation { proxy.scrollTo("bottom") }
            }
        }
    }

    private var hasText: Bool {
        !inputText.trimmingCharacters(in: .whitespaces).isEmpty
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

            HStack(alignment: .bottom, spacing: 8) {
                Button { showAttachMenu = true } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(MocodeTheme.textSecondary)
                        .frame(width: 42, height: 42)
                }
                .glassEffect(.regular.interactive(), in: .circle)

                HStack(alignment: .bottom, spacing: 0) {
                    TextField("Message mocode...", text: $inputText, axis: .vertical)
                        .font(.system(size: 16))
                        .foregroundColor(MocodeTheme.textPrimary)
                        .lineLimit(1...5)
                        .focused($inputFocused)
                        .padding(.leading, 14)
                        .padding(.vertical, 12)

                    if hasText {
                        Button {
                            let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { return }
                            inputText = ""
                            attachedImage = nil

                            if text.hasPrefix("/") {
                                handleSlashCommand(text)
                            } else {
                                let model = appState.selectedModel.isEmpty ? nil : appState.selectedModel
                                let effort = appState.reasoningEffort
                                Task { await serverManager.send(text, cwd: workDir, model: model, effort: effort) }
                            }
                        } label: {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(MocodeTheme.accentForeground)
                                .frame(width: 32, height: 32)
                                .background(MocodeTheme.accent, in: Circle())
                        }
                        .padding(.trailing, 5)
                        .padding(.bottom, 5)
                    }
                }
                .glassEffect(.regular, in: .capsule)
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
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhoto, matching: .images)
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    attachedImage = img
                }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraView(image: $attachedImage)
                .ignoresSafeArea()
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
        !inputText.trimmingCharacters(in: .whitespaces).isEmpty
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

                HStack(alignment: .bottom, spacing: 0) {
                    TextField("Message mocode...", text: $inputText, axis: .vertical)
                        .font(.system(size: 16))
                        .foregroundColor(MocodeTheme.textPrimary)
                        .lineLimit(1...5)
                        .padding(.leading, 14)
                        .padding(.vertical, 12)

                    if hasText {
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
                        .padding(.trailing, 5)
                        .padding(.bottom, 5)
                    }
                }
                .glassEffect(.regular, in: .capsule)
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
