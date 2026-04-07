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
    let source: String?
    let path: String?
    let details: String?
    let message: String

    init(
        id: UUID = UUID(),
        date: Date,
        scope: String,
        toolRaw: String?,
        source: String? = nil,
        path: String? = nil,
        details: String? = nil,
        message: String
    ) {
        self.id = id
        self.date = date
        self.scope = scope
        self.toolRaw = toolRaw
        self.source = source
        self.path = path
        self.details = details
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
        let sourceLabel = source ?? "unknown-source"
        let pathLabel = path.flatMap { URL(filePath: $0).lastPathComponent }
        let context = [sourceLabel, pathLabel].compactMap { $0 }.joined(separator: " · ")
        return "\(scopeLabel) · \(toolLabel) · \(context) · \(message)"
    }
}

struct PersistentDiagnosticEvent: Codable, Identifiable, Sendable {
    let id: UUID
    let date: Date
    let levelRaw: String
    let scope: String
    let message: String

    init(id: UUID = UUID(), date: Date, level: LogLevel, scope: String, message: String) {
        self.id = id
        self.date = date
        self.levelRaw = level.rawValue
        self.scope = scope
        self.message = message
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
    private let persistentDiagnosticLogURL: URL

    private init() {
        persistentSyncErrorLogURL = Self.makePersistentSyncErrorLogURL()
        persistentDiagnosticLogURL = Self.makePersistentDiagnosticLogURL()
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

    func recordSyncError(
        scope: String,
        tool: Tool?,
        error: Error,
        source: String? = nil,
        path: String? = nil,
        details: String? = nil
    ) {
        let event = PersistentSyncErrorEvent(
            date: Date(),
            scope: scope,
            toolRaw: tool?.rawValue,
            source: source,
            path: path,
            details: details,
            message: error.localizedDescription
        )
        latestPersistentSyncError = event
        appendPersistentSyncError(event)
    }

    func recordDiagnostic(level: LogLevel = .info, scope: String, message: String) {
        appendPersistentDiagnostic(
            PersistentDiagnosticEvent(date: Date(), level: level, scope: scope, message: message)
        )
    }

    func clear() { entries.removeAll() }

    private func appendPersistentSyncError(_ event: PersistentSyncErrorEvent) {
        appendJSONLine(event, to: persistentSyncErrorLogURL, failureScope: "sync error")
    }

    private func appendPersistentDiagnostic(_ event: PersistentDiagnosticEvent) {
        appendJSONLine(event, to: persistentDiagnosticLogURL, failureScope: "diagnostic")
    }

    private func appendJSONLine<T: Encodable>(_ value: T, to url: URL, failureScope: String) {
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var data = try encoder.encode(value)
            data.append(0x0A)
            if fileManager.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url, options: .atomic)
            }
        } catch {
            log(.error, "Failed to persist \(failureScope) log: \(error.localizedDescription)")
        }
    }

    private static func makePersistentSyncErrorLogURL() -> URL {
        makeLogsDirectoryURL().appending(path: "sync-errors.jsonl")
    }

    private static func makePersistentDiagnosticLogURL() -> URL {
        makeLogsDirectoryURL().appending(path: "diagnostics.jsonl")
    }

    private static func makeLogsDirectoryURL() -> URL {
        let baseDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL.homeDirectory.appending(path: "Library/Application Support")
        return baseDir
            .appending(path: "OpenPulse")
            .appending(path: "logs")
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
