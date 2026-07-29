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
