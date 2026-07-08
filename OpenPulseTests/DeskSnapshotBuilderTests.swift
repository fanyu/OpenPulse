import CloudKit
import Testing
@testable import OpenPulse

struct DeskSnapshotBuilderTests {
    @Test
    func buildUsesCurrentCodexAccountAndClaudeUsage() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = DeskSnapshotBuilder.build(
            now: now,
            codexAccounts: [
                .init(
                    id: "fallback-account",
                    label: "Fallback",
                    email: "fallback@example.com",
                    accountID: "codex-fallback",
                    planType: "pro",
                    teamName: nil,
                    addedAt: .distantPast,
                    updatedAt: now,
                    lastFetchedAt: now,
                    limits: .init(
                        primary: .init(
                            usedPercent: 88,
                            windowMinutes: 300,
                            windowSeconds: nil,
                            resetsAt: 4_000
                        ),
                        secondary: nil,
                        credits: nil,
                        resetCredits: nil,
                        planType: "pro"
                    ),
                    usageError: nil,
                    isCurrent: false
                ),
                .init(
                    id: "current-account",
                    label: "Current",
                    email: "current@example.com",
                    accountID: "codex-current",
                    planType: "pro",
                    teamName: nil,
                    addedAt: .distantPast,
                    updatedAt: now,
                    lastFetchedAt: now,
                    limits: .init(
                        primary: .init(
                            usedPercent: 32,
                            windowMinutes: 300,
                            windowSeconds: nil,
                            resetsAt: 2_000
                        ),
                        secondary: nil,
                        credits: nil,
                        resetCredits: nil,
                        planType: "pro"
                    ),
                    usageError: nil,
                    isCurrent: true
                )
            ],
            claudeUsage: .init(
                fiveHour: .init(utilization: 81, resetsAt: "3000"),
                sevenDay: nil
            ),
            fallbackQuotas: [
                QuotaRecord(
                    tool: .codex,
                    accountKey: "fallback-quota",
                    accountLabel: "Fallback quota",
                    remaining: 9,
                    total: 100,
                    resetAt: Date(timeIntervalSince1970: 9_000)
                ),
                QuotaRecord(
                    tool: .claudeCode,
                    accountKey: "claude-fallback",
                    accountLabel: "Claude fallback",
                    remaining: 77,
                    total: 100,
                    resetAt: Date(timeIntervalSince1970: 8_000)
                )
            ]
        )

        #expect(snapshot != nil)
        #expect(snapshot?.snapshotID == "desk-current")
        #expect(snapshot?.updatedAt == now)
        #expect(snapshot?.sourceDeviceID.isEmpty == false)

        #expect(snapshot?.codex.tool == .codex)
        #expect(snapshot?.codex.displayLabel == "Codex")
        #expect(snapshot?.codex.remaining == 68)
        #expect(snapshot?.codex.total == 100)
        #expect(snapshot?.codex.fraction == 0.68)
        #expect(snapshot?.codex.resetAt == Date(timeIntervalSince1970: 2_000))
        #expect(snapshot?.codex.status == .healthy)
        #expect(snapshot?.codex.petState == .patrol)

        #expect(snapshot?.claude.tool == .claudeCode)
        #expect(snapshot?.claude.displayLabel == "Claude")
        #expect(snapshot?.claude.remaining == 19)
        #expect(snapshot?.claude.total == 100)
        #expect(snapshot?.claude.fraction == 0.19)
        #expect(snapshot?.claude.resetAt == Date(timeIntervalSince1970: 3_000))
        #expect(snapshot?.claude.status == .critical)
        #expect(snapshot?.claude.petState == .alert)
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
