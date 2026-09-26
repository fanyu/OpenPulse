import Testing
import Foundation
@testable import OpenPulse

struct ClaudeUsageTests {
    @Test
    func weeklyQuotaZeroMakesEffectiveRemainingZero() {
        let usage = ClaudeUsageResponse(
            fiveHour: UsageWindow(utilization: 0, resetsAt: "1000"),
            sevenDay: UsageWindow(utilization: 100, resetsAt: "5000")
        )

        #expect(usage.isWeeklyExhausted)
        #expect(usage.fiveHourRemainingPercent == 100)
        #expect(usage.sevenDayRemainingPercent == 0)
        #expect(usage.effectiveRemainingPercent == 0)
        #expect(usage.effectiveFraction == 0.0)
    }

    @Test
    func weeklyQuotaNotExhaustedPreservesFiveHourWindow() {
        let usage = ClaudeUsageResponse(
            fiveHour: UsageWindow(utilization: 20, resetsAt: "1000"),
            sevenDay: UsageWindow(utilization: 85, resetsAt: "5000")
        )

        #expect(!usage.isWeeklyExhausted)
        #expect(usage.fiveHourRemainingPercent == 80)
        #expect(usage.sevenDayRemainingPercent == 15)
        #expect(usage.effectiveRemainingPercent == 80)
        #expect(usage.effectiveFraction == 0.80)
    }

    @Test
    func fiveHourWindowConstrainsEffectiveRemaining() {
        let usage = ClaudeUsageResponse(
            fiveHour: UsageWindow(utilization: 80, resetsAt: "1000"),
            sevenDay: UsageWindow(utilization: 40, resetsAt: "5000")
        )

        #expect(!usage.isWeeklyExhausted)
        #expect(usage.fiveHourRemainingPercent == 20)
        #expect(usage.sevenDayRemainingPercent == 60)
        #expect(usage.effectiveRemainingPercent == 20)
        #expect(usage.effectiveFraction == 0.20)
    }

    @Test
    func missingWeeklyWindowUsesFiveHour() {
        let usage = ClaudeUsageResponse(
            fiveHour: UsageWindow(utilization: 25, resetsAt: "1000"),
            sevenDay: nil
        )

        #expect(!usage.isWeeklyExhausted)
        #expect(usage.fiveHourRemainingPercent == 75)
        #expect(usage.sevenDayRemainingPercent == nil)
        #expect(usage.effectiveRemainingPercent == 75)
        #expect(usage.effectiveFraction == 0.75)
    }

    @Test
    func missingFiveHourWindowUsesWeekly() {
        let usage = ClaudeUsageResponse(
            fiveHour: nil,
            sevenDay: UsageWindow(utilization: 60, resetsAt: "5000")
        )

        #expect(!usage.isWeeklyExhausted)
        #expect(usage.fiveHourRemainingPercent == nil)
        #expect(usage.sevenDayRemainingPercent == 40)
        #expect(usage.effectiveRemainingPercent == 40)
        #expect(usage.effectiveFraction == 0.40)
    }

    @Test
    func weeklyExhaustedOver100PercentUtilization() {
        let usage = ClaudeUsageResponse(
            fiveHour: UsageWindow(utilization: 10, resetsAt: "1000"),
            sevenDay: UsageWindow(utilization: 105, resetsAt: "5000")
        )

        #expect(usage.isWeeklyExhausted)
        #expect(usage.sevenDayRemainingPercent == 0)
        #expect(usage.effectiveRemainingPercent == 0)
        #expect(usage.effectiveFraction == 0.0)
    }
}
