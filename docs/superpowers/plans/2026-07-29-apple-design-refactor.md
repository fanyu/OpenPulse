# Apple Design System Refactoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor OpenPulse macOS app UI components and views to adhere to Apple Fluid Design principles, enhancing translucency depth, typography, spring motion feel, and layout consistency across all 8 tabs.

**Architecture:**
- Update `CommonUI.swift` to introduce standardized Apple-style design primitives (`GlassSurfaceCard`, `AppleStatCard`, `AppleFilterChip`).
- Refactor views (`TrendsView`, `QuotaView`, `SessionHistoryView`, `MenuBarSettingsView`, `ProviderComponents`, `ConfigsView`, `SettingsView`, `LogView`) using the refined primitives.
- Verify zero regression in concurrency, UI functionality, and unit test pass.

**Tech Stack:** Swift 6.2, SwiftUI, XcodeGen (`xcodegen generate`), XCTest / `xcodebuild`.

## Global Constraints

- **Language/Framework**: Swift 6.2 strict concurrency (`SWIFT_STRICT_CONCURRENCY = complete`), SwiftUI, macOS 26.0 deployment target.
- **XcodeGen**: Any newly added file under `OpenPulse/` requires running `xcodegen generate` to update `OpenPulse.xcodeproj`.
- **No external dependencies**: Rely on native SwiftUI and Apple macOS system APIs.

---

### Task 1: Refactor `CommonUI.swift` with Apple Design Primitives

**Files:**
- Modify: `OpenPulse/Views/Components/CommonUI.swift`

**Interfaces:**
- Consumes: SwiftUI View modifiers, glass effect
- Produces: Enhanced `StatCard`, `FilterChip`, `SectionHeader`, `ProminentActionButtonStyle`

- [ ] **Step 1: Update `CommonUI.swift` with subtle border overlays and hover springs**

In `OpenPulse/Views/Components/CommonUI.swift`, update `StatCard`, `FilterChip`, and button styles with:
1. Outer light border: `.overlay(RoundedRectangle(cornerRadius: ...).stroke(Color.primary.opacity(0.06), lineWidth: 1))`
2. Spring animations on selection/hover: `.animation(.spring(duration: 0.3, bounce: 0.15), value: ...)`
3. Monospaced digit numbers for metrics: `.font(.system(...).monospacedDigit())`

- [ ] **Step 2: Commit Task 1**

```bash
git add OpenPulse/Views/Components/CommonUI.swift
git commit -m "design(common): enhance CommonUI with Apple-style glass surfaces and spring feedback"
```

---

### Task 2: Polish Dashboard (`TrendsView`), Quota (`QuotaView`), and Activity (`SessionHistoryView`)

**Files:**
- Modify: `OpenPulse/Views/Trends/TrendsView.swift`
- Modify: `OpenPulse/Views/Quota/QuotaView.swift`
- Modify: `OpenPulse/Views/History/SessionHistoryView.swift`

**Interfaces:**
- Consumes: Updated `CommonUI.swift` components
- Produces: Polished main views with fluid typography, responsive greeting icons, and clean card spacing

- [ ] **Step 1: Enhance `TrendsView.swift` greeting & bento grid**

Add time-of-day SF Symbol (`sun.max.fill` / `sun.horizon.fill` / `moon.stars.fill`) to welcome header and polish bento grid cards with subtle scale feedback and monospaced digits.

- [ ] **Step 2: Enhance `QuotaView.swift` cards & progress bars**

Ensure progress bar fills animate with smooth spring curves (`.animation(.spring(duration: 0.4), value: fraction)`) and account cards display clear tier badges and countdowns.

- [ ] **Step 3: Enhance `SessionHistoryView.swift` activity list & search bar**

Refine search field with rounded borders, smooth focus animations, and clean task item checklists.

- [ ] **Step 4: Commit Task 2**

```bash
git add OpenPulse/Views/Trends/TrendsView.swift OpenPulse/Views/Quota/QuotaView.swift OpenPulse/Views/History/SessionHistoryView.swift
git commit -m "design(views): polish TrendsView, QuotaView, and SessionHistoryView to match Apple design"
```

---

### Task 3: Polish `MenuBarSettingsView`, `ProviderComponents`, `ConfigsView`, `SettingsView`, and `LogView`

**Files:**
- Modify: `OpenPulse/Views/MenuBar/MenuBarSettingsView.swift`
- Modify: `OpenPulse/Views/Providers/ProviderComponents.swift`
- Modify: `OpenPulse/Views/Configs/ConfigsView.swift`
- Modify: `OpenPulse/Views/Settings/SettingsView.swift`
- Modify: `OpenPulse/Views/Logs/LogView.swift`

**Interfaces:**
- Consumes: Shared design system
- Produces: Unified Apple-style settings, provider, config editor, and log views

- [ ] **Step 1: Polish `MenuBarSettingsView.swift` & `SettingsView.swift` cards**

Apply consistent 20px padding, glass backgrounds, and clean divider spacing across all setting sections.

- [ ] **Step 2: Polish `ConfigsView.swift` & `LogView.swift`**

Update code editor view and log viewer with clean monospaced font, subtle scroll gradients, and crisp filter chips.

- [ ] **Step 3: Commit Task 3**

```bash
git add OpenPulse/Views/MenuBar/MenuBarSettingsView.swift OpenPulse/Views/Providers/ProviderComponents.swift OpenPulse/Views/Configs/ConfigsView.swift OpenPulse/Views/Settings/SettingsView.swift OpenPulse/Views/Logs/LogView.swift
git commit -m "design(views): polish MenuBarSettingsView, ProviderComponents, ConfigsView, SettingsView, and LogView"
```

---

### Task 4: Full Build and Unit Test Verification

- [ ] **Step 1: Run `xcodebuild` test suite**

Run: `xcodebuild -project OpenPulse.xcodeproj -scheme OpenPulse -destination 'platform=macOS' test`
Expected: Build succeeds, 23/23 unit tests pass.

- [ ] **Step 2: Verify git working tree clean**

Run: `git status`
Expected: Clean working tree.
