import Foundation

/// A parsed AI coding session from any supported tool.
struct ToolSession: Identifiable, Sendable {
    let id: UUID
    let tool: Tool
    let startedAt: Date
    let endedAt: Date?
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let taskDescription: String
    let model: String
    let cwd: String
    let gitBranch: String?
    let taskItems: [TaskItem]

    var totalTokens: Int { inputTokens + outputTokens }
    var duration: TimeInterval? { endedAt.map { $0.timeIntervalSince(startedAt) } }

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
        gitBranch: String? = nil,
        taskItems: [TaskItem] = []
    ) {
        self.id = id
        self.tool = tool
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
        self.taskItems = taskItems
    }
}
