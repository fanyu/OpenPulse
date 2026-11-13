import Testing
import Foundation
@testable import OpenPulse

struct AntigravityQuotaDecodingTests {
    @Test @MainActor func antigravityPollsEveryThreeMinutes() {
        #expect(DataSyncService.defaultPollInterval[.antigravity] == 180)
    }

    private let summaryJSON = """
    {"groups":[
      {"displayName":"Gemini Models","buckets":[
        {"bucketId":"gemini-weekly","window":"weekly","resetTime":"2999-07-16T02:49:09Z","remainingFraction":0.7138273,"description":"weekly prose"},
        {"bucketId":"gemini-5h","window":"5h","resetTime":"2999-07-10T06:42:14Z","remainingFraction":0.5812507,"description":"5h prose"}]},
      {"displayName":"Claude and GPT models","buckets":[
        {"bucketId":"3p-weekly","window":"weekly","resetTime":"2999-07-16T05:52:06Z","remainingFraction":0.66538054},
        {"bucketId":"3p-5h","window":"5h","resetTime":"2999-07-10T07:40:22Z","remainingFraction":1}]}]}
    """.data(using: .utf8)!

    @Test func decodesTwoGroupsWithBothWindows() throws {
        let groups = try AntigravityParser.decodeQuotaGroups(from: summaryJSON)
        #expect(groups.count == 2)
        let gemini = try #require(groups.first { $0.displayName == "Gemini Models" })
        #expect(gemini.id == "gemini")
        #expect(gemini.fiveHour?.kind == .fiveHour)
        #expect(gemini.fiveHour?.remainingFraction == 0.5812507)
        #expect(gemini.fiveHour?.description == "5h prose")
        #expect(gemini.weekly?.remainingFraction == 0.7138273)
        #expect(gemini.weekly?.validatedResetDate != nil)   // year 2999 = future
        let thirdParty = try #require(groups.first { $0.id == "3p" })
        #expect(thirdParty.fiveHour?.remainingFraction == 1)
        #expect(thirdParty.fiveHour?.description == nil)
    }

    @Test func percentTextAndClamp() throws {
        let groups = try AntigravityParser.decodeQuotaGroups(from: summaryJSON)
        let gemini = try #require(groups.first { $0.id == "gemini" })
        #expect(gemini.fiveHour?.remainingPercentText == "58%")
    }

    @Test func tierFreeVsPaid() {
        let free = AntigravityParser.decodeTier(from: #"{"currentTier":{"id":"free-tier","name":"Antigravity"}}"#.data(using: .utf8)!)
        #expect(free?.isPaid == false)
        #expect(free?.badgeLabel == "Free")
        let paid = AntigravityParser.decodeTier(from: #"{"currentTier":{"id":"legacy-tier","name":"Google AI Pro"}}"#.data(using: .utf8)!)
        #expect(paid?.isPaid == true)
        #expect(paid?.badgeLabel == "Google AI Pro")
        let paidFromPaidTier = AntigravityParser.decodeTier(from: #"{"currentTier":{"id":"free-tier","name":"Antigravity"},"paidTier":{"id":"g1-pro-tier","name":"Google AI Pro"}}"#.data(using: .utf8)!)
        #expect(paidFromPaidTier?.isPaid == true)
        #expect(paidFromPaidTier?.badgeLabel == "Google AI Pro")
        let starterFromPaidTier = AntigravityParser.decodeTier(from: #"{"currentTier":{"id":"free-tier","name":"Antigravity"},"paidTier":{"id":"free-tier","name":"Antigravity Starter Quota"}}"#.data(using: .utf8)!)
        #expect(starterFromPaidTier?.isPaid == false)
        #expect(starterFromPaidTier?.badgeLabel == "Free")
    }

    @Test func single3PGroupWithBothWindowsIsGoogleAIPro() {
        let single3P = [
            AGQuotaGroup(
                id: "3p",
                displayName: "Claude and GPT models",
                fiveHour: AGWindow(kind: .fiveHour, remainingFraction: 1.0, resetTime: nil, description: nil),
                weekly: AGWindow(kind: .weekly, remainingFraction: 0.8, resetTime: nil, description: nil)
            )
        ]
        let account = AGAccountQuota(
            email: "pro@example.com",
            tier: AGTier(id: "free-tier", name: "Antigravity"),
            groups: single3P
        )
        #expect(account.isPaid)
        #expect(account.badgeLabel == "Google AI Pro")
    }

    @Test func single3PGroupWithWeeklyOnlyRemainsFree() {
        let weeklyOnly3P = [
            AGQuotaGroup(
                id: "3p",
                displayName: "Claude and GPT models",
                fiveHour: nil,
                weekly: AGWindow(kind: .weekly, remainingFraction: 0.8, resetTime: nil, description: nil)
            )
        ]
        let account = AGAccountQuota(
            email: "free@example.com",
            tier: AGTier(id: "free-tier", name: "Antigravity"),
            groups: weeklyOnly3P
        )
        #expect(!account.isPaid)
        #expect(account.badgeLabel == "Free")
    }

    @Test func completeConsumerQuotaWindowsAreGoogleAIPro() throws {
        let groups = try AntigravityParser.decodeQuotaGroups(from: summaryJSON)
        let account = AGAccountQuota(
            email: "pro@example.com",
            tier: AGTier(id: "free-tier", name: "Antigravity"),
            groups: groups
        )

        #expect(account.isPaid)
        #expect(account.badgeLabel == "Google AI Pro")
    }

    @Test func incompleteFreeQuotaWindowsRemainFree() throws {
        let groups = try AntigravityParser.decodeQuotaGroups(from: summaryJSON)
        let weeklyOnly = groups.map { group in
            AGQuotaGroup(
                id: group.id,
                displayName: group.displayName,
                fiveHour: nil,
                weekly: group.weekly
            )
        }
        let account = AGAccountQuota(
            email: "free@example.com",
            tier: AGTier(id: "free-tier", name: "Antigravity"),
            groups: weeklyOnly
        )

        #expect(!account.isPaid)
        #expect(account.badgeLabel == "Free")
    }

    @Test func nonFreeTierRemainsPaidWithoutQuotaWindows() {
        let account = AGAccountQuota(
            email: "standard@example.com",
            tier: AGTier(id: "standard-tier", name: "Antigravity"),
            groups: []
        )

        #expect(account.isPaid)
        #expect(account.badgeLabel == "Google AI Pro")
    }

    @Test func pastResetReturnsNilForBothWindows() {
        let past = Date().addingTimeInterval(-3600)
        let daily = AGWindow(kind: .fiveHour, remainingFraction: 0.5, resetTime: past, description: nil)
        #expect(daily.validatedResetDate == nil)

        let weekly = AGWindow(kind: .weekly, remainingFraction: 0.5, resetTime: past, description: nil)
        #expect(weekly.validatedResetDate == nil)
    }

    @Test func futureResetReturnsDateForBothWindows() {
        let future = Date().addingTimeInterval(3600)
        let daily = AGWindow(kind: .fiveHour, remainingFraction: 0.5, resetTime: future, description: nil)
        #expect(daily.validatedResetDate != nil)

        let weekly = AGWindow(kind: .weekly, remainingFraction: 0.5, resetTime: future, description: nil)
        #expect(weekly.validatedResetDate != nil)
    }

    @Test func resetCountdownFormat() {
        let future = Date().addingTimeInterval(3600)
        let daily = AGWindow(kind: .fiveHour, remainingFraction: 0.5, resetTime: future, description: nil)
        #expect(daily.resetCountdown != nil)
        // HH:mm format — no slash (date separator) in output
        #expect(daily.resetCountdown?.contains("/") == false)

        let weekly = AGWindow(kind: .weekly, remainingFraction: 0.5, resetTime: future, description: nil)
        #expect(weekly.resetCountdown != nil)
        // MM/dd HH:mm format — must contain slash
        #expect(weekly.resetCountdown?.contains("/") == true)
    }

    @Test func decodesGeminiArgonWithoutExplicitWindowField() throws {
        let payload = """
        {"groups":[
          {"displayName":"Gemini Models","buckets":[
            {"bucketId":"gemini-weekly","window":"weekly","resetTime":"2999-07-16T02:49:09Z","remainingFraction":0.7},
            {"bucketId":"gemini-5h","window":"5h","resetTime":"2999-07-10T06:42:14Z","remainingFraction":0.9}]},
          {"displayName":"Gemini 4 Argon","buckets":[
            {"bucketId":"gemini-argon-wtu-weekly","resetTime":"2999-07-16T02:49:09Z","remainingFraction":0.42}]},
          {"displayName":"Claude and GPT models","buckets":[
            {"bucketId":"3p-weekly","window":"weekly","resetTime":"2999-07-16T05:52:06Z","remainingFraction":1},
            {"bucketId":"3p-5h","window":"5h","resetTime":"2999-07-10T07:40:22Z","remainingFraction":1}]}]}
        """.data(using: .utf8)!

        let groups = try AntigravityParser.decodeQuotaGroups(from: payload)
        #expect(groups.map(\.id) == ["gemini", "gemini-argon", "3p"])
        let argon = try #require(groups.first { $0.id == "gemini-argon" })
        #expect(argon.displayName == "Gemini 4 Argon")
        #expect(argon.fiveHour == nil)
        #expect(argon.weekly?.remainingFraction == 0.42)
    }

    @Test func apiUserAgentMeetsCliMinimumVersion() {
        #expect(AntigravityParser.apiUserAgent.hasPrefix("antigravity/cli/"))
        let versionPart = AntigravityParser.apiUserAgent
            .dropFirst("antigravity/cli/".count)
            .split(separator: " ")
            .first ?? ""
        let parts = versionPart.split(separator: ".").compactMap { Int($0) }
        #expect(parts.count >= 2)
        let isAtLeast1_3 = parts[0] > 1 || (parts[0] == 1 && parts[1] >= 3)
        #expect(isAtLeast1_3)
    }
}
