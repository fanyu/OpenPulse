# Design Spec: Unified Native Card Surface Design System

**Date:** 2026-07-29  
**Status:** Approved  
**Target:** OpenPulse macOS App (All Content Views)

---

## 1. Executive Summary

To match the clean, readable, high-contrast card styling of `QuotaView` (`DetailCardContainer`), all content cards and section wrappers across the main window views (`TrendsView`, `SessionHistoryView`, `ProviderView`, `MenuBarSettingsView`, `SettingsView`, `CompareView`) will be unified to use the native macOS card surface pattern.

---

## 2. Standardized Card Surface Specification

Every content container card will use the following view modifiers:

```swift
.background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: cornerRadius))
.shadow(color: Color.black.opacity(0.03), radius: 8, y: 4)
.overlay(
    RoundedRectangle(cornerRadius: cornerRadius)
        .stroke(Color.primary.opacity(0.05), lineWidth: 1)
)
```

### Components & Views Affected:
1. `CommonUI.swift` (`StatCard`)
2. `SettingsView.swift` (`SettingsCard`)
3. `TrendsView.swift` (Charts, Bento Grid, Distribution, Activity, Cost sections)
4. `SessionHistoryView.swift` (Deep Analysis Header container)
5. `ProviderView.swift` (Provider card containers)
6. `CompareView.swift` (Charts and Heatmap containers)

---

## 3. Verification Plan

1. Build with `xcodebuild -project OpenPulse.xcodeproj -scheme OpenPulse -configuration Debug build`.
2. Run unit tests `xcodebuild -project OpenPulse.xcodeproj -scheme OpenPulse -destination 'platform=macOS' test`.
3. Verify visual consistency across light and dark macOS system appearances.
