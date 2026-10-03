import SwiftUI
import Charts
import SwiftData

// MARK: - Activity heatmap

struct ActivityHeatmap: View {
    let dailyStats: [DailyStatsRecord]
    var dataRevision: UInt64 = 0

    var body: some View {
        ActivityHeatmapContent(
            samples: dailyStats.map {
                ActivityHeatmapSample(date: $0.date, tokens: $0.totalInputTokens + $0.totalOutputTokens)
            },
            dataRevision: dataRevision
        )
    }
}

struct ActivityHeatmapSample: Equatable {
    let date: Date
    let tokens: Int
}

func activityHeatmapDailyTotals(
    samples: [ActivityHeatmapSample],
    year: Int,
    now: Date,
    calendar: Calendar = .current
) -> [Date: Int] {
    var totals: [Date: Int] = [:]
    for sample in samples where calendar.component(.year, from: sample.date) == year && sample.date <= now {
        totals[calendar.startOfDay(for: sample.date), default: 0] += sample.tokens
    }
    return totals
}

/// A year can span 54 Sunday-aligned columns (for example, leap-year 2028).
func activityHeatmapColumnCount(year: Int, calendar: Calendar = .current) -> Int {
    guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
          let end = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)) else { return 0 }
    let leadingDays = calendar.component(.weekday, from: start) - 1
    let dayCount = calendar.dateComponents([.day], from: start, to: end).day ?? 0
    return (leadingDays + dayCount + 6) / 7
}

private struct ActivityHeatmapDay: Identifiable {
    let date: Date
    let tokens: Int
    let fraction: Double
    let isInYear: Bool
    let isFuture: Bool
    var id: Date { date }
}

private struct ActivityHeatmapWeek: Identifiable {
    let date: Date
    let days: [ActivityHeatmapDay]
    var id: Date { date }
}

private struct ActivityHeatmapMonth: Identifiable {
    let date: Date
    let column: Int
    var id: Date { date }
}

private struct ActivityHeatmapContent: View {
    let samples: [ActivityHeatmapSample]
    let dataRevision: UInt64
    @State private var selectedYear = Calendar.current.component(.year, from: Date())
    @State private var weeks: [ActivityHeatmapWeek] = []
    @State private var months: [ActivityHeatmapMonth] = []

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let currentYear = Calendar.current.component(.year, from: context.date)
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Button { selectedYear -= 1 } label: {
                        Image(systemName: "chevron.left")
                    }
                    .help("上一年")
                    Text(selectedYear.formatted(.number.grouping(.never)))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    Button { selectedYear += 1 } label: {
                        Image(systemName: "chevron.right")
                    }
                    .help("下一年")
                    .disabled(selectedYear >= currentYear)
                    Spacer()
                    HeatmapLegend()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                ActivityYearGrid(weeks: weeks, months: months)
            }
            .onChange(of: samples, initial: true) { _, _ in rebuild(now: context.date) }
            .onChange(of: dataRevision) { _, _ in rebuild(now: context.date) }
            .onChange(of: selectedYear) { _, _ in rebuild(now: context.date) }
            .onChange(of: Calendar.current.startOfDay(for: context.date)) { _, _ in rebuild(now: context.date) }
        }
    }

    private func rebuild(now: Date) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        guard let yearStart = calendar.date(from: DateComponents(year: selectedYear, month: 1, day: 1)),
              let gridStart = calendar.date(byAdding: .day, value: -(calendar.component(.weekday, from: yearStart) - 1), to: yearStart) else { return }
        let tokensByDay = activityHeatmapDailyTotals(samples: samples, year: selectedYear, now: now, calendar: calendar)
        let maximum = max(1, tokensByDay.values.max() ?? 0)
        let columnCount = activityHeatmapColumnCount(year: selectedYear, calendar: calendar)
        weeks = (0..<columnCount).compactMap { column in
            guard let weekStart = calendar.date(byAdding: .day, value: column * 7, to: gridStart) else { return nil }
            let days = (0..<7).compactMap { row -> ActivityHeatmapDay? in
                guard let date = calendar.date(byAdding: .day, value: row, to: weekStart) else { return nil }
                let tokens = tokensByDay[date] ?? 0
                return ActivityHeatmapDay(
                    date: date,
                    tokens: tokens,
                    fraction: Double(tokens) / Double(maximum),
                    isInYear: calendar.component(.year, from: date) == selectedYear,
                    isFuture: date > today
                )
            }
            return ActivityHeatmapWeek(date: weekStart, days: days)
        }
        months = (1...12).compactMap { month in
            guard let date = calendar.date(from: DateComponents(year: selectedYear, month: month, day: 1)) else { return nil }
            let offset = calendar.dateComponents([.day], from: gridStart, to: date).day ?? 0
            return ActivityHeatmapMonth(date: date, column: offset / 7)
        }
    }
}

private struct ActivityYearGrid: View {
    let weeks: [ActivityHeatmapWeek]
    let months: [ActivityHeatmapMonth]
    private let cellSize: CGFloat = 12
    private let spacing: CGFloat = 3

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: spacing) {
                    ForEach(0..<7, id: \.self) { row in
                        Text([1, 3, 5].contains(row) ? Calendar.current.shortWeekdaySymbols[row] : "")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .frame(height: cellSize)
                    }
                }
                VStack(alignment: .leading, spacing: 7) {
                    ZStack(alignment: .leading) {
                        ForEach(months) { month in
                            Text(month.date, format: .dateTime.month(.abbreviated))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .offset(x: CGFloat(month.column) * (cellSize + spacing))
                        }
                    }
                    .frame(width: max(0, CGFloat(weeks.count) * (cellSize + spacing) - spacing), height: 15, alignment: .leading)
                    HStack(alignment: .top, spacing: spacing) {
                        ForEach(weeks) { week in
                            VStack(spacing: spacing) {
                                ForEach(week.days) { day in
                                    ActivityDayCell(day: day, size: cellSize)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.trailing, 4)
        }
    }
}

private struct ActivityDayCell: View {
    let day: ActivityHeatmapDay
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(!day.isInYear ? .clear : day.isFuture ? Color.primary.opacity(0.025) : heatmapColor(fraction: day.fraction))
            .frame(width: size, height: size)
            .help(day.isInYear && !day.isFuture ? "\(day.date.formatted(date: .abbreviated, time: .omitted))：\(day.tokens.compactTokenString) tokens" : "")
            .accessibilityLabel(Text("\(day.date.formatted(date: .abbreviated, time: .omitted))：\(day.tokens.compactTokenString) tokens"))
            .accessibilityHidden(!day.isInYear || day.isFuture)
    }
}

private struct HeatmapLegend: View {
    var body: some View {
        HStack(spacing: 5) {
            Text("少")
            ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { level in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(heatmapColor(fraction: level))
                    .frame(width: 10, height: 10)
            }
            Text("多")
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Token 用量从少到多")
    }
}

private func heatmapColor(fraction: Double) -> Color {
    fraction <= 0 ? Color.primary.opacity(0.055) : Color.accentColor.opacity(0.18 + min(1, max(0, fraction)) * 0.72)
}

// MARK: - Today hourly heatmap

struct TodayHourlyHeatmap: View {
    let sessions: [SessionRecord]

    var body: some View {
        TodayHourlyHeatmapContent(samples: sessions.map {
            ActivityHeatmapSample(date: $0.startedAt, tokens: $0.totalTokens)
        })
    }
}

private struct TodayHourlyHeatmapContent: View {
    let samples: [ActivityHeatmapSample]
    @State private var tokensByHour: [Int: Int] = [:]
    @State private var maximum = 1

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: context.date)
            let currentHour = calendar.component(.hour, from: context.date)
            VStack(alignment: .leading, spacing: 12) {
                Text(today, format: .dateTime.month().day().weekday(.wide))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(0..<4, id: \.self) { row in
                        HStack(spacing: 5) {
                            Text(String(format: "%02d", row * 6))
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 20, alignment: .trailing)
                            ForEach(0..<6, id: \.self) { column in
                                HourlyActivityCell(
                                    hour: row * 6 + column,
                                    tokens: tokensByHour[row * 6 + column] ?? 0,
                                    maximum: maximum,
                                    currentHour: currentHour
                                )
                            }
                        }
                    }
                }
                HStack { Spacer(); HeatmapLegend() }
            }
            .onChange(of: samples, initial: true) { _, _ in rebuild(today: today) }
            .onChange(of: today) { _, _ in rebuild(today: today) }
        }
    }

    private func rebuild(today: Date) {
        let calendar = Calendar.current
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return }
        var totals: [Int: Int] = [:]
        for sample in samples where sample.date >= today && sample.date < tomorrow {
            totals[calendar.component(.hour, from: sample.date), default: 0] += sample.tokens
        }
        tokensByHour = totals
        maximum = max(1, totals.values.max() ?? 0)
    }
}

private struct HourlyActivityCell: View {
    let hour: Int
    let tokens: Int
    let maximum: Int
    let currentHour: Int

    var body: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(hour <= currentHour ? heatmapColor(fraction: Double(tokens) / Double(maximum)) : Color.primary.opacity(0.025))
            .frame(width: 22, height: 22)
            .overlay {
                if hour == currentHour {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.45), lineWidth: 1)
                }
            }
            .help(hour <= currentHour ? "\(String(format: "%02d:00", hour))–\(String(format: "%02d:00", hour + 1))：\(tokens.compactTokenString) tokens" : "")
            .accessibilityLabel(Text("\(hour) 时：\(tokens.compactTokenString) tokens"))
            .accessibilityHidden(hour > currentHour)
    }
}

// MARK: - Recent tool sessions

private struct AnalysisSessionSnapshot: Identifiable, Equatable {
    let id: UUID
    let tool: Tool
    let date: Date
    let tokens: Int
    let task: String
    let model: String
    let branch: String?

    init(_ record: SessionRecord) {
        id = record.id
        tool = record.tool
        date = record.startedAt
        tokens = record.totalTokens
        task = record.taskDescription
        model = record.model
        branch = record.gitBranch
    }
}

struct ToolAnalysisSessionView: View {
    let tool: Tool
    let sessions: [SessionRecord]
    let range: TrendsView.ChartRange

    var body: some View {
        RecentAnalysisSessions(tool: tool, samples: sessions.map(AnalysisSessionSnapshot.init), days: range.days)
    }
}

private struct RecentAnalysisSessions: View {
    let tool: Tool
    let samples: [AnalysisSessionSnapshot]
    let days: Int
    var showModel = true
    @State private var recent: [AnalysisSessionSnapshot] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if recent.isEmpty {
                Text("暂无记录")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ForEach(recent) { session in
                    AnalysisSessionRow(session: session, showModel: showModel)
                }
            }
        }
        .onChange(of: samples, initial: true) { _, _ in rebuild() }
        .onChange(of: days) { _, _ in rebuild() }
        .onChange(of: tool) { _, _ in rebuild() }
    }

    private func rebuild() {
        let now = Date()
        let calendar = Calendar.current
        let cutoff = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now)) ?? now
        recent = Array(samples.filter { $0.tool == tool && $0.date >= cutoff && $0.date <= now }
            .sorted { $0.date > $1.date }.prefix(5))
    }
}

private struct AnalysisSessionRow: View {
    let session: AnalysisSessionSnapshot
    let showModel: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ToolLogoImage(tool: session.tool, size: 22)
            VStack(alignment: .leading, spacing: 5) {
                Text(session.task.isEmpty ? String(localized: "Untitled session") : session.task)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                Text(session.date, format: .dateTime.month().day().hour().minute())
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 5) {
                Text(session.tokens.compactTokenString)
                    .font(.system(size: 12).monospacedDigit())
                if let branch = session.branch, !branch.isEmpty {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .font(.system(size: 10))
                        .lineLimit(1)
                } else if showModel && !session.model.isEmpty {
                    Text(session.model).font(.system(size: 10)).lineLimit(1)
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Antigravity analysis

struct AGAnalysisView: View {
    let sessions: [SessionRecord]
    let range: TrendsView.ChartRange

    var body: some View {
        let samples = sessions.map(AnalysisSessionSnapshot.init)
        VStack(alignment: .leading, spacing: 22) {
            AGRecentTaskChart(samples: samples)
            VStack(alignment: .leading, spacing: 12) {
                DashboardSectionTitle(title: String(localized: "近期任务记录"))
                RecentAnalysisSessions(tool: .antigravity, samples: samples, days: range.days, showModel: false)
            }
        }
    }
}

private struct AGTaskCount: Identifiable {
    let date: Date
    let count: Int
    var id: Date { date }
}

private struct AGRecentTaskChart: View {
    let samples: [AnalysisSessionSnapshot]
    @State private var points: [AGTaskCount] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DashboardSectionTitle(title: String(localized: "近 7 日任务数"))
            if points.allSatisfy({ $0.count == 0 }) {
                Text("暂无数据")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                Chart(points) { point in
                    BarMark(x: .value("日期", point.date, unit: .day), y: .value("任务数", point.count))
                        .foregroundStyle(Color.accentColor.opacity(0.7))
                        .cornerRadius(3)
                }
                .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.abbreviated)) } }
                .frame(height: 120)
            }
        }
        .onChange(of: samples, initial: true) { _, _ in rebuild() }
    }

    private func rebuild() {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let cutoff = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        var counts: [Date: Int] = [:]
        for sample in samples where sample.tool == .antigravity && sample.date >= cutoff && sample.date <= now {
            counts[calendar.startOfDay(for: sample.date), default: 0] += 1
        }
        points = (0..<7).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: cutoff) else { return nil }
            return AGTaskCount(date: date, count: counts[date] ?? 0)
        }
    }
}

// MARK: - Copilot analysis

struct CopilotAnalysisView: View {
    let snapshots: [String: CopilotSnapshot]?
    let resetAt: Date?

    var body: some View {
        CopilotAnalysisContent(
            entries: (snapshots ?? [:]).map { CopilotAnalysisEntry(id: $0.key, snapshot: $0.value) }.sorted { $0.id < $1.id },
            resetAt: resetAt
        )
    }
}

private struct CopilotAnalysisEntry: Identifiable {
    let id: String
    let snapshot: CopilotSnapshot
}

private struct CopilotAnalysisContent: View {
    let entries: [CopilotAnalysisEntry]
    let resetAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !entries.isEmpty {
                // Dictionary keys are stable even when the API omits quotaId.
                ForEach(entries) { entry in
                    CopilotSnapshotCard(snapshot: entry.snapshot, resetAt: resetAt)
                }
            } else {
                Text("未同步配额数据")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
        }
    }
}

struct CopilotSnapshotCard: View {
    let snapshot: CopilotSnapshot
    let resetAt: Date?

    private var remainingFraction: Double? {
        copilotAnalysisRemainingFraction(percentRemaining: snapshot.percentRemaining)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(snapshot.displayName)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if snapshot.unlimited == true {
                    Text("无限制")
                        .font(.system(size: 12, weight: .medium))
                } else if let remainingFraction {
                    Text("已用 \(Int(((1 - remainingFraction) * 100).rounded()))%")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            if snapshot.unlimited != true {
                QuotaProgressBar(fraction: remainingFraction, color: .accentColor, height: 4)
                if let resetAt {
                    Text("重置于 \(resetAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .dashboardSurface(cornerRadius: 12)
    }
}

func copilotAnalysisRemainingFraction(percentRemaining: Double?) -> Double? {
    percentRemaining.flatMap { $0.isFinite ? min(1, max(0, $0 / 100)) : nil }
}
