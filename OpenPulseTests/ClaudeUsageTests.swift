import Testing
import Foundation
import SQLite
@testable import OpenPulse

struct ClaudeUsageTests {
    @Test
    func weeklyQuotaZeroMakesEffectiveRemainingZero() {
        let usage = ClaudeUsageResponse(
            fiveHour: UsageWindow(utilization: 0, resetsAt: "1000"),
            sevenDay: UsageWindow(utilization: 100, resetsAt: "5000")
        )

        #expect(usage.isWeeklyExhausted)
        #expect(usage.fiveHourRemainingPercent == 100)
        #expect(usage.sevenDayRemainingPercent == 0)
        #expect(usage.effectiveRemainingPercent == 0)
        #expect(usage.effectiveFraction == 0.0)
    }

    @Test
    func weeklyQuotaNotExhaustedPreservesFiveHourWindow() {
        let usage = ClaudeUsageResponse(
            fiveHour: UsageWindow(utilization: 20, resetsAt: "1000"),
            sevenDay: UsageWindow(utilization: 85, resetsAt: "5000")
        )

        #expect(!usage.isWeeklyExhausted)
        #expect(usage.fiveHourRemainingPercent == 80)
        #expect(usage.sevenDayRemainingPercent == 15)
        #expect(usage.effectiveRemainingPercent == 80)
        #expect(usage.effectiveFraction == 0.80)
    }

    @Test
    func fiveHourWindowConstrainsEffectiveRemaining() {
        let usage = ClaudeUsageResponse(
            fiveHour: UsageWindow(utilization: 80, resetsAt: "1000"),
            sevenDay: UsageWindow(utilization: 40, resetsAt: "5000")
        )

        #expect(!usage.isWeeklyExhausted)
        #expect(usage.fiveHourRemainingPercent == 20)
        #expect(usage.sevenDayRemainingPercent == 60)
        #expect(usage.effectiveRemainingPercent == 20)
        #expect(usage.effectiveFraction == 0.20)
    }

    @Test
    func missingWeeklyWindowUsesFiveHour() {
        let usage = ClaudeUsageResponse(
            fiveHour: UsageWindow(utilization: 25, resetsAt: "1000"),
            sevenDay: nil
        )

        #expect(!usage.isWeeklyExhausted)
        #expect(usage.fiveHourRemainingPercent == 75)
        #expect(usage.sevenDayRemainingPercent == nil)
        #expect(usage.effectiveRemainingPercent == 75)
        #expect(usage.effectiveFraction == 0.75)
    }

    @Test
    func missingFiveHourWindowUsesWeekly() {
        let usage = ClaudeUsageResponse(
            fiveHour: nil,
            sevenDay: UsageWindow(utilization: 60, resetsAt: "5000")
        )

        #expect(!usage.isWeeklyExhausted)
        #expect(usage.fiveHourRemainingPercent == nil)
        #expect(usage.sevenDayRemainingPercent == 40)
        #expect(usage.effectiveRemainingPercent == 40)
        #expect(usage.effectiveFraction == 0.40)
    }

    @Test
    func weeklyExhaustedOver100PercentUtilization() {
        let usage = ClaudeUsageResponse(
            fiveHour: UsageWindow(utilization: 10, resetsAt: "1000"),
            sevenDay: UsageWindow(utilization: 105, resetsAt: "5000")
        )

        #expect(usage.isWeeklyExhausted)
        #expect(usage.sevenDayRemainingPercent == 0)
        #expect(usage.effectiveRemainingPercent == 0)
        #expect(usage.effectiveFraction == 0.0)
    }
}

struct MenuBarTitleQuotaTests {
    @Test
    func compactAndVerticalShowAllSupportedToolsWhenUnconfigured() {
        #expect(
            Tool.menuBarTitleQuotaTools(displayStyle: "compact", titleQuotaToolsRaw: nil, toolOrderRaw: nil)
                == [.codex, .claudeCode, .copilot, .antigravity]
        )
        #expect(
            Tool.menuBarTitleQuotaTools(displayStyle: "vertical", titleQuotaToolsRaw: nil, toolOrderRaw: nil)
                == [.codex, .claudeCode, .copilot, .antigravity]
        )
        #expect(
            Tool.menuBarTitleQuotaTools(displayStyle: "classic", titleQuotaToolsRaw: nil, toolOrderRaw: nil)
                == []
        )
    }

    @Test
    func uncheckingCodexRemovesCodexFromCompactVerticalAndClassic() {
        let updated = Tool.updatingTitleQuotaTools(
            displayStyle: "compact",
            currentRaw: nil,
            toolOrderRaw: nil,
            tool: .codex,
            isEnabled: false
        )
        #expect(updated == "claude,copilot,antigravity")

        for style in ["compact", "vertical", "classic"] {
            #expect(
                Tool.menuBarTitleQuotaTools(displayStyle: style, titleQuotaToolsRaw: updated, toolOrderRaw: nil)
                    == [.claudeCode, .copilot, .antigravity]
            )
        }
    }

    @Test
    func emptyExplicitSelectionHidesAllToolsInEveryStyle() {
        for style in ["compact", "vertical", "classic"] {
            #expect(
                Tool.menuBarTitleQuotaTools(displayStyle: style, titleQuotaToolsRaw: "", toolOrderRaw: nil)
                    == []
            )
        }
    }

    @Test
    func toolOrderControlsResolvedMenuBarOrder() {
        #expect(
            Tool.menuBarTitleQuotaTools(
                displayStyle: "compact",
                titleQuotaToolsRaw: "codex,claude,copilot,antigravity",
                toolOrderRaw: "antigravity,claude,copilot,codex"
            ) == [.antigravity, .claudeCode, .copilot, .codex]
        )
    }

    @Test
    func copilotMenuBarPercentPrefersPremiumInteractionsAndRejectsExpired() {
        let now = Date(timeIntervalSince1970: 10_000)
        let snapshots: [String: CopilotSnapshot] = [
            "chat": CopilotSnapshot(quotaId: "chat", remaining: nil, entitlement: nil, percentRemaining: 100, unlimited: true),
            "premium_interactions": CopilotSnapshot(quotaId: "premium_interactions", remaining: 147, entitlement: 300, percentRemaining: 49.4, unlimited: false)
        ]

        #expect(CopilotSnapshot.menuBarRemainingPercent(from: snapshots, resetAt: now.addingTimeInterval(3600), now: now) == 49)
        #expect(CopilotSnapshot.menuBarRemainingPercent(from: snapshots, resetAt: now.addingTimeInterval(-10), now: now) == nil)
        #expect(CopilotSnapshot.menuBarRemainingPercent(from: nil, resetAt: nil, now: now) == nil)
    }
}

// Regression coverage for committed usage updates and refresh lifecycle.
import SwiftData
import Observation
import Synchronization
import Carbon.HIToolbox

@MainActor
struct UsageSyncRegressionTests {
    @Test func refreshStateNotifiesObserversAndRejectsOverlap() {
        let state = ToolSyncState()
        let observed = Mutex(false)
        withObservationTracking { _ = state.isRefreshing } onChange: {
            observed.withLock { $0 = true }
        }
        #expect(state.beginRefresh())
        #expect(observed.withLock { $0 })
        #expect(!state.beginRefresh())
        state.endRefresh()
        #expect(state.lastSyncDate == nil)
        state.recordSuccess()
        let successfulDate = state.lastSyncDate
        #expect(state.beginRefresh())
        state.recordError("fixture failure")
        state.endRefresh()
        #expect(state.lastSyncDate == successfulDate)
    }

    @Test func inPlaceUsageUpdateAdvancesRevisionWithoutAddingRows() throws {
        let schema = Schema([SessionRecord.self, DailyStatsRecord.self, QuotaRecord.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let service = DataSyncService(modelContainer: container, codexAccountService: CodexAccountService(), deskSnapshotPublisher: nil, restoreCachedSnapshots: false)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let record = DailyStatsRecord(date: Date(timeIntervalSince1970: 1_000), tool: .codex, totalInputTokens: 10, totalOutputTokens: 1, sessionCount: 1)
        context.insert(record)
        try service.saveUsageContext(context)
        let before = service.dataRevision
        record.totalInputTokens = 90
        try service.saveUsageContext(context)
        #expect(service.dataRevision == before + 1)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<DailyStatsRecord>()) == 1)
        #expect(try ModelContext(container).fetch(FetchDescriptor<DailyStatsRecord>()).first?.totalInputTokens == 90)
    }

    @Test func duplicateBatchUpsertsKeepOneSessionAndRefreshMetadata() async throws {
        let schema = Schema([SessionRecord.self, DailyStatsRecord.self, QuotaRecord.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let service = DataSyncService(modelContainer: container, codexAccountService: CodexAccountService(), deskSnapshotPublisher: nil, restoreCachedSnapshots: false)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let id = UUID()
        let initial = ToolSession(id: id, tool: .codex, startedAt: .now, inputTokens: 1, cwd: "/Fixture/A", gitBranch: "main")
        let updated = ToolSession(id: id, tool: .codex, startedAt: initial.startedAt, inputTokens: 12, cwd: "/Fixture/B", gitBranch: "feature")
        try await service.upsertSessions([initial, updated], context: context)
        try service.saveUsageContext(context)
        let rows = try ModelContext(container).fetch(FetchDescriptor<SessionRecord>())
        #expect(rows.count == 1)
        #expect(rows.first?.inputTokens == 12)
        #expect(rows.first?.cwd == "/Fixture/B")
        #expect(rows.first?.gitBranch == "feature")
    }

    @Test func cacheClearRemovesAllThreeCachedRecordTypes() throws {
        let store = AppStore(inMemory: true)
        let context = ModelContext(store.modelContainer)
        context.autosaveEnabled = false
        context.insert(SessionRecord(tool: .codex, startedAt: .now))
        context.insert(DailyStatsRecord(date: .now, tool: .codex))
        context.insert(QuotaRecord(tool: .codex, remaining: 20, total: 100, unit: .tokens))
        try context.save()
        try store.clearUsageCache()
        let read = ModelContext(store.modelContainer)
        #expect(try read.fetchCount(FetchDescriptor<SessionRecord>()) == 0)
        #expect(try read.fetchCount(FetchDescriptor<DailyStatsRecord>()) == 0)
        #expect(try read.fetchCount(FetchDescriptor<QuotaRecord>()) == 0)
    }

    @Test func modifiedAIsAValidShortcut() {
        #expect(GlobalHotkeyService.displayString(keyCode: 0, carbonModifiers: UInt32(cmdKey)) == "⌘A")
        #expect(GlobalHotkeyService.displayString(keyCode: 46, carbonModifiers: 0) == String(localized: "无"))
    }

    @Test func hostedTestsDisableRealSyncStartup() {
        #expect(AppStore.isRunningTests)
        let store = AppStore(inMemory: true)
        store.startSync()
        #expect(store.syncService == nil)
    }
}

@MainActor
struct NavigationAndConfigQuickOpenTests {
    @Test func openDiagnosticsLogsNavigatesToSettingsDiagnosticsSection() {
        let store = AppStore(inMemory: true)
        #expect(store.selectedTab == .trends)
        #expect(store.selectedSettingsSection == .general)

        store.openDiagnosticsLogs()

        #expect(store.selectedTab == .settings)
        #expect(store.selectedSettingsSection == .diagnostics)
    }

    @Test func toolConfigCatalogProvidesExpectedFilesForEveryTool() {
        let fakeHome = URL(fileURLWithPath: "/tmp/openpulse-synthetic-home")
        #expect(ToolConfigFileEntry.entries(for: .codex, home: fakeHome).map(\.displayName) == ["config.toml", "AGENTS.md"])
        #expect(ToolConfigFileEntry.entries(for: .claudeCode, home: fakeHome).map(\.displayName) == ["settings.json", "CLAUDE.md"])
        #expect(ToolConfigFileEntry.entries(for: .antigravity, home: fakeHome).map(\.displayName) == ["settings.json", "GEMINI.md"])
        #expect(ToolConfigFileEntry.entries(for: .copilot, home: fakeHome).map(\.displayName) == ["config.json"])
    }
}


@MainActor
struct QuotaNotificationRegressionTests {
    private func fixtureDefaults() -> (UserDefaults, String) {
        let name = "OpenPulse.NotificationFixtures." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.set(true, forKey: "notifications.enabled")
        defaults.set(10, forKey: "notifications.threshold")
        return (defaults, name)
    }

    @Test func failedDeliveryCanRetryAndSuccessIsThrottled() async {
        let (defaults, name) = fixtureDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        var attempts = 0
        let date = Date(timeIntervalSince1970: 5_000)
        let service = NotificationService(defaults: defaults, now: { date }) { _, _, _ in
            attempts += 1
            if attempts == 1 { throw CocoaError(.fileWriteUnknown) }
        }
        let quotas: [String: NotificationService.QuotaInfo] = ["codex": .init(fraction: 0.05, resetAt: date.addingTimeInterval(60))]
        await service.deliverQuotaNotifications(quotas: quotas)
        await service.deliverQuotaNotifications(quotas: quotas)
        await service.deliverQuotaNotifications(quotas: quotas)
        #expect(attempts == 2)
    }

    @Test func expiredAndInvalidFractionsNeverDeliver() async {
        let (defaults, name) = fixtureDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        var deliveries = 0
        let date = Date(timeIntervalSince1970: 5_000)
        let service = NotificationService(defaults: defaults, now: { date }) { _, _, _ in deliveries += 1 }
        await service.deliverQuotaNotifications(quotas: [
            "expired": .init(fraction: 0.01, resetAt: date),
            "negative": .init(fraction: -0.1, resetAt: nil),
            "nan": .init(fraction: .nan, resetAt: nil),
            "infinity": .init(fraction: .infinity, resetAt: nil),
            "unknown": .init(fraction: 2, resetAt: nil)
        ])
        #expect(deliveries == 0)
    }

    @Test func concurrentChecksDoNotDeliverDuplicateAlerts() async {
        let (defaults, name) = fixtureDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        var deliveries = 0
        let date = Date(timeIntervalSince1970: 5_000)
        let service = NotificationService(defaults: defaults, now: { date }) { _, _, _ in
            deliveries += 1
            await Task.yield()
        }
        let quotas: [String: NotificationService.QuotaInfo] = ["codex": .init(fraction: 0.05, resetAt: nil)]
        async let first: Void = service.deliverQuotaNotifications(quotas: quotas)
        async let second: Void = service.deliverQuotaNotifications(quotas: quotas)
        _ = await (first, second)
        #expect(deliveries == 1)
    }
}

@MainActor
struct LocalQuotaRefreshRegressionTests {
    @Test func quotaOnlyRefreshOwnsToolStateAndRejectsOverlapUntilCompletion() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let gate = LocalQuotaRefreshFixtureGate()
        var operations = 0
        var publications = 0
        let service = makeService(fixture) { _ in publications += 1 }
        let running = Task {
            await service.performQuotaOnlyRefresh(for: .codex) {
                operations += 1
                await gate.suspend()
                return true
            }
        }
        while !gate.isSuspended { await Task.yield() }

        #expect(service.isSyncingActive)
        #expect(!service.states[.codex].beginRefresh())
        await service.performQuotaOnlyRefresh(for: .codex) {
            operations += 1
            return true
        }
        #expect(operations == 1)
        #expect(publications == 0)
        #expect(service.states[.codex].lastSyncDate == nil)

        gate.resume()
        await running.value
        #expect(!service.isSyncingActive)
        #expect(service.states[.codex].lastSyncDate != nil)
        #expect(publications == 1)
    }

    @Test func failedAndSkippedLocalQuotaDoNotAdvanceSuccessOrPublish() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        var publications = 0
        let service = makeService(fixture) { _ in publications += 1 }
        await service.performQuotaOnlyRefresh(for: .codex) { false }
        await service.performQuotaOnlyRefresh(for: .codex) { throw NSError(domain: "SyntheticLocalQuota", code: 1) }
        #expect(service.states[.codex].lastSyncDate == nil)
        #expect(!service.isSyncingActive)
        #expect(publications == 0)
    }

    @Test func missingBridgeRetainsSavedQuotaWithoutNetworkFallbackOrSuccess() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        var publications = 0
        let service = makeService(fixture) { _ in publications += 1 }
        let context = ModelContext(fixture.container)
        context.insert(QuotaRecord(tool: .claudeCode, remaining: 42, total: 100, unit: .messages))
        try context.save()

        await service.refreshClaudeQuotaFromBridge()

        #expect(service.latestClaudeUsage == nil)
        #expect(service.states[.claudeCode].lastSyncDate == nil)
        #expect(!service.isSyncingActive)
        #expect(publications == 0)
        #expect(try ModelContext(fixture.container).fetch(FetchDescriptor<QuotaRecord>()).first?.remaining == 42)
    }

    @Test func validBridgeCommitsAndPublishesUsingCaptureTime() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let capturedAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 120)
        let body: [String: Any] = [
            "captured_at": Int(capturedAt.timeIntervalSince1970),
            "rate_limits": ["five_hour": ["utilization": 25, "resets_at": "2099-01-01T00:00:00Z"]]
        ]
        try JSONSerialization.data(withJSONObject: body).write(to: fixture.root.appending(path: "bridge.json"))
        var publications = 0
        let service = makeService(fixture) { _ in publications += 1 }

        await service.refreshClaudeQuotaFromBridge()

        #expect(service.latestClaudeUsage?.fiveHourRemainingPercent == 75)
        #expect(service.latestClaudeQuotaObservedAt == capturedAt)
        #expect(service.states[.claudeCode].lastSyncDate != nil)
        #expect(publications == 1)
        let quota = try #require(try ModelContext(fixture.container).fetch(FetchDescriptor<QuotaRecord>()).first)
        #expect(quota.remaining == 75)
        #expect(quota.updatedAt == capturedAt)
        #expect(fixture.defaults.object(forKey: "cached.claudeQuotaObservedAt") as? Date == capturedAt)

        let desktop = fixture.root.appending(path: "desktop")
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        try Data(#"{"tokens-today":{"tokens":111}}"#.utf8).write(to: desktop.appending(path: "buddy-tokens.json"))
        await service.refreshLocalFiles(for: .claudeCode)
        #expect(service.latestClaudeQuotaObservedAt == capturedAt)
        #expect(try ModelContext(fixture.container).fetch(FetchDescriptor<QuotaRecord>()).first?.updatedAt == capturedAt)
        #expect(publications == 2)
    }

    @Test func desktopBuddyEventsRouteToClaudeAndMergeLocalDailyUsage() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let desktop = fixture.root.appending(path: "desktop")
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        try Data(#"{"tokens-today":{"tokens":345}}"#.utf8).write(to: desktop.appending(path: "buddy-tokens.json"))
        var publications = 0
        let service = makeService(fixture) { _ in publications += 1 }
        let sourceRoot = URL.homeDirectory.appending(path: "Library/Application Support/Claude").path
        #expect(service.toolsAffectedByPaths([sourceRoot + "/buddy-tokens.json"]) == [.claudeCode])
        #expect(service.toolsAffectedByPaths([sourceRoot + "/claude-code-sessions/synthetic.json"]) == [.claudeCode])

        await service.refreshLocalFiles(for: .claudeCode)

        let stats = try #require(try ModelContext(fixture.container).fetch(FetchDescriptor<DailyStatsRecord>()).first)
        #expect(stats.tool == .claudeCode)
        #expect(stats.totalInputTokens == 345)
        #expect(publications == 1)
        #expect(service.latestClaudeQuotaObservedAt == nil)
    }

    @Test func eventDuringPausedOwnerIsImportedAfterCompletionWithoutPolling() async throws {
        let fixture = try makeFixture()
        let gate = LocalQuotaRefreshFixtureGate()
        var publications = 0
        let service = makeService(fixture) { _ in publications += 1 }
        defer { service.stop(); cleanup(fixture) }
        let desktop = fixture.root.appending(path: "desktop")
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        try Data(#"{"tokens-today":{"tokens":678}}"#.utf8).write(to: desktop.appending(path: "buddy-tokens.json"))
        let running = Task {
            await service.performQuotaOnlyRefresh(for: .claudeCode) {
                await gate.suspend()
                return false
            }
        }
        while !gate.isSuspended { await Task.yield() }
        let event = URL.homeDirectory.appending(path: "Library/Application Support/Claude/buddy-tokens.json").path
        service.handleLocalFileChange(paths: [event])
        await service.flushLocalFileChanges()
        #expect(try ModelContext(fixture.container).fetchCount(FetchDescriptor<DailyStatsRecord>()) == 0)

        gate.resume()
        await running.value
        await service.awaitLocalCatchUps()

        let stats = try #require(try ModelContext(fixture.container).fetch(FetchDescriptor<DailyStatsRecord>()).first)
        #expect(stats.totalInputTokens == 678)
        #expect(publications == 1)
        #expect(!service.isSyncingActive)
    }

    @Test func stopDiscardsQueuedLocalCatchUpAndLateEvents() async throws {
        let fixture = try makeFixture()
        let gate = LocalQuotaRefreshFixtureGate()
        var publications = 0
        let service = makeService(fixture) { _ in publications += 1 }
        defer { service.stop(); cleanup(fixture) }
        let running = Task {
            await service.performQuotaOnlyRefresh(for: .claudeCode) {
                await gate.suspend()
                return false
            }
        }
        while !gate.isSuspended { await Task.yield() }
        let event = URL.homeDirectory.appending(path: "Library/Application Support/Claude/buddy-tokens.json").path
        service.handleLocalFileChange(paths: [event])
        await service.flushLocalFileChanges()
        service.stop()
        service.handleLocalFileChange(paths: [event])
        gate.resume()
        await running.value
        await service.awaitLocalCatchUps()

        #expect(publications == 0)
        #expect(service.states[.claudeCode].lastSyncDate == nil)
        #expect(try ModelContext(fixture.container).fetchCount(FetchDescriptor<DailyStatsRecord>()) == 0)
    }

    @Test func antigravityQuotaFailureStillPersistsLocalTasksAndRetainsQuotaObservation() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let sourceID = UUID()
        try writeAntigravityTask(fixture, id: sourceID)
        let account = antigravityAccount(email: "synthetic-a@example.invalid", remaining: 0.2)
        fixture.defaults.set(try JSONEncoder().encode([account]), forKey: "cached.antigravityAccountsData")
        let observedAt = Date(timeIntervalSince1970: 5_000)
        let context = ModelContext(fixture.container)
        let quota = QuotaRecord(tool: .antigravity, remaining: 20, total: 100, unit: .requests)
        quota.updatedAt = observedAt
        context.insert(quota)
        try context.save()
        var quotaRequests = 0
        var publications = 0
        let service = makeService(fixture, restoreCachedSnapshots: true, antigravityQuotaFetch: {
            quotaRequests += 1
            throw AntigravityError.apiFailed("Synthetic quota failure")
        }) { _ in publications += 1 }

        await service.refreshTool(.antigravity)

        let imported = try #require(try ModelContext(fixture.container).fetch(FetchDescriptor<SessionRecord>()).first)
        #expect(imported.id == sourceID)
        #expect(imported.taskDescription == "Synthetic local task")
        #expect(service.dataRevision == 1)
        #expect(service.states[.antigravity].lastSyncDate == nil)
        #expect(publications == 0)
        // The existing failure gate surfaces a persistent API error on the third attempt.
        await service.refreshTool(.antigravity)
        await service.refreshTool(.antigravity)

        #expect(quotaRequests == 3)
        #expect(service.states[.antigravity].lastError?.contains("Synthetic quota failure") == true)
        #expect(service.states[.antigravity].lastSyncDate == nil)
        #expect(service.latestAntigravityAccounts?.first?.geminiRemainingFraction == 0.2)
        let storedQuota = try #require(try ModelContext(fixture.container).fetch(FetchDescriptor<QuotaRecord>()).first)
        #expect(storedQuota.remaining == 20)
        #expect(storedQuota.updatedAt == observedAt)
        #expect(try ModelContext(fixture.container).fetchCount(FetchDescriptor<SessionRecord>()) == 1)
        #expect(service.dataRevision == 1)
        #expect(publications == 0)
    }

    @Test func antigravityPartialQuotaRetainsCredentialedAccountUntilCredentialRemoval() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let first = antigravityAccount(email: "synthetic-a@example.invalid", remaining: 0.8)
        let failed = antigravityAccount(email: "synthetic-b@example.invalid", remaining: 0.2)
        let refreshed = antigravityAccount(email: first.email, remaining: 0.9)
        fixture.defaults.set(try JSONEncoder().encode([first, failed]), forKey: "cached.antigravityAccountsData")
        let observedAt = Date(timeIntervalSince1970: 5_000)
        let context = ModelContext(fixture.container)
        let quota = QuotaRecord(tool: .antigravity, remaining: 20, total: 100, unit: .requests)
        quota.updatedAt = observedAt
        context.insert(quota)
        try context.save()
        let quotaProvider = AntigravityQuotaFixtureProvider(AGQuotaFetchResult(accounts: [refreshed], orderedEmails: [first.email, failed.email]))
        var publications = 0
        let service = makeService(fixture, restoreCachedSnapshots: true, antigravityQuotaFetch: { await quotaProvider.fetch() }) { _ in publications += 1 }

        for _ in 0..<3 { await service.refreshTool(.antigravity) }

        #expect(service.latestAntigravityAccounts?.map(\.email) == [first.email, failed.email])
        #expect(service.latestAntigravityAccounts?.first?.geminiRemainingFraction == 0.9)
        #expect(service.latestAntigravityAccounts?.last?.geminiRemainingFraction == 0.2)
        #expect(service.states[.antigravity].lastError?.contains("1 of 2 accounts") == true)
        #expect(service.states[.antigravity].lastSyncDate == nil)
        let partialQuota = try #require(try ModelContext(fixture.container).fetch(FetchDescriptor<QuotaRecord>()).first)
        #expect(partialQuota.remaining == 20)
        #expect(partialQuota.updatedAt == observedAt)
        let partialCache = try #require(fixture.defaults.data(forKey: "cached.antigravityAccountsData"))
        #expect(try JSONDecoder().decode([AGAccountQuota].self, from: partialCache).map(\.email) == [first.email, failed.email])
        #expect(publications == 0)

        // Credential discovery now excludes B: it must not be retained forever.
        await quotaProvider.update(AGQuotaFetchResult(accounts: [refreshed], orderedEmails: [first.email]))
        await service.refreshTool(.antigravity)

        #expect(service.latestAntigravityAccounts?.map(\.email) == [first.email])
        #expect(service.states[.antigravity].lastError == nil)
        #expect(service.states[.antigravity].lastSyncDate != nil)
        let completeQuota = try #require(try ModelContext(fixture.container).fetch(FetchDescriptor<QuotaRecord>()).first)
        #expect(completeQuota.remaining == 90)
        #expect(completeQuota.updatedAt > observedAt)
        let completeCache = try #require(fixture.defaults.data(forKey: "cached.antigravityAccountsData"))
        #expect(try JSONDecoder().decode([AGAccountQuota].self, from: completeCache).map(\.email) == [first.email])
        #expect(publications == 1)
    }

    @Test func backgroundMenuBarModeSkipsLocalSessionScanUntilMainWindowOpens() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let sourceID = UUID()
        try writeAntigravityTask(fixture, id: sourceID)
        let account = antigravityAccount(email: "synthetic-a@example.invalid", remaining: 0.75)

        let service = makeService(
            fixture,
            restoreCachedSnapshots: false,
            sessionScanningActive: false,
            antigravityQuotaFetch: { AGQuotaFetchResult(accounts: [account], orderedEmails: [account.email]) }
        ) { _ in }

        // While main window is closed (Menu Bar background mode), refreshTool fetches quota only.
        await service.refreshTool(.antigravity)
        #expect(try ModelContext(fixture.container).fetchCount(FetchDescriptor<SessionRecord>()) == 0)
        #expect(service.latestAntigravityAccounts?.first?.geminiRemainingFraction == 0.75)

        // Opening the main window enables session scanning and imports sessions on demand.
        service.setMainWindowVisible(true)
        try await Task.sleep(for: .milliseconds(250))
        let records = try ModelContext(fixture.container).fetch(FetchDescriptor<SessionRecord>())
        #expect(records.count == 1)
        #expect(records.first?.id == sourceID)

        // Closing the main window pauses session scanning again.
        service.setMainWindowVisible(false)
        #expect(!service.sessionScanningActive)
    }

    private struct Fixture {
        let root: URL
        let suiteName: String
        let defaults: UserDefaults
        let container: ModelContainer
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "OpenPulse-LocalQuota-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suiteName = "OpenPulse.LocalQuotaTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let schema = Schema([SessionRecord.self, DailyStatsRecord.self, QuotaRecord.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        return Fixture(root: root, suiteName: suiteName, defaults: defaults, container: container)
    }

    private func makeService(
        _ fixture: Fixture,
        restoreCachedSnapshots: Bool = false,
        sessionScanningActive: Bool = true,
        antigravityQuotaFetch: (@MainActor () async throws -> AGQuotaFetchResult)? = nil,
        postRefresh: @escaping @MainActor (Tool?) async -> Void
    ) -> DataSyncService {
        let parser = ClaudeCodeParser(
            claudeDir: fixture.root.appending(path: "claude"),
            configProjectsDir: fixture.root.appending(path: "config/projects"),
            claudeDesktopDir: fixture.root.appending(path: "desktop"),
            statusCacheURL: fixture.root.appending(path: "bridge.json")
        )
        let codexParser = CodexParser(codexDir: fixture.root.appending(path: "codex"))
        let antigravityParser = AntigravityParser(brainDir: fixture.root.appending(path: "brain"), accountService: nil)
        return DataSyncService(modelContainer: fixture.container, codexAccountService: CodexAccountService(), deskSnapshotPublisher: nil, restoreCachedSnapshots: restoreCachedSnapshots, sessionScanningActive: sessionScanningActive, claudeParser: parser, codexParser: codexParser, antigravityParser: antigravityParser, cacheDefaults: fixture.defaults, postRefresh: postRefresh, antigravityQuotaFetch: antigravityQuotaFetch)
    }

    private func writeAntigravityTask(_ fixture: Fixture, id: UUID) throws {
        let conversation = fixture.root.appending(path: "brain").appending(path: id.uuidString)
        try FileManager.default.createDirectory(at: conversation, withIntermediateDirectories: true)
        let metadata: [String: String] = ["updatedAt": ISO8601DateFormatter().string(from: Date()), "summary": "Synthetic task"]
        try JSONSerialization.data(withJSONObject: metadata).write(to: conversation.appending(path: "task.md.metadata.json"))
        try Data("# Synthetic local task\n\n- [x] Synthetic fixture item\n".utf8).write(to: conversation.appending(path: "task.md.resolved"))
    }

    private func antigravityAccount(email: String, remaining: Double) -> AGAccountQuota {
        let resetAt = Date(timeIntervalSince1970: 4_102_444_800)
        return AGAccountQuota(email: email, tier: nil, groups: [
            AGQuotaGroup(id: "gemini", displayName: "Synthetic Gemini", fiveHour: AGWindow(kind: .fiveHour, remainingFraction: remaining, resetTime: resetAt, description: nil), weekly: nil)
        ])
    }

    @Test func customPollIntervalsClampPersistAndResetToDefaults() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let service = makeService(fixture) { _ in }

        #expect(service.currentPollInterval(for: .claudeCode) == 300)
        #expect(service.currentPollInterval(for: .copilot) == 3600)

        // Clamps below minimum to safe per-tool floor
        service.setPollInterval(10, for: .claudeCode)
        service.setPollInterval(60, for: .copilot)
        #expect(service.currentPollInterval(for: .claudeCode) == 60)
        #expect(service.currentPollInterval(for: .copilot) == 300)

        // Supports explicit manual-only mode (0)
        service.setPollInterval(0, for: .codex)
        #expect(service.currentPollInterval(for: .codex) == 0)
        #expect(DataSyncService.nextPollDelay(for: .codex, baseInterval: 0, isInitial: true, jitterUnit: 0) == nil)

        // Reset restores defaults
        service.resetPollIntervalsToDefaults()
        #expect(service.currentPollInterval(for: .claudeCode) == 300)
        #expect(service.currentPollInterval(for: .codex) == 300)
        #expect(service.currentPollInterval(for: .copilot) == 3600)
    }

    @Test func staggeredPollDelaysAvoidHarmonicCollisionsAndBoundJitter() {
        let codexInitial = DataSyncService.nextPollDelay(for: .codex, baseInterval: 300, isInitial: true, jitterUnit: 0)
        let claudeInitial = DataSyncService.nextPollDelay(for: .claudeCode, baseInterval: 300, isInitial: true, jitterUnit: 0)
        let agInitial = DataSyncService.nextPollDelay(for: .antigravity, baseInterval: 300, isInitial: true, jitterUnit: 0)
        let copilotInitial = DataSyncService.nextPollDelay(for: .copilot, baseInterval: 300, isInitial: true, jitterUnit: 0)

        #expect(codexInitial == 300)
        #expect(claudeInitial == 325)
        #expect(agInitial == 350)
        #expect(copilotInitial == 375)

        // Subsequent polls omit initial phase offset and bound jitter to +/- min(15s, 5%)
        let minSubsequent = DataSyncService.nextPollDelay(for: .claudeCode, baseInterval: 300, isInitial: false, jitterUnit: -1)
        let maxSubsequent = DataSyncService.nextPollDelay(for: .claudeCode, baseInterval: 300, isInitial: false, jitterUnit: 1)
        #expect(minSubsequent == 285)
        #expect(maxSubsequent == 315)
    }

    @Test func silentLocalRefreshHoldsLockWithoutFlashingGlobalSyncSpinner() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let gate = LocalQuotaRefreshFixtureGate()
        let service = makeService(fixture) { _ in }

        let running = Task {
            await service.performQuotaOnlyRefresh(for: .claudeCode, refreshKind: .local) {
                await gate.suspend()
                return false
            }
        }
        while !gate.isSuspended { await Task.yield() }

        #expect(service.hasAnyRefreshInFlight)
        #expect(!service.isSyncingActive)

        gate.resume()
        await running.value
        #expect(!service.hasAnyRefreshInFlight)
        #expect(!service.isSyncingActive)
    }

    @Test func claudeCedarEmberDistinguishesFullAndFableResetsFiltersExpiredAndSurvivesBridgeRefresh() async throws {
        let now = ISO8601DateFormatter().date(from: "2026-11-26T06:00:00Z")!
        let json = """
        {
          "five_hour": { "utilization": 30.0, "resets_at": "2026-11-26T11:00:00Z" },
          "seven_day": { "utilization": 45.0, "resets_at": "2026-12-01T04:00:00Z" },
          "cedar_ember": {
            "eligible": true,
            "next_grant_id": "launch-2610-fable-week",
            "grants": [
              {
                "id": "expired-grant",
                "label": "Expired promo",
                "resets_left": 1,
                "resets_total": 1,
                "ends_at": "2026-11-20T00:00:00Z",
                "clears": ["five_hour", "seven_day"],
                "type": "full"
              },
              {
                "id": "paused-grant",
                "label": "Paused Fable reset",
                "resets_left": 1,
                "resets_total": 1,
                "ends_at": "2026-12-15T00:00:00Z",
                "clears": ["five_hour", "seven_day_overage_included"],
                "paused": true
              },
              {
                "id": "launch-2610-fable-week",
                "label": "New model launch: one Fable reset for Pro and Team Standard",
                "resets_left": 2,
                "resets_total": 2,
                "ends_at": "2026-12-10T00:00:00Z",
                "clears": ["five_hour", "seven_day_overage_included"],
                "type": "full",
                "paused": false,
                "usable_now": true
              },
              {
                "id": "full-comp-grant",
                "label": "One full limit reset",
                "resets_left": 1,
                "resets_total": 1,
                "ends_at": "2026-12-01T00:00:00Z",
                "clears": ["five_hour", "seven_day"],
                "type": "full",
                "paused": false,
                "usable_now": true
              }
            ]
          }
        }
        """
        let decoded = try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data(json.utf8))
        let resets = try #require(decoded.cedarEmber)
        #expect(resets.totalResetsLeft(now: now) == 3)

        let buckets = resets.groupedResets(now: now)
        #expect(buckets.map(\.kind) == [.full, .fable])
        #expect(buckets[0].count == 1)
        #expect(buckets[0].grants.map(\.id) == ["full-comp-grant"])
        #expect(buckets[1].count == 2)
        #expect(buckets[1].grants.map(\.id) == ["launch-2610-fable-week"])

        // Bridge update without cedar_ember preserves existing limit reset metadata.
        let bridgeUpdate = ClaudeUsageResponse(
            fiveHour: UsageWindow(utilization: 50, resetsAt: "2026-11-26T11:00:00Z"),
            sevenDay: UsageWindow(utilization: 48, resetsAt: "2026-12-01T04:00:00Z")
        )
        let merged = bridgeUpdate.mergingSupplementalMetadata(from: decoded)
        #expect(merged.fiveHourRemainingPercent == 50)
        #expect(merged.cedarEmber?.groupedResets(now: now).map(\.kind) == [.full, .fable])
    }

    @Test func codexResetCreditsFiltersExpiredAndUsedAndSortsByExpiry() throws {
        let now = ISO8601DateFormatter().date(from: "2026-11-26T06:00:00Z")!
        let json = """
        {
          "available_count": 3,
          "credits": [
            {
              "id": "expired",
              "status": "available",
              "title": "Expired reset",
              "expires_at": "2026-11-20T00:00:00Z"
            },
            {
              "id": "used",
              "status": "redeemed",
              "title": "Used reset",
              "expires_at": "2026-12-20T00:00:00Z"
            },
            {
              "id": "later",
              "status": "available",
              "title": "Later reset",
              "expires_at": "2026-12-10T00:00:00Z"
            },
            {
              "id": "sooner",
              "status": "available",
              "title": "Sooner reset",
              "expires_at": "2026-12-01T00:00:00Z"
            }
          ]
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CodexResetCredits.self, from: Data(json.utf8))
        #expect(decoded.resolvedAvailableCount(now: now) == 2)
        #expect(decoded.activeCredits(now: now).map(\.id) == ["sooner", "later"])
        #expect(decoded.expiryDates(now: now).count == 2)
        #expect(decoded.hasDisplayableCredits(now: now))

        // Count-only payload without credits array still reports available_count.
        let countOnly = try decoder.decode(CodexResetCredits.self, from: Data(#"{"available_count": 2}"#.utf8))
        #expect(countOnly.resolvedAvailableCount(now: now) == 2)
        #expect(countOnly.hasDisplayableCredits(now: now))
    }

    @Test func settingsLanguageResolutionMapsAppleLanguagesConsistently() {
        let suiteName = "OpenPulse.SettingsLang." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(SettingsView.resolvedAppleLanguage(defaults: defaults, domainName: suiteName) == "system")

        defaults.set(["en-US"], forKey: "AppleLanguages")
        #expect(SettingsView.resolvedAppleLanguage(defaults: defaults, domainName: suiteName) == "en")

        defaults.set(["zh-Hans-CN"], forKey: "AppleLanguages")
        #expect(SettingsView.resolvedAppleLanguage(defaults: defaults, domainName: suiteName) == "zh-Hans")

        defaults.set(["ja-JP"], forKey: "AppleLanguages")
        #expect(SettingsView.resolvedAppleLanguage(defaults: defaults, domainName: suiteName) == "system")

        defaults.removeObject(forKey: "AppleLanguages")
        #expect(SettingsView.resolvedAppleLanguage(defaults: defaults, domainName: suiteName) == "system")
    }

    @Test func notificationServiceTestDeliveryUsesInjectedHandler() async throws {
        var delivered: (id: String, title: String, body: String)?
        let service = NotificationService(deliver: { id, title, body in
            delivered = (id, title, body)
        })
        try await service.sendTestNotification()
        #expect(delivered?.id.hasPrefix("openpulse-test-") == true)
        #expect(delivered?.title.isEmpty == false)
        #expect(delivered?.body.isEmpty == false)
    }

    @Test func dotTextTestPushValidatesMissingDeviceIDAndAPIKey() async {
        let suiteName = "OpenPulse.DotTextTest." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = DotTextAPIService()
        do {
            try await service.testPushQuotaSnapshot(
                codexAccounts: [],
                claudeUsage: nil,
                fallbackQuotas: [],
                defaults: defaults,
                apiKeyOverride: "secret-key"
            )
            Issue.record("Expected missingDeviceID error")
        } catch let error as DotTextAPIError {
            #expect(error == .missingDeviceID)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        defaults.set("DOT-123456", forKey: "dot.textAPI.deviceID")
        do {
            try await service.testPushQuotaSnapshot(
                codexAccounts: [],
                claudeUsage: nil,
                fallbackQuotas: [],
                defaults: defaults,
                apiKeyOverride: "   "
            )
            Issue.record("Expected missingAPIKey error")
        } catch let error as DotTextAPIError {
            #expect(error == .missingAPIKey)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func activitySnapshotFiltersByTimeSortModelAndSessionID() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let recent = ActivitySessionSnapshot(
            id: UUID(),
            tool: .claudeCode,
            startedAt: now.addingTimeInterval(-3600),
            endedAt: now.addingTimeInterval(-3000),
            inputTokens: 100,
            outputTokens: 50,
            task: "Recent Claude work",
            model: "claude-opus-4-6"
        )
        let oldHeavy = ActivitySessionSnapshot(
            id: UUID(),
            tool: .codex,
            startedAt: now.addingTimeInterval(-10 * 86_400),
            endedAt: now.addingTimeInterval(-10 * 86_400 + 7200),
            inputTokens: 900,
            outputTokens: 300,
            task: "Heavy Codex task",
            model: "gpt-5.4"
        )
        let agTask = ActivitySessionSnapshot(
            id: UUID(),
            tool: .antigravity,
            startedAt: now.addingTimeInterval(-2 * 86_400),
            task: "Antigravity brainstorm"
        )
        let snapshot = try ActivityHistorySnapshot(sessions: [recent, agTask, oldHeavy])

        #expect(try snapshot.filtered(tool: nil, search: "opus").sessions.map(\.id) == [recent.id])
        #expect(try snapshot.filtered(tool: nil, search: agTask.id.uuidString).sessions.map(\.id) == [agTask.id])
        #expect(try snapshot.filtered(tool: nil, search: "", timeFilter: .last7Days, referenceDate: now).sessions.map(\.id) == [recent.id, agTask.id])
        #expect(try snapshot.filtered(tool: nil, search: "", sortOrder: .mostTokens).sessions.map(\.id) == [oldHeavy.id, recent.id, agTask.id])
        #expect(try snapshot.filtered(tool: nil, search: "", sortOrder: .longestDuration).sessions.map(\.id) == [oldHeavy.id, recent.id, agTask.id])
        #expect(try snapshot.filtered(tool: nil, search: "", sortOrder: .oldest).sessions.map(\.id) == [oldHeavy.id, agTask.id, recent.id])
    }

    @Test func sessionManagementHideModeDeletesRecordAndPreventsReimportUntilRestored() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let service = makeService(fixture) { _ in }

        let sessionID = UUID()
        let writeContext = ModelContext(fixture.container)
        writeContext.autosaveEnabled = false
        writeContext.insert(SessionRecord(id: sessionID, tool: .claudeCode, startedAt: Date(), inputTokens: 100, outputTokens: 20, taskDescription: "To hide"))
        try writeContext.save()

        let report = try await SessionManagementService.deleteSessions(
            [SessionDeletionTarget(id: sessionID, tool: .claudeCode, title: "To hide", projectPath: "")],
            mode: .hideInOpenPulse,
            modelContainer: fixture.container,
            defaultsSuiteName: fixture.suiteName
        )
        #expect(report.deletedRecords == 1)
        #expect(report.trashedURLs.isEmpty)
        #expect(SessionManagementService.hiddenSessionIDs(defaults: fixture.defaults).contains(sessionID))

        // Re-upserting the same session while hidden must skip it.
        let syncContext = ModelContext(fixture.container)
        syncContext.autosaveEnabled = false
        try await service.upsertSessions(
            [ToolSession(id: sessionID, tool: .claudeCode, startedAt: Date(), inputTokens: 100, outputTokens: 20, taskDescription: "To hide")],
            context: syncContext
        )
        try syncContext.save()
        #expect(try syncContext.fetchCount(FetchDescriptor<SessionRecord>()) == 0)

        // Unhiding allows re-import cleanly.
        SessionManagementService.unhideAllSessions(defaults: fixture.defaults)
        try await service.upsertSessions(
            [ToolSession(id: sessionID, tool: .claudeCode, startedAt: Date(), inputTokens: 100, outputTokens: 20, taskDescription: "Restored")],
            context: syncContext
        )
        try syncContext.save()
        #expect(try syncContext.fetchCount(FetchDescriptor<SessionRecord>()) == 1)
    }

    @Test func sessionManagementTrashModeCleansClaudeAntigravityAndCodexSources() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }

        let claudeID = UUID()
        let agID = UUID()
        let codexID = UUID()

        let claudeProjects = fixture.root.appending(path: "claude/projects")
        let claudeProject = claudeProjects.appending(path: "proj-a")
        try FileManager.default.createDirectory(at: claudeProject, withIntermediateDirectories: true)
        let claudeFile = claudeProject.appending(path: "\(claudeID.uuidString.lowercased()).jsonl")
        let claudeSubdir = claudeProject.appending(path: claudeID.uuidString.lowercased())
        try Data("{}".utf8).write(to: claudeFile)
        try FileManager.default.createDirectory(at: claudeSubdir, withIntermediateDirectories: true)

        let agBrain = fixture.root.appending(path: "brain")
        let agDir = agBrain.appending(path: agID.uuidString)
        try FileManager.default.createDirectory(at: agDir, withIntermediateDirectories: true)
        try Data("# AG".utf8).write(to: agDir.appending(path: "task.md"))

        let codexDir = fixture.root.appending(path: "codex")
        let codexSessions = codexDir.appending(path: "sessions/2026/11")
        try FileManager.default.createDirectory(at: codexSessions, withIntermediateDirectories: true)
        let codexRollout = codexSessions.appending(path: "rollout-2026-11-26T10-00-00-\(codexID.uuidString.lowercased()).jsonl")
        try Data("{}".utf8).write(to: codexRollout)

        // Create minimal state_5.sqlite threads table
        let dbURL = codexDir.appending(path: "state_5.sqlite")
        let db = try Connection(dbURL.path)
        try db.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, archived INTEGER DEFAULT 0)")
        try db.run("INSERT INTO threads (id, archived) VALUES (?, 0)", codexID.uuidString.lowercased())

        let context = ModelContext(fixture.container)
        context.autosaveEnabled = false
        context.insert(SessionRecord(id: claudeID, tool: .claudeCode, startedAt: Date(), taskDescription: "Claude"))
        context.insert(SessionRecord(id: agID, tool: .antigravity, startedAt: Date(), taskDescription: "AG"))
        context.insert(SessionRecord(id: codexID, tool: .codex, startedAt: Date(), taskDescription: "Codex"))
        try context.save()

        let paths = SessionManagementPaths(
            claudeProjectsDir: claudeProjects,
            configClaudeProjectsDir: fixture.root.appending(path: "missing-config"),
            codexDir: codexDir,
            antigravityBrainDir: agBrain
        )

        #expect(SessionManagementService.locateSourceURL(for: .claudeCode, sessionID: claudeID, paths: paths) != nil)
        #expect(SessionManagementService.locateSourceURL(for: .antigravity, sessionID: agID, paths: paths)?.standardizedFileURL == agDir.standardizedFileURL)
        #expect(SessionManagementService.locateSourceURL(for: .codex, sessionID: codexID, paths: paths)?.standardizedFileURL == codexRollout.standardizedFileURL)
        #expect(SessionManagementService.resumeCommand(for: .claudeCode, sessionID: claudeID, projectPath: "/tmp/app") == "cd '/tmp/app' && claude --resume \(claudeID.uuidString.lowercased())")
        #expect(SessionManagementService.resumeCommand(for: .codex, sessionID: codexID, projectPath: "") == "codex resume \(codexID.uuidString.lowercased())")
        #expect(SessionManagementService.resumeCommand(for: .antigravity, sessionID: agID, projectPath: "") == nil)

        let report = try await SessionManagementService.deleteSessions(
            [
                SessionDeletionTarget(id: claudeID, tool: .claudeCode, title: "Claude", projectPath: ""),
                SessionDeletionTarget(id: agID, tool: .antigravity, title: "AG", projectPath: ""),
                SessionDeletionTarget(id: codexID, tool: .codex, title: "Codex", projectPath: ""),
            ],
            mode: .trashLocalFiles,
            modelContainer: fixture.container,
            paths: paths,
            defaultsSuiteName: fixture.suiteName,
            trashItem: { url in
                try FileManager.default.removeItem(at: url)
            }
        )

        #expect(report.deletedRecords == 3)
        #expect(report.trashedURLs.count == 4) // claude jsonl + claude subdir + ag dir + codex rollout
        #expect(report.archivedCodexThreads == 1)
        #expect(report.warnings.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: claudeFile.path))
        #expect(!FileManager.default.fileExists(atPath: claudeSubdir.path))
        #expect(!FileManager.default.fileExists(atPath: agDir.path))
        #expect(!FileManager.default.fileExists(atPath: codexRollout.path))
        let archivedFlag = try db.scalar("SELECT archived FROM threads WHERE id = ?", codexID.uuidString.lowercased()) as? Int64
        #expect(archivedFlag == 1)
        #expect(try context.fetchCount(FetchDescriptor<SessionRecord>()) == 0)
    }

    private func cleanup(_ fixture: Fixture) {
        try? FileManager.default.removeItem(at: fixture.root)
        fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
    }
}

private actor AntigravityQuotaFixtureProvider {
    private var result: AGQuotaFetchResult

    init(_ result: AGQuotaFetchResult) { self.result = result }

    func fetch() -> AGQuotaFetchResult { result }

    func update(_ result: AGQuotaFetchResult) { self.result = result }
}

@MainActor
private final class LocalQuotaRefreshFixtureGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var isSuspended: Bool { continuation != nil }

    func suspend() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
