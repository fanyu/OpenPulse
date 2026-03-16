import Foundation

/// Aggregated statistics for a single tool on a single day.
struct DailyStats: Sendable {
    let date: Date
    let tool: Tool
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let totalCacheReadTokens: Int
    let sessionCount: Int
    let estimatedOutputWords: Int

    var totalTokens: Int { totalInputTokens + totalOutputTokens }

    init(
        date: Date,
        tool: Tool,
        totalInputTokens: Int = 0,
        totalOutputTokens: Int = 0,
        totalCacheReadTokens: Int = 0,
        sessionCount: Int = 0
    ) {
        self.date = date
        self.tool = tool
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.totalCacheReadTokens = totalCacheReadTokens
        self.sessionCount = sessionCount
        // Approximate: 1 output token ≈ 0.75 words
        self.estimatedOutputWords = Int(Double(totalOutputTokens) * 0.75)
    }
}

/// Aggregated daily stats across all tools.
struct AllToolsDailyStats: Sendable {
    let date: Date
    let statsByTool: [Tool: DailyStats]

    var totalTokens: Int { statsByTool.values.reduce(0) { $0 + $1.totalTokens } }
    var totalOutputTokens: Int { statsByTool.values.reduce(0) { $0 + $1.totalOutputTokens } }
    var totalSessions: Int { statsByTool.values.reduce(0) { $0 + $1.sessionCount } }
    var estimatedOutputWords: Int { statsByTool.values.reduce(0) { $0 + $1.estimatedOutputWords } }
}
