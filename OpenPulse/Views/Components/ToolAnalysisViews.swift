import SwiftUI
import Charts
import SwiftData

// MARK: - ActivityHeatmap

struct ActivityHeatmap: View {
    let dailyStats: [DailyStatsRecord]
    @State private var selectedYear: Int = Calendar.current.component(.year, from: Date())
    @State private var cachedTokensByDay: [Date: Int] = [:]
    @State private var cachedMaxTokens: Int = 1

    private let cellSize: CGFloat = 11
    private let cellSpacing: CGFloat = 3
    private let dayLabelWidth: CGFloat = 26
    private let totalWeeks = 53
    private var calendar: Calendar { Calendar.current }
    private var today: Date { calendar.startOfDay(for: Date()) }
    private var currentYear: Int { calendar.component(.year, from: Date()) }

    // First Sunday on or before Jan 1 of selectedYear
    private var gridStart: Date {
        let jan1 = calendar.date(from: DateComponents(year: selectedYear, month: 1, day: 1))!
        let weekday = calendar.component(.weekday, from: jan1) // 1=Sun
        let offset = weekday - 1 // days back to reach Sunday
        return calendar.date(byAdding: .day, value: -offset, to: jan1)!
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Year navigation
            HStack(spacing: 6) {
                Button { selectedYear -= 1 } label: {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                Text(String(selectedYear))
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                Button { selectedYear += 1 } label: {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .disabled(selectedYear >= currentYear)
            }
            .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 0) {
                        Spacer().frame(width: dayLabelWidth + cellSpacing)
                        ZStack(alignment: .leading) {
                            Color.clear.frame(height: 14)
                            ForEach(monthLabels(), id: \.col) { item in
                                Text(item.label).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                                    .offset(x: CGFloat(item.col) * (cellSize + cellSpacing))
                            }
                        }
                    }
                    HStack(alignment: .top, spacing: cellSpacing) {
                        VStack(alignment: .leading, spacing: cellSpacing) {
                            ForEach(0..<7, id: \.self) { row in
                                Text(dayLabel(for: row)).font(.system(size: 8)).foregroundStyle(.tertiary).frame(height: cellSize)
                            }
                        }.frame(width: dayLabelWidth)
                        HStack(spacing: cellSpacing) {
                            ForEach(0..<totalWeeks, id: \.self) { col in
                                VStack(spacing: cellSpacing) {
                                    ForEach(0..<7, id: \.self) { row in
                                        cellView(col: col, row: row)
                                    }
                                }
                            }
                        }
                    }
                }.padding(.trailing, 4)
            }
            HStack(spacing: 6) {
                Spacer()
                Text("少").font(.system(size: 9)).foregroundStyle(.secondary)
                ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2).fill(heatColor(fraction: level)).frame(width: 9, height: 9)
                }
                Text("多").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .onAppear { rebuildTokensByDay() }
        .onChange(of: selectedYear) { _, _ in rebuildTokensByDay() }
        .onChange(of: dailyStats.count) { _, _ in rebuildTokensByDay() }
    }

    private func rebuildTokensByDay() {
        var map: [Date: Int] = [:]
        for stat in dailyStats where calendar.component(.year, from: stat.date) == selectedYear {
            let day = calendar.startOfDay(for: stat.date)
            map[day, default: 0] += stat.totalInputTokens + stat.totalOutputTokens
        }
        cachedTokensByDay = map
        cachedMaxTokens = map.values.max() ?? 1
    }

    @ViewBuilder
    private func cellView(col: Int, row: Int) -> some View {
        if let date = dateFor(col: col, row: row) {
            let inYear = calendar.component(.year, from: date) == selectedYear
            let isPast = date <= today
            if inYear && isPast {
                let tokens = cachedTokensByDay[date] ?? 0
                let fraction = cachedMaxTokens > 0 ? Double(tokens) / Double(cachedMaxTokens) : 0
                RoundedRectangle(cornerRadius: 2).fill(heatColor(fraction: fraction)).frame(width: cellSize, height: cellSize)
                    .help("\(date.formatted(date: .abbreviated, time: .omitted))：\(tokens.compactTokenString) tokens")
            } else if inYear {
                RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.03)).frame(width: cellSize, height: cellSize)
            } else {
                RoundedRectangle(cornerRadius: 2).fill(Color.clear).frame(width: cellSize, height: cellSize)
            }
        } else {
            RoundedRectangle(cornerRadius: 2).fill(Color.clear).frame(width: cellSize, height: cellSize)
        }
    }

    private func dateFor(col: Int, row: Int) -> Date? {
        calendar.date(byAdding: .day, value: col * 7 + row, to: gridStart)
    }
    private func monthLabels() -> [(col: Int, label: String)] {
        var seenMonths: [Int: Bool] = [:]
        var labels: [(col: Int, label: String)] = []
        let fmt = DateFormatter(); fmt.dateFormat = "MMM"
        for col in 0..<totalWeeks {
            if let date = dateFor(col: col, row: 0) {
                let month = calendar.component(.month, from: date)
                let year = calendar.component(.year, from: date)
                if seenMonths[month] == nil && year == selectedYear {
                    seenMonths[month] = true
                    labels.append((col: col, label: fmt.string(from: date)))
                }
            }
        }
        return labels
    }
    private func dayLabel(for row: Int) -> String {
        switch row { case 1: return "Mon"; case 3: return "Wed"; case 5: return "Fri"; default: return "" }
    }
    private func heatColor(fraction: Double) -> Color {
        if fraction <= 0 { return Color.primary.opacity(0.06) }
        return Color.green.opacity(0.15 + max(0, min(1, fraction)) * 0.85)
    }
}

// MARK: - TodayHourlyHeatmap

struct TodayHourlyHeatmap: View {
    let sessions: [SessionRecord]
    @State private var cachedTokensByHour: [Int: Int] = [:]
    @State private var cachedMaxHourTokens: Int = 1

    private let cellW: CGFloat = 20
    private let cellH: CGFloat = 20
    private let spacing: CGFloat = 4
    private var calendar: Calendar { Calendar.current }
    private var today: Date { calendar.startOfDay(for: Date()) }
    private var currentHour: Int { calendar.component(.hour, from: Date()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(today.formatted(.dateTime.month().day().weekday(.wide)))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            // 4 rows × 6 cols: 00-05, 06-11, 12-17, 18-23
            VStack(alignment: .leading, spacing: spacing) {
                ForEach(0..<4, id: \.self) { row in
                    HStack(spacing: spacing) {
                        Text(String(format: "%02d", row * 6))
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                            .frame(width: 16, alignment: .trailing)
                        ForEach(0..<6, id: \.self) { col in
                            hourCell(hour: row * 6 + col)
                        }
                    }
                }
            }

            HStack(spacing: 6) {
                Spacer()
                Text("少").font(.system(size: 9)).foregroundStyle(.secondary)
                ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2).fill(hourHeatColor(fraction: level)).frame(width: 9, height: 9)
                }
                Text("多").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .onAppear { rebuildTokensByHour() }
        .onChange(of: sessions.count) { _, _ in rebuildTokensByHour() }
    }

    private func rebuildTokensByHour() {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let tomorrow = cal.date(byAdding: .day, value: 1, to: todayStart)!
        var map: [Int: Int] = [:]
        for session in sessions where session.startedAt >= todayStart && session.startedAt < tomorrow {
            map[cal.component(.hour, from: session.startedAt), default: 0] += session.totalTokens
        }
        cachedTokensByHour = map
        cachedMaxHourTokens = map.values.max() ?? 1
    }

    @ViewBuilder
    private func hourCell(hour: Int) -> some View {
        let tokens = cachedTokensByHour[hour] ?? 0
        let fraction = cachedMaxHourTokens > 0 ? Double(tokens) / Double(cachedMaxHourTokens) : 0
        let isPast = hour <= currentHour

        RoundedRectangle(cornerRadius: 3)
            .fill(isPast ? hourHeatColor(fraction: fraction) : Color.primary.opacity(0.03))
            .frame(width: cellW, height: cellH)
            .overlay {
                if hour == currentHour {
                    RoundedRectangle(cornerRadius: 3).stroke(Color.accentColor.opacity(0.7), lineWidth: 1)
                }
            }
            .help(isPast ? "\(String(format: "%02d:00", hour))–\(String(format: "%02d:00", hour + 1))：\(tokens.compactTokenString) tokens" : "")
    }

    private func hourHeatColor(fraction: Double) -> Color {
        if fraction <= 0 { return Color.primary.opacity(0.06) }
        return Color.orange.opacity(0.15 + max(0, min(1, fraction)) * 0.85)
    }
}

// MARK: - Claude / Codex CLI Analysis

struct ToolAnalysisSessionView: View {
    let tool: Tool
    let sessions: [SessionRecord]
    let range: TrendsView.ChartRange
    private var cal: Calendar { Calendar.current }
    private var rangedSessions: [SessionRecord] {
        let cutoff = cal.date(byAdding: .day, value: -range.days, to: Date())!
        return sessions.filter { $0.tool == tool && $0.startedAt >= cutoff }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if rangedSessions.isEmpty {
                Text("暂无记录").font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ForEach(rangedSessions.prefix(5)) { session in
                    UnifiedSessionRow(session: session)
                }
            }
        }
    }
}

// MARK: - Antigravity Analysis

struct AGAnalysisView: View {
    let sessions: [SessionRecord]
    let range: TrendsView.ChartRange
    private var cal: Calendar { Calendar.current }
    private var rangedSessions: [SessionRecord] {
        let cutoff = cal.date(byAdding: .day, value: -range.days, to: Date())!
        return sessions.filter { $0.tool == .antigravity && $0.startedAt >= cutoff }
    }
    private var last7DayCounts: [(date: Date, count: Int)] {
        let cutoff = cal.date(byAdding: .day, value: -7, to: Date())!
        let relevant = sessions.filter { $0.tool == .antigravity && $0.startedAt >= cutoff }
        var map: [Date: Int] = [:]
        for s in relevant { map[cal.startOfDay(for: s.startedAt), default: 0] += 1 }
        return (0..<7).map { offset in
            let d = cal.date(byAdding: .day, value: -6 + offset, to: cal.startOfDay(for: Date()))!
            return (date: d, count: map[d] ?? 0)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("近 7 日任务数").font(.subheadline.bold())
                if last7DayCounts.allSatisfy({ $0.count == 0 }) {
                    Text("暂无数据").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    Chart(last7DayCounts, id: \.date) { pt in
                        BarMark(x: .value("日期", pt.date, unit: .day), y: .value("任务数", pt.count))
                            .foregroundStyle(Color("AntigravityPurple").gradient).cornerRadius(4)
                    }
                    .frame(height: 100)
                }
            }
            .padding().background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 10) {
                Text("近期任务记录").font(.subheadline.bold())
                if rangedSessions.isEmpty {
                    Text("暂无记录").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(rangedSessions.prefix(5)) { session in
                        UnifiedSessionRow(session: session, showModel: false)
                    }
                }
            }
        }
    }
}

// MARK: - Copilot Analysis

struct CopilotAnalysisView: View {
    let snapshots: [String: CopilotSnapshot]?
    let resetAt: Date?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let snapshots, !snapshots.isEmpty {
                ForEach(Array(snapshots.values.sorted { ($0.quotaId ?? "") < ($1.quotaId ?? "") }), id: \.quotaId) { snap in
                    CopilotSnapshotCard(snapshot: snap, resetAt: resetAt)
                }
            } else {
                Text("未同步配额数据").font(.subheadline).foregroundStyle(.secondary).padding().frame(maxWidth: .infinity).background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}

struct CopilotSnapshotCard: View {
    let snapshot: CopilotSnapshot
    let resetAt: Date?
    private var fractionUsed: Double {
        if let pct = snapshot.percentRemaining { return max(0, 1.0 - pct / 100.0) }
        return 0.0
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(snapshot.displayName).font(.subheadline.bold())
                Spacer()
                if snapshot.unlimited == true {
                    Text("无限制").font(.caption.bold()).foregroundStyle(.green)
                } else {
                    Text("已用 \(Int(fractionUsed * 100))%").font(.caption.monospacedDigit().bold())
                }
            }
            if snapshot.unlimited != true {
                QuotaProgressBar(fraction: 1.0 - fractionUsed, color: .blue, height: 6)
                if let reset = resetAt {
                    Text("重置于 \(reset.formatted(.relative(presentation: .named)))").font(.system(size: 8)).foregroundStyle(.tertiary)
                }
            }
        }
        .padding().background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
    }
}
