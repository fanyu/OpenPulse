# App Architecture & Navigation Refactoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reorganize OpenPulse sidebar navigation (8 tabs with updated SF Symbol icons), introduce a dedicated `MenuBarSettingsView` tab for popover/status-bar settings, and streamline `SessionHistoryView` (Activity) to only display Codex and Claude Code sessions.

**Architecture:**
- Add `.menuBar` to `AppTab` enum in `AppStore.swift` and reorder tabs to: `trends`, `quota`, `activity`, `menuBar`, `providers`, `configs`, `settings`, `logs` with updated icons.
- Create `MenuBarSettingsView.swift` grouping display style, title quota tools, Antigravity Pro aggregation toggle, tool reordering/visibility list, and global hotkey settings.
- Restrict `SessionHistoryView.swift` to filter and display only `.codex` and `.claudeCode` sessions and filter chips.
- Clean up `SettingsView.swift` and `ProviderComponents.swift` to eliminate duplicate menu bar settings.

**Tech Stack:** Swift 6.2, SwiftUI, XcodeGen (`xcodegen generate`), XCTest / `xcodebuild`.

## Global Constraints

- **Language/Framework**: Swift 6.2 strict concurrency (`SWIFT_STRICT_CONCURRENCY = complete`), SwiftUI, macOS 26.0 deployment target.
- **XcodeGen**: Any newly added file under `OpenPulse/` requires running `xcodegen generate` to update `OpenPulse.xcodeproj`.
- **No external dependencies**: Rely on stdlib and existing models/views.

---

### Task 1: Update `AppTab` Enum, Icons, Sidebar Order, and `MainWindowView` Switcher

**Files:**
- Modify: `OpenPulse/App/AppStore.swift:52-85`
- Modify: `OpenPulse/Views/Dashboard/MainWindowView.swift:20-31`

**Interfaces:**
- Consumes: `AppTab` cases
- Produces: 8-tab sidebar navigation in `AppStore` and `MainWindowView`

- [ ] **Step 1: Update `AppTab` enum in `AppStore.swift`**

Update `AppTab` in `OpenPulse/App/AppStore.swift`:

```swift
enum AppTab: String, CaseIterable {
    case trends    = "总览"
    case quota     = "配额"
    case activity  = "活动"
    case menuBar   = "菜单栏"
    case providers = "接入"
    case configs   = "配置"
    case settings  = "设置"
    case logs      = "日志"

    var icon: String {
        switch self {
        case .trends:    "chart.line.uptrend.xyaxis"
        case .quota:     "chart.pie.fill"
        case .activity:  "terminal.fill"
        case .menuBar:   "menubar.dock.rectangle"
        case .providers: "cable.connector"
        case .configs:   "doc.badge.gearshape.fill"
        case .settings:  "gearshape.fill"
        case .logs:      "scroll"
        }
    }

    var localizedTitle: LocalizedStringKey {
        switch self {
        case .trends:    "总览"
        case .quota:     "配额"
        case .activity:  "活动"
        case .menuBar:   "菜单栏"
        case .providers: "接入"
        case .configs:   "配置"
        case .settings:  "设置"
        case .logs:      "日志"
        }
    }
}
```

- [ ] **Step 2: Update `MainWindowView.swift` detail view switcher**

In `OpenPulse/Views/Dashboard/MainWindowView.swift`:

```swift
    @ViewBuilder
    private var detailView: some View {
        switch appStore.selectedTab {
        case .trends:    TrendsView()
        case .quota:     QuotaView()
        case .activity:  SessionHistoryView()
        case .menuBar:   MenuBarSettingsView()
        case .providers: ProviderView()
        case .configs:   ConfigsView()
        case .settings:  SettingsView()
        case .logs:      LogView()
        }
    }
```

- [ ] **Step 3: Commit Task 1 preparation**

```bash
git add OpenPulse/App/AppStore.swift OpenPulse/Views/Dashboard/MainWindowView.swift
git commit -m "feat(navigation): add menuBar tab to AppTab and update sidebar tab order and icons"
```

---

### Task 2: Create `MenuBarSettingsView.swift` and Register with XcodeGen

**Files:**
- Create: `OpenPulse/Views/MenuBar/MenuBarSettingsView.swift`

**Interfaces:**
- Consumes: `@AppStorage` keys (`displayStyle`, `titleQuotaTools`, `antigravityDisplayMode`, `toolOrder`, `hiddenTools`, `hotkey`)
- Produces: `MenuBarSettingsView` SwiftUI View

- [ ] **Step 1: Create `MenuBarSettingsView.swift`**

Create `OpenPulse/Views/MenuBar/MenuBarSettingsView.swift`:

```swift
import SwiftUI
import SwiftData

struct MenuBarSettingsView: View {
    @AppStorage("menubar.toolOrder")        private var toolOrderRaw = Tool.defaultOrderRaw
    @AppStorage("menubar.hiddenTools")      private var hiddenToolsRaw = ""
    @AppStorage("menubar.titleQuotaTools")  private var titleQuotaToolsRaw = ""
    @AppStorage("menubar.antigravityDisplayMode") private var antigravityDisplayMode = "accounts"
    @AppStorage("menubar.displayStyle") private var displayStyle = "compact"

    // MARK: - Hotkey
    @AppStorage("menubar.hotkey.keyCode")    private var hotkeyKeyCode    = 0
    @AppStorage("menubar.hotkey.modifiers")  private var hotkeyModifiers  = 0

    private var hotkeyLabel: String {
        GlobalHotkeyService.displayString(
            keyCode: UInt32(hotkeyKeyCode),
            carbonModifiers: UInt32(hotkeyModifiers)
        )
    }

    private var orderedTools: [Tool] {
        let order = toolOrderRaw.components(separatedBy: ",").compactMap { Tool(rawValue: $0) }
        return order + Tool.allCases.filter { !order.contains($0) }
    }

    private var hiddenTools: Set<String> {
        Set(hiddenToolsRaw.components(separatedBy: ",").filter { !$0.isEmpty })
    }

    private var selectedTitleQuotaTools: Set<String> {
        Set(titleQuotaToolsRaw.components(separatedBy: ",").filter { !$0.isEmpty })
    }

    private var menuBarTitleQuotaTools: [Tool] {
        orderedTools.filter(\.supportsMenuBarFiveHourDisplay)
    }

    private func moveTools(from offsets: IndexSet, to destination: Int) {
        var tools = orderedTools
        tools.move(fromOffsets: offsets, toOffset: destination)
        toolOrderRaw = tools.map(\.rawValue).joined(separator: ",")
    }

    private func setToolHidden(_ tool: Tool, _ hidden: Bool) {
        var set = hiddenTools
        if hidden { set.insert(tool.rawValue) } else { set.remove(tool.rawValue) }
        hiddenToolsRaw = set.joined(separator: ",")
    }

    private func setTitleQuotaToolEnabled(_ tool: Tool, _ enabled: Bool) {
        var selected = selectedTitleQuotaTools
        if enabled {
            selected.insert(tool.rawValue)
        } else {
            selected.remove(tool.rawValue)
        }
        titleQuotaToolsRaw = orderedTools
            .map(\.rawValue)
            .filter { selected.contains($0) }
            .joined(separator: ",")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // 快捷键
                SettingsCard(title: "快捷键", icon: "keyboard") {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("全局快捷键")
                                .font(.body)
                            Text("按下快捷键随时显示或隐藏 OpenPulse 菜单栏窗口")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        HotkeyRecorderView(
                            keyCode: $hotkeyKeyCode,
                            modifiers: $hotkeyModifiers
                        )
                        .frame(width: 140, height: 28)
                    }
                }

                // 菜单栏显示
                SettingsCard(title: "菜单栏控制", icon: "menubar.rectangle") {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("状态栏样式")
                                .font(.subheadline.weight(.medium))
                            Text("精简模式直接显示工具图标和 5h 余量；经典模式显示应用图标和 5H/7D 额度摘要。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Picker("状态栏样式", selection: $displayStyle) {
                                Text("精简模式").tag("compact")
                                Text("经典模式").tag("classic")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            Text("菜单栏标题额度")
                                .font(.subheadline.weight(.medium))
                            Text("选择后会在菜单栏直接显示该 Agent 的余量摘要；单个工具显示 5H/7D，两项工具时每行显示一个工具。")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            ForEach(menuBarTitleQuotaTools, id: \.self) { tool in
                                HStack(spacing: 12) {
                                    ToolLogoImage(tool: tool, size: 20)
                                    Text(tool.displayName)
                                        .font(.body)
                                    Spacer()
                                    Toggle("", isOn: Binding(
                                        get: { selectedTitleQuotaTools.contains(tool.rawValue) },
                                        set: { setTitleQuotaToolEnabled(tool, $0) }
                                    ))
                                    .toggleStyle(.switch)
                                    .labelsHidden()
                                }
                                .padding(.vertical, 2)
                            }
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Antigravity Pro 账号额度聚合")
                                .font(.subheadline.weight(.medium))
                            Text("开启后在 Menu Bar 中合并所有 Pro 账号额度，按模型（Gemini/3P）计算平均剩余量与最早重置时间。")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Picker("Antigravity 展示方式", selection: $antigravityDisplayMode) {
                                Text("逐账号").tag("accounts")
                                Text("聚合 Pro 账号").tag("aggregate")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            Text("工具排序与显示")
                                .font(.subheadline.weight(.medium))
                            Text("拖拽列表调整菜单栏中的显示顺序，并控制是否在菜单栏中显示。")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            List {
                                ForEach(orderedTools, id: \.self) { tool in
                                    HStack(spacing: 12) {
                                        ToolLogoImage(tool: tool, size: 24)
                                        Text(tool.displayName)
                                            .font(.body)
                                        Spacer()
                                        Toggle("", isOn: Binding(
                                            get: { !hiddenTools.contains(tool.rawValue) },
                                            set: { setToolHidden(tool, !$0) }
                                        ))
                                        .toggleStyle(.switch)
                                        .labelsHidden()
                                    }
                                    .padding(.vertical, 4)
                                }
                                .onMove(perform: moveTools)
                            }
                            .listStyle(.plain)
                            .frame(height: CGFloat(orderedTools.count) * 44)
                            .scrollDisabled(true)
                            .background(Color.primary.opacity(0.03))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            .padding(24)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .navigationTitle("菜单栏设置")
    }
}
```

- [ ] **Step 2: Regenerate Xcode project with `xcodegen generate`**

Run: `xcodegen generate`

- [ ] **Step 3: Commit Task 2**

```bash
git add OpenPulse/Views/MenuBar/MenuBarSettingsView.swift OpenPulse.xcodeproj project.yml
git commit -m "feat(menuBar): create dedicated MenuBarSettingsView tab"
```

---

### Task 3: Streamline `SessionHistoryView` (Activity) to Codex & Claude Code Only

**Files:**
- Modify: `OpenPulse/Views/History/SessionHistoryView.swift:15-180`

**Interfaces:**
- Consumes: `sessions: [SessionRecord]`
- Produces: Filtered session history displaying only Codex and Claude Code sessions and filter pills.

- [ ] **Step 1: Update tool filters and session filtering in `SessionHistoryView.swift`**

In `OpenPulse/Views/History/SessionHistoryView.swift`:
1. Limit `activeActivityTools`: `let activeTools: [Tool] = [.codex, .claudeCode]`
2. Filter sessions:
   ```swift
   private var filtered: [SessionRecord] {
       sessions.filter { session in
           let isActivityTool = session.tool == .codex || session.tool == .claudeCode
           guard isActivityTool else { return false }
           let matchesTool = selectedTool == nil || session.tool == selectedTool
           let matchesSearch = debouncedSearchText.isEmpty ||
               session.taskDescription.localizedStandardContains(debouncedSearchText) ||
               session.cwd.localizedStandardContains(debouncedSearchText) ||
               (session.gitBranch?.localizedStandardContains(debouncedSearchText) ?? false)
           return matchesTool && matchesSearch
       }
   }
   ```
3. Update `filterBar` to iterate over `[.codex, .claudeCode]`:
   ```swift
   ForEach([Tool.codex, Tool.claudeCode], id: \.self) { tool in
       let count = toolSessionCounts[tool] ?? 0
       FilterChip(label: "\(tool.displayName) (\(count))", isSelected: selectedTool == tool) {
           withAnimation(.spring(duration: 0.3)) {
               selectedTool = (selectedTool == tool) ? nil : tool
           }
       }
   }
   ```
4. Clean up `toolDeepAnalysisHeader`: remove `AGAnalysisView` and `CopilotAnalysisView` cases from switch.

- [ ] **Step 2: Commit Task 3**

```bash
git add OpenPulse/Views/History/SessionHistoryView.swift
git commit -m "refactor(activity): streamline SessionHistoryView to show only Codex and Claude Code"
```

---

### Task 4: Clean Up `SettingsView.swift` and `ProviderComponents.swift`

**Files:**
- Modify: `OpenPulse/Views/Settings/SettingsView.swift`
- Modify: `OpenPulse/Views/Providers/ProviderComponents.swift`

**Interfaces:**
- Consumes: Remaining non-menubar setting components
- Produces: Cleaned up `SettingsView` and `AntigravityProviderContent` without duplicated menu bar toggles.

- [ ] **Step 1: Remove MenuBar card & hotkey card from `SettingsView.swift`**

Remove the hotkey card and the `SettingsCard(title: "菜单栏显示", icon: "menubar.rectangle")` block from `SettingsView.swift`, keeping General, Notifications, Dot Text API, and Data Reset cards.

- [ ] **Step 2: Remove Pro aggregation toggle from `ProviderComponents.swift`**

Remove the `VStack` toggle card from `AntigravityProviderContent` (lines 476-494) that was added earlier, keeping `AntigravityProviderContent` focused purely on login/auth and account listing.

- [ ] **Step 3: Commit Task 4**

```bash
git add OpenPulse/Views/Settings/SettingsView.swift OpenPulse/Views/Providers/ProviderComponents.swift
git commit -m "clean(settings): remove duplicated menu bar settings from SettingsView and ProviderComponents"
```

---

### Task 5: Build and Run Tests Verification

- [ ] **Step 1: Run full `xcodebuild` test suite**

Run: `xcodebuild -project OpenPulse.xcodeproj -scheme OpenPulse -destination 'platform=macOS' test`
Expected: Build succeeds, 23/23 unit tests pass.

- [ ] **Step 2: Commit final verification**

```bash
git status
```
