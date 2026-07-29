# Design Spec: AntiGravity Pro Account Quota Aggregation

**Date:** 2026-07-29  
**Status:** Approved  
**Target:** OpenPulse (macOS Menu Bar App)

---

## 1. Executive Summary

OpenPulse currently supports multiple Antigravity (Gemini Code Assist) accounts. When multiple Pro accounts exist, users want a unified aggregate view in the Menu Bar popover that calculates the **average remaining quota percentage** across all Pro accounts for each model group (Gemini and 3P) and displays the **earliest reset time** for quick capacity restoration awareness.

This spec defines:
1. Adding an Aggregation Toggle under **Providers -> AntiGravity** settings.
2. The mathematical aggregation algorithm for Pro accounts.
3. Upgrading `AntigravityAggregateCard` in `MenuBarView.swift` to render the averaged Pro quota views.
4. Unit test verification.

---

## 2. Requirements & Key Decisions

### 2.1 User Settings Toggle
- **Location**: `AntigravityProviderContent` (`OpenPulse/Views/Providers/ProviderComponents.swift`) & synced with `SettingsView.swift`.
- **Storage**: Binds to `@AppStorage("menubar.antigravityDisplayMode")` (`"accounts"` vs `"aggregate"`).
- **Behavior**: When set to `"aggregate"`, MenuBar displays the aggregated Pro accounts view instead of listing every account individually.

### 2.2 Pro Account Filtering
- Account is recognized as Pro if `account.isPaid == true` (i.e. tier is paid Google AI Pro, or account contains complete consumer 5h + weekly quota windows).
- Hidden accounts (configured via `ag.hiddenAccountEmails`) are excluded before aggregation.
- Fallback: If no Pro accounts exist, fallback gracefully to aggregating all visible active accounts with a visual indicator.

### 2.3 Quota Aggregation & Averaging Logic
For each model group (`gemini`, `3p`) and each time window (`fiveHour`, `weekly`):
1. **Average Fraction**:
   $$\text{AvgFraction} = \frac{\sum_{i=1}^{N} \text{remainingFraction}_i}{N}$$
   Where $N$ is the number of valid Pro accounts containing that group and window.
2. **Earliest Reset Time (Earliest Strategy)**:
   $$\text{ResetTime} = \min_{i=1..N} (\text{validatedResetDate}_i)$$
   *Rationale*: Users want to know when the next capacity recovery begins ("回血时间").

---

## 3. Data Flow & Architecture

```
[ AntigravityProviderContent Toggle ]
               │
               ▼ Updates @AppStorage("menubar.antigravityDisplayMode")
               │
[ DataSyncService.latestAntigravityAccounts ]
               │
               ▼
   [ AntigravityProAggregator ] ─── (Filters Pro accounts & computes averages + min reset date)
               │
               ▼
 [ AntigravityAggregateCard (MenuBarView) ] ─── Renders unified Gemini & 3P panels
```

---

## 4. Code Changes Detail

### 4.1 Models & Helper: `AntigravityProAggregator`
Add a helper structure in `OpenPulse/Data/Parsers/AntigravityParser.swift` or a dedicated extension:

```swift
struct AGProAggregateSummary: Sendable {
    let proAccountCount: Int
    let groups: [AGQuotaGroup]
}

enum AntigravityProAggregator {
    static func aggregate(accounts: [AGAccountQuota]) -> AGProAggregateSummary {
        let proAccounts = accounts.filter(\.isPaid)
        let targetAccounts = proAccounts.isEmpty ? accounts : proAccounts
        
        // Group buckets: "gemini", "3p"
        let groupIds = ["gemini", "3p"]
        var aggregatedGroups: [AGQuotaGroup] = []
        
        for groupId in groupIds {
            // Collect all matching groups across accounts
            let matchingGroups = targetAccounts.compactMap { acc in
                acc.groups.first(where: { $0.id == groupId })
            }
            guard !matchingGroups.isEmpty else { continue }
            
            let displayName = matchingGroups.first?.displayName ?? groupId.capitalized
            
            // Average 5-hour window
            let fiveHourFractions = matchingGroups.compactMap { $0.fiveHour?.remainingFraction }
            let fiveHourAvg = fiveHourFractions.isEmpty ? nil : (fiveHourFractions.reduce(0.0, +) / Double(fiveHourFractions.count))
            let fiveHourEarliestReset = matchingGroups.compactMap { $0.fiveHour?.validatedResetDate }.min()
            
            let fiveHourWindow: AGWindow? = fiveHourAvg.map { frac in
                AGWindow(
                    kind: .fiveHour,
                    remainingFraction: frac,
                    resetTime: fiveHourEarliestReset,
                    description: nil
                )
            }
            
            // Average weekly window
            let weeklyFractions = matchingGroups.compactMap { $0.weekly?.remainingFraction }
            let weeklyAvg = weeklyFractions.isEmpty ? nil : (weeklyFractions.reduce(0.0, +) / Double(weeklyFractions.count))
            let weeklyEarliestReset = matchingGroups.compactMap { $0.weekly?.validatedResetDate }.min()
            
            let weeklyWindow: AGWindow? = weeklyAvg.map { frac in
                AGWindow(
                    kind: .weekly,
                    remainingFraction: frac,
                    resetTime: weeklyEarliestReset,
                    description: nil
                )
            }
            
            aggregatedGroups.append(AGQuotaGroup(
                id: groupId,
                displayName: displayName,
                fiveHour: fiveHourWindow,
                weekly: weeklyWindow
            ))
        }
        
        return AGProAggregateSummary(proAccountCount: targetAccounts.count, groups: aggregatedGroups)
    }
}
```

### 4.2 Provider UI: `ProviderComponents.swift`
In `AntigravityProviderContent`, insert a control section before/after account cards:

```swift
// Display mode toggle card
VStack(alignment: .leading, spacing: 8) {
    HStack {
        VStack(alignment: .leading, spacing: 2) {
            Text("菜单栏 Pro 账号额度聚合")
                .font(.system(size: 13, weight: .medium))
            Text("开启后在 Menu Bar 中合并所有 Pro 账号额度，计算 Gemini/3P 的平均可用剩余与最早重置时间。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        Spacer()
        Toggle("", isOn: Binding(
            get: { antigravityDisplayMode == "aggregate" },
            set: { antigravityDisplayMode = $0 ? "aggregate" : "accounts" }
        ))
        .toggleStyle(.switch)
    }
}
.padding(12)
.background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
```

### 4.3 Menu Bar UI: `MenuBarView.swift`
Update `AntigravityAggregateCard`:
- Calculate `AntigravityProAggregator.aggregate(accounts: visibleAccounts)`.
- Display a subheader showing `"Pro 账号聚合 (\(summary.proAccountCount) 个账号)"`.
- Render `AGMenuBarGroupCard` for each aggregated group.

---

## 5. Verification Plan

1. **Unit Tests**:
   - Add unit test `AntigravityProAggregatorTests` verifying:
     - Average remaining fraction calculation across 2+ accounts.
     - Selection of earliest reset date (`min()`).
     - Filtering of non-Pro accounts when Pro accounts exist.
2. **Build Verification**:
   - Run `xcodebuild -project OpenPulse.xcodeproj -scheme OpenPulse -configuration Debug build` to confirm Swift 6 concurrency and compilation pass cleanly.
