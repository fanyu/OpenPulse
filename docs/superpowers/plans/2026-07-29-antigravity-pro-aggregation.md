# AntiGravity Pro Account Quota Aggregation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement Pro account quota aggregation in the macOS Menu Bar popover for AntiGravity, averaging 5h/weekly quota fractions across Pro accounts and displaying earliest reset times, controlled by a toggle in the Providers settings page.

**Architecture:** 
- Add `AntigravityProAggregator` struct to `AntigravityParser.swift` to filter Pro accounts (`account.isPaid == true`) and average `gemini` and `3p` quota fractions while picking the earliest reset date (`min()`).
- Add a display mode toggle in `ProviderComponents.swift` (`AntigravityProviderContent`) bound to `@AppStorage("menubar.antigravityDisplayMode")`.
- Update `AntigravityAggregateCard` in `MenuBarView.swift` to render the aggregated Pro groups and account count header when `"aggregate"` mode is active.

**Tech Stack:** Swift 6.2, SwiftUI, XcodeGen (`xcodegen generate`), XCTest / `xcodebuild`.

## Global Constraints

- **Language/Framework**: Swift 6.2 strict concurrency (`SWIFT_STRICT_CONCURRENCY = complete`), SwiftUI, macOS 26.0 deployment target.
- **XcodeGen**: Any newly added file under `OpenPulseTests/` requires running `xcodegen generate` to update `OpenPulse.xcodeproj`.
- **No external dependencies**: Rely on stdlib and existing models (`AGAccountQuota`, `AGQuotaGroup`, `AGWindow`).

---

### Task 1: Add `AntigravityProAggregator` and Unit Tests

**Files:**
- Modify: `OpenPulse/Data/Parsers/AntigravityParser.swift`
- Create: `OpenPulseTests/AntigravityProAggregatorTests.swift`

**Interfaces:**
- Consumes: `AGAccountQuota`, `AGQuotaGroup`, `AGWindow`, `AGTier`
- Produces: `AGProAggregateSummary`, `AntigravityProAggregator.aggregate(accounts:)`

- [ ] **Step 1: Write the unit test for `AntigravityProAggregator`**

Create `OpenPulseTests/AntigravityProAggregatorTests.swift`:

```swift
import XCTest
@testable import OpenPulse

final class AntigravityProAggregatorTests: XCTestCase {
    func testAggregateProAccountsAveragesFractionsAndFindsEarliestReset() {
        let date1 = Date().addingTimeInterval(3600)
        let date2 = Date().addingTimeInterval(1800)
        
        let account1 = AGAccountQuota(
            email: "pro1@gmail.com",
            tier: AGTier(id: "gai-pro", name: "Google AI Pro"),
            groups: [
                AGQuotaGroup(
                    id: "gemini",
                    displayName: "Gemini",
                    fiveHour: AGWindow(kind: .fiveHour, remainingFraction: 0.8, resetTime: date1, description: nil),
                    weekly: AGWindow(kind: .weekly, remainingFraction: 0.6, resetTime: date1, description: nil)
                )
            ]
        )
        
        let account2 = AGAccountQuota(
            email: "pro2@gmail.com",
            tier: AGTier(id: "gai-pro", name: "Google AI Pro"),
            groups: [
                AGQuotaGroup(
                    id: "gemini",
                    displayName: "Gemini",
                    fiveHour: AGWindow(kind: .fiveHour, remainingFraction: 0.6, resetTime: date2, description: nil),
                    weekly: AGWindow(kind: .weekly, remainingFraction: 0.4, resetTime: date2, description: nil)
                )
            ]
        )
        
        let freeAccount = AGAccountQuota(
            email: "free@gmail.com",
            tier: AGTier(id: "free-tier", name: "Free Tier"),
            groups: [
                AGQuotaGroup(
                    id: "gemini",
                    displayName: "Gemini",
                    fiveHour: AGWindow(kind: .fiveHour, remainingFraction: 0.1, resetTime: date1, description: nil),
                    weekly: nil
                )
            ]
        )
        
        let summary = AntigravityProAggregator.aggregate(accounts: [account1, account2, freeAccount])
        
        XCTAssertEqual(summary.proAccountCount, 2)
        XCTAssertEqual(summary.groups.count, 1)
        
        let geminiGroup = summary.groups.first { $0.id == "gemini" }
        XCTAssertNotNil(geminiGroup)
        
        // 5h average = (0.8 + 0.6) / 2 = 0.7
        XCTAssertEqual(geminiGroup?.fiveHour?.remainingFraction ?? 0, 0.7, accuracy: 0.001)
        // Earliest reset = date2 (1800s in future vs 3600s)
        XCTAssertEqual(geminiGroup?.fiveHour?.validatedResetDate, date2)
        
        // Weekly average = (0.6 + 0.4) / 2 = 0.5
        XCTAssertEqual(geminiGroup?.weekly?.remainingFraction ?? 0, 0.5, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: Regenerate Xcode project with `xcodegen generate`**

Run: `xcodegen generate`

- [ ] **Step 3: Run tests to verify failure before implementation**

Run: `xcodebuild -project OpenPulse.xcodeproj -scheme OpenPulse -destination 'platform=macOS' test`
Expected: Compiler error (`AntigravityProAggregator` not found).

- [ ] **Step 4: Implement `AntigravityProAggregator` in `AntigravityParser.swift`**

Add the struct and aggregation function to `AntigravityParser.swift`:

```swift
struct AGProAggregateSummary: Sendable {
    let proAccountCount: Int
    let groups: [AGQuotaGroup]
}

enum AntigravityProAggregator {
    static func aggregate(accounts: [AGAccountQuota]) -> AGProAggregateSummary {
        let proAccounts = accounts.filter(\.isPaid)
        let targetAccounts = proAccounts.isEmpty ? accounts : proAccounts
        
        let groupIds = ["gemini", "3p"]
        var aggregatedGroups: [AGQuotaGroup] = []
        
        for groupId in groupIds {
            let matchingGroups = targetAccounts.compactMap { acc in
                acc.groups.first(where: { $0.id == groupId })
            }
            guard !matchingGroups.isEmpty else { continue }
            
            let displayName = matchingGroups.first?.displayName ?? (groupId == "gemini" ? "Gemini Models" : "3P Models")
            
            // 5-hour window
            let fiveHourWindows = matchingGroups.compactMap(\.fiveHour)
            let fiveHourFractions = fiveHourWindows.compactMap(\.remainingFraction)
            let fiveHourAvg = fiveHourFractions.isEmpty ? nil : (fiveHourFractions.reduce(0.0, +) / Double(fiveHourFractions.count))
            let fiveHourEarliestReset = fiveHourWindows.compactMap(\.validatedResetDate).min()
            
            let fiveHourWindow: AGWindow? = fiveHourAvg.map { frac in
                AGWindow(
                    kind: .fiveHour,
                    remainingFraction: frac,
                    resetTime: fiveHourEarliestReset,
                    description: nil
                )
            }
            
            // Weekly window
            let weeklyWindows = matchingGroups.compactMap(\.weekly)
            let weeklyFractions = weeklyWindows.compactMap(\.remainingFraction)
            let weeklyAvg = weeklyFractions.isEmpty ? nil : (weeklyFractions.reduce(0.0, +) / Double(weeklyFractions.count))
            let weeklyEarliestReset = weeklyWindows.compactMap(\.validatedResetDate).min()
            
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

- [ ] **Step 5: Run unit tests to verify they pass**

Run: `xcodebuild -project OpenPulse.xcodeproj -scheme OpenPulse -destination 'platform=macOS' test`
Expected: PASS

- [ ] **Step 6: Commit changes**

```bash
git add OpenPulse/Data/Parsers/AntigravityParser.swift OpenPulseTests/AntigravityProAggregatorTests.swift OpenPulse.xcodeproj project.yml
git commit -m "feat(antigravity): add AntigravityProAggregator and unit tests"
```

---

### Task 2: Add Pro Account Aggregation Toggle in Provider UI

**Files:**
- Modify: `OpenPulse/Views/Providers/ProviderComponents.swift`

**Interfaces:**
- Consumes: `@AppStorage("menubar.antigravityDisplayMode")`
- Produces: Aggregation toggle UI card inside `AntigravityProviderContent`

- [ ] **Step 1: Update `AntigravityProviderContent` in `ProviderComponents.swift`**

Add `@AppStorage("menubar.antigravityDisplayMode") private var antigravityDisplayMode = "accounts"` and add the UI toggle card at the top of the provider action bar in `AntigravityProviderContent`:

```swift
// MARK: - Display Mode Toggle
VStack(alignment: .leading, spacing: 8) {
    HStack {
        VStack(alignment: .leading, spacing: 2) {
            Text("菜单栏 Pro 账号额度聚合")
                .font(.system(size: 13, weight: .medium))
            Text("开启后在 Menu Bar 中合并所有 Pro 账号额度，按模型（Gemini/3P）计算平均剩余量与最早重置时间。")
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

- [ ] **Step 2: Build project to verify compilation**

Run: `xcodebuild -project OpenPulse.xcodeproj -scheme OpenPulse -configuration Debug build`
Expected: Build succeeds with 0 errors.

- [ ] **Step 3: Commit changes**

```bash
git add OpenPulse/Views/Providers/ProviderComponents.swift
git commit -m "feat(providers): add Antigravity Pro quota aggregation toggle"
```

---

### Task 3: Update `AntigravityAggregateCard` in MenuBarView

**Files:**
- Modify: `OpenPulse/Views/MenuBar/MenuBarView.swift:1125-1164`

**Interfaces:**
- Consumes: `AntigravityProAggregator.aggregate(accounts: visibleAccounts)`
- Produces: Updated `AntigravityAggregateCard` rendering aggregated Pro account quota groups and account count indicator

- [ ] **Step 1: Update `AntigravityAggregateCard` in `MenuBarView.swift`**

Replace the current implementation of `AntigravityAggregateCard` with:

```swift
struct AntigravityAggregateCard: View {
    let accounts: [AGAccountQuota]
    let todayTokens: Int
    @AppStorage("ag.hiddenAccountEmails") private var hiddenAccountEmailsRaw = ""

    private var hiddenAccountEmails: Set<String> {
        Set(hiddenAccountEmailsRaw.components(separatedBy: ",").filter { !$0.isEmpty })
    }

    private var visibleAccounts: [AGAccountQuota] {
        accounts.filter { !hiddenAccountEmails.contains($0.email) }
    }

    var body: some View {
        MenuBarToolShell {
            MenuBarToolIdentity(
                tool: .antigravity,
                todayTokens: todayTokens
            ) {
                ConfigShortcutButton(tool: .antigravity)
            }
        } content: {
            if visibleAccounts.isEmpty {
                Text("暂无可用账号额度")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                let summary = AntigravityProAggregator.aggregate(accounts: visibleAccounts)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text("Pro 账号额度聚合 (\(summary.proAccountCount)个账号)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    
                    ForEach(summary.groups) { group in
                        AGMenuBarGroupCard(group: group)
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 2: Build project and run unit tests**

Run: `xcodebuild -project OpenPulse.xcodeproj -scheme OpenPulse -destination 'platform=macOS' test`
Expected: Build and tests pass completely.

- [ ] **Step 3: Commit changes**

```bash
git add OpenPulse/Views/MenuBar/MenuBarView.swift
git commit -m "feat(menubar): render Pro account aggregated quotas in AntigravityAggregateCard"
```
