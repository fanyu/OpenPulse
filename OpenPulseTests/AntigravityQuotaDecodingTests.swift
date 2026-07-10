import Testing
import Foundation
@testable import OpenPulse

struct AntigravityQuotaDecodingTests {
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
    }
}
