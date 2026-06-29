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
        .frame(width: 410)
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
                            Text("今日 \(todayTokens.compactTokenString) tokens")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("额度仪表盘")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.primary)
                Text("余量优先")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
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
                .help(String(localized: "刷新同步 (⌘R)"))
                .disabled(isSyncing)
                Button(action: {
                    performMenuBarAction {
                        WindowCoordinator.shared.showMainWindow()
                    }
                }) {
                    Image(systemName: "macwindow")
                }
                .keyboardShortcut("m", modifiers: .command)
                .help(String(localized: "打开主窗口 (⌘M)"))
                Button(action: {
                    performMenuBarAction {
                        WindowCoordinator.shared.showMainWindow(select: .settings)
                    }
                }) {
                    Image(systemName: "gearshape")
                }
                .keyboardShortcut(",", modifiers: .command)
                .help(String(localized: "设置 (⌘,)"))
                Button(action: {
                    performMenuBarAction {
                        NSApp.terminate(nil)
                    }
                }) {
                    Image(systemName: "power")
                }
                .keyboardShortcut("q", modifiers: .command)
                .help(String(localized: "退出 (⌘Q)"))
                .foregroundStyle(.secondary)
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
            Image(systemName: "gearshape")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .onTapGesture {
                    GlobalHotkeyService.shared.closeMenuBar()
                    if FileManager.default.fileExists(atPath: configFile.url.path) {
                        NSWorkspace.shared.open(configFile.url)
                    } else {
                        NSWorkspace.shared.activateFileViewerSelecting([configFile.url.deletingLastPathComponent()])
                    }
                }
                .accessibilityLabel(Text(String(localized: "打开 \(configFile.displayName)")))
                .accessibilityAddTraits(.isButton)
            .foregroundStyle(.secondary)
            .help(String(localized: "打开 \(configFile.displayName)"))
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
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 10) {
                ToolLogoImage(tool: tool, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.displayName)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 10, weight: .medium))
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
        VStack(alignment: .leading, spacing: 9) {
            Text(LocalizedStringKey(title))
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(primaryValue)
                    .font(.system(size: 22, weight: .black, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 2)
                MenuBarResetLine(countdown: countdown)
            }

            QuotaProgressBar(
                fraction: fraction,
                color: menuBarQuotaBarColor(fraction: fraction),
                height: 4,
                showsGlow: false
            )

            if let footer, !footer.isEmpty {
                Text(LocalizedStringKey(footer))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.045), lineWidth: 0.5)
        }
    }
}

private struct MenuBarResetLine: View {
    let countdown: String?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
            Text(LocalizedStringKey(countdown ?? "—"))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(countdown == nil ? .tertiary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.76)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.055), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

private func menuBarQuotaBarColor(fraction: Double?) -> Color {
    guard let fraction else { return Color.primary.opacity(0.18) }
    if fraction < 0.15 { return Color.red.opacity(0.82) }
    if fraction < 0.40 { return Color.orange.opacity(0.76) }
    return Color.green.opacity(0.58)
}

private func menuBarTimeOnlyResetString(for date: Date) -> String {
    date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
}

private func menuBarShortResetString(for date: Date) -> String {
    if Calendar.current.isDateInToday(date) {
        return menuBarTimeOnlyResetString(for: date)
    }
    return date.formatted(.dateTime.month(.defaultDigits).day(.defaultDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
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
                        title: "5小时余量",
                        fraction: usage.fiveHour?.utilization.map { max(0, min(1, (100 - $0) / 100)) },
                        primaryValue: usage.fiveHour?.utilization.map { "\(max(0, Int((100 - $0).rounded())))%" } ?? "—",
                        countdown: usage.fiveHour?.resetDate.map { menuBarTimeOnlyResetString(for: $0) },
                        footer: nil
                    )
                    MenuBarQuotaPanel(
                        title: "本周余量",
                        fraction: usage.sevenDay?.utilization.map { max(0, min(1, (100 - $0) / 100)) },
                        primaryValue: usage.sevenDay?.utilization.map { "\(max(0, Int((100 - $0).rounded())))%" } ?? "—",
                        countdown: usage.sevenDay?.resetDate.map { menuBarShortResetString(for: $0) },
                        footer: nil
                    )
                }
            } else if let q = quota, let r = q.remaining, let t = q.total, t > 0 {
                let frac = Double(r) / Double(t)
                let pct = Int((frac * 100).rounded())
                MenuBarQuotaPanel(
                    title: "5小时余量",
                    fraction: frac,
                    primaryValue: "\(pct)%",
                    countdown: q.resetAt.map { menuBarTimeOnlyResetString(for: $0) } ?? q.toModel().resetCountdown,
                    footer: nil
                )
            } else {
                Text("未获取到额度")
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
                HStack(spacing: 6) {
                    CodexProviderMenuButton { message in
                        statusMessage = message
                    }
                    ConfigShortcutButton(tool: .codex)
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                if let limits {
                    HStack(spacing: 8) {
                        codexPanel(label: "5小时余量", isFiveHour: true, window: limits.fiveHourWindow)
                        codexPanel(label: "本周余量", isFiveHour: false, window: limits.oneWeekWindow)
                    }
                } else if let q = fallbackQuota, let r = q.remaining, let t = q.total {
                    let frac = Double(r) / Double(t)
                    let pct = Int((frac * 100).rounded())
                    MenuBarQuotaPanel(
                        title: "5小时余量",
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
    private func codexPanel(label: String, isFiveHour: Bool, window: CodexWindow?) -> some View {
        let isStale = window?.resetDate.map { $0 < Date() } ?? false
        let fraction = isStale ? nil : window?.usedPercent.map { max(0, min(1, (100 - $0) / 100)) }
        let primary = isStale ? "—" : fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
        MenuBarQuotaPanel(
            title: label,
            fraction: fraction,
            primaryValue: primary,
            countdown: isStale ? "数据已过期" : window?.resetDate.map { isFiveHour ? menuBarTimeOnlyResetString(for: $0) : menuBarShortResetString(for: $0) },
            footer: nil
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
                    accountPanel(label: "5小时余量", isFiveHour: true, window: limits.fiveHourWindow)
                    accountPanel(label: "本周余量", isFiveHour: false, window: limits.oneWeekWindow)
                }
                if let resetCredits = limits.resetCredits {
                    CodexResetCreditsLine(resetCredits: resetCredits)
                }
            } else if let error = account.usageError {
                Text(error).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("尚未获取配额").font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func accountPanel(label: String, isFiveHour: Bool, window: CodexWindow?) -> some View {
        let isStale = window?.resetDate.map { $0 < Date() } ?? false
        let fraction = isStale ? nil : window?.usedPercent.map { max(0, min(1, (100 - $0) / 100)) }
        let primary = isStale ? "—" : fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
        MenuBarQuotaPanel(
            title: label,
            fraction: fraction,
            primaryValue: primary,
            countdown: isStale ? "数据已过期" : window?.resetDate.map { isFiveHour ? menuBarTimeOnlyResetString(for: $0) : menuBarShortResetString(for: $0) },
            footer: nil
        )
    }
}

private struct CodexResetCreditsLine: View {
    let resetCredits: CodexResetCredits

    private var availableCredits: [CodexResetCredit] {
        (resetCredits.credits ?? [])
            .filter { ($0.status ?? "").caseInsensitiveCompare("available") == .orderedSame }
            .sorted { lhs, rhs in
            switch (lhs.expiresAt, rhs.expiresAt) {
            case let (left?, right?): return left < right
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return (lhs.title ?? "") < (rhs.title ?? "")
            }
        }
    }

    private var availableCount: Int {
        resetCredits.availableCount ?? availableCredits.count
    }

    private var expiryText: String? {
        let values = availableCredits.compactMap { credit in
            credit.expiresAt.map { menuBarShortResetString(for: $0) }
        }
        guard !values.isEmpty else { return nil }
        return values.joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.counterclockwise.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.green)
            Text("可用重置券")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Text("\(availableCount)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)
            if let expiryText {
                Text("过期 \(expiryText)")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: Capsule())
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
                            ? String(localized: "已自动切换到 \(decision.account.titleText)")
                            : String(localized: "已切换到 \(decision.account.titleText)")
                    } else {
                        statusMessage = String(localized: "当前账号已经是最优选择")
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

    private var currentProviderName: String? {
        guard
            let providerState,
            let provider = providerState.providers.first(where: { $0.id == providerState.currentProviderID })
        else {
            return nil
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
                if let currentProviderName {
                    Text(currentProviderName)
                        .font(.system(size: 10, weight: .bold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text("服务商")
                        .font(.system(size: 10, weight: .bold))
                        .lineLimit(1)
                }
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
                    onMessage(String(localized: "已切换到 \(provider.name)"))
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
                    title: "Copilot 余量",
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
            countdown: resetAt.map { menuBarShortResetString(for: $0) },
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

    private var prioritizedAggregatedModels: [AntigravityAggregatedModel] {
        aggregatedModels.sorted { lhs, rhs in
            switch (lhs.remainingFraction, rhs.remainingFraction) {
            case let (l?, r?): return l < r
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return lhs.title < rhs.title
            }
        }
    }

    private var displayedAggregatedModels: [AntigravityAggregatedModel] {
        Array(prioritizedAggregatedModels.prefix(4))
    }

    private var hiddenAggregatedModelCount: Int {
        max(0, aggregatedModels.count - displayedAggregatedModels.count)
    }

    private var lowestRemainingText: String {
        guard let lowest = aggregatedModels.compactMap(\.remainingFraction).min() else { return "—" }
        return "\(Int((lowest * 100).rounded()))%"
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
                    AntigravityAggregateSummary(
                        accountCount: visibleAccounts.count,
                        modelCount: aggregatedModels.count,
                        lowestRemainingText: lowestRemainingText
                    )

                    let pairs = stride(from: 0, to: displayedAggregatedModels.count, by: 2)
                        .map { Array(displayedAggregatedModels[$0..<min($0 + 2, displayedAggregatedModels.count)]) }
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

                    if hiddenAggregatedModelCount > 0 {
                        Text("+\(hiddenAggregatedModelCount) 个模型在主窗口查看")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.tertiary)
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
        contributingCount > 0 ? String(localized: "\(contributingCount) 个账号") : String(localized: "额度未知")
    }
}

struct AntigravityAggregateSummary: View {
    let accountCount: Int
    let modelCount: Int
    let lowestRemainingText: String

    var body: some View {
        HStack(spacing: 6) {
            aggregatePill(label: "账号", value: "\(accountCount)")
            aggregatePill(label: "模型", value: "\(modelCount)")
            aggregatePill(label: "最低余量", value: lowestRemainingText, emphasized: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func aggregatePill(label: String, value: String, emphasized: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(LocalizedStringKey(label))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(emphasized ? .primary : .secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(emphasized ? 0.07 : 0.045), in: Capsule())
    }
}

struct AntigravityAggregatedModelRow: View {
    let model: AntigravityAggregatedModel

    var body: some View {
        MenuBarQuotaPanel(
            title: model.title,
            fraction: model.remainingFraction,
            primaryValue: model.primaryValueText,
            countdown: model.resetDate.map { menuBarShortResetString(for: $0) },
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
                    Text("+\(hiddenModelCount) 个模型在主窗口查看")
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
                    title: "总余量",
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
