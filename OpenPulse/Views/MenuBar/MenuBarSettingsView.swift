import SwiftUI

struct MenuBarSettingsView: View {
    @AppStorage("menubar.toolOrder")        private var toolOrderRaw = Tool.defaultOrderRaw
    @AppStorage("menubar.hiddenTools")      private var hiddenToolsRaw = ""
    @AppStorage("menubar.titleQuotaTools")  private var titleQuotaToolsRaw = ""
    @AppStorage("menubar.antigravityDisplayMode") private var antigravityDisplayMode = "accounts"
    @AppStorage("menubar.displayStyle") private var displayStyle = "compact"

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
                VStack(alignment: .leading, spacing: 8) {
                    Text("菜单栏设置")
                        .font(.system(size: 28, weight: .semibold))
                    Text("安排工具顺序、额度摘要与快捷键。")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                SettingsCard(title: "菜单栏控制") {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("状态栏样式")
                                .font(.system(size: 13, weight: .medium))
                            Text("横向紧凑展示图标与 5h 余量；竖向紧凑上下堆叠以节省状态栏空间；经典模式显示应用图标与 5H/7D 摘要。")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Picker("状态栏样式", selection: $displayStyle) {
                                Text("精简横向").tag("compact")
                                Text("精简竖向").tag("vertical")
                                Text("经典模式").tag("classic")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            Text("菜单栏标题额度")
                                .font(.system(size: 13, weight: .medium))
                            Text("选择后会在菜单栏直接显示该 Agent 的余量摘要；单个工具显示 5H/7D，两项工具时每行显示一个工具。")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)

                            ForEach(menuBarTitleQuotaTools, id: \.self) { tool in
                                HStack(spacing: 12) {
                                    ToolLogoImage(tool: tool, size: 20)
                                    Text(tool.displayName)
                                        .font(.system(size: 13))
                                    Spacer()
                                    Toggle(tool.displayName, isOn: Binding(
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
                                .font(.system(size: 13, weight: .medium))
                            Text("开启后在 Menu Bar 中合并所有 Pro 账号额度，按模型（Gemini/3P）计算平均剩余量与最早重置时间。")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)

                            Picker("Antigravity 展示方式", selection: $antigravityDisplayMode) {
                                Text("逐账号").tag("accounts")
                                Text("聚合 Pro 账号").tag("aggregate")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }

                    }
                }

                SettingsCard(title: "工具排序与显示", subtitle: "拖拽列表调整菜单栏中的显示顺序，并控制是否在菜单栏中显示。") {
                    List {
                        ForEach(orderedTools, id: \.self) { tool in
                            HStack(spacing: 12) {
                                Image(systemName: "line.3.horizontal")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                ToolLogoImage(tool: tool, size: 24)
                                Text(tool.displayName)
                                    .font(.system(size: 13))
                                Spacer()
                                Toggle(tool.displayName, isOn: Binding(
                                    get: { !hiddenTools.contains(tool.rawValue) },
                                    set: { setToolHidden(tool, !$0) }
                                ))
                                .toggleStyle(.switch)
                                .labelsHidden()
                            }
                            .frame(minHeight: 44)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .listRowBackground(Color.clear)
                        }
                        .onMove(perform: moveTools)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .frame(height: CGFloat(orderedTools.count) * 48 + 8)
                    .scrollDisabled(true)
                }

                SettingsCard(title: "快捷键") {
                    MenuBarHotkeySettings()
                }
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .navigationTitle("菜单栏设置")
    }
}

/// Shared by general settings and the menu-bar preferences tab.
struct MenuBarHotkeySettings: View {
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
            VStack(alignment: .leading, spacing: 10) {
                Text("激活菜单栏")
                    .font(.system(size: 13, weight: .medium))
                Text(hotkeyModifiers == 0
                     ? String(localized: "录制快捷键后，可在任何界面激活菜单栏。")
                     : String(localized: "在任何界面按下快捷键即可激活菜单栏"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    if GlobalHotkeyService.shared.isRecording {
                        Text("请按下快捷键…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Button("取消") { GlobalHotkeyService.shared.stopRecording() }
                            .buttonStyle(.bordered)
                    } else {
                        Button(action: { GlobalHotkeyService.shared.startRecording() }) {
                            Text(hotkeyModifiers == 0 ? String(localized: "点击录制") : hotkeyLabel)
                                .font(.system(size: 12, design: .monospaced))
                        }
                        .buttonStyle(.bordered)

                        if hotkeyModifiers != 0 {
                            Button("清除快捷键", systemImage: "xmark") {
                                hotkeyKeyCode = 0
                                hotkeyModifiers = 0
                                GlobalHotkeyService.shared.apply(keyCode: 0, carbonModifiers: 0)
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("菜单栏操作快捷键")
                    .font(.system(size: 13, weight: .medium))
                ShortcutRow(label: "刷新同步", shortcut: "⌘R")
                ShortcutRow(label: "打开主窗口", shortcut: "⌘M")
                ShortcutRow(label: "设置", shortcut: "⌘,")
                ShortcutRow(label: "退出", shortcut: "⌘Q")
            }
        }
        .onDisappear {
            GlobalHotkeyService.shared.stopRecording()
        }
    }
}
