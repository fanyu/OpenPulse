import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MenuBarSettingsView: View {
    @Environment(AppStore.self) private var appStore
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("menubar.toolOrder") private var toolOrderRaw = Tool.defaultOrderRaw
    @AppStorage("menubar.hiddenTools") private var hiddenToolsRaw = ""
    @AppStorage("menubar.titleQuotaTools") private var titleQuotaToolsRaw: String?
    @AppStorage("menubar.antigravityDisplayMode") private var antigravityDisplayMode = "accounts"
    @AppStorage("menubar.displayStyle") private var displayStyle = "compact"
    @AppStorage("ag.hiddenAccountEmails") private var hiddenAGEmailsRaw = ""

    @State private var draggingTool: Tool?
    @State private var dropTargetTool: Tool?
    @State private var hoveredTool: Tool?
    @State private var isWide = true

    private var orderedTools: [Tool] {
        Tool.orderedTools(from: toolOrderRaw)
    }

    private var hiddenTools: Set<String> {
        Set(hiddenToolsRaw.components(separatedBy: ",").filter { !$0.isEmpty })
    }

    private var activeStatusBarTools: [Tool] {
        Tool.menuBarTitleQuotaTools(
            displayStyle: displayStyle,
            titleQuotaToolsRaw: titleQuotaToolsRaw,
            toolOrderRaw: toolOrderRaw
        )
    }

    private var selectedTitleQuotaTools: Set<String> {
        Set(activeStatusBarTools.map(\.rawValue))
    }

    private func reorderTool(_ dragged: Tool, to target: Tool) {
        guard dragged != target else { return }
        var tools = orderedTools
        guard let fromIndex = tools.firstIndex(of: dragged),
              let toIndex = tools.firstIndex(of: target) else { return }
        withAnimation(.smooth(duration: 0.22)) {
            tools.move(
                fromOffsets: IndexSet(integer: fromIndex),
                toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
            )
            toolOrderRaw = tools.map(\.rawValue).joined(separator: ",")
        }
    }

    private func moveTool(_ tool: Tool, by delta: Int) {
        var tools = orderedTools
        guard let index = tools.firstIndex(of: tool) else { return }
        let targetIndex = index + delta
        guard tools.indices.contains(targetIndex) else { return }
        withAnimation(.smooth(duration: 0.22)) {
            tools.swapAt(index, targetIndex)
            toolOrderRaw = tools.map(\.rawValue).joined(separator: ",")
        }
    }

    private func setToolHidden(_ tool: Tool, _ hidden: Bool) {
        var set = hiddenTools
        if hidden { set.insert(tool.rawValue) } else { set.remove(tool.rawValue) }
        hiddenToolsRaw = set.joined(separator: ",")
    }

    private func setTitleQuotaToolEnabled(_ tool: Tool, _ enabled: Bool) {
        titleQuotaToolsRaw = Tool.updatingTitleQuotaTools(
            displayStyle: displayStyle,
            currentRaw: titleQuotaToolsRaw,
            toolOrderRaw: toolOrderRaw,
            tool: tool,
            isEnabled: enabled
        )
    }

    private var previewItemsByTool: [Tool: MenuBarPreviewItem] {
        Dictionary(
            uniqueKeysWithValues: orderedTools.map { tool in
                (
                    tool,
                    MenuBarPreviewItem.build(
                        tool: tool,
                        appStore: appStore,
                        hiddenAGEmailsRaw: hiddenAGEmailsRaw
                    )
                )
            }
        )
    }

    private var previewItems: [MenuBarPreviewItem] {
        let map = previewItemsByTool
        return activeStatusBarTools.compactMap { map[$0] }
    }

    var body: some View {
        let itemMap = previewItemsByTool
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                // Page Header (unified with Quota, Overview, Activity, Providers)
                VStack(alignment: .leading, spacing: 6) {
                    Text("菜单栏设置")
                        .font(.system(size: 28, weight: .semibold))
                        .tracking(-0.4)
                    Text("安排工具顺序、额度摘要与快捷键。")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                // Section 1: Live Menu Bar Preview + Visual Style Picker
                VStack(alignment: .leading, spacing: 14) {
                    DashboardSectionTitle(title: "菜单栏样式")

                    VStack(alignment: .leading, spacing: 16) {
                        StatusBarLivePreviewStage(
                            style: displayStyle,
                            items: previewItems
                        )

                        let styleColumns = Array(
                            repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
                            count: isWide ? 3 : 1
                        )
                        LazyVGrid(columns: styleColumns, spacing: 12) {
                            StatusBarStyleOptionCard(
                                tag: "compact",
                                title: "精简横向",
                                subtitle: "图标与余量横向排列",
                                isSelected: displayStyle == "compact"
                            ) {
                                withAnimation(.smooth(duration: 0.22)) {
                                    displayStyle = "compact"
                                }
                            } preview: {
                                styleMiniMenuBarPill {
                                    HStack(spacing: 10) {
                                        HStack(spacing: 3) {
                                            styleMiniGlyph(tool: .codex, size: 12)
                                            Text("85%")
                                        }
                                        HStack(spacing: 3) {
                                            styleMiniGlyph(tool: .antigravity, size: 12)
                                            Text("79%")
                                        }
                                    }
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                }
                            }

                            StatusBarStyleOptionCard(
                                tag: "vertical",
                                title: "精简竖向",
                                subtitle: "上下堆叠，更省菜单栏空间",
                                isSelected: displayStyle == "vertical"
                            ) {
                                withAnimation(.smooth(duration: 0.22)) {
                                    displayStyle = "vertical"
                                }
                            } preview: {
                                styleMiniMenuBarPill {
                                    HStack(spacing: 12) {
                                        VStack(spacing: 1.5) {
                                            styleMiniGlyph(tool: .codex, size: 9.5)
                                            Text("85%")
                                        }
                                        VStack(spacing: 1.5) {
                                            styleMiniGlyph(tool: .antigravity, size: 9.5)
                                            Text("79%")
                                        }
                                    }
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                }
                            }

                            StatusBarStyleOptionCard(
                                tag: "classic",
                                title: "经典模式",
                                subtitle: "应用图标搭配额度摘要",
                                isSelected: displayStyle == "classic"
                            ) {
                                withAnimation(.smooth(duration: 0.22)) {
                                    displayStyle = "classic"
                                }
                            } preview: {
                                styleMiniMenuBarPill {
                                    HStack(spacing: 6) {
                                        menuBarAppTemplateIcon(size: 14)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text("5H 85%")
                                            Text("7D 72%")
                                        }
                                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                    }
                                }
                            }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dashboardSurface()
                }

                // Section 2: Unified Tools, Order & Visibility (pure SwiftUI rows for exact alignment)
                VStack(alignment: .leading, spacing: 14) {
                    DashboardSectionTitle(
                        title: "工具排序与显示",
                        subtitle: "拖拽调整工具顺序，分别控制其在菜单栏与下拉面板中的显示。"
                    )

                    VStack(spacing: 0) {
                        // Column Header Bar
                        HStack(spacing: 12) {
                            Text("工具")
                                .padding(.leading, 24)
                            Spacer(minLength: 12)
                            Text("当前额度")
                                .frame(width: 84, alignment: .trailing)
                            Text("菜单栏")
                                .frame(width: 84, alignment: .center)
                            Text("下拉面板")
                                .frame(width: 84, alignment: .center)
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 11)
                        .background(Color.primary.opacity(colorScheme == .dark ? 0.035 : 0.02))

                        TelemetryHairline()

                        VStack(spacing: 0) {
                            ForEach(Array(orderedTools.enumerated()), id: \.element) { index, tool in
                                let item = itemMap[tool]
                                let isHovered = hoveredTool == tool
                                let isDropTarget = dropTargetTool == tool && draggingTool != nil && draggingTool != tool

                                HStack(spacing: 12) {
                                    Image(systemName: "line.3.horizontal")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(isHovered ? .secondary : .tertiary)
                                        .frame(width: 12)

                                    ToolBrandIconWell(tool: tool, size: 28, iconSize: 17)

                                    HStack(spacing: 8) {
                                        Text(tool.displayName)
                                            .font(.system(size: 13, weight: .medium))

                                        if isHovered {
                                            HStack(spacing: 2) {
                                                Button {
                                                    moveTool(tool, by: -1)
                                                } label: {
                                                    Image(systemName: "chevron.up")
                                                        .font(.system(size: 9.5, weight: .semibold))
                                                        .frame(width: 18, height: 18)
                                                        .contentShape(Circle())
                                                }
                                                .buttonStyle(.plain)
                                                .focusEffectDisabled()
                                                .disabled(index == 0)
                                                .opacity(index == 0 ? 0.25 : 0.7)
                                                .help("上移")

                                                Button {
                                                    moveTool(tool, by: 1)
                                                } label: {
                                                    Image(systemName: "chevron.down")
                                                        .font(.system(size: 9.5, weight: .semibold))
                                                        .frame(width: 18, height: 18)
                                                        .contentShape(Circle())
                                                }
                                                .buttonStyle(.plain)
                                                .focusEffectDisabled()
                                                .disabled(index == orderedTools.count - 1)
                                                .opacity(index == orderedTools.count - 1 ? 0.25 : 0.7)
                                                .help("下移")
                                            }
                                            .foregroundStyle(.secondary)
                                            .transition(.opacity)
                                        }
                                    }

                                    Spacer(minLength: 12)

                                    toolLiveQuotaBadge(tool: tool, item: item)
                                        .frame(width: 84, alignment: .trailing)

                                    Toggle(tool.displayName, isOn: Binding(
                                        get: { selectedTitleQuotaTools.contains(tool.rawValue) },
                                        set: { setTitleQuotaToolEnabled(tool, $0) }
                                    ))
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                                    .labelsHidden()
                                    .frame(width: 84, alignment: .center)

                                    Toggle(tool.displayName, isOn: Binding(
                                        get: { !hiddenTools.contains(tool.rawValue) },
                                        set: { setToolHidden(tool, !$0) }
                                    ))
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                                    .labelsHidden()
                                    .frame(width: 84, alignment: .center)
                                }
                                .padding(.horizontal, 20)
                                .frame(minHeight: 52)
                                .background(
                                    isDropTarget
                                        ? Color.accentColor.opacity(colorScheme == .dark ? 0.14 : 0.08)
                                        : (isHovered ? Color.primary.opacity(colorScheme == .dark ? 0.035 : 0.022) : Color.clear)
                                )
                                .overlay(alignment: .top) {
                                    if isDropTarget {
                                        Rectangle()
                                            .fill(Color.accentColor)
                                            .frame(height: 2)
                                    }
                                }
                                .contentShape(Rectangle())
                                .onHover { hovering in
                                    withAnimation(.easeOut(duration: 0.12)) {
                                        hoveredTool = hovering ? tool : (hoveredTool == tool ? nil : hoveredTool)
                                    }
                                }
                                .draggable(tool.rawValue) {
                                    HStack(spacing: 8) {
                                        ToolBrandIconWell(tool: tool, size: 22, iconSize: 13)
                                        Text(tool.displayName)
                                            .font(.system(size: 12.5, weight: .medium))
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .onAppear { draggingTool = tool }
                                }
                                .dropDestination(for: String.self) { items, _ in
                                    defer {
                                        draggingTool = nil
                                        dropTargetTool = nil
                                    }
                                    guard let raw = items.first,
                                          let dragged = Tool(rawValue: raw) else { return false }
                                    reorderTool(dragged, to: tool)
                                    return true
                                } isTargeted: { targeted in
                                    if targeted {
                                        dropTargetTool = tool
                                    } else if dropTargetTool == tool {
                                        dropTargetTool = nil
                                    }
                                }

                                if index < orderedTools.count - 1 {
                                    TelemetryHairline()
                                        .padding(.leading, 20)
                                }
                            }
                        }

                        TelemetryHairline()

                        // Antigravity Display Mode
                        HStack(alignment: .center, spacing: 16) {
                            ToolBrandIconWell(tool: .antigravity, size: 28, iconSize: 17)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Antigravity 展示方式")
                                    .font(.system(size: 13, weight: .medium))
                                Text("控制下拉面板中多个 Pro 账号的展示模式")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 12)
                            AntigravityDisplayModeSwitcher(selection: $antigravityDisplayMode)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                    }
                    .dashboardSurface()
                }

                // Section 3: Hotkey & Shortcuts
                SettingsCard(title: "快捷键") {
                    MenuBarHotkeySettings()
                }
            }
            .frame(maxWidth: 1120, alignment: .leading)
            .padding(.horizontal, isWide ? 28 : 20)
            .padding(.top, 8)
            .padding(.bottom, 26)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollEdgeEffectStyle(.soft, for: .vertical)
        .onGeometryChange(for: Bool.self) { proxy in
            proxy.size.width >= 720
        } action: { next in
            if isWide != next { isWide = next }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .navigationTitle("菜单栏设置")
    }

    @ViewBuilder
    private func toolLiveQuotaBadge(tool: Tool, item: MenuBarPreviewItem?) -> some View {
        if let pct = item?.fiveHourPercent {
            let tint = tool.brandAccentColor(for: colorScheme)
            Text("\(pct)%")
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(tint.opacity(colorScheme == .dark ? 0.16 : 0.10), in: Capsule())
        } else {
            Text("—")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    private func styleMiniMenuBarPill<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                colorScheme == .dark
                    ? Color.white.opacity(0.10)
                    : Color.white.opacity(0.82),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.08), lineWidth: 0.6)
            }
    }

    @ViewBuilder
    private func styleMiniGlyph(tool: Tool, size: CGFloat) -> some View {
        if let nsImage = NSImage(named: tool.menuBarIconName) {
            Image(nsImage: nsImage)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: tool.iconName)
                .font(.system(size: size * 0.85))
        }
    }

    @ViewBuilder
    private func menuBarAppTemplateIcon(size: CGFloat) -> some View {
        if let nsImage = NSImage(named: "MenuBarIcon") {
            Image(nsImage: nsImage)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: size * 0.85))
        }
    }
}

// MARK: - Live Menu Bar Preview Stage

private struct MenuBarPreviewItem: Identifiable {
    let tool: Tool
    let shortLabel: String
    let fiveHourPercent: Int?
    let sevenDayPercent: Int?

    var id: Tool { tool }

    var fiveHourDisplay: String {
        fiveHourPercent.map { "\($0)%" } ?? "--%"
    }

    var sevenDayDisplay: String {
        sevenDayPercent.map { "\($0)%" } ?? "--%"
    }

    @MainActor
    static func build(tool: Tool, appStore: AppStore, hiddenAGEmailsRaw: String) -> MenuBarPreviewItem {
        switch tool {
        case .codex:
            let account = appStore.syncService?.latestCodexAccounts.first(where: \.isCurrent)
                ?? appStore.syncService?.latestCodexAccounts.first
            let five = account?.limits?.fiveHourWindow?.usedPercent.map { max(0, 100 - Int($0.rounded())) }
            let week = account?.limits?.oneWeekWindow?.usedPercent.map { max(0, 100 - Int($0.rounded())) }
            return MenuBarPreviewItem(tool: .codex, shortLabel: "CX", fiveHourPercent: five, sevenDayPercent: week)
        case .claudeCode:
            let five = appStore.syncService?.latestClaudeUsage?.effectiveRemainingPercent
            let week = appStore.syncService?.latestClaudeUsage?.sevenDay?.utilization.map { max(0, 100 - Int($0.rounded())) }
            return MenuBarPreviewItem(tool: .claudeCode, shortLabel: "CC", fiveHourPercent: five, sevenDayPercent: week)
        case .antigravity:
            let hidden = Set(hiddenAGEmailsRaw.components(separatedBy: ",").filter { !$0.isEmpty })
            let accounts = (appStore.syncService?.latestAntigravityAccounts ?? [])
                .filter { !hidden.contains($0.email) }
            let five = AGAccountQuota.effectiveMenuBarFiveHourPercent(across: accounts)
            let pro = accounts.filter(\.isPaid)
            let target = pro.isEmpty ? accounts : pro
            let week = AGAccountQuota.averageWeeklyGeminiPercent(across: target)
                ?? AGAccountQuota.averageWeekly3PPercent(across: target)
            return MenuBarPreviewItem(tool: .antigravity, shortLabel: "AG", fiveHourPercent: five, sevenDayPercent: week)
        case .copilot:
            let pct = CopilotSnapshot.menuBarRemainingPercent(
                from: appStore.syncService?.latestCopilotSnapshots,
                resetAt: appStore.syncService?.latestCopilotResetAt
            )
            return MenuBarPreviewItem(tool: .copilot, shortLabel: "CP", fiveHourPercent: pct, sevenDayPercent: nil)
        }
    }
}

private struct StatusBarLivePreviewStage: View {
    @Environment(\.colorScheme) private var colorScheme
    let style: String
    let items: [MenuBarPreviewItem]

    var body: some View {
        VStack(spacing: 0) {
            // Simulated macOS Menu Bar Ribbon
            HStack(spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "apple.logo")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.72))
                    Text("OpenPulse")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.78))
                }

                Spacer(minLength: 12)

                // Live OpenPulse Menu Bar Item Highlight
                openPulseStatusItemPreview
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(
                        colorScheme == .dark
                            ? Color.white.opacity(0.16)
                            : Color.white.opacity(0.78),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1)
                    }
                    .animation(.smooth(duration: 0.22), value: style)
                    .animation(.smooth(duration: 0.22), value: items.map(\.tool))

                // Authentic macOS right-side system status icons
                HStack(spacing: 10) {
                    Image(systemName: "wifi")
                        .font(.system(size: 11, weight: .medium))
                    Image(systemName: "battery.100percent")
                        .font(.system(size: 12, weight: .medium))
                    Text(Date().formatted(.dateTime.hour().minute()))
                        .font(.system(size: 11.5, weight: .medium))
                        .monospacedDigit()
                }
                .foregroundStyle(.primary.opacity(0.55))
            }
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(.ultraThinMaterial)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.08))
                    .frame(height: 0.5)
            }

            // Preview Caption Strip over Soft Wallpaper Tint
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                    Text("实时预览")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.78))
                    Text("·")
                        .foregroundStyle(.tertiary)
                    if items.isEmpty {
                        Text("仅显示应用图标")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(items.map(\.tool.displayName).joined(separator: " · "))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if style == "classic", items.count > 2 {
                    Text("经典模式最多显示前 2 项")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2.5)
                        .background(Color.orange.opacity(colorScheme == .dark ? 0.18 : 0.12), in: Capsule())
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 34)
        }
        .background {
            LinearGradient(
                colors: colorScheme == .dark
                    ? [
                        Color(red: 0.14, green: 0.17, blue: 0.28),
                        Color(red: 0.19, green: 0.14, blue: 0.26),
                        Color(red: 0.11, green: 0.19, blue: 0.22)
                    ]
                    : [
                        Color(red: 0.86, green: 0.91, blue: 0.99),
                        Color(red: 0.92, green: 0.89, blue: 0.99),
                        Color(red: 0.86, green: 0.95, blue: 0.93)
                    ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .opacity(colorScheme == .dark ? 0.65 : 0.72)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.09), lineWidth: 0.75)
        }
    }

    @ViewBuilder
    private var openPulseStatusItemPreview: some View {
        if items.isEmpty {
            appIconImage(size: 15)
        } else if style == "compact" {
            HStack(spacing: 10) {
                ForEach(items) { item in
                    HStack(spacing: 3) {
                        toolMenuBarGlyph(item.tool, size: 13)
                        Text(item.fiveHourDisplay)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                    }
                }
            }
        } else if style == "vertical" {
            HStack(spacing: 9) {
                ForEach(items) { item in
                    VStack(spacing: 0.5) {
                        toolMenuBarGlyph(item.tool, size: 9.5)
                        Text(item.fiveHourDisplay)
                            .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                    }
                }
            }
        } else {
            // classic
            HStack(spacing: 6) {
                appIconImage(size: 15)
                if items.count == 1, let item = items.first {
                    if item.tool == .copilot {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(item.shortLabel)
                            Text(item.fiveHourDisplay)
                        }
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("5H \(item.fiveHourDisplay)")
                            Text("7D \(item.sevenDayDisplay)")
                        }
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    }
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(items.prefix(2)) { item in
                            if item.tool == .copilot {
                                Text("\(item.shortLabel) \(item.fiveHourDisplay)")
                            } else {
                                Text("\(item.shortLabel) \(item.fiveHourDisplay) \(item.sevenDayDisplay)")
                            }
                        }
                    }
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                }
            }
        }
    }

    @ViewBuilder
    private func toolMenuBarGlyph(_ tool: Tool, size: CGFloat) -> some View {
        if let nsImage = NSImage(named: tool.menuBarIconName) {
            Image(nsImage: nsImage)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: tool.iconName)
                .font(.system(size: size * 0.85))
        }
    }

    @ViewBuilder
    private func appIconImage(size: CGFloat) -> some View {
        if let nsImage = NSImage(named: "MenuBarIcon") {
            Image(nsImage: nsImage)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: size * 0.85))
        }
    }
}

private struct StatusBarStyleOptionCard<Preview: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let tag: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let preview: () -> Preview
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(
                            isSelected
                                ? Color.accentColor.opacity(colorScheme == .dark ? 0.14 : 0.08)
                                : Color.primary.opacity(colorScheme == .dark ? 0.05 : 0.035)
                        )
                    preview()
                        .foregroundStyle(isSelected ? .primary : .secondary)
                }
                .frame(height: 52)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                        Spacer()
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 124, maxHeight: .infinity, alignment: .topLeading)
            .background(
                isSelected
                    ? Color.accentColor.opacity(colorScheme == .dark ? 0.11 : 0.055)
                    : (isHovered ? Color.primary.opacity(colorScheme == .dark ? 0.045 : 0.025) : Color.primary.opacity(colorScheme == .dark ? 0.025 : 0.014)),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? Color.accentColor.opacity(0.75)
                            : Color.primary.opacity(isHovered ? 0.15 : 0.08),
                        lineWidth: isSelected ? 1.25 : 0.75
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Shared Hotkey Settings

/// Shared by general settings and the menu-bar preferences tab.
struct MenuBarHotkeySettings: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("menubar.hotkey.keyCode") private var hotkeyKeyCode = 0
    @AppStorage("menubar.hotkey.modifiers") private var hotkeyModifiers = 0

    private var hotkeyLabel: String {
        GlobalHotkeyService.displayString(
            keyCode: UInt32(hotkeyKeyCode),
            carbonModifiers: UInt32(hotkeyModifiers)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("激活菜单栏")
                        .font(.system(size: 13, weight: .medium))
                    Text(hotkeyModifiers == 0
                         ? String(localized: "录制快捷键后，可在任何界面激活菜单栏。")
                         : String(localized: "在任何界面按下快捷键即可激活菜单栏"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    if GlobalHotkeyService.shared.isRecording {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 6, height: 6)
                            Text("请按下快捷键…")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1)
                        }

                        Button("取消") { GlobalHotkeyService.shared.stopRecording() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    } else {
                        Button {
                            GlobalHotkeyService.shared.startRecording()
                        } label: {
                            Text(hotkeyModifiers == 0 ? String(localized: "点击录制") : hotkeyLabel)
                                .font(.system(size: 12, weight: .medium, design: hotkeyModifiers == 0 ? .default : .monospaced))
                                .padding(.horizontal, 10)
                                .frame(height: 28)
                                .background(
                                    Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05),
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.75)
                                }
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()

                        if hotkeyModifiers != 0 {
                            Button {
                                hotkeyKeyCode = 0
                                hotkeyModifiers = 0
                                GlobalHotkeyService.shared.apply(keyCode: 0, carbonModifiers: 0)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                            .help("清除快捷键")
                            .accessibilityLabel("清除快捷键")
                        }
                    }
                }
            }

            Divider().opacity(0.5)

            VStack(alignment: .leading, spacing: 10) {
                Text("菜单栏操作快捷键")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 185), spacing: 10)],
                    spacing: 10
                ) {
                    compactShortcutTile(label: "刷新同步", shortcut: "⌘R")
                    compactShortcutTile(label: "打开主窗口", shortcut: "⌘M")
                    compactShortcutTile(label: "设置", shortcut: "⌘,")
                    compactShortcutTile(label: "退出", shortcut: "⌘Q")
                }
            }
        }
        .onDisappear {
            GlobalHotkeyService.shared.stopRecording()
        }
    }

    private func compactShortcutTile(label: LocalizedStringKey, shortcut: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(shortcut)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(
                    Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05),
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Color.primary.opacity(colorScheme == .dark ? 0.04 : 0.025),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }
}

private struct AntigravityDisplayModeSwitcher: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var selection: String
    @Namespace private var thumbNamespace
    @State private var hoveredID: String?

    var body: some View {
        let accent = Tool.antigravity.brandAccentColor(for: colorScheme)
        HStack(spacing: 2) {
            segment(id: "accounts", icon: "list.bullet", title: "逐账号", accent: accent)
            segment(id: "aggregate", icon: "square.stack.3d.up", title: "聚合", accent: accent)
        }
        .padding(3)
        .background(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.055), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08), lineWidth: 0.5)
        }
        .animation(.smooth(duration: 0.22), value: selection)
    }

    private func segment(id: String, icon: String, title: LocalizedStringKey, accent: Color) -> some View {
        let isSelected = selection == id
        let isHovered = hoveredID == id
        return Button {
            selection = id
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isSelected ? accent : (isHovered ? .primary : .secondary))
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? .primary : (isHovered ? .primary : .secondary))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    Capsule()
                        .fill(colorScheme == .dark ? Color.white.opacity(0.16) : Color.white)
                        .overlay {
                            Capsule()
                                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.06), lineWidth: 0.5)
                        }
                        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.07), radius: 2, y: 1)
                        .matchedGeometryEffect(id: "agSettingsModeThumb", in: thumbNamespace)
                } else if isHovered {
                    Capsule()
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.04))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering in
            hoveredID = hovering ? id : (hoveredID == id ? nil : hoveredID)
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
