import Foundation
import SwiftData

@Model
final class DailyStatsRecord {
    #Index<DailyStatsRecord>([\.date], [\.toolRaw], [\.date, \.toolRaw])
    var date: Date
    var toolRaw: String
    var totalInputTokens: Int
    var totalOutputTokens: Int
    var totalCacheReadTokens: Int
    var sessionCount: Int

    init(date: Date, tool: Tool, totalInputTokens: Int = 0, totalOutputTokens: Int = 0, totalCacheReadTokens: Int = 0, sessionCount: Int = 0) {
        self.date = date
        self.toolRaw = tool.rawValue
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.totalCacheReadTokens = totalCacheReadTokens
        self.sessionCount = sessionCount
    }

    var tool: Tool { Tool(rawValue: toolRaw) ?? .claudeCode }
}
