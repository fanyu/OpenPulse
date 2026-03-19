import SwiftUI
import SwiftData
import Charts

struct TrendsView: View {
    @Environment(AppStore.self) private var appStore
    @Query private var allSessions: [SessionRecord]
    @Query(sort: \DailyStatsRecord.date) private var dailyStats: [DailyStatsRecord]
    @Query(sort: \QuotaRecord.updatedAt, order: .reverse) private var allQuotas: [QuotaRecord]

    @State private var range: ChartRange = .month
    @State private var showComparison = false

    init() {
        // Limit to 90 days (the max ChartRange). Without this, allSessions grows
        // unboundedly and updateDerivedCache() blocks the main thread on window open.
        let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? Date()
        _allSessions = Query(
            filter: #Predicate<SessionRecord> { $0.startedAt > cutoff },
            sort: \SessionRecord.startedAt,
            order: .reverse
        )
    }

    // Cached derived data — recomputed only when range or underlying data changes,
    // not on every render pass. Eliminates 20+ redundant O(n) filter operations per render.
    @State private var cachedFilteredSessions: [SessionRecord] = []
    @State private var cachedFilteredStats: [DailyStatsRecord] = []
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
    }

    private var cal: Calendar { Calendar.current }
    private var today: Date { cal.startOfDay(for: Date()) }
    private var yesterday: Date { cal.date(byAdding: .day, value: -1, to: today)! }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                welcomeHeader
                bentoGridStats
                tokenUsageTrendSection
                modelAndToolDistributionRow
                contextAnalysisSection
                activitySection
                toolSummarySection
                costAnalyticsSection
            }
            .padding(24)
        }
        .navigationTitle("数据总览")
        .background(Color(NSColor.windowBackgroundColor))
        .task { updateDerivedCache() }
        .onChange(of: range) { _, _ in updateDerivedCache() }
        .onChange(of: allSessions.count) { _, _ in updateDerivedCache() }
        .onChange(of: dailyStats.count) { _, _ in updateDerivedCache() }
    }

    private var welcomeHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                let hour = cal.component(.hour, from: Date())
                let greeting = hour < 12 ? "早上好" : (hour < 18 ? "下午好" : "晚上好")
                Text("\(greeting), Developer")
                    .font(.system(size: 28, weight: .bold))
                Spacer()
                Picker("时间范围", selection: $range) {
                    ForEach(ChartRange.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 200)
            }
            
            HStack(spacing: 12) {

                Label("今日已消耗 \(todayTotalTokens.compactTokenString) tokens", systemImage: "bolt.fill").font(.subheadline).foregroundStyle(.secondary)
                if let delta = percentDelta(today: todayTotalTokens, yesterday: yesterdayTotalTokens) {
                    Label("\(abs(delta))%", systemImage: delta >= 0 ? "arrow.up" : "arrow.down").font(.caption.bold()).foregroundStyle(delta >= 0 ? .red : .green).padding(.horizontal, 6).padding(.vertical, 2).background((delta >= 0 ? Color.red : Color.green).opacity(0.1), in: Capsule())
                }
            }
        }
    }

    private var bentoGridStats: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
            StatCard(title: "近 \(range.days) 天总量", value: rangeTotalTokens.compactTokenString, icon: "bolt.ring.closed", color: .blue, delta: rangeWoWDelta, isGlass: true)
            StatCard(title: "全局缓存率", value: String(format: "%.1f%%", globalCacheHitRate * 100), icon: "leaf.fill", color: .green, isGlass: true)
            StatCard(title: "最爱工具", value: topTool?.displayName ?? "—", icon: "heart.fill", color: .red, isGlass: true)
            StatCard(title: "活跃峰值", value: peakHourLabel, icon: "timer", color: .orange, isGlass: true)
        }
    }

    private var tokenUsageTrendSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Token 使用趋势")
            WeeklyAreaChart(data: timelinePoints, color: .accentColor).frame(height: 260).padding().glassEffect(.regular, in: .rect(cornerRadius: 16))
        }
    }

    private var modelAndToolDistributionRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "分布与占比分析")
            HStack(alignment: .top, spacing: 0) {
                // Left: model leaderboard (no duplicate bar chart)
                VStack(alignment: .leading, spacing: 16) {
                    Label("模型效能排行", systemImage: "cpu.fill").font(.subheadline.bold()).foregroundStyle(.secondary)
                    let data = topModelDeepData
                    if data.isEmpty {
                        emptyChartPlaceholder(height: 180)
                    } else {
                        let maxTokens = data.first?.tokens ?? 1
                        VStack(spacing: 0) {
                            ForEach(Array(data.prefix(5).enumerated()), id: \.element.name) { idx, item in
                                ModelLeaderboardRow(rank: idx + 1, model: item.name, tokens: item.tokens, fraction: Double(item.tokens) / Double(maxTokens), color: .blue, lastUsed: item.lastUsed, sessionCount: item.sessionCount, favoriteProject: item.favoriteProject, avgTokens: item.sessionCount > 0 ? item.tokens / item.sessionCount : 0)
                                if idx < min(4, data.count - 1) { Divider().opacity(0.08).padding(.vertical, 6) }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 32)

                Rectangle().fill(Color.primary.opacity(0.06)).frame(width: 1).padding(.vertical, 8)

                // Right: donut + rich legend
                VStack(alignment: .leading, spacing: 16) {
                    Label("工具份额占比", systemImage: "chart.pie.fill").font(.subheadline.bold()).foregroundStyle(.secondary)
                    let toolData = aggregateByTool
                    if toolData.isEmpty {
                        Text("无工具数据").foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .center)
                    } else {
                        ZStack {
                            Chart(toolData, id: \.tool) {
                                SectorMark(angle: .value("Tokens", $0.tokens), innerRadius: .ratio(0.6), angularInset: 2)
                                    .foregroundStyle(Color($0.tool.accentColorName).gradient)
                            }
                            .frame(height: 180)
                            VStack(spacing: 3) {
                                Text(grandTotal.compactTokenString)
                                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                                Text("Tokens").font(.system(size: 9)).foregroundStyle(.secondary)
                                Text("\(toolData.count) 工具").font(.system(size: 9)).foregroundStyle(.tertiary)
                            }
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(toolData, id: \.tool) { item in
                                let pct = Double(item.tokens) / Double(max(1, grandTotal))
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        ToolLogoImage(tool: item.tool, size: 13)
                                        Text(item.tool.displayName).font(.system(size: 11)).foregroundStyle(.secondary)
                                        Spacer()
                                        Text(item.tokens.compactTokenString)
                                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        Text(String(format: "%.0f%%", pct * 100))
                                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                                            .frame(width: 30, alignment: .trailing)
                                    }
                                    GeometryReader { geo in
                                        ZStack(alignment: .leading) {
                                            Capsule().fill(Color.primary.opacity(0.06)).frame(height: 4)
                                            Capsule().fill(Color(item.tool.accentColorName).opacity(0.7))
                                                .frame(width: geo.size.width * CGFloat(pct), height: 4)
                                        }
                                    }
                                    .frame(height: 4)
                                }
                            }
                        }
                    }
                }
                .frame(width: 280)
                .padding(.leading, 32)
            }
            .padding(24)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
        }
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "活动分析")
            VStack(spacing: 0) {
                // Top: GitHub-style activity heatmap (full width)
                ActivityHeatmap(dailyStats: Array(dailyStats))
                    .frame(maxWidth: .infinity)
                    .padding(20)

                Divider().opacity(0.08)

                // Bottom: achievement stats (left) | hourly + weekday charts (right)
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        let statsSet: [(String, String, String, Color)] = [
                            ("当前连击",   "\(currentStreak) 天",          "flame.fill",               .orange),
                            ("历史最高",   "\(maxStreak) 天",              "trophy.fill",              .yellow),
                            ("总活跃天数", "\(activeDaysCount) 天",        "calendar.badge.checkmark", .green),
                            ("单日巅峰",   bestDayEverLabel,               "bolt.fill",                .blue),
                            ("周期会话数", "\(filteredSessions.count)",    "bubble.left.fill",         .indigo),
                            ("日均会话",   String(format: "%.1f", Double(filteredSessions.count) / Double(max(1, range.days))), "chart.bar.fill", .teal),
                        ]
                        ForEach(0..<statsSet.count, id: \.self) { i in
                            activityStatItem(label: statsSet[i].0, value: statsSet[i].1, icon: statsSet[i].2, color: statsSet[i].3)
                            if i < statsSet.count - 1 { Divider().opacity(0.08).padding(.vertical, 8) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 32)

                    Rectangle().fill(Color.primary.opacity(0.06)).frame(width: 1).padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("按小时分布", systemImage: "clock").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            Chart(hourlyActivityPoints, id: \.hour) { pt in
                                BarMark(x: .value("H", pt.hourLabel), y: .value("N", pt.count))
                                    .foregroundStyle(Color.orange.gradient).cornerRadius(2)
                            }
                            .chartXAxis { AxisMarks(values: .stride(by: 6)) { _ in AxisValueLabel().font(.system(size: 8)) } }
                            .chartYAxis(.hidden)
                            .frame(height: 90)
                        }
                        Divider().opacity(0.08)
                        VStack(alignment: .leading, spacing: 6) {
                            Label("按星期分布", systemImage: "calendar").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            Chart(weekdayActivityPoints, id: \.weekday) { pt in
                                BarMark(x: .value("D", pt.label), y: .value("N", pt.count))
                                    .foregroundStyle(Color.purple.gradient).cornerRadius(2)
                            }
                            .chartYAxis(.hidden)
                            .frame(height: 90)
                        }
                        Divider().opacity(0.08)
                        HStack(spacing: 16) {
                            statLabel(label: "高峰时段", value: peakHourLabel, color: .orange)
                            Divider().frame(height: 28).opacity(0.2)
                            statLabel(label: "最忙星期", value: peakWeekdayLabel, color: .purple)
                            Divider().frame(height: 28).opacity(0.2)
                            statLabel(label: "均值/会话", value: avgTokensPerSession.compactTokenString, color: .blue)
                            Divider().frame(height: 28).opacity(0.2)
                            statLabel(label: "总会话数", value: "\(filteredSessions.count)", color: .indigo)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.leading, 32)
                }
                .padding(24)
            }
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
        }
    }

    private func activityStatItem(label: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 30, height: 30)
                .background(color.opacity(0.1), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 14, weight: .bold))
            }
            Spacer()
        }
    }

    private var contextAnalysisSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "开发上下文分析")
            HStack(alignment: .top, spacing: 0) {
                // Left: projects
                VStack(alignment: .leading, spacing: 12) {
                    Label("项目用量 TOP 5", systemImage: "folder.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                    let pData = projectDistribution
                    if pData.isEmpty { Text("暂无数据").font(.caption).foregroundStyle(.tertiary) } else { DistributionBarChart(data: pData.map { DistributionBarChart.Entry(label: $0.project, value: $0.tokens, color: .indigo) }, total: pData.map(\.tokens).reduce(0, +)) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 32)
                Rectangle().fill(Color.primary.opacity(0.06)).frame(width: 1).padding(.vertical, 4)
                // Right: branches
                VStack(alignment: .leading, spacing: 12) {
                    Label("活跃分支 TOP 3", systemImage: "arrow.triangle.branch").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                    let bData = branchDistribution
                    if bData.isEmpty { Text("暂无数据").font(.caption).foregroundStyle(.tertiary) } else { DistributionBarChart(data: bData.map { DistributionBarChart.Entry(label: $0.branch, value: $0.tokens, color: .teal) }, total: bData.map(\.tokens).reduce(0, +)) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 32)
            }
            .padding(24)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
        }
    }

    private func statLabel(label: String, value: String, color: Color) -> some View { VStack(alignment: .leading, spacing: 2) { Text(label).font(.system(size: 9)).foregroundStyle(.tertiary); Text(value).font(.system(size: 16, weight: .bold, design: .monospaced)).foregroundStyle(.primary) } }

    private var toolSummarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "各工具用量统计")
            let data = toolSummaryData
            if data.isEmpty { emptyChartPlaceholder(height: 80) } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    ForEach(data) { toolSummaryCard($0) }
                }
            }
        }
    }

    private func toolSummaryCard(_ item: ToolSummaryItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 10) {
                ToolLogoImage(tool: item.tool, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.tool.displayName).font(.system(size: 13, weight: .bold))
                    Text("\(item.sessionCount) 次会话").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Spacer()
                if let cost = item.estimatedCostUSD {
                    Text(String(format: "$%.2f", cost))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.green.opacity(0.1), in: Capsule())
                }
            }
            // Total tokens
            Text(item.totalTokens.compactTokenString)
                .font(.system(size: 22, weight: .bold, design: .monospaced))
            // Input / Output split bar
            let total = max(1, item.inputTokens + item.outputTokens)
            let inputFrac = Double(item.inputTokens) / Double(total)
            VStack(alignment: .leading, spacing: 4) {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.purple.opacity(0.2)).frame(height: 4)
                    GeometryReader { g in
                        Capsule().fill(Color.blue.opacity(0.7))
                            .frame(width: g.size.width * inputFrac, height: 4)
                    }.frame(height: 4)
                }
                HStack(spacing: 4) {
                    Circle().fill(Color.blue.opacity(0.7)).frame(width: 5, height: 5)
                    Text("输入 \(item.inputTokens.compactTokenString)").font(.system(size: 9)).foregroundStyle(.secondary)
                    Spacer()
                    Text("输出 \(item.outputTokens.compactTokenString)").font(.system(size: 9)).foregroundStyle(.secondary)
                    Circle().fill(Color.purple.opacity(0.7)).frame(width: 5, height: 5)
                }
            }
            Divider().opacity(0.08)
            // Bottom stats row
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("缓存率").font(.system(size: 9)).foregroundStyle(.tertiary)
                    Text(String(format: "%.0f%%", item.cacheHitRate * 100))
                        .font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(.green)
                }
                Divider().frame(height: 28).opacity(0.15).padding(.horizontal, 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text("均值/session").font(.system(size: 9)).foregroundStyle(.tertiary)
                    Text(item.avgTokensPerSession.compactTokenString)
                        .font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(.blue)
                }
            }
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private func percentDelta(today: Int, yesterday: Int) -> Int? { guard yesterday > 0 else { return nil }; return Int(((Double(today) - Double(yesterday)) / Double(yesterday) * 100).rounded()) }

    private var activeDaysCount: Int { cachedActiveDaysCount }
    private var currentStreak: Int { cachedCurrentStreak }
    private var maxStreak: Int { cachedMaxStreak }
    private var filteredStats: [DailyStatsRecord] { cachedFilteredStats }
    private var previousPeriodStats: [DailyStatsRecord] { let end = cal.date(byAdding: .day, value: -range.days, to: Date())!; let start = cal.date(byAdding: .day, value: -range.days * 2, to: Date())!; return dailyStats.filter { $0.date >= start && $0.date < end } }
    private var filteredSessions: [SessionRecord] { cachedFilteredSessions }
    private var todayTotalTokens: Int { cachedTodayTokens }
    private var yesterdayTotalTokens: Int { cachedYesterdayTokens }
    private var rangeTotalTokens: Int { filteredStats.reduce(0) { $0 + $1.totalInputTokens + $1.totalOutputTokens } }
    private var rangeWoWDelta: Int? { percentDelta(today: rangeTotalTokens, yesterday: previousPeriodStats.reduce(0) { $0 + $1.totalInputTokens + $1.totalOutputTokens }) }
    private var globalCacheHitRate: Double { let saved = filteredSessions.reduce(0) { $0 + $1.cacheReadTokens }; let total = rangeTotalTokens + saved; return total > 0 ? Double(saved) / Double(total) : 0 }
    private var topTool: Tool? { cachedAggregateByTool.first?.tool }
    private var peakHourLabel: String { let peak = cachedHourlyActivityPoints.max(by: { $0.count < $1.count })?.hour ?? 0; return String(format: "%02d:00", peak) }
    private var avgTokensPerSession: Int { let total = filteredSessions.reduce(0) { $0 + $1.totalTokens }; return filteredSessions.count > 0 ? total / filteredSessions.count : 0 }
    private var aggregateByTool: [(tool: Tool, tokens: Int)] { cachedAggregateByTool }
    private var grandTotal: Int { cachedAggregateByTool.reduce(0) { $0 + $1.tokens } }
    private var timelinePoints: [WeeklyAreaChart.Point] { dailyTotals(from: filteredStats).map { WeeklyAreaChart.Point(date: $0.date, value: $0.tokens) } }
    private func dailyTotals(from stats: [DailyStatsRecord]) -> [DailyPoint] { var map: [Date: Int] = [:] ; for stat in stats { let day = cal.startOfDay(for: stat.date); map[day, default: 0] += stat.totalInputTokens + stat.totalOutputTokens }; return map.map { DailyPoint(date: $0.key, tokens: $0.value) }.sorted { $0.date < $1.date } }
    private struct ModelDeepEntry: Identifiable { let name: String; let tokens: Int; let lastUsed: Date; let sessionCount: Int; let favoriteProject: String; var id: String { name } }
    private var topModelDeepData: [ModelDeepEntry] { cachedTopModelDeepData }
    private struct ProjectDist: Identifiable { let id = UUID(); let project: String; let tokens: Int }
    private var projectDistribution: [ProjectDist] { cachedProjectDistribution }
    private struct BranchDist: Identifiable { let id = UUID(); let branch: String; let tokens: Int }
    private var branchDistribution: [BranchDist] { cachedBranchDistribution }
    private struct HourlyPoint { let hour: Int; let count: Int; var hourLabel: String { String(format: "%02d", hour) } }
    private var hourlyActivityPoints: [HourlyPoint] { cachedHourlyActivityPoints }
    private struct WeekdayPoint { let weekday: Int; let count: Int; var label: String { ["日","一","二","三","四","五","六"][weekday] } }
    private var weekdayActivityPoints: [WeekdayPoint] { cachedWeekdayActivityPoints }
    private var peakWeekdayLabel: String { let names = ["周日","周一","周二","周三","周四","周五","周六"]; return names[cachedWeekdayActivityPoints.max(by: { $0.count < $1.count })?.weekday ?? 1] }
    private struct ToolSummaryItem: Identifiable {
        let tool: Tool; let totalTokens: Int; let inputTokens: Int; let outputTokens: Int
        let sessionCount: Int; let cacheHitRate: Double; let estimatedCostUSD: Double?
        var id: Tool { tool }
        var avgTokensPerSession: Int { sessionCount > 0 ? totalTokens / sessionCount : 0 }
    }
    private var toolSummaryData: [ToolSummaryItem] { cachedToolSummaryData }
    private func emptyChartPlaceholder(height: CGFloat) -> some View { Text("暂无数据").font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: height).glassEffect(.regular, in: .rect(cornerRadius: 16)) }
    private var bestDayEverLabel: String { let best = dailyStats.map { $0.totalInputTokens + $0.totalOutputTokens }.max() ?? 0; return best > 0 ? best.compactTokenString : "—" }

    // MARK: - Cost Analytics

    private var costAnalyticsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "成本分析 (估算)")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                let costStr = rangeTotalCNY > 0 ? formatUSD(rangeTotalUSD) + " + " + formatCNY(rangeTotalCNY) : formatUSD(rangeTotalUSD)
                StatCard(title: "总估算成本", value: costStr, icon: "dollarsign.circle.fill", color: .green, isGlass: true)
                StatCard(title: "日均成本", value: formatUSD(dailyAvgUSD > 0 ? dailyAvgUSD : nil), icon: "chart.line.uptrend.xyaxis", color: .blue, isGlass: true)
                StatCard(title: "最贵工具", value: mostExpensiveTool?.displayName ?? "—", icon: "flame.fill", color: .orange, isGlass: true)
                StatCard(title: "成本效率", value: costEfficiency.map { String(format: "$%.4f", $0) } ?? "—", unit: "/1K tokens", icon: "leaf.fill", color: .teal, isGlass: true)
            }
            if !hasCostData {
                emptyChartPlaceholder(height: 200)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("日成本趋势", systemImage: "chart.line.uptrend.xyaxis").font(.subheadline.bold()).foregroundStyle(.secondary)
                        if costTimelinePoints.isEmpty {
                            emptyChartPlaceholder(height: 160)
                        } else {
                            Chart(costTimelinePoints, id: \.date) { pt in
                                AreaMark(x: .value("Date", pt.date), y: .value("Cents", pt.value))
                                    .foregroundStyle(LinearGradient(colors: [Color.green.opacity(0.4), .clear], startPoint: .top, endPoint: .bottom))
                                    .interpolationMethod(.catmullRom)
                                LineMark(x: .value("Date", pt.date), y: .value("Cents", pt.value))
                                    .foregroundStyle(Color.green)
                                    .interpolationMethod(.catmullRom)
                                    .lineStyle(StrokeStyle(lineWidth: 2))
                            }
                            .chartXAxis { AxisMarks(values: .stride(by: .day, count: max(1, range.days / 7))) { _ in AxisValueLabel(format: .dateTime.month().day()) } }
                            .chartYAxis { AxisMarks { v in AxisValueLabel { if let c = v.as(Int.self) { Text(String(format: "$%.2f", Double(c) / 100)) } } } }
                            .frame(height: 160)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 32)
                    Rectangle().fill(Color.primary.opacity(0.06)).frame(width: 1).padding(.vertical, 8)
                    VStack(alignment: .leading, spacing: 8) {
                        Label("按工具分布", systemImage: "chart.pie.fill").font(.subheadline.bold()).foregroundStyle(.secondary)
                        let donutData = perToolCost.filter { $0.usd > 0 }
                        if donutData.isEmpty {
                            Text("无 USD 成本数据").font(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .center)
                        } else {
                            ZStack {
                                Chart(donutData, id: \.tool) { SectorMark(angle: .value("Cost", $0.usd), innerRadius: .ratio(0.65), angularInset: 1.5).foregroundStyle(Color($0.tool.accentColorName).gradient) }.frame(height: 120)
                                VStack(spacing: 0) { Text(formatUSD(rangeTotalUSD)).font(.system(size: 12, weight: .bold, design: .monospaced)); Text("USD").font(.system(size: 9)).foregroundStyle(.secondary) }
                            }
                            VStack(alignment: .leading, spacing: 6) { ForEach(donutData, id: \.tool) { item in HStack { ToolLogoImage(tool: item.tool, size: 12); Text(item.tool.displayName).font(.system(size: 10)).foregroundStyle(.secondary); Spacer(); Text(formatUSD(item.usd)).font(.system(size: 10, weight: .bold, design: .monospaced)) } } }
                        }
                    }
                    .frame(width: 220)
                    .padding(.leading, 32)
                }
                .padding(24)
                .glassEffect(.regular, in: .rect(cornerRadius: 24))
                if !topModelCosts.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("模型成本排行 TOP 5", systemImage: "cpu.fill").font(.subheadline.bold()).foregroundStyle(.secondary)
                        let maxCents = topModelCosts.first?.cents ?? 1
                        DistributionBarChart(
                            data: topModelCosts.map {
                                DistributionBarChart.Entry(
                                    label: $0.name,
                                    value: $0.cents,
                                    color: .green,
                                    displayValue: String(format: "$%.2f", Double($0.cents) / 100)
                                )
                            },
                            total: maxCents
                        )
                    }
                    .padding(20)
                    .glassEffect(.regular, in: .rect(cornerRadius: 16))
                }
            }
            if !balanceQuotas.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Label("余额监控", systemImage: "creditcard.fill").font(.subheadline.bold()).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        ForEach(Array(balanceQuotas.enumerated()), id: \.offset) { _, quota in
                            costBalanceCard(quota)
                        }
                    }
                }
                .padding(20)
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
            }
            Text("* 价格基于公开定价，仅供参考").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func costBalanceCard(_ quota: QuotaRecord) -> some View {
        let fraction = Double(quota.remaining ?? 0) / Double(max(1, quota.total ?? 100))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ToolLogoImage(tool: quota.tool, size: 16)
                Text(quota.accountLabel ?? quota.tool.displayName).font(.system(size: 11, weight: .semibold))
                Spacer()
            }
            QuotaProgressBar(fraction: fraction, color: quotaBarColor(fraction: fraction)).frame(height: 4)
            Text(String(format: "%.0f%% 剩余", fraction * 100)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }

    private var perToolCost: [(tool: Tool, usd: Double, cny: Double)] { cachedPerToolCost }

    private var rangeTotalUSD: Double { perToolCost.reduce(0) { $0 + $1.usd } }
    private var rangeTotalCNY: Double { perToolCost.reduce(0) { $0 + $1.cny } }
    private var dailyAvgUSD: Double { rangeTotalUSD / Double(max(1, range.days)) }
    private var mostExpensiveTool: Tool? { perToolCost.max { ($0.usd + $0.cny / 7.2) < ($1.usd + $1.cny / 7.2) }?.tool }
    private var costEfficiency: Double? { let t = filteredSessions.filter { $0.estimatedCost.usd != nil }.reduce(0) { $0 + $1.totalTokens }; guard t > 0 else { return nil }; return rangeTotalUSD / Double(t) * 1000 }
    private var hasCostData: Bool { rangeTotalUSD > 0 || rangeTotalCNY > 0 }

    private var costTimelinePoints: [WeeklyAreaChart.Point] { cachedCostTimelinePoints }
    private var topModelCosts: [(name: String, cents: Int)] { cachedTopModelCosts }

    private var balanceQuotas: [QuotaRecord] {
        return allQuotas.filter { $0.remaining != nil && Tool(rawValue: $0.toolRaw) != nil }
    }

    private func formatUSD(_ v: Double?) -> String { guard let v, v > 0 else { return "--" }; return String(format: "$%.2f", v) }
    private func formatCNY(_ v: Double?) -> String { guard let v, v > 0 else { return "--" }; return String(format: "¥%.2f", v) }

    // MARK: - Derived cache update

    /// Single-pass cache update. Runs once on appear and on range/data changes.
    /// All O(n) derived computations happen here; body and computed properties are O(1).
    private func updateDerivedCache() {
        let cutoff = cal.date(byAdding: .day, value: -range.days, to: Date())!
        let fs = allSessions.filter { $0.startedAt >= cutoff }
        let fStats = dailyStats.filter { $0.date >= cutoff }
        cachedFilteredSessions = fs
        cachedFilteredStats = fStats

        // Today / yesterday token counts (independent of range)
        let todayStart = cal.startOfDay(for: Date())
        let yesterdayStart = cal.date(byAdding: .day, value: -1, to: todayStart)!
        var todayTok = 0; var yesterdayTok = 0
        for s in allSessions {
            if s.startedAt >= todayStart { todayTok += s.totalTokens }
            else if s.startedAt >= yesterdayStart { yesterdayTok += s.totalTokens }
        }
        cachedTodayTokens = todayTok
        cachedYesterdayTokens = yesterdayTok

        // Active days & streaks over all-time dailyStats
        let activeDays = Set(dailyStats.filter { ($0.totalInputTokens + $0.totalOutputTokens) > 0 }.map { cal.startOfDay(for: $0.date) })
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
        for s in fs {
            let cost = s.estimatedCost
            if let v = cost.usd { usdMap[s.tool, default: 0] += v }
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

private struct DailyPoint { let date: Date; let tokens: Int }
