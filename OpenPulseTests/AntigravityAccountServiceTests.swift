import Testing
import Foundation
@testable import OpenPulse

struct AntigravityAccountServiceTests {
    @Test func emailFromIDTokenReadsEmailClaim() throws {
        let payload = try JSONSerialization.data(withJSONObject: ["email": "x@y.com"])
        let payloadBase64URL = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let fakeJWT = "header.\(payloadBase64URL).sig"

        let email = try AntigravityAccountService.email(fromIDToken: fakeJWT)
        #expect(email == "x@y.com")
    }

    @Test func keychainKeyFormatsEmail() {
        #expect(AntigravityAccountService.keychainKey(email: "x@y.com") == "antigravity_refresh_x@y.com")
    }
}
