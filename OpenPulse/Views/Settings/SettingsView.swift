import SwiftUI
import SwiftData
import ServiceManagement
import UserNotifications
import AppKit

struct SettingsView: View {
    private enum DotTextDefaultsKey {
        static let apiKeyRevision = "dot.textAPI.apiKeyRevision"
    }

    private enum LaunchAtLoginState: Equatable {
        case enabled
        case requiresApproval
        case notRegistered
        case unavailable
    }

    private struct CacheCounts: Equatable {
        let sessions: Int
        let dailyStats: Int
        let quotas: Int
    }

    /// Snapshot of the language preference active when this process launched,
    /// so switching tabs preserves the pending-restart banner and reverting clears it.
    private static let launchLanguage: String = resolvedAppleLanguage()

    private static let thresholdPresets: [Int] = [5, 10, 15, 20, 30, 50]

    @Environment(AppStore.self) private var appStore
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme

    @State private var showingClearConfirm = false
    @State private var cachedRecordCounts: CacheCounts?
    @State private var cacheStatus: String?
    @State private var cacheStatusIsError = false

    @AppStorage("app.launchAtLogin") private var launchAtLogin = false
    @State private var launchAtLoginState: LaunchAtLoginState = .notRegistered
    @State private var launchAtLoginError: String?

    @AppStorage("app.language") private var appLanguage = "system"
    @State private var languageRestartError: String?

    @AppStorage("notifications.enabled") private var notificationsEnabled = false
    @AppStorage("notifications.threshold") private var notificationThreshold = 10
    @State private var notificationAuthStatus: UNAuthorizationStatus = .notDetermined
    @State private var notificationStatusMessage: String?
    @State private var notificationStatusIsError = false
    @State private var isSendingTestNotification = false

    @AppStorage("menubar.toolOrder") private var toolOrderRaw = Tool.defaultOrderRaw
    @AppStorage(DataSyncService.localFileWatchEnabledKey) private var localFileWatchEnabled = true
    @State private var pollIntervalRevision: UInt64 = 0
    @State private var hoveredTool: Tool?

    @AppStorage("dot.textAPI.enabled") private var dotTextAPIEnabled = false
    @AppStorage("dot.textAPI.deviceID") private var dotTextAPIDeviceID = ""
    @AppStorage("dot.textAPI.taskKey") private var dotTextAPITaskKey = ""
    @State private var dotTextAPIKey = ""
    @State private var savedDotTextAPIKey = ""
    @State private var dotTextAPIStatus: String?
    @State private var dotTextAPIStatusIsError = false
    @State private var isTestingDotTextPush = false

    // Session Sources state (format-based auto-discovery & custom directories)
    @State private var sessionSources: [SessionSourceEntry] = []
    @State private var isRediscoveringSources = false
    @State private var sessionSourcesStatus: String?
    @State private var sessionSourcesStatusIsError = false
    @State private var isWide = true

    private var cacheIsBusy: Bool {
        guard let service = appStore.syncService else { return false }
        return service.hasAnyRefreshInFlight || !service.refreshingAntigravityAccountEmails.isEmpty
    }

    private var orderedTools: [Tool] {
        Tool.orderedTools(from: toolOrderRaw)
    }

    private var needsLanguageRestart: Bool {
        appLanguage != Self.launchLanguage
    }

    private var hasCustomPollIntervals: Bool {
        _ = pollIntervalRevision
        return Tool.allCases.contains { tool in
            let current = appStore.syncService?.currentPollInterval(for: tool)
                ?? DataSyncService.pollInterval(for: tool)
            return current != (DataSyncService.defaultPollInterval[tool] ?? 300)
        }
    }

    private var dotTextHasSavedKey: Bool {
        !savedDotTextAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var dotTextKeyHasUnsavedChanges: Bool {
        dotTextAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            != savedDotTextAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var dotTextIsConfigured: Bool {
        !dotTextAPIDeviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && dotTextHasSavedKey
    }

    private func pollIntervalBinding(for tool: Tool) -> Binding<TimeInterval> {
        Binding(
            get: {
                _ = pollIntervalRevision
                return appStore.syncService?.currentPollInterval(for: tool)
                    ?? DataSyncService.pollInterval(for: tool)
            },
            set: { newValue in
                if let service = appStore.syncService {
                    service.setPollInterval(newValue, for: tool)
                } else {
                    let normalized = DataSyncService.normalizedPollInterval(newValue, for: tool)
                    UserDefaults.standard.set(normalized, forKey: DataSyncService.pollIntervalKey(for: tool))
                }
                pollIntervalRevision &+= 1
            }
        )
    }

    private func pollIntervalOptionsIncludingCurrent(for tool: Tool, current: TimeInterval) -> [TimeInterval] {
        var options = DataSyncService.pollIntervalOptions(for: tool)
        if !options.contains(current) {
            if let manualIndex = options.firstIndex(of: 0) {
                options.insert(current, at: manualIndex)
            } else {
                options.append(current)
            }
        }
        return options
    }

    private func pollIntervalLabel(_ seconds: TimeInterval) -> String {
        if seconds <= 0 {
            return String(localized: "仅手动")
        }
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes >= 60, minutes % 60 == 0 {
            let hours = minutes / 60
            return hours == 1
                ? String(localized: "1 小时")
                : String(localized: "\(hours) 小时")
        }
        return String(localized: "\(minutes) 分钟")
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

    static func resolvedAppleLanguage(
        defaults: UserDefaults = .standard,
        domainName: String? = Bundle.main.bundleIdentifier
    ) -> String {
        // Read only the app's persistent domain so NSGlobalDomain.AppleLanguages
        // does not masquerade as an explicit per-app override when set to "system".
        guard let domainName,
              let languages = defaults.persistentDomain(forName: domainName)?["AppleLanguages"] as? [String],
              let preferred = languages.first else {
            return "system"
        }
        if preferred == "en" || preferred.hasPrefix("en-") {
            return "en"
        }
        if preferred == "zh-Hans" || preferred.hasPrefix("zh-Hans-") {
            return "zh-Hans"
        }
        return "system"
    }

    var body: some View {
        @Bindable var store = appStore
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                // Page Header (aligned with Quota, Overview, Activity, Providers, MenuBarSettings)
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("设置")
                            .font(.system(size: 28, weight: .semibold))
                            .tracking(-0.4)
                        Text("管理应用偏好、同步周期、外部集成与诊断日志。")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }

                    SettingsSectionSwitcher(selection: $store.selectedSettingsSection)
                }

                Group {
                    switch store.selectedSettingsSection {
                    case .general:
                        generalSection
                    case .sync:
                        syncAndIntegrationsSection
                    case .diagnostics:
                        diagnosticsSection
                    }
                }
                .id(store.selectedSettingsSection)
                .transition(.opacity)
            }
            .frame(maxWidth: 1120, alignment: .leading)
            .padding(.horizontal, isWide ? 28 : 20)
            .padding(.top, 8)
            .padding(.bottom, 26)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollEdgeEffectStyle(.soft, for: .vertical)
        .onGeometryChange(for: Bool.self) { proxy in
            proxy.size.width >= 760
        } action: { next in
            if isWide != next { isWide = next }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .navigationTitle("设置")
        .onAppear {
            readLaunchAtLoginStatus()
            syncLanguageFromSystemDefaults()
            refreshCacheCounts()
            loadDotTextAPIKey()
            reloadSessionSourceList()
            Task { await refreshNotificationAuthStatus() }
        }
        .onChange(of: appStore.syncService?.dataRevision) { _, _ in
            refreshCacheCounts()
        }
        .onChange(of: appStore.selectedSettingsSection) { _, newSection in
            if newSection == .diagnostics {
                refreshCacheCounts()
            } else if newSection == .sync {
                reloadSessionSourceList()
            } else if newSection == .general {
                readLaunchAtLoginStatus()
                Task { await refreshNotificationAuthStatus() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            readLaunchAtLoginStatus()
            Task { await refreshNotificationAuthStatus() }
        }
        .confirmationDialog("清除所有已缓存的会话、用量与配额数据？此操作不可撤销。", isPresented: $showingClearConfirm) {
            Button("清除", role: .destructive) { clearData() }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - Section 1: General

    @ViewBuilder
    private var generalSection: some View {
        // Card 1: Startup & Language
        VStack(alignment: .leading, spacing: 14) {
            DashboardSectionTitle(
                title: "启动与语言",
                subtitle: "管理登录自启动状态与应用界面语言。"
            )

            VStack(spacing: 0) {
                // Launch at Login Row
                SettingsHoverRow {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .center, spacing: 14) {
                            SettingsIconWell(systemName: "power.circle.fill", tint: .accentColor)

                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 8) {
                                    Text("开机自动启动")
                                        .font(.system(size: 13, weight: .medium))
                                    launchAtLoginStatusBadge
                                }
                                Text("在登录 Mac 时自动运行 OpenPulse")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 12)

                            Toggle("开机自动启动", isOn: Binding(
                                get: { launchAtLoginState == .enabled || launchAtLoginState == .requiresApproval },
                                set: { setLaunchAtLogin($0) }
                            ))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                            .disabled(launchAtLoginState == .unavailable)
                        }

                        if let launchAtLoginError {
                            SettingsInlineBanner(
                                style: .error,
                                message: launchAtLoginError
                            )
                        }

                        if launchAtLoginState == .requiresApproval {
                            SettingsInlineBanner(
                                style: .warning,
                                message: String(localized: "请在系统设置中允许 OpenPulse 登录时启动。"),
                                actionTitle: String(localized: "打开系统设置")
                            ) {
                                SMAppService.openSystemSettingsLoginItems()
                            }
                        }
                    }
                }

                Divider()
                    .opacity(0.45)
                    .padding(.leading, 20)

                // Language Row
                SettingsHoverRow {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .center, spacing: 14) {
                            SettingsIconWell(systemName: "globe", tint: .blue)

                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 8) {
                                    Text("语言")
                                        .font(.system(size: 13, weight: .medium))
                                    if needsLanguageRestart {
                                        SettingsStatusBadge(
                                            text: String(localized: "待重启生效"),
                                            tint: .orange,
                                            showDot: true
                                        )
                                    }
                                }
                                Text("选择 OpenPulse 的显示语言。更改后需要重启应用。")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 12)

                            SettingsLanguageSwitcher(
                                selection: Binding(
                                    get: { appLanguage },
                                    set: { newValue in
                                        appLanguage = newValue
                                        applyLanguagePreference(newValue)
                                    }
                                )
                            )
                        }

                        if needsLanguageRestart {
                            SettingsInlineBanner(
                                style: .info,
                                message: String(localized: "语言将在重启 OpenPulse 后生效。"),
                                actionTitle: String(localized: "立即重启")
                            ) {
                                relaunchApp()
                            }
                        }

                        if let languageRestartError {
                            SettingsInlineBanner(
                                style: .error,
                                message: languageRestartError
                            )
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .dashboardSurface()
        }

        // Card 2: Notifications
        VStack(alignment: .leading, spacing: 14) {
            DashboardSectionTitle(
                title: "通知提醒",
                subtitle: "当工具配额低于阈值时发送 macOS 系统通知（每工具每小时最多提醒一次）。"
            )

            VStack(spacing: 0) {
                SettingsHoverRow {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .center, spacing: 14) {
                            SettingsIconWell(systemName: "bell.badge.fill", tint: .orange)

                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 8) {
                                    Text("配额不足提醒")
                                        .font(.system(size: 13, weight: .medium))
                                    notificationStatusBadge
                                }
                                Text("当任意工具的配额低于设定阈值时，发送系统通知提醒")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 12)

                            if notificationsEnabled && notificationAuthStatus != .denied {
                                Button {
                                    Task { await sendTestNotification() }
                                } label: {
                                    HStack(spacing: 5) {
                                        if isSendingTestNotification {
                                            ProgressView().controlSize(.mini)
                                        } else {
                                            Image(systemName: "paperplane")
                                                .font(.system(size: 10.5, weight: .semibold))
                                        }
                                        Text("发送测试")
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(isSendingTestNotification)
                            }

                            Toggle("配额不足提醒", isOn: Binding(
                                get: { notificationsEnabled },
                                set: { enabled in
                                    notificationsEnabled = enabled
                                    notificationStatusMessage = nil
                                    if enabled {
                                        Task { await requestNotificationPermission() }
                                    }
                                }
                            ))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                        }

                        if notificationsEnabled && notificationAuthStatus == .denied {
                            SettingsInlineBanner(
                                style: .warning,
                                message: String(localized: "系统已禁用 OpenPulse 的通知权限，请在系统设置中允许通知。"),
                                actionTitle: String(localized: "打开通知设置")
                            ) {
                                openNotificationSystemSettings()
                            }
                        }

                        if let notificationStatusMessage {
                            SettingsInlineBanner(
                                style: notificationStatusIsError ? .error : .success,
                                message: notificationStatusMessage
                            )
                        }
                    }
                }

                if notificationsEnabled {
                    Divider()
                        .opacity(0.45)
                        .padding(.leading, 20)

                    SettingsHoverRow {
                        HStack(alignment: .center, spacing: 14) {
                            SettingsIconWell(systemName: "gauge.with.needle.fill", tint: .orange)

                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 8) {
                                    Text("提醒阈值")
                                        .font(.system(size: 13, weight: .medium))
                                    SettingsStatusBadge(
                                        text: "< \(notificationThreshold)%",
                                        tint: .orange,
                                        isMonospaced: true
                                    )
                                }
                                Text("低于 \(notificationThreshold)% 时提醒")
                                    .font(.system(size: 12))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 12)

                            HStack(spacing: 6) {
                                ForEach(Self.thresholdPresets, id: \.self) { preset in
                                    let isSelected = notificationThreshold == preset
                                    Button {
                                        withAnimation(.smooth(duration: 0.18)) {
                                            notificationThreshold = preset
                                        }
                                    } label: {
                                        Text("\(preset)%")
                                            .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium, design: .monospaced))
                                            .foregroundStyle(isSelected ? Color.orange : .secondary)
                                            .padding(.horizontal, 9)
                                            .frame(height: 26)
                                            .background(
                                                isSelected
                                                    ? Color.orange.opacity(colorScheme == .dark ? 0.20 : 0.12)
                                                    : Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.035),
                                                in: Capsule()
                                            )
                                            .overlay {
                                                Capsule()
                                                    .strokeBorder(
                                                        isSelected
                                                            ? Color.orange.opacity(0.55)
                                                            : Color.primary.opacity(0.08),
                                                        lineWidth: isSelected ? 1 : 0.5
                                                    )
                                            }
                                            .contentShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .focusEffectDisabled()
                                }

                                Stepper("", value: $notificationThreshold, in: 5...50, step: 5)
                                    .labelsHidden()
                                    .controlSize(.small)
                            }
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .dashboardSurface()
        }
    }

    // MARK: - Section 2: Sync & Integrations

    @ViewBuilder
    private var syncAndIntegrationsSection: some View {
        // Card 1: Sync & Polling Table (aligned with MenuBarSettingsView Tool Table)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom, spacing: 12) {
                DashboardSectionTitle(
                    title: "同步与轮询",
                    subtitle: "按工具自定义后台配额轮询周期；各工具会自动错峰并加入随机抖动，避免同时集中请求。"
                )
                Spacer(minLength: 12)
                if hasCustomPollIntervals {
                    Button("恢复默认频率") {
                        withAnimation(.smooth(duration: 0.2)) {
                            if let service = appStore.syncService {
                                service.resetPollIntervalsToDefaults()
                            } else {
                                for tool in Tool.allCases {
                                    UserDefaults.standard.removeObject(forKey: DataSyncService.pollIntervalKey(for: tool))
                                }
                            }
                            pollIntervalRevision &+= 1
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            VStack(spacing: 0) {
                // Column Header Bar (exact alignment with MenuBarSettingsView)
                HStack(spacing: 12) {
                    Text("工具")
                    Spacer(minLength: 12)
                    Text("状态")
                        .frame(width: 88, alignment: .trailing)
                    Text("下次轮询")
                        .frame(width: 96, alignment: .trailing)
                    Text("轮询周期")
                        .frame(width: 118, alignment: .trailing)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.vertical, 11)
                .background(Color.primary.opacity(colorScheme == .dark ? 0.04 : 0.025))

                Divider().opacity(0.45)

                VStack(spacing: 0) {
                    ForEach(Array(orderedTools.enumerated()), id: \.element) { index, tool in
                        pollToolRow(for: tool)

                        if index < orderedTools.count - 1 {
                            Divider()
                                .opacity(0.45)
                                .padding(.leading, 20)
                        }
                    }
                }

                Divider().opacity(0.45)

                // Footer row: Local File Watch (mirrors Antigravity footer row in MenuBarSettingsView)
                HStack(alignment: .center, spacing: 14) {
                    SettingsIconWell(
                        systemName: "doc.text.magnifyingglass",
                        tint: localFileWatchEnabled ? .green : .secondary
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text("静默监听本地文件变更")
                                .font(.system(size: 13, weight: .medium))
                            SettingsStatusBadge(
                                text: localFileWatchEnabled ? String(localized: "监听中") : String(localized: "已暂停"),
                                tint: localFileWatchEnabled ? .green : .secondary,
                                showDot: localFileWatchEnabled
                            )
                        }
                        Text("自动感知 Claude Code、Codex 与 Antigravity 的本地会话日志更新，仅做本地增量解析，不额外发起网络请求，也不会打断界面状态。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 12)

                    Toggle("静默监听本地文件变更", isOn: Binding(
                        get: { localFileWatchEnabled },
                        set: { enabled in
                            localFileWatchEnabled = enabled
                            appStore.syncService?.setLocalFileWatchEnabled(enabled)
                        }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .dashboardSurface()
        }

        // Card 1.5: Format-based Local Session Sources (Auto-Discovery + Custom Directories)
        localSessionSourcesCard

        // Card 2: External Integrations (Dot Text API)
        VStack(alignment: .leading, spacing: 14) {
            DashboardSectionTitle(
                title: "外部集成",
                subtitle: "可选的第三方硬件与外部推送服务，未开启时不会产生任何请求。"
            )

            VStack(spacing: 0) {
                SettingsHoverRow {
                    HStack(alignment: .center, spacing: 14) {
                        SettingsIconWell(
                            systemName: "dot.radiowaves.left.and.right",
                            tint: dotTextAPIEnabled ? .accentColor : .secondary
                        )

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text("Dot Text 自动推送")
                                    .font(.system(size: 13, weight: .medium))
                                dotTextStatusBadge
                            }
                            Text("同步完成后，自动将菜单栏中的 Codex 与 Claude 额度摘要推送到 Dot 点阵设备。")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 12)

                        Toggle("Dot Text 自动推送", isOn: $dotTextAPIEnabled)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                    }
                }

                if dotTextAPIEnabled {
                    Divider().opacity(0.45)

                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top, spacing: 14) {
                            SettingsRecessedTextField(
                                title: "设备序列号",
                                placeholder: "例如: DOT-XXXXXX",
                                text: $dotTextAPIDeviceID
                            )
                            SettingsRecessedTextField(
                                title: "任务 Key（可选）",
                                placeholder: "留空使用默认任务",
                                text: $dotTextAPITaskKey
                            )
                        }

                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 8) {
                                Text("API Key")
                                    .font(.system(size: 12, weight: .medium))
                                if dotTextKeyHasUnsavedChanges {
                                    SettingsStatusBadge(
                                        text: String(localized: "未保存更改"),
                                        tint: .orange
                                    )
                                } else if dotTextHasSavedKey {
                                    SettingsStatusBadge(
                                        text: String(localized: "已存入钥匙串"),
                                        tint: .green
                                    )
                                } else {
                                    SettingsStatusBadge(
                                        text: String(localized: "未配置"),
                                        tint: .secondary
                                    )
                                }
                            }

                            HStack(spacing: 10) {
                                SecureField("输入 Dot Text API Key", text: $dotTextAPIKey)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 12.5, design: .monospaced))
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 8)
                                    .background(
                                        Color.primary.opacity(colorScheme == .dark ? 0.055 : 0.035),
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    )
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.75)
                                    }

                                Button("保存 API Key") {
                                    saveDotTextAPIKey()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)

                                Button {
                                    Task { await testDotTextPush() }
                                } label: {
                                    HStack(spacing: 5) {
                                        if isTestingDotTextPush {
                                            ProgressView().controlSize(.mini)
                                        } else {
                                            Image(systemName: "paperplane")
                                                .font(.system(size: 11, weight: .semibold))
                                        }
                                        Text("测试推送")
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)
                                .disabled(isTestingDotTextPush || appStore.syncService == nil)
                            }
                        }

                        if let dotTextAPIStatus {
                            SettingsInlineBanner(
                                style: dotTextAPIStatusIsError ? .error : .success,
                                message: dotTextAPIStatus
                            )
                        }
                    }
                    .padding(20)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .dashboardSurface()
        }
    }

    @ViewBuilder
    private var localSessionSourcesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom, spacing: 12) {
                DashboardSectionTitle(
                    title: "本地会话数据源",
                    subtitle: "按引擎日志格式自动探测本机所有外壳（终端、IDE、T3、Orca、Rex 等）的会话目录，支持单独开关或手动添加。"
                )

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    Button {
                        Task { await rediscoverSessionSources() }
                    } label: {
                        HStack(spacing: 5) {
                            if isRediscoveringSources {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 10.5, weight: .semibold))
                            }
                            Text("重新发现")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isRediscoveringSources)

                    Button {
                        addCustomSessionSourceFolder()
                    } label: {
                        Label("添加目录", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            VStack(spacing: 0) {
                if sessionSources.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        Text("尚未发现本地会话目录，点击「重新发现」或「添加目录」开始扫描。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(20)
                } else {
                    ForEach(Array(sessionSources.enumerated()), id: \.element.id) { index, entry in
                        sessionSourceRow(entry)
                        if index < sessionSources.count - 1 {
                            Divider()
                                .opacity(0.45)
                                .padding(.leading, 62)
                        }
                    }
                }

                if let sessionSourcesStatus {
                    Divider().opacity(0.45)
                    SettingsInlineBanner(
                        style: sessionSourcesStatusIsError ? .error : .success,
                        message: sessionSourcesStatus
                    )
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .dashboardSurface()
        }
    }

    @ViewBuilder
    private func sessionSourceRow(_ entry: SessionSourceEntry) -> some View {
        let tint: Color = entry.isEnabled ? formatTintColor(for: entry.format) : .secondary
        SettingsHoverRow {
            HStack(alignment: .center, spacing: 12) {
                SettingsIconWell(systemName: entry.format.systemImage, tint: tint)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(entry.format.displayName)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(entry.isEnabled ? .primary : .secondary)

                        SettingsStatusBadge(
                            text: entry.origin.badgeTitle,
                            tint: entry.origin == .custom ? .accentColor : .secondary
                        )
                    }

                    Text(entry.abbreviatedPath)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(entry.path)
                }

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .background(Color.primary.opacity(colorScheme == .dark ? 0.07 : 0.045), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help("在 Finder 中显示")

                    if entry.origin == .custom {
                        Button(role: .destructive) {
                            removeCustomSessionSource(entry)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.red)
                                .frame(width: 24, height: 24)
                                .background(Color.red.opacity(colorScheme == .dark ? 0.16 : 0.10), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .help("移除自定义目录")
                    }

                    Toggle(entry.abbreviatedPath, isOn: Binding(
                        get: { entry.isEnabled },
                        set: { enabled in
                            toggleSessionSource(entry, isEnabled: enabled)
                        }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                }
            }
        }
    }

    private func formatTintColor(for format: SessionSourceFormat) -> Color {
        switch format {
        case .claudeProjects:   Tool.claudeCode.brandAccentColor(for: colorScheme)
        case .codexHome:        Tool.codex.brandAccentColor(for: colorScheme)
        case .antigravityBrain: Tool.antigravity.brandAccentColor(for: colorScheme)
        case .piAgentSessions:  .accentColor
        }
    }

    private func reloadSessionSourceList() {
        Task.detached(priority: .utility) {
            let entries = SessionSourceRegistry.shared.allEntries()
            await MainActor.run {
                sessionSources = entries
            }
        }
    }

    private func rediscoverSessionSources() async {
        isRediscoveringSources = true
        sessionSourcesStatus = nil
        defer { isRediscoveringSources = false }

        let entries = await Task.detached(priority: .utility) {
            SessionSourceRegistry.shared.rediscover()
        }.value
        sessionSources = entries
        sessionSourcesStatusIsError = false
        sessionSourcesStatus = String(localized: "已完成扫描，共发现 \(entries.count) 个本地会话数据源。")
        await appStore.syncService?.reloadSessionSources(rediscover: false)
    }

    private func toggleSessionSource(_ entry: SessionSourceEntry, isEnabled: Bool) {
        SessionSourceRegistry.shared.setEnabled(isEnabled, for: entry.id)
        sessionSources = SessionSourceRegistry.shared.allEntries()
        Task {
            await appStore.syncService?.reloadSessionSources(rediscover: false)
        }
    }

    private func addCustomSessionSourceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = String(localized: "选择包含 AI 编程工具会话日志的目录（自动识别格式）")
        panel.prompt = String(localized: "添加数据源")

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let added = SessionSourceRegistry.shared.addCustomDirectory(url)
        sessionSources = SessionSourceRegistry.shared.allEntries()
        if added.isEmpty {
            sessionSourcesStatusIsError = true
            sessionSourcesStatus = String(localized: "未在所选目录中识别到受支持的 Claude / Codex / Antigravity / Pi 会话格式。")
        } else {
            sessionSourcesStatusIsError = false
            sessionSourcesStatus = String(localized: "已识别并添加 \(added.count) 个自定义数据源，正在同步会话。")
            Task {
                await appStore.syncService?.reloadSessionSources(rediscover: false)
            }
        }
    }

    private func removeCustomSessionSource(_ entry: SessionSourceEntry) {
        SessionSourceRegistry.shared.removeCustomSource(id: entry.id)
        sessionSources = SessionSourceRegistry.shared.allEntries()
        sessionSourcesStatusIsError = false
        sessionSourcesStatus = String(localized: "已移除自定义数据源：\(entry.abbreviatedPath)")
        Task {
            await appStore.syncService?.reloadSessionSources(rediscover: false)
        }
    }

    @ViewBuilder
    private func pollToolRow(for tool: Tool) -> some View {
        let state = appStore.syncService?.states[tool]
        let nextFire = appStore.syncService?.nextScheduledPollDates[tool]
        let currentInterval = pollIntervalBinding(for: tool).wrappedValue
        let options = pollIntervalOptionsIncludingCurrent(for: tool, current: currentInterval)
        let isHovered = hoveredTool == tool
        let isRefreshing = state?.isUserVisibleRefreshing ?? false
        let isBusy = state?.isRefreshing ?? false
        let brand = tool.brandAccentColor(for: colorScheme)

        HStack(spacing: 12) {
            ToolBrandIconWell(tool: tool, size: 28, iconSize: 17)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tool.displayName)
                        .font(.system(size: 13, weight: .medium))

                    if isHovered || isRefreshing {
                        Button {
                            guard !isBusy else { return }
                            Task { await appStore.syncService?.sync(tool: tool) }
                        } label: {
                            Group {
                                if isRefreshing {
                                    ProgressView()
                                        .controlSize(.mini)
                                        .scaleEffect(0.75)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                            }
                            .frame(width: 20, height: 20)
                            .background(
                                Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05),
                                in: Circle()
                            )
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .focusEffectDisabled()
                        .disabled(isBusy || appStore.syncService == nil)
                        .help("立即同步 \(tool.displayName)")
                        .accessibilityLabel("立即同步 \(tool.displayName)")
                        .transition(.opacity)
                    }
                }

                if let error = state?.lastError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(error)
                } else if let lastSync = state?.lastSyncDate {
                    Text("最近同步于 \(lastSync.formatted(.dateTime.hour().minute()))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Text("等待首次同步")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 12)

            // Sync Status Column
            Group {
                if isRefreshing {
                    SettingsStatusBadge(text: String(localized: "同步中"), tint: brand)
                } else if state?.lastError != nil {
                    SettingsStatusBadge(text: String(localized: "异常"), tint: .orange)
                } else if state?.lastSyncDate != nil {
                    SettingsStatusBadge(text: String(localized: "正常"), tint: brand)
                } else {
                    SettingsStatusBadge(text: String(localized: "待同步"), tint: .secondary)
                }
            }
            .frame(width: 88, alignment: .trailing)

            // Next Poll Column
            Group {
                if currentInterval <= 0 {
                    Text("仅手动")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                } else if let nextFire {
                    Text(nextFire.formatted(.dateTime.hour().minute()))
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(brand)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(brand.opacity(colorScheme == .dark ? 0.16 : 0.10), in: Capsule())
                        .help("下次轮询于 \(nextFire.formatted(date: .omitted, time: .standard))")
                } else {
                    Text("每 \(pollIntervalLabel(currentInterval))")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .frame(width: 96, alignment: .trailing)

            // Poll Interval Picker Column
            Picker(tool.displayName, selection: pollIntervalBinding(for: tool)) {
                ForEach(options, id: \.self) { option in
                    Text(pollIntervalLabel(option)).tag(option)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 118, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 54)
        .background(
            isHovered
                ? Color.primary.opacity(colorScheme == .dark ? 0.035 : 0.022)
                : Color.clear
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                hoveredTool = hovering ? tool : (hoveredTool == tool ? nil : hoveredTool)
            }
        }
    }

    // MARK: - Section 3: Data & Diagnostics

    @ViewBuilder
    private var diagnosticsSection: some View {
        // Card 1: Data & Storage
        VStack(alignment: .leading, spacing: 14) {
            DashboardSectionTitle(
                title: "数据与存储",
                subtitle: "查看本地缓存统计，或重置 SwiftData 与内存快照重新拉取。"
            )

            VStack(alignment: .leading, spacing: 0) {
                // 3-Column Compact Metric Tiles
                HStack(spacing: 12) {
                    SettingsMetricTile(
                        title: "会话记录",
                        value: cachedRecordCounts.map { "\($0.sessions)" },
                        icon: "terminal"
                    )
                    SettingsMetricTile(
                        title: "每日统计",
                        value: cachedRecordCounts.map { "\($0.dailyStats)" },
                        icon: "calendar"
                    )
                    SettingsMetricTile(
                        title: "配额快照",
                        value: cachedRecordCounts.map { "\($0.quotas)" },
                        icon: "chart.pie"
                    )
                }
                .padding(20)

                Divider().opacity(0.45)

                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 14) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("缓存管理")
                                .font(.system(size: 13, weight: .medium))
                            Text(cacheIsBusy
                                 ? String(localized: "同步完成后可清除缓存。")
                                 : String(localized: "清除缓存不会删除原始工具日志，下次同步时将重新导入。"))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 12)

                        Button {
                            Task { await appStore.syncService?.sync() }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 11, weight: .semibold))
                                Text("立即同步")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(cacheIsBusy || appStore.syncService == nil)

                        Button("清除所有缓存", role: .destructive) {
                            showingClearConfirm = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(cacheIsBusy)
                    }

                    if let cacheStatus {
                        SettingsInlineBanner(
                            style: cacheStatusIsError ? .error : .success,
                            message: cacheStatus
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .dashboardSurface()
        }

        // Card 2: System Logs
        SettingsCard(
            title: "系统日志",
            subtitle: "查看运行状态、排查同步异常，并支持搜索与导出。"
        ) {
            EmbeddedLogPanel()
        }

        // Card 3: About (aligned with ProviderHeroCard)
        VStack(alignment: .leading, spacing: 14) {
            DashboardSectionTitle(title: "关于")

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 14) {
                    Group {
                        if let appIcon = NSApp.applicationIconImage {
                            Image(nsImage: appIcon)
                                .resizable()
                                .scaledToFit()
                        } else if let icon = NSImage(named: "MenuBarIcon") {
                            Image(nsImage: icon)
                                .renderingMode(.template)
                                .resizable()
                                .scaledToFit()
                                .padding(8)
                        }
                    }
                    .frame(width: 40, height: 40)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text("OpenPulse")
                                .font(.system(size: 16, weight: .semibold))
                            SettingsStatusBadge(
                                text: "v\(appVersion) (\(appBuild))",
                                tint: .accentColor,
                                isMonospaced: true
                            )
                        }
                        Text("AI 编程助手用量与配额统一监控")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 12)
                }

                Divider().opacity(0.45)

                Text("会话与历史用量保存在本地 Mac。额度摘要可通过 iCloud 同步至 iPhone，并可按设置推送至 Dot Text API。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .dashboardSurface()
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [
                        Color.accentColor.opacity(colorScheme == .dark ? 0.55 : 0.42),
                        Color.accentColor.opacity(0.06)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 2)
                .clipShape(Capsule())
                .padding(.horizontal, 18)
            }
        }
    }

    // MARK: - Status Badges

    @ViewBuilder
    private var launchAtLoginStatusBadge: some View {
        switch launchAtLoginState {
        case .enabled:
            SettingsStatusBadge(text: String(localized: "已启用"), tint: .green, showDot: true)
        case .requiresApproval:
            SettingsStatusBadge(text: String(localized: "待系统批准"), tint: .orange, showDot: true)
        case .notRegistered:
            SettingsStatusBadge(text: String(localized: "未开启"), tint: .secondary)
        case .unavailable:
            SettingsStatusBadge(text: String(localized: "不可用"), tint: .secondary)
        }
    }

    @ViewBuilder
    private var notificationStatusBadge: some View {
        if !notificationsEnabled {
            SettingsStatusBadge(text: String(localized: "未开启"), tint: .secondary)
        } else {
            switch notificationAuthStatus {
            case .authorized, .provisional, .ephemeral:
                SettingsStatusBadge(text: String(localized: "已授权"), tint: .green, showDot: true)
            case .denied:
                SettingsStatusBadge(text: String(localized: "系统已禁用"), tint: .orange, showDot: true)
            case .notDetermined:
                SettingsStatusBadge(text: String(localized: "待授权"), tint: .orange)
            @unknown default:
                SettingsStatusBadge(text: String(localized: "已开启"), tint: .accentColor)
            }
        }
    }

    @ViewBuilder
    private var dotTextStatusBadge: some View {
        if !dotTextAPIEnabled {
            SettingsStatusBadge(text: String(localized: "未开启"), tint: .secondary)
        } else if dotTextIsConfigured {
            SettingsStatusBadge(text: String(localized: "已就绪"), tint: .green, showDot: true)
        } else {
            SettingsStatusBadge(text: String(localized: "待完善"), tint: .orange, showDot: true)
        }
    }

    // MARK: - Actions

    private func refreshCacheCounts() {
        do {
            cachedRecordCounts = CacheCounts(
                sessions: try modelContext.fetchCount(FetchDescriptor<SessionRecord>()),
                dailyStats: try modelContext.fetchCount(FetchDescriptor<DailyStatsRecord>()),
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
        switch status {
        case .enabled:
            launchAtLoginState = .enabled
            launchAtLogin = true
            launchAtLoginError = nil
        case .requiresApproval:
            launchAtLoginState = .requiresApproval
            launchAtLogin = false
        case .notRegistered:
            launchAtLoginState = .notRegistered
            launchAtLogin = false
        case .notFound:
            launchAtLoginState = .unavailable
            launchAtLogin = false
        @unknown default:
            launchAtLoginState = .notRegistered
            launchAtLogin = false
        }
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

    private func syncLanguageFromSystemDefaults() {
        let stored = Self.resolvedAppleLanguage()
        if appLanguage != stored {
            appLanguage = stored
        }
    }

    private func applyLanguagePreference(_ language: String) {
        languageRestartError = nil
        if language == "system" {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([language], forKey: "AppleLanguages")
        }
        UserDefaults.standard.synchronize()
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

    private func refreshNotificationAuthStatus() async {
        notificationAuthStatus = await NotificationService.shared.authorizationStatus()
    }

    private func requestNotificationPermission() async {
        notificationAuthStatus = await NotificationService.shared.requestAuthorization()
    }

    private func openNotificationSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func sendTestNotification() async {
        isSendingTestNotification = true
        notificationStatusMessage = nil
        defer { isSendingTestNotification = false }

        let status = await NotificationService.shared.requestAuthorization()
        notificationAuthStatus = status
        guard status != .denied else {
            notificationStatusMessage = String(localized: "系统已禁用通知权限，无法发送测试通知。")
            notificationStatusIsError = true
            return
        }

        do {
            try await NotificationService.shared.sendTestNotification()
            notificationStatusMessage = String(localized: "测试通知已发送")
            notificationStatusIsError = false
        } catch {
            notificationStatusMessage = error.localizedDescription
            notificationStatusIsError = true
        }
    }

    private func loadDotTextAPIKey() {
        let retrieved = (try? KeychainService.retrieve(key: KeychainService.Keys.dotAPIKey)) ?? ""
        dotTextAPIKey = retrieved
        savedDotTextAPIKey = retrieved
    }

    private func saveDotTextAPIKey() {
        let trimmedKey = dotTextAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmedKey.isEmpty {
                try KeychainService.deleteChecked(key: KeychainService.Keys.dotAPIKey)
                bumpDotAPIKeyRevision()
                dotTextAPIKey = ""
                savedDotTextAPIKey = ""
                dotTextAPIStatus = String(localized: "API Key 已移除")
                dotTextAPIStatusIsError = false
            } else {
                try KeychainService.store(key: KeychainService.Keys.dotAPIKey, value: trimmedKey)
                bumpDotAPIKeyRevision()
                dotTextAPIKey = trimmedKey
                savedDotTextAPIKey = trimmedKey
                dotTextAPIStatus = String(localized: "API Key 已保存")
                dotTextAPIStatusIsError = false
            }
        } catch {
            dotTextAPIStatus = error.localizedDescription
            dotTextAPIStatusIsError = true
        }
    }

    private func testDotTextPush() async {
        guard let syncService = appStore.syncService else { return }
        if dotTextKeyHasUnsavedChanges {
            saveDotTextAPIKey()
            guard !dotTextAPIStatusIsError else { return }
        }
        isTestingDotTextPush = true
        dotTextAPIStatus = nil
        defer { isTestingDotTextPush = false }

        do {
            try await syncService.testDotTextPush()
            dotTextAPIStatus = String(localized: "测试推送成功")
            dotTextAPIStatusIsError = false
        } catch {
            dotTextAPIStatus = error.localizedDescription
            dotTextAPIStatusIsError = true
        }
    }
}

// MARK: - Capsule Switchers (aligned with MenuBarSettingsView)

private struct SettingsSectionSwitcher: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var selection: SettingsSection
    @Namespace private var thumbNamespace
    @State private var hoveredSection: SettingsSection?

    private func iconName(for section: SettingsSection) -> String {
        switch section {
        case .general:     "slider.horizontal.3"
        case .sync:        "arrow.triangle.2.circlepath"
        case .diagnostics: "stethoscope"
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SettingsSection.allCases) { section in
                let isSelected = selection == section
                let isHovered = hoveredSection == section
                Button {
                    withAnimation(.smooth(duration: 0.22)) {
                        selection = section
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: iconName(for: section))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(isSelected ? Color.accentColor : (isHovered ? .primary : .secondary))
                        Text(section.localizedTitle)
                            .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? .primary : (isHovered ? .primary : .secondary))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(colorScheme == .dark ? Color.white.opacity(0.16) : Color.white)
                                .overlay {
                                    Capsule()
                                        .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.06), lineWidth: 0.5)
                                }
                                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.07), radius: 2, y: 1)
                                .matchedGeometryEffect(id: "settingsSectionThumb", in: thumbNamespace)
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
                    hoveredSection = hovering ? section : (hoveredSection == section ? nil : hoveredSection)
                }
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.055), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08), lineWidth: 0.5)
        }
    }
}

private struct SettingsLanguageSwitcher: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var selection: String
    @Namespace private var thumbNamespace
    @State private var hoveredID: String?

    private let options: [(id: String, title: LocalizedStringKey)] = [
        ("system", "跟随系统"),
        ("en", "English"),
        ("zh-Hans", "简体中文"),
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.id) { option in
                let isSelected = selection == option.id
                let isHovered = hoveredID == option.id
                Button {
                    withAnimation(.smooth(duration: 0.22)) {
                        selection = option.id
                    }
                } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? .primary : (isHovered ? .primary : .secondary))
                        .lineLimit(1)
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
                                    .matchedGeometryEffect(id: "settingsLanguageThumb", in: thumbNamespace)
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
                    hoveredID = hovering ? option.id : (hoveredID == option.id ? nil : hoveredID)
                }
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.055), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08), lineWidth: 0.5)
        }
    }
}

// MARK: - Settings Visual Primitives

private struct SettingsIconWell: View {
    @Environment(\.colorScheme) private var colorScheme
    let systemName: String
    let tint: Color
    var size: CGFloat = 28

    var body: some View {
        let cornerRadius = size * 0.26
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(tint.opacity(colorScheme == .dark ? 0.18 : 0.11))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(tint.opacity(colorScheme == .dark ? 0.28 : 0.16), lineWidth: 0.5)
                }
            Image(systemName: systemName)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct SettingsStatusBadge: View {
    @Environment(\.colorScheme) private var colorScheme
    let text: String
    let tint: Color
    var showDot: Bool = false
    var isMonospaced: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            if showDot {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
                    .shadow(color: tint.opacity(0.4), radius: 2)
            }
            Text(text)
                .font(.system(size: 10.5, weight: .semibold, design: isMonospaced ? .monospaced : .default))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(colorScheme == .dark ? 0.16 : 0.10), in: Capsule())
    }
}

private struct SettingsInlineBanner: View {
    enum Style {
        case info
        case success
        case warning
        case error

        var tint: Color {
            switch self {
            case .info:    .accentColor
            case .success: .green
            case .warning: .orange
            case .error:   .red
            }
        }

        var icon: String {
            switch self {
            case .info:    "info.circle.fill"
            case .success: "checkmark.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .error:   "xmark.octagon.fill"
            }
        }
    }

    @Environment(\.colorScheme) private var colorScheme
    let style: Style
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: style.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(style.tint)

            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(style == .error ? style.tint : .primary.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            style.tint.opacity(colorScheme == .dark ? 0.13 : 0.075),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(style.tint.opacity(colorScheme == .dark ? 0.28 : 0.18), lineWidth: 0.75)
        }
    }
}

private struct SettingsHoverRow<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder let content: () -> Content
    @State private var isHovered = false

    var body: some View {
        content()
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isHovered
                    ? Color.primary.opacity(colorScheme == .dark ? 0.035 : 0.022)
                    : Color.clear
            )
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) {
                    isHovered = hovering
                }
            }
    }
}

private struct SettingsMetricTile: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: LocalizedStringKey
    let value: String?
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            if let value {
                Text(value)
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .contentTransition(.numericText())
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(height: 26)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(colorScheme == .dark ? 0.045 : 0.025),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.065), lineWidth: 0.75)
        }
    }
}

private struct SettingsRecessedTextField: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: LocalizedStringKey
    let placeholder: LocalizedStringKey
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, design: .monospaced))
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(
                    Color.primary.opacity(colorScheme == .dark ? 0.055 : 0.035),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.75)
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

struct SettingsToggleRow: View {
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
                .controlSize(.small)
                .labelsHidden()
        }
    }
}
