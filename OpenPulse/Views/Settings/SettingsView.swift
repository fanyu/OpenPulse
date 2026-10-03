import SwiftUI
import SwiftData
import ServiceManagement
import AppKit

struct SettingsView: View {
    private enum DotTextDefaultsKey {
        static let apiKeyRevision = "dot.textAPI.apiKeyRevision"
    }

    @Environment(AppStore.self) private var appStore
    @Environment(\.modelContext) private var modelContext

    @State private var showingClearConfirm = false
    @State private var cachedRecordCounts: (sessions: Int, quotas: Int)?
    @State private var cacheStatus: String?
    @State private var cacheStatusIsError = false
    @AppStorage("app.launchAtLogin") private var launchAtLogin = false
    @State private var launchAtLoginError: String?
    @State private var launchAtLoginNeedsApproval = false
    @AppStorage("app.language") private var appLanguage = "system"
    @State private var showsLanguageRestartNotice = false
    @State private var languageRestartError: String?

    @AppStorage("notifications.enabled") private var notificationsEnabled = false
    @AppStorage("notifications.threshold") private var notificationThreshold = 10
    @AppStorage("codex.smartSwitch.enabled") private var codexSmartSwitchEnabled = false

    @AppStorage("dot.textAPI.enabled") private var dotTextAPIEnabled = false
    @AppStorage("dot.textAPI.deviceID") private var dotTextAPIDeviceID = ""
    @AppStorage("dot.textAPI.taskKey") private var dotTextAPITaskKey = ""
    @State private var dotTextAPIKey = ""
    @State private var dotTextAPIStatus: String?

    private var cacheIsBusy: Bool {
        guard let service = appStore.syncService else { return false }
        return service.isSyncingActive || !service.refreshingAntigravityAccountEmails.isEmpty
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    private func bumpDotAPIKeyRevision() {
        let defaults = UserDefaults.standard
        defaults.set(
            defaults.integer(forKey: DotTextDefaultsKey.apiKeyRevision) + 1,
            forKey: DotTextDefaultsKey.apiKeyRevision
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("设置")
                        .font(.system(size: 28, weight: .semibold))
                    Text("管理应用偏好、通知与数据。")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                SettingsCard(title: "通用") {
                    VStack(alignment: .leading, spacing: 20) {
                        SettingsToggleRow(
                            title: "开机自动启动",
                            detail: "在登录 Mac 时自动运行 OpenPulse",
                            isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) })
                        )
                        if let launchAtLoginError {
                            Text(launchAtLoginError)
                                .font(.system(size: 12))
                                .foregroundStyle(.red)
                        }
                        if launchAtLoginNeedsApproval {
                            HStack(spacing: 12) {
                                Text("请在系统设置中允许 OpenPulse 登录时启动。")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 12)
                                Button("打开系统设置") {
                                    SMAppService.openSystemSettingsLoginItems()
                                }
                                .buttonStyle(.bordered)
                            }
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 10) {
                            Text("语言")
                                .font(.system(size: 13, weight: .medium))
                            Text("选择 OpenPulse 的显示语言。更改后需要重启应用。")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Picker("语言", selection: $appLanguage) {
                                Text("跟随系统").tag("system")
                                Text("English").tag("en")
                                Text("简体中文").tag("zh-Hans")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(maxWidth: 320)
                            .onChange(of: appLanguage) { _, newValue in
                                applyLanguagePreference(newValue)
                            }

                            if showsLanguageRestartNotice {
                                HStack(spacing: 12) {
                                    Text("语言将在重启 OpenPulse 后生效。")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                    Spacer(minLength: 12)
                                    Button("立即重启") { relaunchApp() }
                                        .buttonStyle(.bordered)
                                }
                            }
                            if let languageRestartError {
                                Text(languageRestartError)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }

                SettingsCard(title: "快捷键") {
                    MenuBarHotkeySettings()
                }

                SettingsCard(title: "Codex") {
                    SettingsToggleRow(
                        title: "启用智能切换",
                        detail: "开启后，菜单栏会显示「智能切换」入口；后台监测到当前 Codex 账号 5h/7d 配额耗尽时，会自动切换到更优账号并重启 Codex。",
                        isOn: $codexSmartSwitchEnabled
                    )
                }

                SettingsCard(title: "Dot Text API") {
                    VStack(alignment: .leading, spacing: 18) {
                        SettingsToggleRow(
                            title: "Auto push quota",
                            detail: "Push only Codex and Claude quota from the menu bar snapshot after sync finishes.",
                            isOn: $dotTextAPIEnabled
                        )

                        if dotTextAPIEnabled {
                            Divider()
                            VStack(alignment: .leading, spacing: 14) {
                                SettingsTextField(title: "Device serial number", text: $dotTextAPIDeviceID)
                                SettingsTextField(title: "Task key (optional)", text: $dotTextAPITaskKey)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("API key")
                                        .font(.system(size: 12, weight: .medium))
                                    SecureField("API key", text: $dotTextAPIKey)
                                        .textFieldStyle(.roundedBorder)
                                }
                                HStack(spacing: 12) {
                                    Button("Save API Key") { saveDotTextAPIKey() }
                                        .buttonStyle(.bordered)
                                    if let dotTextAPIStatus {
                                        Text(dotTextAPIStatus)
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .frame(maxWidth: 460, alignment: .leading)
                        }
                    }
                }

                SettingsCard(title: "通知") {
                    VStack(alignment: .leading, spacing: 18) {
                        SettingsToggleRow(
                            title: "配额不足提醒",
                            detail: "当任意工具的配额低于设定阈值时，发送系统通知提醒",
                            isOn: $notificationsEnabled
                        )
                        if notificationsEnabled {
                            Divider()
                            Stepper(value: $notificationThreshold, in: 5...50, step: 5) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("提醒阈值")
                                        .font(.system(size: 13, weight: .medium))
                                    Text("低于 \(notificationThreshold)% 时提醒")
                                        .font(.system(size: 12))
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: 360)
                        }
                    }
                }

                SettingsCard(title: "数据与存储") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 20) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("已缓存数据")
                                    .font(.system(size: 13, weight: .medium))
                                if let counts = cachedRecordCounts {
                                    Text("共 \(counts.sessions) 条会话记录，\(counts.quotas) 条配额快照")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                } else {
                                    ProgressView().controlSize(.small)
                                }
                            }
                            Spacer(minLength: 12)
                            Button("清除所有缓存", role: .destructive) {
                                showingClearConfirm = true
                            }
                            .buttonStyle(.bordered)
                            .disabled(cacheIsBusy)
                        }
                        if cacheIsBusy {
                            Text("同步完成后可清除缓存。")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        if let cacheStatus {
                            Text(cacheStatus)
                                .font(.system(size: 12))
                                .foregroundStyle(cacheStatusIsError ? Color.red : .secondary)
                        }
                    }
                }

                SettingsCard(title: "关于") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("OpenPulse")
                                .font(.system(size: 15, weight: .semibold))
                            Spacer()
                            Text("版本 \(appVersion) (Build \(appBuild))")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Divider()
                        Text("会话与历史用量保存在本地 Mac。额度摘要可通过 iCloud 同步至 iPhone，并可按设置推送至 Dot Text API。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .navigationTitle("设置")
        .onAppear {
            readLaunchAtLoginStatus()
            refreshCacheCounts()
            dotTextAPIKey = (try? KeychainService.retrieve(key: KeychainService.Keys.dotAPIKey)) ?? ""
        }
        .onChange(of: appStore.syncService?.dataRevision) { _, _ in refreshCacheCounts() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            readLaunchAtLoginStatus()
        }
        .confirmationDialog("清除所有已缓存的会话、用量与配额数据？此操作不可撤销。", isPresented: $showingClearConfirm) {
            Button("清除", role: .destructive) { clearData() }
            Button("取消", role: .cancel) {}
        }
    }

    private func refreshCacheCounts() {
        do {
            cachedRecordCounts = (
                sessions: try modelContext.fetchCount(FetchDescriptor<SessionRecord>()),
                quotas: try modelContext.fetchCount(FetchDescriptor<QuotaRecord>())
            )
        } catch {
            cachedRecordCounts = nil
            cacheStatus = error.localizedDescription
            cacheStatusIsError = true
        }
    }

    private func clearData() {
        do {
            try appStore.clearUsageCache()
            cacheStatus = String(localized: "已清除会话、用量与配额缓存")
            cacheStatusIsError = false
            refreshCacheCounts()
        } catch {
            cacheStatus = error.localizedDescription
            cacheStatusIsError = true
        }
    }

    private func readLaunchAtLoginStatus() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        launchAtLoginNeedsApproval = status == .requiresApproval
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        readLaunchAtLoginStatus()
    }

    private func applyLanguagePreference(_ language: String) {
        if language == "system" {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([language], forKey: "AppleLanguages")
        }
        UserDefaults.standard.synchronize()
        showsLanguageRestartNotice = true
    }

    private func relaunchApp() {
        languageRestartError = nil
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { application, error in
            let didLaunch = application != nil
            let errorMessage = error?.localizedDescription
            Task { @MainActor in
                if let errorMessage {
                    languageRestartError = errorMessage
                } else if didLaunch {
                    NSApp.terminate(nil)
                } else {
                    languageRestartError = String(localized: "无法重新启动 OpenPulse。请手动重新打开应用。")
                }
            }
        }
    }

    private func saveDotTextAPIKey() {
        let trimmedKey = dotTextAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmedKey.isEmpty {
                KeychainService.delete(key: KeychainService.Keys.dotAPIKey)
                bumpDotAPIKeyRevision()
                dotTextAPIKey = ""
                dotTextAPIStatus = String(localized: "API key removed")
            } else {
                try KeychainService.store(key: KeychainService.Keys.dotAPIKey, value: trimmedKey)
                bumpDotAPIKeyRevision()
                dotTextAPIKey = trimmedKey
                dotTextAPIStatus = String(localized: "API key saved")
            }
        } catch {
            dotTextAPIStatus = error.localizedDescription
        }
    }
}

// MARK: - Shortcut Row

struct ShortcutRow: View {
    let label: LocalizedStringKey
    let shortcut: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Text(shortcut)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

// MARK: - Shared settings presentation

struct SettingsCard<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DashboardSectionTitle(title: title, subtitle: subtitle)
            content()
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .dashboardSurface()
        }
    }
}

private struct SettingsToggleRow: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}

private struct SettingsTextField: View {
    let title: LocalizedStringKey
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
            TextField(title, text: $text)
                .textFieldStyle(.roundedBorder)
        }
    }
}
