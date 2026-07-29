# Glass Effect Reduction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove unnecessary `.glassEffect` calls from main window views and cards, replacing them with crisp macOS card containers (`Color.primary.opacity(0.03)` with a 1px border stroke).

**Architecture:**
- Update `CommonUI.swift` (`StatCard` & `SettingsCard`) to default to clean flat cards.
- Remove `.glassEffect` from `TrendsView`, `SessionHistoryView`, `ProviderView`, and `CompareView`.
- Retain `.glassEffect` only in `MenuBarView` popover components.

**Tech Stack:** Swift 6.2, SwiftUI, XcodeGen (`xcodegen generate`), XCTest / `xcodebuild`.

## Global Constraints

- **Language/Framework**: Swift 6.2 strict concurrency (`SWIFT_STRICT_CONCURRENCY = complete`), SwiftUI, macOS 26.0 deployment target.
- **No external dependencies**: Rely on native SwiftUI.

---

### Task 1: Update `CommonUI.swift` & `SettingsView.swift` Card Primitives

**Files:**
- Modify: `OpenPulse/Views/Components/CommonUI.swift`
- Modify: `OpenPulse/Views/Settings/SettingsView.swift`

- [ ] **Step 1: Update `StatCard` and `SettingsCard` in `CommonUI.swift` and `SettingsView.swift`**

1. In `CommonUI.swift`: change `StatCard` default `isGlass: Bool = false`.
2. In `SettingsView.swift`: update `SettingsCard` to remove `.glassEffect` and use `Color.primary.opacity(0.03)` with `.overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.05), lineWidth: 1))`.

- [ ] **Step 2: Commit Task 1**

```bash
git add OpenPulse/Views/Components/CommonUI.swift OpenPulse/Views/Settings/SettingsView.swift
git commit -m "refactor(ui): update StatCard and SettingsCard to use clean solid-opacity backgrounds"
```

---

### Task 2: Strip Overused Glass Effects from `TrendsView.swift`, `SessionHistoryView.swift`, `ProviderView.swift`, `CompareView.swift`

**Files:**
- Modify: `OpenPulse/Views/Trends/TrendsView.swift`
- Modify: `OpenPulse/Views/History/SessionHistoryView.swift`
- Modify: `OpenPulse/Views/Providers/ProviderView.swift`
- Modify: `OpenPulse/Views/Compare/CompareView.swift`

- [ ] **Step 1: Replace `.glassEffect` in `TrendsView.swift`**

Replace `.glassEffect(.regular, in: .rect(cornerRadius: ...))` on trend sections and chart wrappers with:
`.background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.05), lineWidth: 1))`

- [ ] **Step 2: Replace `.glassEffect` in `SessionHistoryView.swift` & `ProviderView.swift` & `CompareView.swift`**

Replace `.glassEffect` on deep analysis card, provider header card, and compare containers with clean background cards.

- [ ] **Step 3: Commit Task 2**

```bash
git add OpenPulse/Views/Trends/TrendsView.swift OpenPulse/Views/History/SessionHistoryView.swift OpenPulse/Views/Providers/ProviderView.swift OpenPulse/Views/Compare/CompareView.swift
git commit -m "refactor(ui): strip redundant glassEffect from main app content sections"
```

---

### Task 3: Build and Test Verification

- [ ] **Step 1: Run `xcodebuild` test suite**

Run: `xcodebuild -project OpenPulse.xcodeproj -scheme OpenPulse -destination 'platform=macOS' test`
Expected: Build succeeds, 23/23 unit tests pass.
