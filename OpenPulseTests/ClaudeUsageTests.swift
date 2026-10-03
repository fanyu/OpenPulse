import Testing
import Foundation
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

// Config editor regressions use isolated synthetic files, never local tool data.
@MainActor
struct ConfigsEditorRegressionTests {
    @Test func successiveSavesRefreshBackupAndPreserveRestrictivePermissions() throws {
        let fixture = try makeFixture(contents: "model = \"fixture-a\"\n")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.file.url.path)
        let model = ConfigsViewModel()
        model.selectedFile = fixture.file
        model.editorContent = "model = \"fixture-b\"\n"
        #expect(model.saveFile(fixture.file))
        let backup = fixture.file.url.appendingPathExtension("bak")
        #expect(try String(contentsOf: backup, encoding: .utf8) == "model = \"fixture-a\"\n")

        model.editorContent = "model = \"fixture-c\"\n"
        #expect(model.saveFile(fixture.file))
        #expect(try String(contentsOf: fixture.file.url, encoding: .utf8) == "model = \"fixture-c\"\n")
        #expect(try String(contentsOf: backup, encoding: .utf8) == "model = \"fixture-b\"\n")
        let permissions = try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        #expect(!model.isDirty)
        #expect(model.saveError == nil)
    }

    @Test func externalEditsBlockSaveAndKeepTheDraft() throws {
        let fixture = try makeFixture(contents: "model = \"loaded\"\n")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let model = ConfigsViewModel()
        model.selectedFile = fixture.file
        model.editorContent = "model = \"unsaved-draft\"\n"
        try "model = \"external-edit\"\n".write(to: fixture.file.url, atomically: true, encoding: .utf8)

        #expect(!model.saveFile(fixture.file))
        #expect(try String(contentsOf: fixture.file.url, encoding: .utf8) == "model = \"external-edit\"\n")
        #expect(model.editorContent == "model = \"unsaved-draft\"\n")
        #expect(model.isDirty)
        #expect(model.saveError != nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.file.url.appendingPathExtension("bak").path))
    }

    @Test func createDoesNotOverwriteAFileThatAppearedAfterTheRead() throws {
        let fixture = try makeFixture(contents: nil)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let model = ConfigsViewModel()
        model.selectedFile = fixture.file
        #expect(model.fileIsMissing)
        try "model = \"created-elsewhere\"\n".write(to: fixture.file.url, atomically: true, encoding: .utf8)

        model.createFile(fixture.file)
        #expect(try String(contentsOf: fixture.file.url, encoding: .utf8) == "model = \"created-elsewhere\"\n")
        #expect(!model.fileIsMissing)
        #expect(model.loadError != nil)
        model.loadFile(fixture.file)
        #expect(model.editorContent == "model = \"created-elsewhere\"\n")
        #expect(model.loadError == nil)
    }

    @Test func jsonFormattingUpdatesDirtyStateAndRoundTripsThroughRevertAndSave() throws {
        let original = "{\"z\":2,\"a\":1}"
        let fixture = try makeFixture(fileExtension: "json", contents: original)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let model = ConfigsViewModel()
        model.selectedFile = fixture.file
        model.formatJSON()
        #expect(model.isDirty)
        #expect(model.editorContent != original)
        let formattedObject = try JSONSerialization.jsonObject(with: Data(model.editorContent.utf8)) as? [String: Int]
        #expect(formattedObject == ["a": 1, "z": 2])

        model.revert()
        #expect(model.editorContent == original)
        #expect(!model.isDirty)
        model.formatJSON()
        #expect(model.saveFile(fixture.file))
        #expect(!model.isDirty)
        #expect(model.savedContent == model.editorContent)
        #expect(try String(contentsOf: fixture.file.url.appendingPathExtension("bak"), encoding: .utf8) == original)
    }

    @Test func selectingTheCurrentFileKeepsUnsavedChanges() throws {
        let fixture = try makeFixture(contents: "model = \"loaded\"\n")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let model = ConfigsViewModel()
        model.selectedFile = fixture.file
        model.editorContent = "model = \"draft\"\n"
        model.selectedFile = fixture.file
        #expect(model.editorContent == "model = \"draft\"\n")
        #expect(model.isDirty)
    }

    @Test func appStoreRetainsTheEditorDraftAcrossTabChanges() {
        let store = AppStore(inMemory: true)
        let editor = store.configsViewModel
        editor.editorContent = "synthetic unsaved draft"
        store.selectedTab = .configs
        store.selectedTab = .quota
        store.selectedTab = .configs
        #expect(store.configsViewModel === editor)
        #expect(store.configsViewModel.editorContent == "synthetic unsaved draft")
        #expect(store.configsViewModel.isDirty)
    }

    private func makeFixture(fileExtension: String = "toml", contents: String?) throws -> (directory: URL, file: ConfigFile) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OpenPulseConfigsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = ConfigFile(id: UUID().uuidString, toolName: "Fixture", displayName: "fixture.\(fileExtension)", url: directory.appendingPathComponent("fixture.\(fileExtension)"), kind: .config)
        if let contents { try contents.write(to: file.url, atomically: true, encoding: .utf8) }
        return (directory, file)
    }
}

import WebKit

@MainActor
struct ConfigsMarkdownSecurityTests {
    @Test func markdownTreatsScriptClosingQuotesAndUnsafeLinksAsContent() async throws {
        let source = #"""
        # Security fixture
        </script><script>window.__openPulseInjected = true</script>
        [Unsafe](javascript:window.__openPulseInjected=true)
        [Quote](https://example.invalid/" onmouseover="window.__openPulseInjected=true")
        """#
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 500, height: 400), configuration: configuration)
        let loader = ConfigsPreviewFixtureLoader()
        defer { webView.stopLoading(); webView.navigationDelegate = nil }
        try await loader.load(configMarkdownHTML(source: source), in: webView)
        let result = try await webView.evaluateJavaScript(#"""
        (() => {
            const links = [...document.querySelectorAll('a')];
            for (const link of links) link.dispatchEvent(new MouseEvent('mouseover'));
            return {
                injected: window.__openPulseInjected === true,
                unsafeHrefCount: links.filter(link => /^\s*javascript:/i.test(link.getAttribute('href') || '')).length,
                inlineHandlerCount: links.filter(link => link.hasAttribute('onclick') || link.hasAttribute('onmouseover')).length,
                anchorCount: links.length,
                closingScriptIsText: document.getElementById('c').textContent.includes('</script>'),
                documentRendered: document.querySelector('h1').textContent === 'Security fixture'
            };
        })()
        """#)
        let values = try #require(result as? [String: Any])
        #expect(values["documentRendered"] as? Bool == true)
        #expect(values["closingScriptIsText"] as? Bool == true)
        #expect(values["injected"] as? Bool == false)
        #expect(values["unsafeHrefCount"] as? Int == 0)
        #expect(values["inlineHandlerCount"] as? Int == 0)
        #expect(values["anchorCount"] as? Int == 1)
    }
}

@MainActor
private final class ConfigsPreviewFixtureLoader: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?

    func load(_ html: String, in webView: WKWebView) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.navigationDelegate = self
            webView.loadHTMLString(html, baseURL: nil)
            timeout = Task {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                finish(.failure(NSError(domain: "OpenPulse.ConfigsPreviewTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Synthetic preview load timed out"])))
            }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        // Even an unexpectedly rendered payload cannot navigate to the network.
        let scheme = navigationAction.request.url?.scheme?.lowercased()
        return scheme == nil || scheme == "about" ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        continuation.resume(with: result)
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
        antigravityQuotaFetch: (@MainActor () async throws -> AGQuotaFetchResult)? = nil,
        postRefresh: @escaping @MainActor (Tool?) async -> Void
    ) -> DataSyncService {
        let parser = ClaudeCodeParser(
            claudeDir: fixture.root.appending(path: "claude"),
            configProjectsDir: fixture.root.appending(path: "config/projects"),
            claudeDesktopDir: fixture.root.appending(path: "desktop"),
            statusCacheURL: fixture.root.appending(path: "bridge.json")
        )
        let antigravityParser = AntigravityParser(brainDir: fixture.root.appending(path: "brain"), accountService: nil)
        return DataSyncService(modelContainer: fixture.container, codexAccountService: CodexAccountService(), deskSnapshotPublisher: nil, restoreCachedSnapshots: restoreCachedSnapshots, claudeParser: parser, antigravityParser: antigravityParser, cacheDefaults: fixture.defaults, postRefresh: postRefresh, antigravityQuotaFetch: antigravityQuotaFetch)
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
