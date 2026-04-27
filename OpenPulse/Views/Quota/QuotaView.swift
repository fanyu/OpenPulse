import SwiftUI
import SwiftData

/// 配额页：展示各工具当前配额卡片 + 今日/累计用量汇总
struct QuotaView: View {
    @Environment(AppStore.self) private var appStore
    // Use DailyStatsRecord for token aggregates — much smaller fetch than all SessionRecords.
    @Query private var dailyStats: [DailyStatsRecord]
    @Query private var quotas: [QuotaRecord]

    @State private var selectedTool: Tool? = nil
    @AppStorage("menubar.toolOrder") private var toolOrderRaw = Tool.defaultOrderRaw
    @AppStorage("menubar.hiddenTools") private var hiddenToolsRaw = ""

    // Cached token aggregates — one pass over daily stats instead of all sessions.
    @State private var cachedTodayTokens: Int = 0
    @State private var cachedWeekTokens: Int = 0
    @State private var cachedTotalTokens: Int = 0
    @State private var cachedTodayByTool: [Tool: Int] = [:]
    @State private var refreshingTools: Set<Tool> = []

    private func rebuildTokenCache() {
        let today = Calendar.current.startOfDay(for: Date())
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: today)!
        var todayMap: [Tool: Int] = [:]
        var todayTotal = 0, weekTotal = 0, total = 0
        for stat in dailyStats {
            let tokens = stat.totalInputTokens + stat.totalOutputTokens
            total += tokens
            if stat.date >= weekAgo {
                weekTotal += tokens
                if stat.date >= today {
                    todayTotal += tokens
                    todayMap[stat.tool, default: 0] += tokens
                }
            }
        }
        cachedTodayTokens = todayTotal
        cachedWeekTokens = weekTotal
        cachedTotalTokens = total
        cachedTodayByTool = todayMap
    }

    private var orderedVisibleTools: [Tool] {
        let hidden = Set(hiddenToolsRaw.components(separatedBy: ",").filter { !$0.isEmpty })
        let order = toolOrderRaw.components(separatedBy: ",").compactMap { Tool(rawValue: $0) }
        let ordered = order + Tool.allCases.filter { !order.contains($0) }
        return ordered.filter { !hidden.contains($0.rawValue) }
    }

    private var isSyncing: Bool { appStore.syncService?.isSyncingActive ?? false }

    private func isRefreshing(_ tool: Tool) -> Bool {
        refreshingTools.contains(tool)
    }

    private func refresh(tool: Tool) {
        guard !refreshingTools.contains(tool), appStore.syncService != nil else { return }
        refreshingTools.insert(tool)
        Task {
            await appStore.syncService?.sync(tool: tool)
            refreshingTools.remove(tool)
        }
    }

    // MARK: - Aggregated stats (served from cache)

    private var todayTokens: Int { cachedTodayTokens }
    private var weekTokens: Int { cachedWeekTokens }
    private var totalTokens: Int { cachedTotalTokens }
    private func toolTodayTokens(for tool: Tool) -> Int { cachedTodayByTool[tool] ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Dashboard Header
                    QuotaDashboardHeader(
                        today: todayTokens,
                        week: weekTokens,
                        total: totalTokens,
                        isSyncing: isSyncing,
                        lastSync: appStore.syncService?.lastSyncDate
                    )

                    // Filter Bar
                    toolFilterBar
                        .padding(.top, -8)

                    // Quota Cards Grid
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeader(title: "实时配额详情")
                        
                        if let tool = selectedTool {
                            // Single tool filtered view
                            toolCard(for: tool)
                        } else {
                            // Flatten cards (AG accounts expanded) then split into left/right columns
                            let cards = waterfallCards
                            let leftCards  = cards.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
                            let rightCards = cards.enumerated().filter { $0.offset % 2 != 0 }.map(\.element)
                            HStack(alignment: .top, spacing: 16) {
                                VStack(spacing: 16) {
                                    ForEach(leftCards)  { item in card(for: item) }
                                }
                                .frame(maxWidth: .infinity)

                                VStack(spacing: 16) {
                                    ForEach(rightCards) { item in card(for: item) }
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
                .padding(24)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .task { rebuildTokenCache() }
        .onChange(of: dailyStats.count) { _, _ in rebuildTokenCache() }
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

    private var toolFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                FilterChip(label: "全部", isSelected: selectedTool == nil) {
                    withAnimation(.spring(duration: 0.3)) { selectedTool = nil }
                }
                ForEach(Tool.allCases, id: \.self) { tool in
                    FilterChip(label: tool.displayName, isSelected: selectedTool == tool) {
                        withAnimation(.spring(duration: 0.3)) {
                            selectedTool = (selectedTool == tool) ? nil : tool
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Waterfall helpers

    private enum WaterfallCard: Identifiable {
        case tool(Tool)
        case antigravityAccount(AGAccountQuota)

        var id: String {
            switch self {
            case .tool(let t): t.rawValue
            case .antigravityAccount(let a): "ag-\(a.id)"
            }
        }
    }

    private var waterfallCards: [WaterfallCard] {
        var result: [WaterfallCard] = []
        for tool in orderedVisibleTools {
            if tool == .antigravity,
               let accounts = appStore.syncService?.latestAntigravityAccounts,
               !accounts.isEmpty {
                for account in accounts { result.append(.antigravityAccount(account)) }
            } else {
                result.append(.tool(tool))
            }
        }
        return result
    }

    @ViewBuilder
    private func card(for item: WaterfallCard) -> some View {
        switch item {
        case .tool(let tool): toolCard(for: tool)
        case .antigravityAccount(let account):
            AntigravityDetailCard(
                account: account,
                todayTokens: toolTodayTokens(for: .antigravity),
                isRefreshing: isRefreshing(.antigravity),
                onRefresh: { refresh(tool: .antigravity) }
            )
        }
    }

    @ViewBuilder
    private func toolCard(for tool: Tool) -> some View {
        // Only render if tool is visible
        switch tool {
        case .claudeCode:
                ClaudeDetailCard(
                    usage: appStore.syncService?.latestClaudeUsage,
                    quota: quotas.first(where: { $0.tool == .claudeCode }),
                    accountInfo: appStore.syncService?.latestClaudeAccountInfo,
                    todayTokens: toolTodayTokens(for: .claudeCode),
                    isRefreshing: isRefreshing(.claudeCode),
                    onRefresh: { refresh(tool: .claudeCode) }
                )
            case .codex:
                if let accounts = appStore.syncService?.latestCodexAccounts, !accounts.isEmpty {
                    CodexAccountsDetailCard(
                        accounts: accounts,
                        todayTokens: toolTodayTokens(for: .codex),
                        isRefreshing: isRefreshing(.codex),
                        onRefresh: { refresh(tool: .codex) }
                    )
                } else {
                    CodexDetailCard(
                        limits: nil,
                        fallbackQuota: quotas.first(where: { $0.tool == .codex && $0.accountKey == nil }),
                        todayTokens: toolTodayTokens(for: .codex),
                        isRefreshing: isRefreshing(.codex),
                        onRefresh: { refresh(tool: .codex) }
                    )
                }
            case .copilot:
                CopilotDetailCard(
                    snapshots: appStore.syncService?.latestCopilotSnapshots,
                    resetAt: appStore.syncService?.latestCopilotResetAt,
                    plan: appStore.syncService?.latestCopilotPlan,
                    fallbackQuota: quotas.first(where: { $0.tool == .copilot }),
                    todayTokens: toolTodayTokens(for: .copilot),
                    isRefreshing: isRefreshing(.copilot),
                    onRefresh: { refresh(tool: .copilot) }
                )
            case .antigravity:
                if let accounts = appStore.syncService?.latestAntigravityAccounts {
                    ForEach(accounts) { account in
                        AntigravityDetailCard(
                            account: account,
                            todayTokens: toolTodayTokens(for: .antigravity),
                            isRefreshing: isRefreshing(.antigravity),
                            onRefresh: { refresh(tool: .antigravity) }
                        )
                    }
                } else if let fallback = quotas.first(where: { $0.tool == .antigravity }) {
                    AntigravityDetailFallbackCard(
                        quota: fallback,
                        todayTokens: toolTodayTokens(for: .antigravity),
                        isRefreshing: isRefreshing(.antigravity),
                        onRefresh: { refresh(tool: .antigravity) }
                    )
                }
            case .opencode:
                OpenCodeDetailCard(
                    todayTokens: toolTodayTokens(for: .opencode),
                    isRefreshing: isRefreshing(.opencode),
                    onRefresh: { refresh(tool: .opencode) }
                )
            }
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
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                StatCard(title: "今日用量", value: today.compactTokenString, unit: "Tokens", icon: "bolt.fill", color: .orange)
                StatCard(title: "本周合计", value: week.compactTokenString, unit: "Tokens", icon: "calendar", color: .blue)
                StatCard(title: "累计消耗", value: total.compactTokenString, unit: "Tokens", icon: "sum", color: .purple)
            }

            HStack {
                if isSyncing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("数据同步中...").font(.caption).foregroundStyle(.secondary)
                    }
                } else if let lastSync {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("配额已更新于 \(lastSync.formatted(.dateTime.hour().minute()))").font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 4)
        }
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
                    secondaryValue: "\(max(0, 100 - pct))% used",
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
        let footer = date.map { isWeekly ? countdownString(to: $0) : $0.formatted(.dateTime.hour().minute()) }
        
        UnifiedQuotaRow(
            title: label,
            fraction: frac,
            primaryValue: rem.map { "\($0)%" },
            secondaryValue: used.map { "\($0)% used" },
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
                VStack(spacing: 12) {
                    CodexDetailRow(label: "5h Session", window: limits.fiveHourWindow)
                    Divider().opacity(0.5)
                    CodexDetailRow(label: "7d Weekly", window: limits.oneWeekWindow)
                }
            } else if let q = fallbackQuota, let r = q.remaining, let t = q.total, t > 0 {
                let frac = Double(r) / Double(t)
                let pct = Int((frac * 100).rounded())
                UnifiedQuotaRow(
                    title: "5h Session",
                    fraction: frac,
                    primaryValue: "\(pct)%",
                    secondaryValue: "\(max(0, 100 - pct))% used",
                    countdown: q.toModel().resetCountdown
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
                        Text(account.titleText).font(.headline)
                        if let displaySubscriptionName = account.displaySubscriptionName {
                            SubscriptionTag(text: displaySubscriptionName)
                        }
                    }
                    if let subtitleText = account.subtitleText {
                        Text(subtitleText).font(.caption).foregroundStyle(.secondary)
                    }
                    if let metaText = account.metaText {
                        Text(metaText).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                if account.isCurrent {
                    Text("当前账号")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.green.opacity(0.12), in: Capsule())
                }
            }

            if let limits = account.limits {
                CodexDetailRow(label: "5h Session", window: limits.fiveHourWindow)
                Divider().opacity(0.5)
                CodexDetailRow(label: "7d Weekly", window: limits.oneWeekWindow)
            } else if let error = account.usageError {
                Text(error).foregroundStyle(.secondary)
            } else {
                Text("尚未获取数据").foregroundStyle(.secondary)
            }
        }
    }
}

struct CodexDetailRow: View {
    let label: String
    let window: CodexWindow?

    /// True when the rate limit window has already reset — the stored percentages
    /// are stale and must not be shown as if they reflect the current window.
    private var isStale: Bool {
        guard let d = window?.resetDate else { return false }
        return d < Date()
    }

    private var frac: Double? {
        guard !isStale, let u = window?.usedPercent else { return nil }
        return max(0, min(1, (100 - u) / 100))
    }

    var body: some View {
        let isLong = (window?.windowMinutes ?? 0) > 1440
        let used = window?.usedPercent.map { Int($0.rounded()) }
        let rem = used.map { max(0, 100 - $0) }
        let footer: String? = isStale
            ? "已重置"
            : window?.resetDate.map { isLong ? $0.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute()) : $0.formatted(.dateTime.hour().minute()) }

        UnifiedQuotaRow(
            title: label,
            fraction: frac,
            primaryValue: isStale ? "—" : rem.map { "\($0)%" },
            secondaryValue: isStale ? "数据已过期" : used.map { "\($0)% used" },
            countdown: footer
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
                    ForEach(0..<orderedArray.count, id: \.self) { idx in
                        let item = orderedArray[idx]
                        if idx > 0 { Divider().opacity(0.5) }
                        CopilotDetailRow(snapshot: item.value)
                    }
                    if let resetAt {
                        HStack {
                            Spacer()
                            Text("全局重置于 \(resetAt.formatted(.dateTime.year().month().day()))")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
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
        DetailCardContainer(tool: .antigravity, todayTokens: todayTokens, isRefreshing: isRefreshing, onRefresh: onRefresh) {
            VStack(alignment: .leading, spacing: 12) {
                Text(account.email).font(.caption).foregroundStyle(.secondary)
                
                let cols = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
                LazyVGrid(columns: cols, spacing: 12) {
                    ForEach(account.models, id: \.id) { model in
                        AntigravityModelGridCell(model: model)
                    }
                }
            }
        }
    }
}

struct AntigravityModelGridCell: View {
    let model: AGModelQuota
    
    var body: some View {
        let pct = model.remainingFraction.map { Int(($0 * 100).rounded()) }
        let used = pct.map { max(0, 100 - $0) }
        
        VStack(alignment: .leading, spacing: 8) {
            UnifiedQuotaRow(
                showUsedAtTop: true,
                valuePlacement: .bottomLeading,
                title: model.displayName,
                fraction: model.remainingFraction,
                primaryValue: pct.map { "\($0)%" },
                secondaryValue: used.map { "\($0)% used" },
                countdown: model.resetCountdown
            )
        }
        .padding(14)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct AntigravityDetailFallbackCard: View {
    let quota: QuotaRecord
    let todayTokens: Int
    let isRefreshing: Bool
    let onRefresh: () -> Void
    var body: some View {
        DetailCardContainer(tool: .antigravity, todayTokens: todayTokens, isRefreshing: isRefreshing, onRefresh: onRefresh) {
            Text("尚未获取数据").foregroundStyle(.secondary)
        }
    }
}

struct OpenCodeDetailCard: View {
    let todayTokens: Int
    let isRefreshing: Bool
    let onRefresh: () -> Void
    var body: some View {
        DetailCardContainer(tool: .opencode, todayTokens: todayTokens, isRefreshing: isRefreshing, onRefresh: onRefresh) {
            if todayTokens == 0 {
                Text("暂无数据").foregroundStyle(.secondary)
            }
        }
    }
}
