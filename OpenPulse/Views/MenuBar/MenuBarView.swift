import SwiftUI
import SwiftData
import AppKit

struct MenuBarView: View {
    @Environment(AppStore.self) private var appStore
    @Query private var dailyStats: [DailyStatsRecord]
    @Query private var quotas: [QuotaRecord]
    @State private var logger = AppLogger.shared

    @AppStorage("menubar.toolOrder") private var toolOrderRaw = Tool.defaultOrderRaw
    @AppStorage("menubar.hiddenTools") private var hiddenToolsRaw = ""
    @AppStorage("menubar.antigravityDisplayMode") private var antigravityDisplayMode = "accounts"
    init() {
        // Only load today's aggregate stats — avoids scanning today's raw sessions
        // every time the menu bar popover is shown or refreshed.
        let start = Calendar.current.startOfDay(for: Date())
        _dailyStats = Query(filter: #Predicate<DailyStatsRecord> { $0.date >= start })
    }

    private var orderedVisibleTools: [Tool] {
        let hidden = Set(hiddenToolsRaw.components(separatedBy: ",").filter { !$0.isEmpty })
        let order = toolOrderRaw.components(separatedBy: ",").compactMap { Tool(rawValue: $0) }
        let ordered = order + Tool.allCases.filter { !order.contains($0) }
        return ordered.filter { !hidden.contains($0.rawValue) }
    }

    @State private var contentHeight: CGFloat = 0
    // Cached per-tool today token counts — one pass over today's aggregate stats only.
    @State private var todayTokensByTool: [Tool: Int] = [:]

    private func rebuildTodayTokens() {
        var map: [Tool: Int] = [:]
        for stats in dailyStats {
            map[stats.tool, default: 0] += stats.totalInputTokens + stats.totalOutputTokens
        }
        todayTokensByTool = map
    }

    private var todayTokens: Int { todayTokensByTool.values.reduce(0, +) }

    private var isSyncing: Bool { appStore.syncService?.isSyncingActive ?? false }
    private var lastSyncDate: Date? { appStore.syncService?.lastSyncDate ?? appStore.lastSyncDate }

    private var maxScrollHeight: CGFloat {
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        return max(300, screenHeight - 58 - 52 - 22 - 24)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider().opacity(0.3).padding(.horizontal)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(orderedVisibleTools, id: \.self) { tool in
                        toolCard(for: tool)
                    }
                }
                .padding(12)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: min(contentHeight, maxScrollHeight))
            .scrollIndicators(.hidden)
            Divider().opacity(0.3).padding(.horizontal)
            footerSection
        }
        .frame(width: 390)
        .background(MenuBarWindowCapture())
        .task { rebuildTodayTokens() }
        .onChange(of: dailyStats.count) { _, _ in rebuildTodayTokens() }
    }

    @ViewBuilder
    private func toolCard(for tool: Tool) -> some View {
        switch tool {
        case .claudeCode:
            ClaudeQuotaCard(
                usage: appStore.syncService?.latestClaudeUsage,
                quota: quotas.first(where: { $0.tool == .claudeCode }),
                accountInfo: appStore.syncService?.latestClaudeAccountInfo,
                todayTokens: todaySessionTokens(for: .claudeCode)
            )
        case .codex:
            if let accounts = appStore.syncService?.latestCodexAccounts, !accounts.isEmpty {
                CodexMultiAccountQuotaCard(
                    accounts: accounts,
                    todayTokens: todaySessionTokens(for: .codex)
                )
            } else {
                CodexQuotaCard(
                    limits: nil,
                    fallbackQuota: quotas.first(where: { $0.tool == .codex && $0.accountKey == nil }),
                    todayTokens: todaySessionTokens(for: .codex)
                )
            }
        case .copilot:
            CopilotQuotaCard(
                snapshots: appStore.syncService?.latestCopilotSnapshots,
                resetAt: appStore.syncService?.latestCopilotResetAt,
                plan: appStore.syncService?.latestCopilotPlan,
                fallbackQuota: quotas.first(where: { $0.tool == .copilot }),
                todayTokens: todaySessionTokens(for: .copilot)
            )
        case .antigravity:
            if let accounts = appStore.syncService?.latestAntigravityAccounts {
                if antigravityDisplayMode == "aggregate" {
                    AntigravityAggregateCard(
                        accounts: accounts,
                        todayTokens: todaySessionTokens(for: .antigravity)
                    )
                } else {
                    AntigravityMultiAccountCard(
                        accounts: accounts,
                        todayTokens: todaySessionTokens(for: .antigravity)
                    )
                }
            } else if let fallback = quotas.first(where: { $0.tool == .antigravity }) {
                AntigravityFallbackCard(
                    quota: fallback,
                    todayTokens: todaySessionTokens(for: .antigravity)
                )
            }
        }
    }

    private func todaySessionTokens(for tool: Tool) -> Int { todayTokensByTool[tool] ?? 0 }

    private var headerSection: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("OpenPulse")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                HStack(spacing: 4) {
                    if isSyncing {
                        ProgressView().controlSize(.mini).scaleEffect(0.8)
                        Text("同步中…").font(.caption2).foregroundStyle(.secondary)
                    } else {
                        let activeCount = orderedVisibleTools.filter { todayTokensByTool[$0] != nil }.count
                        Text("\(activeCount) 个工具")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        if todayTokens > 0 {
                            Text("·")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Text("Today \(todayTokens.compactTokenString)")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Spacer()
            HStack(spacing: 5) {
                ForEach(orderedVisibleTools, id: \.self) { tool in
                    let active = todayTokensByTool[tool] != nil
                    Circle()
                        .fill(active ? Color(tool.accentColorName) : Color.gray.opacity(0.2))
                        .frame(width: 6, height: 6)
                        .overlay {
                            if active {
                                Circle()
                                    .stroke(Color(tool.accentColorName).opacity(0.35), lineWidth: 2)
                                    .scaleEffect(1.6)
                            }
                        }
                }
            }
            .padding(.trailing, 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var footerSection: some View {
        HStack {
            if let lastSync = lastSyncDate {
                Text("更新于 \(lastSync, style: .relative)前")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                Text("尚未同步")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            if let err = appStore.syncService?.syncError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .help(syncErrorHelpText(fallback: err))
            }
            Spacer()
            HStack(spacing: 8) {
                Button(action: {
                    performMenuBarAction {
                        await appStore.syncService?.sync()
                    }
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("刷新同步 (⌘R)")
                .disabled(isSyncing)
                Button(action: {
                    performMenuBarAction {
                        WindowCoordinator.shared.showMainWindow()
                    }
                }) {
                    Image(systemName: "macwindow")
                }
                .keyboardShortcut("m", modifiers: .command)
                .help("打开主窗口 (⌘M)")
                Button(action: {
                    performMenuBarAction {
                        WindowCoordinator.shared.showMainWindow(select: .settings)
                    }
                }) {
                    Image(systemName: "gearshape")
                }
                .keyboardShortcut(",", modifiers: .command)
                .help("设置 (⌘,)")
                Button(action: {
                    performMenuBarAction {
                        NSApp.terminate(nil)
                    }
                }) {
                    Image(systemName: "power")
                }
                .keyboardShortcut("q", modifiers: .command)
                .help("退出 (⌘Q)")
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .labelStyle(.iconOnly)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func syncErrorHelpText(fallback: String) -> String {
        logger.latestPersistentSyncError?.summary ?? fallback
    }

    private func performMenuBarAction(_ action: @escaping @MainActor () async -> Void) {
        Task { @MainActor in
            GlobalHotkeyService.shared.closeMenuBar()
            await action()
        }
    }
}

private struct ConfigShortcutButton: View {
    let tool: Tool

    private var configFile: ConfigFile? { ConfigFile.primaryConfig(for: tool) }

    var body: some View {
        if let configFile {
            Button {
                GlobalHotkeyService.shared.closeMenuBar()
                if FileManager.default.fileExists(atPath: configFile.url.path) {
                    NSWorkspace.shared.open(configFile.url)
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([configFile.url.deletingLastPathComponent()])
                }
            } label: {
                Image(systemName: "document.badge.gearshape")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("打开 \(configFile.displayName)")
        }
    }
}

private struct MenuBarToolShell<Identity: View, Content: View>: View {
    let identity: Identity
    let content: Content

    init(@ViewBuilder identity: () -> Identity, @ViewBuilder content: () -> Content) {
        self.identity = identity()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            identity
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuBarCardSurface()
    }
}

private struct MenuBarToolIdentity<Accessory: View>: View {
    let tool: Tool
    let subtitle: String?
    let metaText: String?
    let todayTokens: Int
    let accessory: Accessory

    init(
        tool: Tool,
        subtitle: String? = nil,
        metaText: String? = nil,
        todayTokens: Int = 0,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.tool = tool
        self.subtitle = subtitle
        self.metaText = metaText
        self.todayTokens = todayTokens
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            HStack(spacing: 9) {
                ToolLogoImage(tool: tool, size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.displayName)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let metaText, !metaText.isEmpty {
                        Text(metaText)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            if todayTokens > 0 {
                TodayTokenBadge(tokens: todayTokens)
            }
            accessory
        }
    }
}

private struct MenuBarQuotaPanel: View {
    let title: String
    let fraction: Double?
    let primaryValue: String
    let countdown: String?
    let footer: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(primaryValue)
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)

            MenuBarResetLine(countdown: countdown)

            QuotaProgressBar(
                fraction: fraction,
                color: menuBarQuotaBarColor(fraction: fraction),
                height: 4,
                showsGlow: false
            )

            if let footer, !footer.isEmpty {
                Text(footer)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct MenuBarResetLine: View {
    let countdown: String?

    var body: some View {
        HStack(spacing: 5) {
            Text("Reset")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            Text(countdown ?? "—")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(countdown == nil ? .tertiary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.055), in: Capsule())
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

private func menuBarQuotaBarColor(fraction: Double?) -> Color {
    guard let fraction else { return Color.primary.opacity(0.18) }
    if fraction < 0.15 { return Color.red.opacity(0.72) }
    if fraction < 0.40 { return Color.orange.opacity(0.68) }
    return Color.green.opacity(0.68)
}

private func menuBarTimeOnlyResetString(for date: Date) -> String {
    date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
}

// MARK: - Claude Code

struct ClaudeQuotaCard: View {
    let usage: ClaudeUsageResponse?
    let quota: QuotaRecord?
    let accountInfo: ClaudeAccountInfo?
    let todayTokens: Int

    var body: some View {
        MenuBarToolShell {
            MenuBarToolIdentity(
                tool: .claudeCode,
                subtitle: accountInfo?.displaySubscriptionName,
                todayTokens: todayTokens
            ) {
                ConfigShortcutButton(tool: .claudeCode)
            }
        } content: {
            if let usage {
                HStack(spacing: 8) {
                    MenuBarQuotaPanel(
                        title: "5h",
                        fraction: usage.fiveHour?.utilization.map { max(0, min(1, (100 - $0) / 100)) },
                        primaryValue: usage.fiveHour?.utilization.map { "\(max(0, Int((100 - $0).rounded())))%" } ?? "—",
                        countdown: usage.fiveHour?.resetDate.map { menuBarTimeOnlyResetString(for: $0) },
                        footer: nil
                    )
                    MenuBarQuotaPanel(
                        title: "Weekly",
                        fraction: usage.sevenDay?.utilization.map { max(0, min(1, (100 - $0) / 100)) },
                        primaryValue: usage.sevenDay?.utilization.map { "\(max(0, Int((100 - $0).rounded())))%" } ?? "—",
                        countdown: usage.sevenDay?.resetDate.map { resetDateString(for: $0) },
                        footer: nil
                    )
                }
            } else if let q = quota, let r = q.remaining, let t = q.total, t > 0 {
                let frac = Double(r) / Double(t)
                let pct = Int((frac * 100).rounded())
                MenuBarQuotaPanel(
                    title: "5h",
                    fraction: frac,
                    primaryValue: "\(pct)%",
                    countdown: q.resetAt.map { menuBarTimeOnlyResetString(for: $0) } ?? q.toModel().resetCountdown,
                    footer: nil
                )
            } else {
                Text("Quota data unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // TODO: surface off-peak multiplier badge in UI when ClaudeOffPeakBadge is re-added
    private var claudeOffPeakBadgeText: String? {
        var calendar = Calendar(identifier: .gregorian)
        guard let pacificTimeZone = TimeZone(identifier: "America/Los_Angeles") else { return nil }
        calendar.timeZone = pacificTimeZone

        let now = Date()
        let weekday = calendar.component(.weekday, from: now) // 1 = Sunday, 7 = Saturday
        let hour = calendar.component(.hour, from: now)

        if weekday == 1 || weekday == 7 {
            return "2x weekend"
        }
        if hour < 5 || hour >= 11 {
            return "2x off-peak"
        }
        return nil
    }
}

// MARK: - Codex

struct CodexQuotaCard: View {
    @Environment(AppStore.self) private var appStore
    let limits: CodexRateLimits?
    let fallbackQuota: QuotaRecord?
    let todayTokens: Int
    @State private var statusMessage: String?
    var body: some View {
        MenuBarToolShell {
            MenuBarToolIdentity(
                tool: .codex,
                subtitle: normalizedSubscriptionDisplayName(limits?.planType),
                todayTokens: todayTokens
            ) {
                ConfigShortcutButton(tool: .codex)
            }
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(normalizedSubscriptionDisplayName(limits?.planType) ?? "Codex")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    CodexProviderMenuButton { message in
                        statusMessage = message
                    }
                }
                if let limits {
                    HStack(spacing: 8) {
                        codexPanel(label: "5h", window: limits.fiveHourWindow)
                        codexPanel(label: "Weekly", window: limits.oneWeekWindow)
                    }
                } else if let q = fallbackQuota, let r = q.remaining, let t = q.total {
                    let frac = Double(r) / Double(t)
                    let pct = Int((frac * 100).rounded())
                    MenuBarQuotaPanel(
                        title: "5h",
                        fraction: frac,
                        primaryValue: "\(pct)%",
                        countdown: q.resetAt.map { menuBarTimeOnlyResetString(for: $0) } ?? q.toModel().resetCountdown,
                        footer: nil
                    )
                }
                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func codexPanel(label: String, window: CodexWindow?) -> some View {
        let isStale = window?.resetDate.map { $0 < Date() } ?? false
        let fraction = isStale ? nil : window?.usedPercent.map { max(0, min(1, (100 - $0) / 100)) }
        let primary = isStale ? "—" : fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
        MenuBarQuotaPanel(
            title: label,
            fraction: fraction,
            primaryValue: primary,
            countdown: isStale ? nil : window?.resetDate.map { label == "5h" ? menuBarTimeOnlyResetString(for: $0) : resetDateString(for: $0) },
            footer: isStale ? "数据已过期" : nil
        )
    }
}

struct CodexAccountQuotaCard: View {
    let account: CodexAccountSnapshot
    let isSwitching: Bool
    let onSwitch: (String) -> Void
    let onProviderMessage: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(account.titleText)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if account.isCurrent {
                            Text("当前")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.12), in: Capsule())
                        }
                    }
                    if let subtitleText = account.subtitleText {
                        Text(subtitleText)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else if let metaText = account.metaText {
                        Text(metaText)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                if account.isCurrent {
                    CodexProviderMenuButton(onMessage: onProviderMessage)
                } else {
                    Button("切换") {
                        onSwitch(account.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(isSwitching)
                }
            }

            if let limits = account.limits {
                HStack(spacing: 8) {
                    accountPanel(label: "5h", window: limits.fiveHourWindow)
                    accountPanel(label: "Weekly", window: limits.oneWeekWindow)
                }
            } else if let error = account.usageError {
                Text(error).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("尚未获取配额").font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func accountPanel(label: String, window: CodexWindow?) -> some View {
        let isStale = window?.resetDate.map { $0 < Date() } ?? false
        let fraction = isStale ? nil : window?.usedPercent.map { max(0, min(1, (100 - $0) / 100)) }
        let primary = isStale ? "—" : fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
        MenuBarQuotaPanel(
            title: label,
            fraction: fraction,
            primaryValue: primary,
            countdown: isStale ? nil : window?.resetDate.map { label == "5h" ? menuBarTimeOnlyResetString(for: $0) : resetDateString(for: $0) },
            footer: isStale ? "数据已过期" : nil
        )
    }
}

struct CodexMultiAccountQuotaCard: View {
    @Environment(AppStore.self) private var appStore
    @AppStorage("codex.smartSwitch.enabled") private var codexSmartSwitchEnabled = false
    let accounts: [CodexAccountSnapshot]
    let todayTokens: Int
    @State private var isSwitching = false
    @State private var statusMessage: String?

    var body: some View {
        MenuBarToolShell {
            MenuBarToolIdentity(
                tool: .codex,
                subtitle: accounts.first(where: { $0.isCurrent })?.displaySubscriptionName,
                todayTokens: todayTokens
            ) {
                HStack(spacing: 6) {
                    if codexSmartSwitchEnabled {
                        Button("智能切换") {
                            runSwitch(closeWhenNoDecision: false) {
                                try await appStore.codexAccountService.smartSwitch()
                            }
                        }
                        .buttonStyle(
                            ProminentActionButtonStyle(
                                fillColor: Color.green.opacity(0.78),
                                fontSizeOverride: 10,
                                horizontalPaddingOverride: 7,
                                verticalPaddingOverride: 2,
                                cornerRadius: 8
                            )
                        )
                        .controlSize(.mini)
                        .disabled(isSwitching)
                    }
                    ConfigShortcutButton(tool: .codex)
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(accounts) { account in
                    CodexAccountQuotaCard(
                        account: account,
                        isSwitching: isSwitching,
                        onSwitch: { id in
                            runSwitch(closeWhenNoDecision: true) {
                                _ = try await appStore.codexAccountService.switchAccount(id: id, relaunchCodex: true)
                                return nil as CodexAccountService.SmartSwitchDecision?
                            }
                        },
                        onProviderMessage: { message in
                            statusMessage = message
                        }
                    )
                    if account.id != accounts.last?.id {
                        Divider().opacity(0.18)
                    }
                }
                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func runSwitch(
        closeWhenNoDecision: Bool,
        _ action: @escaping () async throws -> CodexAccountService.SmartSwitchDecision?
    ) {
        isSwitching = true
        statusMessage = nil
        Task {
            do {
                let decision = try await action()
                if decision != nil || closeWhenNoDecision {
                    GlobalHotkeyService.shared.closeMenuBar()
                }
                await appStore.syncService?.sync(tool: .codex)
                await MainActor.run {
                    isSwitching = false
                    if let decision {
                        statusMessage = decision.isAutomatic
                            ? "已自动切换到 \(decision.account.titleText)"
                            : "已切换到 \(decision.account.titleText)"
                    } else {
                        statusMessage = "当前账号已经是最优选择"
                    }
                }
            } catch {
                await MainActor.run {
                    isSwitching = false
                    statusMessage = error.localizedDescription
                }
            }
        }
    }
}

private struct CodexProviderMenuButton: View {
    @Environment(AppStore.self) private var appStore
    @State private var providerState: CodexProviderConfigurationState?
    @State private var isSwitching = false

    let onMessage: (String) -> Void

    private var currentProviderName: String {
        guard
            let providerState,
            let provider = providerState.providers.first(where: { $0.id == providerState.currentProviderID })
        else {
            return "Provider"
        }
        return provider.name
    }

    var body: some View {
        Menu {
            if let providerState {
                ForEach(providerState.providers) { provider in
                    Button {
                        switchProvider(provider)
                    } label: {
                        HStack {
                            Text(provider.name)
                            Spacer()
                            if provider.id == providerState.currentProviderID {
                                Image(systemName: "checkmark")
                            } else if provider.defaultModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text("未配模型")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(isSwitching || provider.defaultModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Text("读取中…")
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 10, weight: .semibold))
                Text(currentProviderName)
                    .font(.system(size: 10, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: 112)
            .background(Color.primary.opacity(0.065), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
        .controlSize(.mini)
        .task {
            if providerState == nil {
                await reloadState()
            }
        }
        .onTapGesture {
            Task {
                await reloadState()
            }
        }
    }

    private func reloadState() async {
        do {
            let state = try await appStore.codexProviderConfigService.loadState()
            await MainActor.run {
                providerState = state
            }
        } catch {
            await MainActor.run {
                providerState = nil
                onMessage(error.localizedDescription)
            }
        }
    }

    private func switchProvider(_ provider: CodexProviderConfig) {
        isSwitching = true
        Task {
            do {
                let state = try await appStore.codexProviderConfigService.switchProvider(id: provider.id)
                _ = try await appStore.codexAccountService.relaunchCodex()
                await appStore.syncService?.sync(tool: .codex)
                await MainActor.run {
                    providerState = state
                    isSwitching = false
                    onMessage("已切换到 \(provider.name)")
                    GlobalHotkeyService.shared.closeMenuBar()
                }
            } catch {
                await MainActor.run {
                    isSwitching = false
                    onMessage(error.localizedDescription)
                }
            }
        }
    }
}

// MARK: - Copilot

struct CopilotQuotaCard: View {
    let snapshots: [String: CopilotSnapshot]?
    let resetAt: Date?
    let plan: String?
    let fallbackQuota: QuotaRecord?
    let todayTokens: Int
    private var ordered: [(key: String, value: CopilotSnapshot)] {
        guard let s = snapshots else { return [] }
        return s
            .filter { key, _ in
                key != "chat" && key != "completions"
            }
            .sorted { a, b in
            if a.key == "premium_interactions" { return true }
            if b.key == "premium_interactions" { return false }
            return a.key < b.key
        }
    }
    var body: some View {
        MenuBarToolShell {
            MenuBarToolIdentity(
                tool: .copilot,
                subtitle: normalizedCopilotPlanDisplayName(plan),
                todayTokens: todayTokens
            ) {
                ConfigShortcutButton(tool: .copilot)
            }
        } content: {
            if !ordered.isEmpty {
                if ordered.count == 1, let snapshot = ordered.first?.value {
                    copilotPanel(for: snapshot)
                } else {
                    VStack(spacing: 8) {
                        let pairs = stride(from: 0, to: ordered.count, by: 2).map {
                            Array(ordered[$0..<min($0 + 2, ordered.count)])
                        }
                        ForEach(pairs, id: \.first?.key) { pair in
                            HStack(alignment: .top, spacing: 8) {
                                ForEach(pair, id: \.key) { item in
                                    copilotPanel(for: item.value)
                                }
                                if pair.count == 1 {
                                    Color.clear.frame(maxWidth: .infinity)
                                }
                            }
                        }
                    }
                }
            } else if let q = fallbackQuota, let r = q.remaining, let t = q.total, t > 0 {
                let frac = Double(r) / Double(t)
                let used = t - r
                let pct = Int((frac * 100).rounded())
                MenuBarQuotaPanel(
                    title: "Copilot",
                    fraction: frac,
                    primaryValue: "\(pct)%",
                    countdown: q.toModel().resetCountdown,
                    footer: "\(used)/\(t)"
                )
            }
        }
    }

    private func copilotPanel(for snapshot: CopilotSnapshot) -> some View {
        let isInf = snapshot.unlimited ?? false
        let pctText = snapshot.percentRemaining.map { "\(Int($0.rounded()))%" } ?? "—"
        let countsText: String? = {
            if let remaining = snapshot.remaining, let entitlement = snapshot.entitlement {
                return "\(max(0, remaining))/\(entitlement)"
            }
            return nil
        }()

        return MenuBarQuotaPanel(
            title: snapshot.displayName,
            fraction: isInf ? 1.0 : snapshot.percentRemaining.map { $0 / 100.0 },
            primaryValue: isInf ? "∞" : pctText,
            countdown: resetAt.map { resetDateString(for: $0) },
            footer: countsText
        )
    }
}

// MARK: - Antigravity

/// Top-level card: shared header (logo + title + ConfigShortcut + TodayTokenBadge),
/// then one section per account separated by dividers — mirrors CodexMultiAccountQuotaCard.
struct AntigravityMultiAccountCard: View {
    let accounts: [AGAccountQuota]
    let todayTokens: Int

    var body: some View {
        MenuBarToolShell {
            MenuBarToolIdentity(
                tool: .antigravity,
                todayTokens: todayTokens
            ) {
                ConfigShortcutButton(tool: .antigravity)
            }
        } content: {
            VStack(spacing: 10) {
                ForEach(accounts) { account in
                    AntigravityAccountSection(account: account)
                    if account.id != accounts.last?.id {
                        Divider().opacity(0.18)
                    }
                }
            }
        }
    }
}

struct AntigravityAggregateCard: View {
    let accounts: [AGAccountQuota]
    let todayTokens: Int
    @AppStorage("ag.hiddenModelIds") private var globalHiddenModelIdsRaw = ""
    @AppStorage("ag.hiddenAccountEmails") private var hiddenAccountEmailsRaw = ""

    private var hiddenModelIds: Set<String> {
        Set(globalHiddenModelIdsRaw.components(separatedBy: ",").filter { !$0.isEmpty })
    }

    private var hiddenAccountEmails: Set<String> {
        Set(hiddenAccountEmailsRaw.components(separatedBy: ",").filter { !$0.isEmpty })
    }

    private var visibleAccounts: [AGAccountQuota] {
        accounts.filter { !hiddenAccountEmails.contains($0.email) }
    }

    private var aggregatedModels: [AntigravityAggregatedModel] {
        var orderedKeys: [String] = []
        var buckets: [String: [AGModelQuota]] = [:]
        var titles: [String: String] = [:]

        for model in visibleAccounts.flatMap(\.models) where !hiddenModelIds.contains(model.id) {
            let key = model.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { continue }
            if buckets[key] == nil {
                orderedKeys.append(key)
                titles[key] = model.displayName
            }
            buckets[key, default: []].append(model)
        }

        return orderedKeys.compactMap { key in
            guard let models = buckets[key], let title = titles[key] else { return nil }
            let fractions = models.compactMap(\.remainingFraction)
            let average = fractions.isEmpty ? nil : fractions.reduce(0, +) / Double(fractions.count)
            return AntigravityAggregatedModel(
                id: key,
                title: title,
                remainingFraction: average,
                resetDate: models.compactMap(\.validatedResetDate).min(),
                contributingCount: fractions.count
            )
        }
        .filter { $0.remainingFraction != nil || $0.resetDate != nil }
    }

    var body: some View {
        MenuBarToolShell {
            MenuBarToolIdentity(
                tool: .antigravity,
                todayTokens: todayTokens
            ) {
                ConfigShortcutButton(tool: .antigravity)
            }
        } content: {
            if aggregatedModels.isEmpty {
                Text("暂无可聚合的模型额度")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("All accounts")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    let pairs = stride(from: 0, to: aggregatedModels.count, by: 2)
                        .map { Array(aggregatedModels[$0..<min($0 + 2, aggregatedModels.count)]) }
                    VStack(spacing: 5) {
                        ForEach(pairs, id: \.first?.id) { pair in
                            HStack(alignment: .top, spacing: 6) {
                                ForEach(pair) { model in
                                    AntigravityAggregatedModelRow(model: model)
                                        .frame(maxWidth: .infinity)
                                }
                                if pair.count == 1 { Color.clear.frame(maxWidth: .infinity) }
                            }
                        }
                    }
                }
            }
        }
    }
}

struct AntigravityAggregatedModel: Identifiable {
    let id: String
    let title: String
    let remainingFraction: Double?
    let resetDate: Date?
    let contributingCount: Int

    var primaryValueText: String {
        guard let remainingFraction else { return "—" }
        return "\(Int((remainingFraction * 100).rounded()))%"
    }

    var footerText: String {
        contributingCount > 0 ? "\(contributingCount) accounts" : "额度未知"
    }
}

struct AntigravityAggregatedModelRow: View {
    let model: AntigravityAggregatedModel

    var body: some View {
        MenuBarQuotaPanel(
            title: model.title,
            fraction: model.remainingFraction,
            primaryValue: model.primaryValueText,
            countdown: model.resetDate.map { resetDateString(for: $0) },
            footer: model.footerText
        )
    }
}

/// Content for a single Antigravity account (email + model quota grid).
/// No outer card chrome — used inside AntigravityMultiAccountCard.
struct AntigravityAccountSection: View {
    let account: AGAccountQuota
    @AppStorage("ag.hiddenModelIds") private var globalHiddenModelIdsRaw = ""
    @AppStorage("ag.hiddenAccountEmails") private var hiddenAccountEmailsRaw = ""
    @AppStorage("ag.syncModelConfig") private var syncModelConfig = true

    private var hiddenIds: Set<String> {
        Set(effectiveHiddenModelIdsRaw.components(separatedBy: ",").filter { !$0.isEmpty })
    }
    private var effectiveHiddenModelIdsRaw: String {
        syncModelConfig
            ? globalHiddenModelIdsRaw
            : (UserDefaults.standard.string(forKey: "ag.hiddenModelIds.\(account.email)") ?? "")
    }
    private var isAccountHidden: Bool {
        Set(hiddenAccountEmailsRaw.components(separatedBy: ",").filter { !$0.isEmpty }).contains(account.email)
    }
    private var visibleModels: [AGModelQuota] { account.models.filter { !hiddenIds.contains($0.id) } }
    private var displayedModels: [AGModelQuota] { Array(visibleModels.prefix(4)) }
    private var hiddenModelCount: Int { max(0, visibleModels.count - displayedModels.count) }

    var body: some View {
        if isAccountHidden { EmptyView() } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(account.email)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if visibleModels.isEmpty {
                    Text("全部模型已隐藏")
                        .font(.system(size: 9))
                        .foregroundStyle(.quaternary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if displayedModels.count == 1 {
                    AntigravityModelRow(model: displayedModels[0]).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    let pairs = stride(from: 0, to: displayedModels.count, by: 2)
                        .map { Array(displayedModels[$0..<min($0 + 2, displayedModels.count)]) }
                    VStack(spacing: 5) {
                        ForEach(pairs, id: \.first?.id) { pair in
                            HStack(alignment: .top, spacing: 6) {
                                ForEach(pair, id: \.id) { model in
                                    AntigravityModelRow(model: model, inGrid: true).frame(maxWidth: .infinity)
                                }
                                if pair.count == 1 { Color.clear.frame(maxWidth: .infinity) }
                            }
                        }
                    }
                }
                if hiddenModelCount > 0 {
                    Text("+\(hiddenModelCount) more models in dashboard")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

struct AntigravityFallbackCard: View {
    let quota: QuotaRecord
    let todayTokens: Int
    var body: some View {
        MenuBarToolShell {
            MenuBarToolIdentity(
                tool: .antigravity,
                todayTokens: todayTokens
            ) {
                ConfigShortcutButton(tool: .antigravity)
            }
        } content: {
            if let r = quota.remaining, let t = quota.total, t > 0 {
                let frac = Double(r) / Double(t)
                let pct = Int((frac * 100).rounded())
                MenuBarQuotaPanel(
                    title: "Total Quota",
                    fraction: frac,
                    primaryValue: "\(pct)%",
                    countdown: quota.toModel().resetCountdown,
                    footer: nil
                )
            }
        }
    }
}

/// Shared quota row for a single Antigravity model.
/// `inGrid: true` adds the cell background used in the two-column grid layout.
struct AntigravityModelRow: View {
    let model: AGModelQuota
    var inGrid: Bool = false

    var body: some View {
        MenuBarQuotaPanel(
            title: model.displayName,
            fraction: model.remainingFraction,
            primaryValue: model.primaryValueText,
            countdown: model.resetCountdown,
            footer: model.secondaryStatusText
        )
    }
}

private extension View {
    func menuBarCardSurface() -> some View {
        padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}

// MARK: - Window capture for global hotkey

/// Invisible background view that registers the MenuBarExtra window with GlobalHotkeyService
/// each time the popover opens. Uses viewDidMoveToWindow which fires reliably on every open.
private struct MenuBarWindowCapture: NSViewRepresentable {
    func makeNSView(context: Context) -> _MenuBarCaptureView { _MenuBarCaptureView() }
    func updateNSView(_ nsView: _MenuBarCaptureView, context: Context) {}
}

final class _MenuBarCaptureView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        Task { @MainActor in
            AppLogger.shared.recordDiagnostic(scope: "menubar.open", message: "menu bar window attached")
        }
    }
}
