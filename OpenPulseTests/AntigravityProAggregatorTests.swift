import XCTest
@testable import OpenPulse

final class AntigravityProAggregatorTests: XCTestCase {
    func testAggregateProAccountsAveragesFractionsAndFindsEarliestReset() {
        let date1 = Date().addingTimeInterval(3600)
        let date2 = Date().addingTimeInterval(1800)
        
        let account1 = AGAccountQuota(
            email: "pro1@gmail.com",
            tier: AGTier(id: "gai-pro", name: "Google AI Pro"),
            groups: [
                AGQuotaGroup(
                    id: "gemini",
                    displayName: "Gemini",
                    fiveHour: AGWindow(kind: .fiveHour, remainingFraction: 0.8, resetTime: date1, description: nil),
                    weekly: AGWindow(kind: .weekly, remainingFraction: 0.6, resetTime: date1, description: nil)
                )
            ]
        )
        
        let account2 = AGAccountQuota(
            email: "pro2@gmail.com",
            tier: AGTier(id: "gai-pro", name: "Google AI Pro"),
            groups: [
                AGQuotaGroup(
                    id: "gemini",
                    displayName: "Gemini",
                    fiveHour: AGWindow(kind: .fiveHour, remainingFraction: 0.6, resetTime: date2, description: nil),
                    weekly: AGWindow(kind: .weekly, remainingFraction: 0.4, resetTime: date2, description: nil)
                )
            ]
        )
        
        let freeAccount = AGAccountQuota(
            email: "free@gmail.com",
            tier: AGTier(id: "free-tier", name: "Free Tier"),
            groups: [
                AGQuotaGroup(
                    id: "gemini",
                    displayName: "Gemini",
                    fiveHour: AGWindow(kind: .fiveHour, remainingFraction: 0.1, resetTime: date1, description: nil),
                    weekly: nil
                )
            ]
        )
        
        let summary = AntigravityProAggregator.aggregate(accounts: [account1, account2, freeAccount])
        
        XCTAssertEqual(summary.proAccountCount, 2)
        XCTAssertEqual(summary.groups.count, 1)
        
        let geminiGroup = summary.groups.first { $0.id == "gemini" }
        XCTAssertNotNil(geminiGroup)
        
        // 5h average = (0.8 + 0.6) / 2 = 0.7
        XCTAssertEqual(geminiGroup?.fiveHour?.remainingFraction ?? 0, 0.7, accuracy: 0.001)
        // Earliest reset = date2 (1800s in future vs 3600s)
        XCTAssertEqual(geminiGroup?.fiveHour?.validatedResetDate, date2)
        
        // Weekly average = (0.6 + 0.4) / 2 = 0.5
        XCTAssertEqual(geminiGroup?.weekly?.remainingFraction ?? 0, 0.5, accuracy: 0.001)
    }
    func testZeroWeeklyQuotaMarksFiveHourUnusableWhilePreservingPercentage() {
        let date = Date().addingTimeInterval(3600)
        let groupWithZeroWeekly = AGQuotaGroup(
            id: "gemini",
            displayName: "Gemini",
            fiveHour: AGWindow(kind: .fiveHour, remainingFraction: 1.0, resetTime: date, description: nil),
            weekly: AGWindow(kind: .weekly, remainingFraction: 0.0, resetTime: date, description: nil)
        )
        
        XCTAssertTrue(groupWithZeroWeekly.isFiveHourUnusable)
        XCTAssertEqual(groupWithZeroWeekly.fiveHour?.remainingPercentText, "100%")
        
        let account = AGAccountQuota(
            email: "pro1@gmail.com",
            tier: AGTier(id: "gai-pro", name: "Google AI Pro"),
            groups: [groupWithZeroWeekly]
        )
        
        let summary = AntigravityProAggregator.aggregate(accounts: [account])
        let geminiGroup = summary.groups.first { $0.id == "gemini" }
        XCTAssertEqual(geminiGroup?.fiveHour?.remainingFraction, 1.0)
        XCTAssertTrue(geminiGroup?.isFiveHourUnusable == true)
    }
}
