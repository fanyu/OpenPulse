# Design Spec: Apple Design System Refactoring for OpenPulse Main App

**Date:** 2026-07-29  
**Status:** Approved  
**Target:** OpenPulse macOS App (All Views)

---

## 1. Executive Summary & Design System Principles

This spec defines a comprehensive Apple-style visual and motion refactoring across all 8 main views of OpenPulse, adhering to WWDC *Designing Fluid Interfaces* and *Principles of Great Design*:

1. **Materials & Depth (Translucency & Light Catching)**:
   - Use unified `.glassEffect(.regular, in: .rect(cornerRadius: 16-20))` for surface cards.
   - Add a subtle top/border light stroke (`.overlay(RoundedRectangle(cornerRadius: ...).stroke(Color.primary.opacity(0.06), lineWidth: 1))`) to catch light on dark and light mode translucent materials.
2. **Typography & Hierarchy**:
   - Size-specific tracking and line-heights: Prominent headlines with tight tracking (`-0.02em`), clear weight separation, monospaced numbers for metrics (`.font(.system(...).monospacedDigit())`).
3. **Motion & Feedback**:
   - Apply interruptible spring animations (`.spring(duration: 0.35, bounce: 0.15)`) for view transitions, tab switching, and expansion toggles.
   - Pointer-down active scaling (`scaleEffect(0.98)`) and hover highlights on interactive cards and buttons.
4. **Consistency & Accessibility**:
   - Standardized status badges (Success: Green, Warning: Yellow, Critical: Red).
   - High-contrast text on blurred materials and full support for Dark and Light macOS system appearances.

---

## 2. Per-Page Design Specifications

### 2.1 Dashboard (`TrendsView`)
- **Header**: Greeting with time-of-day SF Symbol (`sun.max.fill` / `sun.horizon.fill` / `moon.stars.fill`), subtle token usage badge, and clean segmented time range picker (`7天 / 30天 / 90天`).
- **Bento Grid**: 4 metric cards (`StatCard`) featuring translucent surfaces, subtle hover scaling, monospaced numbers, and trend deltas.
- **Charts**: Token usage area chart & cost timeline chart with gradient fills, smooth axis formatting, and hover tooltips.

### 2.2 Quota View (`QuotaView`)
- **Tool Quota Grid**: Card grid displaying real-time 5-hour and weekly quota progress bars with spring fill animation (`QuotaProgressBar`).
- **Antigravity Account Cards**: Multi-account / Pro-aggregated cards with badge labels (`Google AI Pro` / `Free`), earliest reset time countdowns, and quick account refresh buttons.

### 2.3 Activity View (`SessionHistoryView`)
- **Streamlined Filter Bar**: Segmented chips for **全部**, **Codex**, **Claude Code** with smooth selection spring animations.
- **Session Rows**: Expandable `UnifiedSessionRow` cards with Git branch badges, project directory paths, token metrics, and expandable task item checklists.

### 2.4 Menu Bar Controls (`MenuBarSettingsView`)
- **Card Sections**:
  1. **快捷键**: Hotkey recording button with active recording state pulsing indicator.
  2. **状态栏样式**: Compact vs Classic mode segmented picker with visual preview description.
  3. **菜单栏标题额度**: Agent 5H/7D display toggle rows with tool logos.
  4. **Antigravity Pro 账号聚合**: Accounts vs Aggregate Pro toggle switch.
  5. **工具排序与显示**: Reorderable list with grab handles and visibility toggle switches.

### 2.5 Provider Management (`ProviderView` & `ProviderComponents.swift`)
- **Codex Management**: API Endpoint selector (Official vs Custom proxy), API key field with show/hide toggle, and Smart Switch status banner.
- **AntiGravity Accounts**: OAuth login button (`ProminentActionButtonStyle`), account list with email badge, source tag (`cli-proxy` / `OpenPulse OAuth`), and deletion confirm dialog.

### 2.6 Configs Editor (`ConfigsView`)
- **File Selection Chips**: Horizontal pill bar for `CLAUDE.md`, `settings.json`, `GEMINI.md`, etc.
- **Prompt/Config Editor**: Clean monospaced code editor view with line numbers, status info (char count, file size), and "Open in Finder / External Editor" action shortcuts.

### 2.7 Settings (`SettingsView`)
- **General**: Launch at Login switch, Language segmented picker (System / English / 简体中文) with restart notice.
- **Notifications**: Low-quota warning switch and threshold slider.
- **Data Management**: Clear cache button with confirmation dialog.

### 2.8 Diagnostic Logs (`LogView`)
- **Log List**: Real-time ring buffer diagnostic log viewer with log level badges (Info, Warning, Error) and monospaced timestamps.
- **Filter Bar**: Search text field and log level filter chips.

---

## 3. Implementation Plan Roadmap

1. Refine `CommonUI.swift` with shared Apple-style components (`StatCard`, `FilterChip`, `SectionHeader`, `GlassSurface`).
2. Polish `TrendsView.swift`, `QuotaView.swift`, and `SessionHistoryView.swift`.
3. Polish `MenuBarSettingsView.swift`, `ProviderComponents.swift`, `ConfigsView.swift`, `SettingsView.swift`, and `LogView.swift`.
4. Compile and verify full test suite with `xcodebuild`.
