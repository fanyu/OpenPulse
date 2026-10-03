import SwiftUI
import SwiftData
import Charts

struct TrendsView: View {
    @Environment(AppStore.self) private var appStore
    @State private var allSessions: [SessionRecord] = []
    @State private var dailyStats: [DailyStatsRecord] = []
    @State private var usageReadContext: ModelContext?
    @State private var usageSnapshotError: String?
    @State private var snapshotDate = Date()
    @State private var usageSnapshotRevision: UInt64 = 0
    @Query(sort: \QuotaRecord.updatedAt, order: .reverse) private var allQuotas: [QuotaRecord]

    @State private var range: ChartRange = .month

    // Usage aggregates are derived when the persisted snapshot or selected range
    // changes. View layout reads scalar values and already prepared chart data.
    @State private var cachedSessionCount = 0
    @State private var cachedRangeTotalTokens = 0
    @State private var cachedRangeWoWDelta: Int?
    @State private var cachedGlobalCacheHitRate: Double = 0
    @State private var cachedAverageTokensPerSession = 0
    @State private var cachedTimelinePoints: [WeeklyAreaChart.Point] = []
    @State private var cachedBestDayTokens = 0
    @State private var cachedRangeTotalUSD: Double = 0
    @State private var cachedRangeTotalCNY: Double = 0
    @State private var cachedCostEfficiency: Double?
    @State private var cachedPerToolCost: [(tool: Tool, usd: Double, cny: Double)] = []
    @State private var cachedActiveDaysCount: Int = 0
    @State private var cachedCurrentStreak: Int = 0
    @State private var cachedMaxStreak: Int = 0
    @State private var cachedTodayTokens: Int = 0
    @State private var cachedYesterdayTokens: Int = 0
    @State private var cachedAggregateByTool: [(tool: Tool, tokens: Int)] = []
    @State private var cachedTopModelDeepData: [ModelDeepEntry] = []
    @State private var cachedProjectDistribution: [ProjectDist] = []
    @State private var cachedBranchDistribution: [BranchDist] = []
    @State private var cachedHourlyActivityPoints: [HourlyPoint] = []
    @State private var cachedWeekdayActivityPoints: [WeekdayPoint] = []
    @State private var cachedToolSummaryData: [ToolSummaryItem] = []
    @State private var cachedCostTimelinePoints: [WeeklyAreaChart.Point] = []
    @State private var cachedTopModelCosts: [(name: String, cents: Int)] = []

    enum ChartRange: String, CaseIterable {
        case week    = "7 天"
        case month   = "30 天"
        case quarter = "90 天"
        var days: Int {
            switch self {
            case .week:    7
            case .month:   30
            case .quarter: 90
            }
        }
        var localizedTitle: LocalizedStringKey {
            switch self {
            case .week: "7 天"
            case .month: "30 天"
            case .quarter: "90 天"
            }
        }
    }

    private var cal: Calendar { Calendar.current }

    var body: some View {
        GeometryReader { geometry in
            let isWide = geometry.size.width >= 820
            let padding: CGFloat = geometry.size.width < 760 ? 20 : 28
            let primaryLayout = isWide ? AnyLayout(HStackLayout(alignment: .top, spacing: 20)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 20))

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if let usageSnapshotError {
                        UsageSnapshotErrorBanner(message: usageSnapshotError, retry: reloadUsageSnapshot)
                    }
                    OverviewHeader(
                        range: $range,
                        lastSync: appStore.syncService?.lastSyncDate,
                        isSyncing: appStore.syncService?.isSyncingActive ?? false,
                        isWide: geometry.size.width >= 760
                    )

                    OverviewMetrics(
                        todayTokens: todayTotalTokens,
                        todayDelta: percentDelta(today: todayTotalTokens, yesterday: yesterdayTotalTokens),
                        periodTokens: rangeTotalTokens,
                        periodDelta: rangeWoWDelta,
                        cacheRate: globalCacheHitRate,
                        sessions: cachedSessionCount,
                        days: range.days,
                        isWide: geometry.size.width >= 800
                    )

                    primaryLayout {
                        OverviewTrend(points: timelinePoints, days: range.days)
                            .frame(maxWidth: .infinity)
                        OverviewQuotaGlance(quotas: quotaGlanceEntries) {
                            appStore.selectedTab = .quota
                        }
                        .frame(width: isWide ? 280 : nil)
                        .frame(maxWidth: isWide ? nil : .infinity)
                    }

                    OverviewDistribution(
                        models: topModelDeepData,
                        tools: aggregateByTool,
                        total: grandTotal,
                        isWide: geometry.size.width >= 860
                    )

                    VStack(spacing: 14) {
                        OverviewDisclosure(title: String(localized: "开发上下文"), subtitle: String(localized: "项目与分支的用量分布")) {
                            OverviewContext(
                                projects: projectDistribution,
                                branches: branchDistribution,
                                isWide: geometry.size.width >= 860
                            )
                        }

                        OverviewDisclosure(title: String(localized: "活动与工具详情"), subtitle: String(localized: "活跃记录、时段与各工具统计")) {
                            OverviewActivity(
                                dailyStats: dailyStats,
                                dataRevision: usageSnapshotRevision,
                                currentStreak: currentStreak,
                                maxStreak: maxStreak,
                                activeDays: activeDaysCount,
                                bestDay: bestDayEverLabel,
                                sessionCount: cachedSessionCount,
                                days: range.days,
                                hourlyPoints: hourlyActivityPoints,
                                weekdayPoints: weekdayActivityPoints,
                                peakHour: peakHourLabel,
                                peakWeekday: peakWeekdayLabel,
                                averageTokens: avgTokensPerSession,
                                favoriteTool: topTool?.displayName,
                                tools: toolSummaryData,
                                isWide: geometry.size.width >= 860
                            )
                        }

                        OverviewDisclosure(title: String(localized: "成本估算"), subtitle: String(localized: "公开模型价格的用量参考")) {
                            OverviewCost(
                                totalUSD: rangeTotalUSD,
                                totalCNY: rangeTotalCNY,
                                dailyAverageUSD: dailyAvgUSD,
                                mostExpensiveTool: mostExpensiveTool,
                                efficiency: costEfficiency,
                                points: costTimelinePoints,
                                tools: perToolCost,
                                models: topModelCosts,
                                balances: balanceQuotas,
                                days: range.days,
                                isWide: geometry.size.width >= 860
                            )
                        }
                    }
                }
                .frame(maxWidth: 1360, alignment: .leading)
                .padding(padding)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("总览")
        .background(Color(NSColor.windowBackgroundColor))
        .background {
            UsageSnapshotRefreshObserver(reload: reloadUsageSnapshot)
        }
        .onChange(of: range) { _, _ in updateDerivedCache() }
    }

    private var quotaGlanceEntries: [OverviewQuotaEntry] {
        Tool.allCases.map { tool in
            let records = allQuotas.filter { $0.toolRaw == tool.rawValue }
            return OverviewQuotaEntry(tool: tool, quota: records.first?.toModel(), hasMultipleAccounts: records.count > 1)
        }
    }

    private func percentDelta(today: Int, yesterday: Int) -> Int? { guard yesterday > 0 else { return nil }; return Int(((Double(today) - Double(yesterday)) / Double(yesterday) * 100).rounded()) }

    private var activeDaysCount: Int { cachedActiveDaysCount }
    private var currentStreak: Int { cachedCurrentStreak }
    private var maxStreak: Int { cachedMaxStreak }
    private var todayTotalTokens: Int { cachedTodayTokens }
    private var yesterdayTotalTokens: Int { cachedYesterdayTokens }
    private var rangeTotalTokens: Int { cachedRangeTotalTokens }
    private var rangeWoWDelta: Int? { cachedRangeWoWDelta }
    private var globalCacheHitRate: Double { cachedGlobalCacheHitRate }
    private var topTool: Tool? { cachedAggregateByTool.first?.tool }
    private var peakHourLabel: String { let peak = cachedHourlyActivityPoints.max(by: { $0.count < $1.count })?.hour ?? 0; return String(format: "%02d:00", peak) }
    private var avgTokensPerSession: Int { cachedAverageTokensPerSession }
    private var aggregateByTool: [(tool: Tool, tokens: Int)] { cachedAggregateByTool }
    private var grandTotal: Int { cachedRangeTotalTokens }
    private var timelinePoints: [WeeklyAreaChart.Point] { cachedTimelinePoints }
    fileprivate struct ModelDeepEntry: Identifiable { let name: String; let tokens: Int; let lastUsed: Date; let sessionCount: Int; let favoriteProject: String; var id: String { name } }
    private var topModelDeepData: [ModelDeepEntry] { cachedTopModelDeepData }
    fileprivate struct ProjectDist: Identifiable { let project: String; let tokens: Int; var id: String { project } }
    private var projectDistribution: [ProjectDist] { cachedProjectDistribution }
    fileprivate struct BranchDist: Identifiable { let branch: String; let tokens: Int; var id: String { branch } }
    private var branchDistribution: [BranchDist] { cachedBranchDistribution }
    fileprivate struct HourlyPoint { let hour: Int; let count: Int; var hourLabel: String { String(format: "%02d", hour) } }
    private var hourlyActivityPoints: [HourlyPoint] { cachedHourlyActivityPoints }
    fileprivate struct WeekdayPoint { let weekday: Int; let count: Int; var label: String { Calendar.current.veryShortWeekdaySymbols[weekday] } }
    private var weekdayActivityPoints: [WeekdayPoint] { cachedWeekdayActivityPoints }
    private var peakWeekdayLabel: String { cal.weekdaySymbols[cachedWeekdayActivityPoints.max(by: { $0.count < $1.count })?.weekday ?? 1] }
    fileprivate struct ToolSummaryItem: Identifiable {
        let tool: Tool; let totalTokens: Int; let inputTokens: Int; let outputTokens: Int
        let sessionCount: Int; let cacheHitRate: Double; let estimatedCostUSD: Double?
        var id: Tool { tool }
        var avgTokensPerSession: Int { sessionCount > 0 ? totalTokens / sessionCount : 0 }
    }
    private var toolSummaryData: [ToolSummaryItem] { cachedToolSummaryData }
    private var bestDayEverLabel: String { cachedBestDayTokens > 0 ? cachedBestDayTokens.compactTokenString : "—" }


    private var perToolCost: [(tool: Tool, usd: Double, cny: Double)] { cachedPerToolCost }

    private var rangeTotalUSD: Double { cachedRangeTotalUSD }
    private var rangeTotalCNY: Double { cachedRangeTotalCNY }
    private var dailyAvgUSD: Double { rangeTotalUSD / Double(max(1, range.days)) }
    private var mostExpensiveTool: Tool? { perToolCost.max { ($0.usd + $0.cny / 7.2) < ($1.usd + $1.cny / 7.2) }?.tool }
    private var costEfficiency: Double? { cachedCostEfficiency }

    private var costTimelinePoints: [WeeklyAreaChart.Point] { cachedCostTimelinePoints }
    private var topModelCosts: [(name: String, cents: Int)] { cachedTopModelCosts }

    private var balanceQuotas: [QuotaRecord] {
        return allQuotas.filter { $0.remaining != nil && Tool(rawValue: $0.toolRaw) != nil }
    }

    // MARK: - Persisted usage snapshots

    private func reloadUsageSnapshot() {
        let now = Date()
        let history = OverviewCalendarRange.current(days: ChartRange.quarter.days, at: now, calendar: cal)
        do {
            // A fresh context sees the committed writer transaction immediately,
            // including updates that leave the number of persisted rows unchanged.
            let context = ModelContext(appStore.modelContainer)
            let start = history.start
            let end = history.end
            let sessions = try context.fetch(FetchDescriptor<SessionRecord>(
                predicate: #Predicate { $0.startedAt >= start && $0.startedAt < end },
                sortBy: [SortDescriptor(\SessionRecord.startedAt, order: .reverse)]
            ))
            let stats = try context.fetch(FetchDescriptor<DailyStatsRecord>(
                sortBy: [SortDescriptor(\DailyStatsRecord.date)]
            ))
            usageReadContext = context
            allSessions = sessions
            dailyStats = stats
            snapshotDate = now
            usageSnapshotRevision = appStore.syncService?.dataRevision ?? 0
            usageSnapshotError = nil
            updateDerivedCache()
        } catch {
            usageSnapshotError = error.localizedDescription
        }
    }

    // MARK: - Derived cache update

    /// Derived values are rebuilt only for a committed snapshot, range change,
    /// day rollover, or foreground refresh, rather than while laying out the view.
    private func updateDerivedCache() {
        let period = OverviewCalendarRange.current(days: range.days, at: snapshotDate, calendar: cal)
        let previous = OverviewCalendarRange.previous(days: range.days, at: snapshotDate, calendar: cal)
        let todayStart = cal.startOfDay(for: snapshotDate)
        let yesterdayStart = cal.date(byAdding: .day, value: -1, to: todayStart)!
        let fs = allSessions.filter { period.contains($0.startedAt) && $0.startedAt < period.end }
        var fStats: [DailyStatsRecord] = []
        var dailyTotals: [Date: Int] = [:]
        var previousTokens = 0
        var activeDays: Set<Date> = []
        var allTimeDailyTotals: [Date: Int] = [:]
        for stat in dailyStats where stat.date < period.end {
            let tokens = stat.totalInputTokens + stat.totalOutputTokens
            let day = cal.startOfDay(for: stat.date)
            if tokens > 0 { activeDays.insert(day) }
            allTimeDailyTotals[day, default: 0] += tokens
            if stat.date >= period.start {
                fStats.append(stat)
                dailyTotals[day, default: 0] += tokens
            } else if stat.date >= previous.start {
                previousTokens += tokens
            }
        }
        cachedSessionCount = fs.count
        cachedRangeTotalTokens = dailyTotals.values.reduce(0, +)
        cachedRangeWoWDelta = percentDelta(today: cachedRangeTotalTokens, yesterday: previousTokens)
        cachedTimelinePoints = dailyTotals.map { WeeklyAreaChart.Point(date: $0.key, value: $0.value) }.sorted { $0.date < $1.date }
        cachedBestDayTokens = allTimeDailyTotals.values.max() ?? 0

        // Session-based detail metrics retain their source and attribution.
        var todayTok = 0; var yesterdayTok = 0
        for session in allSessions {
            if session.startedAt >= todayStart { todayTok += session.totalTokens }
            else if session.startedAt >= yesterdayStart { yesterdayTok += session.totalTokens }
        }
        cachedTodayTokens = todayTok
        cachedYesterdayTokens = yesterdayTok

        // Active days & streaks over all-time dailyStats
        cachedActiveDaysCount = activeDays.count
        var streak = 0; var checkDate = todayStart
        while activeDays.contains(checkDate) { streak += 1; checkDate = cal.date(byAdding: .day, value: -1, to: checkDate)! }
        cachedCurrentStreak = streak
        let sortedActiveDays = activeDays.sorted()
        if sortedActiveDays.isEmpty {
            cachedMaxStreak = 0
        } else {
            var maxS = 0; var curS = 1
            for i in 1..<sortedActiveDays.count {
                if cal.isDate(sortedActiveDays[i], inSameDayAs: cal.date(byAdding: .day, value: 1, to: sortedActiveDays[i-1])!) { curS += 1 }
                else { maxS = max(maxS, curS); curS = 1 }
            }
            cachedMaxStreak = max(maxS, curS)
        }

        // Per-tool token aggregates from filtered daily stats (one pass)
        var toolInputMap: [Tool: Int] = [:]
        var toolOutputMap: [Tool: Int] = [:]
        for stat in fStats {
            toolInputMap[stat.tool, default: 0] += stat.totalInputTokens
            toolOutputMap[stat.tool, default: 0] += stat.totalOutputTokens
        }
        cachedAggregateByTool = Tool.allCases.compactMap { tool in
            let t = (toolInputMap[tool] ?? 0) + (toolOutputMap[tool] ?? 0)
            return t > 0 ? (tool: tool, tokens: t) : nil
        }.sorted { $0.tokens > $1.tokens }

        // Single pass over filtered sessions for all session-based aggregates
        var usdMap: [Tool: Double] = [:]
        var cnyMap: [Tool: Double] = [:]
        var toolCacheHits: [Tool: Int] = [:]
        var toolSessionCounts: [Tool: Int] = [:]
        var modelMap: [String: (tokens: Int, lastUsed: Date, count: Int, projects: [String: Int])] = [:]
        var modelCostMap: [String: Int] = [:]
        var projectMap: [String: Int] = [:]
        var branchMap: [String: Int] = [:]
        var hours = Array(repeating: 0, count: 24)
        var weekdays = Array(repeating: 0, count: 7)
        var costDayMap: [Date: Int] = [:]
        var sessionTokens = 0
        var cacheReadTokens = 0
        var pricedSessionTokens = 0
        for s in fs {
            sessionTokens += s.totalTokens
            cacheReadTokens += s.cacheReadTokens
            let cost = s.estimatedCost
            if let v = cost.usd {
                usdMap[s.tool, default: 0] += v
                pricedSessionTokens += s.totalTokens
            }
            if let v = cost.cny { cnyMap[s.tool, default: 0] += v }
            toolCacheHits[s.tool, default: 0] += s.cacheReadTokens
            toolSessionCounts[s.tool, default: 0] += 1
            if !s.model.isEmpty {
                var data = modelMap[s.model] ?? (0, .distantPast, 0, [:])
                data.tokens += s.totalTokens; data.lastUsed = max(data.lastUsed, s.startedAt); data.count += 1
                let proj = s.cwd.components(separatedBy: "/").last ?? "Unknown"
                if !proj.isEmpty && proj != "Unknown" { data.projects[proj, default: 0] += s.totalTokens }
                modelMap[s.model] = data
                if let usd = cost.usd { modelCostMap[s.model, default: 0] += Int((usd * 100).rounded()) }
            }
            let projName = s.cwd.components(separatedBy: "/").last ?? "Unknown"
            if !projName.isEmpty && projName != "Unknown" { projectMap[projName, default: 0] += s.totalTokens }
            let branchName = s.gitBranch ?? "No Branch"
            if !branchName.isEmpty { branchMap[branchName, default: 0] += s.totalTokens }
            hours[cal.component(.hour, from: s.startedAt)] += 1
            weekdays[cal.component(.weekday, from: s.startedAt) - 1] += 1
            if let usd = cost.usd { costDayMap[cal.startOfDay(for: s.startedAt), default: 0] += Int((usd * 100).rounded()) }
        }

        cachedAverageTokensPerSession = fs.isEmpty ? 0 : sessionTokens / fs.count
        let cacheDenominator = cachedRangeTotalTokens + cacheReadTokens
        cachedGlobalCacheHitRate = cacheDenominator > 0 ? Double(cacheReadTokens) / Double(cacheDenominator) : 0
        cachedRangeTotalUSD = usdMap.values.reduce(0, +)
        cachedRangeTotalCNY = cnyMap.values.reduce(0, +)
        cachedCostEfficiency = pricedSessionTokens > 0 ? cachedRangeTotalUSD / Double(pricedSessionTokens) * 1000 : nil

        let costTools = Set(usdMap.keys).union(Set(cnyMap.keys))
        let perToolEntries: [(tool: Tool, usd: Double, cny: Double)] = costTools.map { t in
            (tool: t, usd: usdMap[t] ?? 0, cny: cnyMap[t] ?? 0)
        }
        cachedPerToolCost = perToolEntries.sorted { ($0.usd + $0.cny / 7.2) > ($1.usd + $1.cny / 7.2) }
        cachedTopModelDeepData = modelMap.sorted { $0.value.tokens > $1.value.tokens }.map { k, v in
            ModelDeepEntry(name: k, tokens: v.tokens, lastUsed: v.lastUsed, sessionCount: v.count,
                           favoriteProject: v.projects.sorted { $0.value > $1.value }.first?.key ?? "—")
        }
        cachedProjectDistribution = projectMap.sorted { $0.value > $1.value }.prefix(5)
            .map { ProjectDist(project: $0.key, tokens: $0.value) }
        cachedBranchDistribution = branchMap.sorted { $0.value > $1.value }.prefix(3)
            .map { BranchDist(branch: $0.key, tokens: $0.value) }
        cachedHourlyActivityPoints = hours.enumerated().map { HourlyPoint(hour: $0.offset, count: $0.element) }
        cachedWeekdayActivityPoints = weekdays.enumerated().map { WeekdayPoint(weekday: $0.offset, count: $0.element) }
        cachedCostTimelinePoints = costDayMap.map { WeeklyAreaChart.Point(date: $0.key, value: $0.value) }.sorted { $0.date < $1.date }
        cachedTopModelCosts = modelCostMap.sorted { $0.value > $1.value }.prefix(5).map { (name: $0.key, cents: $0.value) }
        cachedToolSummaryData = Tool.allCases.compactMap { tool in
            let input = toolInputMap[tool] ?? 0
            let output = toolOutputMap[tool] ?? 0
            let tokens = input + output
            let sessionCount = toolSessionCounts[tool] ?? 0
            let saved = toolCacheHits[tool] ?? 0
            let costUSD = usdMap[tool] ?? 0
            if tokens == 0 && sessionCount == 0 { return nil }
            return ToolSummaryItem(tool: tool, totalTokens: tokens, inputTokens: input, outputTokens: output,
                                   sessionCount: sessionCount,
                                   cacheHitRate: tokens + saved > 0 ? Double(saved) / Double(tokens + saved) : 0,
                                   estimatedCostUSD: costUSD > 0 ? costUSD : nil)
        }.sorted { $0.totalTokens > $1.totalTokens }
    }
}


/// The selected number of complete calendar days, including the current day.
/// Calendar arithmetic preserves these boundaries across daylight-saving changes.
enum OverviewCalendarRange {
    static func current(days: Int, at date: Date, calendar: Calendar) -> DateInterval {
        let today = calendar.startOfDay(for: date)
        let start = calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        return DateInterval(start: start, end: end)
    }

    static func previous(days: Int, at date: Date, calendar: Calendar) -> DateInterval {
        let current = current(days: days, at: date, calendar: calendar)
        let start = calendar.date(byAdding: .day, value: -max(1, days), to: current.start) ?? current.start
        return DateInterval(start: start, end: current.start)
    }
}

/// Keep revision and clock observations outside the dashboard's layout scope.
struct UsageSnapshotRefreshObserver: View {
    @Environment(AppStore.self) private var appStore
    @Environment(\.scenePhase) private var scenePhase
    let reload: () -> Void

    var body: some View {
        UsageDayBoundaryObserver(reload: reload)
            .task(id: appStore.syncService?.dataRevision) {
                reload()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { reload() }
            }
    }
}

private struct UsageDayBoundaryObserver: View {
    let reload: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
                reload()
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
                reload()
            }
            .accessibilityHidden(true)
    }
}

struct UsageSnapshotErrorBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("无法读取本地用量数据。")
                    .font(.system(size: 13, weight: .medium))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button("重试", action: retry)
        }
        .padding(16)
        .dashboardSurface()
    }
}

private struct OverviewHeader: View {
    @Binding var range: TrendsView.ChartRange
    let lastSync: Date?
    let isSyncing: Bool
    let isWide: Bool

    var body: some View {
        let layout = isWide ? AnyLayout(HStackLayout(alignment: .center, spacing: 20)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
        layout {
            VStack(alignment: .leading, spacing: 8) {
                Text("总览")
                    .font(.system(size: 30, weight: .semibold))
                HStack(spacing: 7) {
                    Text(Date(), format: .dateTime.month().day().weekday(.wide))
                    Text("·")
                    if isSyncing {
                        Text("正在同步")
                    } else if let lastSync {
                        Text("同步于 \(lastSync, format: .relative(presentation: .named))")
                            .help(lastSync.formatted(date: .complete, time: .standard))
                    } else {
                        Text("等待首次同步")
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Picker("时间范围", selection: $range) {
                ForEach(TrendsView.ChartRange.allCases, id: \.self) { item in
                    Text(item.localizedTitle).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 216, alignment: isWide ? .trailing : .leading)
        }
    }
}

private struct OverviewMetrics: View {
    let todayTokens: Int
    let todayDelta: Int?
    let periodTokens: Int
    let periodDelta: Int?
    let cacheRate: Double
    let sessions: Int
    let days: Int
    let isWide: Bool

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: isWide ? 4 : 2), alignment: .leading, spacing: 22) {
            DashboardMetric(title: String(localized: "今日消耗"), value: todayTokens.compactTokenString, subtitle: deltaLabel(todayDelta, comparedToPreviousPeriod: false))
            DashboardMetric(title: String(localized: "近 \(days) 天用量"), value: periodTokens.compactTokenString, subtitle: deltaLabel(periodDelta, comparedToPreviousPeriod: true))
            DashboardMetric(title: String(localized: "缓存命中率"), value: String(format: "%.1f%%", cacheRate * 100), subtitle: String(localized: "当前周期"))
            DashboardMetric(title: String(localized: "会话数"), value: sessions.formatted(), subtitle: String(localized: "近 \(days) 天"))
        }
        .padding(.vertical, 4)
        .padding(.bottom, 22)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func deltaLabel(_ delta: Int?, comparedToPreviousPeriod: Bool) -> String {
        guard let delta else { return "Tokens" }
        if delta == 0 {
            return comparedToPreviousPeriod ? String(localized: "与上一周期持平") : String(localized: "与昨日持平")
        }
        let change = "\(delta > 0 ? "+" : "")\(delta)%"
        return comparedToPreviousPeriod ? String(localized: "较上一周期 \(change)") : String(localized: "较昨日 \(change)")
    }
}

private struct OverviewTrend: View {
    let points: [WeeklyAreaChart.Point]
    let days: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            DashboardSectionTitle(title: String(localized: "用量趋势"), subtitle: String(localized: "近 \(days) 天 · Tokens"))
            if points.isEmpty {
                OverviewEmptyState(message: String(localized: "开始使用工具后，用量趋势会显示在这里。"), height: 216)
            } else {
                WeeklyAreaChart(data: points, color: .accentColor)
                    .frame(height: 216)
            }
        }
        .padding(22)
        .dashboardSurface()
    }
}

private struct OverviewQuotaEntry: Identifiable {
    let tool: Tool
    let quota: ToolQuota?
    let hasMultipleAccounts: Bool
    var id: Tool { tool }
}

private struct OverviewQuotaGlance: View {
    let quotas: [OverviewQuotaEntry]
    let openQuotas: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                DashboardSectionTitle(title: String(localized: "配额快照"))
                Spacer(minLength: 8)
                Button("查看全部", action: openQuotas)
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }

            VStack(spacing: 14) {
                ForEach(quotas) { entry in
                    OverviewQuotaRow(tool: entry.tool, quota: entry.quota, hasMultipleAccounts: entry.hasMultipleAccounts)
                }
            }
            Text("各工具最近同步的账户快照")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(22)
        .dashboardSurface()
    }
}

private struct OverviewQuotaRow: View {
    let tool: Tool
    let quota: ToolQuota?
    let hasMultipleAccounts: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            OverviewQuotaSnapshotRow(tool: tool, quota: quota, hasMultipleAccounts: hasMultipleAccounts, now: context.date)
        }
    }
}

private struct OverviewQuotaSnapshotRow: View {
    let tool: Tool
    let quota: ToolQuota?
    let hasMultipleAccounts: Bool
    let now: Date

    private var isStale: Bool {
        guard tool == .codex, let reset = quota?.resetAt else { return false }
        return reset <= now
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ToolLogoImage(tool: tool, size: 15)
                Text(tool.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(remainingLabel)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(quota?.remaining == nil || isStale ? .secondary : .primary)
            }
            if hasMultipleAccounts, let accountLabel = quota?.accountLabel, !accountLabel.isEmpty {
                Text(accountLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(accountLabel)
            }
            if isStale {
                Text("窗口已到期，请刷新")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else if let fraction = quota?.fraction {
                OverviewProgress(fraction: fraction, color: quotaBarColor(fraction: fraction))
            }
        }
    }

    private var remainingLabel: String {
        guard !isStale, let quota, let remaining = quota.remaining else { return String(localized: "未知") }
        if let fraction = quota.fraction {
            let percentage = Int((fraction * 100).rounded())
            return String(localized: "\(percentage)% 剩余")
        }
        return "\(remaining.formatted()) \(quota.unit.rawValue)"
    }
}

private struct OverviewDistribution: View {
    let models: [TrendsView.ModelDeepEntry]
    let tools: [(tool: Tool, tokens: Int)]
    let total: Int
    let isWide: Bool

    var body: some View {
        let layout = isWide ? AnyLayout(HStackLayout(alignment: .top, spacing: 32)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 28))
        layout {
            OverviewModels(models: models)
                .frame(maxWidth: .infinity, alignment: .leading)
            OverviewToolShare(tools: tools, total: total)
                .frame(width: isWide ? 280 : nil)
                .frame(maxWidth: isWide ? nil : .infinity, alignment: .leading)
        }
        .padding(22)
        .dashboardSurface()
    }
}

private struct OverviewModels: View {
    let models: [TrendsView.ModelDeepEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            DashboardSectionTitle(title: String(localized: "常用模型"), subtitle: String(localized: "按当前周期的 Token 用量排序"))
            if models.isEmpty {
                OverviewEmptyState(message: String(localized: "暂无模型数据"), height: 120)
            } else {
                VStack(spacing: 14) {
                    ForEach(models.prefix(5).enumerated(), id: \.element.id) { index, model in
                        OverviewModelRow(rank: index + 1, model: model)
                    }
                }
            }
        }
    }
}

private struct OverviewModelRow: View {
    let rank: Int
    let model: TrendsView.ModelDeepEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(rank.formatted())
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 14, alignment: .leading)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                Text(model.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .help(model.name)
                Text("\(model.sessionCount) 次会话 · 平均 \((model.sessionCount > 0 ? model.tokens / model.sessionCount : 0).compactTokenString)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if model.favoriteProject != "—" && !model.favoriteProject.isEmpty {
                    Text(model.favoriteProject)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 5) {
                Text(model.tokens.compactTokenString)
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                Text(model.lastUsed, format: .relative(presentation: .named))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct OverviewToolShare: View {
    let tools: [(tool: Tool, tokens: Int)]
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            DashboardSectionTitle(title: String(localized: "工具占比"), subtitle: String(localized: "当前周期的 Token 用量"))
            if tools.isEmpty {
                OverviewEmptyState(message: String(localized: "暂无工具数据"), height: 120)
            } else {
                Chart(tools, id: \.tool) { item in
                    BarMark(x: .value("Tokens", item.tokens), y: .value(String(localized: "用量"), String(localized: "工具")))
                        .foregroundStyle(Color(item.tool.accentColorName))
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartLegend(.hidden)
                .frame(height: 12)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .accessibilityLabel("工具用量占比")

                VStack(spacing: 16) {
                    ForEach(tools, id: \.tool) { item in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color(item.tool.accentColorName))
                                .frame(width: 6, height: 6)
                            Text(item.tool.displayName)
                                .font(.system(size: 12))
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(item.tokens.compactTokenString)
                                .font(.system(size: 12, weight: .medium))
                                .monospacedDigit()
                            Text(String(format: "%.0f%%", Double(item.tokens) / Double(max(1, total)) * 100))
                                .font(.system(size: 11))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 32, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }
}

private struct OverviewDisclosure<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            content()
                .padding(.top, 24)
        } label: {
            DashboardSectionTitle(title: title, subtitle: subtitle)
                .padding(.vertical, 2)
        }
        .padding(22)
        .dashboardSurface()
        .transaction { transaction in
            if reduceMotion { transaction.animation = nil }
        }
    }
}

private struct OverviewContext: View {
    let projects: [TrendsView.ProjectDist]
    let branches: [TrendsView.BranchDist]
    let isWide: Bool

    var body: some View {
        let layout = isWide ? AnyLayout(HStackLayout(alignment: .top, spacing: 32)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 28))
        layout {
            OverviewRankedUsage(title: String(localized: "项目用量 · 前 5"), entries: projects.map { OverviewUsageEntry(name: $0.project, value: $0.tokens) }, color: .accentColor)
                .frame(maxWidth: .infinity, alignment: .leading)
            OverviewRankedUsage(title: String(localized: "活跃分支 · 前 3"), entries: branches.map { OverviewUsageEntry(name: $0.branch, value: $0.tokens) }, color: .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct OverviewUsageEntry: Identifiable {
    let name: String
    let value: Int
    var displayValue: String? = nil
    var id: String { name }
}

private struct OverviewRankedUsage: View {
    let title: String
    let entries: [OverviewUsageEntry]
    let color: Color
    var useMaximumAsTotal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            if entries.isEmpty {
                Text("暂无数据")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                let total = max(1, useMaximumAsTotal ? entries.map(\.value).max() ?? 0 : entries.reduce(0) { $0 + $1.value })
                ForEach(entries) { entry in
                    VStack(spacing: 7) {
                        HStack(spacing: 12) {
                            Text(entry.name)
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .help(entry.name)
                            Spacer(minLength: 8)
                            Text(entry.displayValue ?? entry.value.compactTokenString)
                                .font(.system(size: 12))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        OverviewProgress(fraction: Double(entry.value) / Double(total), color: color)
                    }
                }
            }
        }
    }
}

private struct OverviewActivity: View {
    let dailyStats: [DailyStatsRecord]
    let dataRevision: UInt64
    let currentStreak: Int
    let maxStreak: Int
    let activeDays: Int
    let bestDay: String
    let sessionCount: Int
    let days: Int
    let hourlyPoints: [TrendsView.HourlyPoint]
    let weekdayPoints: [TrendsView.WeekdayPoint]
    let peakHour: String
    let peakWeekday: String
    let averageTokens: Int
    let favoriteTool: String?
    let tools: [TrendsView.ToolSummaryItem]
    let isWide: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            ActivityHeatmap(dailyStats: dailyStats, dataRevision: dataRevision)
            Divider()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: isWide ? 3 : 2), alignment: .leading, spacing: 20) {
                OverviewSmallMetric(title: String(localized: "连续活跃"), value: String(localized: "\(currentStreak) 天"))
                OverviewSmallMetric(title: String(localized: "最长连续"), value: String(localized: "\(maxStreak) 天"))
                OverviewSmallMetric(title: String(localized: "累计活跃"), value: String(localized: "\(activeDays) 天"))
                OverviewSmallMetric(title: String(localized: "单日峰值"), value: bestDay)
                OverviewSmallMetric(title: String(localized: "周期会话"), value: sessionCount.formatted())
                OverviewSmallMetric(title: String(localized: "日均会话"), value: String(format: "%.1f", Double(sessionCount) / Double(max(1, days))))
            }
            Divider()
            OverviewActivityCharts(hourlyPoints: hourlyPoints, weekdayPoints: weekdayPoints, isWide: isWide)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: isWide ? 4 : 2), alignment: .leading, spacing: 20) {
                OverviewSmallMetric(title: String(localized: "高峰时段"), value: peakHour)
                OverviewSmallMetric(title: String(localized: "最忙星期"), value: peakWeekday)
                OverviewSmallMetric(title: String(localized: "平均 Token / 会话"), value: averageTokens.compactTokenString)
                OverviewSmallMetric(title: String(localized: "常用工具"), value: favoriteTool ?? "—")
            }
            Divider()
            OverviewToolDetails(tools: tools, isWide: isWide)
        }
    }
}

private struct OverviewActivityCharts: View {
    let hourlyPoints: [TrendsView.HourlyPoint]
    let weekdayPoints: [TrendsView.WeekdayPoint]
    let isWide: Bool

    var body: some View {
        let layout = isWide ? AnyLayout(HStackLayout(alignment: .top, spacing: 32)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 24))
        layout {
            VStack(alignment: .leading, spacing: 14) {
                Text("会话时段")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Chart(hourlyPoints, id: \.hour) { point in
                    BarMark(x: .value("小时", point.hour), y: .value("会话", point.count))
                        .foregroundStyle(Color.accentColor.opacity(0.75))
                        .cornerRadius(2)
                }
                .chartXAxis {
                    AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                        AxisValueLabel {
                            if let hour = value.as(Int.self) {
                                Text(String(format: "%02d", hour))
                                    .font(.system(size: 10))
                            }
                        }
                    }
                }
                .chartYAxis(.hidden)
                .frame(height: 100)
            }
            .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 14) {
                Text("每周节奏")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Chart(weekdayPoints, id: \.weekday) { point in
                    BarMark(x: .value("星期", point.label), y: .value("会话", point.count))
                        .foregroundStyle(Color.accentColor.opacity(0.75))
                        .cornerRadius(2)
                }
                .chartXAxis { AxisMarks { _ in AxisValueLabel().font(.system(size: 10)) } }
                .chartYAxis(.hidden)
                .frame(height: 100)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private struct OverviewToolDetails: View {
    let tools: [TrendsView.ToolSummaryItem]
    let isWide: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("各工具用量")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            if tools.isEmpty {
                OverviewEmptyState(message: String(localized: "暂无工具数据"), height: 70)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top), count: isWide ? 2 : 1), alignment: .leading, spacing: 16) {
                    ForEach(tools) { tool in
                        OverviewToolDetail(tool: tool)
                    }
                }
            }
        }
    }
}

private struct OverviewToolDetail: View {
    let tool: TrendsView.ToolSummaryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                ToolLogoImage(tool: tool.tool, size: 18)
                Text(tool.tool.displayName)
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 8)
                Text("\(tool.sessionCount) 次会话")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(tool.totalTokens.compactTokenString)
                    .font(.system(size: 22, weight: .semibold))
                    .monospacedDigit()
                Text("Tokens")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                if let cost = tool.estimatedCostUSD {
                    Text(cost, format: .currency(code: "USD"))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 8) {
                OverviewProgress(fraction: Double(tool.inputTokens) / Double(max(1, tool.inputTokens + tool.outputTokens)), color: .accentColor)
                HStack {
                    Text("输入 \(tool.inputTokens.compactTokenString)")
                    Spacer(minLength: 8)
                    Text("输出 \(tool.outputTokens.compactTokenString)")
                }
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            HStack(spacing: 24) {
                OverviewSmallMetric(title: String(localized: "缓存命中率"), value: String(format: "%.0f%%", tool.cacheHitRate * 100))
                OverviewSmallMetric(title: String(localized: "平均 Token / 会话"), value: tool.avgTokensPerSession.compactTokenString)
            }
        }
        .padding(18)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct OverviewCost: View {
    let totalUSD: Double
    let totalCNY: Double
    let dailyAverageUSD: Double
    let mostExpensiveTool: Tool?
    let efficiency: Double?
    let points: [WeeklyAreaChart.Point]
    let tools: [(tool: Tool, usd: Double, cny: Double)]
    let models: [(name: String, cents: Int)]
    let balances: [QuotaRecord]
    let days: Int
    let isWide: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: isWide ? 4 : 2), alignment: .leading, spacing: 20) {
                OverviewSmallMetric(title: String(localized: "总估算成本"), value: totalLabel, subtitle: totalUSD > 0 && totalCNY > 0 ? String(localized: "另计 \(OverviewCurrency.cny(totalCNY))") : nil)
                OverviewSmallMetric(title: String(localized: "日均成本 · USD"), value: OverviewCurrency.usd(dailyAverageUSD))
                OverviewSmallMetric(title: String(localized: "最高成本工具"), value: mostExpensiveTool?.displayName ?? "—")
                OverviewSmallMetric(title: String(localized: "每千 Token 成本"), value: efficiency.map { String(format: "$%.4f", $0) } ?? "—")
            }

            if totalUSD > 0 || totalCNY > 0 {
                Divider()
                OverviewCostCharts(points: points, tools: tools, days: days, isWide: isWide)
                if !models.isEmpty {
                    Divider()
                    OverviewRankedUsage(
                        title: String(localized: "模型成本 · 前 5"),
                        entries: models.map { OverviewUsageEntry(name: $0.name, value: $0.cents, displayValue: String(format: "$%.2f", Double($0.cents) / 100)) },
                        color: .accentColor,
                        useMaximumAsTotal: true
                    )
                }
            } else {
                OverviewEmptyState(message: String(localized: "暂无可估算的成本数据"), height: 80)
            }

            if !balances.isEmpty {
                Divider()
                OverviewBalances(balances: balances, isWide: isWide)
            }
            Text("估算基于公开定价，仅供参考。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var totalLabel: String {
        if totalUSD > 0 { return OverviewCurrency.usd(totalUSD) }
        if totalCNY > 0 { return OverviewCurrency.cny(totalCNY) }
        return "—"
    }
}

private struct OverviewCostCharts: View {
    let points: [WeeklyAreaChart.Point]
    let tools: [(tool: Tool, usd: Double, cny: Double)]
    let days: Int
    let isWide: Bool

    var body: some View {
        let layout = isWide ? AnyLayout(HStackLayout(alignment: .top, spacing: 32)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 26))
        layout {
            VStack(alignment: .leading, spacing: 16) {
                Text("每日估算成本 · USD")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                if points.isEmpty {
                    OverviewEmptyState(message: String(localized: "暂无 USD 成本数据"), height: 150)
                } else {
                    Chart(points, id: \.date) { point in
                        AreaMark(x: .value("日期", point.date), y: .value("美分", point.value))
                            .foregroundStyle(Color.accentColor.opacity(0.08))
                            .interpolationMethod(.linear)
                        LineMark(x: .value("日期", point.date), y: .value("美分", point.value))
                            .foregroundStyle(Color.accentColor)
                            .interpolationMethod(.linear)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: max(1, days / 7))) { _ in
                            AxisValueLabel(format: .dateTime.month().day())
                        }
                    }
                    .chartYAxis {
                        AxisMarks { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let cents = value.as(Int.self) {
                                    Text(String(format: "$%.2f", Double(cents) / 100))
                                }
                            }
                        }
                    }
                    .frame(height: 150)
                }
            }
            .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 16) {
                Text("工具成本")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                ForEach(tools, id: \.tool) { tool in
                    HStack(alignment: .top, spacing: 8) {
                        ToolLogoImage(tool: tool.tool, size: 15)
                        Text(tool.tool.displayName)
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 4) {
                            if tool.usd > 0 { Text(OverviewCurrency.usd(tool.usd)) }
                            if tool.cny > 0 { Text(OverviewCurrency.cny(tool.cny)) }
                        }
                        .font(.system(size: 12))
                        .monospacedDigit()
                    }
                }
            }
            .frame(width: isWide ? 250 : nil)
            .frame(maxWidth: isWide ? nil : .infinity, alignment: .leading)
        }
    }
}

private struct OverviewBalances: View {
    let balances: [QuotaRecord]
    let isWide: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("余额监控")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: isWide ? 2 : 1), alignment: .leading, spacing: 16) {
                ForEach(balances, id: \.persistentModelID) { balance in
                    OverviewBalanceRow(quota: balance.toModel())
                }
            }
        }
    }
}

private struct OverviewBalanceRow: View {
    let quota: ToolQuota

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            OverviewBalanceSnapshotRow(quota: quota, now: context.date)
        }
    }
}

private struct OverviewBalanceSnapshotRow: View {
    let quota: ToolQuota
    let now: Date

    private var isStale: Bool {
        guard quota.tool == .codex, let reset = quota.resetAt else { return false }
        return reset <= now
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ToolLogoImage(tool: quota.tool, size: 15)
                Text(quota.accountLabel ?? quota.tool.displayName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isStale {
                    Text("未知")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if let fraction = quota.fraction {
                    Text("\(Int((fraction * 100).rounded()))% 剩余")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else if let remaining = quota.remaining {
                    Text("\(remaining.formatted()) \(quota.unit.rawValue)")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Text("未知")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            if !isStale, let fraction = quota.fraction {
                OverviewProgress(fraction: fraction, color: quotaBarColor(fraction: fraction))
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct OverviewSmallMetric: View {
    let title: String
    let value: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 17, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OverviewProgress: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule().fill(color.opacity(0.8))
                    .frame(width: geometry.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

private struct OverviewEmptyState: View {
    let message: String
    let height: CGFloat

    var body: some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: height)
    }
}

private enum OverviewCurrency {
    static func usd(_ value: Double) -> String {
        value > 0 ? value.formatted(.currency(code: "USD")) : "—"
    }

    static func cny(_ value: Double) -> String {
        value > 0 ? value.formatted(.currency(code: "CNY")) : "—"
    }
}
