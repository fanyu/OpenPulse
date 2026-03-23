import Foundation
import SwiftData

/// Orchestrates all parsers: FSEvents file watching + periodic polling.
@MainActor
@Observable
final class DataSyncService {
    private(set) var isSyncing = false
    private(set) var lastSyncDate: Date?
    private(set) var syncError: Error?

    /// 最新的 Codex 多账户额度列表
    private(set) var latestCodexAccounts: [CodexAccountSnapshot] = []

    /// 最新的 Claude 订阅配额响应（含 fiveHour / sevenDay 窗口）；无订阅时为 nil
    private(set) var latestClaudeUsage: ClaudeUsageResponse?
    /// Exponential-backoff state for Claude quota API calls.
    /// After each failure the wait doubles: 5m → 10m → 20m → 40m → 80m → 120m (cap).
    private var claudeQuotaNextAt: Date = .distantPast
    private var claudeQuotaFailCount: Int = 0

    /// 最新的 Antigravity 账号配额列表（每个账号含所有模型，推荐模型优先）
    private(set) var latestAntigravityAccounts: [AGAccountQuota]?

    /// 最新的 Copilot quota snapshots（keyed by quota_id）
    private(set) var latestCopilotSnapshots: [String: CopilotSnapshot]?

    /// Copilot 账号配额重置日期（来自 quota_reset_date_utc）
    private(set) var latestCopilotResetAt: Date?

    private let claudeParser = ClaudeCodeParser()
    private let codexParser = CodexParser()
    private let codexAccountService: CodexAccountService
    private let antigravityParser = AntigravityParser()
    private let copilotClient = CopilotAPIClient()
    private let openCodeParser = OpenCodeParser()

    private var timers: [Tool: Timer] = [:]
    private var fsEventStream: FSEventStream?
    private var fsDebounceTask: Task<Void, Never>?
    /// Set to true after the first Codex full scan completes. Prevents re-scanning
    /// every FSEvents trigger when some sessions permanently lack JSONL model data.
    private var codexBackfillDone: Bool = false

    private let modelContext: ModelContext

    /// UserDefaults key for per-tool sync interval
    static func intervalKey(for tool: Tool) -> String { "syncInterval.\(tool.rawValue)" }

    /// Default intervals (seconds) per tool
    static func defaultInterval(for tool: Tool) -> Double {
        switch tool {
        case .claudeCode:   1800
        case .codex:         300   // has FSEvents, timer is coarse backup
        case .antigravity:   600
        case .copilot:      3600   // API-only, no FSEvents
        case .opencode:      300   // has FSEvents, timer is coarse backup
        }
    }

    init(modelContext: ModelContext, codexAccountService: CodexAccountService) {
        self.modelContext = modelContext
        self.codexAccountService = codexAccountService
    }

    // MARK: - Lifecycle

    func start() {
        purgeOrphanedQuotas()
        for tool in Tool.allCases { scheduleTimer(for: tool) }
        startFSEventWatching()
        NotificationService.shared.requestPermission()
        Task { await sync() }
    }

    /// Delete QuotaRecords whose toolRaw no longer maps to a known Tool case.
    /// This cleans up stale records from tools that have since been removed.
    private func purgeOrphanedQuotas() {
        let known = Set(Tool.allCases.map(\.rawValue))
        let descriptor = FetchDescriptor<QuotaRecord>()
        guard let all = try? modelContext.fetch(descriptor) else { return }
        for record in all where !known.contains(record.toolRaw) {
            modelContext.delete(record)
        }
        try? modelContext.save()
    }

    func stop() {
        timers.values.forEach { $0.invalidate() }
        timers.removeAll()
        fsEventStream?.stop()
        fsEventStream = nil
    }

    func sync() async {
        guard !isSyncing else { return }
        isSyncing = true
        syncError = nil
        AppLogger.shared.info("Sync started at \(Date())")

        do {
            try await syncClaudeCode()
            try await syncCodex()
            try await syncAntigravity()
            await syncCopilot()
            try await syncOpenCode()
            try modelContext.save()
            syncError = nil
            lastSyncDate = Date()
            let count = (try? modelContext.fetchCount(FetchDescriptor<SessionRecord>())) ?? 0
            AppLogger.shared.info("Sync completed. Total sessions in DB: \(count)")
            checkQuotaNotifications()
        } catch {
            syncError = error
            AppLogger.shared.error("Sync error: \(error)")
            AppLogger.shared.recordSyncError(scope: "full-sync", tool: nil, error: error)
        }

        isSyncing = false
    }

    /// Sync a single tool and save. Used by per-tool timers.
    func sync(tool: Tool) async {
        syncError = nil
        do {
            switch tool {
            case .claudeCode:   try await syncClaudeCode()
            case .codex:        try await syncCodex()
            case .antigravity:  try await syncAntigravity()
            case .copilot:      await syncCopilot()
            case .opencode:     try await syncOpenCode()
            }
            try modelContext.save()
            syncError = nil
            lastSyncDate = Date()
        } catch {
            syncError = error
            AppLogger.shared.error("Sync error (\(tool.rawValue)): \(error)")
            AppLogger.shared.recordSyncError(scope: "tool-sync", tool: tool, error: error)
        }
    }

    func rescheduleTimer(for tool: Tool, interval: Double) {
        timers[tool]?.invalidate()
        scheduleTimer(for: tool, override: interval)
    }

    // MARK: - Per-tool sync

    /// Parses Claude's local files only (stats-cache.json + JSONL). No network.
    private func parseClaudeFiles(since: Date?) async throws {
        let cachedStats = (try? await claudeParser.parseDailyStatsFromCache()) ?? []
        AppLogger.shared.info("ClaudeCode: parsed \(cachedStats.count) cached daily stats")
        for stat in cachedStats { upsertDailyStats(stat) }

        let sessions = try await claudeParser.parseSessions(since: since)
        AppLogger.shared.info("ClaudeCode: parsed \(sessions.count) sessions")
        for session in sessions { upsertSession(session) }
    }

    /// Parses Antigravity's local markdown files only. No network.
    private func parseAntigravityFiles(since: Date?) async throws {
        let sessions = try await antigravityParser.parseSessions(since: since)
        AppLogger.shared.info("Antigravity: parsed \(sessions.count) sessions")
        for session in sessions { upsertSession(session) }
    }

    /// Full Claude sync: local files + subscription quota API.
    private func syncClaudeCode() async throws {
        let since = lastSyncDate.map { Calendar.current.date(byAdding: .hour, value: -1, to: $0)! }
        try await parseClaudeFiles(since: since)
        await syncClaudeQuota()
    }

    private func syncClaudeQuota() async {
        // Restore last-known data from disk so the UI never shows "API Key mode" on launch.
        if latestClaudeUsage == nil,
           let cached = UserDefaults.standard.data(forKey: "cached.claudeUsageData"),
           let restored = try? JSONDecoder().decode(ClaudeUsageResponse.self, from: cached) {
            latestClaudeUsage = restored
            // Also keep SwiftData QuotaRecord in sync with the cached data
            // so the card's fallback path has something to show even when latestClaudeUsage
            // later gets cleared (e.g. after app restart where cache decode fails).
            upsertQuota(toolQuota(from: restored))
        }

        // Exponential backoff: don't fetch until the computed next-allowed time.
        guard Date() >= claudeQuotaNextAt else { return }

        do {
            let quota = try await claudeParser.fetchSubscriptionQuota()
            if let usage = quota.raw as? ClaudeUsageResponse {
                latestClaudeUsage = usage
            }
            claudeQuotaFailCount = 0
            claudeQuotaNextAt = Date().addingTimeInterval(1800)          // 30 min on success
            upsertQuota(quota)
        } catch {
            claudeQuotaFailCount += 1
            let backoff = min(300.0 * pow(2.0, Double(claudeQuotaFailCount - 1)), 7200)  // 5m…120m
            claudeQuotaNextAt = Date().addingTimeInterval(backoff)
            AppLogger.shared.warning(
                "Claude quota failed (\(claudeQuotaFailCount)x), retry in \(Int(backoff / 60))min: \(error.localizedDescription)"
            )
        }
    }

    /// Build a ToolQuota from a ClaudeUsageResponse (mirrors ClaudeCodeParser.fetchSubscriptionQuota).
    private func toolQuota(from usage: ClaudeUsageResponse) -> ToolQuota {
        let fiveHour = usage.fiveHour
        let remaining = fiveHour.map { Int((1.0 - ($0.utilization ?? 0) / 100.0) * 100) }
        let resetAt = fiveHour?.resetsAt.flatMap { ISO8601DateFormatter().date(from: $0) }
        return ToolQuota(
            id: Tool.claudeCode.rawValue, tool: .claudeCode,
            accountKey: nil, accountLabel: nil,
            remaining: remaining, total: 100,
            unit: .messages, resetAt: resetAt, updatedAt: Date(),
            raw: usage
        )
    }

    private func syncCodex() async throws {
        let since = lastSyncDate.map { Calendar.current.date(byAdding: .hour, value: -1, to: $0)! }

        // Full scan to backfill placeholder model names — done at most once per launch.
        // After the scan (even if some records remain un-fixable), we stop forcing full
        // scans so that FSEvents-triggered syncs don't re-scan thousands of sessions.
        let needsBackfill = !codexBackfillDone && hasCodexPlaceholderModels()
        let effectiveSince: Date? = needsBackfill ? nil : since
        if needsBackfill { codexBackfillDone = true }

        let sessions = try await codexParser.parseSessions(since: effectiveSince)
        AppLogger.shared.info("Codex: parsed \(sessions.count) sessions (fullScan=\(needsBackfill))")
        for session in sessions { upsertSession(session) }

        let stats = try await codexParser.parseDailyStats(since: since)
        for stat in stats { upsertDailyStats(stat) }

        await codexAccountService.syncCurrentSelectionFromAuthFile()
        let accounts = await codexAccountService.refreshAllUsage()
        let smartSwitchEnabled = UserDefaults.standard.bool(forKey: "codex.smartSwitch.enabled")
        if smartSwitchEnabled,
           let decision = try? await codexAccountService.autoSmartSwitchIfNeeded(accounts: accounts) {
            AppLogger.shared.warning(
                "Codex auto switch -> \(decision.account.titleText)\(decision.usedCLIFallback ? " (CLI fallback)" : "")"
            )
            latestCodexAccounts = await codexAccountService.listAccounts()
        } else {
            latestCodexAccounts = accounts
        }
        removeStaleCodexQuotas(validAccountKeys: Set(latestCodexAccounts.map(\.accountID)))
        for account in latestCodexAccounts {
            upsertQuota(account.quota)
        }

        if latestCodexAccounts.isEmpty, let limits = await codexParser.parseLatestRateLimits() {
            let quota = ToolQuota(
                id: Tool.codex.rawValue,
                tool: .codex,
                accountKey: nil,
                accountLabel: nil,
                remaining: limits.fiveHourWindow.map { Int($0.remainingPercent) },
                total: 100,
                unit: .tokens,
                resetAt: limits.fiveHourWindow?.resetDate,
                updatedAt: Date(),
                raw: limits
            )
            upsertQuota(quota)
        }
    }

    /// Full Antigravity sync: local markdown files + Google OAuth quota API.
    private func syncAntigravity() async throws {
        let since = lastSyncDate.map { Calendar.current.date(byAdding: .hour, value: -1, to: $0)! }
        try await parseAntigravityFiles(since: since)

        do {
            let quota = try await antigravityParser.fetchQuota()
            if let accounts = quota.raw as? [AGAccountQuota] {
                latestAntigravityAccounts = accounts
            }
            upsertQuota(quota)
        } catch {
            AppLogger.shared.warning("Antigravity quota skipped: \(error.localizedDescription)")
        }
    }

    /// Local-files-only sync — called by FSEvents on every file change.
    /// Parses JSONL/SQLite/markdown but never touches any network API,
    /// so frequent file writes during active use can't trigger rate limits.
    private func syncLocalFiles() async {
        guard !isSyncing else { return }
        let since = lastSyncDate.map { Calendar.current.date(byAdding: .hour, value: -1, to: $0)! }
        do {
            try await parseClaudeFiles(since: since)
            try await syncCodex()               // Codex is SQLite-only, no external API
            try await parseAntigravityFiles(since: since)
            try await syncOpenCode()
            try modelContext.save()
            syncError = nil
            lastSyncDate = Date()
        } catch {
            AppLogger.shared.error("Local file sync error: \(error)")
            syncError = error
            AppLogger.shared.recordSyncError(scope: "local-files", tool: nil, error: error)
        }
    }

    private func syncCopilot() async {
        do {
            let (quota, snapshots) = try await copilotClient.fetchQuota()
            latestCopilotSnapshots = snapshots
            latestCopilotResetAt = quota.resetAt
            upsertQuota(quota)
        } catch {
            AppLogger.shared.warning("Copilot quota skipped: \(error.localizedDescription)")
        }
    }

    private func syncOpenCode() async throws {
        let since = lastSyncDate.map { Calendar.current.date(byAdding: .hour, value: -1, to: $0)! }
        let sessions = try await openCodeParser.parseSessions(since: since)
        AppLogger.shared.info("OpenCode: parsed \(sessions.count) sessions")
        for session in sessions { upsertSession(session) }
    }

    // MARK: - SwiftData upsert helpers

    /// Returns true if any Codex SessionRecord still has the "openai" placeholder model name.
    private func hasCodexPlaceholderModels() -> Bool {
        let toolRaw = Tool.codex.rawValue
        let placeholder = "openai"
        let descriptor = FetchDescriptor<SessionRecord>(
            predicate: #Predicate { $0.toolRaw == toolRaw && $0.model == placeholder }
        )
        return ((try? modelContext.fetchCount(descriptor)) ?? 0) > 0
    }

    private func upsertSession(_ session: ToolSession) {
        let sessionId = session.id
        var sessionDescriptor = FetchDescriptor<SessionRecord>(predicate: #Predicate { $0.id == sessionId })
        sessionDescriptor.fetchLimit = 1
        let existing = (try? modelContext.fetch(sessionDescriptor))?.first

        if let existing {
            existing.inputTokens = session.inputTokens
            existing.outputTokens = session.outputTokens
            existing.cacheReadTokens = session.cacheReadTokens
            existing.cacheWriteTokens = session.cacheWriteTokens
            existing.endedAt = session.endedAt
            if !session.taskDescription.isEmpty {
                existing.taskDescription = session.taskDescription
            }
            // Update model name so previously-saved "openai" placeholders get corrected
            if !session.model.isEmpty {
                existing.model = session.model
            }
        } else {
            let record = SessionRecord(
                id: session.id,
                tool: session.tool,
                startedAt: session.startedAt,
                endedAt: session.endedAt,
                inputTokens: session.inputTokens,
                outputTokens: session.outputTokens,
                cacheReadTokens: session.cacheReadTokens,
                cacheWriteTokens: session.cacheWriteTokens,
                taskDescription: session.taskDescription,
                model: session.model,
                cwd: session.cwd,
                gitBranch: session.gitBranch
            )
            modelContext.insert(record)
        }
    }

    private func upsertDailyStats(_ stats: DailyStats) {
        let date = stats.date
        let toolRaw = stats.tool.rawValue
        var statsDescriptor = FetchDescriptor<DailyStatsRecord>(
            predicate: #Predicate { $0.date == date && $0.toolRaw == toolRaw }
        )
        statsDescriptor.fetchLimit = 1
        let existing = (try? modelContext.fetch(statsDescriptor))?.first

        if let existing {
            existing.totalInputTokens = stats.totalInputTokens
            existing.totalOutputTokens = stats.totalOutputTokens
            existing.totalCacheReadTokens = stats.totalCacheReadTokens
            existing.sessionCount = stats.sessionCount
        } else {
            let record = DailyStatsRecord(
                date: stats.date,
                tool: stats.tool,
                totalInputTokens: stats.totalInputTokens,
                totalOutputTokens: stats.totalOutputTokens,
                totalCacheReadTokens: stats.totalCacheReadTokens,
                sessionCount: stats.sessionCount
            )
            modelContext.insert(record)
        }
    }

    private func upsertQuota(_ quota: ToolQuota) {
        let toolRaw = quota.tool.rawValue
        let accountKey = quota.accountKey
        var quotaDescriptor = FetchDescriptor<QuotaRecord>(
            predicate: #Predicate { $0.toolRaw == toolRaw && $0.accountKey == accountKey }
        )
        quotaDescriptor.fetchLimit = 1
        let existing = (try? modelContext.fetch(quotaDescriptor))?.first

        if let existing {
            existing.accountLabel = quota.accountLabel
            existing.remaining = quota.remaining
            existing.total = quota.total
            existing.resetAt = quota.resetAt
            existing.updatedAt = Date()
        } else {
            let record = QuotaRecord(
                tool: quota.tool,
                accountKey: quota.accountKey,
                accountLabel: quota.accountLabel,
                remaining: quota.remaining,
                total: quota.total,
                unit: quota.unit,
                resetAt: quota.resetAt
            )
            modelContext.insert(record)
        }
    }

    private func removeStaleCodexQuotas(validAccountKeys: Set<String>) {
        let toolRaw = Tool.codex.rawValue
        let descriptor = FetchDescriptor<QuotaRecord>(predicate: #Predicate { $0.toolRaw == toolRaw })
        guard let records = try? modelContext.fetch(descriptor) else { return }
        for record in records {
            guard let accountKey = record.accountKey else { continue }
            if !validAccountKeys.contains(accountKey) {
                modelContext.delete(record)
            }
        }
    }

    // MARK: - Quota notifications

    private func checkQuotaNotifications() {
        var quotas: [String: NotificationService.QuotaInfo] = [:]

        if let current = latestCodexAccounts.first(where: \.isCurrent),
           let fiveHour = current.limits?.fiveHourWindow,
           let used = fiveHour.usedPercent {
            quotas[Tool.codex.rawValue] = .init(fraction: max(0, (100 - used) / 100), resetAt: fiveHour.resetDate)
        }
        if let usage = latestClaudeUsage,
           let window = usage.fiveHour,
           let util = window.utilization {
            let resetAt = window.resetsAt.flatMap { parseISO8601Flexible($0) }
            quotas[Tool.claudeCode.rawValue] = .init(fraction: max(0, (100 - util) / 100), resetAt: resetAt)
        }
        // Copilot and Antigravity: use stored QuotaRecord if available
        let descriptor = FetchDescriptor<QuotaRecord>()
        if let records = try? modelContext.fetch(descriptor) {
            for r in records {
                guard quotas[r.toolRaw] == nil,
                      let rem = r.remaining, let tot = r.total, tot > 0 else { continue }
                quotas[r.toolRaw] = .init(fraction: Double(rem) / Double(tot), resetAt: r.resetAt)
            }
        }

        NotificationService.shared.checkAndNotify(quotas: quotas)
    }

    // MARK: - Timer

    private func scheduleTimer(for tool: Tool, override: Double? = nil) {
        // Global interval takes precedence when set (> 0)
        let global = UserDefaults.standard.double(forKey: "menubar.syncIntervalGlobal")
        let stored = UserDefaults.standard.double(forKey: Self.intervalKey(for: tool))
        let interval = override ?? (global > 0 ? global : (stored > 0 ? stored : Self.defaultInterval(for: tool)))
        let clamped = max(30, interval)
        timers[tool] = Timer.scheduledTimer(withTimeInterval: clamped, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.sync(tool: tool) }
        }
    }

    // Legacy: reschedule all tools at once (used nowhere but kept for safety)
    func rescheduleTimer(interval: Double) {
        for tool in Tool.allCases { rescheduleTimer(for: tool, interval: interval) }
    }

    // MARK: - FSEvents

    private func startFSEventWatching() {
        let paths = [
            URL.homeDirectory.appending(path: ".claude/projects").path,
            URL.homeDirectory.appending(path: ".codex/sessions").path,
            URL.homeDirectory.appending(path: ".gemini/antigravity/brain").path,
            URL.homeDirectory.appending(path: ".local/share/opencode").path,
        ].filter { FileManager.default.fileExists(atPath: $0) }

        AppLogger.shared.info("Watching paths: \(paths)")
        guard !paths.isEmpty else { return }
        fsEventStream = FSEventStream(paths: paths) { [weak self] in
            // Debounce rapid file-change bursts (e.g. JSONL appends during active use)
            // into a single syncLocalFiles() call after 500 ms of silence.
            Task { @MainActor [weak self] in
                self?.fsDebounceTask?.cancel()
                self?.fsDebounceTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    await self?.syncLocalFiles()
                }
            }
        }
        fsEventStream?.start()
    }
}

// MARK: - Minimal FSEventStream wrapper

final class FSEventStream: @unchecked Sendable {
    private var streamRef: FSEventStreamRef?
    private let callback: @Sendable () -> Void

    init(paths: [String], callback: @escaping @Sendable () -> Void) {
        self.callback = callback
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        streamRef = FSEventStreamCreate(
            nil,
            { _, info, _, _, _, _ in
                guard let info else { return }
                let obj = Unmanaged<FSEventStream>.fromOpaque(info).takeUnretainedValue()
                obj.callback()
            },
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            2.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        )
    }

    func start() {
        guard let ref = streamRef else { return }
        FSEventStreamSetDispatchQueue(ref, DispatchQueue.main)
        FSEventStreamStart(ref)
    }

    func stop() {
        guard let ref = streamRef else { return }
        FSEventStreamStop(ref)
        FSEventStreamInvalidate(ref)
        FSEventStreamRelease(ref)
        streamRef = nil
    }
}
