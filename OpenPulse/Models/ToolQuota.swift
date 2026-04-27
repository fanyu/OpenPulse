import Foundation

// MARK: - Reset date formatting

/// Format a reset date consistently across the app.
/// Same calendar day → "HH:mm"  (e.g. "14:30")
/// Different day     → "M月d日 HH:mm"  (e.g. "5月3日 14:30")
func resetDateString(for date: Date) -> String {
    if Calendar.current.isDateInToday(date) {
        return date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute())
    }
    return date.formatted(.dateTime.month().day().hour(.twoDigits(amPM: .omitted)).minute())
}

/// Quota / remaining allowance for a tool.
struct ToolQuota: Identifiable, Sendable {
    let id: String
    let tool: Tool
    let accountKey: String?
    let accountLabel: String?
    let remaining: Int?
    let total: Int?
    let unit: QuotaUnit
    let resetAt: Date?
    let updatedAt: Date
    /// Raw decoded API response, for richer display (e.g. ClaudeUsageResponse, CopilotUserResponse).
    let raw: (any Sendable)?

    var fraction: Double? {
        guard let remaining, let total, total > 0 else { return nil }
        return Double(remaining) / Double(total)
    }

    var resetCountdown: String? {
        guard let resetAt else { return nil }
        guard resetAt.timeIntervalSinceNow > 0 else { return "即将重置" }
        return resetDateString(for: resetAt)
    }
}

enum QuotaUnit: String, Sendable {
    case tokens
    case messages
    case requests
    case flowActions = "flow actions"
}
