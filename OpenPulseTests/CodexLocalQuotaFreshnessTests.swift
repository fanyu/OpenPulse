import Foundation
import Testing
@testable import OpenPulse

struct CodexLocalQuotaFreshnessTests {
    @Test
    func onlyRecentLocalSnapshotsCanOverrideAPIUsage() {
        let now = Date(timeIntervalSince1970: 10_000)

        #expect(CodexLocalQuotaFreshness.shouldPrefer(
            snapshotModifiedAt: now.addingTimeInterval(-299),
            now: now
        ))
        #expect(!CodexLocalQuotaFreshness.shouldPrefer(
            snapshotModifiedAt: now.addingTimeInterval(-301),
            now: now
        ))
        #expect(!CodexLocalQuotaFreshness.shouldPrefer(snapshotModifiedAt: nil, now: now))
    }

    @Test
    func modelSpecificQuotaDoesNotOverrideGeneralQuota() async throws {
        let fileManager = FileManager.default
        let codexDir = fileManager.temporaryDirectory
            .appending(path: "OpenPulse-CodexQuota-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: codexDir) }

        let sessionsDir = codexDir.appending(path: "sessions")
        try fileManager.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let generalURL = sessionsDir.appending(path: "general.jsonl")
        let sparkURL = sessionsDir.appending(path: "spark.jsonl")
        try writeQuotaEvent(limitID: "codex", usedPercent: 34, to: generalURL)
        try writeQuotaEvent(limitID: "codex_bengalfox", usedPercent: 0, to: sparkURL)

        let now = Date()
        try fileManager.setAttributes([.modificationDate: now.addingTimeInterval(-1)], ofItemAtPath: generalURL.path)
        try fileManager.setAttributes([.modificationDate: now], ofItemAtPath: sparkURL.path)

        let snapshot = await CodexParser(codexDir: codexDir).parseLatestRateLimitsSnapshot()

        #expect(snapshot?.limits.primary?.usedPercent == 34)
    }

    @Test
    func legacyQuotaWithoutLimitIDRemainsEligible() async throws {
        let fileManager = FileManager.default
        let codexDir = fileManager.temporaryDirectory
            .appending(path: "OpenPulse-CodexLegacyQuota-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: codexDir) }

        let sessionsDir = codexDir.appending(path: "sessions")
        try fileManager.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let legacyURL = sessionsDir.appending(path: "legacy.jsonl")
        try writeQuotaEvent(limitID: nil, usedPercent: 12, to: legacyURL)

        let snapshot = await CodexParser(codexDir: codexDir).parseLatestRateLimitsSnapshot()

        #expect(snapshot?.limits.primary?.usedPercent == 12)
    }

    private func writeQuotaEvent(limitID: String?, usedPercent: Double, to url: URL) throws {
        var rateLimits: [String: Any] = [
            "primary": [
                "used_percent": usedPercent,
                "window_minutes": 10_080,
                "resets_at": Date().addingTimeInterval(7 * 24 * 60 * 60).timeIntervalSince1970,
            ],
            "plan_type": "prolite",
        ]
        if let limitID {
            rateLimits["limit_id"] = limitID
        }

        let event: [String: Any] = [
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "rate_limits": rateLimits,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: event)
        try data.write(to: url)
    }
}
