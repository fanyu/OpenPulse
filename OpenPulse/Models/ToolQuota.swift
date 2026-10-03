import Foundation

// MARK: - Reset date formatting

/// Format a reset date consistently across the app.
/// Uses the user's locale and retains the period in 12-hour time formats.
/// Different calendar days also include the month and day.
func resetDateString(for date: Date) -> String {
    if Calendar.current.isDateInToday(date) {
        return date.formatted(.dateTime.hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits))
    }
    return date.formatted(.dateTime.month().day().hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits))
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
        guard resetAt.timeIntervalSinceNow > 0 else { return String(localized: "即将重置") }
        return resetDateString(for: resetAt)
    }
}

enum QuotaUnit: String, Sendable {
    case tokens
    case messages
    case requests
    case flowActions = "flow actions"
}
