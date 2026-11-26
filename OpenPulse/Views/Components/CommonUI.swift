import SwiftUI

// MARK: - Dashboard presentation

struct DashboardSectionTitle: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(title))
                .font(.system(size: 15, weight: .semibold))
                .tracking(-0.2)
            if let subtitle {
                Text(LocalizedStringKey(subtitle))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct DashboardSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat
    let accent: Color?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
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

struct TelemetryHairline: View {
    @Environment(\.colorScheme) private var colorScheme
    var opacity: Double? = nil

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(opacity ?? (colorScheme == .dark ? 0.10 : 0.07)))
            .frame(height: 0.5)
    }
}

extension View {
    func dashboardSurface(cornerRadius: CGFloat = 16, accent: Color? = nil) -> some View {
        modifier(DashboardSurfaceModifier(cornerRadius: cornerRadius, accent: accent))
    }
}

// MARK: - Shared Progress Bar

struct QuotaProgressBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let fraction: Double?
    let color: Color
    var height: CGFloat = 4
    var showsGlow = false
    var trackColor: Color = Color.primary.opacity(0.06)

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(trackColor).frame(height: height)
                if let f = fraction {
                    Capsule()
                        .fill(color)
                        .frame(width: geo.size.width * CGFloat(max(0, min(1, f))), height: height)
                        .shadow(color: showsGlow ? color.opacity(0.25) : .clear, radius: showsGlow ? 2 : 0, y: showsGlow ? 1 : 0)
                        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 1), value: f)
                }
            }
        }
        .frame(height: height)
    }
}

// MARK: - Shared Badges

struct SubscriptionTag: View {
    let text: String
    var isPaid: Bool? = nil

    private var effectiveIsPaid: Bool {
        if let isPaid { return isPaid }
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower != "free" && !lower.contains("starter")
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: effectiveIsPaid ? .semibold : .medium))
            .foregroundStyle(effectiveIsPaid ? Color.primary : Color.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(
                effectiveIsPaid
                    ? Color.primary.opacity(0.08)
                    : Color.primary.opacity(0.04),
                in: Capsule()
            )
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
/// Countdown string — delegates to resetDateString for consistent output.
func countdownString(to date: Date) -> String {
    resetDateString(for: date)
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

func normalizedSubscriptionDisplayName(_ rawValue: String?) -> String? {
    guard let rawValue else { return nil }
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let normalized = trimmed
        .replacingOccurrences(of: "-", with: "_")
        .lowercased()

    switch normalized {
    case "pro", "chatgpt_pro", "claude_pro":
        return "Pro"
    case "plus", "chatgpt_plus":
        return "Plus"
    case "max", "chatgpt_max", "claude_max":
        return "Max"
    case "team", "business", "chatgpt_team", "claude_team":
        return "Team"
    case "free":
        return "Free"
    case "enterprise", "enterprise_plus":
        return "Enterprise"
    default:
        return nil
    }
}

func normalizedCopilotPlanDisplayName(_ rawValue: String?) -> String? {
    guard let rawValue else { return nil }
    let normalized = rawValue
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "-", with: "_")
        .lowercased()

    switch normalized {
    case "individual":
        return "Individual"
    case "business":
        return "Business"
    case "enterprise":
        return "Enterprise"
    default:
        return nil
    }
}
