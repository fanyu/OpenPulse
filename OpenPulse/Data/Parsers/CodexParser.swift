import Foundation
import SQLite

/// Streams a JSONL file one line at a time.
///
/// Lives here rather than in its own file so the Xcode project does not need
/// regenerating; `ClaudeCodeParser` uses it too.
///
/// The previous `Data(contentsOf:)` + `String(data:)` + `components(separatedBy:)`
/// approach materialised three full copies of every file. Codex session logs
/// reach ~500 MB each, which drove multi-GB transient RSS on every rescan.
/// Lines are handed back as raw bytes so callers can reject most of them
/// without paying for a `String`.
enum JSONLReader {
    private static let newline = UInt8(0x0A)

    @discardableResult
    static func forEachLine(of url: URL, _ body: (Data, Int) -> Void) -> Bool {
        forEachLine(of: url, until: { data, index in
            body(data, index)
            return false
        })
    }

    /// Stops reading as soon as a caller finds its value.
    @discardableResult
    static func forEachLine(of url: URL, until body: (Data, Int) -> Bool) -> Bool {
        // Memory-mapped: pages are faulted in on demand and can be evicted by the
        // kernel, so a 500 MB log costs no lasting resident memory. Lines are handed
        // back as raw bytes so callers can reject most of them before paying for a
        // String, and can decode JSON straight from the slice.
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }

        var lineStart = data.startIndex
        var lineIndex = 0
        while let newlineIndex = data[lineStart...].firstIndex(of: newline) {
            if body(data[lineStart..<newlineIndex], lineIndex) { return true }
            lineIndex += 1
            lineStart = data.index(after: newlineIndex)
        }
        if lineStart < data.endIndex {
            _ = body(data[lineStart...], lineIndex)
        }
        return true
    }
}

/// Parses OpenAI Codex CLI data from ~/.codex/
/// - Token usage: state_5.sqlite threads table (created_at is Unix seconds)
/// - Rate limits: latest token_count event from session JSONL files
actor CodexParser {
    struct LocalRateLimitSnapshot: Sendable {
        let limits: CodexRateLimits
        let sourceURL: URL
        let modifiedAt: Date?
    }

    private struct RateLimitCandidate {
        let identity: String
        let limits: CodexRateLimits
        let observedAt: Date?
        let sourceURL: URL
        let modifiedAt: Date?
        let lineIndex: Int
    }

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

    private struct RateLimitFileSignature: Equatable {
        let modifiedAt: Date
        let size: Int?
        let fileIdentifier: AnyHashable?
    }

    /// Cache per source file, including files with no usable quota event. Each file
    /// has its own signature; another file's future mtime cannot hide an append.
    private var cachedRateLimitCandidatesByFile: [URL: [RateLimitCandidate]] = [:]
    private var cachedRateLimitFileSignatures: [URL: RateLimitFileSignature] = [:]

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
            let hasUpdatedAt = (try db.scalar("SELECT COUNT(*) FROM pragma_table_info('threads') WHERE name = 'updated_at'") as? Int64) == 1
            let updatedCol = Expression<Int64?>("updated_at")
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
            if let date { refreshModelMap(since: date) }
            let modelMap = cachedModelMap ?? [:]

            var sessions: [ToolSession] = []
            for row in try db.prepare(threads) {
                // created_at is Unix SECONDS (not ms)
                let startDate = Date(timeIntervalSince1970: TimeInterval(row[createdCol]))
                // Existing conversations can gain tokens long after they were created.
                // Older schemas without updated_at require a full scan for correctness.
                if let cutoff = date, hasUpdatedAt,
                   startDate < cutoff,
                   TimeInterval(row[updatedCol] ?? row[createdCol]) < cutoff.timeIntervalSince1970 { continue }
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
                    outputTokens: tokens - tokens * 4 / 5,
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
        var model: String?
        JSONLReader.forEachLine(of: url, until: { line, _ in
            guard line.range(of: Data("turn_context".utf8)) != nil,
                  let event = try? JSONDecoder().decode(CodexTurnContextEvent.self, from: line),
                  event.type == "turn_context", let value = event.payload?.model, !value.isEmpty else { return false }
            model = value
            return true
        })
        return model
    }

    private func refreshModelMap(since cutoff: Date) {
        for root in [sessionsDir, archivedDir] {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      modified >= cutoff else { continue }
                let parts = url.deletingPathExtension().lastPathComponent.components(separatedBy: "-")
                guard parts.count >= 5, let model = extractModelFromJSONL(url) else { continue }
                cachedModelMap?[parts.suffix(5).joined(separator: "-")] = model
            }
        }
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
                // Daily rows are whole-day totals. A rolling cutoff would overwrite
                // today's existing row with only conversations created in the last hour.
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
                    totalOutputTokens: val.tokens - val.tokens * 4 / 5,
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

    func parseLatestRateLimitsSnapshot() async -> LocalRateLimitSnapshot? {
        if let snapshot = scanRecentlyModifiedFilesForRateLimits() {
            return snapshot
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

            if let snapshot = await scanDirForRateLimits(dirPath) { return snapshot }
        }

        // Try archived
        return await scanDirForRateLimits(archivedDir)
    }

    func parseLatestRateLimits() async -> CodexRateLimits? {
        await parseLatestRateLimitsSnapshot()?.limits
    }

    private static let rateLimitFileWindow: TimeInterval = 14 * 24 * 60 * 60

    private func scanRecentlyModifiedFilesForRateLimits() -> LocalRateLimitSnapshot? {
        let cutoff = Date().addingTimeInterval(-Self.rateLimitFileWindow)
        let files = recentlyModifiedJSONLFiles(in: [sessionsDir, archivedDir], limit: 200, cutoff: cutoff)
        let selectedURLs = Set(files.map(\.url))
        // Match exactly the bounded source set a full scan would reduce, including
        // deletions, replacements, and files aging out of the selection window.
        cachedRateLimitCandidatesByFile = cachedRateLimitCandidatesByFile.filter { selectedURLs.contains($0.key) }
        cachedRateLimitFileSignatures = cachedRateLimitFileSignatures.filter { selectedURLs.contains($0.key) }
        for file in files {
            guard cachedRateLimitFileSignatures[file.url] != file.signature else { continue }
            guard let candidates = readRateLimitCandidatesFromFile(file.url) else { continue }
            cachedRateLimitCandidatesByFile[file.url] = candidates
            cachedRateLimitFileSignatures[file.url] = file.signature
        }
        return makeRateLimitSnapshot(from: cachedRateLimitCandidatesByFile.values.flatMap { $0 })
    }

    private func recentlyModifiedJSONLFiles(
        in roots: [URL],
        limit: Int,
        cutoff: Date
    ) -> [(url: URL, signature: RateLimitFileSignature)] {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey, .fileResourceIdentifierKey]
        var candidates: [(url: URL, signature: RateLimitFileSignature)] = []

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
                candidates.append((url, RateLimitFileSignature(modifiedAt: modifiedAt, size: values.fileSize, fileIdentifier: values.fileResourceIdentifier as? AnyHashable)))
            }
        }

        return Array(candidates.sorted {
            if $0.signature.modifiedAt != $1.signature.modifiedAt { return $0.signature.modifiedAt > $1.signature.modifiedAt }
            return $0.url.path < $1.url.path
        }.prefix(limit))
    }

    private func scanDirForRateLimits(_ dir: URL) async -> LocalRateLimitSnapshot? {
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "jsonl" }
            .sorted {
                let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhs > rhs
            }) ?? []

        return makeRateLimitSnapshot(from: files.flatMap(parseRateLimitCandidatesFromFile))
    }

    private static let tokenCountNeedle = Data("token_count".utf8)

    private func parseRateLimitCandidatesFromFile(_ url: URL) -> [RateLimitCandidate] {
        readRateLimitCandidatesFromFile(url) ?? []
    }

    private func readRateLimitCandidatesFromFile(_ url: URL) -> [RateLimitCandidate]? {
        let decoder = JSONDecoder()
        let modifiedAt = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

        // Reduce per file rather than returning every candidate. `makeRateLimitSnapshot`
        // keeps only the newest candidate per identity, and that reduction is
        // associative, so collapsing here is equivalent — while keeping tens of
        // thousands of candidates from accumulating across 200 files.
        // The window filter below must match the one in `makeRateLimitSnapshot`:
        // without it a window-less but newer candidate could evict a usable older
        // one here and then be discarded there, losing the limit entirely.
        var latestByIdentity: [String: RateLimitCandidate] = [:]

        let didRead = JSONLReader.forEachLine(of: url) { lineData, lineIndex in
            // Cheap byte-level reject before the expensive decode — only token_count
            // events carry rate limits. Decoding straight from the line bytes also
            // avoids the old String round-trip.
            guard lineData.range(of: Self.tokenCountNeedle) != nil,
                  let event = try? decoder.decode(CodexEvent.self, from: lineData),
                  event.type == "event_msg",
                  let payload = event.payload,
                  payload.type == "token_count",
                  let limits = payload.rateLimits,
                  limits.fiveHourWindow != nil || limits.oneWeekWindow != nil else { return }

            let identity = normalizedLimitIdentity(for: limits)
            let candidate = RateLimitCandidate(
                identity: identity,
                limits: limits,
                observedAt: parseEventTimestamp(event.timestamp) ?? modifiedAt,
                sourceURL: url,
                modifiedAt: modifiedAt,
                lineIndex: lineIndex
            )
            if let existing = latestByIdentity[identity], !isNewer(candidate, than: existing) { return }
            latestByIdentity[identity] = candidate
        }
        guard didRead else { return nil }
        return Array(latestByIdentity.values)
    }

    private func makeRateLimitSnapshot(from candidates: [RateLimitCandidate]) -> LocalRateLimitSnapshot? {
        guard !candidates.isEmpty else { return nil }

        var latestByIdentity: [String: RateLimitCandidate] = [:]
        for candidate in candidates {
            guard candidate.limits.fiveHourWindow != nil || candidate.limits.oneWeekWindow != nil else { continue }
            if let existing = latestByIdentity[candidate.identity], !isNewer(candidate, than: existing) {
                continue
            }
            latestByIdentity[candidate.identity] = candidate
        }

        let additionalLimits = latestByIdentity
            .filter { $0.key != Self.generalLimitIdentity }
            .values
            .sorted { lhs, rhs in lhs.identity < rhs.identity }
            .map { candidate in
                CodexNamedRateLimit(
                    id: candidate.identity,
                    name: candidate.limits.limitName,
                    primary: candidate.limits.primary,
                    secondary: candidate.limits.secondary,
                    observedAt: candidate.observedAt
                )
            }

        let source: RateLimitCandidate
        let snapshotLimits: CodexRateLimits
        if let general = latestByIdentity[Self.generalLimitIdentity] {
            source = general
            snapshotLimits = general.limits
                .replacingObservedAt(general.observedAt)
                .replacingAdditionalLimits(additionalLimits.isEmpty ? nil : additionalLimits)
        } else if let newestNamed = latestByIdentity
            .filter({ $0.key != Self.generalLimitIdentity })
            .values
            .reduce(nil as RateLimitCandidate?, { newest, candidate in
                guard let newest else { return candidate }
                return isNewer(candidate, than: newest) ? candidate : newest
            })
        {
            source = newestNamed
            snapshotLimits = CodexRateLimits(
                primary: nil,
                secondary: nil,
                credits: nil,
                resetCredits: nil,
                planType: nil,
                additionalLimits: additionalLimits.isEmpty ? nil : additionalLimits
            )
        } else {
            return nil
        }
        return LocalRateLimitSnapshot(
            limits: snapshotLimits,
            sourceURL: source.sourceURL,
            modifiedAt: source.modifiedAt
        )
    }

    private static let generalLimitIdentity = "codex"

    private func normalizedLimitIdentity(for limits: CodexRateLimits) -> String {
        guard let rawID = limits.limitID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawID.isEmpty,
              rawID.caseInsensitiveCompare(Self.generalLimitIdentity) != .orderedSame else {
            return Self.generalLimitIdentity
        }
        return rawID.lowercased()
    }

    private func isNewer(_ lhs: RateLimitCandidate, than rhs: RateLimitCandidate) -> Bool {
        switch (lhs.observedAt, rhs.observedAt) {
        case let (left?, right?) where left != right:
            return left > right
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            break
        }

        switch (lhs.modifiedAt, rhs.modifiedAt) {
        case let (left?, right?) where left != right:
            return left > right
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            return lhs.lineIndex > rhs.lineIndex
        }
    }

    // Sendable value-type styles, built once. The previous code allocated an
    // ISO8601DateFormatter per call and then mutated formatOptions, which forces
    // ICU to reload its locale symbols on every single timestamp.
    private static let isoWithFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let isoPlain = Date.ISO8601FormatStyle()

    private func parseEventTimestamp(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if let date = try? Self.isoWithFraction.parse(raw) { return date }
        return try? Self.isoPlain.parse(raw)
    }
}

// MARK: - Decodable models

struct CodexRateLimits: Codable, Sendable {
    let primary: CodexWindow?
    let secondary: CodexWindow?
    let credits: CodexCredits?
    let resetCredits: CodexResetCredits?
    let planType: String?
    let limitID: String?
    let limitName: String?
    let observedAt: Date?
    let additionalLimits: [CodexNamedRateLimit]?

    enum CodingKeys: String, CodingKey {
        case primary, secondary, credits
        case resetCredits = "rate_limit_reset_credits"
        case planType = "plan_type"
        case limitID = "limit_id"
        case limitName = "limit_name"
        case observedAt = "observed_at"
        case additionalLimits = "additional_limits"
    }

    init(
        primary: CodexWindow?,
        secondary: CodexWindow?,
        credits: CodexCredits?,
        resetCredits: CodexResetCredits?,
        planType: String?,
        limitID: String? = nil,
        limitName: String? = nil,
        observedAt: Date? = nil,
        additionalLimits: [CodexNamedRateLimit]? = nil
    ) {
        self.primary = primary
        self.secondary = secondary
        self.credits = credits
        self.resetCredits = resetCredits
        self.planType = planType
        self.limitID = limitID
        self.limitName = limitName
        self.observedAt = observedAt
        self.additionalLimits = additionalLimits
    }

    var isGeneralCodexLimit: Bool {
        guard let limitID else { return true }
        let normalized = limitID.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty || normalized.caseInsensitiveCompare("codex") == .orderedSame
    }

    var fiveHourWindow: CodexWindow? {
        selectWindow(durationSeconds: 5 * 60 * 60)
    }

    var oneWeekWindow: CodexWindow? {
        selectWindow(durationSeconds: 7 * 24 * 60 * 60)
    }

    var hasKnownGeneralWindow: Bool {
        fiveHourWindow != nil || oneWeekWindow != nil
    }

    func hasUsableGeneralWindow(at now: Date = Date()) -> Bool {
        [fiveHourWindow, oneWeekWindow]
            .compactMap { $0?.resetDate }
            .contains { $0 > now }
    }

    func hasUsableKnownWindow(at now: Date = Date()) -> Bool {
        if hasUsableGeneralWindow(at: now) { return true }
        return (additionalLimits ?? [])
            .flatMap { [$0.primary, $0.secondary] }
            .compactMap { window -> Date? in
                guard let window,
                      window.durationSeconds == 5 * 60 * 60 || window.durationSeconds == 7 * 24 * 60 * 60 else {
                    return nil
                }
                return window.resetDate
            }
            .contains { $0 > now }
    }

    func preservingResetCredits(from fallback: CodexRateLimits?) -> CodexRateLimits {
        guard resetCredits == nil, let fallbackResetCredits = fallback?.resetCredits else {
            return self
        }
        return replacingResetCredits(fallbackResetCredits)
    }

    func replacingResetCredits(_ resetCredits: CodexResetCredits?) -> CodexRateLimits {
        return CodexRateLimits(
            primary: primary,
            secondary: secondary,
            credits: credits,
            resetCredits: resetCredits,
            planType: planType,
            limitID: limitID,
            limitName: limitName,
            observedAt: observedAt,
            additionalLimits: additionalLimits
        )
    }

    func replacingObservedAt(_ observedAt: Date?) -> CodexRateLimits {
        CodexRateLimits(
            primary: primary,
            secondary: secondary,
            credits: credits,
            resetCredits: resetCredits,
            planType: planType,
            limitID: limitID,
            limitName: limitName,
            observedAt: observedAt,
            additionalLimits: additionalLimits
        )
    }

    func replacingAdditionalLimits(_ additionalLimits: [CodexNamedRateLimit]?) -> CodexRateLimits {
        CodexRateLimits(
            primary: primary,
            secondary: secondary,
            credits: credits,
            resetCredits: resetCredits,
            planType: planType,
            limitID: limitID,
            limitName: limitName,
            observedAt: observedAt,
            additionalLimits: additionalLimits
        )
    }

    func merging(_ incoming: CodexRateLimits) -> CodexRateLimits {
        let incomingHasGeneralObservation = [incoming.primary, incoming.secondary]
            .compactMap { $0 }
            .contains { $0.durationSeconds == 5 * 60 * 60 || $0.durationSeconds == 7 * 24 * 60 * 60 }
        let useIncomingGeneral = incomingHasGeneralObservation
            && Self.isNewerObservation(incoming.observedAt, than: observedAt)

        var mergedAdditionalLimits = additionalLimits
        if let incomingAdditionalLimits = incoming.additionalLimits, !incomingAdditionalLimits.isEmpty {
            var byIdentity: [String: CodexNamedRateLimit] = [:]
            for limit in additionalLimits ?? [] {
                guard let identity = Self.normalizedNamedLimitID(limit.id) else { continue }
                byIdentity[identity] = limit.replacingID(identity)
            }
            for limit in incomingAdditionalLimits {
                guard let identity = Self.normalizedNamedLimitID(limit.id) else { continue }
                let normalizedLimit = limit.replacingID(identity)
                if let existing = byIdentity[identity],
                   !Self.isNewerObservation(normalizedLimit.observedAt, than: existing.observedAt) {
                    continue
                }
                byIdentity[identity] = normalizedLimit
            }
            mergedAdditionalLimits = byIdentity.values.sorted { $0.id < $1.id }
        }

        return CodexRateLimits(
            primary: useIncomingGeneral ? incoming.primary : primary,
            secondary: useIncomingGeneral ? incoming.secondary : secondary,
            credits: incoming.credits ?? credits,
            resetCredits: incoming.resetCredits ?? resetCredits,
            planType: incoming.planType ?? planType,
            limitID: useIncomingGeneral ? (incoming.limitID ?? limitID) : limitID,
            limitName: useIncomingGeneral ? (incoming.limitName ?? limitName) : limitName,
            observedAt: useIncomingGeneral ? incoming.observedAt : observedAt,
            additionalLimits: mergedAdditionalLimits
        )
    }

    private static func normalizedNamedLimitID(_ rawID: String) -> String? {
        let identity = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identity.isEmpty, identity.caseInsensitiveCompare("codex") != .orderedSame else {
            return nil
        }
        return identity.lowercased()
    }

    private static func isNewerObservation(_ incoming: Date?, than existing: Date?) -> Bool {
        switch (incoming, existing) {
        case let (incoming?, existing?):
            return incoming >= existing
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return true
        }
    }

    private func selectWindow(durationSeconds targetSeconds: Int) -> CodexWindow? {
        [primary, secondary]
            .compactMap { $0 }
            .first { $0.durationSeconds == targetSeconds }
    }
}

struct CodexNamedRateLimit: Codable, Sendable, Identifiable {
    let id: String
    let name: String?
    let primary: CodexWindow?
    let secondary: CodexWindow?
    let observedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, primary, secondary
        case observedAt = "observed_at"
    }

    fileprivate func replacingID(_ id: String) -> CodexNamedRateLimit {
        CodexNamedRateLimit(
            id: id,
            name: name,
            primary: primary,
            secondary: secondary,
            observedAt: observedAt
        )
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
    var remainingPercent: Double? {
        guard let usedPercent, usedPercent.isFinite else { return nil }
        return min(100, max(0, 100 - usedPercent))
    }
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

struct CodexResetCredits: Codable, Sendable {
    let availableCount: Int?
    let credits: [CodexResetCredit]?

    enum CodingKeys: String, CodingKey {
        case availableCount = "available_count"
        case credits
    }
}

struct CodexResetCredit: Codable, Sendable, Identifiable {
    private let rawID: String?
    let status: String?
    let title: String?
    let grantedAt: Date?
    let expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case rawID = "id"
        case status, title
        case grantedAt = "granted_at"
        case expiresAt = "expires_at"
    }

    var id: String {
        rawID ?? [status, title, grantedAt?.timeIntervalSince1970.description, expiresAt?.timeIntervalSince1970.description]
            .compactMap { $0 }
            .joined(separator: ":")
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rawID = try container.decodeIfPresent(String.self, forKey: .rawID)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        grantedAt = Self.decodeDate(from: container, forKey: .grantedAt)
        expiresAt = Self.decodeDate(from: container, forKey: .expiresAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(rawID, forKey: .rawID)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(grantedAt, forKey: .grantedAt)
        try container.encodeIfPresent(expiresAt, forKey: .expiresAt)
    }

    private static func decodeDate(from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> Date? {
        if let date = try? container.decodeIfPresent(Date.self, forKey: key) {
            return date
        }
        guard let raw = try? container.decodeIfPresent(String.self, forKey: key) else {
            return nil
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}

private struct CodexEvent: Decodable {
    let timestamp: String?
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
