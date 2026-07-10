# Antigravity Consumer Pro Badge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Recognize consumer Google AI Pro entitlement from Antigravity's complete dual-window quota response.

**Architecture:** Add account-level computed badge properties that combine the reported GCP tier with quota group structure. Pass the account to the existing shared badge view so all surfaces use the same classification.

**Tech Stack:** Swift 6.2, SwiftUI, Swift Testing, Xcode 26.

## Global Constraints

- Treat a free-tier account as consumer Pro only when both `gemini` and `3p` groups contain non-nil `fiveHour` and `weekly` windows.
- Preserve existing paid behavior for every non-`free-tier` tier.
- Preserve `Free` for missing or incomplete quota data.
- Do not touch unrelated pet animation work already present in the worktree.

---

### Task 1: Account-level entitlement classification

**Files:**
- Modify: `OpenPulseTests/AntigravityQuotaDecodingTests.swift`
- Modify: `OpenPulse/Data/Parsers/AntigravityParser.swift`
- Modify: `OpenPulse/Views/Components/AGQuotaViews.swift`
- Modify: `OpenPulse/Views/MenuBar/MenuBarView.swift`

**Interfaces:**
- Consumes: `AGAccountQuota.tier`, `AGAccountQuota.groups`
- Produces: `AGAccountQuota.isPaid`, `AGAccountQuota.badgeLabel`

- [ ] **Step 1: Write failing classification tests**

Add fixtures asserting that a free-tier account with complete `gemini` and `3p` dual windows is paid and labeled `Google AI Pro`, while weekly-only or incomplete accounts remain `Free`; assert non-free tiers remain paid.

- [ ] **Step 2: Verify the tests fail for the missing account-level properties**

Run: `xcodebuild test -project OpenPulse.xcodeproj -scheme OpenPulse -destination 'platform=macOS' -only-testing:OpenPulseTests/AntigravityQuotaDecodingTests`

Expected: FAIL because `AGAccountQuota` has no `isPaid` or `badgeLabel` member.

- [ ] **Step 3: Implement the minimal classification**

Add an `AGAccountQuota` helper that requires both expected groups and both windows, then expose `isPaid` and `badgeLabel`. Change `AGTierBadge` to accept `AGAccountQuota`, and update both call sites.

- [ ] **Step 4: Verify focused and full behavior**

Run the focused test command again, then:

`xcodebuild test -project OpenPulse.xcodeproj -scheme OpenPulse -destination 'platform=macOS'`

`xcodebuild -project OpenPulse.xcodeproj -scheme OpenPulse -configuration Debug build`

Expected: all commands exit 0.
