import Foundation

enum LogLevel: String, CaseIterable {
    case info    = "INFO"
    case warning = "WARNING"
    case error   = "ERROR"

    var symbol: String {
        switch self {
        case .info:    "ℹ"
        case .warning: "⚠"
        case .error:   "✕"
        }
    }
}

struct LogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let level: LogLevel
    let message: String
}

/// In-memory ring buffer for runtime logs. Thread-safe via @MainActor.
@MainActor
@Observable
final class AppLogger {
    static let shared = AppLogger()

    private(set) var entries: [LogEntry] = []
    private let capacity = 500

    func log(_ level: LogLevel, _ message: String) {
        let entry = LogEntry(date: Date(), level: level, message: message)
        if entries.count >= capacity { entries.removeFirst() }
        entries.append(entry)
        #if DEBUG
        print("[\(level.rawValue)] \(message)")
        #endif
    }

    func info(_ message: String)    { log(.info, message) }
    func warning(_ message: String) { log(.warning, message) }
    func error(_ message: String)   { log(.error, message) }

    func clear() { entries.removeAll() }
}
