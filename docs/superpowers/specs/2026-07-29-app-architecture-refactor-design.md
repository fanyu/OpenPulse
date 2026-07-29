# Design Spec: OpenPulse App Navigation & Architecture Refactoring

**Date:** 2026-07-29  
**Status:** Approved  
**Target:** OpenPulse (macOS App)

---

## 1. Executive Summary

This specification outlines a structural cleanup and consolidation of OpenPulse's sidebar navigation, settings organization, and activity views:
1. Introduce a dedicated **「菜单栏」 (MenuBar)** sidebar Tab for all status-bar, popover layout, shortcut, and display mode configurations.
2. Reorder sidebar tabs and update SF Symbol icons for maximum clarity.
3. Streamline **Activity (`SessionHistoryView`)** to restrict session tracking and deep analysis exclusively to local coding tools: **Codex** and **Claude Code**.
4. Remove duplicated MenuBar toggle settings from **Providers (`ProviderComponents.swift`)** and **Settings (`SettingsView.swift`)**, consolidating them into the new `MenuBarSettingsView`.

---

## 2. Sidebar Tabs & Icons Order

The `AppTab` enum in `AppStore.swift` will be updated to 8 cases in the following order:

| # | Tab Case | Display Title | SF Symbol Icon | Purpose |
|---|---|---|---|---|
| 1 | `.trends` | 总览 | `chart.line.uptrend.xyaxis` | Token analytics dashboard |
| 2 | `.quota` | 配额 | `chart.pie.fill` | Real-time quota snapshots |
| 3 | `.activity` | 活动 | `terminal.fill` | Session history (**Codex & Claude Code only**) |
| 4 | `.menuBar` | 菜单栏 | `menubar.dock.rectangle` | Status bar, popover controls, hotkey & tool order |
| 5 | `.providers` | 接入 | `cable.connector` | Auth, API endpoints & accounts (no UI display toggles) |
| 6 | `.configs` | 配置 | `doc.badge.gearshape.fill` | Prompt/config files (`CLAUDE.md`, `settings.json`) |
| 7 | `.settings` | 设置 | `gearshape.fill` | General app settings (Launch at login, Language, Notifications, Data cache) |
| 8 | `.logs` | 日志 | `scroll` | Diagnostics and sync logs |

---

## 3. Subsystem Changes

### 3.1 `AppTab` & `MainWindowView`
- Add `.menuBar` to `AppTab`.
- Update `MainWindowView` detail switcher:
  ```swift
  case .trends:    TrendsView()
  case .quota:     QuotaView()
  case .activity:  SessionHistoryView()
  case .menuBar:   MenuBarSettingsView()
  case .providers: ProviderView()
  case .configs:   ConfigsView()
  case .settings:  SettingsView()
  case .logs:      LogView()
  ```

### 3.2 Activity (`SessionHistoryView`) Refactoring
- **Filter Pills**: Restrict tool pills in `filterBar` to `[.codex, .claudeCode]`.
- **Query Filter**: `sessions.filter { session in (session.tool == .codex || session.tool == .claudeCode) && ... }`.
- **Deep Analysis**: `toolDeepAnalysisHeader` supports only `.codex` and `.claudeCode`. Remove `AGAnalysisView` and `CopilotAnalysisView` invocations from `SessionHistoryView.swift`.

### 3.3 Dedicated `MenuBarSettingsView`
Create `OpenPulse/Views/MenuBar/MenuBarSettingsView.swift` containing:
1. **状态栏与展示样式**: `compact` vs `classic` mode.
2. **菜单栏标题额度**: Agent 5H/7D display selection.
3. **Antigravity 菜单栏展示**: Pro quota aggregation toggle (`accounts` vs `aggregate`).
4. **工具排序与显示**: Draggable reordering list and visibility toggles.
5. **全局快捷键**: Hotkey recording for MenuBar popover.

### 3.4 Providers (`ProviderComponents.swift`) Cleanup
- Remove display toggle cards from `AntigravityProviderContent` (keeps auth/account management focused).

### 3.5 Settings (`SettingsView.swift`) Cleanup
- Remove the `SettingsCard(title: "菜单栏显示", icon: "menubar.rectangle")` section since its controls now live in `MenuBarSettingsView`.

---

## 4. Verification Plan

1. **Unit & Build Tests**:
   - `xcodegen generate` to register `MenuBarSettingsView.swift`.
   - Run `xcodebuild -project OpenPulse.xcodeproj -scheme OpenPulse -destination 'platform=macOS' test` to verify zero compile errors and all unit tests pass.
2. **Visual/Functional Check**:
   - Verify sidebar exhibits 8 tabs with updated icons.
   - Verify Activity tab only shows Codex & Claude Code sessions and pills.
   - Verify MenuBar tab controls popover settings, display mode, hotkey, and tool ordering.
