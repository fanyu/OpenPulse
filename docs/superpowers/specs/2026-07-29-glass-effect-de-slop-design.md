# Design Spec: Glass Effect Reduction & De-Slop Refactoring

**Date:** 2026-07-29  
**Status:** Approved  
**Target:** OpenPulse macOS App Main Window Views

---

## 1. Executive Summary

Excessive use of `.glassEffect` across scrolling content cards, settings containers, and chart sections reduces text contrast, creates visual noise, and breaks Apple's principle that translucency should be reserved for floating chrome layers.

This spec defines a cleanup to strip unnecessary `.glassEffect` modifiers from main window views, replacing them with crisp, clean macOS native card surfaces (`Color.primary.opacity(0.03)` with a 1px border stroke `Color.primary.opacity(0.05)`). Glass effects will remain only on floating overlays such as the status bar popover (`MenuBarView`).

---

## 2. Changes by Component & View

### 2.1 `CommonUI.swift`
- `StatCard`: Set `isGlass: false` by default, using `Color.primary.opacity(0.03)` with a subtle border stroke.
- `SettingsCard`: Remove `.glassEffect`. Use `Color.primary.opacity(0.03)` with rounded corners (16px) and border stroke.

### 2.2 `TrendsView.swift`
- `WeeklyAreaChart` container: Remove `.glassEffect`, use subtle background fill & rounded border.
- Bento Grid `StatCard`: Disable glass mode (`isGlass: false`).
- Sections (Model distribution, Context analysis, Activity heatmaps, Cost analytics): Remove `.glassEffect` from card sections.

### 2.3 `SessionHistoryView.swift` & `LogView.swift`
- Deep analysis context header: Remove `.glassEffect`, use subtle background card fill.

### 2.4 `ProviderView.swift` & `CompareView.swift`
- Remove `.glassEffect` from main body containers.

### 2.5 Retained Glass Effects (Floating Only)
- `MenuBarView.swift` (Popover shell & floating tool identity cards).
- `ValueChip` (Small floating status pills).

---

## 3. Verification Plan

1. Compile with `xcodebuild -project OpenPulse.xcodeproj -scheme OpenPulse -configuration Debug build`.
2. Run unit tests `xcodebuild -project OpenPulse.xcodeproj -scheme OpenPulse -destination 'platform=macOS' test`.
3. Verify visual contrast and clean card borders across dark and light macOS system appearances.
