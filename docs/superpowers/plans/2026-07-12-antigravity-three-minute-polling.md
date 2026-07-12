# Antigravity Three-Minute Polling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Poll Antigravity quotas every 180 seconds and release OpenPulse 1.0.15 (16).

**Architecture:** Retain `DataSyncService`'s per-tool timer dictionary. Make the existing interval map internal for a focused Swift Testing assertion, then update only Antigravity's entry. Bump the XcodeGen source version and release the generated macOS application as a signed DMG.

**Tech Stack:** Swift 6.2, Swift Testing, XcodeGen, xcodebuild, GitHub Releases.

## Global Constraints

- Antigravity polling interval must be exactly 180 seconds.
- Claude Code, Codex, and Copilot polling intervals must remain unchanged.
- Preserve the pre-existing `OpenPulse.xcodeproj/xcshareddata/xcschemes/OpenPulse.xcscheme` local modification.
- Release version is `1.0.15` and build is `16`.

---

### Task 1: Configure and test the Antigravity poll interval

**Files:**
- Modify: `OpenPulse/Data/Services/DataSyncService.swift:73-79`
- Modify: `OpenPulseTests/AntigravityQuotaDecodingTests.swift`

**Interfaces:**
- Produces: `DataSyncService.defaultPollInterval`, an internal `[Tool: TimeInterval]` map used by `schedulePollTimer(for:)`.

- [ ] **Step 1: Write the failing test**

```swift
@Test @MainActor func antigravityPollsEveryThreeMinutes() {
    #expect(DataSyncService.defaultPollInterval[.antigravity] == 180)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -project OpenPulse.xcodeproj -scheme OpenPulseTests -destination 'platform=macOS' -only-testing:OpenPulseTests/AntigravityQuotaDecodingTests/antigravityPollsEveryThreeMinutes test`

Expected: FAIL because `defaultPollInterval` is private or does not equal `180`.

- [ ] **Step 3: Write the minimal implementation**

```swift
static let defaultPollInterval: [Tool: TimeInterval] = [
    .claudeCode: 300,
    .codex: 300,
    .antigravity: 180,
    .copilot: 3600,
]
```

- [ ] **Step 4: Run focused and full tests**

Run: `xcodebuild -project OpenPulse.xcodeproj -scheme OpenPulseTests -destination 'platform=macOS' test`

Expected: PASS.

### Task 2: Version, package, and publish OpenPulse 1.0.15

**Files:**
- Modify: `project.yml:109-110`
- Regenerate: `OpenPulse.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: Task 1's tested polling interval.
- Produces: a Release app and DMG tagged `v1.0.15`.

- [ ] **Step 1: Bump the XcodeGen source version**

```yaml
CFBundleVersion: "16"
CFBundleShortVersionString: "1.0.15"
```

- [ ] **Step 2: Regenerate and build**

Run: `xcodegen generate && xcodebuild -project OpenPulse.xcodeproj -scheme OpenPulse -configuration Release -derivedDataPath build/DerivedData build`

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Package and verify**

Run: package the built `OpenPulse.app` into `build/OpenPulse-1.0.15.dmg`, then run `codesign --verify --deep --strict --verbose=2` on the app and `hdiutil verify` on the DMG.

Expected: both verifications succeed.

- [ ] **Step 4: Commit and publish**

Run: commit the polling, test, version, generated project, and release-documentation changes; tag `v1.0.15`; push `main` and the tag; then create a GitHub release with `build/OpenPulse-1.0.15.dmg` attached.

Expected: GitHub release `v1.0.15` contains the DMG asset.
