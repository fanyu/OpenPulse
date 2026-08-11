# Codex Independent Model Quotas Implementation Plan

> **For Codex:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task with tests first.

**Goal:** Keep the normal Codex quota and GPT-5.3-Codex-Spark quota independent, select the newest JSONL observation by event timestamp, persist last-known observations, and show Spark as its own menu-bar row without changing smart-switch behavior.

**Architecture:** Extend the existing Codable `CodexRateLimits` payload with observation metadata and named additional limits so the existing account store supplies persistence without a second cache. The parser aggregates candidates by normalized `limit_id`; API data maps into the same structure; merge logic selects each identity independently by `observedAt`. Existing general-quota consumers remain compatible and only the menu bar renders named limits.

**Tech Stack:** Swift 6.2, SwiftUI, Swift Testing, Foundation JSONL decoding, existing Codable account store.

---

### Task 1: Parse quota identities by event time and classify windows strictly

**Files:**
- Modify: `OpenPulse/Data/Parsers/CodexParser.swift`
- Modify: `OpenPulseTests/CodexLocalQuotaFreshnessTests.swift`

**Step 1: Write failing tests**

Add fixtures proving:

- a newer Spark event does not hide the newest general event;
- candidates for each `limit_id` are selected by the JSONL event timestamp, not file modification date;
- an event without `limit_id` remains the legacy general quota;
- a 10,080-minute-only window yields `fiveHourWindow == nil` and a weekly window;
- the parsed named limit keeps its real observation time and display name.

**Step 2: Run the focused tests and confirm RED**

Run:

```bash
xcodebuild -project OpenPulse.xcodeproj -scheme OpenPulseTests -destination 'platform=macOS' -derivedDataPath build/DerivedData-CodexQuota -only-testing:OpenPulseTests/CodexLocalQuotaFreshnessTests test
```

Expected: failures for missing per-identity aggregation, timestamp ordering, and strict duration selection.

After Xcode teardown, check that no `xcodebuild`/`xctest` process is active, then inspect `/Users/fanyu/Library/Developer/XCTestDevices`; clean only if it exceeds the repository thresholds.

**Step 3: Implement the minimum parser/model changes**

- Decode the top-level event `timestamp`, including fractional ISO-8601 seconds.
- Introduce a Codable, Sendable named-limit value carrying `id`, optional name, windows, and `observedAt`.
- Add optional `observedAt` and named additional limits to `CodexRateLimits`; keep defaults so version-1 account JSON decodes unchanged.
- Scan eligible JSONL files and retain the newest candidate independently for general and each normalized non-general ID. Compare event timestamp first, then source mtime, then line order.
- Keep source mtime only as the observation fallback for legacy events without timestamps.
- Preserve `LocalRateLimitSnapshot.limits` as the general-compatible entry point.
- Replace nearest-window matching with exact known durations: 18,000 seconds for 5 hours and 604,800 seconds for 7 days.

**Step 4: Run the focused tests and confirm GREEN**

Use the same focused command and lifecycle check from Step 2.

**Step 5: Commit**

```bash
git add OpenPulse/Data/Parsers/CodexParser.swift OpenPulseTests/CodexLocalQuotaFreshnessTests.swift
git commit -m "fix: parse Codex quotas by identity and event time"
```

### Task 2: Merge JSONL and API observations without erasing last-known data

**Files:**
- Modify: `OpenPulse/Data/Services/CodexAccountService.swift`
- Modify: `OpenPulse/Data/Services/DataSyncService.swift`
- Modify: `OpenPulseTests/CodexLocalQuotaFreshnessTests.swift`

**Step 1: Write failing merge tests**

Cover these rules with pure model tests:

- a newer general observation replaces only general windows;
- a newer Spark observation replaces only Spark;
- API data that contains only `additional_rate_limits` does not erase stored general JSONL data;
- an older incoming observation cannot overwrite newer persisted data;
- a failed refresh cannot fabricate a new quota observation time.

**Step 2: Run the focused tests and confirm RED**

Use the focused command from Task 1 and perform the required XCTest artifact check.

**Step 3: Implement identity-aware merge and persistence**

- Add a small `CodexRateLimits` merge operation that chooses general and each named identity independently by `observedAt` while preserving reset credits.
- Map `/wham/usage` general data and `additional_rate_limits` into the same model without folding windows together.
- Merge successful API responses into `lastUsage` instead of replacing it wholesale.
- Merge local JSONL observations into the current account; do not create a synthetic Spark account or `QuotaRecord`.
- Stop using the five-minute file-mtime gate as data lifetime. Keep the single-account ownership guard for general local quota and retain last-known values indefinitely.
- Keep Spark excluded from smart-switch scoring, notifications, and account cleanup by leaving those consumers on the general windows only.

**Step 4: Run focused tests and confirm GREEN**

Use the focused command and lifecycle check from Task 1.

**Step 5: Commit**

```bash
git add OpenPulse/Data/Services/CodexAccountService.swift OpenPulse/Data/Services/DataSyncService.swift OpenPulseTests/CodexLocalQuotaFreshnessTests.swift
git commit -m "fix: merge independent Codex quota observations"
```

### Task 3: Render Spark as a separate menu-bar quota row

**Files:**
- Modify: `OpenPulse/Views/MenuBar/MenuBarView.swift`
- Modify: `OpenPulse/Resources/Localizable.xcstrings` only if a new localized phrase is required
- Modify: `OpenPulseTests/CodexLocalQuotaFreshnessTests.swift`

**Step 1: Write failing presentation tests**

Add pure helper tests proving that:

- Spark is absent when no named observation exists;
- `GPT-5.3-Codex-Spark` is presented as `Spark`;
- a weekly-only Spark observation produces one weekly panel, never a placeholder 5-hour panel;
- the footer uses the observation timestamp to produce a relative `更新于 … 前` status.

**Step 2: Run the focused tests and confirm RED**

Use the focused command and lifecycle check from Task 1.

**Step 3: Implement the minimal menu-bar UI**

- Factor a small internal presentation helper that returns only real windows.
- Keep the existing general row, omitting panels whose known duration is absent.
- Add one compact named row per detected additional limit; for the requested identity label it `Spark`.
- Use `observedAt` for a last-updated footer. Do not use account `updatedAt` or API fetch time.
- Apply the same rendering to the single-account and current multi-account cards; leave the main Quota window unchanged.

**Step 4: Run focused tests and confirm GREEN**

Use the focused command and lifecycle check from Task 1.

**Step 5: Commit**

```bash
git add OpenPulse/Views/MenuBar/MenuBarView.swift OpenPulse/Resources/Localizable.xcstrings OpenPulseTests/CodexLocalQuotaFreshnessTests.swift
git commit -m "feat: show Spark quota separately in menu bar"
```

### Task 4: Integration verification and regression review

**Files:**
- Verify: all files changed in Tasks 1-3
- Verify: existing user Router changes remain intact

**Step 1: Run the focused suite**

Run the focused command from Task 1 and perform the lifecycle check.

**Step 2: Run all tests**

```bash
xcodebuild -project OpenPulse.xcodeproj -scheme OpenPulseTests -destination 'platform=macOS' -derivedDataPath build/DerivedData-CodexQuota test
```

Perform the required post-test artifact check without altering the test exit status.

**Step 3: Build the app**

```bash
xcodebuild -project OpenPulse.xcodeproj -scheme OpenPulse -configuration Debug -destination 'platform=macOS' -derivedDataPath build/DerivedData-CodexQuota build
```

**Step 4: Validate against live JSONL read-only data**

Confirm that the current local data resolves general `codex` separately from `codex_bengalfox`, that Spark remains weekly-only when its only window is 10,080 minutes, and that no credentials or JSONL files were modified.

**Step 5: Review the final diff**

Check `git diff` and `git status` to prove that pre-existing Router/provider edits were preserved. Run a separate code-review pass focused on persistence compatibility, timestamp selection, strict concurrency, and downstream general-quota behavior. Leave final OpenPulse/Codex app restart to the user.
