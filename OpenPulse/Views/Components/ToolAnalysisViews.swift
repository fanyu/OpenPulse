import SwiftUI
import SwiftData

// MARK: - Activity heatmap

struct ActivityHeatmap: View {
    private let samples: [ActivityHeatmapSample]
    private let dataRevision: UInt64

    init(dailyStats: [DailyStatsRecord], dataRevision: UInt64 = 0) {
        self.samples = dailyStats.map {
            ActivityHeatmapSample(date: $0.date, tokens: $0.totalInputTokens + $0.totalOutputTokens)
        }
        self.dataRevision = dataRevision
    }

    init(samples: [ActivityHeatmapSample], dataRevision: UInt64 = 0) {
        self.samples = samples
        self.dataRevision = dataRevision
    }

    var body: some View {
        ActivityHeatmapContent(
            samples: samples,
            dataRevision: dataRevision
        )
    }
}

struct ActivityHeatmapSample: Equatable, Sendable {
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
    @State private var currentYear = Calendar.current.component(.year, from: Date())
    @State private var weeks: [ActivityHeatmapWeek] = []
    @State private var months: [ActivityHeatmapMonth] = []
    @State private var hoveredDay: ActivityHeatmapDay?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Button { selectedYear -= 1 } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 22, height: 22)
                            .contentShape(Circle())
                    }
                    .help("上一年")

                    Text(selectedYear.formatted(.number.grouping(.never)))
                        .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                        .frame(minWidth: 40)

                    Button { selectedYear += 1 } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 22, height: 22)
                            .contentShape(Circle())
                    }
                    .help("下一年")
                    .disabled(selectedYear >= currentYear)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)

                if let hoveredDay {
                    HStack(spacing: 5) {
                        Text(hoveredDay.date, format: .dateTime.year().month().day())
                            .foregroundStyle(.secondary)
                        Text("·").foregroundStyle(.tertiary)
                        Text("\(hoveredDay.tokens.compactTokenString) tokens")
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                    .font(.system(size: 11))
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .background(Color.primary.opacity(0.055), in: Capsule())
                    .transition(.opacity)
                } else {
                    Text("悬停方块查看当日用量")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .transition(.opacity)
                }

                Spacer(minLength: 8)
                HeatmapLegend()
            }
            .frame(height: 24)
            .animation(.easeOut(duration: 0.12), value: hoveredDay?.id)

            ActivityYearGrid(weeks: weeks, months: months, hoveredDay: $hoveredDay)
        }
        .onChange(of: samples, initial: true) { _, _ in rebuild(now: Date()) }
        .onChange(of: dataRevision) { _, _ in rebuild(now: Date()) }
        .onChange(of: selectedYear) { _, _ in
            hoveredDay = nil
            rebuild(now: Date())
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            let now = Date()
            currentYear = Calendar.current.component(.year, from: now)
            rebuild(now: now)
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            let now = Date()
            currentYear = Calendar.current.component(.year, from: now)
            rebuild(now: now)
        }
    }

    private func rebuild(now: Date) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        currentYear = calendar.component(.year, from: now)
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
    @Environment(\.colorScheme) private var colorScheme
    let weeks: [ActivityHeatmapWeek]
    let months: [ActivityHeatmapMonth]
    @Binding var hoveredDay: ActivityHeatmapDay?
    private let cellSize: CGFloat = 12
    private let spacing: CGFloat = 3

    private var gridWidth: CGFloat {
        max(0, CGFloat(weeks.count) * (cellSize + spacing) - spacing)
    }

    private var gridHeight: CGFloat {
        7 * cellSize + 6 * spacing
    }

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
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .offset(x: CGFloat(month.column) * (cellSize + spacing))
                        }
                    }
                    .frame(width: gridWidth, height: 15, alignment: .leading)

                    Canvas { context, _ in
                        let step = cellSize + spacing
                        let hoveredID = hoveredDay?.id
                        for (col, week) in weeks.enumerated() {
                            let x = CGFloat(col) * step
                            for (row, day) in week.days.enumerated() {
                                guard day.isInYear else { continue }
                                let rect = CGRect(x: x, y: CGFloat(row) * step, width: cellSize, height: cellSize)
                                let path = Path(roundedRect: rect, cornerRadius: 3, style: .continuous)
                                let fillColor: Color = day.isFuture
                                    ? Color.primary.opacity(colorScheme == .dark ? 0.035 : 0.025)
                                    : heatmapColor(fraction: day.fraction, colorScheme: colorScheme)
                                context.fill(path, with: .color(fillColor))
                                if hoveredID == day.id {
                                    context.stroke(
                                        path,
                                        with: .color(Color.primary.opacity(colorScheme == .dark ? 0.72 : 0.55)),
                                        lineWidth: 1.25
                                    )
                                }
                            }
                        }
                    }
                    .frame(width: gridWidth, height: gridHeight)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let step = cellSize + spacing
                            let col = Int(location.x / step)
                            let row = Int(location.y / step)
                            if col >= 0, col < weeks.count, row >= 0, row < weeks[col].days.count {
                                let candidate = weeks[col].days[row]
                                if candidate.isInYear && !candidate.isFuture {
                                    if hoveredDay?.id != candidate.id {
                                        hoveredDay = candidate
                                    }
                                    return
                                }
                            }
                            if hoveredDay != nil { hoveredDay = nil }
                        case .ended:
                            if hoveredDay != nil { hoveredDay = nil }
                        }
                    }
                    .accessibilityLabel("年度活跃热力图")
                }
            }
            .padding(.trailing, 18)
        }
    }
}

private struct HeatmapLegend: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 4) {
            Text("少")
            ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { level in
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(heatmapColor(fraction: level, colorScheme: colorScheme))
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

private func heatmapColor(fraction: Double, colorScheme: ColorScheme = .light) -> Color {
    if fraction <= 0 {
        return Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.055)
    }
    let clamped = min(1, max(0, fraction))
    let base = colorScheme == .dark
        ? Color(red: 0.22, green: 0.80, blue: 0.52)
        : Color(red: 0.12, green: 0.66, blue: 0.40)
    return base.opacity(0.22 + clamped * 0.76)
}

// MARK: - Copilot helper

func copilotAnalysisRemainingFraction(percentRemaining: Double?) -> Double? {
    percentRemaining.flatMap { $0.isFinite ? min(1, max(0, $0 / 100)) : nil }
}
