# Codex General Quota Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent model-specific Codex quotas from overriding the general Codex quota, then release OpenPulse 1.0.19 (20) with a verified DMG asset.

**Architecture:** Preserve quota identity while decoding local Codex JSONL events and filter at the parser boundary, so every existing downstream consumer continues to receive only the general quota. Keep legacy no-ID events eligible, retain the existing API and freshness behavior, then use the repository's XcodeGen, xcodebuild, and GitHub Releases workflow for delivery.

**Tech Stack:** Swift 6.2, Swift Testing, XcodeGen, Xcode/xcodebuild, hdiutil, Git, GitHub CLI.

## Global Constraints

- The general local quota is identified by `limit_id = "codex"`.
- A nonempty different ID, including `codex_bengalfox`, must not enter the general quota synchronization path.
- A legacy local quota without `limit_id` remains eligible.
- API quota fetching, account switching, persistence schema, and menu-bar layout remain unchanged.
- Release version is `1.0.19` and build is `20`.
- Distribution remains a signed DMG through GitHub Releases, matching the repository's current Gatekeeper guidance.

---

### Task 1: Select only the general Codex quota

**Files:**
- Modify: `OpenPulseTests/CodexLocalQuotaFreshnessTests.swift`
- Modify: `OpenPulse/Data/Parsers/CodexParser.swift:292-367`

**Interfaces:**
- Consumes: `event_msg` / `token_count` JSONL events whose `rate_limits` object may contain `limit_id` and `limit_name`.
- Produces: `CodexRateLimits.isGeneralCodexLimit: Bool`; `parseLatestRateLimitsSnapshot()` returns the newest eligible general or legacy quota.

- [x] **Step 1: Write the failing parser regression tests**

Add these tests and fixture helper inside `CodexLocalQuotaFreshnessTests`:

```swift
@Test
func modelSpecificQuotaDoesNotOverrideGeneralQuota() async throws {
    let fileManager = FileManager.default
    let codexDir = fileManager.temporaryDirectory
        .appending(path: "OpenPulse-CodexQuota-\(UUID().uuidString)")
    defer { try? fileManager.removeItem(at: codexDir) }

    let sessionsDir = codexDir.appending(path: "sessions")
    try fileManager.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

    let generalURL = sessionsDir.appending(path: "general.jsonl")
    let sparkURL = sessionsDir.appending(path: "spark.jsonl")
    try writeQuotaEvent(limitID: "codex", usedPercent: 34, to: generalURL)
    try writeQuotaEvent(limitID: "codex_bengalfox", usedPercent: 0, to: sparkURL)

    let now = Date()
    try fileManager.setAttributes([.modificationDate: now.addingTimeInterval(-1)], ofItemAtPath: generalURL.path)
    try fileManager.setAttributes([.modificationDate: now], ofItemAtPath: sparkURL.path)

    let snapshot = await CodexParser(codexDir: codexDir).parseLatestRateLimitsSnapshot()

    #expect(snapshot?.limits.primary?.usedPercent == 34)
}

@Test
func legacyQuotaWithoutLimitIDRemainsEligible() async throws {
    let fileManager = FileManager.default
    let codexDir = fileManager.temporaryDirectory
        .appending(path: "OpenPulse-CodexLegacyQuota-\(UUID().uuidString)")
    defer { try? fileManager.removeItem(at: codexDir) }

    let sessionsDir = codexDir.appending(path: "sessions")
    try fileManager.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

    let legacyURL = sessionsDir.appending(path: "legacy.jsonl")
    try writeQuotaEvent(limitID: nil, usedPercent: 12, to: legacyURL)

    let snapshot = await CodexParser(codexDir: codexDir).parseLatestRateLimitsSnapshot()

    #expect(snapshot?.limits.primary?.usedPercent == 12)
}

private func writeQuotaEvent(limitID: String?, usedPercent: Double, to url: URL) throws {
    var rateLimits: [String: Any] = [
        "primary": [
            "used_percent": usedPercent,
            "window_minutes": 10_080,
            "resets_at": Date().addingTimeInterval(7 * 24 * 60 * 60).timeIntervalSince1970,
        ],
        "plan_type": "prolite",
    ]
    if let limitID {
        rateLimits["limit_id"] = limitID
    }

    let event: [String: Any] = [
        "type": "event_msg",
        "payload": [
            "type": "token_count",
            "rate_limits": rateLimits,
        ],
    ]
    let data = try JSONSerialization.data(withJSONObject: event)
    try data.write(to: url)
}
```

- [x] **Step 2: Run the suite and verify the regression test fails**

Run:

```bash
xcodebuild -project OpenPulse.xcodeproj \
  -scheme OpenPulseTests \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData-CodexQuota \
  -only-testing:OpenPulseTests/CodexLocalQuotaFreshnessTests \
  test
```

Expected: the suite executes three tests; `modelSpecificQuotaDoesNotOverrideGeneralQuota` fails because the current parser returns `0.0` from the newer Spark file instead of `34.0`.

- [x] **Step 3: Decode quota identity and filter at the parser boundary**

Extend `CodexRateLimits` with identity, initialization, and eligibility:

```swift
struct CodexRateLimits: Codable, Sendable {
    let primary: CodexWindow?
    let secondary: CodexWindow?
    let credits: CodexCredits?
    let resetCredits: CodexResetCredits?
    let planType: String?
    let limitID: String?
    let limitName: String?

    enum CodingKeys: String, CodingKey {
        case primary, secondary, credits
        case resetCredits = "rate_limit_reset_credits"
        case planType = "plan_type"
        case limitID = "limit_id"
        case limitName = "limit_name"
    }

    init(
        primary: CodexWindow?,
        secondary: CodexWindow?,
        credits: CodexCredits?,
        resetCredits: CodexResetCredits?,
        planType: String?,
        limitID: String? = nil,
        limitName: String? = nil
    ) {
        self.primary = primary
        self.secondary = secondary
        self.credits = credits
        self.resetCredits = resetCredits
        self.planType = planType
        self.limitID = limitID
        self.limitName = limitName
    }

    var isGeneralCodexLimit: Bool {
        guard let limitID else { return true }
        let normalized = limitID.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty || normalized.caseInsensitiveCompare("codex") == .orderedSame
    }
}
```

In `replacingResetCredits`, pass `limitID` and `limitName` into the new initializer so identity survives the merge. In `parseRateLimitsFromFile`, require eligibility before returning:

```swift
let limits = payload.rateLimits,
limits.isGeneralCodexLimit else { continue }
```

- [x] **Step 4: Run focused and full tests**

Run:

```bash
xcodebuild -project OpenPulse.xcodeproj \
  -scheme OpenPulseTests \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData-CodexQuota \
  -only-testing:OpenPulseTests/CodexLocalQuotaFreshnessTests \
  test

xcodebuild -project OpenPulse.xcodeproj \
  -scheme OpenPulseTests \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData-AllTests \
  test
```

Expected: the focused suite reports three passing tests with a nonzero count; the full test target exits successfully with zero failures.

- [x] **Step 5: Commit the tested fix**

```bash
git add OpenPulse/Data/Parsers/CodexParser.swift \
  OpenPulseTests/CodexLocalQuotaFreshnessTests.swift \
  docs/superpowers/plans/2026-08-09-codex-general-quota-selection.md
git commit -m "fix(codex): ignore model-specific local quotas"
```

### Task 2: Version, package, and publish OpenPulse 1.0.19

**Files:**
- Modify: `project.yml:109-110`
- Regenerate: `OpenPulse/Info.plist`
- Regenerate if XcodeGen changes it: `OpenPulse.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: Task 1's tested local quota selection.
- Produces: signed `OpenPulse.app`, `build/OpenPulse-1.0.19.dmg`, and a verified release commit ready for final review and publication.

- [ ] **Step 1: Bump the XcodeGen source version**

Set:

```yaml
CFBundleVersion: "20"
CFBundleShortVersionString: "1.0.19"
```

- [ ] **Step 2: Regenerate, retest, and build Release**

Run:

```bash
xcodegen generate

xcodebuild -project OpenPulse.xcodeproj \
  -scheme OpenPulseTests \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData-ReleaseTests \
  test

xcodebuild -project OpenPulse.xcodeproj \
  -scheme OpenPulse \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData-Release \
  build
```

Expected: XcodeGen succeeds, the full test target has zero failures, and the Release build ends with `BUILD SUCCEEDED`.

- [ ] **Step 3: Verify the app and create the DMG**

Run:

```bash
release_app="build/DerivedData-Release/Build/Products/Release/OpenPulse.app"
release_stage=$(mktemp -d "${TMPDIR%/}/OpenPulse-1.0.19.XXXXXX")

test "$(defaults read "$release_app/Contents/Info" CFBundleShortVersionString)" = "1.0.19"
test "$(defaults read "$release_app/Contents/Info" CFBundleVersion)" = "20"
codesign --verify --deep --strict --verbose=2 "$release_app"

ditto "$release_app" "$release_stage/OpenPulse.app"
ln -s /Applications "$release_stage/Applications"
mkdir -p build
hdiutil create \
  -volname "OpenPulse" \
  -srcfolder "$release_stage" \
  -ov \
  -format UDZO \
  "build/OpenPulse-1.0.19.dmg"

hdiutil verify "build/OpenPulse-1.0.19.dmg"
shasum -a 256 "build/OpenPulse-1.0.19.dmg"
```

Expected: app version is `1.0.19 (20)`, code-sign verification succeeds, DMG verification succeeds, and SHA-256 is printed.

- [ ] **Step 4: Commit the verified release version**

Run:

```bash
git add project.yml OpenPulse/Info.plist OpenPulse.xcodeproj/project.pbxproj
git commit -m "release: v1.0.19"
```

Expected: the release commit contains only version/generated-project changes, and the verified DMG remains at `build/OpenPulse-1.0.19.dmg`.

## Post-review publication

Run these steps only after Task 1 review, Task 2 review, the final whole-branch review, and fresh release verification all pass.

- [ ] **Step 1: Tag and push the reviewed release commit**

```bash
git tag -a v1.0.19 -m "v1.0.19"
git push origin main
git push origin v1.0.19
```

Expected: `origin/main` and remote tag `v1.0.19` resolve to the reviewed release commit.

- [ ] **Step 2: Publish and read back the GitHub release**

Run:

```bash
gh release create v1.0.19 \
  "build/OpenPulse-1.0.19.dmg#OpenPulse 1.0.19 DMG" \
  --repo fanyu/OpenPulse \
  --title "OpenPulse v1.0.19" \
  --notes $'## Fixed\n\n- Keep the menu-bar Codex percentage on the general quota instead of allowing GPT-5.3-Codex-Spark\'s independent quota to overwrite it.'

gh release view v1.0.19 \
  --repo fanyu/OpenPulse \
  --json tagName,name,isDraft,isPrerelease,publishedAt,url,assets,targetCommitish
```

Expected: the release is public, not a draft or prerelease, and contains one uploaded `OpenPulse-1.0.19.dmg` asset whose size is nonzero.
