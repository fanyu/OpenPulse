import Foundation
import SwiftData

/// Orchestrates all parsers: FSEvents file watching + periodic polling.
@MainActor
@Observable
final class DataSyncService {
    private struct SyncSourceError: LocalizedError {
        let source: String
        let path: String?
        let underlying: Error

        var errorDescription: String? { underlying.localizedDescription }
    }

    private enum SyncStateError: LocalizedError {
        case stalled(seconds: Int)

        var errorDescription: String? {
            switch self {
            case .stalled(let seconds):
                "同步已卡住超过 \(seconds) 秒，已允许重新刷新。"
            }
        }
    }

    private static let staleSyncThreshold: TimeInterval = 45
    private static let upsertYieldBatchSize = 100
    private static let localFileMinimumInterval: TimeInterval = 10
    private static let localFileFailureBackoff: TimeInterval = 30
    private static let localFilePathSilenceDuration: TimeInterval = 300
    private static let claudeLocalRoots = [
        URL.homeDirectory.appending(path: ".claude/projects").path,
        URL.homeDirectory.appending(path: ".config/claude/projects").path,
    ]
    private static let codexLocalRoots = [
        URL.homeDirectory.appending(path: ".codex/sessions").path,
    ]
    private static let antigravityLocalRoots = [
        URL.homeDirectory.appending(path: ".gemini/antigravity/brain").path,
    ]
    private static let openCodeLocalRoots = [
        URL.homeDirectory.appending(path: ".local/share/opencode").path,
    ]

    private(set) var isSyncing = false
    private(set) var lastSyncDate: Date?
    private(set) var syncError: Error?
    private var syncStartedAt: Date?
    private var activeSyncID: UUID?
    private var currentSyncPhase: String?
    private var currentSyncPhaseStartedAt: Date?
    private var lastLocalFileSyncAt: Date?
    private var localFileSyncBlockedUntil: Date = .distantPast
    private var pendingLocalFilePaths: Set<String> = []
    private var silencedLocalFailureKeys: [String: Date] = [:]

    /// 最新的 Codex 多账户额度列表
    private(set) var latestCodexAccounts: [CodexAccountSnapshot] = []

    /// 最新的 Claude 订阅配额响应（来自 Claude Code bridge status JSON）；无订阅时为 nil
    private(set) var latestClaudeUsage: ClaudeUsageResponse?
    private(set) var latestClaudeAccountInfo: ClaudeAccountInfo?
    private var lastClaudeAPIFetchAt: Date?

    /// 最新的 Antigravity 账号配额列表（每个账号含所有模型，推荐模型优先）
    private(set) var latestAntigravityAccounts: [AGAccountQuota]?

    /// 最新的 Copilot quota snapshots（keyed by quota_id）
    private(set) var latestCopilotSnapshots: [String: CopilotSnapshot]?

    /// Copilot 账号配额重置日期（来自 quota_reset_date_utc）
    private(set) var latestCopilotResetAt: Date?
    private(set) var latestCopilotPlan: String?

    private let claudeParser = ClaudeCodeParser()
    private let codexParser = CodexParser()
    private let codexAccountService: CodexAccountService
    private let antigravityParser = AntigravityParser()
    private let copilotClient = CopilotAPIClient()
    private let openCodeParser = OpenCodeParser()
    private var dotTextAPIService = DotTextAPIService()

    private var timers: [Tool: Timer] = [:]
    private var toolSyncRetryTasks: [Tool: Task<Void, Never>] = [:]
    private var fsEventStream: FSEventStream?
    private var fsDebounceTask: Task<Void, Never>?
    private var localFileSyncRetryTask: Task<Void, Never>?
    private var dotTextPushTask: Task<Void, Never>?
    /// Set to true after the first Codex full scan completes. Prevents re-scanning
    /// every FSEvents trigger when some sessions permanently lack JSONL model data.
    private var codexBackfillDone: Bool = false

    private let modelContainer: ModelContainer
    private var modelContext: ModelContext

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

    init(modelContainer: ModelContainer, codexAccountService: CodexAccountService) {
        self.modelContainer = modelContainer
        self.modelContext = DataSyncService.makeWriteContext(container: modelContainer)
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
        rebuildWriteContext()
    }

    func stop() {
        timers.values.forEach { $0.invalidate() }
        timers.removeAll()
        toolSyncRetryTasks.values.forEach { $0.cancel() }
        toolSyncRetryTasks.removeAll()
        localFileSyncRetryTask?.cancel()
        localFileSyncRetryTask = nil
        dotTextPushTask?.cancel()
        dotTextPushTask = nil
        fsEventStream?.stop()
        fsEventStream = nil
    }

    var isSyncingActive: Bool {
        guard isSyncing, let syncStartedAt else { return false }
        return Date().timeIntervalSince(syncStartedAt) < Self.staleSyncThreshold
    }

    private func beginSyncRun(scope: String, allowStaleRecovery: Bool) -> UUID? {
        if isSyncing {
            guard let syncStartedAt else {
                isSyncing = false
                activeSyncID = nil
                currentSyncPhase = nil
                currentSyncPhaseStartedAt = nil
                syncError = SyncStateError.stalled(seconds: Int(Self.staleSyncThreshold))
                AppLogger.shared.error("Sync state reset: missing start time while marked syncing")
                return nil
            }

            let elapsed = Date().timeIntervalSince(syncStartedAt)
            if !allowStaleRecovery || elapsed < Self.staleSyncThreshold {
                AppLogger.shared.recordDiagnostic(
                    level: .info,
                    scope: "sync.skip",
                    message: "\(scope) skipped while another sync is active (\(Int(elapsed.rounded()))s)"
                )
                return nil
            }

            syncError = SyncStateError.stalled(seconds: Int(elapsed.rounded()))
            AppLogger.shared.error("Previous sync considered stalled after \(Int(elapsed.rounded()))s; starting a new cycle for \(scope)")
        }

        let runID = UUID()
        activeSyncID = runID
        syncStartedAt = Date()
        isSyncing = true
        return runID
    }

    private func endSyncRun(_ runID: UUID) {
        finishCurrentPhase()
        if activeSyncID == runID {
            isSyncing = false
            syncStartedAt = nil
            activeSyncID = nil
            currentSyncPhase = nil
            currentSyncPhaseStartedAt = nil
        }
    }

    func sync() async {
        guard let runID = beginSyncRun(scope: "full-sync", allowStaleRecovery: true) else { return }
        syncError = nil
        AppLogger.shared.info("Sync started at \(Date())")
        AppLogger.shared.recordDiagnostic(scope: "sync.start", message: "full sync started")
        defer { endSyncRun(runID) }

        do {
            try await syncClaudeCode()
            try await syncCodex()
            try await syncAntigravity()
            await syncCopilot()
            try await syncOpenCode()
            try persistModelContext(scope: "full-sync", tool: nil)
            syncError = nil
            lastSyncDate = Date()
            let count = (try? modelContext.fetchCount(FetchDescriptor<SessionRecord>())) ?? 0
            AppLogger.shared.info("Sync completed. Total sessions in DB: \(count)")
            if let syncStartedAt {
                let elapsed = Date().timeIntervalSince(syncStartedAt)
                AppLogger.shared.recordDiagnostic(scope: "sync.finish", message: "full sync finished in \(Int(elapsed.rounded()))s, sessions=\(count)")
            }
            checkQuotaNotifications()
            scheduleDotTextQuotaPush()
        } catch {
            syncError = error
            AppLogger.shared.error("Sync error: \(error)")
            AppLogger.shared.recordSyncError(
                scope: "full-sync",
                tool: nil,
                error: error,
                source: syncErrorSource(error),
                path: syncErrorPath(error),
                details: syncErrorDetails(error)
            )
        }
    }

    /// Sync a single tool and save. Used by per-tool timers.
    func sync(tool: Tool) async {
        guard let runID = beginSyncRun(scope: "tool-sync:\(tool.rawValue)", allowStaleRecovery: false) else {
            scheduleToolSyncRetry(for: tool)
            return
        }
        toolSyncRetryTasks[tool]?.cancel()
        toolSyncRetryTasks[tool] = nil
        syncError = nil
        AppLogger.shared.recordDiagnostic(scope: "sync.tool.start", message: "\(tool.rawValue) sync started")
        defer { endSyncRun(runID) }
        do {
            switch tool {
            case .claudeCode:   try await syncClaudeCode()
            case .codex:        try await syncCodex()
            case .antigravity:  try await syncAntigravity()
            case .copilot:      await syncCopilot()
            case .opencode:     try await syncOpenCode()
            }
            try persistModelContext(scope: "tool-sync:\(tool.rawValue)", tool: tool)
            syncError = nil
            lastSyncDate = Date()
            AppLogger.shared.recordDiagnostic(scope: "sync.tool.finish", message: "\(tool.rawValue) sync finished")
            if tool == .codex || tool == .claudeCode {
                scheduleDotTextQuotaPush()
            }
        } catch {
            syncError = error
            AppLogger.shared.error("Sync error (\(tool.rawValue)): \(error)")
            AppLogger.shared.recordSyncError(
                scope: "tool-sync",
                tool: tool,
                error: error,
                source: syncErrorSource(error),
                path: syncErrorPath(error),
                details: syncErrorDetails(error)
            )
        }
    }

    private func scheduleToolSyncRetry(for tool: Tool) {
        guard toolSyncRetryTasks[tool] == nil else { return }
        toolSyncRetryTasks[tool] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.toolSyncRetryTasks[tool] = nil
            AppLogger.shared.recordDiagnostic(
                scope: "sync.tool.retry",
                message: "\(tool.rawValue) retrying after skipped timer sync"
            )
            await self?.sync(tool: tool)
        }
    }

    func rescheduleTimer(for tool: Tool, interval: Double) {
        timers[tool]?.invalidate()
        scheduleTimer(for: tool, override: interval)
    }

    // MARK: - Per-tool sync

    /// Parses Claude's local files only (stats-cache.json + JSONL). No network.
    private func parseClaudeFiles(since: Date?) async throws {
        startPhase("claude.local")
        let cachedStats = (try? await claudeParser.parseDailyStatsFromCache()) ?? []
        AppLogger.shared.info("ClaudeCode: parsed \(cachedStats.count) cached daily stats")
        try await upsertDailyStats(cachedStats, label: "claude.dailyStats")

        let sessions = try await claudeParser.parseSessions(since: since)
        AppLogger.shared.info("ClaudeCode: parsed \(sessions.count) sessions")
        try await upsertSessions(sessions, label: "claude.sessions")
        finishCurrentPhase()
    }

    /// Parses Antigravity's local markdown files only. No network.
    private func parseAntigravityFiles(since: Date?) async throws {
        startPhase("antigravity.local")
        let sessions = try await antigravityParser.parseSessions(since: since)
        AppLogger.shared.info("Antigravity: parsed \(sessions.count) sessions")
        try await upsertSessions(sessions, label: "antigravity.sessions")
        finishCurrentPhase()
    }

    /// Full Claude sync: local files + Claude Code bridge quota cache.
    private func syncClaudeCode() async throws {
        let since = lastSyncDate.map { Calendar.current.date(byAdding: .hour, value: -1, to: $0)! }
        try await parseClaudeFiles(since: since)
        if latestClaudeAccountInfo == nil {
            latestClaudeAccountInfo = await claudeParser.readAccountInfo()
        }
        await syncClaudeQuota()
    }

    private func syncClaudeQuota() async {
        startPhase("claude.quota")
        // Restore last-known bridge data from disk so the UI can show the most recent Claude quota on launch.
        if latestClaudeUsage == nil,
           let cached = UserDefaults.standard.data(forKey: "cached.claudeUsageData"),
           let restored = try? JSONDecoder().decode(ClaudeUsageResponse.self, from: cached) {
            latestClaudeUsage = restored
            // Also keep SwiftData QuotaRecord in sync with the cached data
            // so the card's fallback path has something to show even when latestClaudeUsage
            // later gets cleared (e.g. after app restart where cache decode fails).
            upsertQuota(toolQuota(from: restored))
        }

        do {
            let quota = try await claudeParser.readSubscriptionQuotaFromBridge()
            if let usage = quota.raw as? ClaudeUsageResponse {
                latestClaudeUsage = usage
                if let data = try? JSONEncoder().encode(usage) {
                    UserDefaults.standard.set(data, forKey: "cached.claudeUsageData")
                }
            }
            upsertQuota(quota)
        } catch {
            AppLogger.shared.warning("Claude bridge quota unavailable: \(error.localizedDescription)")
            await syncClaudeQuotaFromAPIIfNeeded()
        }
        finishCurrentPhase()
    }

    private func syncClaudeQuotaFromAPIIfNeeded() async {
        let now = Date()
        let minimumInterval = effectiveSyncInterval(for: .claudeCode)
        if let lastClaudeAPIFetchAt,
           now.timeIntervalSince(lastClaudeAPIFetchAt) < minimumInterval {
            AppLogger.shared.recordDiagnostic(
                level: .info,
                scope: "claude.quota.api.skip",
                message: "Claude API fallback throttled for \(Int((minimumInterval - now.timeIntervalSince(lastClaudeAPIFetchAt)).rounded()))s"
            )
            return
        }

        do {
            let quota = try await claudeParser.fetchSubscriptionQuota()
            lastClaudeAPIFetchAt = now
            if let usage = quota.raw as? ClaudeUsageResponse {
                latestClaudeUsage = usage
                if let data = try? JSONEncoder().encode(usage) {
                    UserDefaults.standard.set(data, forKey: "cached.claudeUsageData")
                }
            }
            upsertQuota(quota)
            AppLogger.shared.info("Claude quota refreshed via API fallback")
        } catch {
            lastClaudeAPIFetchAt = now
            AppLogger.shared.warning("Claude API quota fallback failed: \(error.localizedDescription)")
        }
    }

    /// Build a ToolQuota from a ClaudeUsageResponse.
    private func toolQuota(from usage: ClaudeUsageResponse) -> ToolQuota {
        let fiveHour = usage.fiveHour
        let remaining = fiveHour.map { Int((1.0 - ($0.utilization ?? 0) / 100.0) * 100) }
        let resetAt = fiveHour?.resetDate
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
        try await parseCodexFiles(since: since)
        let localLimits = await codexParser.parseLatestRateLimits()
        let smartSwitchEnabled = UserDefaults.standard.bool(forKey: "codex.smartSwitch.enabled")

        startPhase("codex.accounts")
        await codexAccountService.syncCurrentSelectionFromAuthFile()
        let accounts: [CodexAccountSnapshot]
        if !smartSwitchEnabled, let localLimits, isUsableCodexLocalRateLimits(localLimits) {
            _ = await codexAccountService.applyLocalRateLimitsToCurrentAccount(localLimits)
            accounts = await codexAccountService.refreshStaleUsage(excludingCurrentAccount: true)
            AppLogger.shared.info("Codex: using local rate limits from session JSONL")
        } else {
            accounts = await codexAccountService.refreshAllUsage()
        }

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
        try await upsertQuotas(latestCodexAccounts.map(\.quota), label: "codex.quotas")
        finishCurrentPhase()

        if latestCodexAccounts.isEmpty, let limits = localLimits, isUsableCodexLocalRateLimits(limits) {
            startPhase("codex.fallbackQuota")
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
            finishCurrentPhase()
        }
    }

    private func syncCodexLocalQuotaIfNeeded(triggeredPaths: [String]) async throws {
        let shouldRefreshCodexQuota = triggeredPaths.contains { $0.contains("/.codex/") }
        guard shouldRefreshCodexQuota else { return }

        let smartSwitchEnabled = UserDefaults.standard.bool(forKey: "codex.smartSwitch.enabled")
        guard !smartSwitchEnabled else {
            AppLogger.shared.recordDiagnostic(
                scope: "codex.localQuota.skip",
                message: "local Codex quota skipped while smart switch is enabled"
            )
            return
        }

        guard let localLimits = await codexParser.parseLatestRateLimits(),
              isUsableCodexLocalRateLimits(localLimits) else {
            AppLogger.shared.recordDiagnostic(
                scope: "codex.localQuota.skip",
                message: "no usable local Codex rate limits after file event"
            )
            return
        }

        startPhase("codex.localQuota")
        await codexAccountService.syncCurrentSelectionFromAuthFile()
        latestCodexAccounts = await codexAccountService.applyLocalRateLimitsToCurrentAccount(localLimits)
        removeStaleCodexQuotas(validAccountKeys: Set(latestCodexAccounts.map(\.accountID)))
        try await upsertQuotas(latestCodexAccounts.map(\.quota), label: "codex.localQuota")
        AppLogger.shared.recordDiagnostic(
            scope: "codex.localQuota",
            message: "updated Codex quota from local session JSONL"
        )
        finishCurrentPhase()
    }

    private func isUsableCodexLocalRateLimits(_ limits: CodexRateLimits) -> Bool {
        [limits.fiveHourWindow, limits.oneWeekWindow]
            .compactMap(\.?.resetDate)
            .contains { $0 > Date() }
    }

    private func parseCodexFiles(since: Date?) async throws {
        startPhase("codex.local")

        // Full scan to backfill placeholder model names — done at most once per launch.
        // After the scan (even if some records remain un-fixable), we stop forcing full
        // scans so that FSEvents-triggered syncs don't re-scan thousands of sessions.
        let needsBackfill = !codexBackfillDone && hasCodexPlaceholderModels()
        let effectiveSince: Date? = needsBackfill ? nil : since
        if needsBackfill { codexBackfillDone = true }

        let sessions = try await codexParser.parseSessions(since: effectiveSince)
        AppLogger.shared.info("Codex: parsed \(sessions.count) sessions (fullScan=\(needsBackfill))")
        try await upsertSessions(sessions, label: "codex.sessions")

        let stats = try await codexParser.parseDailyStats(since: since)
        try await upsertDailyStats(stats, label: "codex.dailyStats")
        finishCurrentPhase()
    }

    /// Full Antigravity sync: local markdown files + Google OAuth quota API.
    private func syncAntigravity() async throws {
        let since = lastSyncDate.map { Calendar.current.date(byAdding: .hour, value: -1, to: $0)! }
        try await parseAntigravityFiles(since: since)

        do {
            startPhase("antigravity.quota")
            let quota = try await antigravityParser.fetchQuota()
            if let accounts = quota.raw as? [AGAccountQuota] {
                latestAntigravityAccounts = accounts
            }
            upsertQuota(quota)
            finishCurrentPhase()
        } catch {
            AppLogger.shared.warning("Antigravity quota skipped: \(error.localizedDescription)")
            finishCurrentPhase()
        }
    }

    /// Local-files-only sync — called by FSEvents on every file change.
    /// Parses JSONL/SQLite/markdown but never touches any network API,
    /// so frequent file writes during active use can't trigger rate limits.
    private func syncLocalFiles() async {
        let now = Date()
        pruneExpiredSilencedLocalFailures(referenceDate: now)
        let triggeredPaths = pendingLocalFilePaths.sorted()
        let activeTriggeredPaths = triggeredPaths.filter { !isSilencedLocalFailureKey($0, referenceDate: now) }
        if !triggeredPaths.isEmpty, activeTriggeredPaths.isEmpty {
            pendingLocalFilePaths.subtract(triggeredPaths)
            AppLogger.shared.recordDiagnostic(
                level: .info,
                scope: "sync.local.skip",
                message: "all triggered paths silenced for \(Int(Self.localFilePathSilenceDuration / 60))m"
            )
            return
        }
        if now < localFileSyncBlockedUntil {
            scheduleLocalFileSyncRetry(after: localFileSyncBlockedUntil.timeIntervalSince(now))
            AppLogger.shared.recordDiagnostic(
                level: .info,
                scope: "sync.local.skip",
                message: "local file sync blocked for \(Int(localFileSyncBlockedUntil.timeIntervalSince(now).rounded()))s"
            )
            return
        }
        if let lastLocalFileSyncAt,
           now.timeIntervalSince(lastLocalFileSyncAt) < Self.localFileMinimumInterval {
            scheduleLocalFileSyncRetry(after: Self.localFileMinimumInterval - now.timeIntervalSince(lastLocalFileSyncAt))
            AppLogger.shared.recordDiagnostic(
                level: .info,
                scope: "sync.local.skip",
                message: "local file sync throttled"
            )
            return
        }
        guard let runID = beginSyncRun(scope: "local-files", allowStaleRecovery: false) else {
            scheduleLocalFileSyncRetry(after: 10)
            return
        }
        localFileSyncRetryTask?.cancel()
        localFileSyncRetryTask = nil
        pendingLocalFilePaths.subtract(triggeredPaths)
        lastLocalFileSyncAt = now
        AppLogger.shared.recordDiagnostic(
            scope: "sync.local.start",
            message: "local file sync started\(activeTriggeredPaths.isEmpty ? "" : " · paths=\(activeTriggeredPaths.prefix(4).joined(separator: ", "))")"
        )
        defer { endSyncRun(runID) }
        let since = lastSyncDate.map { Calendar.current.date(byAdding: .hour, value: -1, to: $0)! }
        let shouldSyncClaude = activeTriggeredPaths.isEmpty || shouldSyncLocalTool(paths: activeTriggeredPaths, roots: Self.claudeLocalRoots)
        let shouldSyncCodex = activeTriggeredPaths.isEmpty || shouldSyncLocalTool(paths: activeTriggeredPaths, roots: Self.codexLocalRoots)
        let shouldSyncAntigravity = activeTriggeredPaths.isEmpty || shouldSyncLocalTool(paths: activeTriggeredPaths, roots: Self.antigravityLocalRoots)
        let shouldSyncOpenCode = activeTriggeredPaths.isEmpty || shouldSyncLocalTool(paths: activeTriggeredPaths, roots: Self.openCodeLocalRoots)
        do {
            if shouldSyncClaude {
                try await parseClaudeFiles(since: since)
            }
            if shouldSyncCodex {
                try await parseCodexFiles(since: since)
            }
            try await syncCodexLocalQuotaIfNeeded(triggeredPaths: activeTriggeredPaths)
            if shouldSyncAntigravity {
                try await parseAntigravityFiles(since: since)
            }
            if shouldSyncOpenCode {
                try await syncOpenCode()
            }
            try persistModelContext(scope: "local-files", tool: nil)
            syncError = nil
            lastSyncDate = Date()
            AppLogger.shared.recordDiagnostic(scope: "sync.local.finish", message: "local file sync finished")
            scheduleDotTextQuotaPush()
        } catch {
            localFileSyncBlockedUntil = Date().addingTimeInterval(Self.localFileFailureBackoff)
            let silencedKey = localFailureSilenceKey(error: error, triggeredPaths: activeTriggeredPaths)
            if let silencedKey {
                let silencedUntil = Date().addingTimeInterval(Self.localFilePathSilenceDuration)
                silencedLocalFailureKeys[silencedKey] = silencedUntil
                AppLogger.shared.recordDiagnostic(
                    level: .warning,
                    scope: "sync.local.silence",
                    message: "silenced \(silencedKey) for \(Int(Self.localFilePathSilenceDuration / 60))m after repeated file-open failure"
                )
            }
            AppLogger.shared.error("Local file sync error: \(error)")
            syncError = error
            AppLogger.shared.recordSyncError(
                scope: "local-files",
                tool: nil,
                error: error,
                source: syncErrorSource(error),
                path: syncErrorPath(error) ?? activeTriggeredPaths.first,
                details: syncErrorDetails(error, triggeredPaths: activeTriggeredPaths)
            )
            AppLogger.shared.recordDiagnostic(
                level: .warning,
                scope: "sync.local.backoff",
                message: "local file sync backoff \(Int(Self.localFileFailureBackoff))s after error: \(error.localizedDescription)"
            )
        }
    }

    private func scheduleLocalFileSyncRetry(after delay: TimeInterval) {
        guard localFileSyncRetryTask == nil else { return }
        localFileSyncRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(max(1, delay) * 1000)))
            guard !Task.isCancelled else { return }
            self?.localFileSyncRetryTask = nil
            guard self?.pendingLocalFilePaths.isEmpty == false else { return }
            AppLogger.shared.recordDiagnostic(
                scope: "sync.local.retry",
                message: "retrying local file sync after throttle"
            )
            await self?.syncLocalFiles()
        }
    }

    private func syncCopilot() async {
        do {
            startPhase("copilot.quota")
            let (quota, snapshots, plan) = try await copilotClient.fetchQuota()
            latestCopilotSnapshots = snapshots
            latestCopilotResetAt = quota.resetAt
            latestCopilotPlan = plan
            upsertQuota(quota)
            finishCurrentPhase()
        } catch {
            AppLogger.shared.warning("Copilot quota skipped: \(error.localizedDescription)")
            finishCurrentPhase()
        }
    }

    private func syncOpenCode() async throws {
        startPhase("opencode.local")
        let since = lastSyncDate.map { Calendar.current.date(byAdding: .hour, value: -1, to: $0)! }
        let sessions = try await openCodeParser.parseSessions(since: since)
        AppLogger.shared.info("OpenCode: parsed \(sessions.count) sessions")
        try await upsertSessions(sessions, label: "opencode.sessions")
        finishCurrentPhase()
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

    private func upsertSessions(_ sessions: [ToolSession], label: String) async throws {
        guard !sessions.isEmpty else { return }
        let start = Date()
        for (index, session) in sessions.enumerated() {
            upsertSession(session)
            if index.isMultiple(of: Self.upsertYieldBatchSize) {
                await Task.yield()
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        if elapsed >= 1 {
            AppLogger.shared.recordDiagnostic(scope: "upsert.sessions", message: "\(label) inserted/updated \(sessions.count) sessions in \(String(format: "%.2f", elapsed))s")
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

    private func upsertDailyStats(_ stats: [DailyStats], label: String) async throws {
        guard !stats.isEmpty else { return }
        let start = Date()
        for (index, item) in stats.enumerated() {
            upsertDailyStats(item)
            if index.isMultiple(of: Self.upsertYieldBatchSize) {
                await Task.yield()
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        if elapsed >= 1 {
            AppLogger.shared.recordDiagnostic(scope: "upsert.dailyStats", message: "\(label) upserted \(stats.count) rows in \(String(format: "%.2f", elapsed))s")
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

    private func upsertQuotas(_ quotas: [ToolQuota], label: String) async throws {
        guard !quotas.isEmpty else { return }
        let start = Date()
        for (index, quota) in quotas.enumerated() {
            upsertQuota(quota)
            if index.isMultiple(of: Self.upsertYieldBatchSize) {
                await Task.yield()
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        if elapsed >= 1 {
            AppLogger.shared.recordDiagnostic(scope: "upsert.quotas", message: "\(label) upserted \(quotas.count) rows in \(String(format: "%.2f", elapsed))s")
        }
    }

    private func startPhase(_ name: String) {
        finishCurrentPhase()
        currentSyncPhase = name
        currentSyncPhaseStartedAt = Date()
        AppLogger.shared.info("Sync phase started: \(name)")
    }

    private func finishCurrentPhase() {
        guard let currentSyncPhase, let currentSyncPhaseStartedAt else { return }
        let elapsed = Date().timeIntervalSince(currentSyncPhaseStartedAt)
        AppLogger.shared.info("Sync phase finished: \(currentSyncPhase) in \(String(format: "%.2f", elapsed))s")
        if elapsed >= 2 {
            AppLogger.shared.recordDiagnostic(
                level: elapsed >= 10 ? .warning : .info,
                scope: "sync.phase",
                message: "\(currentSyncPhase) took \(String(format: "%.2f", elapsed))s"
            )
        }
        self.currentSyncPhase = nil
        self.currentSyncPhaseStartedAt = nil
    }

    private func persistModelContext(scope: String, tool: Tool?) throws {
        startPhase("model-save")
        do {
            try modelContext.save()
            rebuildWriteContext()
            finishCurrentPhase()
        } catch {
            let wrapped = SyncSourceError(source: "model-save", path: nil, underlying: error)
            finishCurrentPhase()
            if isTransientFileAccessError(error) {
                AppLogger.shared.warning("Transient model save skipped during \(scope): \(error.localizedDescription)")
                AppLogger.shared.recordDiagnostic(
                    level: .warning,
                    scope: "sync.modelSave.skip",
                    message: "scope=\(scope) tool=\(tool?.rawValue ?? "none") details=\(syncErrorDetails(wrapped))"
                )
                return
            }
            throw wrapped
        }
    }

    private static func makeWriteContext(container: ModelContainer) -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    private func rebuildWriteContext() {
        modelContext = Self.makeWriteContext(container: modelContainer)
    }

    private func isTransientFileAccessError(_ error: Error) -> Bool {
        let nsError = error as NSError
        let description = error.localizedDescription.lowercased()
        if description.contains("the file couldn’t be opened") || description.contains("the file couldn't be opened") {
            return true
        }
        if description.contains("unable to open database file") || description.contains("sqlite.result error 0") {
            return true
        }
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoSuchFileError {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == 2 {
            return true
        }
        return false
    }

    private func shouldSyncLocalTool(paths: [String], roots: [String]) -> Bool {
        paths.contains { path in
            roots.contains { root in
                path.hasPrefix(root)
            }
        }
    }

    private func syncErrorSource(_ error: Error) -> String {
        if let syncSourceError = error as? SyncSourceError {
            return syncSourceError.source
        }
        return currentSyncPhase ?? "unknown"
    }

    private func syncErrorPath(_ error: Error) -> String? {
        if let syncSourceError = error as? SyncSourceError {
            return syncSourceError.path
        }
        return nil
    }

    private func syncErrorDetails(_ error: Error, triggeredPaths: [String] = []) -> String {
        let nsError = error as NSError
        var parts: [String] = [
            "domain=\(nsError.domain)",
            "code=\(nsError.code)",
            "phase=\(currentSyncPhase ?? "none")"
        ]
        if let syncSourceError = error as? SyncSourceError, let path = syncSourceError.path {
            parts.append("path=\(path)")
        }
        if !triggeredPaths.isEmpty {
            parts.append("triggered=\(triggeredPaths.prefix(4).joined(separator: ","))")
        }
        return parts.joined(separator: " · ")
    }

    private func localFailureSilenceKey(error: Error, triggeredPaths: [String]) -> String? {
        if let path = syncErrorPath(error) {
            return path
        }
        if let firstTriggeredPath = triggeredPaths.first {
            return firstTriggeredPath
        }
        let source = syncErrorSource(error)
        return source == "unknown" ? nil : source
    }

    private func isSilencedLocalFailureKey(_ key: String, referenceDate: Date) -> Bool {
        guard let blockedUntil = silencedLocalFailureKeys[key] else { return false }
        return blockedUntil > referenceDate
    }

    private func pruneExpiredSilencedLocalFailures(referenceDate: Date) {
        silencedLocalFailureKeys = silencedLocalFailureKeys.filter { $0.value > referenceDate }
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

    // MARK: - Dot Text API

    private func scheduleDotTextQuotaPush() {
        dotTextPushTask?.cancel()
        dotTextPushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.pushDotTextQuotaSnapshot()
        }
    }

    private func pushDotTextQuotaSnapshot() async {
        let codexRaw = Tool.codex.rawValue
        let claudeRaw = Tool.claudeCode.rawValue
        let descriptor = FetchDescriptor<QuotaRecord>(
            predicate: #Predicate { $0.toolRaw == codexRaw || $0.toolRaw == claudeRaw }
        )
        let fallbackQuotas = (try? modelContext.fetch(descriptor)) ?? []
        await dotTextAPIService.pushQuotaSnapshot(
            codexAccounts: latestCodexAccounts,
            claudeUsage: latestClaudeUsage,
            fallbackQuotas: fallbackQuotas
        )
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
            quotas[Tool.claudeCode.rawValue] = .init(fraction: max(0, (100 - util) / 100), resetAt: window.resetDate)
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
        let clamped = max(30, override ?? effectiveSyncInterval(for: tool))
        timers[tool] = Timer.scheduledTimer(withTimeInterval: clamped, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.sync(tool: tool) }
        }
    }

    private func effectiveSyncInterval(for tool: Tool) -> Double {
        let global = UserDefaults.standard.double(forKey: "menubar.syncIntervalGlobal")
        let stored = UserDefaults.standard.double(forKey: Self.intervalKey(for: tool))
        return global > 0 ? global : (stored > 0 ? stored : Self.defaultInterval(for: tool))
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
        fsEventStream = FSEventStream(paths: paths) { [weak self] changedPaths in
            // Debounce rapid file-change bursts (e.g. JSONL appends during active use)
            // into a single syncLocalFiles() call after 500 ms of silence.
            Task { @MainActor [weak self] in
                self?.pendingLocalFilePaths.formUnion(changedPaths)
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
    private let callback: @Sendable ([String]) -> Void

    init(paths: [String], callback: @escaping @Sendable ([String]) -> Void) {
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
            { _, info, _, eventPathsPointer, _, _ in
                guard let info else { return }
                let obj = Unmanaged<FSEventStream>.fromOpaque(info).takeUnretainedValue()
                let paths = (unsafeBitCast(eventPathsPointer, to: NSArray.self) as? [String]) ?? []
                obj.callback(paths)
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
