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
