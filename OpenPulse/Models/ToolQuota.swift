import Foundation

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
        let diff = resetAt.timeIntervalSinceNow
        guard diff > 0 else { return "Reset soon" }
        let days = Int(diff / 86400)
        let hours = Int((diff.truncatingRemainder(dividingBy: 86400)) / 3600)
        if days > 0 { return "\(days)d \(hours)h" }
        let minutes = Int((diff.truncatingRemainder(dividingBy: 3600)) / 60)
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

enum QuotaUnit: String, Sendable {
    case tokens
    case messages
    case requests
    case flowActions = "flow actions"
}
