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

struct PersistentSyncErrorEvent: Codable, Identifiable, Sendable {
    let id: UUID
    let date: Date
    let scope: String
    let toolRaw: String?
    let message: String

    init(id: UUID = UUID(), date: Date, scope: String, toolRaw: String?, message: String) {
        self.id = id
        self.date = date
        self.scope = scope
        self.toolRaw = toolRaw
        self.message = message
    }

    var tool: Tool? { toolRaw.flatMap(Tool.init(rawValue:)) }

    var summary: String {
        let scopeLabel: String = switch scope {
        case "full-sync": "Full Sync"
        case "tool-sync": "Tool Sync"
        case "local-files": "Local Files"
        default: scope
        }
        let toolLabel = tool?.displayName ?? "Unknown Tool"
        return "\(scopeLabel) · \(toolLabel) · \(message)"
    }
}

/// In-memory ring buffer for runtime logs. Thread-safe via @MainActor.
@MainActor
@Observable
final class AppLogger {
    static let shared = AppLogger()

    private(set) var entries: [LogEntry] = []
    private(set) var latestPersistentSyncError: PersistentSyncErrorEvent?
    private let capacity = 500
    private let fileManager = FileManager.default
    private let persistentSyncErrorLogURL: URL

    private init() {
        persistentSyncErrorLogURL = Self.makePersistentSyncErrorLogURL()
        latestPersistentSyncError = Self.loadLatestPersistentSyncError(from: persistentSyncErrorLogURL)
    }

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

    func recordSyncError(scope: String, tool: Tool?, error: Error) {
        let event = PersistentSyncErrorEvent(
            date: Date(),
            scope: scope,
            toolRaw: tool?.rawValue,
            message: error.localizedDescription
        )
        latestPersistentSyncError = event
        appendPersistentSyncError(event)
    }

    func clear() { entries.removeAll() }

    private func appendPersistentSyncError(_ event: PersistentSyncErrorEvent) {
        do {
            try fileManager.createDirectory(
                at: persistentSyncErrorLogURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var data = try encoder.encode(event)
            data.append(0x0A)
            if fileManager.fileExists(atPath: persistentSyncErrorLogURL.path) {
                let handle = try FileHandle(forWritingTo: persistentSyncErrorLogURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: persistentSyncErrorLogURL, options: .atomic)
            }
        } catch {
            log(.error, "Failed to persist sync error log: \(error.localizedDescription)")
        }
    }

    private static func makePersistentSyncErrorLogURL() -> URL {
        let baseDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL.homeDirectory.appending(path: "Library/Application Support")
        return baseDir
            .appending(path: "OpenPulse")
            .appending(path: "logs")
            .appending(path: "sync-errors.jsonl")
    }

    private static func loadLatestPersistentSyncError(from url: URL) -> PersistentSyncErrorEvent? {
        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else { return nil }
        let lastLine = content
            .split(whereSeparator: \.isNewline)
            .last
            .map(String.init)
        guard let lastLine,
              let lineData = lastLine.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PersistentSyncErrorEvent.self, from: lineData)
    }
}
