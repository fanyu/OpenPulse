# Exhausted Quota Countdown Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show an animated reset countdown above an exhausted 5-hour quota pet on iPhone.

**Architecture:** Keep the shared snapshot payload unchanged. Add a pure presentation helper that determines whether a session has an active future reset countdown, then pass only its derived values to a small SwiftUI leaf view driven by `TimelineView`.

**Tech Stack:** Swift 6.2, Swift Testing, SwiftUI, iOS 26.

## Global Constraints

- Activate only for an available 5-hour quota with zero remaining and a future `resetAt`.
- Do not alter Weekly display, CloudKit records, or synchronization behavior.
- Update the countdown once per second and preserve the current card layout.

---

### Task 1: Derive the reset countdown presentation

**Files:**
- Modify: `OpenPulseiPhone/Models/DeskPetPresentation.swift`
- Test: `OpenPulseiPhoneTests/DeskPetPresentationTests.swift`

**Interfaces:**
- Produces: `DeskUsagePresentation.resetCountdown(at:) -> DeskResetCountdownPresentation?`.
- Consumes: `DeskUsagePresentation.isAvailable`, `remaining`, and `resetAt`.
- Extends: `DeskUsagePresentation` with `remaining: Int?` and `resetAt: Date?` populated from the source quota window.

- [ ] **Step 1: Write the failing test**

```swift
let usage = DeskUsagePresentation(
    label: "5h limit",
    percentText: "0%",
    resetText: "Today 02:02",
    fraction: 0,
    isAvailable: true,
    remaining: 0,
    resetAt: Date(timeIntervalSince1970: 4_723)
)
let countdown = usage.resetCountdown(at: Date(timeIntervalSince1970: 1_000))
#expect(countdown?.text == "01:02:03")
```

- [ ] **Step 2: Run the iPhone test scheme and verify the test fails**

Run: `xcodebuild test -project OpenPulse.xcodeproj -scheme OpenPulseiPhoneTests -destination 'platform=iOS Simulator,name=iPhone 17'`

Expected: compilation failure because `resetCountdown(at:)` does not exist.

- [ ] **Step 3: Add the minimal pure presentation helper**

```swift
struct DeskResetCountdownPresentation: Equatable {
    let text: String
}

func resetCountdown(at now: Date) -> DeskResetCountdownPresentation? {
    guard isAvailable, remaining == 0, let resetAt, resetAt > now else { return nil }
    return .init(text: Self.countdownText(until: resetAt, now: now))
}
```

- [ ] **Step 4: Run the iPhone test scheme and verify it passes**

Expected: the new future-reset test and all existing iPhone tests pass.

### Task 2: Render the animated exhausted bubble

**Files:**
- Modify: `OpenPulseiPhone/Views/ToolCockpitPanel.swift`

**Interfaces:**
- Consumes: `DeskUsagePresentation.resetCountdown(at:)`.
- Produces: an `ExhaustedResetCountdownBubble` view with narrow `text` and `accent` inputs.

- [ ] **Step 1: Replace the exhausted percentage bubble path with the countdown leaf view**

```swift
if let countdown = presentation.session.resetCountdown(at: timeline.date) {
    ExhaustedResetCountdownBubble(text: countdown.text, accent: accent)
} else {
    StandardQuotaBubble(percentText: presentation.session.percentText, label: bubbleLabel, accent: accent)
}
```

- [ ] **Step 2: Animate only the exhausted leaf**

```swift
.scaleEffect(1 + sin(phase * 2) * 0.025)
.offset(y: cos(phase * 1.5) * 2)
.shadow(color: accent.opacity(0.38), radius: 16, y: 6)
```

- [ ] **Step 3: Run the iPhone test scheme**

Expected: `** TEST SUCCEEDED **`.

### Task 3: Verify Mac-side shared code remains valid

**Files:**
- No additional source files.

- [ ] **Step 1: Run the macOS test scheme**

Run: `xcodebuild test -project OpenPulse.xcodeproj -scheme OpenPulseTests -destination 'platform=macOS'`

Expected: `** TEST SUCCEEDED **`.
