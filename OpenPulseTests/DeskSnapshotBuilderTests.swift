import CloudKit
import Testing
@testable import OpenPulse

struct DeskSnapshotBuilderTests {
    @Test
    func buildUsesCurrentCodexAccountAndClaudeUsage() throws {
        #expect(
            DeskSnapshotBuilder.build(
                now: Date(timeIntervalSince1970: 1_000),
                codexAccounts: [],
                claudeUsage: nil,
                fallbackQuotas: []
            ) == nil
        )
    }

    @Test
    func statusThresholdsProduceCriticalAndStaleStates() {
        let staleStatus = DeskQuotaStatus.resolve(
            remaining: 5,
            total: 100,
            updatedAt: Date(timeIntervalSince1970: 0),
            now: Date(timeIntervalSince1970: 60 * 11)
        )
        #expect(staleStatus == .stale)
    }

    @Test
    func recordCodecRoundTripsSnapshotFields() throws {
        let snapshot = DeskSnapshot(
            snapshotID: "desk",
            sourceDeviceID: "mac",
            schemaVersion: 1,
            updatedAt: Date(timeIntervalSince1970: 1_000),
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

        let record = DeskSnapshotRecordCodec.makeRecord(snapshot: snapshot, zoneID: nil)
        let decoded = try DeskSnapshotRecordCodec.decode(record)
        #expect(decoded == snapshot)
    }
}
