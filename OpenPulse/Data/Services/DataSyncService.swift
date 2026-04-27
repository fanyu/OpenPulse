import Foundation
import SwiftData

// MARK: - DataSyncService

/// Orchestrates all parsers with:
///   • Per-tool independent refresh (no global lock — tools run concurrently)
///   • ConsecutiveFailureGate so transient errors don't flash-clear UI data
///   • Heavy parsing work off MainActor via Task.detached(priority: .utility)
///   • Per-category quota TTL so API-only tools (Copilot, AG quota) aren't called too often
///   • FSEvents debounce + path filtering to avoid spurious re-parses
@MainActor
@Observable
final class DataSyncService {

    // MARK: - Public observable state

    /// Per-tool sync state (replacing single global isSyncing).
    let states = SyncStateMap()

    /// Latest Codex multi-account snapshots.
    private(set) var latestCodexAccounts: [CodexAccountSnapshot] = []

    /// Latest Claude subscription quota response (nil when no subscription).
    private(set) var latestClaudeUsage: ClaudeUsageResponse?
    private(set) var latestClaudeAccountInfo: ClaudeAccountInfo?

    /// Latest Antigravity account quota list.
    private(set) var latestAntigravityAccounts: [AGAccountQuota]?

    /// Latest Copilot quota snapshots keyed by quota_id.
    private(set) var latestCopilotSnapshots: [String: CopilotSnapshot]?
    private(set) var latestCopilotResetAt: Date?
    private(set) var latestCopilotPlan: String?

    // MARK: - Configuration

    /// Minimum seconds between API quota calls per tool. Parsing local files
    /// is never rate-limited — only network API calls respect this TTL.
    private static let quotaAPITTL: [Tool: TimeInterval] = [
        .claudeCode:   600,    // Claude OAuth API — 10 min
        .copilot:     3600,    // GitHub API — 1 hour
        .antigravity:  600,    // Google API — 10 min
    ]

    // MARK: - SettingsView compatibility helpers

    /// UserDefaults key for per-tool poll interval (used by SettingsView).
    static func intervalKey(for tool: Tool) -> String { "syncInterval.\(tool.rawValue)" }

    /// Default poll interval for a tool (used by SettingsView).
    static func defaultInterval(for tool: Tool) -> Double {
        defaultPollInterval[tool] ?? 600
    }

    /// Reschedule the poll timer for a single tool (called from SettingsView).
    func rescheduleTimer(for tool: Tool, interval: Double) {
        reschedulePollTimer(for: tool, interval: interval)
    }

    // MARK: - MenuBarView compatibility helpers

    /// True when any tool is actively refreshing.
    var isSyncingActive: Bool { Tool.allCases.contains { states[$0].isRefreshing } }

    /// Most recent sync date across all tools.
    var lastSyncDate: Date? { Tool.allCases.compactMap { states[$0].lastSyncDate }.max() }

    /// First non-nil error message across all tools (for status indicator).
    var syncError: String? { Tool.allCases.compactMap { states[$0].lastError }.first }

    /// Refresh a single tool (called from MenuBarView after account switch).
    func sync(tool: Tool) async { await refreshTool(tool) }

    /// Refresh all tools (called from MenuBarView manual refresh button).
    func sync() async { await refreshAll() }

    /// Default background poll intervals per tool (seconds).
    private static let defaultPollInterval: [Tool: TimeInterval] = [
        .claudeCode:  1800,
        .codex:        300,
        .antigravity:  600,
        .copilot:     3600,
        .opencode:     300,
    ]

    /// Watched filesystem paths and which tool they belong to.
    private static let fsWatchRoots: [(path: String, tool: Tool)] = [
        (.homeDirectory + "/.claude/projects",            .claudeCode),
        (.homeDirectory + "/.config/claude/projects",     .claudeCode),
        (.homeDirectory + "/.codex/sessions",             .codex),
        (.homeDirectory + "/.gemini/antigravity/brain",   .antigravity),
        (.homeDirectory + "/.local/share/opencode",       .opencode),
    ]

    /// Claude Code bridge cache dir/file (triggers quota refresh, not session parse).
    private static let claudeBridgeRoot: String = ClaudeCodeBridgeInstaller.cacheURL
        .deletingLastPathComponent().path
    private static let claudeBridgeCachePath: String = ClaudeCodeBridgeInstaller.cacheURL.path

    /// OpenCode: only specific sub-paths are interesting.
    private static let openCodeInterestingFragments = ["/opencode.db", "/opencode.db-wal", "/log/", "/storage/session_diff/"]

    // MARK: - Private state

    private let claudeParser  = ClaudeCodeParser()
    private let codexParser   = CodexParser()
    private let antigravityParser = AntigravityParser()
    private let copilotClient = CopilotAPIClient()
    private let openCodeParser = OpenCodeParser()
    private let codexAccountService: CodexAccountService
    private var dotTextAPIService = DotTextAPIService()

    private let modelContainer: ModelContainer
    /// Dedicated read-only context for cheap lookups (hasStoredData, notifications).
    /// Reused across calls to avoid repeated context allocation overhead.
    private let readContext: ModelContext

    // Per-tool failure gates
    private var failureGates: [Tool: ConsecutiveFailureGate] = {
        Dictionary(uniqueKeysWithValues: Tool.allCases.map { ($0, ConsecutiveFailureGate()) })
    }()

    // Last successful API quota fetch time per tool (for TTL enforcement)
    private var lastQuotaAPIFetchAt: [Tool: Date] = [:]

    // Poll timers and background tasks
    private var pollTimers: [Tool: Timer] = [:]
    private var fsEventStream: FSEventStream?
    private var fsDebounceTask: Task<Void, Never>?
    private var pendingFSPaths: Set<String> = []

    // Tracks the last sync cutoff date used per-tool for incremental parsing
    private var lastParsedAt: [Tool: Date] = [:]

    // One-time flag: backfill Codex placeholder model names at most once per launch
    private var codexBackfillDone = false

    // Dot-text push debounce
    private var dotTextPushTask: Task<Void, Never>?

    // MARK: - Init / lifecycle

    init(modelContainer: ModelContainer, codexAccountService: CodexAccountService) {
        self.modelContainer = modelContainer
        self.codexAccountService = codexAccountService
        let ctx = ModelContext(modelContainer)
        ctx.autosaveEnabled = false
        self.readContext = ctx
    }

    func start() {
        purgeOrphanedQuotas()
        for tool in Tool.allCases { schedulePollTimer(for: tool) }
        startFSEventWatching()
        NotificationService.shared.requestPermission()
        Task { await refreshAll() }
    }

    func stop() {
        pollTimers.values.forEach { $0.invalidate() }
        pollTimers.removeAll()
        fsEventStream?.stop()
        fsEventStream = nil
        fsDebounceTask?.cancel()
        dotTextPushTask?.cancel()
    }

    // MARK: - Public refresh API

    /// Refresh all tools concurrently. This is the primary entry point.
    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for tool in Tool.allCases {
                group.addTask { await self.refreshTool(tool) }
            }
        }
        scheduleDotTextPush(force: true)
        checkQuotaNotifications()
    }

    /// Refresh a single tool (called by per-tool timers and FSEvents).
    func refreshTool(_ tool: Tool) async {
        guard states[tool].beginRefresh() else { return }
        defer { states[tool].endRefresh() }

        do {
            try await performToolRefresh(tool)
            states[tool].recordSuccess()
            failureGates[tool]?.recordSuccess()
            lastParsedAt[tool] = Date()
        } catch {
            let hasPriorData = hasStoredData(for: tool)
            let shouldSurface = failureGates[tool]?.shouldSurfaceError(onFailureWithPriorData: hasPriorData) ?? true
            if shouldSurface {
                states[tool].recordError(error.localizedDescription)
            } else {
                // Suppress transient error — keep showing last-known data silently
                states[tool].clearError()
            }
            AppLogger.shared.warning("[\(tool.rawValue)] refresh error (surfaced=\(shouldSurface)): \(error.localizedDescription)")
        }
    }

    // MARK: - Per-tool timer control (public for settings pane)

    func reschedulePollTimer(for tool: Tool, interval: Double) {
        pollTimers[tool]?.invalidate()
        schedulePollTimer(for: tool, override: interval)
    }

    func reschedulePollTimer(interval: Double) {
        for tool in Tool.allCases { reschedulePollTimer(for: tool, interval: interval) }
    }

    // MARK: - Private: dispatch per tool

    private func performToolRefresh(_ tool: Tool) async throws {
        // All heavy parsing runs off MainActor so the UI stays responsive.
        let context = makeWriteContext()

        switch tool {
        case .claudeCode:
            try await refreshClaudeCode(context: context)
        case .codex:
            try await refreshCodex(context: context)
        case .antigravity:
            try await refreshAntigravity(context: context)
        case .copilot:
            try await refreshCopilot(context: context)
        case .opencode:
            try await refreshOpenCode(context: context)
        }

        try context.save()
    }

    // MARK: - Claude Code

    private func refreshClaudeCode(context: ModelContext) async throws {
        // 1. Parse local files off main thread
        let since = incrementalCutoff(for: .claudeCode)
        let todayStart = Calendar.current.startOfDay(for: Date())
        let (sessions, cacheStats) = try await Task.detached(priority: .utility) {
            let sessions  = try await self.claudeParser.parseSessions(since: since)
            let stats     = (try? await self.claudeParser.parseDailyStatsFromCache()) ?? []
            return (sessions, stats)
        }.value

        upsertSessions(sessions, context: context)

        // Merge cache stats with session-derived stats so today's tokens are always present.
        // stats-cache.json may not cover today yet; sessions are always fresh.
        var mergedStats = mergeDailyStats(cacheStats, sessions: sessions, tool: .claudeCode)

        // If today still has no tokens after the merge (incremental cutoff may have skipped
        // earlier sessions), do a full scan of today's sessions to fill the gap.
        let todayHasTokens = mergedStats.contains {
            $0.date == todayStart && ($0.totalInputTokens + $0.totalOutputTokens) > 0
        }
        if !todayHasTokens {
            let todaySessions = try await Task.detached(priority: .utility) {
                try await self.claudeParser.parseSessions(since: todayStart)
            }.value
            upsertSessions(todaySessions, context: context)
            mergedStats = mergeDailyStats(mergedStats, sessions: todaySessions, tool: .claudeCode)
        }

        mergedStats.forEach { upsertDailyStats($0, context: context) }

        // 2. Account info (cheap local read, do once or on first miss)
        if latestClaudeAccountInfo == nil {
            latestClaudeAccountInfo = await claudeParser.readAccountInfo()
        }

        // 3. Quota — prefer bridge cache, fall back to API (with TTL)
        await refreshClaudeQuota(context: context)
    }

    private func refreshClaudeQuota(context: ModelContext) async {
        // Restore persisted quota on first run so UI isn't empty at launch
        if latestClaudeUsage == nil, let cached = restoredClaudeUsageCache() {
            latestClaudeUsage = cached
            upsertQuota(toolQuotaFromClaudeUsage(cached), context: context)
        }

        // Try bridge cache first (zero network cost)
        do {
            let quota = try await claudeParser.readSubscriptionQuotaFromBridge()
            if let usage = quota.raw as? ClaudeUsageResponse {
                latestClaudeUsage = usage
                persistClaudeUsageCache(usage)
            }
            upsertQuota(quota, context: context)
            return
        } catch {
            AppLogger.shared.info("[claude] bridge quota unavailable: \(error.localizedDescription); checking API TTL")
        }

        // API fallback — respect TTL
        guard isQuotaAPIEligible(for: .claudeCode) else { return }
        do {
            let quota = try await claudeParser.fetchSubscriptionQuota()
            lastQuotaAPIFetchAt[.claudeCode] = Date()
            if let usage = quota.raw as? ClaudeUsageResponse {
                latestClaudeUsage = usage
                persistClaudeUsageCache(usage)
            }
            upsertQuota(quota, context: context)
        } catch {
            lastQuotaAPIFetchAt[.claudeCode] = Date()
            AppLogger.shared.warning("[claude] API quota failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Codex

    private func refreshCodex(context: ModelContext) async throws {
        // 1. Parse local sessions + daily stats off main thread
        let since = incrementalCutoff(for: .codex)
        let needsBackfill = !codexBackfillDone && hasCodexPlaceholderModels(context: context)
        let effectiveSince: Date? = needsBackfill ? nil : since
        if needsBackfill { codexBackfillDone = true }

        let (sessions, dailyStats, rateLimitSnapshot) = try await Task.detached(priority: .utility) {
            let sessions = try await self.codexParser.parseSessions(since: effectiveSince)
            let stats    = try await self.codexParser.parseDailyStats(since: since)
            let rl       = await self.codexParser.parseLatestRateLimitsSnapshot()
            return (sessions, stats, rl)
        }.value

        upsertSessions(sessions, context: context)
        dailyStats.forEach { upsertDailyStats($0, context: context) }

        // 2. Account sync + quota
        await codexAccountService.syncCurrentSelectionFromAuthFile()
        let smartSwitch = UserDefaults.standard.bool(forKey: "codex.smartSwitch.enabled")
        let knownCount  = await codexAccountService.listAccounts().count

        var accounts: [CodexAccountSnapshot]
        if !smartSwitch,
           let snapshot = rateLimitSnapshot,
           shouldPreferLocalCodexLimits(snapshot, accountCount: knownCount)
        {
            _ = await codexAccountService.applyLocalRateLimitsToCurrentAccount(snapshot.limits)
            accounts = await codexAccountService.refreshStaleUsage(excludingCurrentAccount: true)
        } else {
            accounts = await codexAccountService.refreshAllUsage()
        }

        // Auto smart-switch
        if smartSwitch,
           let decision = try? await codexAccountService.autoSmartSwitchIfNeeded(accounts: accounts)
        {
            AppLogger.shared.warning("[codex] auto switch → \(decision.account.titleText)\(decision.usedCLIFallback ? " (CLI)" : "")")
            accounts = await codexAccountService.listAccounts()
        } else if !smartSwitch,
                  let snapshot = rateLimitSnapshot,
                  shouldPreferLocalCodexLimits(snapshot, accountCount: accounts.count)
        {
            accounts = await codexAccountService.applyLocalRateLimitsToCurrentAccount(snapshot.limits)
        }

        latestCodexAccounts = accounts
        removeStaleCodexQuotas(validAccountKeys: Set(accounts.map(\.accountID)), context: context)
        accounts.map(\.quota).forEach { upsertQuota($0, context: context) }

        // Fallback quota from local rate limits when API returned nothing
        if accounts.isEmpty,
           let limits = rateLimitSnapshot?.limits,
           isUsableCodexLimits(limits)
        {
            let fallback = ToolQuota(
                id: Tool.codex.rawValue, tool: .codex,
                accountKey: nil, accountLabel: nil,
                remaining: limits.fiveHourWindow.map { Int($0.remainingPercent) },
                total: 100, unit: .tokens,
                resetAt: limits.fiveHourWindow?.resetDate,
                updatedAt: Date(), raw: limits
            )
            upsertQuota(fallback, context: context)
        }
    }

    // MARK: - Antigravity

    private func refreshAntigravity(context: ModelContext) async throws {
        // 1. Parse local markdown files
        let since = incrementalCutoff(for: .antigravity)
        let sessions = try await Task.detached(priority: .utility) {
            try await self.antigravityParser.parseSessions(since: since)
        }.value
        upsertSessions(sessions, context: context)

        // 2. Quota API — TTL-gated
        guard isQuotaAPIEligible(for: .antigravity) else { return }
        do {
            let quota = try await antigravityParser.fetchQuota()
            lastQuotaAPIFetchAt[.antigravity] = Date()
            if let accounts = quota.raw as? [AGAccountQuota] {
                latestAntigravityAccounts = accounts
            }
            upsertQuota(quota, context: context)
        } catch {
            lastQuotaAPIFetchAt[.antigravity] = Date()
            AppLogger.shared.warning("[antigravity] quota failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Copilot

    private func refreshCopilot(context: ModelContext) async throws {
        guard isQuotaAPIEligible(for: .copilot) else { return }
        do {
            let (quota, snapshots, plan) = try await copilotClient.fetchQuota()
            lastQuotaAPIFetchAt[.copilot] = Date()
            latestCopilotSnapshots = snapshots
            latestCopilotResetAt   = quota.resetAt
            latestCopilotPlan      = plan
            upsertQuota(quota, context: context)
        } catch {
            lastQuotaAPIFetchAt[.copilot] = Date()
            AppLogger.shared.warning("[copilot] quota failed: \(error.localizedDescription)")
            throw error     // propagate so FailureGate can count it
        }
    }

    // MARK: - OpenCode

    private func refreshOpenCode(context: ModelContext) async throws {
        let since = incrementalCutoff(for: .opencode)
        let sessions = try await Task.detached(priority: .utility) {
            try await self.openCodeParser.parseSessions(since: since)
        }.value
        upsertSessions(sessions, context: context)
    }

    // MARK: - FSEvents (local-files-only, no API calls)

    /// Called by FSEvents when local files change. Runs only the parsers for the affected
    /// tools — never touches network APIs. The 500 ms debounce collapses burst writes.
    private func handleLocalFileChange(paths: [String]) {
        pendingFSPaths.formUnion(paths)
        fsDebounceTask?.cancel()
        fsDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.flushLocalFileChanges()
        }
    }

    private func flushLocalFileChanges() async {
        let paths = pendingFSPaths.sorted()
        pendingFSPaths.removeAll()
        guard !paths.isEmpty else { return }

        let affectedTools = toolsAffectedByPaths(paths)
        let bridgeTriggered = paths.contains(Self.claudeBridgeCachePath)

        await withTaskGroup(of: Void.self) { group in
            for tool in affectedTools {
                // Local-files-only refresh — skip quota API
                group.addTask { await self.refreshLocalFiles(for: tool) }
            }
        }

        if bridgeTriggered {
            let ctx = makeWriteContext()
            await refreshClaudeQuota(context: ctx)
            try? ctx.save()
        }

        // Quick FSEvents-driven Codex quota update (local rate-limit JSONL only)
        if paths.contains(where: { $0.contains("/.codex/") }) {
            await refreshCodexLocalQuotaFromFile()
        }

        scheduleDotTextPush(force: false)
    }

    private func refreshLocalFiles(for tool: Tool) async {
        guard states[tool].beginRefresh() else { return }
        defer { states[tool].endRefresh() }
        let since = incrementalCutoff(for: tool)
        let context = makeWriteContext()
        do {
            switch tool {
            case .claudeCode:
                let (sessions, stats) = try await Task.detached(priority: .utility) {
                    let s = try await self.claudeParser.parseSessions(since: since)
                    let d = (try? await self.claudeParser.parseDailyStatsFromCache()) ?? []
                    return (s, d)
                }.value
                upsertSessions(sessions, context: context)
                stats.forEach { upsertDailyStats($0, context: context) }
            case .codex:
                let needsBackfill = !codexBackfillDone && hasCodexPlaceholderModels(context: context)
                let effectiveSince: Date? = needsBackfill ? nil : since
                if needsBackfill { codexBackfillDone = true }
                let (sessions, stats) = try await Task.detached(priority: .utility) {
                    let s = try await self.codexParser.parseSessions(since: effectiveSince)
                    let d = try await self.codexParser.parseDailyStats(since: since)
                    return (s, d)
                }.value
                upsertSessions(sessions, context: context)
                stats.forEach { upsertDailyStats($0, context: context) }
            case .antigravity:
                let sessions = try await Task.detached(priority: .utility) {
                    try await self.antigravityParser.parseSessions(since: since)
                }.value
                upsertSessions(sessions, context: context)
            case .opencode:
                let sessions = try await Task.detached(priority: .utility) {
                    try await self.openCodeParser.parseSessions(since: since)
                }.value
                upsertSessions(sessions, context: context)
            case .copilot:
                break   // no local files
            }
            try context.save()
            states[tool].recordSuccess()
            failureGates[tool]?.recordSuccess()
            lastParsedAt[tool] = Date()
        } catch {
            // Local file errors are silent — stale data is better than a flash of nothing
            AppLogger.shared.warning("[\(tool.rawValue)] local file parse error (silent): \(error.localizedDescription)")
        }
    }

    /// Re-read Codex local rate-limit JSONL and apply quota without hitting the API.
    private func refreshCodexLocalQuotaFromFile() async {
        guard !UserDefaults.standard.bool(forKey: "codex.smartSwitch.enabled") else { return }
        guard let snapshot = await codexParser.parseLatestRateLimitsSnapshot() else { return }
        let accountCount = await codexAccountService.listAccounts().count
        guard shouldPreferLocalCodexLimits(snapshot, accountCount: accountCount) else { return }

        await codexAccountService.syncCurrentSelectionFromAuthFile()
        let accounts = await codexAccountService.applyLocalRateLimitsToCurrentAccount(snapshot.limits)
        let context  = makeWriteContext()
        latestCodexAccounts = accounts
        removeStaleCodexQuotas(validAccountKeys: Set(accounts.map(\.accountID)), context: context)
        accounts.map(\.quota).forEach { upsertQuota($0, context: context) }
        try? context.save()
        AppLogger.shared.recordDiagnostic(scope: "codex.localQuota", message: "updated quota from local JSONL")
    }

    // MARK: - Helpers: quota TTL

    private func isQuotaAPIEligible(for tool: Tool) -> Bool {
        guard let ttl = Self.quotaAPITTL[tool] else { return true }
        guard let last = lastQuotaAPIFetchAt[tool] else { return true }
        return Date().timeIntervalSince(last) >= ttl
    }

    // MARK: - Helpers: Codex local rate limits

    private func isUsableCodexLimits(_ limits: CodexRateLimits) -> Bool {
        [limits.fiveHourWindow, limits.oneWeekWindow]
            .compactMap { $0?.resetDate }
            .contains { $0 > Date() }
    }

    private func shouldPreferLocalCodexLimits(_ snapshot: CodexParser.LocalRateLimitSnapshot, accountCount: Int) -> Bool {
        guard isUsableCodexLimits(snapshot.limits) else { return false }
        return accountCount <= 1
    }

    // MARK: - Helpers: incremental cutoff

    /// Returns last-parsed date minus 1 h buffer so we don't miss sessions that started
    /// just before the previous parse completed.
    private func incrementalCutoff(for tool: Tool) -> Date? {
        lastParsedAt[tool].map { Calendar.current.date(byAdding: .hour, value: -1, to: $0)! }
    }

    // MARK: - Helpers: determine affected tools from FSEvent paths

    private func toolsAffectedByPaths(_ paths: [String]) -> Set<Tool> {
        var tools = Set<Tool>()
        for path in paths {
            for (root, tool) in Self.fsWatchRoots where path.hasPrefix(root) {
                tools.insert(tool)
            }
        }
        return tools
    }

    // MARK: - Helpers: SwiftData (all operate on a dedicated context)

    private static let upsertBatchYieldSize = 100

    private func makeWriteContext() -> ModelContext {
        let ctx = ModelContext(modelContainer)
        ctx.autosaveEnabled = false
        return ctx
    }

    private func upsertSessions(_ sessions: [ToolSession], context: ModelContext) {
        for session in sessions {
            let id = session.id
            var desc = FetchDescriptor<SessionRecord>(predicate: #Predicate { $0.id == id })
            desc.fetchLimit = 1
            if let existing = (try? context.fetch(desc))?.first {
                existing.inputTokens  = session.inputTokens
                existing.outputTokens = session.outputTokens
                existing.cacheReadTokens  = session.cacheReadTokens
                existing.cacheWriteTokens = session.cacheWriteTokens
                existing.endedAt = session.endedAt
                if !session.taskDescription.isEmpty { existing.taskDescription = session.taskDescription }
                if !session.model.isEmpty            { existing.model = session.model }
            } else {
                context.insert(SessionRecord(
                    id: session.id, tool: session.tool,
                    startedAt: session.startedAt, endedAt: session.endedAt,
                    inputTokens: session.inputTokens, outputTokens: session.outputTokens,
                    cacheReadTokens: session.cacheReadTokens, cacheWriteTokens: session.cacheWriteTokens,
                    taskDescription: session.taskDescription, model: session.model,
                    cwd: session.cwd, gitBranch: session.gitBranch
                ))
            }
        }
    }

    /// Merges cache-based daily stats with session-derived stats.
    /// Cache stats are preferred for historical days; sessions fill gaps (especially today).
    private func mergeDailyStats(_ cacheStats: [DailyStats], sessions: [ToolSession], tool: Tool) -> [DailyStats] {
        let calendar = Calendar.current
        // Aggregate sessions by day
        var sessionMap: [Date: (input: Int, output: Int, cacheRead: Int, count: Int)] = [:]
        for s in sessions {
            let day = calendar.startOfDay(for: s.startedAt)
            var entry = sessionMap[day] ?? (0, 0, 0, 0)
            entry.input     += s.inputTokens
            entry.output    += s.outputTokens
            entry.cacheRead += s.cacheReadTokens
            entry.count     += 1
            sessionMap[day] = entry
        }
        // Start from cache stats
        var resultMap: [Date: DailyStats] = Dictionary(uniqueKeysWithValues: cacheStats.map { ($0.date, $0) })
        // Fill in / overwrite with session data for days where sessions have more tokens
        for (day, agg) in sessionMap {
            let existing = resultMap[day]
            let existingTotal = (existing?.totalInputTokens ?? 0) + (existing?.totalOutputTokens ?? 0)
            let sessionTotal  = agg.input + agg.output
            if sessionTotal > existingTotal {
                resultMap[day] = DailyStats(
                    date: day, tool: tool,
                    totalInputTokens: agg.input,
                    totalOutputTokens: agg.output,
                    totalCacheReadTokens: agg.cacheRead,
                    sessionCount: agg.count
                )
            }
        }
        return resultMap.values.sorted { $0.date < $1.date }
    }

    private func upsertDailyStats(_ stats: DailyStats, context: ModelContext) {        let date    = stats.date
        let toolRaw = stats.tool.rawValue
        var desc = FetchDescriptor<DailyStatsRecord>(predicate: #Predicate { $0.date == date && $0.toolRaw == toolRaw })
        desc.fetchLimit = 1
        if let existing = (try? context.fetch(desc))?.first {
            existing.totalInputTokens  = stats.totalInputTokens
            existing.totalOutputTokens = stats.totalOutputTokens
            existing.totalCacheReadTokens = stats.totalCacheReadTokens
            existing.sessionCount = stats.sessionCount
        } else {
            context.insert(DailyStatsRecord(
                date: stats.date, tool: stats.tool,
                totalInputTokens: stats.totalInputTokens, totalOutputTokens: stats.totalOutputTokens,
                totalCacheReadTokens: stats.totalCacheReadTokens, sessionCount: stats.sessionCount
            ))
        }
    }

    private func upsertQuota(_ quota: ToolQuota, context: ModelContext) {
        let toolRaw    = quota.tool.rawValue
        let accountKey = quota.accountKey
        var desc = FetchDescriptor<QuotaRecord>(predicate: #Predicate { $0.toolRaw == toolRaw && $0.accountKey == accountKey })
        desc.fetchLimit = 1
        if let existing = (try? context.fetch(desc))?.first {
            existing.accountLabel = quota.accountLabel
            existing.remaining    = quota.remaining
            existing.total        = quota.total
            existing.resetAt      = quota.resetAt
            existing.updatedAt    = Date()
        } else {
            context.insert(QuotaRecord(
                tool: quota.tool, accountKey: quota.accountKey,
                accountLabel: quota.accountLabel, remaining: quota.remaining,
                total: quota.total, unit: quota.unit, resetAt: quota.resetAt
            ))
        }
    }

    private func removeStaleCodexQuotas(validAccountKeys: Set<String>, context: ModelContext) {
        let toolRaw = Tool.codex.rawValue
        let desc    = FetchDescriptor<QuotaRecord>(predicate: #Predicate { $0.toolRaw == toolRaw })
        guard let records = try? context.fetch(desc) else { return }
        for r in records {
            if let key = r.accountKey, !validAccountKeys.contains(key) { context.delete(r) }
        }
    }

    private func hasStoredData(for tool: Tool) -> Bool {
        let toolRaw = tool.rawValue
        let desc = FetchDescriptor<QuotaRecord>(predicate: #Predicate { $0.toolRaw == toolRaw })
        return ((try? readContext.fetchCount(desc)) ?? 0) > 0
    }

    private func hasCodexPlaceholderModels(context: ModelContext) -> Bool {
        let toolRaw     = Tool.codex.rawValue
        let placeholder = "openai"
        let desc = FetchDescriptor<SessionRecord>(predicate: #Predicate { $0.toolRaw == toolRaw && $0.model == placeholder })
        return ((try? context.fetchCount(desc)) ?? 0) > 0
    }

    private func purgeOrphanedQuotas() {
        let known   = Set(Tool.allCases.map(\.rawValue))
        let context = makeWriteContext()
        let desc    = FetchDescriptor<QuotaRecord>()
        guard let all = try? context.fetch(desc) else { return }
        for r in all where !known.contains(r.toolRaw) { context.delete(r) }
        try? context.save()
    }

    // MARK: - Claude usage cache helpers

    private func restoredClaudeUsageCache() -> ClaudeUsageResponse? {
        guard let data = UserDefaults.standard.data(forKey: "cached.claudeUsageData") else { return nil }
        return try? JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
    }

    private func persistClaudeUsageCache(_ usage: ClaudeUsageResponse) {
        if let data = try? JSONEncoder().encode(usage) {
            UserDefaults.standard.set(data, forKey: "cached.claudeUsageData")
        }
    }

    private func toolQuotaFromClaudeUsage(_ usage: ClaudeUsageResponse) -> ToolQuota {
        let remaining = usage.fiveHour?.utilization.map { Int((1 - $0 / 100) * 100) }
        return ToolQuota(
            id: Tool.claudeCode.rawValue, tool: .claudeCode,
            accountKey: nil, accountLabel: nil,
            remaining: remaining, total: 100, unit: .messages,
            resetAt: usage.fiveHour?.resetDate, updatedAt: Date(), raw: usage
        )
    }

    // MARK: - Poll timers

    private func schedulePollTimer(for tool: Tool, override: Double? = nil) {
        let interval = max(30, override ?? effectivePollInterval(for: tool))
        pollTimers[tool] = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refreshTool(tool) }
        }
    }

    private func effectivePollInterval(for tool: Tool) -> TimeInterval {
        let global = UserDefaults.standard.double(forKey: "menubar.syncIntervalGlobal")
        let stored = UserDefaults.standard.double(forKey: "syncInterval.\(tool.rawValue)")
        return global > 0 ? global : (stored > 0 ? stored : Self.defaultPollInterval[tool] ?? 600)
    }

    // MARK: - FSEvents

    private func startFSEventWatching() {
        var watchPaths = Self.fsWatchRoots.map(\.path).filter { FileManager.default.fileExists(atPath: $0) }
        if FileManager.default.fileExists(atPath: Self.claudeBridgeRoot) {
            watchPaths.append(Self.claudeBridgeRoot)
        }
        guard !watchPaths.isEmpty else { return }

        AppLogger.shared.info("[fs] watching: \(watchPaths)")
        fsEventStream = FSEventStream(paths: watchPaths) { [weak self] changedPaths in
            Task { @MainActor [weak self] in
                let filtered = self?.filterFSEventPaths(changedPaths) ?? []
                guard !filtered.isEmpty else { return }
                self?.handleLocalFileChange(paths: filtered)
            }
        }
        fsEventStream?.start()
    }

    /// Drop paths that are not relevant to avoid noisy re-parses.
    private func filterFSEventPaths(_ paths: [String]) -> [String] {
        paths.filter { path in
            // Bridge dir: only the specific status cache file matters
            if path.hasPrefix(Self.claudeBridgeRoot) {
                return path == Self.claudeBridgeCachePath
            }
            // OpenCode: only interesting sub-paths
            let openCodeRoot = URL.homeDirectory.appending(path: ".local/share/opencode").path
            if path.hasPrefix(openCodeRoot) {
                return Self.openCodeInterestingFragments.contains { path.contains($0) }
            }
            return true
        }
    }

    // MARK: - Dot Text push

    private func scheduleDotTextPush(force: Bool) {
        dotTextPushTask?.cancel()
        dotTextPushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.pushDotTextSnapshot(force: force)
        }
    }

    private func pushDotTextSnapshot(force: Bool) async {
        let codexRaw  = Tool.codex.rawValue
        let claudeRaw = Tool.claudeCode.rawValue
        let ctx  = readContext
        let desc = FetchDescriptor<QuotaRecord>(predicate: #Predicate { $0.toolRaw == codexRaw || $0.toolRaw == claudeRaw })
        let fallback = (try? ctx.fetch(desc)) ?? []
        await dotTextAPIService.pushQuotaSnapshot(
            codexAccounts: latestCodexAccounts,
            claudeUsage: latestClaudeUsage,
            fallbackQuotas: fallback,
            force: force
        )
    }

    // MARK: - Quota notifications

    private func checkQuotaNotifications() {
        var infos: [String: NotificationService.QuotaInfo] = [:]

        if let current = latestCodexAccounts.first(where: \.isCurrent),
           let win = current.limits?.fiveHourWindow,
           let used = win.usedPercent {
            infos[Tool.codex.rawValue] = .init(fraction: max(0, (100 - used) / 100), resetAt: win.resetDate)
        }
        if let usage = latestClaudeUsage, let win = usage.fiveHour, let util = win.utilization {
            infos[Tool.claudeCode.rawValue] = .init(fraction: max(0, (100 - util) / 100), resetAt: win.resetDate)
        }
        let ctx  = readContext
        let desc = FetchDescriptor<QuotaRecord>()
        if let records = try? ctx.fetch(desc) {
            for r in records {
                guard infos[r.toolRaw] == nil,
                      let rem = r.remaining, let tot = r.total, tot > 0 else { continue }
                infos[r.toolRaw] = .init(fraction: Double(rem) / Double(tot), resetAt: r.resetAt)
            }
        }
        NotificationService.shared.checkAndNotify(quotas: infos)
    }
}

// MARK: - Convenience: home directory string

private extension String {
    static let homeDirectory = URL.homeDirectory.path
}

// MARK: - FSEventStream (unchanged wrapper)

final class FSEventStream: @unchecked Sendable {
    private var streamRef: FSEventStreamRef?
    private let callback: @Sendable ([String]) -> Void

    init(paths: [String], callback: @escaping @Sendable ([String]) -> Void) {
        self.callback = callback
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        streamRef = FSEventStreamCreate(
            nil,
            { _, info, _, eventPaths, _, _ in
                guard let info else { return }
                let obj   = Unmanaged<FSEventStream>.fromOpaque(info).takeUnretainedValue()
                let paths = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
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
