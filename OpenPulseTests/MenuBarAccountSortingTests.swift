import Foundation
import Testing
@testable import OpenPulse

struct MenuBarAccountSortingTests {
    @Test func manualOrderAppliesSavedRanksAndAppendsNewAccounts() {
        let accounts = [
            makeAGAccount(email: "a@example.com", gemini5h: 0.9, gemini7d: 0.8),
            makeAGAccount(email: "b@example.com", gemini5h: 0.5, gemini7d: 0.5),
            makeAGAccount(email: "c@example.com", gemini5h: 0.2, gemini7d: 0.3),
        ]

        let sorted = MenuBarAccountOrdering.sortAntigravityAccounts(
            accounts,
            mode: .manual,
            manualOrderRaw: "c@example.com,missing@example.com,a@example.com"
        )
        #expect(sorted.map(\.email) == ["c@example.com", "a@example.com", "b@example.com"])
    }

    @Test func reorderingAndMovingPreserveHiddenIdentifiers() {
        let reordered = MenuBarAccountOrdering.reordering(
            visibleIDs: ["a", "b", "c"],
            existingOrderRaw: "a,hidden-1,b,c",
            draggedID: "c",
            to: "a"
        )
        #expect(reordered == "c,a,b,hidden-1")

        let moved = MenuBarAccountOrdering.moving(
            visibleIDs: ["c", "a", "b"],
            existingOrderRaw: reordered,
            id: "a",
            by: 1
        )
        #expect(moved == "c,b,a,hidden-1")
    }

    @Test func antigravityAutoSortOrdersByQuotaAndKeepsUnknownLast() {
        let accounts = [
            makeAGAccount(email: "low@example.com", gemini5h: 0.20, gemini7d: 0.50),
            makeAGAccount(email: "unknown@example.com", gemini5h: nil, gemini7d: nil),
            makeAGAccount(email: "high@example.com", gemini5h: 0.85, gemini7d: 0.90),
            makeAGAccount(email: "weekly-exhausted@example.com", gemini5h: 0.95, gemini7d: 0.0),
        ]

        let desc = MenuBarAccountOrdering.sortAntigravityAccounts(accounts, mode: .quotaDescending, manualOrderRaw: "")
        #expect(desc.map(\.email) == [
            "high@example.com",
            "low@example.com",
            "weekly-exhausted@example.com",
            "unknown@example.com",
        ])

        let asc = MenuBarAccountOrdering.sortAntigravityAccounts(accounts, mode: .quotaAscending, manualOrderRaw: "")
        #expect(asc.map(\.email) == [
            "weekly-exhausted@example.com",
            "low@example.com",
            "high@example.com",
            "unknown@example.com",
        ])
    }

    @Test func codexAutoSortOrdersByRemainingQuotaAndRespectsExpiredWindows() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let future = now.addingTimeInterval(3_600).timeIntervalSince1970
        let past = now.addingTimeInterval(-60).timeIntervalSince1970

        let accounts = [
            makeCodexAccount(id: "mid", used5h: 40, reset5h: future, used7d: 30, reset7d: future),
            makeCodexAccount(id: "expired", used5h: 10, reset5h: past, used7d: 10, reset7d: past),
            makeCodexAccount(id: "high", used5h: 10, reset5h: future, used7d: 20, reset7d: future),
            makeCodexAccount(id: "weekly-zero", used5h: 5, reset5h: future, used7d: 100, reset7d: future),
        ]

        let desc = MenuBarAccountOrdering.sortCodexAccounts(accounts, mode: .quotaDescending, manualOrderRaw: "", now: now)
        #expect(desc.map(\.id) == ["high", "mid", "weekly-zero", "expired"])

        let asc = MenuBarAccountOrdering.sortCodexAccounts(accounts, mode: .quotaAscending, manualOrderRaw: "", now: now)
        #expect(asc.map(\.id) == ["weekly-zero", "mid", "high", "expired"])
    }

    private func makeAGAccount(email: String, gemini5h: Double?, gemini7d: Double?) -> AGAccountQuota {
        let groups: [AGQuotaGroup] = if gemini5h == nil && gemini7d == nil {
            []
        } else {
            [
                AGQuotaGroup(
                    id: "gemini",
                    displayName: "Gemini Models",
                    fiveHour: gemini5h.map { AGWindow(kind: .fiveHour, remainingFraction: $0, resetTime: nil, description: nil) },
                    weekly: gemini7d.map { AGWindow(kind: .weekly, remainingFraction: $0, resetTime: nil, description: nil) }
                )
            ]
        }
        return AGAccountQuota(email: email, tier: nil, groups: groups)
    }

    private func makeCodexAccount(
        id: String,
        used5h: Double?,
        reset5h: Double?,
        used7d: Double?,
        reset7d: Double?
    ) -> CodexAccountSnapshot {
        let limits = CodexRateLimits(
            primary: used5h.map { CodexWindow(usedPercent: $0, windowMinutes: 300, windowSeconds: nil, resetsAt: reset5h) },
            secondary: used7d.map { CodexWindow(usedPercent: $0, windowMinutes: 10_080, windowSeconds: nil, resetsAt: reset7d) },
            credits: nil,
            resetCredits: nil,
            planType: "pro",
            observedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        return CodexAccountSnapshot(
            id: id,
            label: id,
            email: "\(id)@example.com",
            accountID: "acct-\(id)",
            planType: "pro",
            teamName: nil,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastFetchedAt: Date(timeIntervalSince1970: 1_800_000_000),
            limits: limits,
            usageError: nil,
            isCurrent: false
        )
    }
}
