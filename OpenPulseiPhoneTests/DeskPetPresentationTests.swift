import Foundation
import Testing
@testable import OpenPulseiPhone

struct DeskPetPresentationTests {
    @Test
    func exhaustedSessionWithFutureResetShowsCountdown() {
        let now = Date(timeIntervalSince1970: 1_000)
        let usage = DeskUsagePresentation(
            label: "5h limit",
            percentText: "0%",
            resetText: "Today 02:02",
            fraction: 0,
            isAvailable: true,
            remaining: 0,
            resetAt: Date(timeIntervalSince1970: 4_723)
        )

        #expect(usage.resetCountdown(at: now)?.text == "01:02:03")
    }

    @Test
    func nonzeroOrExpiredSessionDoesNotShowCountdown() {
        let now = Date(timeIntervalSince1970: 1_000)
        let nonzero = DeskUsagePresentation(
            label: "5h limit",
            percentText: "1%",
            resetText: "Today 02:02",
            fraction: 0.01,
            isAvailable: true,
            remaining: 1,
            resetAt: Date(timeIntervalSince1970: 4_723)
        )
        let expired = DeskUsagePresentation(
            label: "5h limit",
            percentText: "0%",
            resetText: "Today 00:16",
            fraction: 0,
            isAvailable: true,
            remaining: 0,
            resetAt: Date(timeIntervalSince1970: 999)
        )

        #expect(nonzero.resetCountdown(at: now) == nil)
        #expect(expired.resetCountdown(at: now) == nil)
    }

    @Test
    func criticalSnapshotMapsToAlertPresentation() {
        let presentation = DeskPetPresentation.make(
            from: .init(
                tool: .codex,
                displayLabel: "Codex",
                remaining: 10,
                total: 100,
                fraction: 0.1,
                resetAt: Date(timeIntervalSince1970: 2_000),
                weekly: .init(
                    label: "7d Weekly",
                    remaining: 72,
                    total: 100,
                    fraction: 0.72,
                    resetAt: Date(timeIntervalSince1970: 9_000)
                ),
                status: .critical,
                petState: .alert
            ),
            now: Date(timeIntervalSince1970: 1_000)
        )

        #expect(presentation.motion == .alert)
        #expect(presentation.session.percentText == "10%")
        #expect(presentation.weekly.percentText == "72%")
    }

    @Test
    func staleSnapshotMapsToWaitingPresentation() {
        let presentation = DeskPetPresentation.make(
            from: .init(
                tool: .claudeCode,
                displayLabel: "Claude",
                remaining: 42,
                total: 100,
                fraction: 0.42,
                resetAt: Date(timeIntervalSince1970: 3_000),
                weekly: nil,
                status: .stale,
                petState: .waiting
            ),
            now: Date(timeIntervalSince1970: 1_000)
        )

        #expect(presentation.motion == .waiting)
        #expect(presentation.isStale)
    }

    @Test
    func exhaustedPresentationMapsToExhaustedMotion() {
        let presentation = DeskPetPresentation(
            tool: .claudeCode,
            title: "Claude",
            session: .init(
                label: "5h Session",
                percentText: "0%",
                resetText: "Resets today 16:05",
                fraction: 0,
                isAvailable: true
            ),
            weekly: .init(
                label: "7d Weekly",
                percentText: "54%",
                resetText: "Resets Jul 12, 09:30",
                fraction: 0.54,
                isAvailable: true
            ),
            status: .exhausted,
            motion: .exhausted,
            isStale: false
        )

        #expect(presentation.motion == .exhausted)
    }

    @MainActor
    @Test
    func appStoreStartsInWaitingStateWithoutSnapshot() async throws {
        let store = DeskModeAppStore(client: .init(fetchCurrent: { nil }))
        await store.refresh()

        #expect(store.snapshot == nil)
        #expect(store.statusText == "Waiting for Mac")
    }

    @MainActor
    @Test
    func appStoreTickMarksDelayedSnapshotsAfterTenMinutes() {
        let store = DeskModeAppStore(
            client: .init(fetchCurrent: { nil }),
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        store.snapshot = makeSnapshot(updatedAt: Date(timeIntervalSince1970: 100))

        store.tick(now: Date(timeIntervalSince1970: 1_000))

        #expect(store.statusText == "Sync delayed")
    }

    @MainActor
    @Test
    func appStoreTickKeepsRecentSnapshotsFresh() {
        let store = DeskModeAppStore(
            client: .init(fetchCurrent: { nil }),
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        store.snapshot = makeSnapshot(updatedAt: Date(timeIntervalSince1970: 955))

        store.tick(now: Date(timeIntervalSince1970: 1_000))

        #expect(store.statusText == "Synced 45s ago")
    }

    @Test
    func expiredSessionAwaitsRefreshInsteadOfKeepingExhaustedQuota() {
        let now = Date(timeIntervalSince1970: 2_000)
        let presentation = DeskPetPresentation.make(
            from: makeToolSnapshot(sessionResetAt: now, remaining: 0, status: .exhausted),
            now: now
        )

        #expect(presentation.session.percentText == "--%")
        #expect(presentation.session.resetText == "Awaiting refresh")
        #expect(presentation.session.fraction == nil)
        #expect(!presentation.session.isAvailable)
        #expect(presentation.session.resetCountdown(at: now) == nil)
        #expect(presentation.weekly.percentText == "51%")
        #expect(presentation.status == .stale)
        #expect(presentation.motion == .waiting)
        #expect(presentation.exhaustedUsage == nil)
    }

    @Test
    func expiredWeeklyWindowDoesNotRestoreItsBalance() {
        let now = Date(timeIntervalSince1970: 2_000)
        let presentation = DeskPetPresentation.make(
            from: makeToolSnapshot(
                sessionResetAt: Date(timeIntervalSince1970: 3_000),
                weeklyResetAt: now,
                weeklyRemaining: 0,
                status: .exhausted,
                petState: .exhausted
            ),
            now: now
        )

        #expect(presentation.session.percentText == "68%")
        #expect(presentation.weekly.percentText == "--%")
        #expect(presentation.weekly.resetText == "Awaiting refresh")
        #expect(presentation.weekly.fraction == nil)
        #expect(!presentation.weekly.isAvailable)
        #expect(presentation.motion == .waiting)
        #expect(presentation.exhaustedUsage == nil)
    }

    @Test
    func futureWeeklyExhaustionPreservesSessionBalance() {
        let presentation = DeskPetPresentation.make(
            from: makeToolSnapshot(
                weeklyRemaining: 0,
                status: .exhausted,
                petState: .exhausted
            ),
            now: Date(timeIntervalSince1970: 1_000)
        )

        #expect(presentation.session.percentText == "68%")
        #expect(presentation.weekly.percentText == "0%")
        #expect(presentation.weekly.isAvailable)
        #expect(presentation.status == .exhausted)
        #expect(presentation.motion == .exhausted)
        #expect(!presentation.isStale)
        #expect(presentation.exhaustedUsage == presentation.weekly)
        #expect(presentation.exhaustedUsage?.resetCountdown(at: Date(timeIntervalSince1970: 1_000))?.text == "01:56:40")
    }

    @Test
    func agedEnvelopeSuppressesExhaustedCountdownUntilRefresh() {
        let now = Date(timeIntervalSince1970: 1_556)
        let presentation = DeskPetPresentation.make(
            from: makeToolSnapshot(remaining: 0, status: .exhausted, petState: .exhausted),
            now: now,
            snapshotUpdatedAt: Date(timeIntervalSince1970: 955)
        )

        #expect(presentation.session.remaining == 0)
        #expect(presentation.session.resetCountdown(at: now) != nil)
        #expect(presentation.status == .stale)
        #expect(presentation.motion == .waiting)
        #expect(presentation.exhaustedUsage == nil)
    }

    @Test
    func recentEnvelopePreservesProducerStaleState() {
        let now = Date(timeIntervalSince1970: 1_000)
        let presentation = DeskPetPresentation.make(
            from: makeToolSnapshot(status: .stale),
            now: now,
            snapshotUpdatedAt: now
        )

        #expect(presentation.status == .stale)
        #expect(presentation.motion == .waiting)
        #expect(presentation.isStale)
    }

    @MainActor
    @Test
    func appStoreTickAgesPetPresentationAtTenMinuteBoundary() {
        let store = DeskModeAppStore(
            client: .init(fetchCurrent: { nil }),
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        store.snapshot = makeSnapshot(updatedAt: Date(timeIntervalSince1970: 955))

        store.tick(now: Date(timeIntervalSince1970: 1_555))
        #expect(store.codexPresentation?.motion == .patrol)
        #expect(store.codexPresentation?.isStale == false)

        store.tick(now: Date(timeIntervalSince1970: 1_556))
        #expect(store.codexPresentation?.status == .stale)
        #expect(store.codexPresentation?.motion == .waiting)
        #expect(store.claudePresentation?.isStale == true)
    }

    @MainActor
    @Test
    func refreshFailureSurvivesTicksAndRecoversWithoutDroppingSnapshot() async {
        let expected = makeSnapshot(updatedAt: Date(timeIntervalSince1970: 955))
        let responses = DeskSnapshotResponseSequence([
            .failure(.unavailable),
            .success(expected),
        ])
        let store = DeskModeAppStore(
            client: .init(fetchCurrent: { try await responses.fetch() }),
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        store.snapshot = expected

        await store.refresh()
        store.tick(now: Date(timeIntervalSince1970: 1_556))

        #expect(store.snapshot == expected)
        #expect(store.statusText == "Cloud sync unavailable")
        #expect(store.codexPresentation?.motion == .waiting)

        await store.refresh()

        #expect(store.snapshot == expected)
        #expect(store.statusText == "Synced 45s ago")
    }

    @MainActor
    @Test
    func concurrentRefreshesShareOneFetch() async {
        let gate = DeskSnapshotFetchGate()
        let store = DeskModeAppStore(
            client: .init(fetchCurrent: { try await gate.fetch() }),
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        let first = Task { await store.refresh() }
        await gate.waitUntilStarted()

        let secondStarted = DeskRefreshStartSignal()
        let second = Task { @MainActor in
            secondStarted.signal()
            await store.refresh()
        }
        await secondStarted.wait()

        let expected = makeSnapshot(updatedAt: Date(timeIntervalSince1970: 955))
        gate.complete(with: expected)
        await first.value
        await second.value

        #expect(gate.fetchCount == 1)
        #expect(store.snapshot == expected)
    }

    @MainActor
    @Test
    func olderOrMissingRefreshDoesNotReplaceLastKnownSnapshot() async {
        let expected = makeSnapshot(updatedAt: Date(timeIntervalSince1970: 955))
        let responses = DeskSnapshotResponseSequence([
            .success(makeSnapshot(updatedAt: Date(timeIntervalSince1970: 100))),
            .success(nil),
        ])
        let store = DeskModeAppStore(
            client: .init(fetchCurrent: { try await responses.fetch() }),
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        store.snapshot = expected

        await store.refresh()
        #expect(store.snapshot == expected)

        await store.refresh()
        #expect(store.snapshot == expected)
    }

    @Test
    func validKeyValueSnapshotAvoidsCloudKitFetch() async throws {
        let expected = makeSnapshot(updatedAt: Date(timeIntervalSince1970: 955))
        let data = try DeskSnapshotJSONCodec.encode(expected)
        let client = DeskSnapshotCloudKitClient(
            readKeyValueData: { data },
            fetchCloudKitSnapshot: { throw DeskSnapshotFixtureError.unexpectedCloudKitFetch }
        )

        #expect(try await client.fetchCurrent() == expected)
    }

    @Test
    func corruptKeyValueSnapshotFallsBackToCloudKit() async throws {
        let expected = makeSnapshot(updatedAt: Date(timeIntervalSince1970: 955))
        let client = DeskSnapshotCloudKitClient(
            readKeyValueData: { Data("invalid snapshot".utf8) },
            fetchCloudKitSnapshot: { expected }
        )

        #expect(try await client.fetchCurrent() == expected)
    }

    @Test
    func corruptKeyValueSnapshotReportsMissingFallback() async throws {
        let client = DeskSnapshotCloudKitClient(
            readKeyValueData: { Data("invalid snapshot".utf8) },
            fetchCloudKitSnapshot: { nil }
        )

        do {
            _ = try await client.fetchCurrent()
            Issue.record("Expected an unreadable snapshot error")
        } catch DeskSnapshotCloudKitClient.FetchError.invalidKeyValueSnapshot {
            // Neither transport supplied a usable snapshot.
        }
    }

    @Test
    func corruptKeyValueSnapshotReportsUnavailableFallback() async throws {
        let client = DeskSnapshotCloudKitClient(
            readKeyValueData: { Data("invalid snapshot".utf8) },
            fetchCloudKitSnapshot: { throw DeskSnapshotFixtureError.unavailable }
        )

        do {
            _ = try await client.fetchCurrent()
            Issue.record("Expected a replacement snapshot error")
        } catch DeskSnapshotCloudKitClient.FetchError.invalidKeyValueAndCloudKitUnavailable {
            // The unreadable local snapshot did not prevent attempting the fallback.
        }
    }
}

private enum DeskSnapshotFixtureError: Error {
    case unavailable
    case unexpectedCloudKitFetch
}

private actor DeskSnapshotResponseSequence {
    private var responses: [Result<DeskSnapshot?, DeskSnapshotFixtureError>]

    init(_ responses: [Result<DeskSnapshot?, DeskSnapshotFixtureError>]) {
        self.responses = responses
    }

    func fetch() throws -> DeskSnapshot? {
        try responses.removeFirst().get()
    }
}

@MainActor
private final class DeskSnapshotFetchGate {
    private(set) var fetchCount = 0
    private var completedSnapshot: DeskSnapshot?
    private var pendingFetches: [CheckedContinuation<DeskSnapshot?, any Error>] = []
    private var startWaiter: CheckedContinuation<Void, Never>?

    func fetch() async throws -> DeskSnapshot? {
        fetchCount += 1
        if let completedSnapshot { return completedSnapshot }
        return try await withCheckedThrowingContinuation { continuation in
            pendingFetches.append(continuation)
            startWaiter?.resume()
            startWaiter = nil
        }
    }

    func waitUntilStarted() async {
        guard fetchCount == 0 else { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func complete(with snapshot: DeskSnapshot) {
        completedSnapshot = snapshot
        let pending = pendingFetches
        pendingFetches.removeAll()
        for continuation in pending {
            continuation.resume(returning: snapshot)
        }
    }
}

@MainActor
private final class DeskRefreshStartSignal {
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?

    func signal() {
        started = true
        waiter?.resume()
        waiter = nil
    }

    func wait() async {
        guard !started else { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

private func makeToolSnapshot(
    sessionResetAt: Date = Date(timeIntervalSince1970: 3_000),
    weeklyResetAt: Date = Date(timeIntervalSince1970: 8_000),
    remaining: Int = 68,
    weeklyRemaining: Int = 51,
    status: DeskQuotaStatus = .healthy,
    petState: DeskPetState = .patrol
) -> DeskToolSnapshot {
    .init(
        tool: .codex,
        displayLabel: "Codex",
        remaining: remaining,
        total: 100,
        fraction: Double(remaining) / 100,
        resetAt: sessionResetAt,
        weekly: .init(
            label: "7d Weekly",
            remaining: weeklyRemaining,
            total: 100,
            fraction: Double(weeklyRemaining) / 100,
            resetAt: weeklyResetAt
        ),
        status: status,
        petState: petState
    )
}

private func makeSnapshot(updatedAt: Date) -> DeskSnapshot {
    DeskSnapshot(
        snapshotID: "desk",
        sourceDeviceID: "mac",
        schemaVersion: 1,
        updatedAt: updatedAt,
        codex: .init(
            tool: .codex,
            displayLabel: "Codex",
            remaining: 68,
            total: 100,
            fraction: 0.68,
            resetAt: Date(timeIntervalSince1970: 2_000),
            weekly: .init(
                label: "7d Weekly",
                remaining: 51,
                total: 100,
                fraction: 0.51,
                resetAt: Date(timeIntervalSince1970: 8_000)
            ),
            status: .healthy,
            petState: .patrol
        ),
        claude: .init(
            tool: .claudeCode,
            displayLabel: "Claude",
            remaining: 42,
            total: 100,
            fraction: 0.42,
            resetAt: Date(timeIntervalSince1970: 3_000),
            weekly: .init(
                label: "7d Weekly",
                remaining: 61,
                total: 100,
                fraction: 0.61,
                resetAt: Date(timeIntervalSince1970: 9_000)
            ),
            status: .warning,
            petState: .pause
        )
    )
}
