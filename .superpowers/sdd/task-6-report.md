# Task 6 Report: Extract shared OAuth loopback helpers

## Summary
Pure refactor — moved the loopback-OAuth toolkit out of `CodexAccountService.swift` into a new file `OpenPulse/Data/Services/OAuthLoopbackSupport.swift`, so it can be reused by the upcoming Antigravity login (Task 8). No logic, signatures, or behavior changed.

## Types moved (verbatim, `private` → file-internal `internal`)
- `final class SimpleHTTPServer: @unchecked Sendable` (init, `start()`, `stop()`)
- `final class OAuthCallbackBox<Value: Sendable>: @unchecked Sendable` (`wait(timeoutSeconds:)`, `succeed(_:)`, `fail(_:)`)
- `struct HTTPRequest` (path, queryItems)
- `struct HTTPResponse` (statusCode, contentType, body, `.text(...)`, `.html(...)`)
- Free functions `parseRequest(from:)` and `renderResponse(_:)` (required by `SimpleHTTPServer`'s connection handler)
- Two crypto statics wrapped in new `enum OAuthPKCE`:
  - `static func randomBase64URL(byteCount: Int) -> String`
  - `static func sha256Base64URL(_ value: String) -> String`

New file imports: `Foundation`, `CryptoKit` (for `SHA256`), `Network` (for `NWListener`/`NWEndpoint.Port`).

## Call sites updated in `CodexAccountService.swift`
Lines ~715-717 (inside the OAuth login flow):
```swift
let verifier = OAuthPKCE.randomBase64URL(byteCount: 32)
let challenge = OAuthPKCE.sha256Base64URL(verifier)
let state = OAuthPKCE.randomBase64URL(byteCount: 32)
```
(previously `Self.randomBase64URL(...)` / `Self.sha256Base64URL(...)`)

All other references (`OAuthCallbackBox<TokenExchangeResponse>()`, `SimpleHTTPServer(...)`) in `CodexAccountService.swift` were left untouched — they now resolve to the file-internal types in the new file since both files are in the same target.

## Build
1. `xcodegen generate` — regenerated `OpenPulse.xcodeproj/project.pbxproj`; `project.yml` was NOT modified (confirmed via `git status --short project.yml` producing no output), so it was not staged.
2. `xcodebuild build -project OpenPulse.xcodeproj -scheme OpenPulse -configuration Debug -destination 'platform=macOS'` → **BUILD SUCCEEDED**.

## Commit
```
1d2dcdc refactor: extract shared OAuth loopback helpers
 3 files changed, 169 insertions(+), 164 deletions(-)
 create mode 100644 OpenPulse/Data/Services/OAuthLoopbackSupport.swift
```
Staged/committed exactly: `OpenPulse/Data/Services/OAuthLoopbackSupport.swift`, `OpenPulse/Data/Services/CodexAccountService.swift`, `OpenPulse.xcodeproj/project.pbxproj`. No iPhone files or `project.yml` touched.

## Concerns
None. Pure move, verified by successful build of the Codex flow which is the regression gate for this task.

Note: this file previously contained an unrelated report (iPhone scheme/provisioning work) from a different task numbering; it has been overwritten with this task's report.
