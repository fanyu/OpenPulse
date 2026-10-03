import CloudKit
import Testing
@testable import OpenPulse

private actor DeskSnapshotPublishAttemptCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

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
                        secondary: .init(
                            usedPercent: 58,
                            windowMinutes: 10_080,
                            windowSeconds: nil,
                            resetsAt: 5_000
                        ),
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
                sevenDay: .init(utilization: 44, resetsAt: "6000")
            ),
            claudeObservedAt: now,
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
        #expect(snapshot?.codex.weekly?.remaining == 42)
        #expect(snapshot?.codex.weekly?.fraction == 0.42)
        #expect(snapshot?.codex.weekly?.resetAt == Date(timeIntervalSince1970: 5_000))
        #expect(snapshot?.codex.status == .healthy)
        #expect(snapshot?.codex.petState == .patrol)

        #expect(snapshot?.claude.tool == .claudeCode)
        #expect(snapshot?.claude.displayLabel == "Claude")
        #expect(snapshot?.claude.remaining == 19)
        #expect(snapshot?.claude.total == 100)
        #expect(snapshot?.claude.fraction == 0.19)
        #expect(snapshot?.claude.resetAt == Date(timeIntervalSince1970: 3_000))
        #expect(snapshot?.claude.weekly?.remaining == 56)
        #expect(snapshot?.claude.weekly?.fraction == 0.56)
        #expect(snapshot?.claude.weekly?.resetAt == Date(timeIntervalSince1970: 6_000))
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
                weekly: .init(
                    label: "7d Weekly",
                    remaining: 44,
                    total: 100,
                    fraction: 0.44,
                    resetAt: Date(timeIntervalSince1970: 4_000)
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
                    remaining: 38,
                    total: 100,
                    fraction: 0.38,
                    resetAt: Date(timeIntervalSince1970: 5_000)
                ),
                status: .warning,
                petState: .pause
            )
        )

        let record = DeskSnapshotRecordCodec.makeRecord(snapshot: snapshot, zoneID: nil)
        let decoded = try DeskSnapshotRecordCodec.decode(record)
        #expect(decoded == snapshot)
    }

    @Test
    func recordCodecRejectsMissingRequiredTopLevelMetadata() throws {
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
                weekly: nil,
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
                weekly: nil,
                status: .warning,
                petState: .pause
            )
        )

        for field in ["snapshotID", "sourceDeviceID", "schemaVersion", "updatedAt"] {
            let record = DeskSnapshotRecordCodec.makeRecord(snapshot: snapshot, zoneID: nil)
            record[field] = nil

            do {
                _ = try DeskSnapshotRecordCodec.decode(record)
                #expect(Bool(false), "Decoding should fail when \(field) is missing")
            } catch {
                #expect(Bool(true))
            }
        }
    }

    @Test
    func buildUsesNewestRelevantFallbackQuotaRecords() {
        let now = Date(timeIntervalSince1970: 1_500)

        let codexScopedNewest = QuotaRecord(
            tool: .codex,
            accountKey: "codex-account",
            accountLabel: "Account scoped",
            remaining: 5,
            total: 100,
            resetAt: Date(timeIntervalSince1970: 20_000)
        )
        codexScopedNewest.updatedAt = Date(timeIntervalSince1970: 900)

        let codexGenericOlder = QuotaRecord(
            tool: .codex,
            accountKey: nil,
            accountLabel: "Generic older",
            remaining: 21,
            total: 100,
            resetAt: Date(timeIntervalSince1970: 21_000)
        )
        codexGenericOlder.updatedAt = Date(timeIntervalSince1970: 1_000)

        let codexGenericNewest = QuotaRecord(
            tool: .codex,
            accountKey: nil,
            accountLabel: "Generic newest",
            remaining: 63,
            total: 100,
            resetAt: Date(timeIntervalSince1970: 22_000)
        )
        codexGenericNewest.updatedAt = Date(timeIntervalSince1970: 1_100)

        let claudeOlder = QuotaRecord(
            tool: .claudeCode,
            accountKey: nil,
            accountLabel: "Claude older",
            remaining: 18,
            total: 100,
            resetAt: Date(timeIntervalSince1970: 23_000)
        )
        claudeOlder.updatedAt = Date(timeIntervalSince1970: 1_200)

        let claudeNewest = QuotaRecord(
            tool: .claudeCode,
            accountKey: nil,
            accountLabel: "Claude newest",
            remaining: 74,
            total: 100,
            resetAt: Date(timeIntervalSince1970: 24_000)
        )
        claudeNewest.updatedAt = Date(timeIntervalSince1970: 1_300)

        let snapshot = DeskSnapshotBuilder.build(
            now: now,
            codexAccounts: [],
            claudeUsage: nil,
            fallbackQuotas: [
                codexScopedNewest,
                codexGenericOlder,
                claudeOlder,
                codexGenericNewest,
                claudeNewest
            ]
        )

        #expect(snapshot?.codex.remaining == 63)
        #expect(snapshot?.codex.resetAt == Date(timeIntervalSince1970: 22_000))
        #expect(snapshot?.codex.status == .healthy)
        #expect(snapshot?.claude.remaining == 74)
        #expect(snapshot?.claude.resetAt == Date(timeIntervalSince1970: 24_000))
        #expect(snapshot?.claude.status == .healthy)
    }

    @Test
    func buildFallsBackWhenCurrentCodexQuotaIsUnusable() {
        let now = Date(timeIntervalSince1970: 1_600)

        let fallbackCodex = QuotaRecord(
            tool: .codex,
            accountKey: nil,
            accountLabel: "Persisted Codex",
            remaining: 57,
            total: 100,
            resetAt: Date(timeIntervalSince1970: 10_000)
        )
        fallbackCodex.updatedAt = Date(timeIntervalSince1970: 1_500)

        let fallbackClaude = QuotaRecord(
            tool: .claudeCode,
            accountKey: nil,
            accountLabel: "Persisted Claude",
            remaining: 73,
            total: 100,
            resetAt: Date(timeIntervalSince1970: 11_000)
        )
        fallbackClaude.updatedAt = Date(timeIntervalSince1970: 1_550)

        let snapshot = DeskSnapshotBuilder.build(
            now: now,
            codexAccounts: [
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
                            usedPercent: nil,
                            windowMinutes: 300,
                            windowSeconds: nil,
                            resetsAt: nil
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
            claudeUsage: nil,
            fallbackQuotas: [fallbackCodex, fallbackClaude]
        )

        #expect(snapshot?.codex.remaining == 57)
        #expect(snapshot?.codex.total == 100)
        #expect(snapshot?.codex.resetAt == Date(timeIntervalSince1970: 10_000))
        #expect(snapshot?.codex.status == .healthy)
        #expect(snapshot?.codex.petState == .patrol)
    }

    @Test
    func publisherSkipsUnchangedSnapshotsWithinThrottleWindow() async throws {
        let defaults = UserDefaults(suiteName: "DeskSnapshotBuilderTests.publisherSkipsUnchangedSnapshotsWithinThrottleWindow")!
        defaults.removePersistentDomain(forName: "DeskSnapshotBuilderTests.publisherSkipsUnchangedSnapshotsWithinThrottleWindow")

        let store = DeskSnapshotPublishStore(
            userDefaults: defaults,
            key: "test.publish.state"
        )
        let publisher = DeskSnapshotPublisher(
            publishStore: store,
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        #expect(await publisher.shouldPublish(hash: "same-hash") == true)
        await store.save(.init(
            lastHash: "same-hash",
            lastPublishedAt: Date(timeIntervalSince1970: 1_000)
        ))
        #expect(await publisher.shouldPublish(hash: "same-hash") == false)
    }

    @Test
    func cloudKitFailureAfterKeyValuePublishStillMarksSuccess() async throws {
        let defaults = UserDefaults(suiteName: "DeskSnapshotBuilderTests.failedPublishDoesNotThrottleRetry")!
        defaults.removePersistentDomain(forName: "DeskSnapshotBuilderTests.failedPublishDoesNotThrottleRetry")

        let store = DeskSnapshotPublishStore(
            userDefaults: defaults,
            key: "test.publish.state.failed"
        )
        let attempts = DeskSnapshotPublishAttemptCounter()
        let publisher = DeskSnapshotPublisher(
            saveRecord: { _ in
                await attempts.increment()
                struct SaveFailure: Error {}
                throw SaveFailure()
            },
            publishStore: store,
            now: { Date(timeIntervalSince1970: 2_000) }
        )
        let snapshot = DeskSnapshot(
            snapshotID: "desk-current",
            sourceDeviceID: "mac",
            schemaVersion: 1,
            updatedAt: Date(timeIntervalSince1970: 2_000),
            codex: .init(
                tool: .codex,
                displayLabel: "Codex",
                remaining: 68,
                total: 100,
                fraction: 0.68,
                resetAt: Date(timeIntervalSince1970: 2_500),
                weekly: nil,
                status: .healthy,
                petState: .patrol
            ),
            claude: .init(
                tool: .claudeCode,
                displayLabel: "Claude",
                remaining: 19,
                total: 100,
                fraction: 0.19,
                resetAt: Date(timeIntervalSince1970: 3_000),
                weekly: nil,
                status: .critical,
                petState: .alert
            )
        )

        await publisher.publishIfNeeded(snapshot: snapshot)
        await publisher.publishIfNeeded(snapshot: snapshot)
        #expect(await attempts.count == 1)
        #expect(await store.load() != nil)
    }

    @Test
    func publishDebouncerCollapsesBurstSchedules() async throws {
        let attempts = DeskSnapshotPublishAttemptCounter()
        let debouncer = DeskSnapshotPublishDebouncer(delay: .milliseconds(20)) {
            await attempts.increment()
        }

        await debouncer.schedule()
        await debouncer.schedule()

        try await Task.sleep(for: .milliseconds(60))

        #expect(await attempts.count == 1)
    }
}

@Suite("OpenPulse 2.0 dashboard regressions")
@MainActor
struct DashboardSourceRegressionTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test("A seven-day overview includes the first day's midnight usage")
    func overviewIncludesFirstCalendarDay() {
        let period = OverviewCalendarRange.current(days: 7, at: date(2026, 10, 3, hour: 15, minute: 42), calendar: calendar)
        #expect(period.start == date(2026, 9, 27))
        #expect(period.end == date(2026, 10, 4))
        #expect(period.start <= date(2026, 9, 27))
        #expect(period.end > date(2026, 10, 3, hour: 23, minute: 59))
    }

    @Test("Adjacent ninety-day periods have one shared boundary")
    func overviewPreviousPeriodDoesNotOverlap() {
        let now = date(2026, 10, 3, hour: 12)
        let current = OverviewCalendarRange.current(days: 90, at: now, calendar: calendar)
        let previous = OverviewCalendarRange.previous(days: 90, at: now, calendar: calendar)
        #expect(current.start == date(2026, 7, 6))
        #expect(current.end == date(2026, 10, 4))
        #expect(previous.start == date(2026, 4, 7))
        #expect(previous.end == current.start)
        #expect(date(2026, 7, 5, hour: 23, minute: 59) < current.start)
        #expect(current.duration == 90 * 86_400)
        #expect(previous.duration == 90 * 86_400)
    }

    @Test("This week follows the calendar's Monday boundary")
    func quotaWeekExcludesPriorWeekendAndFutureDay() {
        let records = [
            DailyStatsRecord(date: date(2026, 9, 26), tool: .claudeCode, totalInputTokens: 100),
            DailyStatsRecord(date: date(2026, 9, 27), tool: .claudeCode, totalInputTokens: 25),
            DailyStatsRecord(date: date(2026, 9, 28), tool: .claudeCode, totalInputTokens: 20),
            DailyStatsRecord(date: date(2026, 9, 29), tool: .codex, totalInputTokens: 30),
            DailyStatsRecord(date: date(2026, 10, 3), tool: .codex, totalInputTokens: 40, totalOutputTokens: 10),
            DailyStatsRecord(date: date(2026, 10, 4), tool: .codex, totalInputTokens: 999)
        ]
        let result = QuotaUsageTotals.summarize(records, at: date(2026, 10, 3, hour: 12), calendar: calendar)
        #expect(result.week == 100)
        #expect(result.total == 225)
        #expect(result.today == 50)
        #expect(result.byTool == [.codex: 50])
    }

    @Test("Today's quota summary rolls over without adding or deleting records")
    func quotaDayRolloverClearsTodayOnly() {
        let records = [DailyStatsRecord(date: date(2026, 10, 3), tool: .codex, totalInputTokens: 40, totalOutputTokens: 10)]
        let before = QuotaUsageTotals.summarize(records, at: date(2026, 10, 3, hour: 23, minute: 59), calendar: calendar)
        let after = QuotaUsageTotals.summarize(records, at: date(2026, 10, 4), calendar: calendar)
        #expect(before.today == 50)
        #expect(after.today == 0)
        #expect(after.byTool.isEmpty)
        #expect(after.week == 50)
        #expect(after.total == 50)
    }

    @Test("Updating an existing daily row changes the quota summary")
    func quotaSummaryReflectsInPlaceTokenUpdate() {
        let record = DailyStatsRecord(date: date(2026, 10, 3), tool: .claudeCode, totalInputTokens: 10)
        let before = QuotaUsageTotals.summarize([record], at: date(2026, 10, 3, hour: 12), calendar: calendar)
        record.totalInputTokens = 70
        record.totalOutputTokens = 20
        let after = QuotaUsageTotals.summarize([record], at: date(2026, 10, 3, hour: 12), calendar: calendar)
        #expect(before.today == 10)
        #expect(after.today == 90)
        #expect(after.byTool[.claudeCode] == 90)
    }

    @Test("A past Codex reset does not prove a full unused window")
    func codexPastResetBecomesUnknown() {
        let now = date(2026, 10, 3, hour: 12, minute: 30)
        let window = CodexWindow(usedPercent: 88, windowMinutes: 300, windowSeconds: nil, resetsAt: date(2026, 10, 3, hour: 12).timeIntervalSince1970)
        let result = CodexQuotaWindowDisplay(window: window, at: now)
        #expect(result.isStale)
        #expect(result.used == nil)
        #expect(result.remaining == nil)
        #expect(result.fraction == nil)
    }

    @Test("Codex allowance is invalid at the exact reset boundary")
    func codexResetBoundaryBecomesUnknown() {
        let now = date(2026, 10, 3, hour: 12)
        let window = CodexWindow(usedPercent: 88, windowMinutes: 300, windowSeconds: nil, resetsAt: now.timeIntervalSince1970)
        let result = CodexQuotaWindowDisplay(window: window, at: now)
        #expect(result.isStale)
        #expect(result.remaining == nil)
        #expect(result.fraction == nil)
    }

    @Test("A known future Codex window with missing usage stays unknown")
    func codexMissingUsageIsNotZeroUsage() {
        let now = date(2026, 10, 3, hour: 12)
        let window = CodexWindow(usedPercent: nil, windowMinutes: 300, windowSeconds: nil, resetsAt: date(2026, 10, 3, hour: 13).timeIntervalSince1970)
        let result = CodexQuotaWindowDisplay(window: window, at: now)
        #expect(!result.isStale)
        #expect(result.used == nil)
        #expect(result.remaining == nil)
        #expect(result.fraction == nil)
    }

    @Test("A fresh Codex observation retains its reported allowance")
    func codexFreshUsageKeepsReportedPercentage() {
        let now = date(2026, 10, 3, hour: 12)
        let window = CodexWindow(usedPercent: 88, windowMinutes: 300, windowSeconds: nil, resetsAt: date(2026, 10, 3, hour: 13).timeIntervalSince1970)
        let result = CodexQuotaWindowDisplay(window: window, at: now)
        #expect(!result.isStale)
        #expect(result.used == 88)
        #expect(result.remaining == 12)
        #expect(result.fraction == 0.12)
    }

    @Test("The Sunday-aligned leap-year 2028 heatmap needs 54 columns")
    func activityLeapYearIncludesLastWeek() {
        #expect(activityHeatmapColumnCount(year: 2028, calendar: calendar) == 54)
        #expect(activityHeatmapColumnCount(year: 2026, calendar: calendar) == 53)
    }

    @Test("Activity heatmaps exclude future dates and other years")
    func activityHeatmapExcludesFutureSamples() {
        let samples = [
            ActivityHeatmapSample(date: date(2027, 12, 31), tokens: 500),
            ActivityHeatmapSample(date: date(2028, 1, 31), tokens: 75),
            ActivityHeatmapSample(date: date(2028, 2, 2), tokens: 300)
        ]
        let totals = activityHeatmapDailyTotals(samples: samples, year: 2028, now: date(2028, 2, 1, hour: 12), calendar: calendar)
        #expect(totals == [date(2028, 1, 31): 75])
    }

    @Test("Heatmap totals follow same-count sample updates")
    func activityHeatmapSameCountUpdateChangesTotals() {
        let before = [ActivityHeatmapSample(date: date(2026, 10, 3), tokens: 10)]
        let after = [ActivityHeatmapSample(date: date(2026, 10, 3), tokens: 70)]
        let now = date(2026, 10, 3, hour: 12)
        #expect(before.count == after.count)
        #expect(activityHeatmapDailyTotals(samples: before, year: 2026, now: now, calendar: calendar)[date(2026, 10, 3)] == 10)
        #expect(activityHeatmapDailyTotals(samples: after, year: 2026, now: now, calendar: calendar)[date(2026, 10, 3)] == 70)
    }

    @Test("Menu-bar today's totals exclude yesterday and tomorrow")
    func menuBarTodayUsesHalfOpenCalendarDay() {
        let stats = [
            MenuBarDailyStatsSnapshot(date: date(2026, 10, 2), tool: .codex, inputTokens: 999, outputTokens: 1),
            MenuBarDailyStatsSnapshot(date: date(2026, 10, 3), tool: .codex, inputTokens: 40, outputTokens: 10),
            MenuBarDailyStatsSnapshot(date: date(2026, 10, 3), tool: .claudeCode, inputTokens: 20, outputTokens: 5),
            MenuBarDailyStatsSnapshot(date: date(2026, 10, 4), tool: .codex, inputTokens: 999, outputTokens: 1)
        ]
        let result = menuBarTodayTokens(from: stats, dayStart: date(2026, 10, 3), calendar: calendar)
        #expect(result == [.codex: 50, .claudeCode: 25])
    }

    @Test("Menu-bar fractions reject expired or nonfinite allowance")
    func menuBarExpiredAndInvalidFractionsStayUnknown() {
        let now = date(2026, 10, 3, hour: 12)
        #expect(menuBarQuotaFraction(remainingFraction: 0.68, resetAt: date(2026, 10, 3, hour: 11), now: now) == nil)
        #expect(menuBarQuotaFraction(remainingFraction: 0.68, resetAt: now, now: now) == nil)
        #expect(menuBarQuotaFraction(remainingFraction: Double.nan, resetAt: date(2026, 10, 3, hour: 13), now: now) == nil)
        #expect(menuBarQuotaFraction(remainingFraction: Double.infinity, resetAt: nil, now: now) == nil)
        #expect(menuBarQuotaFraction(remainingFraction: nil, resetAt: nil, now: now) == nil)
        #expect(menuBarQuotaFraction(remainingFraction: 0.68, resetAt: date(2026, 10, 3, hour: 13), now: now) == 0.68)
    }

    @Test("Hidden Antigravity accounts are removed before menu-bar aggregation")
    func menuBarAntigravityHidingPreservesVisibleAccountOrder() {
        let accounts = [
            AGAccountQuota(email: "first@example.com", tier: nil, groups: []),
            AGAccountQuota(email: "hidden@example.com", tier: nil, groups: []),
            AGAccountQuota(email: "last@example.com", tier: nil, groups: [])
        ]
        let visible = menuBarVisibleAntigravityAccounts(accounts, hiddenAccountEmailsRaw: "hidden@example.com,,")
        #expect(visible.map(\.email) == ["first@example.com", "last@example.com"])
        #expect(menuBarVisibleAntigravityAccounts(accounts, hiddenAccountEmailsRaw: "first@example.com,hidden@example.com,last@example.com").isEmpty)
    }

    @Test("Copilot missing or nonfinite allowance remains unknown")
    func copilotInvalidAllowanceIsNotZero() {
        let invalidValues: [Double?] = [nil, Double.nan, Double.infinity, -Double.infinity]
        for value in invalidValues {
            #expect(copilotAnalysisRemainingFraction(percentRemaining: value) == nil)
        }
        #expect(copilotAnalysisRemainingFraction(percentRemaining: 75) == 0.75)
        #expect(copilotAnalysisRemainingFraction(percentRemaining: 120) == 1)
        #expect(copilotAnalysisRemainingFraction(percentRemaining: -5) == 0)
    }
}

struct DeskSnapshotCloudUpsertTests {
    @Test func fixedCurrentRecordUpdatesToSecondSnapshotWithoutAChangeTag() async throws {
        let cloud = DeskSnapshotCloudStoreDouble()
        let first = Self.snapshot(updatedAt: 1_000, remaining: 68)
        let second = Self.snapshot(updatedAt: 1_100, remaining: 41)
        let firstRecord = DeskSnapshotRecordCodec.makeRecord(snapshot: first, zoneID: nil)
        let secondRecord = DeskSnapshotRecordCodec.makeRecord(snapshot: second, zoneID: nil)
        #expect(firstRecord.recordID == secondRecord.recordID)
        #expect(firstRecord.recordChangeTag == nil)
        #expect(secondRecord.recordChangeTag == nil)

        try await DeskSnapshotPublisher.upsertCloudRecord(firstRecord) { records, policy in
            await cloud.modify(records, policy: policy)
        }
        try await DeskSnapshotPublisher.upsertCloudRecord(secondRecord) { records, policy in
            await cloud.modify(records, policy: policy)
        }

        let saved = try #require(await cloud.record(for: secondRecord.recordID))
        #expect(try DeskSnapshotRecordCodec.decode(saved) == second)
        #expect(await cloud.attemptCount == 2)
    }

    @Test func individualSaveFailureIsThrownEvenWhenModifyOperationCompletes() async throws {
        let record = DeskSnapshotRecordCodec.makeRecord(snapshot: Self.snapshot(updatedAt: 1_000, remaining: 68), zoneID: nil)
        do {
            try await DeskSnapshotPublisher.upsertCloudRecord(record) { records, _ in
                [records[0].recordID: .failure(DeskSnapshotCloudFixtureError.perRecordFailure)]
            }
            Issue.record("An individual record failure must not be treated as a successful cloud save")
        } catch DeskSnapshotCloudFixtureError.perRecordFailure {
        } catch { Issue.record("Expected the individual record's original failure") }
    }

    @Test func missingIndividualSaveResultIsNotTreatedAsSuccess() async throws {
        let record = DeskSnapshotRecordCodec.makeRecord(snapshot: Self.snapshot(updatedAt: 1_000, remaining: 68), zoneID: nil)
        do {
            try await DeskSnapshotPublisher.upsertCloudRecord(record) { _, _ in [:] }
            Issue.record("A missing record result must not be treated as a successful cloud save")
        } catch let error as CKError {
            #expect(error.code == .internalError)
        } catch { Issue.record("Expected an incomplete CloudKit result error") }
    }

    private static func snapshot(updatedAt: TimeInterval, remaining: Int) -> DeskSnapshot {
        DeskSnapshot(
            snapshotID: "desk-current", sourceDeviceID: "fixture-mac", schemaVersion: 2,
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            codex: .init(tool: .codex, displayLabel: "Codex", remaining: remaining, total: 100,
                         fraction: Double(remaining) / 100, resetAt: Date(timeIntervalSince1970: 2_000),
                         weekly: nil, status: .healthy, petState: .patrol),
            claude: .init(tool: .claudeCode, displayLabel: "Claude", remaining: 42, total: 100,
                          fraction: 0.42, resetAt: Date(timeIntervalSince1970: 3_000),
                          weekly: nil, status: .warning, petState: .pause)
        )
    }
}

private enum DeskSnapshotCloudFixtureError: Error { case perRecordFailure }

/// Synthetic change-tag policy behavior only; never opens a CloudKit database or global KVS.
private actor DeskSnapshotCloudStoreDouble {
    private var records: [CKRecord.ID: CKRecord] = [:]
    private(set) var attemptCount = 0

    func modify(_ incoming: [CKRecord], policy: CKModifyRecordsOperation.RecordSavePolicy) -> [CKRecord.ID: Result<CKRecord, any Error>] {
        attemptCount += 1
        var results: [CKRecord.ID: Result<CKRecord, any Error>] = [:]
        for record in incoming {
            if records[record.recordID] != nil && policy == .ifServerRecordUnchanged {
                results[record.recordID] = .failure(CKError(.serverRecordChanged))
                continue
            }
            records[record.recordID] = record
            results[record.recordID] = .success(record)
        }
        return results
    }

    func record(for id: CKRecord.ID) -> CKRecord? { records[id] }
}

struct DeskSnapshotWindowAccuracyTests {
    @Test func weeklyExhaustionKeepsSessionValuesAndSetsEffectiveStatus() throws {
        let now = Date(timeIntervalSince1970: 2_000)
        let snapshot = try #require(DeskSnapshotBuilder.build(
            now: now,
            codexAccounts: [Self.account(sessionRemaining: 80, weeklyRemaining: 0, observedAt: now)],
            claudeUsage: .init(fiveHour: .init(utilization: 25, resetsAt: "4000"),
                               sevenDay: .init(utilization: 100, resetsAt: "8000")),
            claudeObservedAt: now,
            fallbackQuotas: []
        ))
        #expect(snapshot.codex.session.remaining == 80)
        #expect(snapshot.codex.session.resetAt == Date(timeIntervalSince1970: 4_000))
        #expect(snapshot.codex.weekly?.remaining == 0)
        #expect(snapshot.codex.status == .exhausted)
        #expect(snapshot.codex.petState == .exhausted)
        #expect(snapshot.claude.session.remaining == 75)
        #expect(snapshot.claude.session.resetAt == Date(timeIntervalSince1970: 4_000))
        #expect(snapshot.claude.weekly?.remaining == 0)
        #expect(snapshot.claude.status == .exhausted)
        #expect(snapshot.claude.petState == .exhausted)
    }

    @Test func weeklyOnlySourcesKeepSessionUnknown() throws {
        let now = Date(timeIntervalSince1970: 2_000)
        let snapshot = try #require(DeskSnapshotBuilder.build(
            now: now,
            codexAccounts: [Self.account(sessionRemaining: nil, weeklyRemaining: 0, observedAt: now)],
            claudeUsage: .init(fiveHour: nil, sevenDay: .init(utilization: 100, resetsAt: "8000")),
            claudeObservedAt: now,
            fallbackQuotas: []
        ))
        for tool in [snapshot.codex, snapshot.claude] {
            #expect(tool.session.remaining == nil)
            #expect(tool.session.fraction == nil)
            #expect(tool.session.resetAt == nil)
            #expect(tool.weekly?.remaining == 0)
            #expect(tool.status == .exhausted)
        }
    }

    @Test func publishingDoesNotRefreshOldOrUnknownClaudeObservations() throws {
        let now = Date(timeIntervalSince1970: 2_000)
        for observedAt in [Date(timeIntervalSince1970: 1_000), nil] as [Date?] {
            let snapshot = try #require(DeskSnapshotBuilder.build(
                now: now,
                codexAccounts: [Self.account(sessionRemaining: 80, weeklyRemaining: 80, observedAt: now)],
                claudeUsage: .init(fiveHour: .init(utilization: 20, resetsAt: "4000"), sevenDay: nil),
                claudeObservedAt: observedAt,
                fallbackQuotas: []
            ))
            #expect(snapshot.updatedAt == now)
            #expect(snapshot.claude.remaining == 80)
            #expect(snapshot.claude.status == .stale)
            #expect(snapshot.claude.petState == .waiting)
        }
    }

    @Test func elapsedSessionOrWeeklyResetNeedsNewObservation() throws {
        let now = Date(timeIntervalSince1970: 2_000)
        for expiredWeekly in [false, true] {
            var account = Self.account(sessionRemaining: 80, weeklyRemaining: 0, observedAt: now)
            account.limits = .init(
                primary: .init(usedPercent: 20, windowMinutes: 300, windowSeconds: nil,
                               resetsAt: expiredWeekly ? 4_000 : 2_000),
                secondary: .init(usedPercent: 100, windowMinutes: 10_080, windowSeconds: nil,
                                 resetsAt: expiredWeekly ? 2_000 : 8_000),
                credits: nil, resetCredits: nil, planType: "pro", observedAt: now
            )
            let snapshot = try #require(DeskSnapshotBuilder.build(
                now: now,
                codexAccounts: [account],
                claudeUsage: .init(
                    fiveHour: .init(utilization: 20, resetsAt: expiredWeekly ? "4000" : "2000"),
                    sevenDay: .init(utilization: 100, resetsAt: expiredWeekly ? "2000" : "8000")
                ),
                claudeObservedAt: now,
                fallbackQuotas: []
            ))
            #expect(snapshot.codex.status == .stale)
            #expect(snapshot.claude.status == .stale)
            #expect(snapshot.codex.petState == .waiting)
            #expect(snapshot.claude.petState == .waiting)
        }
    }

    @Test func invalidClaudePercentDoesNotBecomeAnIntegerOrInventAWindow() throws {
        let now = Date(timeIntervalSince1970: 2_000)
        for utilization in [Double.nan, Double.infinity, -Double.infinity] {
            let snapshot = try #require(DeskSnapshotBuilder.build(
                now: now,
                codexAccounts: [Self.account(sessionRemaining: 80, weeklyRemaining: 80, observedAt: now)],
                claudeUsage: .init(fiveHour: .init(utilization: utilization, resetsAt: "4000"),
                                   sevenDay: .init(utilization: 20, resetsAt: "8000")),
                claudeObservedAt: now,
                fallbackQuotas: []
            ))
            #expect(snapshot.claude.session.remaining == nil)
            #expect(snapshot.claude.session.fraction == nil)
            #expect(snapshot.claude.weekly?.remaining == 80)
            #expect(snapshot.claude.status == .warning)
        }
    }

    private static func account(sessionRemaining: Double?, weeklyRemaining: Double, observedAt: Date) -> CodexAccountSnapshot {
        .init(
            id: "fixture-account", label: "Fixture", email: "fixture@example.com", accountID: "fixture-account",
            planType: "pro", teamName: nil, addedAt: .distantPast, updatedAt: observedAt,
            lastFetchedAt: observedAt,
            limits: .init(
                primary: sessionRemaining.map {
                    .init(usedPercent: 100 - $0, windowMinutes: 300, windowSeconds: nil, resetsAt: 4_000)
                },
                secondary: .init(usedPercent: 100 - weeklyRemaining, windowMinutes: 10_080,
                                 windowSeconds: nil, resetsAt: 8_000),
                credits: nil, resetCredits: nil, planType: "pro", observedAt: observedAt
            ),
            usageError: nil, isCurrent: true
        )
    }
}
