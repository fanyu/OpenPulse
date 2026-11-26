import SwiftUI
import AppKit

/// Local configuration and instruction files surfaced as quick-open links per tool.
struct ToolConfigFileEntry: Identifiable, Hashable, Sendable {
    let id: String
    let tool: Tool
    let displayName: String
    let url: URL

    var existsOnDisk: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static func entries(for tool: Tool, home: URL = .homeDirectory) -> [ToolConfigFileEntry] {
        switch tool {
        case .codex:
            [
                ToolConfigFileEntry(id: "codex-config", tool: .codex, displayName: "config.toml", url: home.appending(path: ".codex/config.toml")),
                ToolConfigFileEntry(id: "codex-agents", tool: .codex, displayName: "AGENTS.md", url: home.appending(path: ".codex/AGENTS.md")),
            ]
        case .claudeCode:
            [
                ToolConfigFileEntry(id: "claude-settings", tool: .claudeCode, displayName: "settings.json", url: home.appending(path: ".claude/settings.json")),
                ToolConfigFileEntry(id: "claude-md", tool: .claudeCode, displayName: "CLAUDE.md", url: home.appending(path: ".claude/CLAUDE.md")),
            ]
        case .antigravity:
            [
                ToolConfigFileEntry(id: "ag-settings", tool: .antigravity, displayName: "settings.json", url: home.appending(path: ".gemini/settings.json")),
                ToolConfigFileEntry(id: "ag-gemini-md", tool: .antigravity, displayName: "GEMINI.md", url: home.appending(path: ".gemini/GEMINI.md")),
            ]
        case .copilot:
            [
                ToolConfigFileEntry(id: "copilot-config", tool: .copilot, displayName: "config.json", url: home.appending(path: ".config/github-copilot/config.json")),
            ]
        }
    }
}

/// Account access, routing, and connection workspace for every supported AI coding tool.
struct ProviderView: View {
    @Environment(AppStore.self) private var appStore
    @AppStorage("menubar.toolOrder") private var toolOrderRaw = Tool.defaultOrderRaw
    @AppStorage("ag.hiddenAccountEmails") private var hiddenAGEmailsRaw = ""
    @State private var selectedProvider: Provider = .codex
    @State private var isWide = true
    @Namespace private var glassNamespace

    private var orderedProviders: [Provider] {
        Tool.orderedTools(from: toolOrderRaw).compactMap { Provider(rawValue: $0.rawValue) }
    }

    private var isSyncing: Bool { appStore.syncService?.isSyncingActive ?? false }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                // Page Header (unified with Quota, Overview, Activity)
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("接入")
                            .font(.system(size: 28, weight: .semibold))
                            .tracking(-0.4)
                        Text("管理工具账号、授权、智能切换与本地配置文件。")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 12)

                    GlassEffectContainer(spacing: 8) {
                        Button {
                            guard !isSyncing else { return }
                            Task { await appStore.syncService?.sync() }
                        } label: {
                            Group {
                                if isSyncing {
                                    ProgressView()
                                        .controlSize(.mini)
                                        .scaleEffect(0.8)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                            }
                            .frame(width: 30, height: 30)
                            .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .glassEffectID("providersRefresh", in: glassNamespace)
                        .focusEffectDisabled()
                        .keyboardShortcut("r", modifiers: .command)
                        .help(isSyncing ? String(localized: "同步中…") : String(localized: "刷新同步 (⌘R)"))
                        .accessibilityLabel("刷新同步")
                    }
                    .animation(.smooth(duration: 0.25), value: isSyncing)
                }

                // Responsive 4-Provider Visual Selector Strip (4 cols wide, 2x2 narrow)
                let selectorColumns = Array(
                    repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
                    count: isWide ? 4 : 2
                )
                LazyVGrid(columns: selectorColumns, spacing: 12) {
                    ForEach(orderedProviders) { provider in
                        ProviderSelectorCard(
                            provider: provider,
                            summary: providerSummary(for: provider),
                            isConnected: hasLiveData(for: provider),
                            isSelected: selectedProvider == provider
                        ) {
                            withAnimation(.smooth(duration: 0.22)) {
                                selectedProvider = provider
                            }
                        }
                    }
                }

                // Focused Workspace for Selected Provider
                VStack(alignment: .leading, spacing: 20) {
                    ProviderHeroCard(
                        provider: selectedProvider,
                        isConnected: hasLiveData(for: selectedProvider),
                        summary: providerSummary(for: selectedProvider)
                    )

                    switch selectedProvider {
                    case .claudeCode:
                        ClaudeProviderContent()
                    case .codex:
                        CodexProviderContent(appStore: appStore)
                    case .copilot:
                        CopilotProviderContent()
                    case .antigravity:
                        AntigravityProviderContent(appStore: appStore)
                    }

                    ToolConfigFilesCard(tool: selectedProvider.tool)
                }
                .id(selectedProvider)
                .transition(.opacity)
            }
            .frame(maxWidth: 1120, alignment: .leading)
            .padding(.horizontal, isWide ? 28 : 20)
            .padding(.top, 8)
            .padding(.bottom, 26)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollEdgeEffectStyle(.soft, for: .vertical)
        .onGeometryChange(for: Bool.self) { proxy in
            proxy.size.width >= 760
        } action: { next in
            if isWide != next { isWide = next }
        }
        .navigationTitle("接入")
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if let first = orderedProviders.first, !orderedProviders.contains(selectedProvider) {
                selectedProvider = first
            }
        }
    }

    private func hasLiveData(for provider: Provider) -> Bool {
        switch provider {
        case .codex:
            !(appStore.syncService?.latestCodexAccounts.isEmpty ?? true)
        case .claudeCode:
            appStore.syncService?.latestClaudeUsage != nil || appStore.syncService?.latestClaudeAccountInfo != nil
        case .copilot:
            appStore.syncService?.latestCopilotSnapshots != nil
        case .antigravity:
            !(appStore.syncService?.latestAntigravityAccounts?.isEmpty ?? true)
        }
    }

    private func providerSummary(for provider: Provider) -> String {
        switch provider {
        case .codex:
            let accounts = appStore.syncService?.latestCodexAccounts ?? []
            guard !accounts.isEmpty else { return String(localized: "未添加账号") }
            let countLabel = accountCountLabel(accounts.count)
            let current = accounts.first(where: \.isCurrent) ?? accounts.first
            if let pct = current?.limits?.fiveHourWindow?.remainingPercent
                ?? current?.limits?.oneWeekWindow?.remainingPercent {
                return "\(countLabel) · \(Int(pct.rounded()))%"
            }
            return countLabel
        case .claudeCode:
            let plan = appStore.syncService?.latestClaudeAccountInfo?.displaySubscriptionName
            let pct = appStore.syncService?.latestClaudeUsage?.effectiveRemainingPercent
            if let plan, let pct {
                return "\(plan) · \(pct)%"
            } else if let pct {
                return String(localized: "剩余 \(pct)%")
            } else if let plan {
                return plan
            }
            return String(localized: "本地自动同步")
        case .antigravity:
            let all = appStore.syncService?.latestAntigravityAccounts ?? []
            guard !all.isEmpty else { return String(localized: "等待授权") }
            let countLabel = accountCountLabel(all.count)
            let hidden = Set(hiddenAGEmailsRaw.components(separatedBy: ",").filter { !$0.isEmpty })
            let visible = all.filter { !hidden.contains($0.email) }
            if let pct = AGAccountQuota.effectiveMenuBarFiveHourPercent(across: visible) {
                return "\(countLabel) · \(pct)%"
            }
            return countLabel
        case .copilot:
            let pct = CopilotSnapshot.menuBarRemainingPercent(
                from: appStore.syncService?.latestCopilotSnapshots,
                resetAt: appStore.syncService?.latestCopilotResetAt
            )
            let plan = appStore.syncService?.latestCopilotPlan
            if let plan, !plan.isEmpty, let pct {
                return "\(plan.capitalized) · \(pct)%"
            } else if let pct {
                return String(localized: "剩余 \(pct)%")
            }
            return String(localized: "待配置 Token")
        }
    }

    private func accountCountLabel(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 个账号")
            : String(localized: "\(count) 个账号")
    }
}

// MARK: - Visual 4-Provider Selector Card

private struct ProviderSelectorCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let provider: Provider
    let summary: String
    let isConnected: Bool
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        let brand = provider.tool.brandAccentColor(for: colorScheme)
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)

        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    ToolBrandIconWell(tool: provider.tool, size: 32, iconSize: 18)
                    Spacer(minLength: 6)
                    Circle()
                        .fill(
                            isConnected
                                ? brand
                                : Color.primary.opacity(colorScheme == .dark ? 0.20 : 0.14)
                        )
                        .frame(width: 6.5, height: 6.5)
                        .shadow(color: isConnected ? brand.opacity(0.45) : .clear, radius: 2.5)
                        .padding(.top, 3)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.displayName)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(summary)
                        .font(.system(size: 11.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? brand : .secondary)
                        .lineLimit(1)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: 102, alignment: .topLeading)
            .background {
                ZStack(alignment: .topLeading) {
                    shape
                        .fill(
                            Color(nsColor: .controlBackgroundColor)
                                .opacity(colorScheme == .dark ? 0.78 : 0.94)
                        )
                    if isSelected {
                        RadialGradient(
                            colors: [
                                brand.opacity(colorScheme == .dark ? 0.22 : 0.12),
                                brand.opacity(colorScheme == .dark ? 0.05 : 0.025),
                                Color.clear
                            ],
                            center: UnitPoint(x: 0.08, y: 0.0),
                            startRadius: 4,
                            endRadius: 180
                        )
                    } else if isHovered {
                        shape.fill(Color.primary.opacity(colorScheme == .dark ? 0.04 : 0.02))
                    } else {
                        LinearGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.035 : 0.50),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .center
                        )
                    }
                }
            }
            .clipShape(shape)
            .overlay {
                shape
                    .strokeBorder(
                        isSelected
                            ? brand.opacity(colorScheme == .dark ? 0.72 : 0.62)
                            : Color.primary.opacity(isHovered ? 0.16 : 0.09),
                        lineWidth: isSelected ? 1.25 : 0.75
                    )
            }
            .shadow(
                color: isSelected
                    ? brand.opacity(colorScheme == .dark ? 0.18 : 0.09)
                    : Color.black.opacity(colorScheme == .dark ? 0.18 : 0.035),
                radius: isSelected ? 6 : 4,
                x: 0,
                y: 2
            )
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Provider Hero Banner Card

private struct ProviderHeroCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let provider: Provider
    let isConnected: Bool
    let summary: String

    private var subtitle: LocalizedStringKey {
        switch provider {
        case .codex:
            "管理多个 OpenAI 账号与额度智能切换策略。"
        case .claudeCode:
            "自动读取本地对话日志与订阅配额，无需手动配置密钥。"
        case .antigravity:
            "管理 Google OAuth 与本地代理账号，控制菜单栏展示范围。"
        case .copilot:
            "通过 GitHub OAuth Token 同步 Copilot 高级交互额度与订阅计划。"
        }
    }

    var body: some View {
        let brand = provider.tool.brandAccentColor(for: colorScheme)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                ToolBrandIconWell(tool: provider.tool, size: 42, iconSize: 24)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Text(provider.displayName)
                            .font(.system(size: 18, weight: .semibold))
                        Label(
                            isConnected ? String(localized: "已连接") : String(localized: "等待数据"),
                            systemImage: isConnected ? "checkmark.circle.fill" : "clock"
                        )
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isConnected ? brand : .secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3.5)
                        .background(
                            (isConnected ? brand : Color.primary).opacity(colorScheme == .dark ? 0.16 : 0.09),
                            in: Capsule()
                        )
                    }
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Text(summary)
                    .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(isConnected ? .primary : .secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.04),
                        in: Capsule()
                    )
            }

            TelemetryHairline()

            HStack(spacing: 8) {
                Image(systemName: "externaldrive")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text("数据源")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(provider.dataSourcePath)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
        }
        .padding(20)
        .dashboardSurface(cornerRadius: 16, accent: brand)
    }
}

// MARK: - Local Config Files Card

private struct ToolConfigFilesCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let tool: Tool

    var body: some View {
        let entries = ToolConfigFileEntry.entries(for: tool)
        SettingsCard(
            title: "本地配置文件",
            subtitle: "使用系统默认编辑器快速打开，或在 Finder 中定位对应目录。"
        ) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 280), spacing: 12)],
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(entries) { entry in
                    let exists = entry.existsOnDisk
                    HStack(spacing: 10) {
                        Circle()
                            .fill(exists ? Color.green.opacity(0.85) : Color.secondary.opacity(0.32))
                            .frame(width: 7, height: 7)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.displayName)
                                .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                            Text(abbreviatedPath(entry.url))
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer(minLength: 8)

                        Button("打开") {
                            NSWorkspace.shared.open(entry.url)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!exists)
                        .help(exists ? String(localized: "使用默认编辑器打开") : String(localized: "文件尚未创建"))

                        Button {
                            revealInFinder(entry.url, exists: exists)
                        } label: {
                            Image(systemName: "folder")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("在 Finder 中显示")
                        .accessibilityLabel("在 Finder 中显示")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        Color.primary.opacity(colorScheme == .dark ? 0.045 : 0.025),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.75)
                    }
                }
            }
        }
    }

    private func abbreviatedPath(_ url: URL) -> String {
        let home = URL.homeDirectory.path
        if url.path.hasPrefix(home) {
            return "~" + url.path.dropFirst(home.count)
        }
        return url.path
    }

    private func revealInFinder(_ url: URL, exists: Bool) {
        if exists {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            let parent = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: parent.path) {
                NSWorkspace.shared.open(parent)
            }
        }
    }
}
