import SwiftUI
import SwiftData
import ServiceManagement

struct SettingsView: View {
    @Environment(AppStore.self) private var appStore
    @Query(sort: \QuotaRecord.updatedAt, order: .reverse) private var quotaRecords: [QuotaRecord]
    @Query(sort: \SessionRecord.startedAt, order: .reverse) private var sessionRecords: [SessionRecord]
    @Environment(\.modelContext) private var modelContext

    @State private var showingClearConfirm = false
    @AppStorage("app.launchAtLogin") private var launchAtLogin = false

    // MARK: - Menubar display
    @AppStorage("menubar.toolOrder")        private var toolOrderRaw = Tool.defaultOrderRaw
    @AppStorage("menubar.hiddenTools")      private var hiddenToolsRaw = ""
    @AppStorage("menubar.syncIntervalGlobal") private var globalInterval: Double = 0

    // MARK: - Hotkey
    @AppStorage("menubar.hotkey.keyCode")    private var hotkeyKeyCode    = 0
    @AppStorage("menubar.hotkey.modifiers")  private var hotkeyModifiers  = 0

    private var hotkeyLabel: String {
        GlobalHotkeyService.displayString(
            keyCode: UInt32(hotkeyKeyCode),
            carbonModifiers: UInt32(hotkeyModifiers)
        )
    }

    // MARK: - Notifications
    @AppStorage("notifications.enabled")   private var notificationsEnabled = false
    @AppStorage("notifications.threshold") private var notificationThreshold = 10

    // MARK: - Codex
    @AppStorage("codex.smartSwitch.enabled") private var codexSmartSwitchEnabled = false

    // MARK: - Computed helpers

    private var orderedTools: [Tool] {
        let order = toolOrderRaw.components(separatedBy: ",").compactMap { Tool(rawValue: $0) }
        return order + Tool.allCases.filter { !order.contains($0) }
    }

    private var hiddenTools: Set<String> {
        Set(hiddenToolsRaw.components(separatedBy: ",").filter { !$0.isEmpty })
    }

    private var isGlobalMode: Bool { globalInterval > 0 }

    private func syncInterval(for tool: Tool) -> Double {
        let v = UserDefaults.standard.double(forKey: DataSyncService.intervalKey(for: tool))
        return v > 0 ? v : DataSyncService.defaultInterval(for: tool)
    }

    private func setSyncInterval(_ interval: Double, for tool: Tool) {
        UserDefaults.standard.set(interval, forKey: DataSyncService.intervalKey(for: tool))
        appStore.syncService?.rescheduleTimer(for: tool, interval: interval)
    }

    private func applyGlobalInterval(_ interval: Double) {
        for tool in Tool.allCases { setSyncInterval(interval, for: tool) }
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

    // MARK: - View Layout
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // 通用设置
                SettingsCard(title: "通用", icon: "gearshape") {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("开机自动启动")
                                .font(.body)
                            Text("在登录 Mac 时自动运行 OpenPulse")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $launchAtLogin)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }
                
                // 菜单栏设置
                SettingsCard(title: "菜单栏显示", icon: "menubar.rectangle") {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("全局刷新间隔")
                                    .font(.body)
                                Text("统一设置所有助手的数据同步频率")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Picker("", selection: $globalInterval) {
                                Text("自定义").tag(0.0)
                                Text("1 分钟").tag(60.0)
                                Text("5 分钟").tag(300.0)
                                Text("10 分钟").tag(600.0)
                                Text("30 分钟").tag(1800.0)
                                Text("1 小时").tag(3600.0)
                            }
                            .frame(width: 120)
                            .onChange(of: globalInterval) { _, newValue in
                                if newValue > 0 { applyGlobalInterval(newValue) }
                            }
                        }
                        
                        Divider()
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("工具排序与独立设置")
                                .font(.subheadline.weight(.medium))
                            Text("拖拽列表调整菜单栏中的显示顺序；统一间隔选「自定义」后可单独设置每个工具的刷新频率。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            
                            List {
                                ForEach(orderedTools, id: \.self) { tool in
                                    HStack(spacing: 12) {
                                        ToolLogoImage(tool: tool, size: 24)
                                        Text(tool.displayName)
                                            .font(.body)
                                        Spacer()
                                        
                                        Picker("", selection: Binding(
                                            get: { syncInterval(for: tool) },
                                            set: { setSyncInterval($0, for: tool) }
                                        )) {
                                            Text("1m").tag(60.0)
                                            Text("5m").tag(300.0)
                                            Text("10m").tag(600.0)
                                            Text("30m").tag(1800.0)
                                            Text("1h").tag(3600.0)
                                        }
                                        .frame(width: 70)
                                        .disabled(isGlobalMode)
                                        
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
                
                // 快捷键
                SettingsCard(title: "快捷键", icon: "keyboard") {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("激活菜单栏")
                                    .font(.body)
                                Text(hotkeyKeyCode == 0
                                     ? "点击右侧按钮录制，可在任何界面通过快捷键激活菜单栏"
                                     : "在任何界面按下快捷键即可激活菜单栏")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()

                            let isRecording = GlobalHotkeyService.shared.isRecording
                            HStack(spacing: 8) {
                                if isRecording {
                                    Text("请按下快捷键…")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))

                                    Button("取消") { GlobalHotkeyService.shared.stopRecording() }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Button(action: { GlobalHotkeyService.shared.startRecording() }) {
                                        Text(hotkeyKeyCode == 0 ? "点击录制" : hotkeyLabel)
                                            .font(.subheadline.monospaced())
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                                    }
                                    .buttonStyle(.plain)

                                    if hotkeyKeyCode != 0 {
                                        Button(action: {
                                            hotkeyKeyCode = 0
                                            hotkeyModifiers = 0
                                            GlobalHotkeyService.shared.apply(keyCode: 0, carbonModifiers: 0)
                                        }) {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            Text("菜单栏操作快捷键")
                                .font(.subheadline.weight(.medium))

                            VStack(spacing: 6) {
                                ShortcutRow(label: "刷新同步", shortcut: "⌘R")
                                ShortcutRow(label: "打开主窗口", shortcut: "⌘O")
                                ShortcutRow(label: "设置", shortcut: "⌘,")
                                ShortcutRow(label: "退出", shortcut: "⌘Q")
                            }
                        }
                    }
                }

                SettingsCard(title: "Codex", icon: "arrow.triangle.2.circlepath") {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("启用智能切换")
                                .font(.body)
                            Text("开启后，菜单栏会显示「智能切换」入口；后台监测到当前 Codex 账号 5h/7d 配额耗尽时，会自动切换到更优账号并重启 Codex。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $codexSmartSwitchEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }
                
                // 通知
                SettingsCard(title: "通知", icon: "bell.badge") {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("配额不足提醒")
                                    .font(.body)
                                Text("当任意工具的配额低于设定阈值时，发送系统通知提醒")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $notificationsEnabled)
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }
                        
                        if notificationsEnabled {
                            Divider()
                            HStack {
                                Text("提醒阈值")
                                    .font(.body)
                                Spacer()
                                Stepper(
                                    value: $notificationThreshold,
                                    in: 5...50,
                                    step: 5
                                ) {
                                    Text("低于 \(notificationThreshold)% 时提醒")
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                
                // 数据与存储
                SettingsCard(title: "数据与存储", icon: "externaldrive") {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("已缓存数据")
                                    .font(.body)
                                Text("共 \(sessionRecords.count) 条会话记录，\(quotaRecords.count) 条配额快照")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("清除所有缓存", role: .destructive) {
                                showingClearConfirm = true
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                        }
                    }
                }
                
                // 关于
                SettingsCard(title: "关于", icon: "info.circle") {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("OpenPulse")
                                .font(.body.weight(.semibold))
                            Text("版本 1.0 (Build 1)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("数据隐私安全")
                                .font(.caption.weight(.medium))
                            Text("所有数据均保存在本地 Mac 上\n无遥测，无云同步")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
            }
            .padding(24)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .navigationTitle("设置")
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        .confirmationDialog("清除所有已缓存的会话和配额数据？此操作不可撤销。",
                            isPresented: $showingClearConfirm) {
            Button("清除", role: .destructive) { clearData() }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - Private

    private func clearData() {
        quotaRecords.forEach { modelContext.delete($0) }
        sessionRecords.forEach { modelContext.delete($0) }
        try? modelContext.save()
    }
}

// MARK: - Shortcut Row

private struct ShortcutRow: View {
    let label: String
    let shortcut: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(shortcut)
                .font(.caption.monospaced())
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

// MARK: - Settings Card
private struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .font(.headline)
            }
            
            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}
