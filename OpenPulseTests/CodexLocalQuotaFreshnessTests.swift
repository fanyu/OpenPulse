import Foundation
import Testing
@testable import OpenPulse

struct CodexLocalQuotaFreshnessTests {
    @Test
    func newerAndOlderObservationsMergeIndependentlyPerIdentity() {
        let stored = makeRateLimits(
            generalUsedPercent: 10,
            observedAt: Date(timeIntervalSince1970: 100),
            additionalLimits: [makeNamedLimit(id: "codex_bengalfox", usedPercent: 20, observedAt: Date(timeIntervalSince1970: 200))]
        )
        let incoming = makeRateLimits(
            generalUsedPercent: 30,
            observedAt: Date(timeIntervalSince1970: 300),
            additionalLimits: [
                makeNamedLimit(id: " CODEX_BENGALFOX ", usedPercent: 40, observedAt: Date(timeIntervalSince1970: 150)),
                makeNamedLimit(id: "codex_other", usedPercent: 50, observedAt: Date(timeIntervalSince1970: 400)),
            ]
        )

        let merged = stored.merging(incoming)

        #expect(merged.primary?.usedPercent == 30)
        #expect(merged.additionalLimits?.first(where: { $0.id == "codex_bengalfox" })?.primary?.usedPercent == 20)
        #expect(merged.additionalLimits?.first(where: { $0.id == "codex_other" })?.primary?.usedPercent == 50)
    }

    @Test
    func generalOnlyObservationPreservesLastKnownNamedLimits() {
        let stored = makeRateLimits(
            generalUsedPercent: 10,
            observedAt: Date(timeIntervalSince1970: 100),
            additionalLimits: [makeNamedLimit(id: "codex_bengalfox", usedPercent: 20, observedAt: Date(timeIntervalSince1970: 200))]
        )
        let incoming = makeRateLimits(
            generalUsedPercent: 30,
            observedAt: Date(timeIntervalSince1970: 300),
            additionalLimits: nil
        )

        let merged = stored.merging(incoming)

        #expect(merged.primary?.usedPercent == 30)
        #expect(merged.additionalLimits?.map(\.id) == ["codex_bengalfox"])
    }

    @Test
    func additionalOnlyObservationPreservesLastKnownGeneralQuota() {
        let stored = makeRateLimits(
            generalUsedPercent: 10,
            observedAt: Date(timeIntervalSince1970: 100),
            additionalLimits: [makeNamedLimit(id: "codex_bengalfox", usedPercent: 20, observedAt: Date(timeIntervalSince1970: 200))]
        )
        let incoming = makeRateLimits(
            generalUsedPercent: nil,
            observedAt: nil,
            additionalLimits: [makeNamedLimit(id: "codex_bengalfox", usedPercent: 40, observedAt: Date(timeIntervalSince1970: 300))]
        )

        let merged = stored.merging(incoming)

        #expect(merged.primary?.usedPercent == 10)
        #expect(merged.additionalLimits?.first?.primary?.usedPercent == 40)
        #expect(merged.observedAt == Date(timeIntervalSince1970: 100))
    }

    @Test
    func emptyAdditionalLimitsPreserveLastKnownNamedQuota() {
        let stored = makeRateLimits(
            generalUsedPercent: 10,
            observedAt: Date(timeIntervalSince1970: 100),
            additionalLimits: [makeNamedLimit(id: "codex_bengalfox", usedPercent: 20, observedAt: Date(timeIntervalSince1970: 200))]
        )
        let incoming = makeRateLimits(
            generalUsedPercent: 30,
            observedAt: Date(timeIntervalSince1970: 300),
            additionalLimits: []
        )

        let merged = stored.merging(incoming)

        #expect(merged.primary?.usedPercent == 30)
        #expect(merged.additionalLimits?.map(\.id) == ["codex_bengalfox"])
        #expect(merged.additionalLimits?.first?.primary?.usedPercent == 20)
    }

    @Test
    func versionOneCodexRateLimitsDecodeAndRoundTripWithoutNewFields() throws {
        let legacyData = Data("""
        {
          "primary": {"used_percent": 12, "window_minutes": 300, "resets_at": 100000},
          "secondary": null,
          "credits": null,
          "rate_limit_reset_credits": null,
          "plan_type": "pro"
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(CodexRateLimits.self, from: legacyData)
        let roundTripped = try JSONDecoder().decode(
            CodexRateLimits.self,
            from: JSONEncoder().encode(decoded)
        )

        #expect(decoded.observedAt == nil)
        #expect(decoded.additionalLimits == nil)
        #expect(roundTripped.primary?.usedPercent == 12)
        #expect(roundTripped.additionalLimits == nil)
    }

    @Test
    func apiAdditionalRateLimitMapsIdentityAndFetchObservationWithoutFabricatingGeneral() throws {
        let fetchDate = Date(timeIntervalSince1970: 123_456)
        let data = Data("""
        {
          "plan_type": "pro",
          "rate_limit": null,
          "additional_rate_limits": [
            {
              "metered_feature": "codex_bengalfox",
              "limit_name": "GPT-5.3-Codex-Spark",
              "rate_limit": {
                "primary_window": {
                  "used_percent": 0,
                  "limit_window_seconds": 604800,
                  "reset_at": 100000
                },
                "secondary_window": null
              }
            },
            {
              "metered_feature": "codex_empty",
              "limit_name": "No data",
              "rate_limit": null
            }
          ]
        }
        """.utf8)

        let payload = try JSONDecoder().decode(CodexUsageAPIResponse.self, from: data)
        let limits = payload.toRateLimits(observedAt: fetchDate)

        #expect(limits.primary == nil)
        #expect(limits.secondary == nil)
        #expect(limits.observedAt == nil)
        #expect(limits.additionalLimits?.map(\.id) == ["codex_bengalfox"])
        #expect(limits.additionalLimits?.first?.name == "GPT-5.3-Codex-Spark")
        #expect(limits.additionalLimits?.first?.observedAt == fetchDate)
        #expect(limits.additionalLimits?.first?.primary?.durationSeconds == 604_800)
    }

    @Test
    func apiEmptyGeneralRateLimitPreservesLastKnownGeneralQuota() throws {
        let stored = makeRateLimits(
            generalUsedPercent: 10,
            observedAt: Date(timeIntervalSince1970: 100),
            additionalLimits: nil
        )
        let data = Data("""
        {
          "rate_limit": {
            "primary_window": null,
            "secondary_window": null
          },
          "additional_rate_limits": []
        }
        """.utf8)

        let payload = try JSONDecoder().decode(CodexUsageAPIResponse.self, from: data)
        let incoming = payload.toRateLimits(observedAt: Date(timeIntervalSince1970: 300))
        let merged = stored.merging(incoming)

        #expect(incoming.observedAt == nil)
        #expect(merged.primary?.usedPercent == 10)
        #expect(merged.observedAt == Date(timeIntervalSince1970: 100))
    }

    @Test
    func sparkOnlyJSONLProducesNamedSnapshotAndPreservesStoredGeneralQuota() async throws {
        let fileManager = FileManager.default
        let codexDir = fileManager.temporaryDirectory
            .appending(path: "OpenPulse-CodexSparkOnly-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: codexDir) }

        let sessionsDir = codexDir.appending(path: "sessions")
        try fileManager.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        let sparkURL = sessionsDir.appending(path: "spark.jsonl")
        let sparkEvent = Date(timeIntervalSince1970: 90_000)
        try writeQuotaEvent(
            limitID: "CODEX_BENGALFOX",
            limitName: "GPT-5.3-Codex-Spark",
            usedPercent: 0,
            timestamp: sparkEvent,
            to: sparkURL
        )
        let modifiedAt = Date().addingTimeInterval(-30)
        try fileManager.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: sparkURL.path)

        let snapshot = await CodexParser(codexDir: codexDir).parseLatestRateLimitsSnapshot()
        let stored = makeRateLimits(
            generalUsedPercent: 10,
            observedAt: Date(timeIntervalSince1970: 80_000),
            additionalLimits: nil
        )
        let merged = snapshot.map { stored.merging($0.limits) }

        #expect(snapshot?.limits.fiveHourWindow == nil)
        #expect(snapshot?.limits.oneWeekWindow == nil)
        #expect(namedLimitIDs(in: snapshot?.limits) == ["codex_bengalfox"])
        #expect(namedLimitName("codex_bengalfox", in: snapshot?.limits) == "GPT-5.3-Codex-Spark")
        #expect(namedLimitObservedAt("codex_bengalfox", in: snapshot?.limits) == sparkEvent)
        #expect(snapshot?.sourceURL.standardizedFileURL == sparkURL.standardizedFileURL)
        #expect(snapshot?.limits.planType == nil)
        #expect(merged?.primary?.usedPercent == 10)
        #expect(merged?.planType == "pro")
        #expect(namedLimitUsedPercent("codex_bengalfox", in: merged) == 0)
        #expect(snapshot?.limits.hasUsableKnownWindow() == true)
        #expect(snapshot?.limits.hasUsableGeneralWindow() == false)
        #expect(snapshot?.limits.hasKnownGeneralWindow == false)
        #expect(makeAccountSnapshot(updatedAt: modifiedAt, limits: snapshot?.limits).generalQuota == nil)
    }

    @Test
    func quotaUpdatedAtUsesLimitObservationBeforeAccountMetadata() {
        let observedAt = Date(timeIntervalSince1970: 90_000)
        let accountUpdatedAt = Date(timeIntervalSince1970: 100_000)
        let limits = makeRateLimits(generalUsedPercent: 10, observedAt: observedAt, additionalLimits: nil)
        let observedSnapshot = makeAccountSnapshot(updatedAt: accountUpdatedAt, limits: limits)
        let legacySnapshot = makeAccountSnapshot(
            updatedAt: accountUpdatedAt,
            limits: makeRateLimits(generalUsedPercent: 10, observedAt: nil, additionalLimits: nil)
        )

        #expect(observedSnapshot.quota.updatedAt == observedAt)
        #expect(legacySnapshot.quota.updatedAt == accountUpdatedAt)
    }

    @Test
    func legacyStoredAccountMigratesSuccessfulFetchTimeIntoUsageObservation() {
        let accountUpdatedAt = Date(timeIntervalSince1970: 100_000)
        let lastFetchedAt = Date(timeIntervalSince1970: 90_000)
        var account = CodexStoredAccount(
            id: "account",
            label: "Codex",
            email: nil,
            accountID: "account",
            planType: "pro",
            teamName: nil,
            authJSONString: "{}",
            addedAt: Date(timeIntervalSince1970: 80_000),
            updatedAt: accountUpdatedAt,
            lastFetchedAt: lastFetchedAt,
            lastUsage: makeRateLimits(generalUsedPercent: 10, observedAt: nil, additionalLimits: nil),
            usageError: nil
        )

        account.migrateLegacyUsageObservation()
        account.updatedAt = Date(timeIntervalSince1970: 110_000)

        #expect(account.lastUsage?.observedAt == lastFetchedAt)
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

    @Test
    func menuBarRowsKeepGeneralOnlyWithoutAdditionalLimits() {
        let limits = makeMenuBarLimits(
            primary: menuBarWindow(minutes: 300),
            secondary: menuBarWindow(minutes: 10_080)
        )

        let rows = codexMenuBarQuotaRows(for: limits)

        #expect(rows.map(\.id) == ["codex"])
        #expect(rows.first?.title == "通用额度")
    }

    @Test
    func menuBarRowsShortenSparkName() {
        let observedAt = Date(timeIntervalSince1970: 80_000)
        let spark = CodexNamedRateLimit(
            id: "codex_bengalfox",
            name: "GPT-5.3-Codex-Spark",
            primary: menuBarWindow(minutes: 10_080),
            secondary: nil,
            observedAt: observedAt
        )
        let limits = makeMenuBarLimits(
            primary: menuBarWindow(minutes: 300),
            additionalLimits: [spark]
        )

        let rows = codexMenuBarQuotaRows(for: limits)

        #expect(rows.map(\.id) == ["codex", "codex_bengalfox"])
        #expect(rows.last?.title == "Spark")
        #expect(rows.last?.observedAt == observedAt)
    }

    @Test
    func menuBarRowsKeepOnlyWeeklyWindowForWeeklyNamedLimit() {
        let spark = CodexNamedRateLimit(
            id: "codex_bengalfox",
            name: "GPT-5.3-Codex-Spark",
            primary: menuBarWindow(minutes: 10_080),
            secondary: nil,
            observedAt: Date(timeIntervalSince1970: 81_000)
        )
        let rows = codexMenuBarQuotaRows(for: makeMenuBarLimits(
            primary: menuBarWindow(minutes: 300),
            additionalLimits: [spark]
        ))

        let sparkRow = rows.last
        #expect(sparkRow?.fiveHourWindow == nil)
        #expect(sparkRow?.oneWeekWindow?.windowMinutes == 10_080)
    }

    @Test
    func menuBarRowsKeepGeneralFirstAndSortNamedRowsByNameThenID() {
        let named = [
            CodexNamedRateLimit(
                id: "zeta-id",
                name: "Beta",
                primary: menuBarWindow(minutes: 300),
                secondary: nil,
                observedAt: nil
            ),
            CodexNamedRateLimit(
                id: "alpha-id",
                name: "Alpha",
                primary: menuBarWindow(minutes: 300),
                secondary: nil,
                observedAt: nil
            ),
            CodexNamedRateLimit(
                id: "beta-id",
                name: "Beta",
                primary: menuBarWindow(minutes: 300),
                secondary: nil,
                observedAt: nil
            ),
        ]
        let limits = makeMenuBarLimits(
            primary: menuBarWindow(minutes: 300),
            additionalLimits: named
        )

        let rows = codexMenuBarQuotaRows(for: limits)

        #expect(rows.map(\.id) == ["codex", "alpha-id", "beta-id", "zeta-id"])
    }

    @Test
    func menuBarRowsOmitNamedUnknownDuration() {
        let unknown = CodexNamedRateLimit(
            id: "codex_unknown",
            name: "Unknown",
            primary: menuBarWindow(minutes: 60),
            secondary: nil,
            observedAt: Date(timeIntervalSince1970: 82_000)
        )
        let limits = makeMenuBarLimits(
            primary: menuBarWindow(minutes: 300),
            additionalLimits: [unknown]
        )

        let rows = codexMenuBarQuotaRows(for: limits)

        #expect(rows.map(\.id) == ["codex"])
    }

    @Test
    func codexQuotaObservedRelativeTextUsesOnePastSuffix() {
        let observedAt = Date(timeIntervalSince1970: 1)
        let zhText = codexQuotaObservedRelativeText(
            observedAt: observedAt,
            locale: Locale(identifier: "zh_CN")
        )
        let enText = codexQuotaObservedRelativeText(
            observedAt: observedAt,
            locale: Locale(identifier: "en_US")
        )

        #expect(zhText.filter { $0 == "前" }.count == 1)
        #expect(!zhText.contains("前前"))
        #expect(enText.contains("ago"))
    }

    private func makeRateLimits(
        generalUsedPercent: Double?,
        observedAt: Date?,
        additionalLimits: [CodexNamedRateLimit]?
    ) -> CodexRateLimits {
        CodexRateLimits(
            primary: generalUsedPercent.map {
                CodexWindow(usedPercent: $0, windowMinutes: 300, windowSeconds: nil, resetsAt: 100_000)
            },
            secondary: nil,
            credits: nil,
            resetCredits: nil,
            planType: "pro",
            observedAt: observedAt,
            additionalLimits: additionalLimits
        )
    }

    private func makeNamedLimit(id: String, usedPercent: Double, observedAt: Date) -> CodexNamedRateLimit {
        CodexNamedRateLimit(
            id: id,
            name: id == "codex_bengalfox" ? "GPT-5.3-Codex-Spark" : nil,
            primary: CodexWindow(usedPercent: usedPercent, windowMinutes: 300, windowSeconds: nil, resetsAt: 100_000),
            secondary: nil,
            observedAt: observedAt
        )
    }

    private func makeAccountSnapshot(updatedAt: Date, limits: CodexRateLimits?) -> CodexAccountSnapshot {
        CodexAccountSnapshot(
            id: "account",
            label: "Codex",
            email: nil,
            accountID: "account",
            planType: "pro",
            teamName: nil,
            addedAt: updatedAt.addingTimeInterval(-1_000),
            updatedAt: updatedAt,
            lastFetchedAt: updatedAt,
            limits: limits,
            usageError: nil,
            isCurrent: true
        )
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

    private func makeMenuBarLimits(
        primary: CodexWindow?,
        secondary: CodexWindow? = nil,
        additionalLimits: [CodexNamedRateLimit]? = nil
    ) -> CodexRateLimits {
        CodexRateLimits(
            primary: primary,
            secondary: secondary,
            credits: nil,
            resetCredits: nil,
            planType: nil,
            observedAt: Date(timeIntervalSince1970: 79_000),
            additionalLimits: additionalLimits
        )
    }

    private func menuBarWindow(minutes: Int, usedPercent: Double = 12) -> CodexWindow {
        CodexWindow(
            usedPercent: usedPercent,
            windowMinutes: minutes,
            windowSeconds: nil,
            resetsAt: 100_000
        )
    }
}
