import Foundation
import SQLite

/// Parses OpenAI Codex CLI data from ~/.codex/
/// - Token usage: state_5.sqlite threads table (created_at is Unix seconds)
/// - Rate limits: latest token_count event from session JSONL files
actor CodexParser {
    private enum ParserError: LocalizedError {
        case transientDatabaseUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .transientDatabaseUnavailable(let message):
                message
            }
        }
    }

    private let codexDir: URL
    /// In-memory cache of threadId → model name built by scanning JSONL files.
    /// Rebuilt only on full scans (since == nil) or when empty, so incremental syncs
    /// avoid re-enumerating potentially thousands of archived JSONL files every 5 min.
    private var cachedModelMap: [String: String]?

    init(codexDir: URL = .homeDirectory.appending(path: ".codex")) {
        self.codexDir = codexDir
    }

    private var dbPath: String { codexDir.appending(path: "state_5.sqlite").path }
    private var sessionsDir: URL { codexDir.appending(path: "sessions") }
    private var archivedDir: URL { codexDir.appending(path: "archived_sessions") }

    // MARK: - Sessions from SQLite

    func parseSessions(since date: Date? = nil) async throws -> [ToolSession] {
        guard FileManager.default.fileExists(atPath: dbPath) else { return [] }
        do {
            // CANTOPEN (14) can occur transiently when Codex is checkpointing/vacuuming.
            // Treat as "no data this cycle" rather than a hard error.
            guard let db = try? Connection(.uri(dbPath, parameters: [.mode(.readOnly)])) else { return [] }

            let threads = Table("threads")
            let idCol = Expression<String>("id")
            let titleCol = Expression<String?>("title")
            let firstMsgCol = Expression<String?>("first_user_message")
            let tokensCol = Expression<Int64?>("tokens_used")
            let createdCol = Expression<Int64>("created_at")   // UNIX seconds
            let cwdCol = Expression<String?>("cwd")
            let branchCol = Expression<String?>("git_branch")
            let modelProviderCol = Expression<String?>("model_provider")
            let archivedCol = Expression<Bool?>("archived")

            // Build threadId → model map from JSONL files (real model names).
            // Full scan (date == nil) always rebuilds; incremental syncs reuse the cache.
            if cachedModelMap == nil || date == nil {
                cachedModelMap = buildModelMap()
            }
            let modelMap = cachedModelMap ?? [:]

            var sessions: [ToolSession] = []
            for row in try db.prepare(threads) {
                // created_at is Unix SECONDS (not ms)
                let startDate = Date(timeIntervalSince1970: TimeInterval(row[createdCol]))
                if let cutoff = date, startDate < cutoff { continue }
                if row[archivedCol] == true { continue }

                let tokens = Int(row[tokensCol] ?? 0)
                let description = row[firstMsgCol] ?? row[titleCol] ?? ""
                let threadId = row[idCol]
                // Prefer real model name from JSONL; fall back to model_provider
                let modelName = modelMap[threadId] ?? row[modelProviderCol] ?? "openai"

                sessions.append(ToolSession(
                    id: UUID(uuidString: threadId) ?? UUID(),
                    tool: .codex,
                    startedAt: startDate,
                    inputTokens: tokens * 4 / 5,   // rough split: ~80% input, ~20% output
                    outputTokens: tokens / 5,
                    taskDescription: String(description.prefix(300)),
                    model: modelName,
                    cwd: row[cwdCol] ?? "",
                    gitBranch: row[branchCol]
                ))
            }
            return sessions.sorted { $0.startedAt < $1.startedAt }
        } catch {
            if isTransientDatabaseError(error) {
                await AppLogger.shared.warning("Codex DB unavailable this cycle: \(error.localizedDescription)")
                return []
            }
            throw error
        }
    }

    /// Scans all JSONL rollout files and extracts threadId → model from turn_context events.
    /// JSONL filename format: rollout-<date>T<time>-<threadId>.jsonl
    private func buildModelMap() -> [String: String] {
        var map: [String: String] = [:]
        let fm = FileManager.default
        let allDirs = [sessionsDir, archivedDir]

        for rootDir in allDirs {
            guard let enumerator = fm.enumerator(at: rootDir, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in enumerator {
                guard url.pathExtension == "jsonl" else { continue }
                // Extract thread ID from filename: last UUID component before .jsonl
                let stem = url.deletingPathExtension().lastPathComponent
                // Format: rollout-YYYY-MM-DDTHH-MM-SS-<threadId>
                // threadId is the last 5 dash-separated groups (UUID v7)
                let parts = stem.components(separatedBy: "-")
                guard parts.count >= 5 else { continue }
                let threadId = parts.suffix(5).joined(separator: "-")

                if let model = extractModelFromJSONL(url) {
                    map[threadId] = model
                }
            }
        }
        return map
    }

    /// Reads a JSONL file and returns the model name from the first turn_context event.
    private func extractModelFromJSONL(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else { return nil }

        for line in content.components(separatedBy: "\n") {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let event = try? JSONDecoder().decode(CodexTurnContextEvent.self, from: lineData),
                  event.type == "turn_context",
                  let model = event.payload?.model,
                  !model.isEmpty else { continue }
            return model
        }
        return nil
    }

    func parseDailyStats(since date: Date? = nil) async throws -> [DailyStats] {
        guard FileManager.default.fileExists(atPath: dbPath) else { return [] }
        do {
            guard let db = try? Connection(.uri(dbPath, parameters: [.mode(.readOnly)])) else { return [] }

            let threads = Table("threads")
            let tokensCol = Expression<Int64?>("tokens_used")
            let createdCol = Expression<Int64>("created_at")   // UNIX seconds
            let archivedCol = Expression<Bool?>("archived")

            var byDay: [String: (tokens: Int, count: Int)] = [:]
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            fmt.locale = Locale(identifier: "en_US_POSIX")

            for row in try db.prepare(threads) {
                let d = Date(timeIntervalSince1970: TimeInterval(row[createdCol]))
                if let cutoff = date, d < cutoff { continue }
                if row[archivedCol] == true { continue }
                let tokens = Int(row[tokensCol] ?? 0)
                guard tokens > 0 else { continue }
                let key = fmt.string(from: d)
                byDay[key, default: (0, 0)].tokens += tokens
                byDay[key, default: (0, 0)].count += 1
            }

            let calendar = Calendar.current
            return byDay.compactMap { key, val -> DailyStats? in
                guard let d = fmt.date(from: key) else { return nil }
                return DailyStats(
                    date: calendar.startOfDay(for: d),
                    tool: .codex,
                    totalInputTokens: val.tokens * 4 / 5,
                    totalOutputTokens: val.tokens / 5,
                    sessionCount: val.count
                )
            }.sorted { $0.date < $1.date }
        } catch {
            if isTransientDatabaseError(error) {
                await AppLogger.shared.warning("Codex daily stats unavailable this cycle: \(error.localizedDescription)")
                return []
            }
            throw error
        }
    }

    private func isTransientDatabaseError(_ error: Error) -> Bool {
        let description = error.localizedDescription.lowercased()
        if description.contains("unable to open database file") || description.contains("code: 14") {
            return true
        }
        if description.contains("sqlite.result error 0") || description.contains("database is locked") || description.contains("database busy") {
            return true
        }
        if let parserError = error as? ParserError {
            switch parserError {
            case .transientDatabaseUnavailable:
                return true
            }
        }
        return false
    }

    // MARK: - Rate limits from latest JSONL session event

    func parseLatestRateLimits() async -> CodexRateLimits? {
        if let limits = scanRecentlyModifiedFilesForRateLimits() {
            return limits
        }

        // Fallback to date buckets for older Codex layouts or files without mtime metadata.
        let calendar = Calendar.current
        let today = Date()

        for daysBack in 0...3 {
            guard let day = calendar.date(byAdding: .day, value: -daysBack, to: today) else { continue }
            let comp = calendar.dateComponents([.year, .month, .day], from: day)
            let dirPath = sessionsDir
                .appending(path: String(format: "%04d", comp.year!))
                .appending(path: String(format: "%02d", comp.month!))
                .appending(path: String(format: "%02d", comp.day!))

            if let limits = await scanDirForRateLimits(dirPath) { return limits }
        }

        // Try archived
        return await scanDirForRateLimits(archivedDir)
    }

    private func scanRecentlyModifiedFilesForRateLimits() -> CodexRateLimits? {
        for file in recentlyModifiedJSONLFiles(in: [sessionsDir, archivedDir], limit: 200) {
            if let limits = parseRateLimitsFromFile(file) {
                return limits
            }
        }
        return nil
    }

    private func recentlyModifiedJSONLFiles(in roots: [URL], limit: Int) -> [URL] {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        let cutoff = Date().addingTimeInterval(-14 * 24 * 60 * 60)
        var candidates: [(url: URL, modifiedAt: Date)] = []

        for root in roots where fm.fileExists(atPath: root.path) {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let url as URL in enumerator {
                guard url.pathExtension == "jsonl" else { continue }
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true,
                      let modifiedAt = values.contentModificationDate,
                      modifiedAt >= cutoff else { continue }
                candidates.append((url, modifiedAt))
            }
        }

        return candidates
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(limit)
            .map(\.url)
    }

    private func scanDirForRateLimits(_ dir: URL) async -> CodexRateLimits? {
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "jsonl" }
            .sorted {
                let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhs > rhs
            }) ?? []

        for file in files {
            if let limits = parseRateLimitsFromFile(file) { return limits }
        }
        return nil
    }

    private func parseRateLimitsFromFile(_ url: URL) -> CodexRateLimits? {
        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else { return nil }
        let lines = content.components(separatedBy: "\n").reversed()
        let decoder = JSONDecoder()

        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let event = try? decoder.decode(CodexEvent.self, from: lineData),
                  event.type == "event_msg",
                  let payload = event.payload,
                  payload.type == "token_count",
                  let limits = payload.rateLimits else { continue }
            return limits
        }
        return nil
    }
}

// MARK: - Decodable models

struct CodexRateLimits: Codable, Sendable {
    let primary: CodexWindow?
    let secondary: CodexWindow?
    let credits: CodexCredits?
    let planType: String?

    enum CodingKeys: String, CodingKey {
        case primary, secondary, credits
        case planType = "plan_type"
    }

    var fiveHourWindow: CodexWindow? {
        selectNearestWindow(targetSeconds: 5 * 60 * 60)
    }

    var oneWeekWindow: CodexWindow? {
        selectNearestWindow(targetSeconds: 7 * 24 * 60 * 60)
    }

    private func selectNearestWindow(targetSeconds: Int) -> CodexWindow? {
        [primary, secondary]
            .compactMap { $0 }
            .min { lhs, rhs in
                abs(lhs.durationSeconds - targetSeconds) < abs(rhs.durationSeconds - targetSeconds)
            }
    }
}

struct CodexWindow: Codable, Sendable {
    let usedPercent: Double?
    let windowMinutes: Int?
    let windowSeconds: Int?
    let resetsAt: TimeInterval?   // Unix seconds

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case windowMinutes = "window_minutes"
        case windowSeconds = "limit_window_seconds"
        case resetsAt = "resets_at"
        case resetAt = "reset_at"
    }

    init(usedPercent: Double?, windowMinutes: Int?, windowSeconds: Int?, resetsAt: TimeInterval?) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes ?? windowSeconds.map { max(0, $0 / 60) }
        self.windowSeconds = windowSeconds
        self.resetsAt = resetsAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let usedPercent = try container.decodeIfPresent(Double.self, forKey: .usedPercent)
        let windowMinutes = try container.decodeIfPresent(Int.self, forKey: .windowMinutes)
        let windowSeconds = try container.decodeIfPresent(Int.self, forKey: .windowSeconds)
        let resetsAt = try container.decodeIfPresent(TimeInterval.self, forKey: .resetsAt)
            ?? container.decodeIfPresent(TimeInterval.self, forKey: .resetAt)
        self.init(
            usedPercent: usedPercent,
            windowMinutes: windowMinutes,
            windowSeconds: windowSeconds,
            resetsAt: resetsAt
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(usedPercent, forKey: .usedPercent)
        try container.encodeIfPresent(windowMinutes, forKey: .windowMinutes)
        try container.encodeIfPresent(windowSeconds, forKey: .windowSeconds)
        try container.encodeIfPresent(resetsAt, forKey: .resetsAt)
    }

    var resetDate: Date? { resetsAt.map { Date(timeIntervalSince1970: $0) } }
    var remainingPercent: Double { 100 - (usedPercent ?? 0) }
    var durationSeconds: Int { windowSeconds ?? (windowMinutes ?? 0) * 60 }

    /// Human-readable window label derived from windowMinutes.
    /// e.g. 300 → "5h Session", 10080 → "7d Weekly", 20160 → "14d Cycle"
    var windowLabel: String {
        guard let mins = windowMinutes else { return "Window" }
        if mins == 300 { return "5h Session" }
        if mins == 10080 { return "7d Weekly" }
        if mins == 20160 { return "14d Cycle" }
        let totalHours = mins / 60
        let days = totalHours / 24
        if days >= 1 {
            return "\(days)d Cycle"
        } else {
            return "\(totalHours)h Session"
        }
    }
}

struct CodexCredits: Codable, Sendable {
    let hasCredits: Bool?
    let unlimited: Bool?
    let balance: String?

    enum CodingKeys: String, CodingKey {
        case hasCredits = "has_credits"
        case unlimited, balance
    }
}

private struct CodexEvent: Decodable {
    let type: String?
    let payload: CodexEventPayload?
}

private struct CodexEventPayload: Decodable {
    let type: String?
    let rateLimits: CodexRateLimits?

    enum CodingKeys: String, CodingKey {
        case type
        case rateLimits = "rate_limits"
    }
}

private struct CodexTurnContextEvent: Decodable {
    let type: String?
    let payload: CodexTurnContextPayload?
}

private struct CodexTurnContextPayload: Decodable {
    let model: String?
}
