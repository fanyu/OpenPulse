import SwiftUI
import SwiftData
import Charts

struct CompareView: View {
    @Query(sort: \DailyStatsRecord.date) private var dailyStats: [DailyStatsRecord]

    enum DateRange: String, CaseIterable {
        case week = "7 Days"
        case month = "30 Days"
        case quarter = "90 Days"

        var days: Int {
            switch self { case .week: 7; case .month: 30; case .quarter: 90 }
        }

        var localizedTitle: LocalizedStringKey {
            switch self { case .week: "7 Days"; case .month: "30 Days"; case .quarter: "90 Days" }
        }
    }

    var body: some View {
        ComparisonBrowser(
            samples: dailyStats.map { ComparisonDailySample(date: $0.date, tool: $0.tool, tokens: $0.totalInputTokens + $0.totalOutputTokens) },
            dailyStats: dailyStats
        )
        .navigationTitle("Compare")
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct ComparisonDailySample: Equatable {
    let date: Date
    let tool: Tool
    let tokens: Int
}

private struct ComparisonTokenPoint: Identifiable {
    let date: Date
    let tool: Tool
    let tokens: Int
    var id: String { "\(tool.rawValue)-\(date.timeIntervalSinceReferenceDate)" }
}

private struct ComparisonToolTotal: Identifiable {
    let tool: Tool
    let tokens: Int
    var id: Tool { tool }
}

private struct ComparisonBrowser: View {
    let samples: [ComparisonDailySample]
    let dailyStats: [DailyStatsRecord]
    @State private var range: CompareView.DateRange = .week
    @State private var points: [ComparisonTokenPoint] = []
    @State private var totals: [ComparisonToolTotal] = []
    @State private var totalTokens = 0
    @State private var activeDays = 0

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ComparisonHeader(range: $range, isWide: geometry.size.width >= 740)
                    ComparisonSummary(tokens: totalTokens, days: activeDays, tools: totals.filter { $0.tokens > 0 }.count)
                    ComparisonTimeline(points: points, range: range)
                    ComparisonToolShare(totals: totals, total: totalTokens)
                    VStack(alignment: .leading, spacing: 18) {
                        DashboardSectionTitle(title: String(localized: "Activity Heatmap"))
                        ActivityHeatmap(dailyStats: dailyStats)
                    }
                    .padding(20)
                    .dashboardSurface()
                }
                .frame(maxWidth: 1360, alignment: .leading)
                .padding(geometry.size.width < 760 ? 20 : 28)
                .frame(maxWidth: .infinity)
            }
        }
        .onChange(of: samples, initial: true) { _, _ in rebuild() }
        .onChange(of: range) { _, _ in rebuild() }
    }

    private func rebuild() {
        let now = Date()
        let calendar = Calendar.current
        let cutoff = calendar.date(byAdding: .day, value: -(range.days - 1), to: calendar.startOfDay(for: now)) ?? now
        var byDay: [Date: [Tool: Int]] = [:]
        var byTool: [Tool: Int] = [:]
        var days = Set<Date>()
        for sample in samples where sample.date >= cutoff && sample.date <= now {
            let day = calendar.startOfDay(for: sample.date)
            byDay[day, default: [:]][sample.tool, default: 0] += sample.tokens
            byTool[sample.tool, default: 0] += sample.tokens
            if sample.tokens > 0 { days.insert(day) }
        }
        points = byDay.keys.sorted().flatMap { date in
            Tool.allCases.compactMap { tool in
                byDay[date]?[tool].map { ComparisonTokenPoint(date: date, tool: tool, tokens: $0) }
            }
        }
        totals = Tool.allCases.map { ComparisonToolTotal(tool: $0, tokens: byTool[$0] ?? 0) }
            .sorted { $0.tokens == $1.tokens ? $0.tool.rawValue < $1.tool.rawValue : $0.tokens > $1.tokens }
        totalTokens = byTool.values.reduce(0, +)
        activeDays = days.count
    }
}

private struct ComparisonHeader: View {
    @Binding var range: CompareView.DateRange
    let isWide: Bool

    var body: some View {
        let layout = isWide ? AnyLayout(HStackLayout(alignment: .center, spacing: 20)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
        layout {
            VStack(alignment: .leading, spacing: 6) {
                Text("Compare")
                    .font(.system(size: 28, weight: .semibold))
                    .tracking(-0.6)
                Text("Token Usage Over Time")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            if isWide { Spacer() }
            Picker("Range", selection: $range) {
                ForEach(CompareView.DateRange.allCases, id: \.self) { range in
                    Text(range.localizedTitle).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: isWide ? 280 : nil)
        }
    }
}

private struct ComparisonSummary: View {
    let tokens: Int
    let days: Int
    let tools: Int

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            DashboardMetric(title: "累计 Token", value: tokens.compactTokenString)
            DashboardMetric(title: "活跃天数", value: days.formatted())
            DashboardMetric(title: "活跃工具", value: tools.formatted())
        }
        .padding(20)
        .dashboardSurface()
    }
}

private struct ComparisonTimeline: View {
    let points: [ComparisonTokenPoint]
    let range: CompareView.DateRange

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            DashboardSectionTitle(title: String(localized: "Token Usage Over Time"))
            if points.isEmpty || points.allSatisfy({ $0.tokens == 0 }) {
                ContentUnavailableView("暂无数据", systemImage: "chart.xyaxis.line")
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                Chart(points) { point in
                    LineMark(
                        x: .value("Date", point.date, unit: .day),
                        y: .value("Tokens", point.tokens)
                    )
                    .foregroundStyle(by: .value("Tool", point.tool.displayName))
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
                .chartForegroundStyleScale(domain: Tool.allCases.map(\.displayName), range: Tool.allCases.map { Color($0.accentColorName) })
                .chartXAxis {
                    AxisMarks(values: .stride(by: range == .week ? .day : .weekOfYear)) { _ in
                        AxisValueLabel(format: range == .week ? .dateTime.weekday(.abbreviated) : .dateTime.month().day())
                    }
                }
                .chartYAxis { AxisMarks { _ in AxisGridLine(); AxisValueLabel() } }
                .frame(height: 240)
            }
        }
        .padding(20)
        .dashboardSurface()
    }
}

private struct ComparisonToolShare: View {
    let totals: [ComparisonToolTotal]
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            DashboardSectionTitle(title: String(localized: "Usage by Tool"))
            if total <= 0 {
                Text("暂无数据")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                HStack(spacing: 28) {
                    Chart(totals) { item in
                        SectorMark(angle: .value("Tokens", item.tokens), innerRadius: .ratio(0.68), angularInset: 1.5)
                            .foregroundStyle(Color(item.tool.accentColorName))
                    }
                    .chartLegend(.hidden)
                    .frame(width: 150, height: 150)
                    VStack(spacing: 14) {
                        ForEach(totals) { item in
                            ComparisonToolRow(item: item, total: total)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(20)
        .dashboardSurface()
    }
}

private struct ComparisonToolRow: View {
    let item: ComparisonToolTotal
    let total: Int

    var body: some View {
        HStack(spacing: 10) {
            ToolLogoImage(tool: item.tool, size: 20)
            Text(item.tool.displayName)
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Text(item.tokens.compactTokenString)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
            Text(total > 0 ? "\(Int((Double(item.tokens) / Double(total) * 100).rounded()))%" : "—")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
    }
}
