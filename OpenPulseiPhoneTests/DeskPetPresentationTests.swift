import Foundation
import Testing
@testable import OpenPulseiPhone

struct DeskPetPresentationTests {
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
                status: .critical,
                petState: .alert
            ),
            now: Date(timeIntervalSince1970: 1_000)
        )

        #expect(presentation.motion == .alert)
        #expect(presentation.primaryText == "10%")
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
            primaryText: "0%",
            resetText: "Resets 16:05",
            fraction: 0,
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
            status: .warning,
            petState: .pause
        )
    )
}
