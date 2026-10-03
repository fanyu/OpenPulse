import XCTest
import SwiftData
@testable import OpenPulse

final class AntigravityProAggregatorTests: XCTestCase {
    func testAggregateProAccountsAveragesFractionsAndFindsEarliestReset() {
        let date1 = Date().addingTimeInterval(3600)
        let date2 = Date().addingTimeInterval(1800)
        
        let account1 = AGAccountQuota(
            email: "pro1@gmail.com",
            tier: AGTier(id: "gai-pro", name: "Google AI Pro"),
            groups: [
                AGQuotaGroup(
                    id: "gemini",
                    displayName: "Gemini",
                    fiveHour: AGWindow(kind: .fiveHour, remainingFraction: 0.8, resetTime: date1, description: nil),
                    weekly: AGWindow(kind: .weekly, remainingFraction: 0.6, resetTime: date1, description: nil)
                )
            ]
        )
        
        let account2 = AGAccountQuota(
            email: "pro2@gmail.com",
            tier: AGTier(id: "gai-pro", name: "Google AI Pro"),
            groups: [
                AGQuotaGroup(
                    id: "gemini",
                    displayName: "Gemini",
                    fiveHour: AGWindow(kind: .fiveHour, remainingFraction: 0.6, resetTime: date2, description: nil),
                    weekly: AGWindow(kind: .weekly, remainingFraction: 0.4, resetTime: date2, description: nil)
                )
            ]
        )
        
        let freeAccount = AGAccountQuota(
            email: "free@gmail.com",
            tier: AGTier(id: "free-tier", name: "Free Tier"),
            groups: [
                AGQuotaGroup(
                    id: "gemini",
                    displayName: "Gemini",
                    fiveHour: AGWindow(kind: .fiveHour, remainingFraction: 0.1, resetTime: date1, description: nil),
                    weekly: nil
                )
            ]
        )
        
        let summary = AntigravityProAggregator.aggregate(accounts: [account1, account2, freeAccount])
        
        XCTAssertEqual(summary.proAccountCount, 2)
        XCTAssertEqual(summary.groups.count, 1)
        
        let geminiGroup = summary.groups.first { $0.id == "gemini" }
        XCTAssertNotNil(geminiGroup)
        
        // 5h average = (0.8 + 0.6) / 2 = 0.7
        XCTAssertEqual(geminiGroup?.fiveHour?.remainingFraction ?? 0, 0.7, accuracy: 0.001)
        // Earliest reset = date2 (1800s in future vs 3600s)
        XCTAssertEqual(geminiGroup?.fiveHour?.validatedResetDate, date2)
        
        // Weekly average = (0.6 + 0.4) / 2 = 0.5
        XCTAssertEqual(geminiGroup?.weekly?.remainingFraction ?? 0, 0.5, accuracy: 0.001)
    }
    func testZeroWeeklyQuotaMarksFiveHourUnusableWhilePreservingPercentage() {
        let date = Date().addingTimeInterval(3600)
        let groupWithZeroWeekly = AGQuotaGroup(
            id: "gemini",
            displayName: "Gemini",
            fiveHour: AGWindow(kind: .fiveHour, remainingFraction: 1.0, resetTime: date, description: nil),
            weekly: AGWindow(kind: .weekly, remainingFraction: 0.0, resetTime: date, description: nil)
        )
        
        XCTAssertTrue(groupWithZeroWeekly.isFiveHourUnusable)
        XCTAssertEqual(groupWithZeroWeekly.fiveHour?.remainingPercentText, "100%")
        
        let account = AGAccountQuota(
            email: "pro1@gmail.com",
            tier: AGTier(id: "gai-pro", name: "Google AI Pro"),
            groups: [groupWithZeroWeekly]
        )
        
        let summary = AntigravityProAggregator.aggregate(accounts: [account])
        let geminiGroup = summary.groups.first { $0.id == "gemini" }
        XCTAssertEqual(geminiGroup?.fiveHour?.remainingFraction, 1.0)
        XCTAssertTrue(geminiGroup?.isFiveHourUnusable == true)
    }

    func testAverageFiveHourGeminiAcrossAllAccounts() {
        let account1 = AGAccountQuota(
            email: "pro1@gmail.com",
            tier: AGTier(id: "gai-pro", name: "Google AI Pro"),
            groups: [
                AGQuotaGroup(
                    id: "gemini",
                    displayName: "Gemini",
                    fiveHour: AGWindow(kind: .fiveHour, remainingFraction: 0.8, resetTime: nil, description: nil),
                    weekly: nil
                )
            ]
        )
        let account2 = AGAccountQuota(
            email: "pro2@gmail.com",
            tier: AGTier(id: "gai-pro", name: "Google AI Pro"),
            groups: [
                AGQuotaGroup(
                    id: "gemini",
                    displayName: "Gemini",
                    fiveHour: AGWindow(kind: .fiveHour, remainingFraction: 0.6, resetTime: nil, description: nil),
                    weekly: nil
                )
            ]
        )
        let freeAccount = AGAccountQuota(
            email: "free@gmail.com",
            tier: AGTier(id: "free-tier", name: "Free Tier"),
            groups: [
                AGQuotaGroup(
                    id: "gemini",
                    displayName: "Gemini",
                    fiveHour: AGWindow(kind: .fiveHour, remainingFraction: 0.1, resetTime: nil, description: nil),
                    weekly: nil
                )
            ]
        )

        // All accounts: (0.8 + 0.6 + 0.1) / 3 = 0.5 -> 50%
        let avgFraction = AGAccountQuota.averageFiveHourGeminiFraction(across: [account1, account2, freeAccount])
        XCTAssertEqual(avgFraction ?? 0, 0.5, accuracy: 0.001)

        let avgPercent = AGAccountQuota.averageFiveHourGeminiPercent(across: [account1, account2, freeAccount])
        XCTAssertEqual(avgPercent, 50)
    }

    func testAverageFiveHourGeminiWithEmptyOrMissingWindows() {
        XCTAssertNil(AGAccountQuota.averageFiveHourGeminiPercent(across: []))

        let nonGeminiAccount = AGAccountQuota(
            email: "other@gmail.com",
            tier: nil,
            groups: [
                AGQuotaGroup(
                    id: "3p",
                    displayName: "3P Models",
                    fiveHour: AGWindow(kind: .fiveHour, remainingFraction: 0.9, resetTime: nil, description: nil),
                    weekly: nil
                )
            ]
        )
        XCTAssertNil(AGAccountQuota.averageFiveHourGeminiPercent(across: [nonGeminiAccount]))
    }
}

@MainActor
final class ActivityHistorySnapshotTests: XCTestCase {
    func testReaderIncludesAllHistoryAndBuildsSummariesByFullProjectPath() async throws {
        let fixture = try makeFixture()
        let snapshot = try await readSnapshot(from: fixture.container)

        XCTAssertEqual(snapshot.sessions.map(\.id), [fixture.latest.id, fixture.claude.id, fixture.oldest.id])
        XCTAssertEqual(Set(snapshot.sessionsByID.keys), Set(snapshot.sessions.map(\.id)))
        XCTAssertEqual(snapshot.allSummary.count, 3)
        XCTAssertEqual(snapshot.allSummary.tokens, 200)
        XCTAssertEqual(snapshot.allSummary.averageTokens, 66)
        XCTAssertEqual(snapshot.sessionsByTool[.codex]?.map(\.id), [fixture.latest.id, fixture.oldest.id])
        XCTAssertEqual(snapshot.sessionsByTool[.claudeCode]?.map(\.id), [fixture.claude.id])
        XCTAssertEqual(snapshot.allSummary.favoriteProject, "/Fixture/Alpha/shared")
        XCTAssertEqual(snapshot.summaries[.codex]?.count, 2)
        XCTAssertEqual(snapshot.summaries[.codex]?.tokens, 130)
        XCTAssertEqual(snapshot.summaries[.codex]?.averageTokens, 65)
        XCTAssertEqual(snapshot.summaries[.claudeCode]?.count, 1)
        XCTAssertEqual(snapshot.summaries[.claudeCode]?.tokens, 70)
        XCTAssertNil(snapshot.summaries[.copilot])
        XCTAssertNil(snapshot.summaries[.antigravity])
    }

    func testFreshReaderSeesCommittedSameCountUpdatesToTokensAndSearchableFields() async throws {
        let fixture = try makeFixture()
        let initial = try await readSnapshot(from: fixture.container)
        let initialCount = try fixture.context.fetchCount(FetchDescriptor<SessionRecord>())

        fixture.latest.inputTokens = 200
        fixture.latest.outputTokens = 30
        fixture.latest.cacheReadTokens = 17
        fixture.latest.cacheWriteTokens = 9
        fixture.latest.taskDescription = "Réviser le café"
        fixture.latest.model = "fixture-updated"
        fixture.latest.cwd = "/Fixture/Changed/façade"
        fixture.latest.gitBranch = "feature/résumé"
        fixture.latest.endedAt = fixture.latest.startedAt.addingTimeInterval(600)
        try fixture.context.save()

        let refreshed = try await readSnapshot(from: fixture.container)
        let row = try XCTUnwrap(refreshed.sessionsByID[fixture.latest.id])
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<SessionRecord>()), initialCount)
        XCTAssertEqual(refreshed.sessions.count, initial.sessions.count)
        XCTAssertEqual(initial.sessionsByID[fixture.latest.id]?.totalTokens, 30)
        XCTAssertEqual(row.totalTokens, 230)
        XCTAssertEqual(row.cacheReadTokens, 17)
        XCTAssertEqual(row.cacheWriteTokens, 9)
        XCTAssertEqual(row.task, "Réviser le café")
        XCTAssertEqual(row.model, "fixture-updated")
        XCTAssertEqual(row.projectPath, "/Fixture/Changed/façade")
        XCTAssertEqual(row.branch, "feature/résumé")
        XCTAssertEqual(row.endedAt, fixture.latest.endedAt)
        XCTAssertEqual(refreshed.allSummary.tokens, 400)
        XCTAssertEqual(refreshed.summaries[.codex]?.tokens, 330)
        XCTAssertEqual(refreshed.summaries[.codex]?.favoriteProject, "/Fixture/Changed/façade")
        XCTAssertEqual(refreshed.allSummary.favoriteProject, "/Fixture/Changed/façade")
        XCTAssertEqual(try refreshed.filtered(tool: .codex, search: "CAFE").sessions.map(\.id), [row.id])
        XCTAssertEqual(try refreshed.filtered(tool: nil, search: "FACADE").sessions.map(\.id), [row.id])
        XCTAssertEqual(try refreshed.filtered(tool: nil, search: "RESUME").sessions.map(\.id), [row.id])
        XCTAssertTrue(try refreshed.filtered(tool: nil, search: "Initial latest session").sessions.isEmpty)
    }

    func testFilterUsesLocalizedMatchingForTaskPathAndBranchWithToolConstraint() throws {
        let taskMatch = ActivitySessionSnapshot(tool: .codex, startedAt: Date(timeIntervalSince1970: 3), task: "Fix the café")
        let pathMatch = ActivitySessionSnapshot(tool: .claudeCode, startedAt: Date(timeIntervalSince1970: 2), projectPath: "/Fixture/façade/project")
        let branchMatch = ActivitySessionSnapshot(tool: .codex, startedAt: Date(timeIntervalSince1970: 1), branch: "feature/résumé")
        let snapshot = try ActivityHistorySnapshot(sessions: [taskMatch, pathMatch, branchMatch])

        XCTAssertEqual(try snapshot.filtered(tool: nil, search: "CAFE").sessions.map(\.id), [taskMatch.id])
        XCTAssertEqual(try snapshot.filtered(tool: nil, search: "FACADE").sessions.map(\.id), [pathMatch.id])
        XCTAssertEqual(try snapshot.filtered(tool: nil, search: "RESUME").visibleIDs, Set([branchMatch.id]))
        XCTAssertTrue(try snapshot.filtered(tool: .codex, search: "facade").sessions.isEmpty)
        XCTAssertEqual(try snapshot.filtered(tool: .codex, search: "").sessions.map(\.id), [taskMatch.id, branchMatch.id])
        XCTAssertEqual(try snapshot.filtered(tool: nil, search: "").visibleIDs, Set([taskMatch.id, pathMatch.id, branchMatch.id]))
    }

    func testOlderUncooperativeReloadCannotReplaceNewerSnapshot() async throws {
        let model = ActivityHistoryModel()
        let oldRow = ActivitySessionSnapshot(tool: .codex, startedAt: Date(timeIntervalSince1970: 1), inputTokens: 1, task: "Old response")
        let newRow = ActivitySessionSnapshot(tool: .codex, startedAt: Date(timeIntervalSince1970: 2), inputTokens: 20, task: "New response")
        let oldSnapshot = try ActivityHistorySnapshot(sessions: [oldRow])
        let newSnapshot = try ActivityHistorySnapshot(sessions: [newRow])
        let oldGate = ActivityHistoryFixtureGate()
        let newGate = ActivityHistoryFixtureGate()

        let oldLoad = model.reload {
            await oldGate.suspend()
            return oldSnapshot
        }
        await oldGate.waitUntilStarted()
        let newLoad = model.reload {
            await newGate.suspend()
            return newSnapshot
        }
        await newGate.waitUntilStarted()
        await newGate.release()
        await newLoad.value
        await model.waitForPendingFilter()
        let acceptedRevision = model.snapshotRevision
        XCTAssertEqual(model.snapshot.sessions.map(\.id), [newRow.id])
        XCTAssertEqual(model.filtered.visibleIDs, Set([newRow.id]))

        XCTAssertTrue(oldLoad.isCancelled)
        await oldGate.release()
        await oldLoad.value
        await model.waitForPendingFilter()
        XCTAssertEqual(model.snapshot.sessions.map(\.id), [newRow.id])
        XCTAssertEqual(model.snapshot.allSummary.tokens, 20)
        XCTAssertEqual(model.filtered.visibleIDs, Set([newRow.id]))
        XCTAssertEqual(model.snapshotRevision, acceptedRevision)
    }

    func testOlderUncooperativeFilterCannotReplaceNewerSearchResult() async throws {
        let model = ActivityHistoryModel()
        let older = ActivitySessionSnapshot(tool: .codex, startedAt: Date(timeIntervalSince1970: 1), task: "Older task")
        let newer = ActivitySessionSnapshot(tool: .claudeCode, startedAt: Date(timeIntervalSince1970: 2), task: "Newer task")
        let snapshot = try ActivityHistorySnapshot(sessions: [newer, older])
        await model.reload { snapshot }.value
        await model.waitForPendingFilter()
        let snapshotRevision = model.snapshotRevision
        let oldGate = ActivityHistoryFixtureGate()
        let newGate = ActivityHistoryFixtureGate()

        let oldFilter = model.filter(tool: .codex, search: "older") { snapshot, tool, search in
            let result = try snapshot.filtered(tool: tool, search: search)
            await oldGate.suspend()
            return result
        }
        await oldGate.waitUntilStarted()
        let newFilter = model.filter(tool: .claudeCode, search: "newer") { snapshot, tool, search in
            let result = try snapshot.filtered(tool: tool, search: search)
            await newGate.suspend()
            return result
        }
        await newGate.waitUntilStarted()
        await newGate.release()
        await newFilter.value
        let acceptedRevision = model.filterRevision
        XCTAssertEqual(model.filtered.sessions.map(\.id), [newer.id])
        XCTAssertEqual(model.filtered.visibleIDs, Set([newer.id]))

        XCTAssertTrue(oldFilter.isCancelled)
        await oldGate.release()
        await oldFilter.value
        XCTAssertEqual(model.filtered.sessions.map(\.id), [newer.id])
        XCTAssertEqual(model.filtered.visibleIDs, Set([newer.id]))
        XCTAssertEqual(model.filterRevision, acceptedRevision)
        XCTAssertEqual(model.snapshotRevision, snapshotRevision)
    }

    func testNewSnapshotInvalidatesFilterBasedOnPreviousSnapshot() async throws {
        let model = ActivityHistoryModel()
        let id = UUID()
        let original = ActivitySessionSnapshot(id: id, tool: .codex, startedAt: Date(timeIntervalSince1970: 1), inputTokens: 1, task: "Initial task")
        let updated = ActivitySessionSnapshot(id: id, tool: .codex, startedAt: original.startedAt, inputTokens: 20, task: "Updated task")
        let initialSnapshot = try ActivityHistorySnapshot(sessions: [original])
        let updatedSnapshot = try ActivityHistorySnapshot(sessions: [updated])
        await model.reload { initialSnapshot }.value
        await model.waitForPendingFilter()
        let gate = ActivityHistoryFixtureGate()
        let staleFilter = model.filter(tool: .codex, search: "initial") { snapshot, tool, search in
            let result = try snapshot.filtered(tool: tool, search: search)
            await gate.suspend()
            return result
        }
        await gate.waitUntilStarted()

        await model.reload { updatedSnapshot }.value
        await model.waitForPendingFilter()
        let acceptedRevision = model.filterRevision
        XCTAssertEqual(model.snapshot.sessionsByID[id]?.task, "Updated task")
        XCTAssertTrue(model.filtered.sessions.isEmpty)

        await gate.release()
        await staleFilter.value
        XCTAssertTrue(model.filtered.sessions.isEmpty)
        XCTAssertTrue(model.filtered.visibleIDs.isEmpty)
        XCTAssertEqual(model.filterRevision, acceptedRevision)
    }

    private func readSnapshot(from container: ModelContainer) async throws -> ActivityHistorySnapshot {
        try await Task.detached {
            let reader = ActivityHistorySnapshotReader(modelContainer: container)
            return try await reader.read()
        }.value
    }

    private func makeFixture() throws -> ActivityHistoryFixture {
        let schema = Schema([SessionRecord.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let oldest = SessionRecord(tool: .codex, startedAt: Date(timeIntervalSince1970: 1_000), inputTokens: 90, outputTokens: 10, taskDescription: "Historic session", cwd: "/Fixture/Alpha/shared")
        let claude = SessionRecord(tool: .claudeCode, startedAt: Date(timeIntervalSince1970: 2_000_000_000), inputTokens: 60, outputTokens: 10, taskDescription: "Claude fixture", cwd: "/Fixture/Beta/shared")
        let latest = SessionRecord(tool: .codex, startedAt: Date(timeIntervalSince1970: 2_000_000_001), inputTokens: 20, outputTokens: 10, taskDescription: "Initial latest session", cwd: "/Fixture/Alpha/shared")
        let copilot = SessionRecord(tool: .copilot, startedAt: Date(timeIntervalSince1970: 2_000_000_002), inputTokens: 800, taskDescription: "Unsupported Copilot fixture")
        let antigravity = SessionRecord(tool: .antigravity, startedAt: Date(timeIntervalSince1970: 2_000_000_003), inputTokens: 800, taskDescription: "Unsupported Antigravity fixture")
        let unknown = SessionRecord(tool: .codex, startedAt: Date(timeIntervalSince1970: 2_000_000_004), inputTokens: 800, taskDescription: "Unknown tool fixture")
        unknown.toolRaw = "future-tool"
        for record in [oldest, claude, latest, copilot, antigravity, unknown] {
            context.insert(record)
        }
        try context.save()
        return ActivityHistoryFixture(container: container, context: context, oldest: oldest, claude: claude, latest: latest)
    }
}

@MainActor
private struct ActivityHistoryFixture {
    let container: ModelContainer
    let context: ModelContext
    let oldest: SessionRecord
    let claude: SessionRecord
    let latest: SessionRecord
}

private actor ActivityHistoryFixtureGate {
    private var started = false
    private var released = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    // Deliberately ignores cancellation to model work that finishes after a newer request.
    func suspend() async {
        started = true
        startedWaiters.forEach { $0.resume() }
        startedWaiters.removeAll()
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

final class ActivitySessionRenderWindowTests: XCTestCase {
    func testLargeFilteredHistoryRemainsCompleteWhileDuplicatePaginationIsRejected() throws {
        let total = 49_270
        let rows = (0..<total).map { index in
            ActivitySessionSnapshot(tool: .codex, startedAt: Date(timeIntervalSince1970: TimeInterval(index)))
        }
        let result = try ActivityHistoryFilterResult(sessions: rows)
        var window = ActivitySessionRenderWindow()

        XCTAssertEqual(window.visibleCount(total: result.sessions.count), 200)
        XCTAssertTrue(window.revealNext(total: result.sessions.count, boundary: 200))
        XCTAssertEqual(window.visibleCount(total: result.sessions.count), 400)
        XCTAssertFalse(window.revealNext(total: result.sessions.count, boundary: 200))
        XCTAssertEqual(window.visibleCount(total: result.sessions.count), 400)
        XCTAssertEqual(result.sessions.count, total)
        XCTAssertEqual(result.visibleIDs.count, total)
        XCTAssertEqual(result.sessions.last?.id, rows.last?.id)
    }

    func testRefreshRetainsRenderedRangeAndNewQueryKeepsSelectionReachable() {
        let total = 49_270
        var window = ActivitySessionRenderWindow()
        window.update(total: total, selectedIndex: 999, reset: false)
        XCTAssertTrue(window.revealNext(total: total, boundary: 1_000))
        XCTAssertEqual(window.visibleCount(total: total), 1_200)

        // A same-query refresh must preserve the user's expanded scroll range.
        window.update(total: total, selectedIndex: 350, reset: false)
        XCTAssertEqual(window.visibleCount(total: total), 1_200)

        // A new query reduces the range while retaining the selected row.
        window.update(total: total, selectedIndex: 350, reset: true)
        XCTAssertEqual(window.visibleCount(total: total), 400)
        XCTAssertGreaterThan(window.visibleCount(total: total), 350)

        window.revealAll(total: total)
        XCTAssertEqual(window.visibleCount(total: total), total)
        XCTAssertGreaterThan(window.visibleCount(total: total), total - 1)
    }
}
