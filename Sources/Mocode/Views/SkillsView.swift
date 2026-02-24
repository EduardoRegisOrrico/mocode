import SwiftUI

struct SkillsView: View {
    @EnvironmentObject var serverManager: ServerManager
    @Environment(\.dismiss) private var dismiss
    @State private var expandedSkill: String?
    @State private var isReloading = false

    private struct ProviderSkillGroup: Identifiable {
        let provider: String
        let skills: [SkillMetadata]
        let error: String?
        let unsupported: Bool

        var id: String { provider.lowercased() }
    }

    private var groupedSkills: [ProviderSkillGroup] {
        let skillsByProvider = Dictionary(grouping: serverManager.skills) { $0.provider }
        let resultsByProvider = Dictionary(grouping: serverManager.backendResults) { $0.provider }
        let providers = Set(skillsByProvider.keys).union(resultsByProvider.keys).sorted()
        return providers.map { provider in
            let rawSkills = skillsByProvider[provider] ?? []
            let dedupedSkills = dedupeSkillsForDisplay(rawSkills)
            let providerResults = resultsByProvider[provider] ?? []
            let unsupported = !providerResults.isEmpty && providerResults.allSatisfy(\.skillsUnsupported) && dedupedSkills.isEmpty
            let error = dedupedSkills.isEmpty ? providerResults.compactMap(\.skillsError).first : nil
            return ProviderSkillGroup(
                provider: provider,
                skills: dedupedSkills,
                error: error,
                unsupported: unsupported
            )
        }
    }

    private func dedupeSkillsForDisplay(_ skills: [SkillMetadata]) -> [SkillMetadata] {
        var seen = Set<String>()
        var output: [SkillMetadata] = []
        let sorted = skills.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        for skill in sorted {
            let handle = skillHandle(from: skill.path)
            let normalizedName = normalizedKey(skill.displayName)
            let normalizedSummary = normalizedKey(skill.summary)
            let normalizedScope = skill.scope.rawValue.lowercased()
            let key = !handle.isEmpty
                ? "handle:\(handle)"
                : "name:\(normalizedName)|summary:\(normalizedSummary)|scope:\(normalizedScope)"
            if seen.insert(key).inserted {
                output.append(skill)
            }
        }
        return output
    }

    private func skillHandle(from rawPath: String) -> String {
        let path = rawPath.replacingOccurrences(of: "\\", with: "/")

        if let skillsRange = path.range(of: "/skills/") {
            let tail = String(path[skillsRange.upperBound...])
            let collapsed = tail.replacingOccurrences(
                of: "/SKILL.md",
                with: "",
                options: [.caseInsensitive]
            )
            return normalizedKey(collapsed)
        }

        if let commandsRange = path.range(of: "/commands/") {
            let tail = String(path[commandsRange.upperBound...])
            let collapsed = tail.replacingOccurrences(
                of: ".md",
                with: "",
                options: [.caseInsensitive]
            )
            return normalizedKey(collapsed)
        }

        return ""
    }

    private func normalizedKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }

    var body: some View {
        NavigationStack {
            Group {
                if !serverManager.skillsLoaded {
                    loadingState
                } else if serverManager.skills.isEmpty && serverManager.backendResults.isEmpty {
                    emptyState
                } else {
                    skillList
                }
            }
            .navigationTitle("Skills")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(MocodeTheme.accent)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task {
                            isReloading = true
                            await serverManager.refreshSkills()
                            isReloading = false
                        }
                    } label: {
                        if isReloading {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .foregroundColor(MocodeTheme.accent)
                    .disabled(isReloading)
                }
            }
        }
        .task {
            if !serverManager.skillsLoaded {
                await serverManager.refreshSkills()
            }
        }
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .scaleEffect(1.2)
            Text("Loading skills…")
                .font(.system(.subheadline, design: .rounded))
                .foregroundColor(MocodeTheme.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundColor(MocodeTheme.textMuted)
            Text("No skills available")
                .font(.system(.headline, design: .rounded))
                .foregroundColor(MocodeTheme.textPrimary)
            Text("Skills are loaded from your app-server configuration.")
                .font(.system(.footnote, design: .rounded))
                .foregroundColor(MocodeTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                Task {
                    isReloading = true
                    await serverManager.refreshSkills()
                    isReloading = false
                }
            } label: {
                HStack(spacing: 6) {
                    if isReloading {
                        ProgressView().scaleEffect(0.7).tint(MocodeTheme.accentForeground)
                    }
                    Text("Reload")
                        .font(.system(.subheadline, design: .rounded))
                }
                .foregroundColor(MocodeTheme.accentForeground)
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .background(MocodeTheme.accent)
                .cornerRadius(8)
            }
            .disabled(isReloading)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Skill List

    private var skillList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(groupedSkills) { group in
                    sectionHeader(group.provider, count: group.skills.count, error: group.error, unsupported: group.unsupported)
                    if group.skills.isEmpty {
                        emptySection(error: group.error, unsupported: group.unsupported)
                    } else {
                        ForEach(group.skills) { skill in
                            skillRow(skill)
                            if skill.id != group.skills.last?.id {
                                Divider().background(MocodeTheme.surfaceLight)
                                    .padding(.horizontal, 16)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func sectionHeader(_ provider: String, count: Int, error: String?, unsupported: Bool) -> some View {
        HStack(spacing: 6) {
            providerIcon(provider)
            Text(provider)
                .font(.system(.caption, design: .rounded).bold())
                .foregroundColor(MocodeTheme.textSecondary)
                .textCase(.uppercase)
            Spacer()
            if unsupported {
                Text("not supported")
                    .font(.system(.caption2, design: .rounded).bold())
                    .foregroundColor(MocodeTheme.textMuted)
            } else if let error {
                Text("error")
                    .font(.system(.caption2, design: .rounded).bold())
                    .foregroundColor(Color(hex: "#FF5555"))
            } else {
                Text("\(count) skill\(count == 1 ? "" : "s")")
                    .font(.system(.caption2, design: .rounded))
                    .foregroundColor(MocodeTheme.textMuted)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 6)
    }

    private func emptySection(error: String?, unsupported: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if unsupported {
                Text("Skills listing is not available for this backend")
                    .font(.system(.caption, design: .rounded))
                    .foregroundColor(MocodeTheme.textMuted)
            } else if let error {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundColor(Color(hex: "#FF5555"))
                    Text(error)
                        .font(.system(.caption, design: .rounded))
                        .foregroundColor(Color(hex: "#FF5555"))
                        .lineLimit(3)
                }
            } else {
                Text("No skills available")
                    .font(.system(.caption, design: .rounded))
                    .foregroundColor(MocodeTheme.textMuted)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func providerIcon(_ provider: String) -> some View {
        switch provider.lowercased() {
        case "claude":
            ProviderLogoView(brand: .claude, size: 12, tint: Color(hex: "#D86D22"))
        case "codex":
            ProviderLogoView(brand: .openAI, size: 12, tint: MocodeTheme.accent)
        default:
            Image(systemName: "server.rack")
                .font(.system(size: 10))
                .foregroundColor(MocodeTheme.textMuted)
        }
    }

    private func skillRow(_ skill: SkillMetadata) -> some View {
        let isExpanded = expandedSkill == skill.id
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedSkill = isExpanded ? nil : skill.id
                }
            } label: {
                HStack(spacing: 12) {
                    skillIcon(skill)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(skill.displayName)
                                .font(.system(.subheadline, design: .rounded))
                                .foregroundColor(MocodeTheme.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            scopeBadge(skill.scope)
                        }
                        if !skill.summary.isEmpty {
                            Text(skill.summary)
                                .font(.system(.caption2, design: .rounded))
                                .foregroundColor(MocodeTheme.textMuted)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                    if !skill.enabled {
                        Text("Disabled")
                            .font(.system(.caption2, design: .rounded).bold())
                            .foregroundColor(MocodeTheme.textMuted)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(MocodeTheme.surfaceLight)
                            .cornerRadius(4)
                    }
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundColor(MocodeTheme.textMuted)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                expandedContent(skill)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder
    private func skillIcon(_ skill: SkillMetadata) -> some View {
        if let color = skill.interface?.brandColor, !color.isEmpty {
            Image(systemName: "sparkles")
                .font(.system(size: 14))
                .foregroundColor(Color(hex: color))
        } else {
            Image(systemName: "sparkles")
                .font(.system(size: 14))
                .foregroundColor(MocodeTheme.accent)
        }
    }

    private func scopeBadge(_ scope: SkillScope) -> some View {
        Group {
            switch scope {
            case .system, .admin:
                Text(scope.rawValue)
                    .font(.system(.caption2, design: .rounded))
                    .foregroundColor(MocodeTheme.textMuted)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(MocodeTheme.surfaceLight)
                    .cornerRadius(3)
            case .user, .repo:
                EmptyView()
            }
        }
    }

    private func expandedContent(_ skill: SkillMetadata) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !skill.description.isEmpty {
                Text(skill.description)
                    .font(.system(.caption, design: .rounded))
                    .foregroundColor(MocodeTheme.textSecondary)
            }

            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.caption2)
                Text(skill.path)
                    .font(.system(.caption2, design: .monospaced))
                    .lineLimit(1)
            }
            .foregroundColor(MocodeTheme.textMuted)

            if let prompt = skill.interface?.defaultPrompt, !prompt.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Default prompt")
                        .font(.system(.caption2, design: .rounded).bold())
                        .foregroundColor(MocodeTheme.textSecondary)
                    Text(prompt)
                        .font(.system(.caption, design: .rounded))
                        .foregroundColor(MocodeTheme.textPrimary)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(MocodeTheme.surfaceLight)
                        .cornerRadius(6)
                }
            }
        }
        .padding(.leading, 36)
    }
}

// MARK: - Previews

#Preview("Skills - Loading") {
    SkillsView()
        .environmentObject(ServerManager())
}

#Preview("Skills - Empty") {
    let manager = ServerManager()
    manager.skillsLoaded = true
    return SkillsView()
        .environmentObject(manager)
}
