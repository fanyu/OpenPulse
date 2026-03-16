import Foundation

/// A single task item extracted from a session (e.g., Antigravity brain/ task.md).
struct TaskItem: Identifiable, Sendable {
    let id: UUID
    let title: String
    let isCompleted: Bool
    let source: Tool

    init(id: UUID = UUID(), title: String, isCompleted: Bool, source: Tool) {
        self.id = id
        self.title = title
        self.isCompleted = isCompleted
        self.source = source
    }
}
