import SwiftUI
import SwiftData
import Charts

// MARK: - Width Breakpoint (Avoids pixel-by-pixel GeometryReader invalidations)

private enum OverviewWidthClass: Equatable {
    case compact   // < 760pt
    case medium    // 760..<940pt
    case wide      // >= 940pt

    var isTwoColumn: Bool { self != .compact }
    var isFullGrid: Bool { self == .wide }

    static func from(width: CGFloat) -> Self {
        if width >= 940 { return .wide }
        if width >= 760 { return .medium }
        return .compact
    }
}

// MARK: - Immutable Value-Type Inputs & Analytics Snapshot (Off-MainActor Computation)

private struct OverviewSessionInput: Sendable {
    let tool: Tool
    let startedAt: Date
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let model: String
    let cwd: String
    let gitBranch: String?
    let costUSD: Double?
    let costCNY: Double?

    var totalTokens: Int { inputTokens + outputTokens }
}

private struct OverviewDailyStatInput: Sendable {
    let date: Date
    let tool: Tool
    let inputTokens: Int
    let outputTokens: Int

    var totalTokens: Int { inputTokens + outputTokens }
}

private struct OverviewDailyTotalPoint: Identifiable, Sendable {
    let date: Date
    let totalTokens: Int
    let byTool: [(tool: Tool, tokens: Int)]
    var id: Date { date }
}

private struct OverviewDailyToolSegment: Identifiable, Sendable {
    let date: Date
    let tool: Tool
    let tokens: Int
    var id: String { "\(Int(date.timeIntervalSince1970))-\(tool.rawValue)" }
}

private struct OverviewTokenComposition: Sendable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int

    var totalVolume: Int { inputTokens + outputTokens + cacheReadTokens }
    var nonCachedTotal: Int { inputTokens + outputTokens }
}

private struct OverviewModelEntry: Identifiable, Sendable {
    let name: String
    let primaryTool: Tool
    let tokens: Int
    let lastUsed: Date
    let sessionCount: Int
    let favoriteProject: String
    var id: String { name }
    var avgTokens: Int { sessionCount > 0 ? tokens / sessionCount : 0 }
}

private struct OverviewRankedItem: Identifiable, Sendable {
    let name: String
    let tokens: Int
    let sessionCount: Int
    var id: String { name }
}

private struct OverviewHourlyBucket: Identifiable, Sendable {
    let hour: Int
    let sessionCount: Int
    let tokens: Int
    var id: Int { hour }
    var label: String { String(format: "%02d:00", hour) }
}

private struct OverviewWeekdayBucket: Identifiable, Sendable {
    let weekdayIndex: Int // 0 = Sun ... 6 = Sat
    let shortLabel: String
    let fullLabel: String
    let sessionCount: Int
    let tokens: Int
    var id: Int { weekdayIndex }
}

private struct OverviewToolSummary: Identifiable, Sendable {
    let tool: Tool
    let totalTokens: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let sessionCount: Int
    let cacheHitRate: Double
    let estimatedCostUSD: Double?
    var id: Tool { tool }
    var avgTokensPerSession: Int { sessionCount > 0 ? totalTokens / sessionCount : 0 }
}

private struct OverviewCostDayPoint: Identifiable, Sendable {
    let date: Date
    let cents: Int
    var id: Date { date }
    var dollars: Double { Double(cents) / 100.0 }
}

private struct OverviewToolCostEntry: Identifiable, Sendable {
    let tool: Tool
    let usd: Double
    let cny: Double
    var id: Tool { tool }
}

private struct OverviewModelCostEntry: Identifiable, Sendable {
    let name: String
    let cents: Int
    var id: String { name }
}

private struct OverviewSnapshot: Sendable {
    let todayTokens: Int
    let yesterdayTokens: Int
    let todayDelta: Int?
    let sparkline7d: [Int]

    let periodTokens: Int
    let periodDelta: Int?
    let dailyAverageTokens: Int
    let periodMiniBars: [Int]

    let cacheHitRate: Double
    let totalCacheReadTokens: Int

    let sessionCount: Int
    let avgTokensPerSession: Int
    let dailyAverageSessions: Double
    let recent7dSessions: [Int]

    let currentStreak: Int
    let maxStreak: Int
    let activeDaysCount: Int
    let bestDayTokens: Int

    let dailyTotalPoints: [OverviewDailyTotalPoint]
    let dailyToolSegments: [OverviewDailyToolSegment]
    let composition: OverviewTokenComposition
    let toolShares: [(tool: Tool, tokens: Int)]

    let topModels: [OverviewModelEntry]
    let toolSummaries: [OverviewToolSummary]
    let projects: [OverviewRankedItem]
    let branches: [OverviewRankedItem]

    let hourlyBuckets: [OverviewHourlyBucket]
    let weekdayBuckets: [OverviewWeekdayBucket]
    let peakHourLabel: String
    let peakWeekdayLabel: String

    let totalUSD: Double
    let totalCNY: Double
    let dailyAverageUSD: Double
    let mostExpensiveTool: Tool?
    let costEfficiencyPer1K: Double?
    let costTimeline: [OverviewCostDayPoint]
    let perToolCosts: [OverviewToolCostEntry]
    let topModelCosts: [OverviewModelCostEntry]

    static let empty = OverviewSnapshot(
        todayTokens: 0,
        yesterdayTokens: 0,
        todayDelta: nil,
        sparkline7d: [],
        periodTokens: 0,
        periodDelta: nil,
        dailyAverageTokens: 0,
        periodMiniBars: [],
        cacheHitRate: 0,
        totalCacheReadTokens: 0,
        sessionCount: 0,
        avgTokensPerSession: 0,
        dailyAverageSessions: 0,
        recent7dSessions: [],
        currentStreak: 0,
        maxStreak: 0,
        activeDaysCount: 0,
        bestDayTokens: 0,
        dailyTotalPoints: [],
        dailyToolSegments: [],
        composition: OverviewTokenComposition(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0),
        toolShares: [],
        topModels: [],
        toolSummaries: [],
        projects: [],
        branches: [],
        hourlyBuckets: (0..<24).map { OverviewHourlyBucket(hour: $0, sessionCount: 0, tokens: 0) },
        weekdayBuckets: [],
        peakHourLabel: "—",
        peakWeekdayLabel: "—",
        totalUSD: 0,
        totalCNY: 0,
        dailyAverageUSD: 0,
        mostExpensiveTool: nil,
        costEfficiencyPer1K: nil,
        costTimeline: [],
        perToolCosts: [],
        topModelCosts: []
    )
}

// MARK: - Analytics Engine (Pure, Single-Pass, Off-MainActor)

private enum OverviewAnalyticsEngine {
    static func compute(
        sessions: [OverviewSessionInput],
        dailyStats: [OverviewDailyStatInput],
        days: Int,
        at snapshotDate: Date
    ) -> OverviewSnapshot {
        let cal = Calendar.current
        let period = OverviewCalendarRange.current(days: days, at: snapshotDate, calendar: cal)
        let previous = OverviewCalendarRange.previous(days: days, at: snapshotDate, calendar: cal)
        let todayStart = cal.startOfDay(for: snapshotDate)
        let yesterdayStart = cal.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart

        // 1. Single pass over all dailyStats
        var dailyTotals: [Date: Int] = [:]
        var dailyByTool: [Date: [Tool: Int]] = [:]
        var allTimeDailyTotals: [Date: Int] = [:]
        var activeDays: Set<Date> = []
        var toolInputMap: [Tool: Int] = [:]
        var toolOutputMap: [Tool: Int] = [:]
        var previousTokens = 0
        var periodTokens = 0
        var periodInputTotal = 0
        var periodOutputTotal = 0

        for stat in dailyStats where stat.date < period.end {
            let tokens = stat.totalTokens
            let day = cal.startOfDay(for: stat.date)
            if tokens > 0 { activeDays.insert(day) }
            allTimeDailyTotals[day, default: 0] += tokens

            if stat.date >= period.start {
                periodTokens += tokens
                periodInputTotal += stat.inputTokens
                periodOutputTotal += stat.outputTokens
                dailyTotals[day, default: 0] += tokens
                dailyByTool[day, default: [:]][stat.tool, default: 0] += tokens
                toolInputMap[stat.tool, default: 0] += stat.inputTokens
                toolOutputMap[stat.tool, default: 0] += stat.outputTokens
            } else if stat.date >= previous.start {
                previousTokens += tokens
            }
        }

        // Build continuous calendar day series (zero-filled for honest gaps)
        var dailyTotalPoints: [OverviewDailyTotalPoint] = []
        dailyTotalPoints.reserveCapacity(days)
        var dailyToolSegments: [OverviewDailyToolSegment] = []
        dailyToolSegments.reserveCapacity(days * Tool.allCases.count)

        for offset in 0..<days {
            guard let day = cal.date(byAdding: .day, value: offset, to: period.start) else { continue }
            let dayTotal = dailyTotals[day] ?? 0
            let toolMap = dailyByTool[day] ?? [:]
            let sortedByTool = Tool.allCases.compactMap { tool -> (tool: Tool, tokens: Int)? in
                guard let value = toolMap[tool], value > 0 else { return nil }
                return (tool: tool, tokens: value)
            }.sorted { $0.tokens > $1.tokens }

            dailyTotalPoints.append(OverviewDailyTotalPoint(
                date: day,
                totalTokens: dayTotal,
                byTool: sortedByTool
            ))

            for item in sortedByTool {
                dailyToolSegments.append(OverviewDailyToolSegment(
                    date: day,
                    tool: item.tool,
                    tokens: item.tokens
                ))
            }
        }

        // 7-day micro sparkline for Today hero card
        let sparkline7d: [Int] = (0..<7).reversed().map { back in
            guard let day = cal.date(byAdding: .day, value: -back, to: todayStart) else { return 0 }
            return allTimeDailyTotals[day] ?? 0
        }

        // Consistent today / yesterday totals from dailyStats (fallback to sessions below if 0)
        var todayTokens = allTimeDailyTotals[todayStart] ?? 0
        var yesterdayTokens = allTimeDailyTotals[yesterdayStart] ?? 0

        // Active streaks across all-time history
        var currentStreak = 0
        var checkDate = todayStart
        while activeDays.contains(checkDate) {
            currentStreak += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: checkDate) else { break }
            checkDate = prev
        }

        let sortedActiveDays = activeDays.sorted()
        var maxStreak = 0
        if !sortedActiveDays.isEmpty {
            var run = 1
            maxStreak = 1
            for idx in 1..<sortedActiveDays.count {
                if let expected = cal.date(byAdding: .day, value: 1, to: sortedActiveDays[idx - 1]),
                   cal.isDate(sortedActiveDays[idx], inSameDayAs: expected) {
                    run += 1
                } else {
                    maxStreak = max(maxStreak, run)
                    run = 1
                }
            }
            maxStreak = max(maxStreak, run)
        }

        // 2. Single pass over sessions in period (plus today/yesterday fallback)
        var sessionTodayFallback = 0
        var sessionYesterdayFallback = 0
        var sessionCount = 0
        var sessionTokensSum = 0
        var totalCacheRead = 0
        var pricedSessionTokens = 0

        var usdMap: [Tool: Double] = [:]
        var cnyMap: [Tool: Double] = [:]
        var toolCacheHits: [Tool: Int] = [:]
        var toolSessionCounts: [Tool: Int] = [:]

        struct ModelAgg {
            var tokens = 0
            var lastUsed = Date.distantPast
            var count = 0
            var toolTokens: [Tool: Int] = [:]
            var projects: [String: Int] = [:]
        }
        var modelMap: [String: ModelAgg] = [:]
        var modelCostMap: [String: Int] = [:]
        var projectMap: [String: (tokens: Int, count: Int)] = [:]
        var branchMap: [String: (tokens: Int, count: Int)] = [:]

        var hourCounts = Array(repeating: 0, count: 24)
        var hourTokens = Array(repeating: 0, count: 24)
        var weekdayCounts = Array(repeating: 0, count: 7)
        var weekdayTokens = Array(repeating: 0, count: 7)
        var costDayMap: [Date: Int] = [:]
        var sessionDayCounts: [Date: Int] = [:]

        for s in sessions {
            let sDay = cal.startOfDay(for: s.startedAt)
            if sDay <= todayStart {
                sessionDayCounts[sDay, default: 0] += 1
            }

            if s.startedAt >= todayStart && s.startedAt < period.end {
                sessionTodayFallback += s.totalTokens
            } else if s.startedAt >= yesterdayStart && s.startedAt < todayStart {
                sessionYesterdayFallback += s.totalTokens
            }

            guard s.startedAt >= period.start && s.startedAt < period.end else { continue }
            sessionCount += 1
            let tok = s.totalTokens
            sessionTokensSum += tok
            totalCacheRead += s.cacheReadTokens
            toolCacheHits[s.tool, default: 0] += s.cacheReadTokens
            toolSessionCounts[s.tool, default: 0] += 1

            if let usd = s.costUSD {
                usdMap[s.tool, default: 0] += usd
                pricedSessionTokens += tok
                costDayMap[cal.startOfDay(for: s.startedAt), default: 0] += Int((usd * 100).rounded())
                if !s.model.isEmpty {
                    modelCostMap[s.model, default: 0] += Int((usd * 100).rounded())
                }
            }
            if let cny = s.costCNY {
                cnyMap[s.tool, default: 0] += cny
            }

            // Zero-allocation project basename extraction
            let projectName = extractProjectBasename(from: s.cwd)
            if let projectName {
                var p = projectMap[projectName] ?? (0, 0)
                p.tokens += tok
                p.count += 1
                projectMap[projectName] = p
            }

            if !s.model.isEmpty {
                var m = modelMap[s.model] ?? ModelAgg()
                m.tokens += tok
                if s.startedAt > m.lastUsed { m.lastUsed = s.startedAt }
                m.count += 1
                m.toolTokens[s.tool, default: 0] += tok
                if let projectName {
                    m.projects[projectName, default: 0] += tok
                }
                modelMap[s.model] = m
            }

            if let branch = s.gitBranch?.trimmingCharacters(in: .whitespacesAndNewlines), !branch.isEmpty {
                var b = branchMap[branch] ?? (0, 0)
                b.tokens += tok
                b.count += 1
                branchMap[branch] = b
            }

            let hour = cal.component(.hour, from: s.startedAt)
            if (0..<24).contains(hour) {
                hourCounts[hour] += 1
                hourTokens[hour] += tok
            }
            let weekdayIdx = cal.component(.weekday, from: s.startedAt) - 1
            if (0..<7).contains(weekdayIdx) {
                weekdayCounts[weekdayIdx] += 1
                weekdayTokens[weekdayIdx] += tok
            }
        }

        if todayTokens == 0 && sessionTodayFallback > 0 { todayTokens = sessionTodayFallback }
        if yesterdayTokens == 0 && sessionYesterdayFallback > 0 { yesterdayTokens = sessionYesterdayFallback }

        let toolShares: [(tool: Tool, tokens: Int)] = Tool.allCases.compactMap { tool in
            let total = (toolInputMap[tool] ?? 0) + (toolOutputMap[tool] ?? 0)
            return total > 0 ? (tool: tool, tokens: total) : nil
        }.sorted { $0.tokens > $1.tokens }

        let topModels: [OverviewModelEntry] = modelMap
            .sorted { $0.value.tokens > $1.value.tokens }
            .prefix(6)
            .map { name, agg in
                let primaryTool = agg.toolTokens.max { $0.value < $1.value }?.key ?? .claudeCode
                let favProject = agg.projects.max { $0.value < $1.value }?.key ?? ""
                return OverviewModelEntry(
                    name: name,
                    primaryTool: primaryTool,
                    tokens: agg.tokens,
                    lastUsed: agg.lastUsed,
                    sessionCount: agg.count,
                    favoriteProject: favProject
                )
            }

        let projects: [OverviewRankedItem] = projectMap
            .sorted { $0.value.tokens > $1.value.tokens }
            .prefix(5)
            .map { OverviewRankedItem(name: $0.key, tokens: $0.value.tokens, sessionCount: $0.value.count) }

        let branches: [OverviewRankedItem] = branchMap
            .sorted { $0.value.tokens > $1.value.tokens }
            .prefix(5)
            .map { OverviewRankedItem(name: $0.key, tokens: $0.value.tokens, sessionCount: $0.value.count) }

        let hourlyBuckets = (0..<24).map { h in
            OverviewHourlyBucket(hour: h, sessionCount: hourCounts[h], tokens: hourTokens[h])
        }

        // Order Monday -> Sunday for natural weekly rhythm reading
        let mondayFirstOrder = [1, 2, 3, 4, 5, 6, 0]
        let shortSyms = cal.veryShortWeekdaySymbols
        let fullSyms = cal.weekdaySymbols
        let weekdayBuckets = mondayFirstOrder.map { idx in
            OverviewWeekdayBucket(
                weekdayIndex: idx,
                shortLabel: idx < shortSyms.count ? shortSyms[idx] : "",
                fullLabel: idx < fullSyms.count ? fullSyms[idx] : "",
                sessionCount: weekdayCounts[idx],
                tokens: weekdayTokens[idx]
            )
        }

        let peakHour = hourlyBuckets.max { $0.sessionCount < $1.sessionCount }
        let peakHourLabel = (peakHour?.sessionCount ?? 0) > 0 ? peakHour!.label : "—"
        let peakWeekday = weekdayBuckets.max { $0.sessionCount < $1.sessionCount }
        let peakWeekdayLabel = (peakWeekday?.sessionCount ?? 0) > 0 ? peakWeekday!.fullLabel : "—"

        let toolSummaries: [OverviewToolSummary] = Tool.allCases.compactMap { tool in
            let input = toolInputMap[tool] ?? 0
            let output = toolOutputMap[tool] ?? 0
            let tokens = input + output
            let count = toolSessionCounts[tool] ?? 0
            let saved = toolCacheHits[tool] ?? 0
            let costUSD = usdMap[tool] ?? 0
            guard tokens > 0 || count > 0 else { return nil }
            let denom = tokens + saved
            return OverviewToolSummary(
                tool: tool,
                totalTokens: tokens,
                inputTokens: input,
                outputTokens: output,
                cacheReadTokens: saved,
                sessionCount: count,
                cacheHitRate: denom > 0 ? Double(saved) / Double(denom) : 0,
                estimatedCostUSD: costUSD > 0 ? costUSD : nil
            )
        }.sorted { $0.totalTokens > $1.totalTokens }

        let totalUSD = usdMap.values.reduce(0, +)
        let totalCNY = cnyMap.values.reduce(0, +)
        let costTools = Set(usdMap.keys).union(Set(cnyMap.keys))
        let perToolCosts = costTools.map {
            OverviewToolCostEntry(tool: $0, usd: usdMap[$0] ?? 0, cny: cnyMap[$0] ?? 0)
        }.sorted { ($0.usd + $0.cny / 7.2) > ($1.usd + $1.cny / 7.2) }

        let costTimeline: [OverviewCostDayPoint] = (0..<days).compactMap { offset in
            guard let day = cal.date(byAdding: .day, value: offset, to: period.start) else { return nil }
            return OverviewCostDayPoint(date: day, cents: costDayMap[day] ?? 0)
        }

        let topModelCosts = modelCostMap
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { OverviewModelCostEntry(name: $0.key, cents: $0.value) }

        let cacheDenom = periodTokens + totalCacheRead
        let cacheHitRate = cacheDenom > 0 ? Double(totalCacheRead) / Double(cacheDenom) : 0

        let periodMiniBars = downsampleBars(dailyTotalPoints.map(\.totalTokens), targetCount: min(days, 14))
        let recent7dSessions: [Int] = (0..<7).reversed().map { back in
            guard let day = cal.date(byAdding: .day, value: -back, to: todayStart) else { return 0 }
            return sessionDayCounts[day] ?? 0
        }

        return OverviewSnapshot(
            todayTokens: todayTokens,
            yesterdayTokens: yesterdayTokens,
            todayDelta: percentDelta(current: todayTokens, previous: yesterdayTokens),
            sparkline7d: sparkline7d,
            periodTokens: periodTokens,
            periodDelta: percentDelta(current: periodTokens, previous: previousTokens),
            dailyAverageTokens: periodTokens / max(1, days),
            periodMiniBars: periodMiniBars,
            cacheHitRate: cacheHitRate,
            totalCacheReadTokens: totalCacheRead,
            sessionCount: sessionCount,
            avgTokensPerSession: sessionCount > 0 ? sessionTokensSum / sessionCount : 0,
            dailyAverageSessions: Double(sessionCount) / Double(max(1, days)),
            recent7dSessions: recent7dSessions,
            currentStreak: currentStreak,
            maxStreak: maxStreak,
            activeDaysCount: activeDays.count,
            bestDayTokens: allTimeDailyTotals.values.max() ?? 0,
            dailyTotalPoints: dailyTotalPoints,
            dailyToolSegments: dailyToolSegments,
            composition: OverviewTokenComposition(
                inputTokens: periodInputTotal,
                outputTokens: periodOutputTotal,
                cacheReadTokens: totalCacheRead
            ),
            toolShares: toolShares,
            topModels: topModels,
            toolSummaries: toolSummaries,
            projects: projects,
            branches: branches,
            hourlyBuckets: hourlyBuckets,
            weekdayBuckets: weekdayBuckets,
            peakHourLabel: peakHourLabel,
            peakWeekdayLabel: peakWeekdayLabel,
            totalUSD: totalUSD,
            totalCNY: totalCNY,
            dailyAverageUSD: totalUSD / Double(max(1, days)),
            mostExpensiveTool: perToolCosts.first?.tool,
            costEfficiencyPer1K: pricedSessionTokens > 0 ? totalUSD / Double(pricedSessionTokens) * 1000 : nil,
            costTimeline: costTimeline,
            perToolCosts: perToolCosts,
            topModelCosts: topModelCosts
        )
    }

    private static func percentDelta(current: Int, previous: Int) -> Int? {
        guard previous > 0 else { return nil }
        return Int(((Double(current) - Double(previous)) / Double(previous) * 100).rounded())
    }

    private static func downsampleBars(_ values: [Int], targetCount: Int) -> [Int] {
        guard targetCount > 0, !values.isEmpty else { return [] }
        if values.count <= targetCount { return values }
        var result: [Int] = []
        result.reserveCapacity(targetCount)
        let stride = Double(values.count) / Double(targetCount)
        for i in 0..<targetCount {
            let start = Int(floor(Double(i) * stride))
            let end = min(values.count, max(start + 1, Int(floor(Double(i + 1) * stride))))
            var sum = 0
            for idx in start..<end { sum += values[idx] }
            result.append(sum)
        }
        return result
    }

    private static func extractProjectBasename(from cwd: String) -> String? {
        let trimmed = cwd.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !trimmed.isEmpty else { return nil }
        let name: Substring
        if let slash = trimmed.lastIndex(of: "/") {
            name = trimmed[trimmed.index(after: slash)...]
        } else {
            name = trimmed[...]
        }
        guard !name.isEmpty, name != "Unknown" else { return nil }
        return String(name)
    }
}

// MARK: - TrendsView (Overview Page Root)

struct TrendsView: View {
    @Environment(AppStore.self) private var appStore

    @State private var range: ChartRange = .month
    @State private var widthClass: OverviewWidthClass = .wide
    @State private var usageSnapshotError: String?

    // Lightweight Sendable raw inputs — no live ModelContext or SwiftData managed objects pinned in state.
    @State private var sessionInputs: [OverviewSessionInput] = []
    @State private var dailyStatInputs: [OverviewDailyStatInput] = []
    @State private var heatmapSamples: [ActivityHeatmapSample] = []
    @State private var snapshotDate = Date()
    @State private var dataRevision: UInt64 = 0

    // Single atomic derived analytics snapshot computed off MainActor.
    @State private var snapshot: OverviewSnapshot = .empty
    @State private var computeTask: Task<Void, Never>?

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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let usageSnapshotError {
                    UsageSnapshotErrorBanner(message: usageSnapshotError, retry: reloadUsageSnapshot)
                }

                OverviewHeaderBar(range: $range, isCompact: widthClass == .compact)

                OverviewKPIGrid(
                    snapshot: snapshot,
                    days: range.days,
                    isFourColumn: widthClass.isFullGrid
                )

                // Primary Telemetry Row: Interactive Multi-Tool Trend + Token Composition & Tool Share
                if widthClass.isFullGrid {
                    HStack(alignment: .top, spacing: 16) {
                        OverviewDailyTrendCard(
                            dailyTotals: snapshot.dailyTotalPoints,
                            toolSegments: snapshot.dailyToolSegments,
                            activeTools: snapshot.toolShares.map(\.tool),
                            days: range.days,
                            fillHeight: true
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                        OverviewCompositionCard(
                            composition: snapshot.composition,
                            toolShares: snapshot.toolShares,
                            totalTokens: snapshot.periodTokens,
                            fillHeight: true
                        )
                        .frame(width: 368)
                        .frame(maxHeight: .infinity, alignment: .topLeading)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    OverviewDailyTrendCard(
                        dailyTotals: snapshot.dailyTotalPoints,
                        toolSegments: snapshot.dailyToolSegments,
                        activeTools: snapshot.toolShares.map(\.tool),
                        days: range.days,
                        fillHeight: false
                    )
                    OverviewCompositionCard(
                        composition: snapshot.composition,
                        toolShares: snapshot.toolShares,
                        totalTokens: snapshot.periodTokens,
                        fillHeight: false
                    )
                }

                // Annual Activity Heatmap (First-class card with Canvas rendering)
                OverviewHeatmapCard(
                    samples: heatmapSamples,
                    dataRevision: dataRevision,
                    currentStreak: snapshot.currentStreak,
                    maxStreak: snapshot.maxStreak,
                    activeDays: snapshot.activeDaysCount,
                    bestDayTokens: snapshot.bestDayTokens,
                    isWide: widthClass.isFullGrid
                )

                // Coding Rhythm (24h & Weekday interactive charts)
                OverviewRhythmCard(
                    hourlyBuckets: snapshot.hourlyBuckets,
                    weekdayBuckets: snapshot.weekdayBuckets,
                    peakHour: snapshot.peakHourLabel,
                    peakWeekday: snapshot.peakWeekdayLabel,
                    isTwoColumn: widthClass.isTwoColumn,
                    isCompact: widthClass == .compact
                )

                // Per-Tool Telemetry Breakdown (Full-width responsive brand cards)
                OverviewToolsDetailCard(
                    tools: snapshot.toolSummaries,
                    isTwoColumn: widthClass.isTwoColumn,
                    isWide: widthClass.isFullGrid
                )

                // Model Leaderboard (Full-width Swiss-aligned ranking)
                OverviewModelsCard(models: snapshot.topModels)

                // Development Context (Projects & Branches)
                OverviewContextCard(
                    projects: snapshot.projects,
                    branches: snapshot.branches,
                    isTwoColumn: widthClass.isTwoColumn
                )

                // Cost Reference (Collapsible specular card)
                OverviewCostCard(
                    snapshot: snapshot,
                    days: range.days,
                    isTwoColumn: widthClass.isTwoColumn
                )
            }
            .frame(maxWidth: 1120, alignment: .leading)
            .padding(.horizontal, widthClass == .compact ? 20 : 28)
            .padding(.top, 8)
            .padding(.bottom, 26)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollEdgeEffectStyle(.soft, for: .vertical)
        .onGeometryChange(for: OverviewWidthClass.self) { proxy in
            OverviewWidthClass.from(width: proxy.size.width)
        } action: { next in
            if widthClass != next {
                widthClass = next
            }
        }
        .navigationTitle("总览")
        .background(Color(NSColor.windowBackgroundColor))
        .background {
            UsageSnapshotRefreshObserver(reload: reloadUsageSnapshot)
        }
        .onChange(of: range) { _, _ in scheduleCompute() }
        .onDisappear { computeTask?.cancel() }
    }

    // MARK: - Snapshot Fetch & Off-MainActor Aggregation

    private func reloadUsageSnapshot() {
        let now = Date()
        let cal = Calendar.current
        let history = OverviewCalendarRange.current(days: ChartRange.quarter.days, at: now, calendar: cal)
        do {
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

            sessionInputs = sessions.map { s in
                let cost = s.estimatedCost
                return OverviewSessionInput(
                    tool: s.tool,
                    startedAt: s.startedAt,
                    inputTokens: s.inputTokens,
                    outputTokens: s.outputTokens,
                    cacheReadTokens: s.cacheReadTokens,
                    model: s.model,
                    cwd: s.cwd,
                    gitBranch: s.gitBranch,
                    costUSD: cost.usd,
                    costCNY: cost.cny
                )
            }
            dailyStatInputs = stats.map { st in
                OverviewDailyStatInput(
                    date: st.date,
                    tool: st.tool,
                    inputTokens: st.totalInputTokens,
                    outputTokens: st.totalOutputTokens
                )
            }
            heatmapSamples = stats.map { st in
                ActivityHeatmapSample(date: st.date, tokens: st.totalInputTokens + st.totalOutputTokens)
            }
            snapshotDate = now
            dataRevision = appStore.syncService?.dataRevision ?? 0
            usageSnapshotError = nil
            scheduleCompute()
        } catch {
            usageSnapshotError = error.localizedDescription
        }
    }

    private func scheduleCompute() {
        computeTask?.cancel()
        let sessions = sessionInputs
        let stats = dailyStatInputs
        let days = range.days
        let date = snapshotDate
        computeTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                OverviewAnalyticsEngine.compute(
                    sessions: sessions,
                    dailyStats: stats,
                    days: days,
                    at: date
                )
            }.value
            guard !Task.isCancelled else { return }
            snapshot = result
        }
    }
}

// MARK: - Shared Public Helpers (Preserved for tests & SessionHistoryView)

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

// MARK: - Telemetry Visual Primitives (Unified with QuotaView & MenuBarView)

private struct OverviewCapsuleFillShape: Shape {
    var fraction: Double
    var minWidth: CGFloat

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        guard fraction > 0.001, rect.width > 0, rect.height > 0 else { return Path() }
        let clamped = max(0, min(1, fraction))
        let width = min(rect.width, max(minWidth, rect.width * CGFloat(clamped)))
        return Path(
            roundedRect: CGRect(x: 0, y: 0, width: width, height: rect.height),
            cornerRadius: rect.height / 2,
            style: .continuous
        )
    }
}

private struct OverviewLuminousBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    let fraction: Double
    let color: Color
    var height: CGFloat = 5

    private var clamped: Double {
        fraction.isFinite ? max(0, min(1, fraction)) : 0
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.085))
            if clamped > 0.001 {
                OverviewCapsuleFillShape(fraction: clamped, minWidth: height)
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.78), color],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .overlay(alignment: .top) {
                        OverviewCapsuleFillShape(fraction: clamped, minWidth: height)
                            .fill(Color.white.opacity(colorScheme == .dark ? 0.22 : 0.34))
                            .frame(height: 1)
                    }
                    .shadow(color: color.opacity(colorScheme == .dark ? 0.24 : 0.14), radius: 2, y: 0.75)
                    .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.9), value: clamped)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

private struct OverviewHairline: View {
    @Environment(\.colorScheme) private var colorScheme
    var opacity: Double? = nil

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(opacity ?? (colorScheme == .dark ? 0.10 : 0.07)))
            .frame(height: 0.5)
    }
}

/// Specular telemetry plate matching QuotaToolShell & MenuBarToolShell.
/// Neutral cards keep a calm specular surface; colored radial glow is reserved for explicit brand accents.
private struct OverviewSurfaceCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    var accent: Color? = nil
    var cornerRadius: CGFloat = 16
    var padding: CGFloat = 20
    var fillHeight: Bool = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        content()
            .padding(padding)
            .frame(
                maxWidth: .infinity,
                maxHeight: fillHeight ? .infinity : nil,
                alignment: .topLeading
            )
            .background {
                ZStack(alignment: .topLeading) {
                    shape
                        .fill(
                            Color(nsColor: .controlBackgroundColor)
                                .opacity(colorScheme == .dark ? 0.78 : 0.94)
                        )
                    if let accent {
                        RadialGradient(
                            colors: [
                                accent.opacity(colorScheme == .dark ? 0.14 : 0.08),
                                accent.opacity(colorScheme == .dark ? 0.03 : 0.015),
                                Color.clear
                            ],
                            center: UnitPoint(x: 0.06, y: 0.0),
                            startRadius: 6,
                            endRadius: 240
                        )
                    } else {
                        LinearGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.04 : 0.55),
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
                        LinearGradient(
                            colors: [
                                colorScheme == .dark
                                    ? Color.white.opacity(0.18)
                                    : Color.white.opacity(0.94),
                                accent?.opacity(colorScheme == .dark ? 0.16 : 0.11)
                                    ?? Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.055),
                                Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
            }
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.045),
                radius: 5,
                x: 0,
                y: 2
            )
    }
}

private struct OverviewHoverRow<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    var tint: Color = .primary
    var bleedHorizontal: Bool = true
    @ViewBuilder let content: () -> Content
    @State private var isHovered = false

    var body: some View {
        content()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isHovered
                    ? tint.opacity(colorScheme == .dark ? 0.10 : 0.05)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .padding(.horizontal, bleedHorizontal ? -10 : 0)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) {
                    isHovered = hovering
                }
            }
    }
}

private struct OverviewCardHeader<Accessory: View>: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
    @ViewBuilder let accessory: () -> Accessory

    init(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .tracking(-0.2)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            accessory()
        }
    }
}

private struct OverviewStatPill: View {
    @Environment(\.colorScheme) private var colorScheme
    let label: LocalizedStringKey
    let value: String
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(tint ?? .primary)
        }
        .padding(.horizontal, 8.5)
        .padding(.vertical, 3.5)
        .background(
            (tint ?? Color.primary).opacity(colorScheme == .dark ? 0.12 : 0.06),
            in: Capsule()
        )
    }
}

private struct OverviewEmptyPlaceholder: View {
    let message: LocalizedStringKey
    var height: CGFloat = 140

    var body: some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: height)
    }
}

// MARK: - Header Bar (Liquid Glass, unified with QuotaDashboardHeaderBar)

private struct OverviewHeaderBar: View {
    @Environment(AppStore.self) private var appStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var range: TrendsView.ChartRange
    let isCompact: Bool
    @Namespace private var rangeNamespace
    @Namespace private var glassNamespace

    private var isSyncing: Bool { appStore.syncService?.isSyncingActive ?? false }
    private var lastSync: Date? { appStore.syncService?.lastSyncDate ?? appStore.lastSyncDate }

    var body: some View {
        let layout = isCompact
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 16))

        layout {
            VStack(alignment: .leading, spacing: 6) {
                Text("总览")
                    .font(.system(size: 28, weight: .semibold))
                    .tracking(-0.4)

                HStack(spacing: 7) {
                    Text(Date(), format: .dateTime.month().day().weekday(.wide))
                    Text("·").foregroundStyle(.tertiary)
                    if isSyncing {
                        ProgressView().controlSize(.mini).scaleEffect(0.72)
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

            HStack(spacing: 10) {
                // Sliding Liquid Glass style range rail
                HStack(spacing: 2) {
                    ForEach(TrendsView.ChartRange.allCases, id: \.self) { item in
                        let isSelected = range == item
                        Button {
                            withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
                                range = item
                            }
                        } label: {
                            Text(item.localizedTitle)
                                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                                .foregroundStyle(isSelected ? .primary : .secondary)
                                .padding(.horizontal, 12)
                                .frame(height: 24)
                                .background {
                                    if isSelected {
                                        Capsule()
                                            .fill(colorScheme == .dark ? Color.white.opacity(0.15) : Color.white.opacity(0.95))
                                            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.06), radius: 2, y: 1)
                                            .matchedGeometryEffect(id: "overviewRangeSelection", in: rangeNamespace)
                                    }
                                }
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                    }
                }
                .padding(3)
                .background(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.045), in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.07), lineWidth: 0.5)
                }

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
                    .glassEffectID("overviewRefresh", in: glassNamespace)
                    .focusEffectDisabled()
                    .keyboardShortcut("r", modifiers: .command)
                    .help(isSyncing ? String(localized: "同步中…") : String(localized: "刷新同步 (⌘R)"))
                    .accessibilityLabel("刷新同步")
                }
                .animation(.smooth(duration: 0.25), value: isSyncing)
            }
        }
    }
}

// MARK: - Hero KPI Strip (4 Uniform-Height Specular Telemetry Cards)

private struct OverviewKPIGrid: View {
    @Environment(\.colorScheme) private var colorScheme
    let snapshot: OverviewSnapshot
    let days: Int
    let isFourColumn: Bool

    var body: some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: 14, alignment: .top),
            count: isFourColumn ? 4 : 2
        )
        let blueTint = colorScheme == .dark
            ? Color(red: 0.40, green: 0.64, blue: 1.00)
            : Color(red: 0.18, green: 0.48, blue: 0.92)
        let emeraldTint = colorScheme == .dark
            ? Color(red: 0.24, green: 0.80, blue: 0.50)
            : Color(red: 0.14, green: 0.66, blue: 0.40)
        let violetTint = colorScheme == .dark
            ? Color(red: 0.72, green: 0.50, blue: 0.98)
            : Color(red: 0.54, green: 0.34, blue: 0.86)

        LazyVGrid(columns: columns, spacing: 14) {
            // 1. Today Tokens + 7d Micro Sparkline
            OverviewKPICard(
                title: "今日消耗",
                value: snapshot.todayTokens.compactTokenString,
                delta: snapshot.todayDelta,
                subtitle: snapshot.yesterdayTokens > 0
                    ? String(localized: "昨日 \(snapshot.yesterdayTokens.compactTokenString)")
                    : String(localized: "今日累计 Tokens")
            ) {
                OverviewMicroSparkline(values: snapshot.sparkline7d, color: Color.accentColor)
            }

            // 2. Period Tokens + Period Mini Bar Silhouette
            OverviewKPICard(
                title: "近 \(days) 天用量",
                value: snapshot.periodTokens.compactTokenString,
                delta: snapshot.periodDelta,
                subtitle: String(localized: "日均 \(snapshot.dailyAverageTokens.compactTokenString)")
            ) {
                OverviewMicroBarStrip(values: snapshot.periodMiniBars, color: blueTint, highlightLast: false)
            }

            // 3. Cache Hit Rate + Centered Luminous Progress Bar
            OverviewKPICard(
                title: "缓存命中率",
                value: String(format: "%.1f%%", snapshot.cacheHitRate * 100),
                delta: nil,
                subtitle: snapshot.totalCacheReadTokens > 0
                    ? String(localized: "已缓存 \(snapshot.totalCacheReadTokens.compactTokenString)")
                    : String(localized: "当前周期")
            ) {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    OverviewLuminousBar(
                        fraction: snapshot.cacheHitRate,
                        color: emeraldTint,
                        height: 5
                    )
                    Spacer(minLength: 0)
                }
            }

            // 4. Sessions + 7d Session Cadence Bars
            OverviewKPICard(
                title: "会话数",
                value: snapshot.sessionCount.formatted(),
                delta: nil,
                subtitle: snapshot.currentStreak > 0
                    ? String(localized: "日均 \(String(format: "%.1f", snapshot.dailyAverageSessions)) 次 · 连续 \(snapshot.currentStreak) 天")
                    : String(localized: "日均 \(String(format: "%.1f", snapshot.dailyAverageSessions)) 次")
            ) {
                OverviewMicroBarStrip(values: snapshot.recent7dSessions, color: violetTint, highlightLast: true)
            }
        }
    }
}

private struct OverviewKPICard<Visual: View>: View {
    let title: LocalizedStringKey
    let value: String
    let delta: Int?
    let subtitle: String
    @ViewBuilder let visual: () -> Visual

    var body: some View {
        OverviewSurfaceCard(accent: nil, cornerRadius: 15, padding: 16, fillHeight: true) {
            VStack(alignment: .leading, spacing: 0) {
                // Fixed 20pt header row guarantees identical hero value baseline across all 4 cards.
                HStack(alignment: .center, spacing: 6) {
                    Text(title)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let delta {
                        OverviewDeltaBadge(delta: delta)
                    }
                }
                .frame(height: 20)

                Text(value)
                    .font(.system(size: 26, weight: .semibold))
                    .monospacedDigit()
                    .tracking(-0.6)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .contentTransition(.numericText())
                    .frame(height: 32, alignment: .leading)
                    .padding(.top, 6)

                // Fixed 22pt micro-telemetry slot guarantees pixel-identical card heights.
                visual()
                    .frame(maxWidth: .infinity)
                    .frame(height: 22)
                    .padding(.top, 10)

                Text(subtitle)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(height: 15, alignment: .leading)
                    .padding(.top, 8)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct OverviewDeltaBadge: View {
    @Environment(\.colorScheme) private var colorScheme
    let delta: Int

    var body: some View {
        let isUp = delta > 0
        let isFlat = delta == 0
        let tint: Color = isFlat
            ? .secondary
            : (isUp
                ? (colorScheme == .dark ? Color(red: 0.24, green: 0.80, blue: 0.50) : Color(red: 0.14, green: 0.65, blue: 0.38))
                : (colorScheme == .dark ? Color(red: 0.98, green: 0.56, blue: 0.34) : Color(red: 0.86, green: 0.40, blue: 0.16)))

        HStack(spacing: 2) {
            if !isFlat {
                Image(systemName: isUp ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(size: 8.5, weight: .bold))
            }
            Text(isFlat ? "0%" : "\(abs(delta))%")
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.opacity(colorScheme == .dark ? 0.16 : 0.10), in: Capsule())
    }
}

/// Pure SwiftUI Canvas 7-day sparkline — zero Charts layout overhead.
private struct OverviewMicroSparkline: View {
    @Environment(\.colorScheme) private var colorScheme
    let values: [Int]
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0 else { return }
            let hasData = values.contains { $0 > 0 }
            guard values.count >= 2, hasData else {
                let baseline = Path(roundedRect: CGRect(x: 0, y: size.height - 2, width: size.width, height: 1.5), cornerRadius: 0.75)
                context.fill(baseline, with: .color(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.07)))
                return
            }
            let maxVal = max(1, values.max() ?? 1)
            let padX: CGFloat = 2.5
            let usableW = max(1, size.width - padX * 2)
            let stepX = usableW / CGFloat(values.count - 1)
            let insetY: CGFloat = 2.5
            let usableH = max(1, size.height - insetY * 2)

            var line = Path()
            var area = Path()
            for (idx, val) in values.enumerated() {
                let x = padX + CGFloat(idx) * stepX
                let y = insetY + usableH * (1 - CGFloat(val) / CGFloat(maxVal))
                if idx == 0 {
                    line.move(to: CGPoint(x: x, y: y))
                    area.move(to: CGPoint(x: x, y: size.height))
                    area.addLine(to: CGPoint(x: x, y: y))
                } else {
                    line.addLine(to: CGPoint(x: x, y: y))
                    area.addLine(to: CGPoint(x: x, y: y))
                }
            }
            area.addLine(to: CGPoint(x: padX + usableW, y: size.height))
            area.closeSubpath()

            context.fill(
                area,
                with: .linearGradient(
                    Gradient(colors: [color.opacity(0.24), color.opacity(0.0)]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )
            context.stroke(
                line,
                with: .color(color.opacity(0.85)),
                style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
            )

            if let last = values.last {
                let lx = padX + usableW
                let ly = insetY + usableH * (1 - CGFloat(last) / CGFloat(maxVal))
                let dot = Path(ellipseIn: CGRect(x: lx - 2.3, y: ly - 2.3, width: 4.6, height: 4.6))
                context.fill(dot, with: .color(color))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Pure SwiftUI Canvas mini vertical bar strip matching the height and rhythm of OverviewMicroSparkline.
private struct OverviewMicroBarStrip: View {
    @Environment(\.colorScheme) private var colorScheme
    let values: [Int]
    let color: Color
    var highlightLast: Bool = false

    var body: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0 else { return }
            let count = values.count
            guard count > 0 else {
                let baseline = Path(roundedRect: CGRect(x: 0, y: size.height - 2, width: size.width, height: 1.5), cornerRadius: 0.75)
                context.fill(baseline, with: .color(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.07)))
                return
            }

            let maxVal = max(1, values.max() ?? 1)
            let gap: CGFloat = count <= 8 ? 4 : 2.5
            let totalGap = gap * CGFloat(max(0, count - 1))
            let barW = max(2, (size.width - totalGap) / CGFloat(count))
            let corner = min(barW / 2, 2.2)

            for (idx, val) in values.enumerated() {
                let x = CGFloat(idx) * (barW + gap)
                let ratio = CGFloat(val) / CGFloat(maxVal)
                let barH = val > 0 ? max(3, (size.height - 2) * ratio) : 2
                let rect = CGRect(x: x, y: size.height - barH, width: barW, height: barH)
                let path = Path(roundedRect: rect, cornerRadius: corner, style: .continuous)
                let isAccent = (highlightLast && idx == count - 1) || (val == maxVal && val > 0 && !highlightLast)
                let fill: Color = val == 0
                    ? Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.06)
                    : (isAccent ? color : color.opacity(colorScheme == .dark ? 0.42 : 0.34))
                context.fill(path, with: .color(fill))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Primary Chart 1: Interactive Multi-Tool Daily Trend

private struct OverviewDailyTrendCard: View {
    enum DisplayMode: String, CaseIterable {
        case stacked
        case total
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let dailyTotals: [OverviewDailyTotalPoint]
    let toolSegments: [OverviewDailyToolSegment]
    let activeTools: [Tool]
    let days: Int
    var fillHeight: Bool = false

    @State private var mode: DisplayMode = .stacked
    @State private var hoveredDate: Date?
    @Namespace private var modeNamespace

    private var hasAnyUsage: Bool {
        dailyTotals.contains { $0.totalTokens > 0 }
    }

    private var hoveredPoint: OverviewDailyTotalPoint? {
        guard let hoveredDate else { return nil }
        let cal = Calendar.current
        return dailyTotals.first { cal.isDate($0.date, inSameDayAs: hoveredDate) }
    }

    private var axisStrideDays: Int {
        if days <= 7 { return 1 }
        if days <= 30 { return 5 }
        return 14
    }

    var body: some View {
        OverviewSurfaceCard(fillHeight: fillHeight) {
            VStack(alignment: .leading, spacing: 12) {
                OverviewCardHeader(
                    title: "用量趋势",
                    subtitle: "近 \(days) 天 · Tokens"
                ) {
                    modeSwitcher
                }

                // Dedicated 20pt legend & hover readout bar — eliminates header jitter on hover
                HStack(spacing: 10) {
                    if mode == .stacked && !activeTools.isEmpty {
                        HStack(spacing: 10) {
                            ForEach(Array(activeTools.prefix(4)), id: \.self) { tool in
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(tool.brandAccentColor(for: colorScheme))
                                        .frame(width: 6, height: 6)
                                    Text(tool.displayName)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    } else if mode == .total {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 6, height: 6)
                            Text("每日总计")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: 8)

                    if let hovered = hoveredPoint {
                        hoveredCallout(hovered)
                    } else if hasAnyUsage {
                        Text("悬停查看明细")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(height: 20)

                if !hasAnyUsage {
                    OverviewEmptyPlaceholder(message: "开始使用工具后，用量趋势会显示在这里。", height: 224)
                        .frame(maxHeight: fillHeight ? .infinity : nil)
                } else {
                    chartView
                        .frame(minHeight: 224, maxHeight: fillHeight ? .infinity : 224)
                }
            }
        }
    }

    private var modeSwitcher: some View {
        HStack(spacing: 1) {
            modePill(.stacked, title: "按工具")
            modePill(.total, title: "总计")
        }
        .padding(2)
        .background(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.055), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08), lineWidth: 0.5)
        }
    }

    private func modePill(_ target: DisplayMode, title: LocalizedStringKey) -> some View {
        let isSelected = mode == target
        return Button {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) {
                mode = target
            }
        } label: {
            Text(title)
                .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .padding(.horizontal, 9)
                .frame(height: 21)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(colorScheme == .dark ? Color.white.opacity(0.16) : Color.white.opacity(0.95))
                            .shadow(color: Color.black.opacity(0.08), radius: 1, y: 0.5)
                            .matchedGeometryEffect(id: "trendModeSelection", in: modeNamespace)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private func hoveredCallout(_ point: OverviewDailyTotalPoint) -> some View {
        HStack(spacing: 6) {
            Text(point.date, format: .dateTime.month(.twoDigits).day(.twoDigits))
                .foregroundStyle(.secondary)
            Text(point.totalTokens.compactTokenString)
                .fontWeight(.semibold)
                .monospacedDigit()
            if point.byTool.count > 1 {
                ForEach(point.byTool.prefix(3), id: \.tool) { item in
                    HStack(spacing: 3) {
                        Circle()
                            .fill(item.tool.brandAccentColor(for: colorScheme))
                            .frame(width: 5, height: 5)
                        Text(item.tokens.compactTokenString)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .font(.system(size: 10.5))
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.05), in: Capsule())
    }

    private var chartView: some View {
        let axisColor = colorScheme == .dark ? Color.white.opacity(0.55) : Color.black.opacity(0.45)

        return Chart {
            if mode == .stacked {
                ForEach(toolSegments) { seg in
                    BarMark(
                        x: .value("Date", seg.date, unit: .day),
                        y: .value("Tokens", seg.tokens)
                    )
                    .foregroundStyle(seg.tool.brandAccentColor(for: colorScheme).gradient)
                    .cornerRadius(days <= 14 ? 3.5 : 2)
                }
            } else {
                ForEach(dailyTotals) { pt in
                    AreaMark(
                        x: .value("Date", pt.date, unit: .day),
                        y: .value("Tokens", pt.totalTokens)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.24), Color.accentColor.opacity(0.01)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.monotone)

                    LineMark(
                        x: .value("Date", pt.date, unit: .day),
                        y: .value("Tokens", pt.totalTokens)
                    )
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .interpolationMethod(.monotone)
                }
            }

            if let hovered = hoveredPoint {
                RuleMark(x: .value("Hovered", hovered.date, unit: .day))
                    .foregroundStyle(Color.primary.opacity(0.22))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                if mode == .total {
                    PointMark(
                        x: .value("Date", hovered.date, unit: .day),
                        y: .value("Tokens", hovered.totalTokens)
                    )
                    .foregroundStyle(Color.accentColor)
                    .symbolSize(48)
                }
            }
        }
        .chartXScale(range: .plotDimension(padding: 6))
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: axisStrideDays)) { _ in
                if days <= 7 {
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                        .foregroundStyle(axisColor)
                } else {
                    AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                        .foregroundStyle(axisColor)
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06))
                AxisValueLabel {
                    if let v = value.as(Int.self) {
                        Text(v.compactTokenString)
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(axisColor)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plotFrame = proxy.plotFrame else { return }
                            let origin = geo[plotFrame].origin
                            let relativeX = location.x - origin.x
                            if let date: Date = proxy.value(atX: relativeX) {
                                let day = Calendar.current.startOfDay(for: date)
                                if hoveredDate != day { hoveredDate = day }
                            }
                        case .ended:
                            if hoveredDate != nil { hoveredDate = nil }
                        }
                    }
            }
        }
    }
}

// MARK: - Primary Chart 2 (NEW): Token Composition Donut + Brand Tool Share

private struct OverviewCompositionCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let composition: OverviewTokenComposition
    let toolShares: [(tool: Tool, tokens: Int)]
    let totalTokens: Int
    var fillHeight: Bool = false

    private struct Slice: Identifiable {
        let id: String
        let label: LocalizedStringKey
        let value: Int
        let color: Color
    }

    private var slices: [Slice] {
        let inputColor = colorScheme == .dark
            ? Color(red: 0.36, green: 0.62, blue: 1.00)
            : Color(red: 0.18, green: 0.46, blue: 0.92)
        let outputColor = colorScheme == .dark
            ? Color(red: 0.78, green: 0.52, blue: 1.00)
            : Color(red: 0.58, green: 0.32, blue: 0.88)
        let cacheColor = colorScheme == .dark
            ? Color(red: 0.24, green: 0.82, blue: 0.54)
            : Color(red: 0.14, green: 0.66, blue: 0.42)

        return [
            Slice(id: "input", label: "输入", value: composition.inputTokens, color: inputColor),
            Slice(id: "output", label: "输出", value: composition.outputTokens, color: outputColor),
            Slice(id: "cache", label: "缓存读取", value: composition.cacheReadTokens, color: cacheColor),
        ].filter { $0.value > 0 }
    }

    var body: some View {
        OverviewSurfaceCard(fillHeight: fillHeight) {
            VStack(alignment: .leading, spacing: 16) {
                OverviewCardHeader(
                    title: "用量构成",
                    subtitle: "输入 / 输出 / 缓存与工具占比"
                )

                if slices.isEmpty {
                    OverviewEmptyPlaceholder(message: "暂无工具数据", height: 224)
                        .frame(maxHeight: fillHeight ? .infinity : nil)
                } else {
                    // Token Composition Donut + Legend
                    HStack(alignment: .center, spacing: 16) {
                        ZStack {
                            Chart(slices) { slice in
                                SectorMark(
                                    angle: .value("Tokens", slice.value),
                                    innerRadius: .ratio(0.67),
                                    angularInset: 2
                                )
                                .cornerRadius(3)
                                .foregroundStyle(slice.color.gradient)
                            }
                            .chartLegend(.hidden)

                            VStack(spacing: 1) {
                                Text(composition.totalVolume.compactTokenString)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .monospacedDigit()
                                Text("总计")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 88, height: 88)

                        VStack(alignment: .leading, spacing: 9) {
                            let denom = max(1, composition.totalVolume)
                            ForEach(slices) { slice in
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(slice.color)
                                        .frame(width: 6.5, height: 6.5)
                                    Text(slice.label)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(slice.value.compactTokenString)
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .monospacedDigit()
                                    Text("\(Int((Double(slice.value) / Double(denom) * 100).rounded()))%")
                                        .font(.system(size: 10.5))
                                        .monospacedDigit()
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 30, alignment: .trailing)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }

                    OverviewHairline(opacity: 0.08)

                    // Tool Share Stacked Bar + Brand Rows
                    VStack(alignment: .leading, spacing: 10) {
                        if !toolShares.isEmpty {
                            OverviewMultiSegmentBar(
                                segments: toolShares.map { ($0.tool.brandAccentColor(for: colorScheme), $0.tokens) },
                                height: 6.5
                            )

                            VStack(spacing: 8) {
                                ForEach(toolShares, id: \.tool) { item in
                                    let share = Double(item.tokens) / Double(max(1, totalTokens)) * 100
                                    HStack(spacing: 8) {
                                        ToolBrandIconWell(tool: item.tool, size: 20, iconSize: 12)
                                        Text(item.tool.displayName)
                                            .font(.system(size: 12, weight: .medium))
                                            .lineLimit(1)
                                        Spacer(minLength: 6)
                                        Text(item.tokens.compactTokenString)
                                            .font(.system(size: 12, weight: .semibold))
                                            .monospacedDigit()
                                        Text(String(format: "%.0f%%", share))
                                            .font(.system(size: 10.5))
                                            .monospacedDigit()
                                            .foregroundStyle(.secondary)
                                            .frame(width: 32, alignment: .trailing)
                                    }
                                }
                            }
                        }
                    }

                    if fillHeight {
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }
}

/// Zero-GeometryReader proportional multi-segment bar rendered in Canvas.
private struct OverviewMultiSegmentBar: View {
    @Environment(\.colorScheme) private var colorScheme
    let segments: [(color: Color, value: Int)]
    var height: CGFloat = 6

    var body: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0 else { return }
            let bgPath = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: height / 2, style: .continuous)
            context.fill(bgPath, with: .color(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.07)))

            let total = segments.reduce(0) { $0 + max(0, $1.value) }
            guard total > 0 else { return }
            let gap: CGFloat = segments.count > 1 ? 2 : 0
            let totalGap = gap * CGFloat(max(0, segments.count - 1))
            let usableW = max(0, size.width - totalGap)

            var x: CGFloat = 0
            for (index, seg) in segments.enumerated() where seg.value > 0 {
                let w = max(height, usableW * CGFloat(seg.value) / CGFloat(total))
                let clampedW = min(w, max(0, size.width - x))
                let rect = CGRect(x: x, y: 0, width: clampedW, height: size.height)
                let path = Path(roundedRect: rect, cornerRadius: height / 2, style: .continuous)
                context.fill(path, with: .color(seg.color))
                x += clampedW + (index < segments.count - 1 ? gap : 0)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - Annual Activity Heatmap Card (Promoted First-Class Card)

private struct OverviewHeatmapCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let samples: [ActivityHeatmapSample]
    let dataRevision: UInt64
    let currentStreak: Int
    let maxStreak: Int
    let activeDays: Int
    let bestDayTokens: Int
    let isWide: Bool

    var body: some View {
        let emerald = colorScheme == .dark
            ? Color(red: 0.24, green: 0.80, blue: 0.50)
            : Color(red: 0.14, green: 0.66, blue: 0.40)

        OverviewSurfaceCard(accent: nil) {
            VStack(alignment: .leading, spacing: 16) {
                if isWide {
                    OverviewCardHeader(
                        title: "年度活跃",
                        subtitle: "每日 Token 活跃热力图"
                    ) {
                        statPillsRow(emerald: emerald)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        OverviewCardHeader(
                            title: "年度活跃",
                            subtitle: "每日 Token 活跃热力图"
                        )
                        ViewThatFits(in: .horizontal) {
                            statPillsRow(emerald: emerald)
                            LazyVGrid(
                                columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                                alignment: .leading,
                                spacing: 6
                            ) {
                                statPillsContent(emerald: emerald)
                            }
                        }
                    }
                }

                ActivityHeatmap(samples: samples, dataRevision: dataRevision)
            }
        }
    }

    private func statPillsRow(emerald: Color) -> some View {
        HStack(spacing: 6) {
            statPillsContent(emerald: emerald)
        }
    }

    @ViewBuilder
    private func statPillsContent(emerald: Color) -> some View {
        OverviewStatPill(label: "连续活跃", value: String(localized: "\(currentStreak) 天"), tint: currentStreak > 0 ? emerald : nil)
        OverviewStatPill(label: "最长连续", value: String(localized: "\(maxStreak) 天"))
        OverviewStatPill(label: "累计活跃", value: String(localized: "\(activeDays) 天"))
        OverviewStatPill(label: "单日峰值", value: bestDayTokens > 0 ? bestDayTokens.compactTokenString : "—")
    }
}

// MARK: - Coding Rhythm Card (Interactive 24h & Weekday Distribution)

private struct OverviewRhythmCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let hourlyBuckets: [OverviewHourlyBucket]
    let weekdayBuckets: [OverviewWeekdayBucket]
    let peakHour: String
    let peakWeekday: String
    let isTwoColumn: Bool
    let isCompact: Bool

    @State private var hoveredHour: Int?
    @State private var hoveredWeekday: Int?

    private var maxHourCount: Int {
        hourlyBuckets.map(\.sessionCount).max() ?? 0
    }

    private var maxWeekdayCount: Int {
        weekdayBuckets.map(\.sessionCount).max() ?? 0
    }

    var body: some View {
        OverviewSurfaceCard {
            VStack(alignment: .leading, spacing: 16) {
                if isCompact {
                    VStack(alignment: .leading, spacing: 10) {
                        OverviewCardHeader(
                            title: "编码节律",
                            subtitle: "24 小时与星期活跃分布"
                        )
                        rhythmPills
                    }
                } else {
                    OverviewCardHeader(
                        title: "编码节律",
                        subtitle: "24 小时与星期活跃分布"
                    ) {
                        rhythmPills
                    }
                }

                if maxHourCount == 0 && maxWeekdayCount == 0 {
                    OverviewEmptyPlaceholder(message: "暂无活跃数据", height: 120)
                } else if isTwoColumn {
                    HStack(alignment: .top, spacing: 20) {
                        hourlyChartSection
                            .frame(maxWidth: .infinity)
                        Rectangle()
                            .fill(Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.065))
                            .frame(width: 0.5)
                            .padding(.vertical, 4)
                        weekdayChartSection
                            .frame(width: 280)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 20) {
                        hourlyChartSection
                        OverviewHairline(opacity: 0.08)
                        weekdayChartSection
                    }
                }
            }
        }
    }

    private var rhythmPills: some View {
        HStack(spacing: 6) {
            OverviewStatPill(label: "高峰时段", value: peakHour, tint: .accentColor)
            OverviewStatPill(label: "最忙星期", value: peakWeekday)
        }
    }

    private var hourlyChartSection: some View {
        let hoveredBucket = hoveredHour.flatMap { h in hourlyBuckets.first { $0.hour == h } }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("会话时段")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                if let b = hoveredBucket {
                    Text("\(b.label) · \(b.sessionCount) 次 · \(b.tokens.compactTokenString)")
                        .font(.system(size: 10.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                } else {
                    Text("24 小时分布")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(height: 18)

            Chart(hourlyBuckets) { bucket in
                let isPeak = bucket.sessionCount == maxHourCount && maxHourCount > 0
                let isHovered = hoveredHour == bucket.hour
                BarMark(
                    x: .value("Hour", bucket.hour),
                    y: .value("Sessions", bucket.sessionCount)
                )
                .foregroundStyle(
                    isHovered
                        ? Color.accentColor
                        : (isPeak ? Color.accentColor.opacity(0.92) : Color.accentColor.opacity(colorScheme == .dark ? 0.36 : 0.28))
                )
                .cornerRadius(3)
            }
            .chartXScale(domain: -0.5...23.5)
            .chartXAxis {
                AxisMarks(values: [0, 4, 8, 12, 16, 20]) { value in
                    AxisValueLabel {
                        if let h = value.as(Int.self) {
                            Text(String(format: "%02d:00", h))
                                .font(.system(size: 10))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartYAxis(.hidden)
            .frame(height: 116)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                guard let plotFrame = proxy.plotFrame else { return }
                                let x = location.x - geo[plotFrame].origin.x
                                if let hour: Double = proxy.value(atX: x) {
                                    let rounded = Int(hour.rounded())
                                    if (0..<24).contains(rounded) {
                                        if hoveredHour != rounded { hoveredHour = rounded }
                                    }
                                }
                            case .ended:
                                if hoveredHour != nil { hoveredHour = nil }
                            }
                        }
                }
            }
        }
    }

    private var weekdayChartSection: some View {
        let hoveredBucket = hoveredWeekday.flatMap { idx in weekdayBuckets.first { $0.weekdayIndex == idx } }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("每周节奏")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                if let b = hoveredBucket {
                    Text("\(b.fullLabel) · \(b.sessionCount) 次 · \(b.tokens.compactTokenString)")
                        .font(.system(size: 10.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                } else {
                    Text("周一至周日")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(height: 18)

            Chart(weekdayBuckets) { bucket in
                let isPeak = bucket.sessionCount == maxWeekdayCount && maxWeekdayCount > 0
                let isHovered = hoveredWeekday == bucket.weekdayIndex
                BarMark(
                    x: .value("Weekday", bucket.shortLabel),
                    y: .value("Sessions", bucket.sessionCount)
                )
                .foregroundStyle(
                    isHovered
                        ? Color.accentColor
                        : (isPeak ? Color.accentColor.opacity(0.92) : Color.accentColor.opacity(colorScheme == .dark ? 0.36 : 0.28))
                )
                .cornerRadius(4)
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisValueLabel()
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .chartYAxis(.hidden)
            .frame(height: 116)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                guard let plotFrame = proxy.plotFrame else { return }
                                let x = location.x - geo[plotFrame].origin.x
                                if let label: String = proxy.value(atX: x),
                                   let match = weekdayBuckets.first(where: { $0.shortLabel == label }) {
                                    if hoveredWeekday != match.weekdayIndex { hoveredWeekday = match.weekdayIndex }
                                }
                            case .ended:
                                if hoveredWeekday != nil { hoveredWeekday = nil }
                            }
                        }
                }
            }
        }
    }
}

// MARK: - Development Context Card (Top Projects & Git Branches)

private struct OverviewContextCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let projects: [OverviewRankedItem]
    let branches: [OverviewRankedItem]
    let isTwoColumn: Bool

    var body: some View {
        OverviewSurfaceCard {
            VStack(alignment: .leading, spacing: 16) {
                OverviewCardHeader(
                    title: "开发上下文",
                    subtitle: "项目与分支的用量分布"
                )

                if isTwoColumn {
                    HStack(alignment: .top, spacing: 24) {
                        rankedColumn(
                            title: "高频项目",
                            icon: "folder",
                            items: projects,
                            color: Color.accentColor
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Rectangle()
                            .fill(Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.065))
                            .frame(width: 0.5)
                            .padding(.vertical, 4)

                        rankedColumn(
                            title: "活跃分支",
                            icon: "arrow.triangle.branch",
                            items: branches,
                            color: colorScheme == .dark
                                ? Color(red: 0.70, green: 0.54, blue: 0.96)
                                : Color(red: 0.52, green: 0.34, blue: 0.84)
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 20) {
                        rankedColumn(
                            title: "高频项目",
                            icon: "folder",
                            items: projects,
                            color: Color.accentColor
                        )
                        OverviewHairline(opacity: 0.08)
                        rankedColumn(
                            title: "活跃分支",
                            icon: "arrow.triangle.branch",
                            items: branches,
                            color: colorScheme == .dark
                                ? Color(red: 0.70, green: 0.54, blue: 0.96)
                                : Color(red: 0.52, green: 0.34, blue: 0.84)
                        )
                    }
                }
            }
        }
    }

    private func rankedColumn(
        title: LocalizedStringKey,
        icon: String,
        items: [OverviewRankedItem],
        color: Color
    ) -> some View {
        let maxTokens = max(1, items.map(\.tokens).max() ?? 1)
        let totalTokens = max(1, items.reduce(0) { $0 + $1.tokens })

        return VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)

            if items.isEmpty {
                OverviewEmptyPlaceholder(message: "暂无数据", height: 72)
            } else {
                VStack(spacing: 4) {
                    ForEach(items) { item in
                        OverviewHoverRow(tint: color) {
                            VStack(spacing: 6) {
                                HStack(spacing: 7) {
                                    Image(systemName: icon)
                                        .font(.system(size: 10.5, weight: .medium))
                                        .foregroundStyle(color.opacity(0.85))
                                    Text(item.name)
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .help(item.name)
                                    Spacer(minLength: 8)
                                    Text("\(item.sessionCount) 次")
                                        .font(.system(size: 10.5))
                                        .monospacedDigit()
                                        .foregroundStyle(.tertiary)
                                    Text(item.tokens.compactTokenString)
                                        .font(.system(size: 12, weight: .semibold))
                                        .monospacedDigit()
                                    Text("\(Int((Double(item.tokens) / Double(totalTokens) * 100).rounded()))%")
                                        .font(.system(size: 10.5))
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                        .frame(width: 30, alignment: .trailing)
                                }
                                OverviewLuminousBar(
                                    fraction: Double(item.tokens) / Double(maxTokens),
                                    color: color,
                                    height: 4
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Model Leaderboard Card

private struct OverviewModelsCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let models: [OverviewModelEntry]

    var body: some View {
        let maxTokens = max(1, models.map(\.tokens).max() ?? 1)

        OverviewSurfaceCard {
            VStack(alignment: .leading, spacing: 14) {
                OverviewCardHeader(
                    title: "模型排行",
                    subtitle: "按当前周期的 Token 用量排序"
                )

                if models.isEmpty {
                    OverviewEmptyPlaceholder(message: "暂无模型数据", height: 120)
                } else {
                    VStack(spacing: 4) {
                        ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                            let accent = model.primaryTool.brandAccentColor(for: colorScheme)
                            OverviewHoverRow(tint: accent) {
                                VStack(spacing: 7) {
                                    HStack(alignment: .center, spacing: 10) {
                                        Text("\(index + 1)")
                                            .font(.system(size: 10, weight: .bold))
                                            .monospacedDigit()
                                            .foregroundStyle(index == 0 ? accent : .secondary)
                                            .frame(width: 20, height: 20)
                                            .background(
                                                (index == 0 ? accent : Color.primary).opacity(colorScheme == .dark ? 0.16 : 0.08),
                                                in: Circle()
                                            )

                                        VStack(alignment: .leading, spacing: 3) {
                                            HStack(spacing: 6) {
                                                Text(model.name)
                                                    .font(.system(size: 12.5, weight: .semibold))
                                                    .lineLimit(1)
                                                    .help(model.name)
                                                if !model.favoriteProject.isEmpty {
                                                    Text(model.favoriteProject)
                                                        .font(.system(size: 10))
                                                        .foregroundStyle(.secondary)
                                                        .padding(.horizontal, 6)
                                                        .padding(.vertical, 1.5)
                                                        .background(Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.05), in: Capsule())
                                                        .lineLimit(1)
                                                }
                                            }
                                            Text("\(model.sessionCount) 次会话 · 平均 \(model.avgTokens.compactTokenString)")
                                                .font(.system(size: 10.5))
                                                .monospacedDigit()
                                                .foregroundStyle(.secondary)
                                        }

                                        Spacer(minLength: 12)

                                        VStack(alignment: .trailing, spacing: 2) {
                                            Text(model.tokens.compactTokenString)
                                                .font(.system(size: 13, weight: .semibold))
                                                .monospacedDigit()
                                            Text(model.lastUsed, format: .relative(presentation: .named))
                                                .font(.system(size: 10))
                                                .foregroundStyle(.tertiary)
                                        }
                                    }

                                    OverviewLuminousBar(
                                        fraction: Double(model.tokens) / Double(maxTokens),
                                        color: accent,
                                        height: 4
                                    )
                                    .padding(.leading, 30)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Per-Tool Telemetry Breakdown Card (Full-Width Responsive Brand Grid)

private struct OverviewToolsDetailCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let tools: [OverviewToolSummary]
    let isTwoColumn: Bool
    let isWide: Bool

    private var columnCount: Int {
        guard isTwoColumn else { return 1 }
        if tools.count <= 1 { return 1 }
        if tools.count == 3 && isWide { return 3 }
        return 2
    }

    var body: some View {
        OverviewSurfaceCard {
            VStack(alignment: .leading, spacing: 14) {
                OverviewCardHeader(
                    title: "工具详情",
                    subtitle: "各工具用量、输入输出比例与缓存效率"
                )

                if tools.isEmpty {
                    OverviewEmptyPlaceholder(message: "暂无工具数据", height: 120)
                } else {
                    let columns = Array(
                        repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
                        count: columnCount
                    )
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(tools) { item in
                            toolMiniPlate(item)
                        }
                    }
                }
            }
        }
    }

    private func toolMiniPlate(_ item: OverviewToolSummary) -> some View {
        let accent = item.tool.brandAccentColor(for: colorScheme)
        let inputShare = Double(item.inputTokens) / Double(max(1, item.inputTokens + item.outputTokens))
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)

        return VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                ToolBrandIconWell(tool: item.tool, size: 24, iconSize: 14)
                Text(item.tool.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text("\(item.sessionCount) 次会话")
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.totalTokens.compactTokenString)
                    .font(.system(size: 20, weight: .semibold))
                    .monospacedDigit()
                Text("Tokens")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let cost = item.estimatedCostUSD {
                    Text(cost, format: .currency(code: "USD"))
                        .font(.system(size: 11.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 24)

            VStack(spacing: 5) {
                OverviewLuminousBar(fraction: inputShare, color: accent, height: 4.5)
                HStack {
                    Text("输入 \(item.inputTokens.compactTokenString)")
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text("输出 \(item.outputTokens.compactTokenString)")
                        .lineLimit(1)
                }
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 14) {
                HStack(spacing: 4) {
                    Text("缓存命中率").foregroundStyle(.tertiary)
                    Text(String(format: "%.0f%%", item.cacheHitRate * 100))
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                .lineLimit(1)
                HStack(spacing: 4) {
                    Text("平均").foregroundStyle(.tertiary)
                    Text(item.avgTokensPerSession.compactTokenString)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                .lineLimit(1)
            }
            .font(.system(size: 10.5))
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            ZStack(alignment: .topLeading) {
                shape.fill(Color.primary.opacity(colorScheme == .dark ? 0.04 : 0.024))
                RadialGradient(
                    colors: [accent.opacity(colorScheme == .dark ? 0.14 : 0.075), Color.clear],
                    center: .topLeading,
                    startRadius: 2,
                    endRadius: 160
                )
            }
        }
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(accent.opacity(colorScheme == .dark ? 0.18 : 0.12), lineWidth: 0.6)
        }
    }
}

// MARK: - Cost Reference Section (Sleek Collapsible Specular Card, No Redundant Balances)

private struct OverviewCostCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let snapshot: OverviewSnapshot
    let days: Int
    let isTwoColumn: Bool

    @State private var isExpanded = false
    @State private var hoveredDate: Date?

    private var hasCostData: Bool {
        snapshot.totalUSD > 0 || snapshot.totalCNY > 0
    }

    private var totalCostLabel: String {
        if snapshot.totalUSD > 0 { return OverviewCurrency.usd(snapshot.totalUSD) }
        if snapshot.totalCNY > 0 { return OverviewCurrency.cny(snapshot.totalCNY) }
        return "—"
    }

    private var hoveredCostPoint: OverviewCostDayPoint? {
        guard let hoveredDate else { return nil }
        let cal = Calendar.current
        return snapshot.costTimeline.first { cal.isDate($0.date, inSameDayAs: hoveredDate) }
    }

    var body: some View {
        OverviewSurfaceCard(padding: 20) {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("成本估算")
                                .font(.system(size: 14.5, weight: .semibold))
                                .tracking(-0.2)
                            Text("公开模型价格的用量参考")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 8)

                        if hasCostData {
                            OverviewStatPill(label: "总估算成本", value: totalCostLabel)
                        }

                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 22, height: 22)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()

                if isExpanded {
                    VStack(alignment: .leading, spacing: 20) {
                        OverviewHairline(opacity: 0.08)
                            .padding(.top, 14)

                        // 4 Summary Metrics
                        let cols = Array(
                            repeating: GridItem(.flexible(), spacing: 16, alignment: .leading),
                            count: isTwoColumn ? 4 : 2
                        )
                        LazyVGrid(columns: cols, alignment: .leading, spacing: 16) {
                            costMetric(
                                title: "总估算成本",
                                value: totalCostLabel,
                                subtitle: snapshot.totalUSD > 0 && snapshot.totalCNY > 0
                                    ? String(localized: "另计 \(OverviewCurrency.cny(snapshot.totalCNY))")
                                    : nil
                            )
                            costMetric(title: "日均成本 · USD", value: OverviewCurrency.usd(snapshot.dailyAverageUSD))
                            costMetric(title: "最高成本工具", value: snapshot.mostExpensiveTool?.displayName ?? "—")
                            costMetric(
                                title: "每千 Token 成本",
                                value: snapshot.costEfficiencyPer1K.map { String(format: "$%.4f", $0) } ?? "—"
                            )
                        }

                        if hasCostData {
                            OverviewHairline(opacity: 0.08)

                            let layout = isTwoColumn
                                ? AnyLayout(HStackLayout(alignment: .top, spacing: 26))
                                : AnyLayout(VStackLayout(alignment: .leading, spacing: 22))
                            layout {
                                dailyCostChart
                                    .frame(maxWidth: .infinity)
                                perToolCostList
                                    .frame(width: isTwoColumn ? 240 : nil)
                                    .frame(maxWidth: isTwoColumn ? nil : .infinity, alignment: .leading)
                            }

                            if !snapshot.topModelCosts.isEmpty {
                                OverviewHairline(opacity: 0.08)
                                topModelCostsList
                            }
                        } else {
                            OverviewEmptyPlaceholder(message: "暂无可估算的成本数据", height: 72)
                        }

                        Text("估算基于公开定价，仅供参考。")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .transition(.opacity)
                }
            }
        }
    }

    private func costMetric(title: LocalizedStringKey, value: String, subtitle: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 17, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var dailyCostChart: some View {
        let axisColor = colorScheme == .dark ? Color.white.opacity(0.55) : Color.black.opacity(0.45)
        let hasUSDTimeline = snapshot.costTimeline.contains { $0.cents > 0 }

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("每日估算成本 · USD")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                if let hovered = hoveredCostPoint {
                    Text("\(hovered.date.formatted(.dateTime.month(.twoDigits).day(.twoDigits))) · \(String(format: "$%.2f", hovered.dollars))")
                        .font(.system(size: 10.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                } else {
                    Text("悬停查看明细")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(height: 18)

            if !hasUSDTimeline {
                OverviewEmptyPlaceholder(message: "暂无 USD 成本数据", height: 148)
            } else {
                Chart {
                    ForEach(snapshot.costTimeline) { point in
                        AreaMark(
                            x: .value("Date", point.date, unit: .day),
                            y: .value("USD", point.dollars)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.20), Color.accentColor.opacity(0.01)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.monotone)

                        LineMark(
                            x: .value("Date", point.date, unit: .day),
                            y: .value("USD", point.dollars)
                        )
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                        .interpolationMethod(.monotone)
                    }

                    if let hovered = hoveredCostPoint {
                        RuleMark(x: .value("Hovered", hovered.date, unit: .day))
                            .foregroundStyle(Color.primary.opacity(0.22))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        PointMark(
                            x: .value("Date", hovered.date, unit: .day),
                            y: .value("USD", hovered.dollars)
                        )
                        .foregroundStyle(Color.accentColor)
                        .symbolSize(44)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: max(1, days / 7))) { _ in
                        AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                            .foregroundStyle(axisColor)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06))
                        AxisValueLabel {
                            if let dollars = value.as(Double.self) {
                                Text(String(format: "$%.2f", dollars))
                                    .font(.system(size: 10))
                                    .monospacedDigit()
                                    .foregroundStyle(axisColor)
                            }
                        }
                    }
                }
                .frame(height: 152)
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    guard let plotFrame = proxy.plotFrame else { return }
                                    let x = location.x - geo[plotFrame].origin.x
                                    if let date: Date = proxy.value(atX: x) {
                                        let day = Calendar.current.startOfDay(for: date)
                                        if hoveredDate != day { hoveredDate = day }
                                    }
                                case .ended:
                                    if hoveredDate != nil { hoveredDate = nil }
                                }
                            }
                    }
                }
            }
        }
    }

    private var perToolCostList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("工具成本")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 10) {
                ForEach(snapshot.perToolCosts) { item in
                    HStack(alignment: .center, spacing: 8) {
                        ToolBrandIconWell(tool: item.tool, size: 22, iconSize: 13)
                        Text(item.tool.displayName)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        VStack(alignment: .trailing, spacing: 2) {
                            if item.usd > 0 { Text(OverviewCurrency.usd(item.usd)) }
                            if item.cny > 0 { Text(OverviewCurrency.cny(item.cny)) }
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                    }
                }
            }
        }
    }

    private var topModelCostsList: some View {
        let maxCents = max(1, snapshot.topModelCosts.map(\.cents).max() ?? 1)
        return VStack(alignment: .leading, spacing: 10) {
            Text("模型成本 · 前 5")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 8) {
                ForEach(snapshot.topModelCosts) { item in
                    VStack(spacing: 5) {
                        HStack(spacing: 8) {
                            Text(item.name)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            Text(String(format: "$%.2f", Double(item.cents) / 100.0))
                                .font(.system(size: 12, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        OverviewLuminousBar(
                            fraction: Double(item.cents) / Double(maxCents),
                            color: Color.accentColor,
                            height: 4
                        )
                    }
                }
            }
        }
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
