import Foundation
import SwiftData

@Model
final class QuotaRecord {
    #Index<QuotaRecord>([\.toolRaw], [\.toolRaw, \.accountKey])
    var toolRaw: String
    var accountKey: String?
    var accountLabel: String?
    var remaining: Int?
    var total: Int?
    var unitRaw: String
    var resetAt: Date?
    var updatedAt: Date

    init(
        tool: Tool,
        accountKey: String? = nil,
        accountLabel: String? = nil,
        remaining: Int? = nil,
        total: Int? = nil,
        unit: QuotaUnit = .tokens,
        resetAt: Date? = nil
    ) {
        self.toolRaw = tool.rawValue
        self.accountKey = accountKey
        self.accountLabel = accountLabel
        self.remaining = remaining
        self.total = total
        self.unitRaw = unit.rawValue
        self.resetAt = resetAt
        self.updatedAt = Date()
    }

    var tool: Tool { Tool(rawValue: toolRaw) ?? .claudeCode }
    var unit: QuotaUnit { QuotaUnit(rawValue: unitRaw) ?? .tokens }

    func toModel() -> ToolQuota {
        ToolQuota(
            id: [toolRaw, accountKey].compactMap { $0 }.joined(separator: ":"),
            tool: tool,
            accountKey: accountKey,
            accountLabel: accountLabel,
            remaining: remaining,
            total: total,
            unit: unit,
            resetAt: resetAt,
            updatedAt: updatedAt,
            raw: nil
        )
    }
}
