# Unified Native Card Surface Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Standardize all content cards across OpenPulse to use the Quota view card surface (`Color(NSColor.controlBackgroundColor)` + `.shadow(color: Color.black.opacity(0.03), radius: 8, y: 4)` + `.stroke(Color.primary.opacity(0.05), lineWidth: 1)`).

**Architecture:**
- Update `StatCard` in `CommonUI.swift` and `SettingsCard` in `SettingsView.swift`.
- Apply standardized card modifier pattern to `TrendsView`, `SessionHistoryView`, `ProviderView`, and `CompareView`.

**Tech Stack:** Swift 6.2, SwiftUI, XcodeGen (`xcodegen generate`), XCTest / `xcodebuild`.

## Global Constraints

- **Language/Framework**: Swift 6.2 strict concurrency (`SWIFT_STRICT_CONCURRENCY = complete`), SwiftUI, macOS 26.0 deployment target.
- **No external dependencies**: Native SwiftUI.

---

### Task 1: Update `CommonUI.swift` (`StatCard`) and `SettingsView.swift` (`SettingsCard`)

**Files:**
- Modify: `OpenPulse/Views/Components/CommonUI.swift`
- Modify: `OpenPulse/Views/Settings/SettingsView.swift`

- [ ] **Step 1: Update `StatCard` in `CommonUI.swift`**

```swift
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.black.opacity(0.03), radius: 8, y: 4)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
```

- [ ] **Step 2: Update `SettingsCard` in `SettingsView.swift`**

```swift
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.black.opacity(0.03), radius: 8, y: 4)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
```

- [ ] **Step 3: Commit Task 1**

```bash
git add OpenPulse/Views/Components/CommonUI.swift OpenPulse/Views/Settings/SettingsView.swift
git commit -m "refactor(ui): update StatCard and SettingsCard to use unified Quota card surface style"
```

---

### Task 2: Apply Unified Card Surface to `TrendsView`, `SessionHistoryView`, `ProviderView`, `CompareView`

**Files:**
- Modify: `OpenPulse/Views/Trends/TrendsView.swift`
- Modify: `OpenPulse/Views/History/SessionHistoryView.swift`
- Modify: `OpenPulse/Views/Providers/ProviderView.swift`
- Modify: `OpenPulse/Views/Compare/CompareView.swift`

- [ ] **Step 1: Update `TrendsView.swift` content cards**

Apply `Color(NSColor.controlBackgroundColor)` + `.shadow(color: Color.black.opacity(0.03), radius: 8, y: 4)` + `.stroke(Color.primary.opacity(0.05), lineWidth: 1)` to chart & section containers.

- [ ] **Step 2: Update `SessionHistoryView.swift`, `ProviderView.swift`, `CompareView.swift` content cards**

Apply the same card surface modifier.

- [ ] **Step 3: Commit Task 2**

```bash
git add OpenPulse/Views/Trends/TrendsView.swift OpenPulse/Views/History/SessionHistoryView.swift OpenPulse/Views/Providers/ProviderView.swift OpenPulse/Views/Compare/CompareView.swift
git commit -m "refactor(ui): apply unified native card surface across all main window views"
```

---

### Task 3: Build & Unit Test Verification

- [ ] **Step 1: Run `xcodebuild` test suite**

Run: `xcodebuild -project OpenPulse.xcodeproj -scheme OpenPulse -destination 'platform=macOS' test`
Expected: Build succeeds, 23/23 unit tests pass.
