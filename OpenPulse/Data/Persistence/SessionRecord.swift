import Foundation
import SwiftData

@Model
final class SessionRecord {
    #Index<SessionRecord>([\.toolRaw], [\.startedAt], [\.toolRaw, \.startedAt])
    @Attribute(.unique) var id: UUID
    var toolRaw: String
    var startedAt: Date
    var endedAt: Date?
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheWriteTokens: Int
    var taskDescription: String
    var model: String
    var cwd: String
    var gitBranch: String?

    init(
        id: UUID = UUID(),
        tool: Tool,
        startedAt: Date,
        endedAt: Date? = nil,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        taskDescription: String = "",
        model: String = "",
        cwd: String = "",
        gitBranch: String? = nil
    ) {
        self.id = id
        self.toolRaw = tool.rawValue
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.taskDescription = taskDescription
        self.model = model
        self.cwd = cwd
        self.gitBranch = gitBranch
    }

    var tool: Tool { Tool(rawValue: toolRaw) ?? .claudeCode }
    var totalTokens: Int { inputTokens + outputTokens }
}
