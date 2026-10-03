import Foundation
import SwiftData

// MARK: - DataSyncService

/// Orchestrates all parsers with:
///   • Per-tool independent refresh (no global lock — tools run concurrently)
///   • ConsecutiveFailureGate so transient errors don't flash-clear UI data
///   • Heavy parsing work off MainActor via Task.detached(priority: .utility)
///   • FSEvents debounce + path filtering to avoid spurious re-parses
@MainActor
@Observable
final class DataSyncService {

    // MARK: - Public observable state

    /// Per-tool sync state (replacing single global isSyncing).
    let states = SyncStateMap()

    /// Invalidates derived usage caches after a successful usage write, including
    /// in-place updates that leave SwiftData query counts unchanged.
    private(set) var dataRevision: UInt64 = 0

    /// Latest Codex multi-account snapshots.
    private(set) var latestCodexAccounts: [CodexAccountSnapshot] = []

    /// Latest Claude subscription quota response (nil when no subscription).
    private(set) var latestClaudeUsage: ClaudeUsageResponse?
    private(set) var latestClaudeQuotaObservedAt: Date?
    private(set) var latestClaudeAccountInfo: ClaudeAccountInfo?

    /// Latest Antigravity account quota list.
    private(set) var latestAntigravityAccounts: [AGAccountQuota]?
    private(set) var refreshingAntigravityAccountEmails: Set<String> = []

    /// Latest Copilot quota snapshots keyed by quota_id.
    private(set) var latestCopilotSnapshots: [String: CopilotSnapshot]?
    private(set) var latestCopilotResetAt: Date?
    private(set) var latestCopilotPlan: String?

    // MARK: - MenuBarView compatibility helpers

    /// True when any tool is actively refreshing.
    var isSyncingActive: Bool { isRefreshAllInFlight || Tool.allCases.contains { states[$0].isRefreshing } }

    /// Most recent sync date across all tools.
    var lastSyncDate: Date? { Tool.allCases.compactMap { states[$0].lastSyncDate }.max() }

    /// First non-nil error message across all tools (for status indicator).
    var syncError: String? { Tool.allCases.compactMap { states[$0].lastError }.first }

    /// Refresh a single tool (called from MenuBarView after account switch).
    func sync(tool: Tool) async { await refreshTool(tool) }

    /// Refresh all tools (called from MenuBarView manual refresh button).
    func sync() async { await refreshAll() }

    /// Read back a committed account switch without another API request or relaunch.
    func reloadCodexAccountSnapshots() async throws {
        let accounts = try await codexAccountService.listAccounts()
        latestCodexAccounts = accounts
    }

    func refreshAntigravityAccount(email: String) async {
        guard !refreshingAntigravityAccountEmails.contains(email) else { return }
        await performQuotaOnlyRefresh(for: .antigravity) {
            self.refreshingAntigravityAccountEmails.insert(email)
            defer { self.refreshingAntigravityAccountEmails.remove(email) }
            let account = try await antigravityParser.fetchQuota(forAccountEmail: email)
            let merged = mergeAntigravityAccounts(
                current: latestAntigravityAccounts ?? [],
                refreshed: [account],
                orderedEmails: antigravityOrderedEmails(current: latestAntigravityAccounts ?? [], refreshed: [account])
            )
            let context = makeWriteContext()
            upsertQuota(antigravityAggregateQuota(from: merged), context: context)
            try saveUsageContext(context)
            latestAntigravityAccounts = merged
            Self.persistAntigravityAccountsCache(merged, defaults: cacheDefaults)
            return true
        }
    }

    /// Default background poll intervals per tool (seconds).
    static let defaultPollInterval: [Tool: TimeInterval] = [
        .claudeCode:   300,
        .codex:        300,
        .antigravity:  180,
        .copilot:     3600,
    ]

    /// Watched filesystem paths and which tool they belong to.
    private static let fsWatchRoots: [(path: String, tool: Tool)] = [
        (.homeDirectory + "/.claude/projects",            .claudeCode),
        (.homeDirectory + "/.config/claude/projects",     .claudeCode),
        (.homeDirectory + "/.codex/config.toml",          .codex),
        (.homeDirectory + "/.codex/sessions",             .codex),
        (.homeDirectory + "/.codex/codex-router/merged-models.json", .codex),
        (.homeDirectory + "/.gemini/antigravity/brain",   .antigravity),
    ]

    /// Claude Code bridge cache dir/file (triggers quota refresh, not session parse).
    private static let claudeBridgeRoot: String = ClaudeCodeBridgeInstaller.cacheURL
        .deletingLastPathComponent().path
    private static let claudeBridgeCachePath: String = ClaudeCodeBridgeInstaller.cacheURL.path
    private static let claudeDesktopRoot: String = .homeDirectory + "/Library/Application Support/Claude"
    private static let claudeDesktopBuddyTokensPath: String = claudeDesktopRoot + "/buddy-tokens.json"

    // MARK: - Private state

    private let claudeParser: ClaudeCodeParser
    private let codexParser   = CodexParser()
    private let antigravityParser: AntigravityParser
    private let copilotClient = CopilotAPIClient()
    private let codexAccountService: CodexAccountService
    private let deskSnapshotPublisher: DeskSnapshotPublisher?
    private let cacheDefaults: UserDefaults
    @ObservationIgnored private let postRefreshOverride: (@MainActor (Tool?) async -> Void)?
    @ObservationIgnored private let antigravityQuotaFetchOverride: (@MainActor () async throws -> AGQuotaFetchResult)?
    private var dotTextAPIService = DotTextAPIService()

    private let modelContainer: ModelContainer
    /// Dedicated read-only context for cheap lookups (hasStoredData, notifications).
    /// Reused across calls to avoid repeated context allocation overhead.
    private var readContext: ModelContext

    // Per-tool failure gates
    private var failureGates: [Tool: ConsecutiveFailureGate] = {
        Dictionary(uniqueKeysWithValues: Tool.allCases.map { ($0, ConsecutiveFailureGate()) })
    }()

    // Poll timers and background tasks
    private var pollTimers: [Tool: Timer] = [:]
    private var fsEventStream: FSEventStream?
    private var fsDebounceTask: Task<Void, Never>?
    private var pendingFSPaths: Set<String> = []
    private var pendingLocalRefreshTools: Set<Tool> = []
    private var pendingBridgeQuotaRefresh = false
    private var pendingCodexLocalQuotaRefresh = false
    @ObservationIgnored private var localCatchUpTasks: [Tool: Task<Void, Never>] = [:]
    @ObservationIgnored private var localWorkGeneration: UInt64 = 0
    private var acceptingLocalEvents = true
    private var isRefreshAllInFlight = false

    // Tracks the last sync cutoff date used per-tool for incremental parsing
    private var lastParsedAt: [Tool: Date] = [:]

    // One-time flag: backfill Codex placeholder model names at most once per launch
    private var codexBackfillDone = false

    // Dot-text push debounce
    @ObservationIgnored private var dotTextPushTask: Task<Void, Never>?
    @ObservationIgnored private var deskSnapshotPublishDebouncer: DeskSnapshotPublishDebouncer?

    // MARK: - Init / lifecycle

    init(
        modelContainer: ModelContainer,
        codexAccountService: CodexAccountService,
        deskSnapshotPublisher: DeskSnapshotPublisher? = DeskSnapshotPublisher.makeIfAvailable(),
        restoreCachedSnapshots: Bool = true,
        claudeParser: ClaudeCodeParser = ClaudeCodeParser(),
        antigravityParser: AntigravityParser = AntigravityParser(),
        cacheDefaults: UserDefaults = .standard,
        postRefresh: (@MainActor (Tool?) async -> Void)? = nil,
        antigravityQuotaFetch: (@MainActor () async throws -> AGQuotaFetchResult)? = nil
    ) {
        self.modelContainer = modelContainer
        self.codexAccountService = codexAccountService
        self.claudeParser = claudeParser
        self.antigravityParser = antigravityParser
        self.deskSnapshotPublisher = deskSnapshotPublisher
        self.cacheDefaults = cacheDefaults
        self.postRefreshOverride = postRefresh
        self.antigravityQuotaFetchOverride = antigravityQuotaFetch
        self.latestAntigravityAccounts = restoreCachedSnapshots ? Self.restoredAntigravityAccountsCache(defaults: cacheDefaults) : nil
        self.latestClaudeUsage = restoreCachedSnapshots ? Self.restoredClaudeUsageCache(defaults: cacheDefaults) : nil
        self.latestClaudeQuotaObservedAt = restoreCachedSnapshots ? cacheDefaults.object(forKey: "cached.claudeQuotaObservedAt") as? Date : nil
        let ctx = ModelContext(modelContainer)
        ctx.autosaveEnabled = false
        self.readContext = ctx
        if deskSnapshotPublisher != nil {
            self.deskSnapshotPublishDebouncer = DeskSnapshotPublishDebouncer(delay: .milliseconds(500)) { [weak self] in
                await self?.publishDeskSnapshotIfNeeded()
            }
        }
    }

    func start() {
        acceptingLocalEvents = true
        purgeLegacyRefreshPreferences()
        purgeOrphanedQuotas()
        for tool in Tool.allCases { schedulePollTimer(for: tool) }
        startFSEventWatching()
        if UserDefaults.standard.bool(forKey: "notifications.enabled") {
            NotificationService.shared.requestPermission()
        }
        Task { await refreshAll() }
    }

    func stop() {
        acceptingLocalEvents = false
        pollTimers.values.forEach { $0.invalidate() }
        pollTimers.removeAll()
        fsEventStream?.stop()
        fsEventStream = nil
        fsDebounceTask?.cancel()
        fsDebounceTask = nil
        clearPendingLocalRefreshes()
        dotTextPushTask?.cancel()
        Task { await deskSnapshotPublishDebouncer?.cancel() }
    }

    // MARK: - Public refresh API

    /// Refresh all tools concurrently. This is the primary entry point.
    func refreshAll() async {
        guard !isRefreshAllInFlight else { return }
        isRefreshAllInFlight = true
        defer {
            isRefreshAllInFlight = false
        }
        await withTaskGroup(of: Void.self) { group in
            for tool in Tool.allCases {
                group.addTask { await self.refreshTool(tool) }
            }
        }
        await publishAfterSuccessfulRefresh()
    }

    /// Refresh a single tool (called by per-tool timers and FSEvents).
    func refreshTool(_ tool: Tool) async {
        guard states[tool].beginRefresh() else { return }
        defer { endRefreshAndScheduleLocalCatchUp(for: tool) }

        do {
            try await performToolRefresh(tool)
            states[tool].recordSuccess()
            failureGates[tool]?.recordSuccess()
            lastParsedAt[tool] = Date()
            if !isRefreshAllInFlight {
                await publishAfterSuccessfulRefresh(for: tool)
            }
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

    /// Quota-only work owns the same per-tool gate as polling and session imports.
    /// An accepted, saved snapshot advances sync time, never the session parse cursor.
    func performQuotaOnlyRefresh(for tool: Tool, onBusy: (@MainActor () -> Void)? = nil, operation: @MainActor () async throws -> Bool) async {
        guard !Task.isCancelled else { return }
        guard states[tool].beginRefresh() else { onBusy?(); return }
        defer { endRefreshAndScheduleLocalCatchUp(for: tool) }
        do {
            guard try await operation() else { return }
            states[tool].recordSuccess()
            failureGates[tool]?.recordSuccess()
            if !isRefreshAllInFlight {
                await publishAfterSuccessfulRefresh(for: tool)
            }
        } catch {
            // Keep the last successful snapshot and error state on local read failures.
            AppLogger.shared.warning("[\(tool.rawValue)] quota-only refresh failed: \(error.localizedDescription)")
        }
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
            return // Local tasks and quota have independent save boundaries.
        case .copilot:
            try await refreshCopilot(context: context)
        }

        try saveUsageContext(context)
    }

    /// Shared save boundary; failed saves never announce a new usage snapshot.
    func saveUsageContext(_ context: ModelContext) throws {
        let usageChanged = (context.insertedModelsArray + context.changedModelsArray + context.deletedModelsArray)
            .contains { $0 is SessionRecord || $0 is DailyStatsRecord }
        try context.save()
        readContext = makeWriteContext()
        if usageChanged { dataRevision &+= 1 }
    }

    func usageCacheWasCleared() {
        fsDebounceTask?.cancel()
        fsDebounceTask = nil
        clearPendingLocalRefreshes()
        lastParsedAt.removeAll()
        codexBackfillDone = false
        latestCodexAccounts = []
        latestClaudeUsage = nil
        latestClaudeQuotaObservedAt = nil
        latestClaudeAccountInfo = nil
        latestAntigravityAccounts = nil
        latestCopilotSnapshots = nil
        latestCopilotResetAt = nil
        latestCopilotPlan = nil
        readContext = makeWriteContext()
        for tool in Tool.allCases {
            states[tool].reset()
            failureGates[tool]?.reset()
        }
        for key in ["cached.claudeUsageData", "cached.claudeQuotaObservedAt", "cached.antigravityAccountsData", "cached.codexLimitsData"] {
            cacheDefaults.removeObject(forKey: key)
        }
        dataRevision &+= 1
    }

    // MARK: - Claude Code

    private func refreshClaudeCode(context: ModelContext) async throws {
        // 1. Parse local files off main thread
        let since = incrementalCutoff(for: .claudeCode)
        let todayStart = Calendar.current.startOfDay(for: Date())
        let (sessions, cacheStats) = try await Task.detached(priority: .utility) {
            let sessions  = try await self.claudeParser.parseSessions(since: since)
            let cliStats  = (try? await self.claudeParser.parseDailyStatsFromCache()) ?? []
            let desktopStats = (try? await self.claudeParser.parseDailyStatsFromClaudeDesktop()) ?? []
            return (sessions, cliStats + desktopStats)
        }.value

        try await upsertSessions(sessions, context: context)

        // Merge cache stats with session-derived stats so today's tokens are always present.
        // stats-cache.json may not cover today yet; sessions are always fresh.
        var mergedStats = try mergeDailyStats(cacheStats, sessions: sessions, tool: .claudeCode, context: context)

        // If today still has no tokens after the merge (incremental cutoff may have skipped
        // earlier sessions), do a full scan of today's sessions to fill the gap.
        let todayHasTokens = mergedStats.contains {
            $0.date == todayStart && ($0.totalInputTokens + $0.totalOutputTokens) > 0
        }
        if !todayHasTokens {
            let todaySessions = try await Task.detached(priority: .utility) {
                try await self.claudeParser.parseSessions(since: todayStart)
            }.value
            try await upsertSessions(todaySessions, context: context)
            mergedStats = try mergeDailyStats(mergedStats, sessions: todaySessions, tool: .claudeCode, context: context)
        }

        mergedStats.forEach { upsertDailyStats($0, context: context) }

        // 2. Account info (cheap local read, do once or on first miss)
        if latestClaudeAccountInfo == nil {
            latestClaudeAccountInfo = await claudeParser.readAccountInfo()
        }

        // 3. Quota — prefer bridge cache, fall back to API
        await refreshClaudeQuota(context: context)
    }

    private func refreshClaudeQuota(context: ModelContext) async {
        // Restore persisted quota on first run so UI isn't empty at launch
        if latestClaudeUsage == nil, let cached = Self.restoredClaudeUsageCache(defaults: cacheDefaults) {
            latestClaudeUsage = cached
            latestClaudeQuotaObservedAt = cacheDefaults.object(forKey: "cached.claudeQuotaObservedAt") as? Date
            upsertQuota(toolQuotaFromClaudeUsage(cached), context: context)
        }

        // Try bridge cache first (zero network cost)
        do {
            let quota = try await claudeParser.readSubscriptionQuotaFromBridge()
            if let usage = quota.raw as? ClaudeUsageResponse {
                latestClaudeUsage = usage
                latestClaudeQuotaObservedAt = quota.updatedAt
                persistClaudeUsageCache(usage, observedAt: quota.updatedAt)
            }
            upsertQuota(quota, context: context)
            return
        } catch {
            AppLogger.shared.info("[claude] bridge quota unavailable: \(error.localizedDescription); falling back to API")
        }

        // API fallback when bridge cache is unavailable
        do {
            let quota = try await claudeParser.fetchSubscriptionQuotaFromClaudeDesktop()
            if let usage = quota.raw as? ClaudeUsageResponse {
                latestClaudeUsage = usage
                latestClaudeQuotaObservedAt = quota.updatedAt
                persistClaudeUsageCache(usage, observedAt: quota.updatedAt)
            }
            upsertQuota(quota, context: context)
            return
        } catch {
            AppLogger.shared.info("[claude] desktop quota unavailable: \(error.localizedDescription); falling back to CLI OAuth API")
        }

        // CLI OAuth API fallback when desktop usage is unavailable
        do {
            let quota = try await claudeParser.fetchSubscriptionQuota()
            if let usage = quota.raw as? ClaudeUsageResponse {
                latestClaudeUsage = usage
                latestClaudeQuotaObservedAt = quota.updatedAt
                persistClaudeUsageCache(usage, observedAt: quota.updatedAt)
            }
            upsertQuota(quota, context: context)
        } catch {
            AppLogger.shared.warning("[claude] API quota failed: \(error.localizedDescription)")
        }
    }

    /// File events consume bridge data only; unavailable caches await the normal poll.
    func refreshClaudeQuotaFromBridge() async {
        await performQuotaOnlyRefresh(for: .claudeCode, onBusy: { self.pendingBridgeQuotaRefresh = true }) {
            let quota = try await claudeParser.readSubscriptionQuotaFromBridge()
            try Task.checkCancellation()
            let context = makeWriteContext()
            upsertQuota(quota, context: context)
            try saveUsageContext(context)
            if let usage = quota.raw as? ClaudeUsageResponse {
                latestClaudeUsage = usage
                latestClaudeQuotaObservedAt = quota.updatedAt
                persistClaudeUsageCache(usage, observedAt: quota.updatedAt)
            }
            return true
        }
    }

    // MARK: - Codex

    private func refreshCodex(context: ModelContext) async throws {
        // 1. Parse local sessions + daily stats off main thread
        let since = incrementalCutoff(for: .codex)
        let needsBackfill = !codexBackfillDone && hasCodexPlaceholderModels(context: context)
        let effectiveSince: Date? = needsBackfill ? nil : since

        let (sessions, dailyStats, rateLimitSnapshot) = try await Task.detached(priority: .utility) {
            let sessions = try await self.codexParser.parseSessions(since: effectiveSince)
            let stats    = try await self.codexParser.parseDailyStats(since: since)
            let rl       = await self.codexParser.parseLatestRateLimitsSnapshot()
            return (sessions, stats, rl)
        }.value

        try await upsertSessions(sessions, context: context)
        if needsBackfill && !sessions.isEmpty { codexBackfillDone = true }
        dailyStats.forEach { upsertDailyStats($0, context: context) }

        // 2. Account sync + quota
        try await codexAccountService.syncCurrentSelectionFromAuthFile()
        let smartSwitch = UserDefaults.standard.bool(forKey: "codex.smartSwitch.enabled")
        let knownCount  = try await codexAccountService.listAccounts().count
        let currentHasResetCreditDetails = try await codexAccountService.currentAccountHasResetCreditDetails()

        var accounts: [CodexAccountSnapshot]
        if !smartSwitch,
           currentHasResetCreditDetails,
           let snapshot = rateLimitSnapshot,
           shouldPreferLocalCodexLimits(snapshot, accountCount: knownCount)
        {
            _ = try await codexAccountService.refreshCurrentUsage(force: true)
            _ = try await codexAccountService.applyLocalRateLimitsToCurrentAccount(snapshot.limits)
            accounts = try await codexAccountService.refreshStaleUsage(excludingCurrentAccount: true)
        } else {
            accounts = try await codexAccountService.refreshAllUsage()
        }

        // Auto smart-switch
        if smartSwitch,
           let decision = try? await codexAccountService.autoSmartSwitchIfNeeded(accounts: accounts)
        {
            AppLogger.shared.warning("[codex] auto switch → \(decision.account.titleText)\(decision.usedCLIFallback ? " (CLI)" : "")")
            accounts = try await codexAccountService.listAccounts()
        } else if !smartSwitch,
                  let snapshot = rateLimitSnapshot,
                  shouldPreferLocalCodexLimits(snapshot, accountCount: accounts.count)
        {
            accounts = try await codexAccountService.applyLocalRateLimitsToCurrentAccount(snapshot.limits)
        }

        latestCodexAccounts = accounts
        removeStaleCodexQuotas(validAccountKeys: Set(accounts.map(\.accountID)), context: context)
        accounts.compactMap(\.generalQuota).forEach { upsertQuota($0, context: context) }

        // Fallback quota from local rate limits when API returned nothing
        if accounts.isEmpty,
           let limits = rateLimitSnapshot?.limits,
           limits.hasUsableGeneralWindow()
        {
            let fallback = ToolQuota(
                id: Tool.codex.rawValue, tool: .codex,
                accountKey: nil, accountLabel: nil,
                remaining: limits.fiveHourWindow?.remainingPercent.map { Int($0) },
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
        try await upsertSessions(sessions, context: context)
        try Task.checkCancellation()
        try saveUsageContext(context)
        lastParsedAt[.antigravity] = Date()

        // 2. Quota API
        do {
            let result: AGQuotaFetchResult
            if let antigravityQuotaFetchOverride {
                result = try await antigravityQuotaFetchOverride()
            } else {
                result = try await antigravityParser.fetchAllAccountQuotas()
            }
            try Task.checkCancellation()
            let refreshedEmails = Set(result.accounts.map(\.email))
            let failedEmails = result.orderedEmails.filter { !refreshedEmails.contains($0) }
            let mergedAccounts = mergeAntigravityAccounts(
                current: latestAntigravityAccounts ?? [],
                refreshed: result.accounts,
                orderedEmails: result.orderedEmails
            )
            // A partial response includes older retained accounts. Do not give the
            // aggregate a new observation time until every credentialed account succeeds.
            let observedAt: Date
            if failedEmails.isEmpty {
                observedAt = Date()
            } else {
                let toolRaw = Tool.antigravity.rawValue
                var previous = FetchDescriptor<QuotaRecord>(predicate: #Predicate { $0.toolRaw == toolRaw && $0.accountKey == nil })
                previous.fetchLimit = 1
                observedAt = try context.fetch(previous).first?.updatedAt ?? .distantPast
            }
            upsertQuota(antigravityAggregateQuota(from: mergedAccounts, observedAt: observedAt), context: context)
            try saveUsageContext(context)
            latestAntigravityAccounts = mergedAccounts
            Self.persistAntigravityAccountsCache(mergedAccounts, defaults: cacheDefaults)
            if !failedEmails.isEmpty {
                throw AntigravityError.apiFailed("Quota refresh failed for \(failedEmails.count) of \(result.orderedEmails.count) accounts.")
            }
        } catch {
            AppLogger.shared.warning("[antigravity] quota failed: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Copilot

    private func refreshCopilot(context: ModelContext) async throws {
        do {
            let (quota, snapshots, plan) = try await copilotClient.fetchQuota()
            latestCopilotSnapshots = snapshots
            latestCopilotResetAt   = quota.resetAt
            latestCopilotPlan      = plan
            upsertQuota(quota, context: context)
        } catch {
            AppLogger.shared.warning("[copilot] quota failed: \(error.localizedDescription)")
            throw error     // propagate so FailureGate can count it
        }
    }

    // MARK: - FSEvents (local-files-only, no API calls)

    /// Called by FSEvents when local files change. Runs only the parsers for the affected
    /// tools — never touches network APIs. The 500 ms debounce collapses burst writes.
    func handleLocalFileChange(paths: [String]) {
        guard acceptingLocalEvents else { return }
        pendingFSPaths.formUnion(paths)
        fsDebounceTask?.cancel()
        fsDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.flushLocalFileChanges()
        }
    }

    func flushLocalFileChanges() async {
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
            await refreshClaudeQuotaFromBridge()
        }

        // Quick FSEvents-driven Codex quota update (local rate-limit JSONL only)
        if paths.contains(where: { $0.contains("/.codex/") }) {
            await refreshCodexLocalQuotaFromFile()
        }

    }

    func refreshLocalFiles(for tool: Tool) async {
        guard !Task.isCancelled else { return }
        guard states[tool].beginRefresh() else {
            pendingLocalRefreshTools.insert(tool)
            return
        }
        defer { endRefreshAndScheduleLocalCatchUp(for: tool) }
        let since = incrementalCutoff(for: tool)
        let context = makeWriteContext()
        do {
            switch tool {
            case .claudeCode:
                let (sessions, stats) = try await Task.detached(priority: .utility) {
                    let s = try await self.claudeParser.parseSessions(since: since)
                    let d = (try? await self.claudeParser.parseDailyStatsFromCache()) ?? []
                    let desktop = (try? await self.claudeParser.parseDailyStatsFromClaudeDesktop()) ?? []
                    return (s, d + desktop)
                }.value
                try await upsertSessions(sessions, context: context)
                try mergeDailyStats(stats, sessions: sessions, tool: .claudeCode, context: context)
                    .forEach { upsertDailyStats($0, context: context) }
            case .codex:
                let needsBackfill = !codexBackfillDone && hasCodexPlaceholderModels(context: context)
                let effectiveSince: Date? = needsBackfill ? nil : since
                let (sessions, stats) = try await Task.detached(priority: .utility) {
                    let s = try await self.codexParser.parseSessions(since: effectiveSince)
                    let d = try await self.codexParser.parseDailyStats(since: since)
                    return (s, d)
                }.value
                try await upsertSessions(sessions, context: context)
                if needsBackfill && !sessions.isEmpty { codexBackfillDone = true }
                stats.forEach { upsertDailyStats($0, context: context) }
            case .antigravity:
                let sessions = try await Task.detached(priority: .utility) {
                    try await self.antigravityParser.parseSessions(since: since)
                }.value
                try await upsertSessions(sessions, context: context)
            case .copilot:
                break   // no local files
            }
            try Task.checkCancellation()
            try saveUsageContext(context)
            states[tool].recordSuccess()
            failureGates[tool]?.recordSuccess()
            lastParsedAt[tool] = Date()
            if !isRefreshAllInFlight {
                await publishAfterSuccessfulRefresh(for: tool)
            }
        } catch {
            // Local file errors are silent — stale data is better than a flash of nothing
            AppLogger.shared.warning("[\(tool.rawValue)] local file parse error (silent): \(error.localizedDescription)")
        }
    }

    /// Re-read Codex local rate-limit JSONL and apply quota without hitting the API.
    private func refreshCodexLocalQuotaFromFile() async {
        await performQuotaOnlyRefresh(for: .codex, onBusy: { self.pendingCodexLocalQuotaRefresh = true }) {
            guard !UserDefaults.standard.bool(forKey: "codex.smartSwitch.enabled") else { return false }
            guard let snapshot = await codexParser.parseLatestRateLimitsSnapshot() else { return false }
            let accountCount = try await codexAccountService.listAccounts().count
            guard shouldPreferLocalCodexLimits(snapshot, accountCount: accountCount) else { return false }

            try await codexAccountService.syncCurrentSelectionFromAuthFile()
            try Task.checkCancellation()
            let accounts = try await codexAccountService.applyLocalRateLimitsToCurrentAccount(snapshot.limits)
            try Task.checkCancellation()
            let context = makeWriteContext()
            removeStaleCodexQuotas(validAccountKeys: Set(accounts.map(\.accountID)), context: context)
            accounts.compactMap(\.generalQuota).forEach { upsertQuota($0, context: context) }
            try saveUsageContext(context)
            latestCodexAccounts = accounts
            AppLogger.shared.recordDiagnostic(scope: "codex.localQuota", message: "updated quota from local JSONL")
            return true
        }
    }

    private func endRefreshAndScheduleLocalCatchUp(for tool: Tool) {
        states[tool].endRefresh()
        scheduleLocalCatchUp(for: tool)
    }

    private func hasPendingLocalRefresh(for tool: Tool) -> Bool {
        pendingLocalRefreshTools.contains(tool)
            || (tool == .claudeCode && pendingBridgeQuotaRefresh)
            || (tool == .codex && pendingCodexLocalQuotaRefresh)
    }

    private func scheduleLocalCatchUp(for tool: Tool) {
        guard acceptingLocalEvents, !states[tool].isRefreshing, hasPendingLocalRefresh(for: tool), localCatchUpTasks[tool] == nil else { return }
        let generation = localWorkGeneration
        localCatchUpTasks[tool] = Task { [weak self] in
            guard let self else { return }
            await Task.yield()
            if !Task.isCancelled, self.localWorkGeneration == generation, !self.states[tool].isRefreshing {
                let parseLocalFiles = self.pendingLocalRefreshTools.remove(tool) != nil
                let readBridge = tool == .claudeCode && self.pendingBridgeQuotaRefresh
                let readCodexQuota = tool == .codex && self.pendingCodexLocalQuotaRefresh
                if readBridge { self.pendingBridgeQuotaRefresh = false }
                if readCodexQuota { self.pendingCodexLocalQuotaRefresh = false }
                if parseLocalFiles { await self.refreshLocalFiles(for: tool) }
                if readBridge { await self.refreshClaudeQuotaFromBridge() }
                if readCodexQuota { await self.refreshCodexLocalQuotaFromFile() }
            }
            guard self.localWorkGeneration == generation else { return }
            self.localCatchUpTasks[tool] = nil
            if !Task.isCancelled { self.scheduleLocalCatchUp(for: tool) }
        }
    }

    private func clearPendingLocalRefreshes() {
        localWorkGeneration &+= 1
        localCatchUpTasks.values.forEach { $0.cancel() }
        localCatchUpTasks.removeAll()
        pendingFSPaths.removeAll()
        pendingLocalRefreshTools.removeAll()
        pendingBridgeQuotaRefresh = false
        pendingCodexLocalQuotaRefresh = false
    }

    /// Await the already scheduled, bounded local work without starting a poll.
    func awaitLocalCatchUps() async {
        let tasks = Array(localCatchUpTasks.values)
        for task in tasks { await task.value }
    }

    // MARK: - Helpers: Codex local rate limits

    private func isUsableCodexLimits(_ limits: CodexRateLimits) -> Bool {
        limits.hasUsableKnownWindow()
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

    func toolsAffectedByPaths(_ paths: [String]) -> Set<Tool> {
        var tools = Set<Tool>()
        for path in paths {
            if path == Self.claudeDesktopRoot || path.hasPrefix(Self.claudeDesktopRoot + "/") {
                tools.insert(.claudeCode)
            }
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

    func upsertSessions(_ sessions: [ToolSession], context: ModelContext) async throws {
        for start in stride(from: 0, to: sessions.count, by: Self.upsertBatchYieldSize) {
            let batch = Array(sessions[start..<min(start + Self.upsertBatchYieldSize, sessions.count)])
            let ids = batch.map(\.id)
            let desc = FetchDescriptor<SessionRecord>(predicate: #Predicate { ids.contains($0.id) })
            let records = try context.fetch(desc)
            var existingByID = records.reduce(into: [UUID: SessionRecord]()) { $0[$1.id] = $1 }
            for session in batch {
                if let existing = existingByID[session.id] {
                    if existing.inputTokens != session.inputTokens { existing.inputTokens = session.inputTokens }
                    if existing.outputTokens != session.outputTokens { existing.outputTokens = session.outputTokens }
                    if existing.cacheReadTokens != session.cacheReadTokens { existing.cacheReadTokens = session.cacheReadTokens }
                    if existing.cacheWriteTokens != session.cacheWriteTokens { existing.cacheWriteTokens = session.cacheWriteTokens }
                    if existing.endedAt != session.endedAt { existing.endedAt = session.endedAt }
                    if !session.taskDescription.isEmpty && existing.taskDescription != session.taskDescription { existing.taskDescription = session.taskDescription }
                    if !session.model.isEmpty && existing.model != session.model { existing.model = session.model }
                    if !session.cwd.isEmpty && existing.cwd != session.cwd { existing.cwd = session.cwd }
                    if existing.gitBranch != session.gitBranch { existing.gitBranch = session.gitBranch }
                } else {
                    let record = SessionRecord(
                        id: session.id, tool: session.tool,
                        startedAt: session.startedAt, endedAt: session.endedAt,
                        inputTokens: session.inputTokens, outputTokens: session.outputTokens,
                        cacheReadTokens: session.cacheReadTokens, cacheWriteTokens: session.cacheWriteTokens,
                        taskDescription: session.taskDescription, model: session.model,
                        cwd: session.cwd, gitBranch: session.gitBranch
                    )
                    context.insert(record)
                    existingByID[session.id] = record
                }
            }
            // Yield between bounded batches rather than blocking the UI for an import.
            await Task.yield()
        }
    }

    /// Merges cache-based daily stats with session-derived stats.
    /// Cache stats are preferred for historical days; sessions fill gaps (especially today).
    private func mergeDailyStats(_ cacheStats: [DailyStats], sessions: [ToolSession], tool: Tool, context: ModelContext) throws -> [DailyStats] {
        let calendar = Calendar.current
        // Incremental files are not complete daily totals. Include already imported
        // conversations for each affected range before replacing persisted day rows.
        var sourceSessions = sessions
        if let first = sessions.map(\.startedAt).min(), let last = sessions.map(\.startedAt).max() {
            let start = calendar.startOfDay(for: first)
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: last))!
            let toolRaw = tool.rawValue
            let desc = FetchDescriptor<SessionRecord>(predicate: #Predicate { $0.toolRaw == toolRaw && $0.startedAt >= start && $0.startedAt < end })
            sourceSessions = try context.fetch(desc).map { record in
                ToolSession(id: record.id, tool: tool, startedAt: record.startedAt, endedAt: record.endedAt,
                            inputTokens: record.inputTokens, outputTokens: record.outputTokens,
                            cacheReadTokens: record.cacheReadTokens, cacheWriteTokens: record.cacheWriteTokens,
                            taskDescription: record.taskDescription, model: record.model, cwd: record.cwd, gitBranch: record.gitBranch)
            }
        }
        // Aggregate sessions by day
        var sessionMap: [Date: (input: Int, output: Int, cacheRead: Int, count: Int)] = [:]
        for s in sourceSessions {
            let day = calendar.startOfDay(for: s.startedAt)
            var entry = sessionMap[day] ?? (0, 0, 0, 0)
            entry.input     += s.inputTokens
            entry.output    += s.outputTokens
            entry.cacheRead += s.cacheReadTokens
            entry.count     += 1
            sessionMap[day] = entry
        }
        // Start from cache stats. Multiple local sources can report the same day
        // (Claude CLI cache + Claude Desktop buddy-tokens); keep the larger total.
        var resultMap: [Date: DailyStats] = [:]
        for stat in cacheStats {
            let existingTotal = resultMap[stat.date]?.totalTokens ?? 0
            if stat.totalTokens > existingTotal {
                resultMap[stat.date] = stat
            }
        }
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
            if existing.totalInputTokens != stats.totalInputTokens { existing.totalInputTokens = stats.totalInputTokens }
            if existing.totalOutputTokens != stats.totalOutputTokens { existing.totalOutputTokens = stats.totalOutputTokens }
            if existing.totalCacheReadTokens != stats.totalCacheReadTokens { existing.totalCacheReadTokens = stats.totalCacheReadTokens }
            if existing.sessionCount != stats.sessionCount { existing.sessionCount = stats.sessionCount }
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
            existing.updatedAt    = quota.updatedAt
        } else {
            let record = QuotaRecord(
                tool: quota.tool, accountKey: quota.accountKey,
                accountLabel: quota.accountLabel, remaining: quota.remaining,
                total: quota.total, unit: quota.unit, resetAt: quota.resetAt
            )
            record.updatedAt = quota.updatedAt
            context.insert(record)
        }
    }

    private func mergeAntigravityAccounts(
        current: [AGAccountQuota],
        refreshed: [AGAccountQuota],
        orderedEmails: [String]
    ) -> [AGAccountQuota] {
        let currentByEmail = Dictionary(uniqueKeysWithValues: current.map { ($0.email, $0) })
        let refreshedByEmail = Dictionary(uniqueKeysWithValues: refreshed.map { ($0.email, $0) })

        return orderedEmails.compactMap { email in
            switch (currentByEmail[email], refreshedByEmail[email]) {
            case let (_, refreshedAccount?):
                refreshedAccount
            case let (currentAccount?, _):
                currentAccount
            default:
                nil
            }
        }
    }

    private func antigravityOrderedEmails(current: [AGAccountQuota], refreshed: [AGAccountQuota]) -> [String] {
        var seen = Set<String>()
        var emails: [String] = []
        for email in current.map(\.email) + refreshed.map(\.email) where seen.insert(email).inserted {
            emails.append(email)
        }
        return emails
    }

    private func antigravityAggregateQuota(from accounts: [AGAccountQuota], observedAt: Date = Date()) -> ToolQuota {
        let minFraction = accounts.compactMap(\.geminiRemainingFraction).min()
        let resetAt = accounts.compactMap(\.geminiEarliestReset).min()
        let remainingPct = minFraction.map { Int(($0 * 100).rounded()) }
        return ToolQuota(
            id: Tool.antigravity.rawValue, tool: .antigravity,
            accountKey: nil, accountLabel: nil,
            remaining: remainingPct, total: remainingPct == nil ? nil : 100,
            unit: .requests, resetAt: resetAt, updatedAt: observedAt,
            raw: accounts as (any Sendable)
        )
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

    private func purgeLegacyRefreshPreferences() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "menubar.syncIntervalGlobal")
        for tool in Tool.allCases {
            defaults.removeObject(forKey: "syncInterval.\(tool.rawValue)")
        }
    }

    // MARK: - Claude usage cache helpers

    static func restoredClaudeUsageCache(defaults: UserDefaults = .standard) -> ClaudeUsageResponse? {
        guard let data = defaults.data(forKey: "cached.claudeUsageData") else { return nil }
        return try? JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
    }

    private func persistClaudeUsageCache(_ usage: ClaudeUsageResponse, observedAt: Date) {
        if let data = try? JSONEncoder().encode(usage) {
            cacheDefaults.set(data, forKey: "cached.claudeUsageData")
            cacheDefaults.set(observedAt, forKey: "cached.claudeQuotaObservedAt")
        }
    }

    // MARK: - Antigravity accounts cache helpers

    private static func restoredAntigravityAccountsCache(defaults: UserDefaults = .standard) -> [AGAccountQuota]? {
        guard let data = defaults.data(forKey: "cached.antigravityAccountsData") else { return nil }
        return try? JSONDecoder().decode([AGAccountQuota].self, from: data)
    }

    private static func persistAntigravityAccountsCache(_ accounts: [AGAccountQuota], defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(accounts) {
            defaults.set(data, forKey: "cached.antigravityAccountsData")
        }
    }
    private func restoredCodexLimitsCache() -> CodexRateLimits? {
        guard let data = cacheDefaults.data(forKey: "cached.codexLimitsData") else { return nil }
        return try? JSONDecoder().decode(CodexRateLimits.self, from: data)
    }

    private func deskSnapshotCodexAccounts() -> [CodexAccountSnapshot] {
        if latestCodexAccounts.contains(where: { $0.isCurrent && $0.limits != nil }) {
            return latestCodexAccounts
        }

        guard let cached = restoredCodexLimitsCache() else {
            return latestCodexAccounts
        }

        let now = Date()
        return [
            CodexAccountSnapshot(
                id: "desk-cached-codex",
                label: "Codex",
                email: nil,
                accountID: "desk-cached-codex",
                planType: cached.planType,
                teamName: nil,
                addedAt: now,
                updatedAt: now,
                lastFetchedAt: now,
                limits: cached,
                usageError: nil,
                isCurrent: true
            )
        ]
    }

    private func toolQuotaFromClaudeUsage(_ usage: ClaudeUsageResponse) -> ToolQuota {
        let remaining = usage.effectiveRemainingPercent
        let resetAt = usage.isWeeklyExhausted ? (usage.sevenDay?.resetDate ?? usage.fiveHour?.resetDate) : usage.fiveHour?.resetDate
        return ToolQuota(
            id: Tool.claudeCode.rawValue, tool: .claudeCode,
            accountKey: nil, accountLabel: nil,
            remaining: remaining, total: 100, unit: .messages,
            resetAt: resetAt, updatedAt: latestClaudeQuotaObservedAt ?? .distantPast, raw: usage
        )
    }

    // MARK: - Poll timers

    private func schedulePollTimer(for tool: Tool) {
        let interval = max(30, Self.defaultPollInterval[tool] ?? 300)
        pollTimers[tool] = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refreshTool(tool) }
        }
    }

    // MARK: - FSEvents

    private func startFSEventWatching() {
        var watchPaths = Self.fsWatchRoots.map(\.path).filter { FileManager.default.fileExists(atPath: $0) }
        if FileManager.default.fileExists(atPath: Self.claudeBridgeRoot) {
            watchPaths.append(Self.claudeBridgeRoot)
        }
        if FileManager.default.fileExists(atPath: Self.claudeDesktopRoot) {
            watchPaths.append(Self.claudeDesktopRoot)
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
            if path.hasPrefix(Self.claudeDesktopRoot) {
                return path == Self.claudeDesktopRoot
                    || path == Self.claudeDesktopBuddyTokensPath
                    || path.hasPrefix(Self.claudeDesktopRoot + "/claude-code-sessions")
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

    private func publishDeskSnapshotIfNeeded() async {
        guard let deskSnapshotPublisher else { return }
        let codexRaw = Tool.codex.rawValue
        let claudeRaw = Tool.claudeCode.rawValue
        let desc = FetchDescriptor<QuotaRecord>(predicate: #Predicate { $0.toolRaw == codexRaw || $0.toolRaw == claudeRaw })
        let fallbackQuotas = (try? readContext.fetch(desc)) ?? []
        let snapshotCodexAccounts = deskSnapshotCodexAccounts()
        let snapshotClaudeUsage = latestClaudeUsage ?? Self.restoredClaudeUsageCache(defaults: cacheDefaults)
        guard let snapshot = DeskSnapshotBuilder.build(
            now: Date(),
            codexAccounts: snapshotCodexAccounts,
            claudeUsage: snapshotClaudeUsage,
            claudeObservedAt: latestClaudeQuotaObservedAt,
            fallbackQuotas: fallbackQuotas
        ) else {
            return
        }
        await deskSnapshotPublisher.publishIfNeeded(snapshot: snapshot)
    }

    private func scheduleDeskSnapshotPublishIfNeeded(for tool: Tool? = nil) async {
        if let tool, tool != .codex && tool != .claudeCode {
            return
        }
        await deskSnapshotPublishDebouncer?.schedule()
    }

    /// Polls, local file imports, and quota-only updates share successful propagation.
    /// refreshAll coalesces its child updates and calls this once after they finish.
    private func publishAfterSuccessfulRefresh(for tool: Tool? = nil) async {
        if let postRefreshOverride {
            await postRefreshOverride(tool)
            return
        }
        await scheduleDeskSnapshotPublishIfNeeded(for: tool)
        if tool == nil || tool == .codex || tool == .claudeCode {
            scheduleDotTextPush(force: tool == nil)
        }
        checkQuotaNotifications()
    }

    // MARK: - Quota notifications

    private func checkQuotaNotifications() {
        var infos: [String: NotificationService.QuotaInfo] = [:]

        let now = Date()
        if let current = latestCodexAccounts.first(where: \.isCurrent),
           let fraction = current.quota.fraction,
           current.quota.resetAt.map({ $0 > now }) != false {
            infos[Tool.codex.rawValue] = .init(fraction: fraction, resetAt: current.quota.resetAt)
        }
        if let usage = latestClaudeUsage, let frac = usage.effectiveFraction {
            let resetAt = usage.isWeeklyExhausted ? (usage.sevenDay?.resetDate ?? usage.fiveHour?.resetDate) : usage.fiveHour?.resetDate
            if resetAt.map({ $0 > now }) != false {
                infos[Tool.claudeCode.rawValue] = .init(fraction: frac, resetAt: resetAt)
            }
        }
        let ctx  = readContext
        let desc = FetchDescriptor<QuotaRecord>()
        if let records = try? ctx.fetch(desc) {
            for r in records {
                guard infos[r.toolRaw] == nil,
                      !(r.toolRaw == Tool.codex.rawValue && r.accountKey != nil),
                      r.resetAt.map({ $0 > now }) != false,
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
