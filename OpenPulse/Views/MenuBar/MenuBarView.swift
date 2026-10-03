import SwiftUI
import Foundation
import SwiftData
import AppKit

struct MenuBarView: View {
    @State private var dayStart = Calendar.current.startOfDay(for: Date())

    var body: some View {
        MenuBarContentView(dayStart: dayStart)
            .onAppear { updateDayBoundary() }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
                updateDayBoundary()
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
                updateDayBoundary()
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                updateDayBoundary()
            }
    }

    private func updateDayBoundary() {
        dayStart = Calendar.current.startOfDay(for: Date())
    }
}

struct MenuBarDailyStatsSnapshot: Equatable {
    let date: Date
    let tool: Tool
    let inputTokens: Int
    let outputTokens: Int
}

func menuBarTodayTokens(
    from stats: [MenuBarDailyStatsSnapshot],
    dayStart: Date,
    calendar: Calendar = .current
) -> [Tool: Int] {
    let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
    var tokens: [Tool: Int] = [:]
    for record in stats where record.date >= dayStart && record.date < dayEnd {
        tokens[record.tool, default: 0] += record.inputTokens + record.outputTokens
    }
    return tokens
}

private struct MenuBarQuotaNowKey: EnvironmentKey {
    static var defaultValue: Date { Date() }
}

private extension EnvironmentValues {
    var menuBarQuotaNow: Date {
        get { self[MenuBarQuotaNowKey.self] }
        set { self[MenuBarQuotaNowKey.self] = newValue }
    }
}

private struct MenuBarContentView: View {
    @Environment(AppStore.self) private var appStore
    @Query private var dailyStats: [DailyStatsRecord]
    @Query private var quotas: [QuotaRecord]
    @State private var logger = AppLogger.shared

    @AppStorage("menubar.toolOrder") private var toolOrderRaw = Tool.defaultOrderRaw
    @AppStorage("menubar.hiddenTools") private var hiddenToolsRaw = ""
    @AppStorage("menubar.antigravityDisplayMode") private var antigravityDisplayMode = "accounts"
    let dayStart: Date

    init(dayStart: Date) {
        self.dayStart = dayStart
        // A moving, bounded aggregate query keeps yesterday out after midnight.
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        _dailyStats = Query(filter: #Predicate<DailyStatsRecord> { $0.date >= dayStart && $0.date < dayEnd })
    }

    private var orderedVisibleTools: [Tool] {
        let hidden = Set(hiddenToolsRaw.components(separatedBy: ",").filter { !$0.isEmpty })
        let order = toolOrderRaw.components(separatedBy: ",").compactMap { Tool(rawValue: $0) }
        let ordered = order + Tool.allCases.filter { !order.contains($0) }
        return ordered.filter { !hidden.contains($0.rawValue) }
    }

    @State private var contentHeight: CGFloat = 0
    @State private var headerHeight: CGFloat = 88
    @State private var footerHeight: CGFloat = 82
    // Cached per-tool today token counts — one pass over today's aggregate stats only.
    @State private var todayTokensByTool: [Tool: Int] = [:]

    private var todayStatsSnapshot: [MenuBarDailyStatsSnapshot] {
        dailyStats.map {
            MenuBarDailyStatsSnapshot(
                date: $0.date,
                tool: $0.tool,
                inputTokens: $0.totalInputTokens,
                outputTokens: $0.totalOutputTokens
            )
        }
    }

    private func rebuildTodayTokens() {
        todayTokensByTool = menuBarTodayTokens(from: todayStatsSnapshot, dayStart: dayStart)
    }

    private var todayTokens: Int { todayTokensByTool.values.reduce(0, +) }

    private var isSyncing: Bool { appStore.syncService?.isSyncingActive ?? false }
    private var lastSyncDate: Date? { appStore.syncService?.lastSyncDate ?? appStore.lastSyncDate }

    private var maxScrollHeight: CGFloat {
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        return max(300, screenHeight - headerHeight - footerHeight - 22 - 24)
    }

    var body: some View {
        VStack(spacing: 0) {
            MenuBarHeader(
                todayTokens: todayTokens,
                visibleToolCount: orderedVisibleTools.count,
                isSyncing: isSyncing,
                onRefresh: {
                    performMenuBarAction {
                        await appStore.syncService?.sync()
                    }
                }
            )
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            Divider().padding(.horizontal, 16)
            ScrollView {
                // Only quota cards tick; today's bounded query and cached totals
                // remain in the parent and rebuild only when usage or day changes.
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    VStack(spacing: 12) {
                        if orderedVisibleTools.isEmpty {
                            MenuBarEmptyToolsView()
                        } else {
                            ForEach(orderedVisibleTools, id: \.self) { tool in
                                toolCard(for: tool)
                            }
                        }
                    }
                    .environment(\.menuBarQuotaNow, context.date)
                    .padding(14)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
            }
            .frame(height: min(contentHeight, maxScrollHeight))
            .scrollIndicators(.hidden)
            Divider().padding(.horizontal, 16)
            MenuBarFooter(
                lastSyncDate: lastSyncDate,
                syncError: appStore.syncService?.syncError.map { syncErrorHelpText(fallback: $0) },
                onOpen: {
                    performMenuBarAction {
                        WindowCoordinator.shared.showMainWindow()
                    }
                },
                onSettings: {
                    performMenuBarAction {
                        WindowCoordinator.shared.showMainWindow(select: .settings)
                    }
                },
                onQuit: {
                    performMenuBarAction {
                        NSApp.terminate(nil)
                    }
                }
            )
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
        }
        .frame(width: 420)
        .background(MenuBarWindowCapture())
        .task { rebuildTodayTokens() }
        .onChange(of: todayStatsSnapshot) { _, _ in rebuildTodayTokens() }
        .onChange(of: dayStart) { _, _ in rebuildTodayTokens() }
        .onChange(of: appStore.syncService?.dataRevision) { _, _ in rebuildTodayTokens() }
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
            } else {
                MenuBarToolShell {
                    MenuBarToolIdentity(tool: .antigravity, todayTokens: todaySessionTokens(for: .antigravity)) {
                        ConfigShortcutButton(tool: .antigravity)
                    }
                } content: {
                    MenuBarQuotaUnavailable()
                }
            }
        }
    }

    private func todaySessionTokens(for tool: Tool) -> Int { todayTokensByTool[tool] ?? 0 }

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

private struct MenuBarHeader: View {
    let todayTokens: Int
    let visibleToolCount: Int
    let isSyncing: Bool
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("OpenPulse")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("r", modifiers: .command)
                .help("刷新同步 (⌘R)")
                .accessibilityLabel("刷新同步")
                .disabled(isSyncing)
            }

            HStack(alignment: .bottom, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(todayTokens.compactTokenString)
                        .font(.system(size: 24, weight: .semibold))
                        .monospacedDigit()
                    Text("今日 tokens")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 8)
                if isSyncing {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("同步中…")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                } else {
                    Text("\(visibleToolCount) 个工具")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 16)
    }
}

private struct MenuBarFooter: View {
    let lastSyncDate: Date?
    let syncError: String?
    let onOpen: () -> Void
    let onSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let lastSyncDate {
                    Text("更新于 \(lastSyncDate, style: .relative)前")
                        .help(lastSyncDate.formatted(date: .abbreviated, time: .shortened))
                } else {
                    Text("尚未同步")
                }
                Spacer(minLength: 4)
                if let syncError {
                    Label("同步出现问题", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .help(syncError)
                        .accessibilityHint(syncError)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button(action: onOpen) {
                    HStack(spacing: 8) {
                        Label("打开 OpenPulse", systemImage: "macwindow")
                        Spacer(minLength: 8)
                        Text("⌘M")
                            .font(.system(size: 11))
                            .opacity(0.7)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .keyboardShortcut("m", modifiers: .command)
                .help("打开主窗口 (⌘M)")

                Menu {
                    Button("设置…", systemImage: "gearshape", action: onSettings)
                        .keyboardShortcut(",", modifiers: .command)
                    Divider()
                    Button("退出 OpenPulse", systemImage: "power", action: onQuit)
                        .keyboardShortcut("q", modifiers: .command)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 26, height: 28)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("更多操作")
                .accessibilityLabel("更多操作")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

private struct MenuBarEmptyToolsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("没有显示的工具")
                .font(.system(size: 13, weight: .semibold))
            Text("在设置中选择要显示的工具。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text("打开 \(configFile.displayName)"))
            .help("打开 \(configFile.displayName)")
        }
    }
}

private struct MenuBarQuotaUnavailable: View {
    var body: some View {
        Text("尚未获取额度")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
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
        VStack(alignment: .leading, spacing: 12) {
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
                ToolLogoImage(tool: tool, size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let metaText, !metaText.isEmpty {
                        Text(metaText)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            if todayTokens > 0 {
                Text(todayTokens.compactTokenString)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help("今日 \(todayTokens.compactTokenString) tokens")
                    .accessibilityLabel(Text("今日 \(todayTokens.compactTokenString) tokens"))
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
    var isExhaustedOverride: Bool? = nil

    private var isExhausted: Bool {
        isExhaustedOverride ?? ((fraction ?? 1.0) <= 0.001 || primaryValue == "0%")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(title))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(primaryValue)
                .font(.system(size: 22, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(isExhausted ? Color.secondary : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            QuotaProgressBar(
                fraction: isExhausted ? 0.0 : fraction,
                color: isExhausted ? Color.primary.opacity(0.12) : menuBarQuotaBarColor(fraction: fraction),
                height: 4,
                showsGlow: false
            )

            MenuBarResetLine(countdown: countdown)

            if let footer, !footer.isEmpty {
                Text(LocalizedStringKey(footer))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MenuBarResetLine: View {
    let countdown: String?

    var body: some View {
        Group {
            if let countdown {
                Text("\(countdown) 重置")
            } else {
                Text("重置时间未知")
            }
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }
}

func menuBarQuotaFraction(
    remainingFraction: Double?,
    resetAt: Date?,
    now: Date = Date()
) -> Double? {
    guard !menuBarQuotaIsExpired(resetAt: resetAt, now: now),
          let remainingFraction, remainingFraction.isFinite else { return nil }
    return min(1, max(0, remainingFraction))
}

func menuBarQuotaIsExpired(resetAt: Date?, now: Date = Date()) -> Bool {
    resetAt.map { $0 <= now } ?? false
}

private func menuBarQuotaPercentText(_ fraction: Double?) -> String {
    fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
}

private func menuBarQuotaRefreshFooter(resetAt: Date?, now: Date) -> String? {
    menuBarQuotaIsExpired(resetAt: resetAt, now: now) ? String(localized: "等待更新") : nil
}

private func menuBarQuotaBarColor(fraction: Double?) -> Color {
    guard let fraction else { return Color.primary.opacity(0.18) }
    if fraction <= 0.001 { return Color.primary.opacity(0.12) }
    if fraction < 0.15 { return Color.red.opacity(0.75) }
    if fraction < 0.40 { return Color.orange.opacity(0.76) }
    return Color.green.opacity(0.58)
}

private func menuBarTimeOnlyResetString(for date: Date) -> String {
    date.formatted(.dateTime.hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits))
}

private func menuBarShortResetString(for date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) {
        return menuBarTimeOnlyResetString(for: date)
    }
    let month = calendar.component(.month, from: date)
    let day = calendar.component(.day, from: date)
    let hour = calendar.component(.hour, from: date)
    let minute = calendar.component(.minute, from: date)
    return String(format: "%02d/%02d %02d:%02d", month, day, hour, minute)
}

private struct CodexMenuBarWindowDisplayState {
    let fraction: Double?
    let primaryValue: String
    let countdown: String?
    let footer: String?
}

struct CodexMenuBarQuotaRow: Identifiable, Sendable {
    let id: String
    let title: String
    let fiveHourWindow: CodexWindow?
    let oneWeekWindow: CodexWindow?
    let observedAt: Date?
}

func codexMenuBarQuotaRows(for limits: CodexRateLimits?) -> [CodexMenuBarQuotaRow] {
    guard let limits else { return [] }

    var rows: [CodexMenuBarQuotaRow] = []
    let generalFiveHour = limits.fiveHourWindow
    let generalOneWeek = limits.oneWeekWindow
    if generalFiveHour != nil || generalOneWeek != nil {
        rows.append(
            CodexMenuBarQuotaRow(
                id: "codex",
                title: String(localized: "通用额度"),
                fiveHourWindow: generalFiveHour,
                oneWeekWindow: generalOneWeek,
                observedAt: limits.observedAt
            )
        )
    }

    let namedRows = (limits.additionalLimits ?? []).compactMap { named -> CodexMenuBarQuotaRow? in
        let id = named.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }

        let windows = codexMenuBarNamedWindows(for: named)
        guard windows.fiveHour != nil || windows.oneWeek != nil else { return nil }

        return CodexMenuBarQuotaRow(
            id: id,
            title: codexMenuBarNamedTitle(for: named, fallbackID: id),
            fiveHourWindow: windows.fiveHour,
            oneWeekWindow: windows.oneWeek,
            observedAt: named.observedAt
        )
    }

    rows.append(contentsOf: namedRows.sorted { lhs, rhs in
        let lhsName = lhs.title.lowercased()
        let rhsName = rhs.title.lowercased()
        if lhsName != rhsName { return lhsName < rhsName }
        let lhsID = lhs.id.lowercased()
        let rhsID = rhs.id.lowercased()
        if lhsID != rhsID { return lhsID < rhsID }
        if lhs.title != rhs.title { return lhs.title < rhs.title }
        return lhs.id < rhs.id
    })
    return rows
}

private func codexMenuBarNamedWindows(
    for named: CodexNamedRateLimit
) -> (fiveHour: CodexWindow?, oneWeek: CodexWindow?) {
    var fiveHour: CodexWindow?
    var oneWeek: CodexWindow?

    for window in [named.primary, named.secondary].compactMap({ $0 }) {
        switch window.durationSeconds {
        case 18_000:
            if fiveHour == nil { fiveHour = window }
        case 604_800:
            if oneWeek == nil { oneWeek = window }
        default:
            continue
        }
    }

    return (fiveHour, oneWeek)
}

private func codexMenuBarNamedTitle(for named: CodexNamedRateLimit, fallbackID: String) -> String {
    let name = named.name?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let name, !name.isEmpty else { return fallbackID }
    if name.caseInsensitiveCompare("GPT-5.3-Codex-Spark") == .orderedSame {
        return "Spark"
    }
    return name
}

func codexQuotaObservedRelativeText(observedAt: Date, locale: Locale = .current) -> String {
    observedAt.formatted(.relative(presentation: .named).locale(locale))
}

private struct CodexMenuBarQuotaRows: View {
    let limits: CodexRateLimits

    var body: some View {
        let rows = codexMenuBarQuotaRows(for: limits)
        let hasMultipleRows = rows.count > 1
        VStack(alignment: .leading, spacing: 10) {
            ForEach(rows) { row in
                CodexMenuBarQuotaRowView(
                    row: row,
                    showTitle: hasMultipleRows || row.id != "codex"
                )
            }
        }
    }
}

private struct CodexMenuBarQuotaRowView: View {
    @Environment(\.menuBarQuotaNow) private var now
    let row: CodexMenuBarQuotaRow
    let showTitle: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showTitle {
                Text(verbatim: row.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(alignment: .top, spacing: 16) {
                quotaPanel(label: String(localized: "5小时余量"), isFiveHour: true, window: row.fiveHourWindow)
                quotaPanel(label: String(localized: "本周余量"), isFiveHour: false, window: row.oneWeekWindow)
            }
        }
    }
    @ViewBuilder
    private func quotaPanel(label: String, isFiveHour: Bool, window: CodexWindow?) -> some View {
        let state = codexMenuBarDisplayState(for: window, isFiveHour: isFiveHour, now: now)
        MenuBarQuotaPanel(
            title: label,
            fraction: state.fraction,
            primaryValue: state.primaryValue,
            countdown: state.countdown,
            footer: state.footer
        )
    }
}

private func codexMenuBarDisplayState(for window: CodexWindow?, isFiveHour: Bool, now: Date) -> CodexMenuBarWindowDisplayState {
    guard let window else {
        return CodexMenuBarWindowDisplayState(
            fraction: nil,
            primaryValue: "—",
            countdown: nil,
            footer: nil
        )
    }

    let resetDate = window.resetDate
    let fraction = menuBarQuotaFraction(
        remainingFraction: window.usedPercent.map { (100 - $0) / 100 },
        resetAt: resetDate,
        now: now
    )
    let countdown = resetDate.map {
        isFiveHour ? menuBarTimeOnlyResetString(for: $0) : menuBarShortResetString(for: $0)
    }
    return CodexMenuBarWindowDisplayState(
        fraction: fraction,
        primaryValue: menuBarQuotaPercentText(fraction),
        countdown: countdown,
        footer: menuBarQuotaRefreshFooter(resetAt: resetDate, now: now)
    )
}

// MARK: - Claude Code

struct ClaudeQuotaCard: View {
    @Environment(\.menuBarQuotaNow) private var now
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
                let fiveHourFraction = menuBarQuotaFraction(
                    remainingFraction: usage.fiveHour?.utilization.map { (100 - $0) / 100 },
                    resetAt: usage.fiveHour?.resetDate,
                    now: now
                )
                let weeklyFraction = menuBarQuotaFraction(
                    remainingFraction: usage.sevenDay?.utilization.map { (100 - $0) / 100 },
                    resetAt: usage.sevenDay?.resetDate,
                    now: now
                )
                let isWeeklyExhausted = weeklyFraction.map { $0 <= 0.001 } ?? false
                HStack(alignment: .top, spacing: 16) {
                    MenuBarQuotaPanel(
                        title: "5小时余量",
                        fraction: fiveHourFraction,
                        primaryValue: menuBarQuotaPercentText(fiveHourFraction),
                        countdown: usage.fiveHour?.resetDate.map { menuBarTimeOnlyResetString(for: $0) },
                        footer: isWeeklyExhausted
                            ? String(localized: "本周额度已耗尽")
                            : menuBarQuotaRefreshFooter(resetAt: usage.fiveHour?.resetDate, now: now),
                        isExhaustedOverride: isWeeklyExhausted ? true : nil
                    )
                    MenuBarQuotaPanel(
                        title: "本周余量",
                        fraction: weeklyFraction,
                        primaryValue: menuBarQuotaPercentText(weeklyFraction),
                        countdown: usage.sevenDay?.resetDate.map { menuBarShortResetString(for: $0) },
                        footer: menuBarQuotaRefreshFooter(resetAt: usage.sevenDay?.resetDate, now: now)
                    )
                }
            } else if let q = quota, let r = q.remaining, let t = q.total, t > 0 {
                let frac = menuBarQuotaFraction(remainingFraction: Double(r) / Double(t), resetAt: q.resetAt, now: now)
                MenuBarQuotaPanel(
                    title: "5小时余量",
                    fraction: frac,
                    primaryValue: menuBarQuotaPercentText(frac),
                    countdown: q.resetAt.map { menuBarTimeOnlyResetString(for: $0) },
                    footer: menuBarQuotaRefreshFooter(resetAt: q.resetAt, now: now)
                )
            } else {
                MenuBarQuotaUnavailable()
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
    @Environment(\.menuBarQuotaNow) private var now
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
                if let limits, !codexMenuBarQuotaRows(for: limits).isEmpty {
                    CodexMenuBarQuotaRows(limits: limits)
                } else if let q = fallbackQuota, let r = q.remaining, let t = q.total, t > 0 {
                    let frac = menuBarQuotaFraction(remainingFraction: Double(r) / Double(t), resetAt: q.resetAt, now: now)
                    MenuBarQuotaPanel(
                        title: "5小时余量",
                        fraction: frac,
                        primaryValue: menuBarQuotaPercentText(frac),
                        countdown: q.resetAt.map { menuBarTimeOnlyResetString(for: $0) },
                        footer: menuBarQuotaRefreshFooter(resetAt: q.resetAt, now: now)
                    )
                } else {
                    MenuBarQuotaUnavailable()
                }
                if let statusMessage {
                    Text(statusMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
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
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if account.isCurrent {
                            Text("当前")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let subtitleText = account.subtitleText {
                        Text(subtitleText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else if let metaText = account.metaText {
                        Text(metaText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                if !account.isCurrent {
                    Button("切换") {
                        onSwitch(account.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.system(size: 11))
                    .disabled(isSwitching)
                }
            }

            if let limits = account.limits {
                if codexMenuBarQuotaRows(for: limits).isEmpty {
                    Text("尚未获取配额")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    CodexMenuBarQuotaRows(limits: limits)
                }
                if let resetCredits = limits.resetCredits {
                    CodexResetCreditsLine(resetCredits: resetCredits)
                }
            } else if let error = account.usageError {
                Text(error).font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("尚未获取配额").font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
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
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("\(availableCount)")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
            if let expiryText {
                Text("过期")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(expiryText)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Color.primary.opacity(0.78))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.top, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .font(.system(size: 11))
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
                        .font(.system(size: 11))
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
    @State private var routerStatus: CodexRouterStatus?
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
                        if canSwitchProvider(provider) {
                            switchProvider(provider)
                        } else {
                            onMessage(switchDisabledReason(provider) ?? "该 Provider 当前不可用")
                        }
                    } label: {
                        HStack {
                            Text(provider.name)
                            Spacer()
                            if provider.id == providerState.currentProviderID {
                                Image(systemName: "checkmark")
                            } else if provider.defaultModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text("未配模型")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(isSwitching)
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
        .focusEffectDisabled()
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
            let status = await appStore.codexRouterCoordinator.loadStatus()
            await MainActor.run {
                providerState = state
                routerStatus = status
            }
        } catch {
            await MainActor.run {
                providerState = nil
                routerStatus = nil
                onMessage(error.localizedDescription)
            }
        }
    }

    private func switchProvider(_ provider: CodexProviderConfig) {
        isSwitching = true
        let previousProviderID = providerState?.currentProviderID
        Task {
            do {
                let state = try await appStore.codexProviderConfigService.switchProvider(
                    id: provider.id,
                    allowThirdParty: canSwitchProvider(provider)
                )
                let status = await appStore.codexRouterCoordinator.loadStatus()
                await appStore.syncService?.sync(tool: .codex)
                await MainActor.run {
                    providerState = state
                    routerStatus = status
                    isSwitching = false
                    AppLogger.shared.recordDiagnostic(
                        level: .info,
                        scope: CodexRouterDiagnostics.diagnosticScope,
                        message: CodexRouterDiagnostics.switchedToProviderMessage(providerID: provider.id)
                    )
                    onMessage(String(localized: "已切换到 \(provider.name)"))
                    GlobalHotkeyService.shared.closeMenuBar()
                }
            } catch {
                let originalError = error.localizedDescription
                await MainActor.run {
                    AppLogger.shared.recordDiagnostic(
                        level: .warning,
                        scope: CodexRouterDiagnostics.diagnosticScope,
                        message: CodexRouterDiagnostics.switchProviderFailedMessage(
                            target: provider.id,
                            reason: originalError
                        )
                    )
                }
                await MainActor.run {
                    isSwitching = false
                }

                if let previousProviderID, previousProviderID != provider.id {
                    let rollbackID = previousProviderID
                    do {
                        let rollbackState = try await appStore.codexProviderConfigService.switchProvider(
                            id: rollbackID,
                            allowThirdParty: true
                        )
                        let rollbackStatus = await appStore.codexRouterCoordinator.loadStatus()
                        let rollbackSnapshot = describeRollbackTarget(
                            providerID: rollbackID,
                            in: rollbackState,
                            at: Date()
                        )
                        await MainActor.run {
                            providerState = rollbackState
                            routerStatus = rollbackStatus
                            AppLogger.shared.recordDiagnostic(
                                level: .info,
                                scope: CodexRouterDiagnostics.diagnosticScope,
                                message: CodexRouterDiagnostics.rollbackSucceededMessage(snapshot: rollbackSnapshot)
                            )
                            onMessage(CodexRouterDiagnostics.userRollbackNoticeMessage(
                                snapshot: rollbackSnapshot,
                                reason: originalError
                            ))
                        }
                    } catch {
                        await MainActor.run {
                            AppLogger.shared.recordDiagnostic(
                                level: .error,
                                scope: CodexRouterDiagnostics.diagnosticScope,
                                message: CodexRouterDiagnostics.rollbackFailedMessage(
                                    target: provider.id,
                                    fallback: previousProviderID,
                                    reason: error.localizedDescription
                                )
                            )
                        }
                        await MainActor.run {
                            onMessage(CodexRouterDiagnostics.userRollbackFailureMessage(
                                rollbackError: error.localizedDescription,
                                originalReason: originalError
                            ))
                        }
                    }
                } else {
                    await MainActor.run {
                        onMessage(originalError)
                    }
                }
            }
        }
    }

    private func canSwitchProvider(_ provider: CodexProviderConfig) -> Bool {
        if provider.id == CodexRouterConstants.openAIProviderID {
            return true
        }
        guard let routerStatus, routerStatus.canUseRouter else { return false }
        return !provider.defaultModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func switchDisabledReason(_ provider: CodexProviderConfig) -> String? {
        if provider.id == CodexRouterConstants.openAIProviderID {
            return nil
        }
        if provider.defaultModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "该 Provider 未配置默认模型"
        }
        guard let status = routerStatus else {
            return "Router 状态尚未就绪"
        }
        if !status.isConfigured {
            return "未检测到 codex-router 配置"
        }
        if !status.isUserEnabled {
            return "请先在 Providers 中开启 Router"
        }
        if !status.isRouterHealthy {
            return status.healthError ?? "Router 未就绪"
        }
        return nil
    }

    private func describeRollbackTarget(
        providerID: String,
        in state: CodexProviderConfigurationState,
        at timestamp: Date,
    ) -> String {
        CodexRouterDiagnostics.rollbackSnapshot(providerID: providerID, in: state, at: timestamp)
    }
}

// MARK: - Copilot

struct CopilotQuotaCard: View {
    @Environment(\.menuBarQuotaNow) private var now
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
                            HStack(alignment: .top, spacing: 16) {
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
                let frac = menuBarQuotaFraction(remainingFraction: Double(r) / Double(t), resetAt: q.resetAt, now: now)
                let used = t - r
                MenuBarQuotaPanel(
                    title: "Copilot 余量",
                    fraction: frac,
                    primaryValue: menuBarQuotaPercentText(frac),
                    countdown: q.resetAt.map { menuBarShortResetString(for: $0) },
                    footer: menuBarQuotaRefreshFooter(resetAt: q.resetAt, now: now) ?? "\(used)/\(t)"
                )
            } else {
                MenuBarQuotaUnavailable()
            }
        }
    }

    private func copilotPanel(for snapshot: CopilotSnapshot) -> some View {
        let isInf = snapshot.unlimited ?? false
        let fraction = menuBarQuotaFraction(
            remainingFraction: snapshot.percentRemaining.map { $0 / 100 },
            resetAt: resetAt,
            now: now
        )
        let countsText: String? = {
            if let remaining = snapshot.remaining, let entitlement = snapshot.entitlement {
                return "\(max(0, remaining))/\(entitlement)"
            }
            return nil
        }()

        return MenuBarQuotaPanel(
            title: snapshot.displayName,
            fraction: isInf ? 1.0 : fraction,
            primaryValue: isInf ? "∞" : menuBarQuotaPercentText(fraction),
            countdown: resetAt.map { menuBarShortResetString(for: $0) },
            footer: isInf ? countsText : (menuBarQuotaRefreshFooter(resetAt: resetAt, now: now) ?? countsText)
        )
    }
}

// MARK: - Antigravity

private struct AGMenuBarGroupCard: View {
    @Environment(\.menuBarQuotaNow) private var now
    let group: AGQuotaGroup
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(group.displayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            
            let fiveHourFraction = agQuotaDisplayFraction(for: group.fiveHour)
            let weeklyFraction = agQuotaDisplayFraction(for: group.weekly)
            let fiveHourReset = group.fiveHour?.resetTime.flatMap { $0 > now ? $0 : nil }
            let weeklyReset = group.weekly?.resetTime.flatMap { $0 > now ? $0 : nil }
            let isWeeklyExhausted = weeklyFraction.map { $0 <= 0.001 } ?? false
            let is5hUnusable = isWeeklyExhausted || (fiveHourFraction.map { $0 <= 0.001 } ?? false)
            HStack(alignment: .top, spacing: 16) {
                MenuBarQuotaPanel(
                    title: "5小时余量",
                    fraction: fiveHourFraction,
                    primaryValue: menuBarQuotaPercentText(fiveHourFraction),
                    countdown: fiveHourReset.map { menuBarTimeOnlyResetString(for: $0) },
                    footer: isWeeklyExhausted ? String(localized: "本周额度已耗尽") : nil,
                    isExhaustedOverride: is5hUnusable
                )
                MenuBarQuotaPanel(
                    title: "本周余量",
                    fraction: weeklyFraction,
                    primaryValue: menuBarQuotaPercentText(weeklyFraction),
                    countdown: weeklyReset.map { menuBarShortResetString(for: $0) },
                    footer: nil
                )
            }
        }
    }
}

private struct AGMenuBarAccountQuotaBody: View {
    let account: AGAccountQuota
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(account.email)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(account.badgeLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Spacer()
            }
            if account.groups.isEmpty {
                MenuBarQuotaUnavailable()
            } else {
                ForEach(account.groups) { AGMenuBarGroupCard(group: $0) }
            }
        }
    }
}

func menuBarVisibleAntigravityAccounts(
    _ accounts: [AGAccountQuota],
    hiddenAccountEmailsRaw: String
) -> [AGAccountQuota] {
    let hiddenEmails = Set(hiddenAccountEmailsRaw.components(separatedBy: ",").filter { !$0.isEmpty })
    return accounts.filter { !hiddenEmails.contains($0.email) }
}

/// Top-level card: shared header (logo + title + ConfigShortcut + TodayTokenBadge),
/// then one section per account separated by dividers — mirrors CodexMultiAccountQuotaCard.
struct AntigravityMultiAccountCard: View {
    let accounts: [AGAccountQuota]
    let todayTokens: Int
    @AppStorage("ag.hiddenAccountEmails") private var hiddenAccountEmailsRaw = ""

    private var visibleAccounts: [AGAccountQuota] {
        menuBarVisibleAntigravityAccounts(accounts, hiddenAccountEmailsRaw: hiddenAccountEmailsRaw)
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
            VStack(spacing: 10) {
                if visibleAccounts.isEmpty {
                    Text("暂无可用账号额度")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(visibleAccounts) { account in
                    AGMenuBarAccountQuotaBody(account: account)
                    if account.id != visibleAccounts.last?.id {
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
    @AppStorage("ag.hiddenAccountEmails") private var hiddenAccountEmailsRaw = ""

    private var visibleAccounts: [AGAccountQuota] {
        menuBarVisibleAntigravityAccounts(accounts, hiddenAccountEmailsRaw: hiddenAccountEmailsRaw)
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
            if visibleAccounts.isEmpty {
                Text("暂无可用账号额度")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                let summary = AntigravityProAggregator.aggregate(accounts: visibleAccounts)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text("账号额度聚合 (\(summary.proAccountCount)个账号)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    
                    ForEach(summary.groups) { group in
                        AGMenuBarGroupCard(group: group)
                    }
                }
            }
        }
    }
}

/// Content for a single Antigravity account (email + tier badge + quota groups).
/// No outer card chrome — used inside AntigravityMultiAccountCard.
struct AntigravityAccountSection: View {
    let account: AGAccountQuota
    @AppStorage("ag.hiddenAccountEmails") private var hiddenAccountEmailsRaw = ""

    private var isAccountHidden: Bool {
        Set(hiddenAccountEmailsRaw.components(separatedBy: ",").filter { !$0.isEmpty }).contains(account.email)
    }

    var body: some View {
        if isAccountHidden { EmptyView() } else {
            AGMenuBarAccountQuotaBody(account: account)
        }
    }
}

struct AntigravityFallbackCard: View {
    @Environment(\.menuBarQuotaNow) private var now
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
                let frac = menuBarQuotaFraction(remainingFraction: Double(r) / Double(t), resetAt: quota.resetAt, now: now)
                MenuBarQuotaPanel(
                    title: "总余量",
                    fraction: frac,
                    primaryValue: menuBarQuotaPercentText(frac),
                    countdown: quota.resetAt.map { menuBarShortResetString(for: $0) },
                    footer: menuBarQuotaRefreshFooter(resetAt: quota.resetAt, now: now)
                )
            } else {
                MenuBarQuotaUnavailable()
            }
        }
    }
}

private extension View {
    func menuBarCardSurface() -> some View {
        padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.055), lineWidth: 0.5)
            }
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
