import Foundation

/// Parses Claude Code CLI data from ~/.claude/
/// Token usage: projects/**/*.jsonl (per-message) + stats-cache.json (aggregated)
/// Quota: OpenPulse Claude Code bridge cache populated from Claude Code status JSON.
actor ClaudeCodeParser {
    private let claudeDir: URL
    private let statusCacheURL: URL

    init(
        claudeDir: URL = .homeDirectory.appending(path: ".claude"),
        statusCacheURL: URL = ClaudeCodeBridgeInstaller.cacheURL
    ) {
        self.claudeDir = claudeDir
        self.statusCacheURL = statusCacheURL
    }

    // MARK: - Aggregated stats from stats-cache.json (fastest)

    func parseDailyStatsFromCache() async throws -> [DailyStats] {
        let statsFile = claudeDir.appending(path: "stats-cache.json")
        guard FileManager.default.fileExists(atPath: statsFile.path) else { return [] }

        let data = try Data(contentsOf: statsFile)
        let cache = try JSONDecoder().decode(StatsCache.self, from: data)
        let calendar = Calendar.current

        // Build a date → tokens map from dailyModelTokens
        var tokensByDate: [String: Int] = [:]
        for entry in cache.dailyModelTokens ?? [] {
            let total = entry.tokensByModel.values.reduce(0, +)
            tokensByDate[entry.date, default: 0] += total
        }

        // Also pull output tokens from modelUsage totals if dailyModelTokens lacks them
        // (stats-cache stores only input tokens in dailyModelTokens)
        var outputFraction: Double = 0.0
        let totalIn = cache.modelUsage?.values.reduce(0) { $0 + ($1.inputTokens ?? 0) } ?? 0
        let totalOut = cache.modelUsage?.values.reduce(0) { $0 + ($1.outputTokens ?? 0) } ?? 0
        if totalIn > 0 {
            outputFraction = Double(totalOut) / Double(totalIn)
        }

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")

        return (cache.dailyActivity ?? []).compactMap { activity -> DailyStats? in
            guard let date = fmt.date(from: activity.date) else { return nil }
            let inputTokens = tokensByDate[activity.date] ?? 0
            let outputTokens = Int(Double(inputTokens) * outputFraction)
            return DailyStats(
                date: calendar.startOfDay(for: date),
                tool: .claudeCode,
                totalInputTokens: inputTokens,
                totalOutputTokens: outputTokens,
                sessionCount: activity.sessionCount
            )
        }.sorted { $0.date < $1.date }
    }

    // MARK: - Per-session parsing from JSONL (detailed)

    func parseSessions(since cutoff: Date? = nil) async throws -> [ToolSession] {
        let projectsDir = claudeDir.appending(path: "projects")
        guard FileManager.default.fileExists(atPath: projectsDir.path) else { return [] }

        // Also check ~/.config/claude/projects
        var searchDirs = [projectsDir]
        let configDir = URL.homeDirectory.appending(path: ".config/claude/projects")
        if FileManager.default.fileExists(atPath: configDir.path) {
            searchDirs.append(configDir)
        }

        var sessions: [ToolSession] = []
        for searchDir in searchDirs {
            let projectDirs = (try? FileManager.default.contentsOfDirectory(
                at: searchDir,
                includingPropertiesForKeys: [.isDirectoryKey]
            ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }) ?? []

            for projectDir in projectDirs {
                let jsonlFiles = (try? FileManager.default.contentsOfDirectory(
                    at: projectDir,
                    includingPropertiesForKeys: [.contentModificationDateKey]
                ).filter { $0.pathExtension == "jsonl" }) ?? []

                // Skip files not modified since cutoff (perf optimization)
                for file in jsonlFiles {
                    if let cutoff, let modDate = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modDate < cutoff { continue }
                    if let session = parseSessionFile(file, since: cutoff) {
                        sessions.append(session)
                    }
                }
            }
        }
        return sessions.sorted { $0.startedAt < $1.startedAt }
    }

    // MARK: - Subscription quota from Claude Code bridge

    func readSubscriptionQuotaFromBridge(maxAge: TimeInterval = 15 * 60) async throws -> ToolQuota {
        guard FileManager.default.fileExists(atPath: statusCacheURL.path) else {
            throw ClaudeError.bridgeDataUnavailable
        }

        let data = try Data(contentsOf: statusCacheURL)
        let payload = try JSONDecoder().decode(ClaudeStatusBridgePayload.self, from: data)
        let capturedAt = Date(timeIntervalSince1970: TimeInterval(payload.capturedAt))
        guard Date().timeIntervalSince(capturedAt) <= maxAge else {
            throw ClaudeError.bridgeDataStale
        }

        let usage = ClaudeUsageResponse(
            fiveHour: payload.rateLimits.fiveHour,
            sevenDay: payload.rateLimits.sevenDay,
            contextWindow: payload.contextWindow
        )
        let remaining = usage.fiveHour?.utilization.map { Int((1.0 - $0 / 100.0) * 100) }

        return ToolQuota(
            id: Tool.claudeCode.rawValue,
            tool: .claudeCode,
            accountKey: nil,
            accountLabel: nil,
            remaining: remaining,
            total: 100,
            unit: .messages,
            resetAt: usage.fiveHour?.resetDate,
            updatedAt: Date(),
            raw: usage
        )
    }

    // MARK: - Private JSONL parsing

    private func parseSessionFile(_ url: URL, since cutoff: Date?) -> ToolSession? {
        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else { return nil }

        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        let decoder = JSONDecoder()

        var firstTimestamp: Date?
        var lastTimestamp: Date?
        var totalInput = 0, totalOutput = 0, totalCacheRead = 0, totalCacheWrite = 0
        var taskDescription = ""
        var model = ""
        var cwd = ""
        var gitBranch: String?
        var sessionId: String?
        var summaries: [String] = []
        // Accumulate per-messageId usage — keep updating so we always end up with
        // the final (most-complete) chunk rather than the first (which may be partial).
        struct MsgUsage { var input, output, cacheRead, cacheWrite: Int }
        var messageUsage: [String: MsgUsage] = [:]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let record = try? decoder.decode(ClaudeRecord.self, from: lineData) else { continue }

            if let ts = record.timestamp.flatMap({ iso.date(from: $0) }) {
                if firstTimestamp == nil { firstTimestamp = ts }
                lastTimestamp = ts
            }

            switch record.type {
            case "assistant":
                if sessionId == nil { sessionId = record.sessionId }
                if let c = record.cwd, cwd.isEmpty { cwd = c }
                if let b = record.gitBranch, gitBranch == nil { gitBranch = b }
                if let m = record.message {
                    if model.isEmpty, let mdl = m.model { model = mdl }
                    // Always overwrite — last chunk has the complete usage values.
                    let msgId = m.id ?? UUID().uuidString
                    messageUsage[msgId] = MsgUsage(
                        input: m.usage?.inputTokens ?? 0,
                        output: m.usage?.outputTokens ?? 0,
                        cacheRead: m.usage?.cacheReadInputTokens ?? 0,
                        cacheWrite: m.usage?.cacheCreationInputTokens ?? 0
                    )
                }
            case "user":
                if taskDescription.isEmpty, let content = record.message?.contentString {
                    taskDescription = String(content.prefix(200))
                }
            case "summary":
                if let s = record.summary { summaries.append(s) }
            default: break
            }
        }

        // Sum up the final usage across all messages
        for usage in messageUsage.values {
            totalInput += usage.input
            totalOutput += usage.output
            totalCacheRead += usage.cacheRead
            totalCacheWrite += usage.cacheWrite
        }

        guard let startDate = firstTimestamp else { return nil }
        if let cutoff, startDate < cutoff { return nil }
        if totalInput + totalOutput == 0 { return nil }  // skip empty sessions
        if model == "<synthetic>" { return nil }  // skip internal Claude Code sub-agent sessions

        return ToolSession(
            id: UUID(uuidString: sessionId ?? "") ?? UUID(),
            tool: .claudeCode,
            startedAt: startDate,
            endedAt: lastTimestamp,
            inputTokens: totalInput,
            outputTokens: totalOutput,
            cacheReadTokens: totalCacheRead,
            cacheWriteTokens: totalCacheWrite,
            taskDescription: summaries.last ?? taskDescription,
            model: model,
            cwd: cwd,
            gitBranch: gitBranch
        )
    }
}

// MARK: - Errors

enum ClaudeError: Error, LocalizedError {
    case bridgeDataUnavailable
    case bridgeDataStale

    var errorDescription: String? {
        switch self {
        case .bridgeDataUnavailable:
            "Claude Code bridge has not received rate limit data yet."
        case .bridgeDataStale:
            "Claude Code bridge rate limit data is stale."
        }
    }
}

// MARK: - JSON Models

struct ClaudeUsageResponse: Codable, Sendable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let sevenDaySonnet: UsageWindow?
    let sevenDayOpus: UsageWindow?
    let extraUsage: ExtraUsage?
    let contextWindow: ClaudeContextWindow?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayOpus = "seven_day_opus"
        case extraUsage = "extra_usage"
        case contextWindow = "context_window"
    }

    init(
        fiveHour: UsageWindow?,
        sevenDay: UsageWindow?,
        sevenDaySonnet: UsageWindow? = nil,
        sevenDayOpus: UsageWindow? = nil,
        extraUsage: ExtraUsage? = nil,
        contextWindow: ClaudeContextWindow? = nil
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDaySonnet = sevenDaySonnet
        self.sevenDayOpus = sevenDayOpus
        self.extraUsage = extraUsage
        self.contextWindow = contextWindow
    }
}

struct UsageWindow: Codable, Sendable {
    let utilization: Double?    // 0–100
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case usedPercentage = "used_percentage"
        case resetsAt = "resets_at"
    }

    init(utilization: Double?, resetsAt: String?) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        utilization = try container.decodeIfPresent(Double.self, forKey: .utilization)
            ?? container.decodeIfPresent(Double.self, forKey: .usedPercentage)
        if let stringValue = try? container.decodeIfPresent(String.self, forKey: .resetsAt) {
            resetsAt = stringValue
        } else if let doubleValue = try? container.decodeIfPresent(Double.self, forKey: .resetsAt) {
            resetsAt = String(doubleValue)
        } else if let intValue = try? container.decodeIfPresent(Int.self, forKey: .resetsAt) {
            resetsAt = String(intValue)
        } else {
            resetsAt = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(utilization, forKey: .utilization)
        try container.encodeIfPresent(resetsAt, forKey: .resetsAt)
    }

    var resetDate: Date? {
        guard let resetsAt else { return nil }
        if let epochSeconds = Double(resetsAt) {
            return Date(timeIntervalSince1970: epochSeconds)
        }
        return parseClaudeISO8601(resetsAt)
    }
}

struct ExtraUsage: Codable, Sendable {
    let isEnabled: Bool?
    let monthlyLimit: Double?   // cents
    let usedCredits: Double?    // cents
    let utilization: Double?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization
    }
}

struct ClaudeContextWindow: Codable, Sendable {
    let usedPercentage: Double?
    let remainingPercentage: Double?

    enum CodingKeys: String, CodingKey {
        case usedPercentage = "used_percentage"
        case remainingPercentage = "remaining_percentage"
    }
}

private struct ClaudeStatusBridgePayload: Decodable {
    let capturedAt: Int
    let rateLimits: RateLimits
    let contextWindow: ClaudeContextWindow?

    enum CodingKeys: String, CodingKey {
        case capturedAt = "captured_at"
        case rateLimits = "rate_limits"
        case contextWindow = "context_window"
    }

    struct RateLimits: Decodable {
        let fiveHour: UsageWindow?
        let sevenDay: UsageWindow?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }
    }
}

private nonisolated(unsafe) let _claudeISO8601Frac: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private nonisolated(unsafe) let _claudeISO8601Std = ISO8601DateFormatter()

private func parseClaudeISO8601(_ raw: String) -> Date? {
    _claudeISO8601Frac.date(from: raw) ?? _claudeISO8601Std.date(from: raw)
}

private struct StatsCache: Decodable {
    let dailyActivity: [DailyActivity]?
    let dailyModelTokens: [DailyModelTokens]?
    let modelUsage: [String: ModelUsageEntry]?
}

private struct DailyActivity: Decodable {
    let date: String
    let messageCount: Int
    let sessionCount: Int
    let toolCallCount: Int
}

private struct DailyModelTokens: Decodable {
    let date: String
    let tokensByModel: [String: Int]
}

private struct ModelUsageEntry: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadInputTokens: Int?
    let costUSD: Double?
}

// MARK: - JSONL record types

private struct ClaudeRecord: Decodable {
    let type: String?
    let sessionId: String?
    let timestamp: String?
    let cwd: String?
    let gitBranch: String?
    let message: ClaudeMessage?
    let summary: String?

    enum CodingKeys: String, CodingKey {
        case type, sessionId, timestamp, cwd, gitBranch, message, summary
    }
}

private struct ClaudeMessage: Decodable {
    let id: String?
    let role: String?
    let model: String?
    let usage: ClaudeUsage?
    let content: ClaudeContent?

    var contentString: String? {
        switch content {
        case .string(let s): return s
        case .blocks(let blocks): return blocks.compactMap { $0.text }.joined(separator: " ")
        case nil: return nil
        }
    }
}

private enum ClaudeContent: Decodable {
    case string(String)
    case blocks([ContentBlock])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) { self = .string(s) }
        else { self = .blocks((try? container.decode([ContentBlock].self)) ?? []) }
    }
}

private struct ContentBlock: Decodable {
    let type: String?
    let text: String?
}

private struct ClaudeUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadInputTokens: Int?
    let cacheCreationInputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
    }
}
