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
}
