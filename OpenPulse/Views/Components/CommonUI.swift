import SwiftUI
import SwiftData
import Charts

// MARK: - Shared Progress Bar

struct QuotaProgressBar: View {
    let fraction: Double?
    let color: Color
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.06)).frame(height: height)
                if let f = fraction {
                    Capsule()
                        .fill(color.gradient)
                        .frame(width: geo.size.width * CGFloat(max(0, min(1, f))), height: height)
                        .shadow(color: color.opacity(0.25), radius: 2, y: 1)
                }
            }
        }
        .frame(height: height)
    }
}

// MARK: - Shared Chips

struct FilterChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(isSelected ? Color.accentColor : Color.primary.opacity(0.05))
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct ValueChip: View {
    let label: String
    let value: String
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10))
            }
            Text(label)
                .font(.caption)
                .bold()
            Text(value)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
    }
}

struct ProminentActionButtonStyle: ButtonStyle {
    @Environment(\.controlSize) private var controlSize
    var fillColor: Color = Color.primary.opacity(0.9)
    var pressedOpacity: Double = 0.88
    var fontSizeOverride: CGFloat? = nil
    var horizontalPaddingOverride: CGFloat? = nil
    var verticalPaddingOverride: CGFloat? = nil
    var cornerRadius: CGFloat = 10

    func makeBody(configuration: Configuration) -> some View {
        let metrics = metricsForControlSize()
        configuration.label
            .font(.system(size: fontSizeOverride ?? metrics.fontSize, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, horizontalPaddingOverride ?? metrics.horizontalPadding)
            .padding(.vertical, verticalPaddingOverride ?? metrics.verticalPadding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fillColor.opacity(configuration.isPressed ? pressedOpacity : 1))
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private func metricsForControlSize() -> (fontSize: CGFloat, horizontalPadding: CGFloat, verticalPadding: CGFloat) {
        switch controlSize {
        case .mini:
            (10, 8, 3)
        case .small:
            (11, 10, 5)
        case .large:
            (14, 16, 9)
        case .regular, .extraLarge:
            (12, 12, 6)
        @unknown default:
            (12, 12, 6)
        }
    }
}

// MARK: - Shared Sections

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
    }
}

// MARK: - Shared Stats

struct ModelLeaderboardRow: View {
    let rank: Int
    let model: String
    let tokens: Int
    let fraction: Double
    let color: Color
    var lastUsed: Date? = nil
    var sessionCount: Int = 0
    var favoriteProject: String = ""
    var avgTokens: Int = 0

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Text("\(rank)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(Color.primary.opacity(0.05), in: Circle())
                
                VStack(alignment: .leading, spacing: 1) {
                    Text(model)
                        .font(.system(size: 12, weight: .bold))
                        .lineLimit(1)
                    
                    HStack(spacing: 6) {
                        if !favoriteProject.isEmpty && favoriteProject != "—" {
                            Label(favoriteProject, systemImage: "folder")
                                .font(.system(size: 9))
                        }
                        Text("·").opacity(0.5)
                        Text("\(sessionCount) sess")
                            .font(.system(size: 9))
                        Text("·").opacity(0.5)
                        Text("\(avgTokens.compactTokenString)/sess")
                            .font(.system(size: 9))
                    }
                    .foregroundStyle(.tertiary)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 1) {
                    Text(tokens.compactTokenString)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                    if let lastUsed {
                        Text(lastUsed.formatted(.relative(presentation: .named)))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.1)).frame(height: 4)
                    Capsule().fill(color.gradient)
                        .frame(width: geo.size.width * CGFloat(fraction), height: 4)
                }
            }
            .frame(height: 4)
        }
        .padding(.vertical, 6)
    }
}

struct DistributionBarChart: View {
    struct Entry: Identifiable {
        let id = UUID()
        let label: String
        let value: Int
        let color: Color
        var displayValue: String? = nil  // if nil, falls back to compactTokenString
    }
    let data: [Entry]
    let total: Int

    var body: some View {
        VStack(spacing: 8) {
            ForEach(data) { entry in
                VStack(spacing: 4) {
                    HStack {
                        Text(entry.label)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        Text(entry.displayValue ?? entry.value.compactTokenString)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(entry.color.opacity(0.1)).frame(height: 4)
                            Capsule().fill(entry.color.gradient)
                                .frame(width: geo.size.width * CGFloat(Double(entry.value) / Double(max(1, total))), height: 4)
                        }
                    }
                    .frame(height: 4)
                }
            }
        }
    }
}

struct TokenRatioChart: View {
    let input: Int
    let output: Int
    var body: some View {
        let total = Double(input + output)
        let inputShare = total > 0 ? Double(input) / total : 0.5
        let outputShare = total > 0 ? Double(output) / total : 0.5
        
        ZStack {
            Chart {
                SectorMark(
                    angle: .value("Tokens", inputShare),
                    innerRadius: .ratio(0.65),
                    angularInset: 2
                )
                .foregroundStyle(Color.blue.gradient)
                
                SectorMark(
                    angle: .value("Tokens", outputShare),
                    innerRadius: .ratio(0.65),
                    angularInset: 2
                )
                .foregroundStyle(Color.green.gradient)
            }
            
            VStack(spacing: 0) {
                Text("\(Int(inputShare * 100))%")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                Text("Input")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct WeeklyAreaChart: View {
    struct Point: Identifiable {
        let id = UUID()
        let date: Date
        let value: Int
    }
    let data: [Point]
    let color: Color

    /// Number of days spanned by `data`, used to adapt the X-axis density and format.
    private var spanDays: Int {
        guard let first = data.first?.date, let last = data.last?.date else { return 7 }
        return max(1, Calendar.current.dateComponents([.day], from: first, to: last).day ?? 7)
    }

    var body: some View {
        Chart {
            ForEach(data) { pt in
                AreaMark(
                    x: .value("Date", pt.date, unit: .day),
                    y: .value("Tokens", pt.value)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [color.opacity(0.4), color.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.catmullRom)

                LineMark(
                    x: .value("Date", pt.date, unit: .day),
                    y: .value("Tokens", pt.value)
                )
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 3))
                .interpolationMethod(.catmullRom)

                PointMark(
                    x: .value("Date", pt.date, unit: .day),
                    y: .value("Tokens", pt.value)
                )
                .foregroundStyle(color)
                .symbolSize(30)
            }
        }
        .chartXAxis {
            if spanDays <= 7 {
                // 7 天：每天一个刻度，显示星期缩写（周一…周日）
                AxisMarks(values: .stride(by: .day, count: 1)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                }
            } else if spanDays <= 30 {
                // 30 天：每 5 天一个刻度，显示月/日
                AxisMarks(values: .stride(by: .day, count: 5)) { _ in
                    AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                }
            } else {
                // 90 天：每 2 周一个刻度，显示月/日
                AxisMarks(values: .stride(by: .day, count: 14)) { _ in
                    AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                }
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let v = value.as(Int.self) {
                        Text(v >= 1000 ? "\(v / 1000)k" : "\(v)")
                    }
                }
                AxisGridLine()
            }
        }
    }
}

struct StatCard: View {

    let title: String
    let value: String
    var subtitle: String? = nil
    var unit: String? = nil
    let icon: String
    let color: Color
    var delta: Int? = nil // Percentage change, nil to hide
    var isGlass: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(color)
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(value)
                            .font(.system(size: 28, weight: .bold, design: .monospaced))
                            .foregroundStyle(.primary)
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                        if let unit {
                            Text(unit)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            
            if let d = delta {
                Spacer(minLength: 0)
                deltaLabel(d)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isGlass ? Color.clear : Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
        .if(isGlass) { view in
            view.glassEffect(.regular, in: .rect(cornerRadius: 16))
        }
    }

    @ViewBuilder
    private func deltaLabel(_ d: Int) -> some View {
        let isPositive = d >= 0
        let arrow = isPositive ? "arrow.up" : "arrow.down"
        let clr: Color = isPositive ? .green : .red
        Label("\(abs(d))%", systemImage: arrow)
            .font(.caption2.bold())
            .foregroundStyle(clr)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(clr.opacity(0.1), in: .capsule)
    }
}

// MARK: - Shared Rows

enum QuotaRowStyle {
    case compact // For MenuBar
    case detailed // For Dashboard/Quota page
}

struct UnifiedQuotaRow: View {
    var style: QuotaRowStyle = .detailed
    var showUsedAtTop: Bool = false
    let title: String
    let fraction: Double?
    let primaryValue: String?
    let secondaryValue: String?
    let countdown: String?

    private var titleFont: Font { style == .compact ? .system(size: 10, weight: .semibold) : .system(size: 13, weight: .semibold) }
    private var valueFont: Font { style == .compact ? .system(size: 10, weight: .bold, design: .monospaced) : .system(size: 14, weight: .bold, design: .monospaced) }
    private var secondaryFont: Font { style == .compact ? .system(size: 9, weight: .medium) : .system(size: 11) }
    private var barHeight: CGFloat { style == .compact ? 4 : 8 }
    private var spacing: CGFloat { style == .compact ? 4 : 8 }

    var body: some View {
        VStack(spacing: spacing) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(titleFont)
                    .foregroundStyle(style == .compact ? .secondary : .primary)
                    .lineLimit(1)
                
                Spacer()
                
                HStack(spacing: 8) {
                    if showUsedAtTop, let s = secondaryValue {
                        Text(s).font(secondaryFont).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let p = primaryValue {
                        if p == "∞" {
                            Image(systemName: "infinity")
                                .font(style == .compact ? .system(size: 10, weight: .bold) : .system(size: 14, weight: .black))
                                .foregroundStyle(style == .compact ? .secondary : .primary)
                        } else {
                            Text(p).font(valueFont)
                                .foregroundStyle(fraction.map { $0 < 0.15 ? Color.red : (style == .compact ? .primary : .primary) } ?? .primary)
                        }
                    }
                }
            }

            QuotaProgressBar(fraction: fraction, color: quotaBarColor(fraction: fraction), height: barHeight)

            if (!showUsedAtTop && secondaryValue != nil) || countdown != nil {
                HStack(alignment: .firstTextBaseline) {
                    if !showUsedAtTop, let s = secondaryValue {
                        Text(s).font(secondaryFont).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if let c = countdown { 
                        ResetCountdownLabel(countdown: c)
                            .font(style == .compact ? nil : .system(size: 10, weight: .medium))
                    }
                }
            }
        }
    }
}

struct UnifiedSessionRow: View {
    let session: SessionRecord
    var showModel: Bool = true
    var isExpanded: Bool = false
    var onToggle: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ToolLogoImage(tool: session.tool, size: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.taskDescription.isEmpty ? "Untitled session" : session.taskDescription)
                        .font(.callout)
                        .lineLimit(isExpanded ? nil : 2)
                    
                    HStack(spacing: 6) {
                        Text(session.tool.displayName)
                            .font(.caption2)
                        Text("·").foregroundStyle(.tertiary)
                        Text(session.startedAt, style: .time)
                            .font(.caption2)
                        if isExpanded {
                            Text("·").foregroundStyle(.tertiary)
                            Text(session.startedAt, style: .date)
                                .font(.caption2)
                        }
                    }
                    .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(session.totalTokens.compactTokenString)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    
                    if let branch = session.gitBranch, !branch.isEmpty {
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    } else if showModel && !session.model.isEmpty {
                        Text(session.model)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }

            if isExpanded {
                Divider().opacity(0.3)
                VStack(alignment: .leading, spacing: 6) {
                    tokenDetailRow("Input", value: session.inputTokens)
                    tokenDetailRow("Output", value: session.outputTokens)
                    if session.cacheReadTokens > 0 {
                        tokenDetailRow("Cache Read", value: session.cacheReadTokens)
                    }
                    if !session.cwd.isEmpty {
                        Label(session.cwd, systemImage: "folder")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.leading, 40)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture {
            onToggle?()
        }
    }

    private func tokenDetailRow(_ label: String, value: Int) -> some View {
        HStack {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value.formatted(.number))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Card Container

struct DetailCardContainer<Content: View>: View {
    let tool: Tool
    let todayTokens: Int
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                ToolLogoImage(tool: tool, size: 24)
                Text(tool.displayName).font(.headline)
                Spacer()
                if todayTokens > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "bolt.fill").font(.system(size: 10))
                        Text("\(todayTokens.compactTokenString)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.05), in: Capsule())
                }
            }
            
            content()
        }
        .padding(20)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.black.opacity(0.03), radius: 8, y: 4)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }
}


struct TodayTokenBadge: View {
    let tokens: Int
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "bolt.fill")
            Text(tokens.compactTokenString)
        }
        .font(.system(size: 9, weight: .bold, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }
}

// MARK: - Shared Labels

struct ResetCountdownLabel: View {
    let countdown: String
    
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "clock.arrow.2.circlepath")
            if countdown.contains("h") || countdown.contains("m") || countdown.contains("d") {
                Text("\(countdown) 后重置")
            } else {
                Text("\(countdown) 重置")
            }
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

// MARK: - Shared Helpers

extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

/// 根据剩余比例返回进度条颜色
func quotaBarColor(fraction: Double?) -> Color {
    guard let f = fraction else { return .gray.opacity(0.3) }
    if f < 0.15 { return .red }
    if f < 0.40 { return .orange }
    return .green
}

/// 把 Date 转成倒计时字符串，如 "3h 12m"
func countdownString(to date: Date) -> String {
    let diff = date.timeIntervalSinceNow
    guard diff > 0 else { return "即将重置" }
    let totalMins = Int(diff / 60)
    let days = totalMins / (60 * 24)
    let hours = (totalMins % (60 * 24)) / 60
    let mins = totalMins % 60
    if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
    if hours > 0 { return mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h" }
    return "\(max(1, mins))m"
}

/// Static formatters — allocated once and reused across all renders.
private nonisolated(unsafe) let _iso8601FmtFrac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private nonisolated(unsafe) let _iso8601FmtStd = ISO8601DateFormatter()

/// Parse an ISO 8601 string, tolerating both fractional and non-fractional seconds.
func parseISO8601Flexible(_ raw: String) -> Date? {
    _iso8601FmtFrac.date(from: raw) ?? _iso8601FmtStd.date(from: raw)
}

extension Int {
    var compactTokenString: String {
        if self >= 1_000_000 { return String(format: "%.1fM", Double(self) / 1_000_000) }
        if self >= 1_000 { return String(format: "%.1fK", Double(self) / 1_000) }
        return "\(self)"
    }
}
