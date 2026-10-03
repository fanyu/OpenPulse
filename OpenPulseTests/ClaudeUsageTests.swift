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
