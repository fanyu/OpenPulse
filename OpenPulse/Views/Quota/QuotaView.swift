import SwiftUI
import SwiftData

/// 配额页：展示各工具当前配额卡片 + 今日/累计用量汇总
struct QuotaView: View {
    @Environment(AppStore.self) private var appStore
    // Use DailyStatsRecord for token aggregates — much smaller fetch than all SessionRecords.
    @Query(sort: \QuotaRecord.updatedAt, order: .reverse) private var quotas: [QuotaRecord]
    @State private var usageSnapshotError: String?

    @State private var selectedTool: Tool? = nil
    @AppStorage("menubar.toolOrder") private var toolOrderRaw = Tool.defaultOrderRaw

    // Cached token aggregates — one pass over daily stats instead of all sessions.
    @State private var cachedTodayTokens: Int = 0
    @State private var cachedWeekTokens: Int = 0
    @State private var cachedTotalTokens: Int = 0
    @State private var cachedTodayByTool: [Tool: Int] = [:]

    private func reloadUsageSnapshot() {
        do {
            let context = ModelContext(appStore.modelContainer)
            let records = try context.fetch(FetchDescriptor<DailyStatsRecord>())
            let snapshot = QuotaUsageTotals.summarize(records, at: Date(), calendar: .current)
            cachedTodayTokens = snapshot.today
            cachedWeekTokens = snapshot.week
            cachedTotalTokens = snapshot.total
            cachedTodayByTool = snapshot.byTool
            usageSnapshotError = nil
        } catch {
            // Preserve the previous successful snapshot if the store cannot be read.
            usageSnapshotError = error.localizedDescription
        }
    }

    private var orderedTools: [Tool] {
        let preferred = toolOrderRaw.components(separatedBy: ",").compactMap { Tool(rawValue: $0) }
        var seen: Set<Tool> = []
        return (preferred + Tool.allCases).filter { seen.insert($0).inserted }
    }

    private var isSyncing: Bool { appStore.syncService?.isSyncingActive ?? false }

    // MARK: - Aggregated stats (served from cache)

    private var todayTokens: Int { cachedTodayTokens }
    private var weekTokens: Int { cachedWeekTokens }
    private var totalTokens: Int { cachedTotalTokens }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let usageSnapshotError {
                    UsageSnapshotErrorBanner(message: usageSnapshotError, retry: reloadUsageSnapshot)
                }
                QuotaDashboardHeader(
                    today: todayTokens,
                    week: weekTokens,
                    total: totalTokens,
                    isSyncing: isSyncing,
                    lastSync: appStore.syncService?.lastSyncDate
                )

                QuotaCardsSection(
                    selectedTool: $selectedTool,
                    orderedTools: orderedTools,
                    quotas: quotas,
                    todayByTool: cachedTodayByTool
                )
            }
            .frame(maxWidth: 1180, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .background {
            UsageSnapshotRefreshObserver(reload: reloadUsageSnapshot)
        }
        .navigationTitle("配额仪表盘")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await appStore.syncService?.sync() }
                } label: {
                    Label("立即刷新", systemImage: "arrow.clockwise")
                }
                .disabled(isSyncing)
            }
        }
    }

}

private enum QuotaCardItem: Identifiable {
    case tool(Tool)
    case antigravityAccount(AGAccountQuota)

    var id: String {
        switch self {
        case .tool(let tool): tool.rawValue
        case .antigravityAccount(let account): "ag-\(account.id)"
        }
    }
}

private struct QuotaCardsSection: View {
    @Environment(AppStore.self) private var appStore
    @Binding var selectedTool: Tool?
    let orderedTools: [Tool]
    let quotas: [QuotaRecord]
    let todayByTool: [Tool: Int]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            DashboardSectionTitle(title: String(localized: "实时配额详情"))
            QuotaToolFilterBar(selectedTool: $selectedTool)
            if let selectedTool {
                QuotaToolCard(tool: selectedTool, quotas: quotas, todayTokens: todayByTool[selectedTool] ?? 0)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 340), spacing: 16, alignment: .top)],
                    alignment: .leading,
                    spacing: 16
                ) {
                    ForEach(cards) { item in
                        QuotaCard(item: item, quotas: quotas, todayByTool: todayByTool)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
        }
    }

    private var cards: [QuotaCardItem] {
        orderedTools.flatMap { tool in
            if tool == .antigravity, let accounts = appStore.syncService?.latestAntigravityAccounts, !accounts.isEmpty {
                return accounts.map { QuotaCardItem.antigravityAccount($0) }
            }
            return [QuotaCardItem.tool(tool)]
        }
    }
}

private struct QuotaCard: View {
    let item: QuotaCardItem
    let quotas: [QuotaRecord]
    let todayByTool: [Tool: Int]

    var body: some View {
        switch item {
        case .tool(let tool):
            QuotaToolCard(tool: tool, quotas: quotas, todayTokens: todayByTool[tool] ?? 0)
        case .antigravityAccount(let account):
            QuotaAntigravityAccountCard(account: account)
        }
    }
}

private struct QuotaToolCard: View {
    @Environment(AppStore.self) private var appStore
    @State private var localRefreshInFlight = false
    let tool: Tool
    let quotas: [QuotaRecord]
    let todayTokens: Int

    private var isRefreshing: Bool {
        localRefreshInFlight || (appStore.syncService?.states[tool].isRefreshing ?? false)
    }

    var body: some View {
        switch tool {
        case .claudeCode:
            ClaudeDetailCard(
                usage: appStore.syncService?.latestClaudeUsage,
                quota: quotas.first { $0.toolRaw == Tool.claudeCode.rawValue },
                accountInfo: appStore.syncService?.latestClaudeAccountInfo,
                todayTokens: todayTokens,
                isRefreshing: isRefreshing,
                onRefresh: refresh
            )
        case .codex:
            if let accounts = appStore.syncService?.latestCodexAccounts, !accounts.isEmpty {
                CodexAccountsDetailCard(accounts: accounts, todayTokens: todayTokens, isRefreshing: isRefreshing, onRefresh: refresh)
            } else {
                CodexDetailCard(
                    limits: nil,
                    fallbackQuota: quotas.first { $0.toolRaw == Tool.codex.rawValue && $0.accountKey == nil },
                    todayTokens: todayTokens,
                    isRefreshing: isRefreshing,
                    onRefresh: refresh
                )
            }
        case .copilot:
            CopilotDetailCard(
                snapshots: appStore.syncService?.latestCopilotSnapshots,
                resetAt: appStore.syncService?.latestCopilotResetAt,
                plan: appStore.syncService?.latestCopilotPlan,
                fallbackQuota: quotas.first { $0.toolRaw == Tool.copilot.rawValue },
                todayTokens: todayTokens,
                isRefreshing: isRefreshing,
                onRefresh: refresh
            )
        case .antigravity:
            if let accounts = appStore.syncService?.latestAntigravityAccounts, !accounts.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(accounts) { account in
                        QuotaAntigravityAccountCard(account: account)
                    }
                }
            } else {
                AntigravityDetailFallbackCard(
                    quota: quotas.first { $0.toolRaw == Tool.antigravity.rawValue },
                    todayTokens: todayTokens,
                    isRefreshing: isRefreshing,
                    onRefresh: refresh
                )
            }
        }
    }

    private func refresh() {
        guard !isRefreshing, let service = appStore.syncService else { return }
        localRefreshInFlight = true
        Task {
            await service.sync(tool: tool)
            localRefreshInFlight = false
        }
    }
}

private struct QuotaAntigravityAccountCard: View {
    @Environment(AppStore.self) private var appStore
    @State private var localRefreshInFlight = false
    let account: AGAccountQuota

    private var isRefreshing: Bool {
        localRefreshInFlight
            || (appStore.syncService?.states[.antigravity].isRefreshing ?? false)
            || (appStore.syncService?.refreshingAntigravityAccountEmails.contains(account.email) ?? false)
    }

    var body: some View {
        AntigravityDetailCard(account: account, todayTokens: 0, isRefreshing: isRefreshing, onRefresh: refresh)
    }

    private func refresh() {
        guard !isRefreshing, let service = appStore.syncService else { return }
        localRefreshInFlight = true
        Task {
            await service.refreshAntigravityAccount(email: account.email)
            localRefreshInFlight = false
        }
    }
}

/// Canonical daily-stat aggregates for the quota dashboard.
struct QuotaUsageTotals {
    let today: Int
    let week: Int
    let total: Int
    let byTool: [Tool: Int]

    static func summarize(_ records: [DailyStatsRecord], at date: Date, calendar: Calendar) -> Self {
        let todayStart = calendar.startOfDay(for: date)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? todayStart
        var today = 0
        var week = 0
        var total = 0
        var byTool: [Tool: Int] = [:]
        for record in records where record.date < tomorrow {
            let tokens = record.totalInputTokens + record.totalOutputTokens
            total += tokens
            if record.date >= weekStart { week += tokens }
            if record.date >= todayStart {
                today += tokens
                byTool[record.tool, default: 0] += tokens
            }
        }
        return Self(today: today, week: week, total: total, byTool: byTool)
    }
}

// MARK: - Dashboard Header

struct QuotaDashboardHeader: View {
    let today: Int
    let week: Int
    let total: Int
    let isSyncing: Bool
    let lastSync: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("配额仪表盘")
                    .font(.system(size: 28, weight: .semibold))
                Text("查看可用额度、重置时间与 Token 用量。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                QuotaSyncStatus(isSyncing: isSyncing, lastSync: lastSync)
            }

            QuotaUsageStrip(today: today, week: week, total: total)
        }
    }
}

private struct QuotaSyncStatus: View {
    let isSyncing: Bool
    let lastSync: Date?

    var body: some View {
        HStack(spacing: 6) {
            if isSyncing {
                ProgressView().controlSize(.small)
                Text("数据同步中...")
            } else if let lastSync {
                Image(systemName: "checkmark.circle")
                Text("最近同步于 \(lastSync.formatted(.dateTime.hour().minute()))")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
}

private struct QuotaUsageStrip: View {
    let today: Int
    let week: Int
    let total: Int

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 24) {
                DashboardMetric(title: String(localized: "今日用量"), value: today.compactTokenString, subtitle: "Tokens")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider().frame(height: 50)
                DashboardMetric(title: String(localized: "本周合计"), value: week.compactTokenString, subtitle: "Tokens")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider().frame(height: 50)
                DashboardMetric(title: String(localized: "累计消耗"), value: total.compactTokenString, subtitle: "Tokens")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 440)

            VStack(alignment: .leading, spacing: 18) {
                DashboardMetric(title: String(localized: "今日用量"), value: today.compactTokenString, subtitle: "Tokens")
                Divider()
                DashboardMetric(title: String(localized: "本周合计"), value: week.compactTokenString, subtitle: "Tokens")
                Divider()
                DashboardMetric(title: String(localized: "累计消耗"), value: total.compactTokenString, subtitle: "Tokens")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(22)
        .dashboardSurface()
    }
}

private struct QuotaToolFilterBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selectedTool: Tool?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                QuotaToolFilterButton(label: String(localized: "全部"), isSelected: selectedTool == nil) {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1)) {
                        selectedTool = nil
                    }
                }
                ForEach(Tool.allCases, id: \.self) { tool in
                    QuotaToolFilterButton(label: tool.displayName, isSelected: selectedTool == tool) {
                        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1)) {
                            selectedTool = selectedTool == tool ? nil : tool
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }
}

private struct QuotaToolFilterButton: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isSelected ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Tool-Specific Detail Views

struct ClaudeDetailCard: View {
    let usage: ClaudeUsageResponse?
    let quota: QuotaRecord?
    let accountInfo: ClaudeAccountInfo?
    let todayTokens: Int
    let isRefreshing: Bool
    let onRefresh: () -> Void

    var body: some View {
        DetailCardContainer(
            tool: .claudeCode,
            todayTokens: todayTokens,
            title: Tool.claudeCode.displayName,
            subtitle: nil,
            tagText: accountInfo?.displaySubscriptionName,
            isRefreshing: isRefreshing,
            onRefresh: onRefresh
        ) {
            if let usage {
                VStack(spacing: 12) {
                    ClaudeDetailRow(label: "5h Session", window: usage.fiveHour)
                    Divider().opacity(0.5)
                    ClaudeDetailRow(label: "7d Weekly", window: usage.sevenDay)
                }
            } else if let q = quota, let r = q.remaining, let t = q.total, t > 0 {
                let frac = Double(r) / Double(t)
                let pct = Int((frac * 100).rounded())
                UnifiedQuotaRow(
                    title: "5h Session",
                    fraction: frac,
                    primaryValue: "\(pct)%",
                    secondaryValue: String(localized: "已用 \(max(0, 100 - pct))%"),
                    countdown: q.toModel().resetCountdown
                )
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90").foregroundStyle(.secondary)
                    Text("Quota data unavailable").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct ClaudeDetailRow: View {
    let label: String
    let window: UsageWindow?
    
    private var frac: Double? {
        guard let u = window?.utilization else { return nil }
        return max(0, min(1, (100 - u) / 100))
    }
    
    var body: some View {
        let used = window?.utilization.map { Int($0.rounded()) }
        let rem = used.map { max(0, 100 - $0) }
        let isWeekly = label.contains("7d")
        let date = window?.resetDate
        let footer = date.map {
            isWeekly
                ? $0.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits))
                : $0.formatted(.dateTime.hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits))
        }
        
        UnifiedQuotaRow(
            title: label,
            fraction: frac,
            primaryValue: rem.map { "\($0)%" },
            secondaryValue: used.map { String(localized: "已用 \($0)%") },
            countdown: footer
        )
    }
}

struct CodexDetailCard: View {
    let limits: CodexRateLimits?
    let fallbackQuota: QuotaRecord?
    let todayTokens: Int
    let isRefreshing: Bool
    let onRefresh: () -> Void

    var body: some View {
        DetailCardContainer(
            tool: .codex,
            todayTokens: todayTokens,
            tagText: normalizedSubscriptionDisplayName(limits?.planType),
            isRefreshing: isRefreshing,
            onRefresh: onRefresh
        ) {
            if let limits {
                CodexRateLimitsDetailRows(limits: limits)
            } else if let quota = fallbackQuota {
                CodexDetailRow(
                    label: "5h Session",
                    window: CodexWindow(
                        usedPercent: quota.toModel().fraction.map { (1 - $0) * 100 },
                        windowMinutes: 300,
                        windowSeconds: nil,
                        resetsAt: quota.resetAt?.timeIntervalSince1970
                    )
                )
            } else {
                Text("尚未获取数据").foregroundStyle(.secondary)
            }
        }
    }
}

struct CodexAccountsDetailCard: View {
    let accounts: [CodexAccountSnapshot]
    let todayTokens: Int
    let isRefreshing: Bool
    let onRefresh: () -> Void

    var body: some View {
        DetailCardContainer(tool: .codex, todayTokens: todayTokens, isRefreshing: isRefreshing, onRefresh: onRefresh) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(accounts) { account in
                    CodexAccountDetailRow(account: account)
                    if account.id != accounts.last?.id {
                        Divider().opacity(0.35)
                    }
                }
            }
        }
    }
}

struct CodexAccountDetailRow: View {
    let account: CodexAccountSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(account.titleText)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let displaySubscriptionName = account.displaySubscriptionName {
                            SubscriptionTag(text: displaySubscriptionName)
                        }
                    }
                    if let subtitleText = account.subtitleText {
                        Text(subtitleText)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let metaText = account.metaText {
                        Text(metaText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                if account.isCurrent {
                    Label("当前账号", systemImage: "checkmark.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            if let limits = account.limits {
                CodexRateLimitsDetailRows(limits: limits)
            } else if let error = account.usageError {
                Text(error).foregroundStyle(.secondary)
            } else {
                Text("尚未获取数据").foregroundStyle(.secondary)
            }
        }
    }
}

struct CodexRateLimitsDetailRows: View {
    let limits: CodexRateLimits

    var body: some View {
        let rows = codexMenuBarQuotaRows(for: limits)
        let hasMultipleRows = rows.count > 1
        VStack(spacing: 12) {
            ForEach(rows.enumerated(), id: \.element.id) { index, row in
                if index > 0 {
                    Divider().opacity(0.5)
                }
                let prefix = (hasMultipleRows || row.id != "codex") ? "\(row.title) " : ""
                CodexDetailRow(label: "\(prefix)5h Session", window: row.fiveHourWindow)
                Divider().opacity(0.5)
                CodexDetailRow(label: "\(prefix)7d Weekly", window: row.oneWeekWindow)
            }

            if let resetCredits = limits.resetCredits {
                Divider().opacity(0.5)
                CodexResetCreditsDetailRow(resetCredits: resetCredits)
            }
        }
    }
}

struct CodexDetailRow: View {
    let label: String
    let window: CodexWindow?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            CodexQuotaWindowRow(label: label, window: window, now: context.date)
        }
    }
}

/// A deadline passing invalidates the saved window; it cannot establish that
/// a newly started server window is unused.
struct CodexQuotaWindowDisplay {
    let isStale: Bool
    let used: Int?
    let remaining: Int?
    let fraction: Double?

    init(window: CodexWindow?, at now: Date) {
        isStale = window?.resetDate.map { $0 <= now } ?? false
        guard !isStale, let usedPercent = window?.usedPercent, usedPercent.isFinite else {
            used = nil
            remaining = nil
            fraction = nil
            return
        }
        let clamped = min(100, max(0, usedPercent))
        used = Int(clamped.rounded())
        remaining = 100 - Int(clamped.rounded())
        fraction = (100 - clamped) / 100
    }
}

private struct CodexQuotaWindowRow: View {
    let label: String
    let window: CodexWindow?
    let now: Date

    var body: some View {
        let display = CodexQuotaWindowDisplay(window: window, at: now)
        let isLong = (window?.windowMinutes ?? 0) > 1440
        let footer = display.isStale ? nil : window?.resetDate.map {
            isLong
                ? $0.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits))
                : $0.formatted(.dateTime.hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits))
        }
        UnifiedQuotaRow(
            title: label,
            fraction: display.fraction,
            primaryValue: display.remaining.map { "\($0)%" },
            secondaryValue: display.isStale ? String(localized: "窗口已到期，请刷新") : display.used.map { String(localized: "已用 \($0)%") },
            countdown: footer
        )
    }
}

struct CodexResetCreditsDetailRow: View {
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

    private var detailText: String {
        let values = availableCredits.compactMap { credit in
            credit.expiresAt.map {
                $0.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits))
            }
        }
        guard !values.isEmpty else {
            return String(localized: "服务端未返回明细")
        }
        let expirationDates = values.formatted()
        return String(localized: "分别过期于 \(expirationDates)")
    }

    var body: some View {
        UnifiedQuotaRow(
            title: String(localized: "可用重置券"),
            fraction: nil,
            primaryValue: "\(availableCount)",
            secondaryValue: detailText,
            countdown: nil
        )
    }
}

struct CopilotDetailCard: View {
    let snapshots: [String: CopilotSnapshot]?
    let resetAt: Date?
    let plan: String?
    let fallbackQuota: QuotaRecord?
    let todayTokens: Int
    let isRefreshing: Bool
    let onRefresh: () -> Void

    private var ordered: [(key: String, value: CopilotSnapshot)] {
        guard let s = snapshots else { return [] }
        return s.sorted { a, b in
            if a.key == "premium_interactions" { return true }
            if b.key == "premium_interactions" { return false }
            return a.key < b.key
        }
    }

    var body: some View {
        DetailCardContainer(
            tool: .copilot,
            todayTokens: todayTokens,
            tagText: normalizedCopilotPlanDisplayName(plan),
            isRefreshing: isRefreshing,
            onRefresh: onRefresh
        ) {
            if !ordered.isEmpty {
                VStack(spacing: 12) {
                    let orderedArray = ordered
                    ForEach(orderedArray.enumerated(), id: \.element.key) { index, item in
                        if index > 0 { Divider().opacity(0.5) }
                        CopilotDetailRow(snapshot: item.value)
                    }
                    if let resetAt {
                        HStack {
                            Spacer()
                            Text("全局重置于 \(resetAt.formatted(.dateTime.year().month().day()))")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            } else if let fallbackQuota {
                SavedQuotaDetailRow(quota: fallbackQuota.toModel())
            } else {
                Text("尚未获取数据").foregroundStyle(.secondary)
            }
        }
    }
}

struct CopilotDetailRow: View {
    let snapshot: CopilotSnapshot
    
    private var isInf: Bool { snapshot.unlimited ?? false }
    private var frac: Double? {
        if isInf { return 1.0 }
        guard let p = snapshot.percentRemaining else { return nil }
        return p / 100.0
    }
    
    var body: some View {
        let secondary: String? = {
            if let r = snapshot.remaining, let t = snapshot.entitlement {
                return "\(t - r)/\(t)"
            }
            return nil
        }()
        
        UnifiedQuotaRow(
            style: .detailed,
            showUsedAtTop: true,
            title: snapshot.displayName,
            fraction: frac,
            primaryValue: isInf ? "∞" : snapshot.percentRemaining.map { "\(Int($0))%" },
            secondaryValue: secondary,
            countdown: nil
        )
    }
}

struct AntigravityDetailCard: View {
    let account: AGAccountQuota
    let todayTokens: Int
    let isRefreshing: Bool
    let onRefresh: () -> Void

    var body: some View {
        DetailCardContainer(tool: .antigravity, todayTokens: 0, isRefreshing: isRefreshing, onRefresh: onRefresh) {
            AGAccountQuotaBody(account: account)
        }
    }
}

struct AntigravityDetailFallbackCard: View {
    let quota: QuotaRecord?
    let todayTokens: Int
    let isRefreshing: Bool
    let onRefresh: () -> Void
    var body: some View {
        DetailCardContainer(tool: .antigravity, todayTokens: todayTokens, isRefreshing: isRefreshing, onRefresh: onRefresh) {
            if let quota {
                SavedQuotaDetailRow(quota: quota.toModel())
            } else {
                Text("尚未获取数据").foregroundStyle(.secondary)
            }
        }
    }
}

private struct SavedQuotaDetailRow: View {
    let quota: ToolQuota

    var body: some View {
        UnifiedQuotaRow(
            title: String(localized: "最近同步配额"),
            fraction: quota.fraction,
            primaryValue: quota.fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? quota.remaining.map { $0.formatted() },
            secondaryValue: nil,
            countdown: quota.resetCountdown
        )
    }
}
