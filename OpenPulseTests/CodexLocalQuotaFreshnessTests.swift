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
    func latestObservationIsSelectedPerIdentityByEventTimestamp() async throws {
        let fileManager = FileManager.default
        let codexDir = fileManager.temporaryDirectory
            .appending(path: "OpenPulse-CodexGroupedQuota-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: codexDir) }

        let sessionsDir = codexDir.appending(path: "sessions")
        try fileManager.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let generalOlderEvent = sessionsDir.appending(path: "general-older-event.jsonl")
        let generalNewerEvent = sessionsDir.appending(path: "general-newer-event.jsonl")
        let spark = sessionsDir.appending(path: "spark.jsonl")
        let eventOlder = Date(timeIntervalSince1970: 10_000)
        let eventNewer = Date(timeIntervalSince1970: 20_000)
        let eventSpark = Date(timeIntervalSince1970: 30_000)

        try writeQuotaEvent(
            limitID: "codex",
            usedPercent: 10,
            timestamp: eventOlder,
            to: generalOlderEvent
        )
        try writeQuotaEvent(
            limitID: "codex",
            usedPercent: 20,
            timestamp: eventNewer,
            to: generalNewerEvent
        )
        try writeQuotaEvent(
            limitID: "codex_bengalfox",
            limitName: "GPT-5.3-Codex-Spark",
            usedPercent: 0,
            timestamp: eventSpark,
            to: spark
        )

        let now = Date()
        try fileManager.setAttributes([.modificationDate: now], ofItemAtPath: generalOlderEvent.path)
        try fileManager.setAttributes([.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: generalNewerEvent.path)
        try fileManager.setAttributes([.modificationDate: now.addingTimeInterval(60)], ofItemAtPath: spark.path)

        let snapshot = await CodexParser(codexDir: codexDir).parseLatestRateLimitsSnapshot()

        #expect(snapshot?.limits.primary?.usedPercent == 20)
        #expect(namedLimitIDs(in: snapshot?.limits) == ["codex_bengalfox"])
        #expect(namedLimitName("codex_bengalfox", in: snapshot?.limits) == "GPT-5.3-Codex-Spark")
        #expect(namedLimitObservedAt("codex_bengalfox", in: snapshot?.limits) == eventSpark)
        #expect(observedAt(in: snapshot?.limits) == eventNewer)
    }

    @Test
    func legacyQuotaWithoutTimestampUsesFileModificationDate() async throws {
        let fileManager = FileManager.default
        let codexDir = fileManager.temporaryDirectory
            .appending(path: "OpenPulse-CodexLegacyTimestamp-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: codexDir) }

        let sessionsDir = codexDir.appending(path: "sessions")
        try fileManager.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let legacyURL = sessionsDir.appending(path: "legacy.jsonl")
        try writeQuotaEvent(limitID: nil, usedPercent: 12, to: legacyURL)
        let modifiedAt = Date().addingTimeInterval(-30)
        try fileManager.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: legacyURL.path)
        let expectedModifiedAt = try legacyURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

        let snapshot = await CodexParser(codexDir: codexDir).parseLatestRateLimitsSnapshot()

        #expect(snapshot?.limits.primary?.usedPercent == 12)
        #expect(observedAt(in: snapshot?.limits) == expectedModifiedAt)
    }

    @Test
    func weeklyOnlyRateLimitDoesNotPopulateFiveHourWindow() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "primary": [
                "used_percent": 12,
                "window_minutes": 10_080,
                "resets_at": 100_000,
            ],
            "limit_id": "codex_bengalfox",
        ])
        let limits = try JSONDecoder().decode(CodexRateLimits.self, from: data)

        #expect(limits.fiveHourWindow == nil)
        #expect(limits.oneWeekWindow?.windowMinutes == 10_080)
    }

    @Test
    func timestampDecodingAcceptsFractionalAndWholeSeconds() async throws {
        let fileManager = FileManager.default
        let codexDir = fileManager.temporaryDirectory
            .appending(path: "OpenPulse-CodexTimestampFormats-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: codexDir) }

        let sessionsDir = codexDir.appending(path: "sessions")
        try fileManager.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        let fractional = sessionsDir.appending(path: "fractional.jsonl")
        let whole = sessionsDir.appending(path: "whole.jsonl")
        try writeQuotaEvent(
            limitID: "codex",
            usedPercent: 10,
            timestamp: Date(timeIntervalSince1970: 50_000),
            to: fractional
        )
        try writeQuotaEvent(
            limitID: "codex",
            usedPercent: 20,
            timestampString: "1970-01-01T13:53:21Z",
            to: whole
        )

        let now = Date()
        try fileManager.setAttributes([.modificationDate: now], ofItemAtPath: fractional.path)
        try fileManager.setAttributes([.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: whole.path)
        let snapshot = await CodexParser(codexDir: codexDir).parseLatestRateLimitsSnapshot()

        #expect(snapshot?.limits.primary?.usedPercent == 20)
        #expect(observedAt(in: snapshot?.limits) == Date(timeIntervalSince1970: 50_001))
    }

    @Test
    func malformedLineDoesNotDiscardValidQuotaEvent() async throws {
        let fileManager = FileManager.default
        let codexDir = fileManager.temporaryDirectory
            .appending(path: "OpenPulse-CodexMalformedQuota-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: codexDir) }

        let sessionsDir = codexDir.appending(path: "sessions")
        try fileManager.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        let file = sessionsDir.appending(path: "mixed.jsonl")
        var data = Data("{malformed-json}\n".utf8)
        data.append(try quotaEventData(limitID: "codex", usedPercent: 42))
        try data.write(to: file)

        let snapshot = await CodexParser(codexDir: codexDir).parseLatestRateLimitsSnapshot()

        #expect(snapshot?.limits.primary?.usedPercent == 42)
    }

    @Test
    func strictWindowSelectorsClassifySwappedAndUnknownDurations() {
        let limits = CodexRateLimits(
            primary: CodexWindow(usedPercent: 10, windowMinutes: 10_080, windowSeconds: nil, resetsAt: 100_000),
            secondary: CodexWindow(usedPercent: 20, windowMinutes: 300, windowSeconds: nil, resetsAt: 100_000),
            credits: nil,
            resetCredits: nil,
            planType: nil
        )
        #expect(limits.fiveHourWindow?.usedPercent == 20)
        #expect(limits.oneWeekWindow?.usedPercent == 10)

        let unknown = CodexRateLimits(
            primary: CodexWindow(usedPercent: 30, windowMinutes: 60, windowSeconds: nil, resetsAt: 100_000),
            secondary: nil,
            credits: nil,
            resetCredits: nil,
            planType: nil
        )
        #expect(unknown.fiveHourWindow == nil)
        #expect(unknown.oneWeekWindow == nil)
    }

    @Test
    func newerNamedEventWithoutWindowDoesNotReplaceValidObservation() async throws {
        let fileManager = FileManager.default
        let codexDir = fileManager.temporaryDirectory
            .appending(path: "OpenPulse-CodexInvalidNamedQuota-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: codexDir) }

        let sessionsDir = codexDir.appending(path: "sessions")
        try fileManager.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        let file = sessionsDir.appending(path: "spark.jsonl")
        var data = try quotaEventData(
            limitID: "codex_bengalfox",
            limitName: "GPT-5.3-Codex-Spark",
            usedPercent: 30,
            timestamp: Date(timeIntervalSince1970: 60_000)
        )
        data.append(Data("\n".utf8))
        data.append(try quotaEventData(
            limitID: "codex_bengalfox",
            limitName: "GPT-5.3-Codex-Spark",
            usedPercent: 99,
            timestamp: Date(timeIntervalSince1970: 70_000),
            primaryWindowMinutes: nil,
            secondaryWindowMinutes: nil
        ))
        let general = sessionsDir.appending(path: "general.jsonl")
        try quotaEventData(limitID: "codex", usedPercent: 12).write(to: general)
        try data.write(to: file)

        let snapshot = await CodexParser(codexDir: codexDir).parseLatestRateLimitsSnapshot()

        #expect(namedLimitIDs(in: snapshot?.limits) == ["codex_bengalfox"])
        #expect(namedLimitObservedAt("codex_bengalfox", in: snapshot?.limits) == Date(timeIntervalSince1970: 60_000))
        #expect(namedLimitUsedPercent("codex_bengalfox", in: snapshot?.limits) == 30)
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

    private func writeQuotaEvent(
        limitID: String?,
        limitName: String? = nil,
        usedPercent: Double,
        timestamp: Date? = nil,
        timestampString: String? = nil,
        primaryWindowMinutes: Int? = 10_080,
        secondaryWindowMinutes: Int? = nil,
        to url: URL
    ) throws {
        try quotaEventData(
            limitID: limitID,
            limitName: limitName,
            usedPercent: usedPercent,
            timestamp: timestamp,
            timestampString: timestampString,
            primaryWindowMinutes: primaryWindowMinutes,
            secondaryWindowMinutes: secondaryWindowMinutes
        ).write(to: url)
    }

    private func quotaEventData(
        limitID: String?,
        limitName: String? = nil,
        usedPercent: Double,
        timestamp: Date? = nil,
        timestampString: String? = nil,
        primaryWindowMinutes: Int? = 10_080,
        secondaryWindowMinutes: Int? = nil
    ) throws -> Data {
        var rateLimits: [String: Any] = ["plan_type": "prolite"]
        if let primaryWindowMinutes {
            rateLimits["primary"] = [
                "used_percent": usedPercent,
                "window_minutes": primaryWindowMinutes,
                "resets_at": Date().addingTimeInterval(7 * 24 * 60 * 60).timeIntervalSince1970,
            ]
        }
        if let secondaryWindowMinutes {
            rateLimits["secondary"] = [
                "used_percent": usedPercent,
                "window_minutes": secondaryWindowMinutes,
                "resets_at": Date().addingTimeInterval(7 * 24 * 60 * 60).timeIntervalSince1970,
            ]
        }
        if let limitID {
            rateLimits["limit_id"] = limitID
        }
        if let limitName {
            rateLimits["limit_name"] = limitName
        }

        let event: [String: Any] = [
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "rate_limits": rateLimits,
            ],
        ]
        var eventWithTimestamp = event
        if let timestampString {
            eventWithTimestamp["timestamp"] = timestampString
        } else if let timestamp {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            eventWithTimestamp["timestamp"] = formatter.string(from: timestamp)
        }
        return try JSONSerialization.data(withJSONObject: eventWithTimestamp)
    }

    private func namedLimitIDs(in limits: CodexRateLimits?) -> [String] {
        limits?.additionalLimits?.map(\.id).sorted() ?? []
    }

    private func namedLimitName(_ id: String, in limits: CodexRateLimits?) -> String? {
        limits?.additionalLimits?.first(where: { $0.id == id })?.name
    }

    private func namedLimitObservedAt(_ id: String, in limits: CodexRateLimits?) -> Date? {
        limits?.additionalLimits?.first(where: { $0.id == id })?.observedAt
    }

    private func namedLimitUsedPercent(_ id: String, in limits: CodexRateLimits?) -> Double? {
        limits?.additionalLimits?.first(where: { $0.id == id })?.primary?.usedPercent
    }

    private func observedAt(in limits: CodexRateLimits?) -> Date? {
        limits?.observedAt
    }
}
