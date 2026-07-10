import Testing
@testable import OpenPulse
import Foundation

struct AntigravityCredentialMergeTests {
    @Test func openPulseWinsOnDuplicateEmail() {
        let url = URL(fileURLWithPath: "/tmp/antigravity-a_gmail_com.json")
        let cli = [AGCredential(email: "a@gmail.com", source: .cliProxy(url)),
                   AGCredential(email: "b@gmail.com", source: .cliProxy(url))]
        let op  = [AGCredential(email: "a@gmail.com", source: .openPulse)]
        let merged = AntigravityParser.mergeCredentials(cliProxy: cli, openPulse: op)
        #expect(merged.count == 2)
        let a = merged.first { $0.email == "a@gmail.com" }
        if case .openPulse = a?.source {} else { Issue.record("expected openPulse source to win") }
    }
}
