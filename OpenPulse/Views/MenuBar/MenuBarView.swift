import SwiftUI
import Foundation
import SwiftData
import AppKit

struct MenuBarView: View {
    @State private var dayStart = Calendar.current.startOfDay(for: Date())

    var body: some View {
        MenuBarContentView(dayStart: dayStart)
            .onAppear { updateDayBoundary() }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
                updateDayBoundary()
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
                updateDayBoundary()
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                updateDayBoundary()
            }
    }

    private func updateDayBoundary() {
        dayStart = Calendar.current.startOfDay(for: Date())
    }
}

struct MenuBarDailyStatsSnapshot: Equatable {
    let date: Date
    let tool: Tool
    let inputTokens: Int
    let outputTokens: Int
}

func menuBarTodayTokens(
    from stats: [MenuBarDailyStatsSnapshot],
    dayStart: Date,
    calendar: Calendar = .current
) -> [Tool: Int] {
    let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
    var tokens: [Tool: Int] = [:]
    for record in stats where record.date >= dayStart && record.date < dayEnd {
        tokens[record.tool, default: 0] += record.inputTokens + record.outputTokens
    }
    return tokens
}

private struct MenuBarQuotaNowKey: EnvironmentKey {
    static var defaultValue: Date { Date() }
}

private extension EnvironmentValues {
    var menuBarQuotaNow: Date {
        get { self[MenuBarQuotaNowKey.self] }
        set { self[MenuBarQuotaNowKey.self] = newValue }
    }
}

private struct MenuBarContentView: View {
    @Environment(AppStore.self) private var appStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Query private var dailyStats: [DailyStatsRecord]
    @Query private var quotas: [QuotaRecord]
    @State private var logger = AppLogger.shared

    @AppStorage("menubar.toolOrder") private var toolOrderRaw = Tool.defaultOrderRaw
    @AppStorage("menubar.hiddenTools") private var hiddenToolsRaw = ""
    @AppStorage("menubar.antigravityDisplayMode") private var antigravityDisplayMode = "accounts"
    let dayStart: Date

    init(dayStart: Date) {
        self.dayStart = dayStart
        // A moving, bounded aggregate query keeps yesterday out after midnight.
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        _dailyStats = Query(filter: #Predicate<DailyStatsRecord> { $0.date >= dayStart && $0.date < dayEnd })
    }

    private var orderedVisibleTools: [Tool] {
        let hidden = Set(hiddenToolsRaw.components(separatedBy: ",").filter { !$0.isEmpty })
        let order = toolOrderRaw.components(separatedBy: ",").compactMap { Tool(rawValue: $0) }
        let ordered = order + Tool.allCases.filter { !order.contains($0) }
        return ordered.filter { !hidden.contains($0.rawValue) }
    }

    @State private var contentHeight: CGFloat = 0
    @State private var headerHeight: CGFloat = 48
    @State private var footerHeight: CGFloat = 44
    // Cached per-tool today token counts — one pass over today's aggregate stats only.
    @State private var todayTokensByTool: [Tool: Int] = [:]

    private var todayStatsSnapshot: [MenuBarDailyStatsSnapshot] {
        dailyStats.map {
            MenuBarDailyStatsSnapshot(
                date: $0.date,
                tool: $0.tool,
                inputTokens: $0.totalInputTokens,
                outputTokens: $0.totalOutputTokens
            )
        }
    }

    private func rebuildTodayTokens() {
        todayTokensByTool = menuBarTodayTokens(from: todayStatsSnapshot, dayStart: dayStart)
    }

    private var todayTokens: Int { todayTokensByTool.values.reduce(0, +) }

    private var isSyncing: Bool { appStore.syncService?.isSyncingActive ?? false }
    private var lastSyncDate: Date? { appStore.syncService?.lastSyncDate ?? appStore.lastSyncDate }

    private var maxPopoverHeight: CGFloat {
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        return max(360, screenHeight - 56)
    }

    private var resolvedPopoverHeight: CGFloat {
        let desired = contentHeight + headerHeight + footerHeight
        return min(max(240, desired), maxPopoverHeight)
    }

    var body: some View {
        ScrollView {
            // Only quota rows tick; today's bounded query and cached totals
            // remain in the parent and rebuild only when usage or day changes.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                VStack(spacing: 10) {
                    if orderedVisibleTools.isEmpty {
                        MenuBarEmptyToolsView()
                            .padding(.horizontal, 4)
                            .padding(.vertical, 16)
                    } else {
                        ForEach(orderedVisibleTools, id: \.self) { tool in
                            toolCard(for: tool)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
                .environment(\.menuBarQuotaNow, context.date)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
        }
        .scrollIndicators(.hidden)
        .scrollEdgeEffectStyle(.soft, for: .vertical)
        .safeAreaInset(edge: .top, spacing: 0) {
            MenuBarHeader(
                todayTokens: todayTokens,
                isSyncing: isSyncing,
                onRefresh: {
                    performMenuBarAction {
                        await appStore.syncService?.sync()
                    }
                }
            )
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MenuBarFooter(
                lastSyncDate: lastSyncDate,
                syncError: appStore.syncService?.syncError.map { syncErrorHelpText(fallback: $0) },
                onOpen: {
                    performMenuBarAction {
                        WindowCoordinator.shared.showMainWindow()
                    }
                },
                onSettings: {
                    performMenuBarAction {
                        WindowCoordinator.shared.showMainWindow(select: .settings)
                    }
                },
                onQuit: {
                    performMenuBarAction {
                        NSApp.terminate(nil)
                    }
                }
            )
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
        }
        .frame(width: 460, height: resolvedPopoverHeight)
        .background {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                // Soft frosted veil over NSPopover's native Liquid Glass so busy windows
                // behind the popover blur smoothly without washing out text legibility.
                ZStack {
                    Rectangle().fill(.regularMaterial)
                    Color(nsColor: .windowBackgroundColor)
                        .opacity(colorScheme == .dark ? 0.26 : 0.30)
                }
            }
            MenuBarWindowCapture()
        }
        .task { rebuildTodayTokens() }
        .onChange(of: todayStatsSnapshot) { _, _ in rebuildTodayTokens() }
        .onChange(of: dayStart) { _, _ in rebuildTodayTokens() }
        .onChange(of: appStore.syncService?.dataRevision) { _, _ in rebuildTodayTokens() }
    }

    @ViewBuilder
    private func toolCard(for tool: Tool) -> some View {
        switch tool {
        case .claudeCode:
            ClaudeQuotaCard(
                usage: appStore.syncService?.latestClaudeUsage,
                quota: quotas.first(where: { $0.tool == .claudeCode }),
                accountInfo: appStore.syncService?.latestClaudeAccountInfo,
                todayTokens: todaySessionTokens(for: .claudeCode)
            )
        case .codex:
            if let accounts = appStore.syncService?.latestCodexAccounts, !accounts.isEmpty {
                CodexMultiAccountQuotaCard(
                    accounts: accounts,
                    todayTokens: todaySessionTokens(for: .codex)
                )
            } else {
                CodexQuotaCard(
                    limits: nil,
                    fallbackQuota: quotas.first(where: { $0.tool == .codex && $0.accountKey == nil }),
                    todayTokens: todaySessionTokens(for: .codex)
                )
            }
        case .copilot:
            CopilotQuotaCard(
                snapshots: appStore.syncService?.latestCopilotSnapshots,
                resetAt: appStore.syncService?.latestCopilotResetAt,
                plan: appStore.syncService?.latestCopilotPlan,
                fallbackQuota: quotas.first(where: { $0.tool == .copilot }),
                todayTokens: todaySessionTokens(for: .copilot)
            )
        case .antigravity:
            if let accounts = appStore.syncService?.latestAntigravityAccounts {
                if antigravityDisplayMode == "aggregate" {
                    AntigravityAggregateCard(
                        accounts: accounts,
                        todayTokens: todaySessionTokens(for: .antigravity)
                    )
                } else {
                    AntigravityMultiAccountCard(
                        accounts: accounts,
                        todayTokens: todaySessionTokens(for: .antigravity)
                    )
                }
            } else if let fallback = quotas.first(where: { $0.tool == .antigravity }) {
                AntigravityFallbackCard(
                    quota: fallback,
                    todayTokens: todaySessionTokens(for: .antigravity)
                )
            } else {
                MenuBarToolShell(tool: .antigravity) {
                    MenuBarToolIdentity(tool: .antigravity, todayTokens: todaySessionTokens(for: .antigravity)) {
                        ConfigShortcutButton(tool: .antigravity)
                    }
                } content: {
                    MenuBarQuotaUnavailable()
                        .padding(.horizontal, MenuBarGrid.horizontalInset)
                        .padding(.bottom, 12)
                }
            }
        }
    }

    private func todaySessionTokens(for tool: Tool) -> Int { todayTokensByTool[tool] ?? 0 }

    private func syncErrorHelpText(fallback: String) -> String {
        logger.latestPersistentSyncError?.summary ?? fallback
    }

    private func performMenuBarAction(_ action: @escaping @MainActor () async -> Void) {
        Task { @MainActor in
            GlobalHotkeyService.shared.closeMenuBar()
            await action()
        }
    }
}

// MARK: - Telemetry Sheet Chrome

private enum MenuBarGrid {
    static let horizontalInset: CGFloat = 14
    static let groupColumnWidth: CGFloat = 120
    static let groupColumnGap: CGFloat = 14
    static let cellWidth: CGFloat = 56
    static let cellGap: CGFloat = 8
}

private func menuBarToolAccentColor(for tool: Tool, colorScheme: ColorScheme) -> Color {
    switch tool {
    case .codex:
        return colorScheme == .dark
            ? Color(red: 0.18, green: 0.82, blue: 0.64)
            : Color(red: 0.055, green: 0.61, blue: 0.47)
    case .antigravity:
        return colorScheme == .dark
            ? Color(red: 0.65, green: 0.54, blue: 0.98)
            : Color(red: 0.43, green: 0.28, blue: 0.90)
    case .claudeCode:
        return colorScheme == .dark
            ? Color(red: 0.94, green: 0.54, blue: 0.42)
            : Color(red: 0.85, green: 0.41, blue: 0.27)
    case .copilot:
        return colorScheme == .dark
            ? Color(red: 0.35, green: 0.63, blue: 1.00)
            : Color(red: 0.12, green: 0.42, blue: 0.88)
    }
}

private func menuBarWarningColor(colorScheme: ColorScheme) -> Color {
    colorScheme == .dark
        ? Color(red: 0.96, green: 0.65, blue: 0.14)
        : Color(red: 0.86, green: 0.51, blue: 0.00)
}

private func menuBarCriticalColor(colorScheme: ColorScheme) -> Color {
    colorScheme == .dark
        ? Color(red: 1.00, green: 0.36, blue: 0.36)
        : Color(red: 0.86, green: 0.21, blue: 0.21)
}

private struct MenuBarHairline: View {
    @Environment(\.colorScheme) private var colorScheme
    var opacity: Double? = nil

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(opacity ?? (colorScheme == .dark ? 0.10 : 0.07)))
            .frame(height: 0.5)
    }
}

private struct MenuBarHeader: View {
    let todayTokens: Int
    let isSyncing: Bool
    let onRefresh: () -> Void
    @Namespace private var glassNamespace

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                if let icon = NSImage(named: "MenuBarIcon") {
                    Image(nsImage: icon)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 15, height: 15)
                        .foregroundStyle(.primary.opacity(0.85))
                }
                Text("OpenPulse")
                    .font(.system(size: 13.5, weight: .bold))
                    .tracking(-0.2)
            }

            Spacer(minLength: 8)

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(todayTokens.compactTokenString)
                            .font(.system(size: 11.5, weight: .semibold))
                            .monospacedDigit()
                        Text("今日 tokens")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .glassEffect(.regular, in: .capsule)
                    .glassEffectID("todayTokens", in: glassNamespace)
                    .accessibilityElement(children: .combine)

                    Button {
                        guard !isSyncing else { return }
                        onRefresh()
                    } label: {
                        Group {
                            if isSyncing {
                                ProgressView()
                                    .controlSize(.mini)
                                    .scaleEffect(0.75)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                        }
                        .frame(width: 26, height: 26)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .glassEffectID("refresh", in: glassNamespace)
                    .focusEffectDisabled()
                    .keyboardShortcut("r", modifiers: .command)
                    .help(isSyncing ? String(localized: "同步中…") : String(localized: "刷新同步 (⌘R)"))
                    .accessibilityLabel("刷新同步")
                }
            }
            .animation(.smooth(duration: 0.25), value: isSyncing)
        }
        .padding(.horizontal, 14)
        .padding(.top, 11)
        .padding(.bottom, 7)
    }
}

private struct MenuBarFooter: View {
    @Environment(\.colorScheme) private var colorScheme
    let lastSyncDate: Date?
    let syncError: String?
    let onOpen: () -> Void
    let onSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let syncError {
                Label("同步出现问题", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(menuBarWarningColor(colorScheme: colorScheme))
                    .lineLimit(1)
                    .help(syncError)
                    .accessibilityHint(syncError)
            } else if let lastSyncDate {
                Text("更新于 \(lastSyncDate, style: .relative)前")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(lastSyncDate.formatted(date: .abbreviated, time: .shortened))
            } else {
                Text("尚未同步")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button(action: onOpen) {
                        HStack(spacing: 6) {
                            Image(systemName: "macwindow")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text("打开 OpenPulse")
                                .foregroundStyle(.primary)
                            Text("⌘M")
                                .font(.system(size: 10, design: .rounded))
                                .foregroundStyle(.tertiary)
                        }
                        .font(.system(size: 11.5, weight: .medium))
                        .padding(.horizontal, 11)
                        .frame(height: 26)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .focusEffectDisabled()
                    .keyboardShortcut("m", modifiers: .command)
                    .help("打开主窗口 (⌘M)")

                    Menu {
                        Button("设置…", systemImage: "gearshape", action: onSettings)
                            .keyboardShortcut(",", modifiers: .command)
                        Divider()
                        Button("退出 OpenPulse", systemImage: "power", action: onQuit)
                            .keyboardShortcut("q", modifiers: .command)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 26, height: 26)
                            .contentShape(Circle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 26, height: 26)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .focusEffectDisabled()
                    .help("更多操作")
                    .accessibilityLabel("更多操作")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 7)
        .padding(.bottom, 11)
    }
}

private struct MenuBarEmptyToolsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("没有显示的工具")
                .font(.system(size: 13, weight: .semibold))
            Text("在设置中选择要显示的工具。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ConfigShortcutButton: View {
    let tool: Tool
    @State private var isHovered = false

    private var configFile: ConfigFile? { ConfigFile.primaryConfig(for: tool) }

    var body: some View {
        if let configFile {
            Button {
                GlobalHotkeyService.shared.closeMenuBar()
                if FileManager.default.fileExists(atPath: configFile.url.path) {
                    NSWorkspace.shared.open(configFile.url)
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([configFile.url.deletingLastPathComponent()])
                }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 22, height: 22)
                    .background(
                        isHovered ? Color.primary.opacity(0.08) : Color.clear,
                        in: Circle()
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(isHovered ? .primary : .secondary)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) {
                    isHovered = hovering
                }
            }
            .focusEffectDisabled()
            .accessibilityLabel(Text("打开 \(configFile.displayName)"))
            .help("打开 \(configFile.displayName)")
        }
    }
}

private struct MenuBarQuotaUnavailable: View {
    var body: some View {
        Text("尚未获取额度")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Single-layer provider plate with radial brand sheen emanating from the logo well
/// and specular top-rim lighting. Houses flat, borderless telemetry rows inside.
private struct MenuBarToolShell<Identity: View, Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let tool: Tool
    let identity: Identity
    let content: Content

    init(tool: Tool, @ViewBuilder identity: () -> Identity, @ViewBuilder content: () -> Content) {
        self.tool = tool
        self.identity = identity()
        self.content = content()
    }

    var body: some View {
        let accent = menuBarToolAccentColor(for: tool, colorScheme: colorScheme)
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)

        VStack(alignment: .leading, spacing: 0) {
            identity
                .padding(.horizontal, MenuBarGrid.horizontalInset)
                .padding(.vertical, 9)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background {
            ZStack(alignment: .topLeading) {
                shape
                    .fill(
                        Color(nsColor: .controlBackgroundColor)
                            .opacity(colorScheme == .dark ? 0.72 : 0.84)
                    )
                // Soft radial brand sheen radiating seamlessly from behind the tool icon
                RadialGradient(
                    colors: [
                        accent.opacity(colorScheme == .dark ? 0.16 : 0.095),
                        accent.opacity(colorScheme == .dark ? 0.04 : 0.02),
                        Color.clear
                    ],
                    center: UnitPoint(x: 0.06, y: 0.0),
                    startRadius: 4,
                    endRadius: 210
                )
            }
        }
        .clipShape(shape)
        .overlay {
            shape
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            colorScheme == .dark
                                ? Color.white.opacity(0.22)
                                : Color.white.opacity(0.92),
                            accent.opacity(colorScheme == .dark ? 0.16 : 0.12),
                            Color.primary.opacity(colorScheme == .dark ? 0.13 : 0.10)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.75
                )
        }
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.24 : 0.05),
            radius: 4,
            x: 0,
            y: 1.5
        )
    }
}

private struct MenuBarHoverRow<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    var hoverTint: Color? = nil
    var accentLeading: Color? = nil
    @ViewBuilder let content: () -> Content
    @State private var isHovered = false

    var body: some View {
        let tint = hoverTint ?? Color.primary
        ZStack(alignment: .leading) {
            content()
                .padding(.horizontal, 10)
                .padding(.vertical, 7.5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    isHovered
                        ? tint.opacity(colorScheme == .dark ? 0.11 : 0.06)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            if let accentLeading {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(accentLeading)
                    .frame(width: 2.5, height: 22)
                    .padding(.leading, 1)
            }
        }
        .padding(.horizontal, MenuBarGrid.horizontalInset - 10)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovered = hovering
            }
        }
    }
}

/// Precision luminous progress bar for the menu bar telemetry sheet:
/// 2-stop gradient fill with specular top sheen and subtle glow when healthy/active.
private struct MenuBarLuminousBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    let fraction: Double?
    let color: Color
    var height: CGFloat = 4.5
    var isExhausted: Bool = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.15 : 0.095))
                    .frame(height: height)

                if let f = fraction, !isExhausted {
                    let clamped = CGFloat(max(0, min(1, f)))
                    let width = max(clamped > 0.001 ? height : 0, geo.size.width * clamped)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.80), color],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .overlay(alignment: .top) {
                            Capsule()
                                .fill(Color.white.opacity(colorScheme == .dark ? 0.24 : 0.36))
                                .frame(height: 1)
                                .padding(.horizontal, 1)
                        }
                        .frame(width: width, height: height)
                        .shadow(color: color.opacity(colorScheme == .dark ? 0.28 : 0.18), radius: 2, y: 0.75)
                        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.9), value: f)
                }
            }
        }
        .frame(height: height)
    }
}

private struct MenuBarHealthDot: View {
    @Environment(\.colorScheme) private var colorScheme
    let fraction: Double?
    var brandAccent: Color? = nil

    var body: some View {
        let color = menuBarStatusDotColor(fraction: fraction, brandAccent: brandAccent, colorScheme: colorScheme)
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .shadow(color: fraction != nil ? color.opacity(0.42) : .clear, radius: 2)
            .accessibilityHidden(true)
    }
}

private struct MenuBarTintedChipButton: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    var icon: String? = nil
    let accent: Color
    var isDisabled: Bool = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3.5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 9, weight: .semibold))
                }
                Text(LocalizedStringKey(title))
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(accent)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(
                accent.opacity(
                    isHovered
                        ? (colorScheme == .dark ? 0.28 : 0.20)
                        : (colorScheme == .dark ? 0.17 : 0.11)
                ),
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .strokeBorder(accent.opacity(colorScheme == .dark ? 0.30 : 0.20), lineWidth: 0.5)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isDisabled ? 0.5 : 1)
        .disabled(isDisabled)
        .focusEffectDisabled()
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}

private struct MenuBarToolIdentity<Accessory: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let tool: Tool
    let subtitle: String?
    let accountCount: Int?
    let metaText: String?
    let todayTokens: Int
    let accessory: Accessory

    init(
        tool: Tool,
        subtitle: String? = nil,
        accountCount: Int? = nil,
        metaText: String? = nil,
        todayTokens: Int = 0,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.tool = tool
        self.subtitle = subtitle
        self.accountCount = accountCount
        self.metaText = metaText
        self.todayTokens = todayTokens
        self.accessory = accessory()
    }

    var body: some View {
        let accent = menuBarToolAccentColor(for: tool, colorScheme: colorScheme)

        HStack(alignment: .center, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(accent.opacity(colorScheme == .dark ? 0.22 : 0.14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(accent.opacity(colorScheme == .dark ? 0.35 : 0.24), lineWidth: 0.5)
                    }
                ToolLogoImage(tool: tool, size: 15)
            }
            .frame(width: 24, height: 24)

            HStack(alignment: .center, spacing: 6) {
                Text(tool.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(-0.2)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(accent.opacity(colorScheme == .dark ? 0.18 : 0.12), in: Capsule())
                        .lineLimit(1)
                }
                if let accountCount, accountCount > 1 {
                    Text("\(accountCount)")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(accent.opacity(colorScheme == .dark ? 0.18 : 0.12), in: Capsule())
                }
            }

            if let metaText, !metaText.isEmpty {
                Text(metaText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if todayTokens > 0 {
                Text(todayTokens.compactTokenString)
                    .font(.system(size: 10.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help("今日 \(todayTokens.compactTokenString) tokens")
                    .accessibilityLabel(Text("今日 \(todayTokens.compactTokenString) tokens"))
            }
            accessory
        }
    }
}

/// Compact micro-gauge used in the aligned matrix columns (56pt wide).
private struct MenuBarMatrixGauge: View {
    @Environment(\.colorScheme) private var colorScheme
    var tool: Tool? = nil
    let fraction: Double?
    let primaryValue: String
    let resetText: String?
    let resetHelp: String?
    var isExhaustedOverride: Bool? = nil

    private var isExhausted: Bool {
        isExhaustedOverride ?? ((fraction ?? 1.0) <= 0.001 || primaryValue == "0%")
    }

    private var isUnknown: Bool {
        fraction == nil && primaryValue == "—"
    }

    private var valueColor: Color {
        if isUnknown { return Color.secondary.opacity(0.55) }
        if isExhausted { return Color.secondary }
        guard let fraction else { return .primary }
        if fraction < 0.15 { return menuBarCriticalColor(colorScheme: colorScheme) }
        if fraction < 0.40 { return menuBarWarningColor(colorScheme: colorScheme) }
        return .primary
    }

    var body: some View {
        let barColor = isExhausted
            ? Color.primary.opacity(0.16)
            : menuBarQuotaBarColor(fraction: fraction, tool: tool, colorScheme: colorScheme)

        VStack(alignment: .leading, spacing: 3.5) {
            Text(primaryValue)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(valueColor)
                .lineLimit(1)

            MenuBarLuminousBar(
                fraction: fraction,
                color: barColor,
                height: 4.5,
                isExhausted: isExhausted
            )

            if let resetText, !resetText.isEmpty {
                Text(resetText)
                    .font(.system(size: 9.5))
                    .monospacedDigit()
                    .foregroundStyle(.secondary.opacity(0.88))
                    .lineLimit(1)
            }
        }
        .frame(width: MenuBarGrid.cellWidth, alignment: .leading)
        .help(resetHelp ?? "")
    }
}

/// Horizontal telemetry gauge used for wide 2-column rows (Codex, Claude, Copilot, Aggregate).
private struct MenuBarQuotaPanel: View {
    @Environment(\.colorScheme) private var colorScheme
    var tool: Tool? = nil
    let title: String
    var shortBadge: String? = nil
    let fraction: Double?
    let primaryValue: String
    let countdown: String?
    let footer: String?
    var isExpired: Bool = false
    var isExhaustedOverride: Bool? = nil

    private var isExhausted: Bool {
        isExhaustedOverride ?? ((fraction ?? 1.0) <= 0.001 || primaryValue == "0%")
    }

    private var isUnknown: Bool {
        fraction == nil && primaryValue == "—"
    }

    private var valueColor: Color {
        if isUnknown { return Color.secondary.opacity(0.55) }
        if isExhausted { return Color.secondary }
        guard let fraction else { return .primary }
        if fraction < 0.15 { return menuBarCriticalColor(colorScheme: colorScheme) }
        if fraction < 0.40 { return menuBarWarningColor(colorScheme: colorScheme) }
        return .primary
    }

    private var trailingHelp: String {
        if let countdown {
            return String(localized: "\(countdown) 重置")
        }
        return ""
    }

    var body: some View {
        let barColor = isExhausted
            ? Color.primary.opacity(0.16)
            : menuBarQuotaBarColor(fraction: fraction, tool: tool, colorScheme: colorScheme)

        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if let shortBadge {
                    Text(shortBadge)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .help(Text(LocalizedStringKey(title)))
                } else {
                    Text(LocalizedStringKey(title))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(primaryValue)
                    .font(.system(size: 13.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(valueColor)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if isExpired {
                    Text("等待更新")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(menuBarWarningColor(colorScheme: colorScheme))
                        .lineLimit(1)
                        .help(trailingHelp)
                } else if let countdown {
                    Text(countdown)
                        .font(.system(size: 9.5))
                        .monospacedDigit()
                        .foregroundStyle(.secondary.opacity(0.88))
                        .lineLimit(1)
                        .help(trailingHelp)
                }
            }

            MenuBarLuminousBar(
                fraction: fraction,
                color: barColor,
                height: 4.5,
                isExhausted: isExhausted
            )

            if let footer, !footer.isEmpty, !(isExpired && footer == String(localized: "等待更新")) {
                Text(LocalizedStringKey(footer))
                    .font(.system(size: 9.5, weight: isExhausted ? .medium : .regular))
                    .monospacedDigit()
                    .foregroundStyle(isExhausted ? menuBarWarningColor(colorScheme: colorScheme) : Color.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private func menuBarCompactClockString(for date: Date) -> String {
    let calendar = Calendar.current
    let hour = calendar.component(.hour, from: date)
    let minute = calendar.component(.minute, from: date)
    return String(format: "%02d:%02d", hour, minute)
}

private func menuBarCompactDateString(for date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) {
        return menuBarCompactClockString(for: date)
    }
    let month = calendar.component(.month, from: date)
    let day = calendar.component(.day, from: date)
    return String(format: "%02d/%02d", month, day)
}

private func menuBarShortAccountName(_ identifier: String, allIdentifiers: [String]) -> String {
    guard let atIndex = identifier.firstIndex(of: "@") else { return identifier }
    let localPart = String(identifier[..<atIndex])
    guard !localPart.isEmpty else { return identifier }
    let matchingCount = allIdentifiers.reduce(into: 0) { count, item in
        if let idx = item.firstIndex(of: "@"), String(item[..<idx]).caseInsensitiveCompare(localPart) == .orderedSame {
            count += 1
        }
    }
    return matchingCount <= 1 ? localPart : identifier
}

private func menuBarShortAGGroupTitle(_ displayName: String) -> String {
    let lower = displayName.lowercased()
    if lower == "gemini models" { return "Gemini" }
    if lower == "claude and gpt models" { return "Claude & GPT" }
    return displayName
}

func menuBarQuotaFraction(
    remainingFraction: Double?,
    resetAt: Date?,
    now: Date = Date()
) -> Double? {
    guard !menuBarQuotaIsExpired(resetAt: resetAt, now: now),
          let remainingFraction, remainingFraction.isFinite else { return nil }
    return min(1, max(0, remainingFraction))
}

func menuBarQuotaIsExpired(resetAt: Date?, now: Date = Date()) -> Bool {
    resetAt.map { $0 <= now } ?? false
}

private func menuBarQuotaPercentText(_ fraction: Double?) -> String {
    fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
}

private func menuBarQuotaRefreshFooter(resetAt: Date?, now: Date) -> String? {
    menuBarQuotaIsExpired(resetAt: resetAt, now: now) ? String(localized: "等待更新") : nil
}

private func menuBarQuotaBarColor(fraction: Double?, tool: Tool? = nil, colorScheme: ColorScheme = .light) -> Color {
    guard let fraction else { return Color.primary.opacity(0.16) }
    if fraction <= 0.001 { return Color.primary.opacity(0.16) }
    if fraction < 0.15 { return menuBarCriticalColor(colorScheme: colorScheme) }
    if fraction < 0.40 { return menuBarWarningColor(colorScheme: colorScheme) }
    if let tool {
        return menuBarToolAccentColor(for: tool, colorScheme: colorScheme)
    }
    return colorScheme == .dark
        ? Color(red: 0.24, green: 0.80, blue: 0.48)
        : Color(red: 0.18, green: 0.72, blue: 0.40)
}

private func menuBarStatusDotColor(fraction: Double?, brandAccent: Color? = nil, colorScheme: ColorScheme = .light) -> Color {
    guard let fraction else { return Color.secondary.opacity(0.45) }
    if fraction <= 0.001 || fraction < 0.15 { return menuBarCriticalColor(colorScheme: colorScheme) }
    if fraction < 0.40 { return menuBarWarningColor(colorScheme: colorScheme) }
    return brandAccent ?? Color(red: 0.20, green: 0.75, blue: 0.43)
}

private func menuBarTimeOnlyResetString(for date: Date) -> String {
    date.formatted(.dateTime.hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits))
}

private func menuBarShortResetString(for date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) {
        return menuBarTimeOnlyResetString(for: date)
    }
    let month = calendar.component(.month, from: date)
    let day = calendar.component(.day, from: date)
    let hour = calendar.component(.hour, from: date)
    let minute = calendar.component(.minute, from: date)
    return String(format: "%02d/%02d %02d:%02d", month, day, hour, minute)
}

private struct CodexMenuBarWindowDisplayState {
    let fraction: Double?
    let primaryValue: String
    let countdown: String?
    let footer: String?
    let isExpired: Bool
}

struct CodexMenuBarQuotaRow: Identifiable, Sendable {
    let id: String
    let title: String
    let fiveHourWindow: CodexWindow?
    let oneWeekWindow: CodexWindow?
    let observedAt: Date?
}

func codexMenuBarQuotaRows(for limits: CodexRateLimits?) -> [CodexMenuBarQuotaRow] {
    guard let limits else { return [] }

    var rows: [CodexMenuBarQuotaRow] = []
    let generalFiveHour = limits.fiveHourWindow
    let generalOneWeek = limits.oneWeekWindow
    if generalFiveHour != nil || generalOneWeek != nil {
        rows.append(
            CodexMenuBarQuotaRow(
                id: "codex",
                title: String(localized: "通用额度"),
                fiveHourWindow: generalFiveHour,
                oneWeekWindow: generalOneWeek,
                observedAt: limits.observedAt
            )
        )
    }

    let namedRows = (limits.additionalLimits ?? []).compactMap { named -> CodexMenuBarQuotaRow? in
        guard !isSparkNamedLimit(named) else { return nil }
        let id = named.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        let windows = codexMenuBarNamedWindows(for: named)
        guard windows.fiveHour != nil || windows.oneWeek != nil else { return nil }

        return CodexMenuBarQuotaRow(
            id: id,
            title: codexMenuBarNamedTitle(for: named, fallbackID: id),
            fiveHourWindow: windows.fiveHour,
            oneWeekWindow: windows.oneWeek,
            observedAt: named.observedAt
        )
    }

    rows.append(contentsOf: namedRows.sorted { lhs, rhs in
        let lhsName = lhs.title.lowercased()
        let rhsName = rhs.title.lowercased()
        if lhsName != rhsName { return lhsName < rhsName }
        let lhsID = lhs.id.lowercased()
        let rhsID = rhs.id.lowercased()
        if lhsID != rhsID { return lhsID < rhsID }
        if lhs.title != rhs.title { return lhs.title < rhs.title }
        return lhs.id < rhs.id
    })
    return rows
}

private func codexMenuBarNamedWindows(
    for named: CodexNamedRateLimit
) -> (fiveHour: CodexWindow?, oneWeek: CodexWindow?) {
    var fiveHour: CodexWindow?
    var oneWeek: CodexWindow?

    for window in [named.primary, named.secondary].compactMap({ $0 }) {
        switch window.durationSeconds {
        case 18_000:
            if fiveHour == nil { fiveHour = window }
        case 604_800:
            if oneWeek == nil { oneWeek = window }
        default:
            continue
        }
    }

    return (fiveHour, oneWeek)
}

private func isSparkNamedLimit(_ named: CodexNamedRateLimit) -> Bool {
    let id = named.id.trimmingCharacters(in: .whitespacesAndNewlines)
    if id.caseInsensitiveCompare("codex_bengalfox") == .orderedSame { return true }
    if let name = named.name?.trimmingCharacters(in: .whitespacesAndNewlines) {
        if name.caseInsensitiveCompare("GPT-5.3-Codex-Spark") == .orderedSame || name.caseInsensitiveCompare("Spark") == .orderedSame {
            return true
        }
    }
    return false
}

private func codexMenuBarNamedTitle(for named: CodexNamedRateLimit, fallbackID: String) -> String {
    let name = named.name?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let name, !name.isEmpty else { return fallbackID }
    return name
}

func codexQuotaObservedRelativeText(observedAt: Date, locale: Locale = .current) -> String {
    observedAt.formatted(.relative(presentation: .named).locale(locale))
}

private struct CodexMenuBarQuotaRows: View {
    let limits: CodexRateLimits

    var body: some View {
        let rows = codexMenuBarQuotaRows(for: limits)
        let hasMultipleRows = rows.count > 1
        VStack(alignment: .leading, spacing: 10) {
            ForEach(rows) { row in
                CodexMenuBarQuotaRowView(
                    row: row,
                    showTitle: hasMultipleRows || row.id != "codex"
                )
            }
        }
    }
}

private struct CodexMenuBarQuotaRowView: View {
    @Environment(\.menuBarQuotaNow) private var now
    let row: CodexMenuBarQuotaRow
    let showTitle: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if showTitle {
                Text(verbatim: row.title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(alignment: .top, spacing: 12) {
                quotaPanel(label: String(localized: "5小时余量"), shortBadge: "5H", isFiveHour: true, window: row.fiveHourWindow)
                quotaPanel(label: String(localized: "本周余量"), shortBadge: "7D", isFiveHour: false, window: row.oneWeekWindow)
            }
        }
    }
    @ViewBuilder
    private func quotaPanel(label: String, shortBadge: String, isFiveHour: Bool, window: CodexWindow?) -> some View {
        let state = codexMenuBarDisplayState(for: window, isFiveHour: isFiveHour, now: now)
        MenuBarQuotaPanel(
            tool: .codex,
            title: label,
            shortBadge: shortBadge,
            fraction: state.fraction,
            primaryValue: state.primaryValue,
            countdown: state.countdown,
            footer: state.footer,
            isExpired: state.isExpired
        )
    }
}

private func codexMenuBarDisplayState(for window: CodexWindow?, isFiveHour: Bool, now: Date) -> CodexMenuBarWindowDisplayState {
    guard let window else {
        return CodexMenuBarWindowDisplayState(
            fraction: nil,
            primaryValue: "—",
            countdown: nil,
            footer: nil,
            isExpired: false
        )
    }

    let resetDate = window.resetDate
    let expired = menuBarQuotaIsExpired(resetAt: resetDate, now: now)
    let fraction = menuBarQuotaFraction(
        remainingFraction: window.usedPercent.map { (100 - $0) / 100 },
        resetAt: resetDate,
        now: now
    )
    let countdown = resetDate.map {
        isFiveHour ? menuBarCompactClockString(for: $0) : menuBarShortResetString(for: $0)
    }
    return CodexMenuBarWindowDisplayState(
        fraction: fraction,
        primaryValue: menuBarQuotaPercentText(fraction),
        countdown: countdown,
        footer: menuBarQuotaRefreshFooter(resetAt: resetDate, now: now),
        isExpired: expired
    )
}

// MARK: - Claude Code

struct ClaudeQuotaCard: View {
    @Environment(\.menuBarQuotaNow) private var now
    let usage: ClaudeUsageResponse?
    let quota: QuotaRecord?
    let accountInfo: ClaudeAccountInfo?
    let todayTokens: Int

    var body: some View {
        MenuBarToolShell(tool: .claudeCode) {
            MenuBarToolIdentity(
                tool: .claudeCode,
                subtitle: accountInfo?.displaySubscriptionName,
                todayTokens: todayTokens
            ) {
                ConfigShortcutButton(tool: .claudeCode)
            }
        } content: {
            VStack(spacing: 0) {
                MenuBarHairline(opacity: 0.06)
                Group {
                    if let usage {
                        let fiveHourFraction = menuBarQuotaFraction(
                            remainingFraction: usage.fiveHour?.utilization.map { (100 - $0) / 100 },
                            resetAt: usage.fiveHour?.resetDate,
                            now: now
                        )
                        let weeklyFraction = menuBarQuotaFraction(
                            remainingFraction: usage.sevenDay?.utilization.map { (100 - $0) / 100 },
                            resetAt: usage.sevenDay?.resetDate,
                            now: now
                        )
                        let isWeeklyExhausted = weeklyFraction.map { $0 <= 0.001 } ?? false
                        HStack(alignment: .top, spacing: MenuBarGrid.groupColumnGap) {
                            MenuBarQuotaPanel(
                                tool: .claudeCode,
                                title: "5小时余量",
                                shortBadge: "5H",
                                fraction: fiveHourFraction,
                                primaryValue: menuBarQuotaPercentText(fiveHourFraction),
                                countdown: usage.fiveHour?.resetDate.map { menuBarCompactClockString(for: $0) },
                                footer: isWeeklyExhausted
                                    ? String(localized: "本周额度已耗尽")
                                    : menuBarQuotaRefreshFooter(resetAt: usage.fiveHour?.resetDate, now: now),
                                isExpired: menuBarQuotaIsExpired(resetAt: usage.fiveHour?.resetDate, now: now),
                                isExhaustedOverride: isWeeklyExhausted ? true : nil
                            )
                            MenuBarQuotaPanel(
                                tool: .claudeCode,
                                title: "本周余量",
                                shortBadge: "7D",
                                fraction: weeklyFraction,
                                primaryValue: menuBarQuotaPercentText(weeklyFraction),
                                countdown: usage.sevenDay?.resetDate.map { menuBarShortResetString(for: $0) },
                                footer: menuBarQuotaRefreshFooter(resetAt: usage.sevenDay?.resetDate, now: now),
                                isExpired: menuBarQuotaIsExpired(resetAt: usage.sevenDay?.resetDate, now: now)
                            )
                        }
                    } else if let q = quota, let r = q.remaining, let t = q.total, t > 0 {
                        let frac = menuBarQuotaFraction(remainingFraction: Double(r) / Double(t), resetAt: q.resetAt, now: now)
                        MenuBarQuotaPanel(
                            tool: .claudeCode,
                            title: "5小时余量",
                            shortBadge: "5H",
                            fraction: frac,
                            primaryValue: menuBarQuotaPercentText(frac),
                            countdown: q.resetAt.map { menuBarCompactClockString(for: $0) },
                            footer: menuBarQuotaRefreshFooter(resetAt: q.resetAt, now: now),
                            isExpired: menuBarQuotaIsExpired(resetAt: q.resetAt, now: now)
                        )
                    } else {
                        MenuBarQuotaUnavailable()
                    }
                }
                .padding(.horizontal, MenuBarGrid.horizontalInset)
                .padding(.top, 10)
                .padding(.bottom, 12)
            }
        }
    }

    // TODO: surface off-peak multiplier badge in UI when ClaudeOffPeakBadge is re-added
    private var claudeOffPeakBadgeText: String? {
        var calendar = Calendar(identifier: .gregorian)
        guard let pacificTimeZone = TimeZone(identifier: "America/Los_Angeles") else { return nil }
        calendar.timeZone = pacificTimeZone

        let now = Date()
        let weekday = calendar.component(.weekday, from: now) // 1 = Sunday, 7 = Saturday
        let hour = calendar.component(.hour, from: now)

        if weekday == 1 || weekday == 7 {
            return "2x weekend"
        }
        if hour < 5 || hour >= 11 {
            return "2x off-peak"
        }
        return nil
    }
}

// MARK: - Codex

struct CodexQuotaCard: View {
    @Environment(AppStore.self) private var appStore
    @Environment(\.menuBarQuotaNow) private var now
    let limits: CodexRateLimits?
    let fallbackQuota: QuotaRecord?
    let todayTokens: Int
    @State private var statusMessage: String?
    var body: some View {
        MenuBarToolShell(tool: .codex) {
            MenuBarToolIdentity(
                tool: .codex,
                subtitle: normalizedSubscriptionDisplayName(limits?.planType),
                todayTokens: todayTokens
            ) {
                ConfigShortcutButton(tool: .codex)
            }
        } content: {
            VStack(spacing: 0) {
                MenuBarHairline(opacity: 0.06)
                VStack(alignment: .leading, spacing: 8) {
                    if let limits, !codexMenuBarQuotaRows(for: limits).isEmpty {
                        CodexMenuBarQuotaRows(limits: limits)
                    } else if let q = fallbackQuota, let r = q.remaining, let t = q.total, t > 0 {
                        let frac = menuBarQuotaFraction(remainingFraction: Double(r) / Double(t), resetAt: q.resetAt, now: now)
                        MenuBarQuotaPanel(
                            tool: .codex,
                            title: "5小时余量",
                            shortBadge: "5H",
                            fraction: frac,
                            primaryValue: menuBarQuotaPercentText(frac),
                            countdown: q.resetAt.map { menuBarCompactClockString(for: $0) },
                            footer: menuBarQuotaRefreshFooter(resetAt: q.resetAt, now: now),
                            isExpired: menuBarQuotaIsExpired(resetAt: q.resetAt, now: now)
                        )
                    } else {
                        MenuBarQuotaUnavailable()
                    }
                    if let statusMessage {
                        Text(statusMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, MenuBarGrid.horizontalInset)
                .padding(.top, 10)
                .padding(.bottom, 12)
            }
        }
    }
}

struct CodexAccountQuotaCard: View {
    @Environment(\.menuBarQuotaNow) private var now
    @Environment(\.colorScheme) private var colorScheme
    let account: CodexAccountSnapshot
    var allTitles: [String] = []
    var isMultiAccount: Bool = false
    let isSwitching: Bool
    let onSwitch: (String) -> Void
    let onProviderMessage: (String) -> Void

    private var healthFraction: Double? {
        guard let limits = account.limits else { return nil }
        let fractions = codexMenuBarQuotaRows(for: limits).flatMap { row -> [Double] in
            [row.fiveHourWindow, row.oneWeekWindow].compactMap { window in
                guard let window else { return nil }
                return menuBarQuotaFraction(
                    remainingFraction: window.usedPercent.map { (100 - $0) / 100 },
                    resetAt: window.resetDate,
                    now: now
                )
            }
        }
        return fractions.min()
    }

    private var displayTitle: String {
        menuBarShortAccountName(account.titleText, allIdentifiers: allTitles.isEmpty ? [account.titleText] : allTitles)
    }

    var body: some View {
        let rows = account.limits.map { codexMenuBarQuotaRows(for: $0) } ?? []
        let accent = menuBarToolAccentColor(for: .codex, colorScheme: colorScheme)
        MenuBarHoverRow(hoverTint: accent, accentLeading: isMultiAccount && account.isCurrent ? accent : nil) {
            VStack(alignment: .leading, spacing: 6) {
                if rows.count == 1, let singleRow = rows.first, singleRow.id == "codex" {
                    // Single aligned telemetry row matching the Antigravity column grid (146 | 120 | 120)
                    HStack(alignment: .center, spacing: 8) {
                        accountIdentityColumn(accent: accent)
                        HStack(alignment: .top, spacing: MenuBarGrid.groupColumnGap) {
                            codexGauge(label: String(localized: "5小时余量"), shortBadge: "5H", isFiveHour: true, window: singleRow.fiveHourWindow)
                                .frame(width: MenuBarGrid.groupColumnWidth, alignment: .leading)
                            codexGauge(label: String(localized: "本周余量"), shortBadge: "7D", isFiveHour: false, window: singleRow.oneWeekWindow)
                                .frame(width: MenuBarGrid.groupColumnWidth, alignment: .leading)
                        }
                    }
                } else {
                    HStack(alignment: .center, spacing: 8) {
                        accountIdentityColumn(accent: accent)
                        Spacer(minLength: 4)
                    }
                    if let limits = account.limits {
                        if rows.isEmpty {
                            Text("尚未获取配额")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        } else {
                            CodexMenuBarQuotaRows(limits: limits)
                        }
                    } else if let error = account.usageError {
                        Text(error).font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        Text("尚未获取配额").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }

                if let resetCredits = account.limits?.resetCredits {
                    CodexResetCreditsLine(resetCredits: resetCredits)
                }
            }
        }
    }

    private func accountIdentityColumn(accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                MenuBarHealthDot(fraction: healthFraction, brandAccent: accent)
                Text(displayTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(account.titleText)
            }
            HStack(spacing: 5) {
                if let displaySubscriptionName = account.displaySubscriptionName {
                    Text(displaySubscriptionName)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if isMultiAccount && account.isCurrent {
                    Text("当前")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(accent)
                } else if !account.isCurrent {
                    MenuBarTintedChipButton(
                        title: "切换",
                        accent: accent,
                        isDisabled: isSwitching
                    ) {
                        onSwitch(account.id)
                    }
                }
            }
            .padding(.leading, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func codexGauge(label: String, shortBadge: String, isFiveHour: Bool, window: CodexWindow?) -> some View {
        let state = codexMenuBarDisplayState(for: window, isFiveHour: isFiveHour, now: now)
        MenuBarQuotaPanel(
            tool: .codex,
            title: label,
            shortBadge: shortBadge,
            fraction: state.fraction,
            primaryValue: state.primaryValue,
            countdown: state.countdown,
            footer: state.footer,
            isExpired: state.isExpired
        )
    }
}

private struct CodexResetCreditsLine: View {
    @Environment(\.colorScheme) private var colorScheme
    let resetCredits: CodexResetCredits

    private var availableCredits: [CodexResetCredit] {
        (resetCredits.credits ?? [])
            .filter { ($0.status ?? "").caseInsensitiveCompare("available") == .orderedSame }
            .sorted { lhs, rhs in
            switch (lhs.expiresAt, rhs.expiresAt) {
            case let (left?, right?): return left < right
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return (lhs.title ?? "") < (rhs.title ?? "")
            }
        }
    }

    private var availableCount: Int {
        resetCredits.availableCount ?? availableCredits.count
    }

    private var expiryText: String? {
        let values = availableCredits.compactMap { credit in
            credit.expiresAt.map { menuBarShortResetString(for: $0) }
        }
        guard !values.isEmpty else { return nil }
        return values.joined(separator: ", ")
    }

    var body: some View {
        let accent = menuBarToolAccentColor(for: .codex, colorScheme: colorScheme)
        VStack(alignment: .leading, spacing: 5) {
            MenuBarHairline(opacity: 0.06)
                .padding(.leading, 12)
            HStack(spacing: 5) {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(accent)
                Text("可用重置券")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("\(availableCount)")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(accent)
                if let expiryText {
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text("过期")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(expiryText)
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 12)
        }
        .padding(.top, 2)
    }
}

struct CodexMultiAccountQuotaCard: View {
    @Environment(AppStore.self) private var appStore
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("codex.smartSwitch.enabled") private var codexSmartSwitchEnabled = false
    let accounts: [CodexAccountSnapshot]
    let todayTokens: Int
    @State private var isSwitching = false
    @State private var statusMessage: String?

    var body: some View {
        let allTitles = accounts.map(\.titleText)
        let accent = menuBarToolAccentColor(for: .codex, colorScheme: colorScheme)
        MenuBarToolShell(tool: .codex) {
            MenuBarToolIdentity(
                tool: .codex,
                accountCount: accounts.count > 1 ? accounts.count : nil,
                todayTokens: todayTokens
            ) {
                HStack(spacing: 5) {
                    if codexSmartSwitchEnabled {
                        MenuBarTintedChipButton(
                            title: "智能切换",
                            icon: "sparkles",
                            accent: accent,
                            isDisabled: isSwitching
                        ) {
                            runSwitch(closeWhenNoDecision: false) {
                                try await appStore.codexAccountService.smartSwitch()
                            }
                        }
                    }
                    ConfigShortcutButton(tool: .codex)
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                MenuBarHairline(opacity: 0.06)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                        if index > 0 {
                            MenuBarHairline(opacity: 0.06)
                                .padding(.horizontal, MenuBarGrid.horizontalInset)
                        }
                        CodexAccountQuotaCard(
                            account: account,
                            allTitles: allTitles,
                            isMultiAccount: accounts.count > 1,
                            isSwitching: isSwitching,
                            onSwitch: { id in
                                runSwitch(closeWhenNoDecision: true) {
                                    _ = try await appStore.codexAccountService.switchAccount(id: id, relaunchCodex: true)
                                    return nil as CodexAccountService.SmartSwitchDecision?
                                }
                            },
                            onProviderMessage: { message in
                                statusMessage = message
                            }
                        )
                    }
                    if let statusMessage {
                        Text(statusMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, MenuBarGrid.horizontalInset)
                            .padding(.bottom, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func runSwitch(
        closeWhenNoDecision: Bool,
        _ action: @escaping () async throws -> CodexAccountService.SmartSwitchDecision?
    ) {
        isSwitching = true
        statusMessage = nil
        Task {
            do {
                let decision = try await action()
                if decision != nil || closeWhenNoDecision {
                    GlobalHotkeyService.shared.closeMenuBar()
                }
                await appStore.syncService?.sync(tool: .codex)
                await MainActor.run {
                    isSwitching = false
                    if let decision {
                        statusMessage = decision.isAutomatic
                            ? String(localized: "已自动切换到 \(decision.account.titleText)")
                            : String(localized: "已切换到 \(decision.account.titleText)")
                    } else {
                        statusMessage = String(localized: "当前账号已经是最优选择")
                    }
                }
            } catch {
                let switchError = error.localizedDescription
                // Auth/selection can be committed before the relaunch fails.
                // Read back metadata only: a full sync could auto-switch again.
                do {
                    try await appStore.syncService?.reloadCodexAccountSnapshots()
                } catch {
                    AppLogger.shared.warning("[codex] account snapshot reload after switch failure failed: \(error.localizedDescription)")
                }
                await MainActor.run {
                    isSwitching = false
                    statusMessage = switchError
                }
            }
        }
    }
}

private struct CodexProviderMenuButton: View {
    @Environment(AppStore.self) private var appStore
    @State private var providerState: CodexProviderConfigurationState?
    @State private var routerStatus: CodexRouterStatus?
    @State private var isSwitching = false

    let onMessage: (String) -> Void

    private var currentProviderName: String? {
        guard
            let providerState,
            let provider = providerState.providers.first(where: { $0.id == providerState.currentProviderID })
        else {
            return nil
        }
        return provider.name
    }

    var body: some View {
        Menu {
            if let providerState {
                ForEach(providerState.providers) { provider in
                    Button {
                        if canSwitchProvider(provider) {
                            switchProvider(provider)
                        } else {
                            onMessage(switchDisabledReason(provider) ?? "该 Provider 当前不可用")
                        }
                    } label: {
                        HStack {
                            Text(provider.name)
                            Spacer()
                            if provider.id == providerState.currentProviderID {
                                Image(systemName: "checkmark")
                            } else if provider.defaultModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text("未配模型")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(isSwitching)
                }
            } else {
                Text("读取中…")
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 10, weight: .semibold))
                if let currentProviderName {
                    Text(currentProviderName)
                        .font(.system(size: 10, weight: .bold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text("服务商")
                        .font(.system(size: 10, weight: .bold))
                        .lineLimit(1)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: 112)
            .background(Color.primary.opacity(0.065), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
        .controlSize(.mini)
        .focusEffectDisabled()
        .task {
                if providerState == nil {
                await reloadState()
            }
        }
        .onTapGesture {
            Task {
                await reloadState()
            }
        }
    }

    private func reloadState() async {
        do {
            let state = try await appStore.codexProviderConfigService.loadState()
            let status = await appStore.codexRouterCoordinator.loadStatus()
            await MainActor.run {
                providerState = state
                routerStatus = status
            }
        } catch {
            await MainActor.run {
                providerState = nil
                routerStatus = nil
                onMessage(error.localizedDescription)
            }
        }
    }

    private func switchProvider(_ provider: CodexProviderConfig) {
        isSwitching = true
        let previousProviderID = providerState?.currentProviderID
        Task {
            do {
                let state = try await appStore.codexProviderConfigService.switchProvider(
                    id: provider.id,
                    allowThirdParty: canSwitchProvider(provider)
                )
                let status = await appStore.codexRouterCoordinator.loadStatus()
                await appStore.syncService?.sync(tool: .codex)
                await MainActor.run {
                    providerState = state
                    routerStatus = status
                    isSwitching = false
                    AppLogger.shared.recordDiagnostic(
                        level: .info,
                        scope: CodexRouterDiagnostics.diagnosticScope,
                        message: CodexRouterDiagnostics.switchedToProviderMessage(providerID: provider.id)
                    )
                    onMessage(String(localized: "已切换到 \(provider.name)"))
                    GlobalHotkeyService.shared.closeMenuBar()
                }
            } catch {
                let originalError = error.localizedDescription
                await MainActor.run {
                    AppLogger.shared.recordDiagnostic(
                        level: .warning,
                        scope: CodexRouterDiagnostics.diagnosticScope,
                        message: CodexRouterDiagnostics.switchProviderFailedMessage(
                            target: provider.id,
                            reason: originalError
                        )
                    )
                }
                await MainActor.run {
                    isSwitching = false
                }

                if let previousProviderID, previousProviderID != provider.id {
                    let rollbackID = previousProviderID
                    do {
                        let rollbackState = try await appStore.codexProviderConfigService.switchProvider(
                            id: rollbackID,
                            allowThirdParty: true
                        )
                        let rollbackStatus = await appStore.codexRouterCoordinator.loadStatus()
                        let rollbackSnapshot = describeRollbackTarget(
                            providerID: rollbackID,
                            in: rollbackState,
                            at: Date()
                        )
                        await MainActor.run {
                            providerState = rollbackState
                            routerStatus = rollbackStatus
                            AppLogger.shared.recordDiagnostic(
                                level: .info,
                                scope: CodexRouterDiagnostics.diagnosticScope,
                                message: CodexRouterDiagnostics.rollbackSucceededMessage(snapshot: rollbackSnapshot)
                            )
                            onMessage(CodexRouterDiagnostics.userRollbackNoticeMessage(
                                snapshot: rollbackSnapshot,
                                reason: originalError
                            ))
                        }
                    } catch {
                        await MainActor.run {
                            AppLogger.shared.recordDiagnostic(
                                level: .error,
                                scope: CodexRouterDiagnostics.diagnosticScope,
                                message: CodexRouterDiagnostics.rollbackFailedMessage(
                                    target: provider.id,
                                    fallback: previousProviderID,
                                    reason: error.localizedDescription
                                )
                            )
                        }
                        await MainActor.run {
                            onMessage(CodexRouterDiagnostics.userRollbackFailureMessage(
                                rollbackError: error.localizedDescription,
                                originalReason: originalError
                            ))
                        }
                    }
                } else {
                    await MainActor.run {
                        onMessage(originalError)
                    }
                }
            }
        }
    }

    private func canSwitchProvider(_ provider: CodexProviderConfig) -> Bool {
        if provider.id == CodexRouterConstants.openAIProviderID {
            return true
        }
        guard let routerStatus, routerStatus.canUseRouter else { return false }
        return !provider.defaultModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func switchDisabledReason(_ provider: CodexProviderConfig) -> String? {
        if provider.id == CodexRouterConstants.openAIProviderID {
            return nil
        }
        if provider.defaultModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "该 Provider 未配置默认模型"
        }
        guard let status = routerStatus else {
            return "Router 状态尚未就绪"
        }
        if !status.isConfigured {
            return "未检测到 codex-router 配置"
        }
        if !status.isUserEnabled {
            return "请先在 Providers 中开启 Router"
        }
        if !status.isRouterHealthy {
            return status.healthError ?? "Router 未就绪"
        }
        return nil
    }

    private func describeRollbackTarget(
        providerID: String,
        in state: CodexProviderConfigurationState,
        at timestamp: Date,
    ) -> String {
        CodexRouterDiagnostics.rollbackSnapshot(providerID: providerID, in: state, at: timestamp)
    }
}

// MARK: - Copilot

struct CopilotQuotaCard: View {
    @Environment(\.menuBarQuotaNow) private var now
    let snapshots: [String: CopilotSnapshot]?
    let resetAt: Date?
    let plan: String?
    let fallbackQuota: QuotaRecord?
    let todayTokens: Int
    private var ordered: [(key: String, value: CopilotSnapshot)] {
        guard let s = snapshots else { return [] }
        return s
            .filter { key, _ in
                key != "chat" && key != "completions"
            }
            .sorted { a, b in
            if a.key == "premium_interactions" { return true }
            if b.key == "premium_interactions" { return false }
            return a.key < b.key
        }
    }
    var body: some View {
        MenuBarToolShell(tool: .copilot) {
            MenuBarToolIdentity(
                tool: .copilot,
                subtitle: normalizedCopilotPlanDisplayName(plan),
                todayTokens: todayTokens
            ) {
                ConfigShortcutButton(tool: .copilot)
            }
        } content: {
            VStack(spacing: 0) {
                MenuBarHairline(opacity: 0.06)
                Group {
                    if !ordered.isEmpty {
                        if ordered.count == 1, let snapshot = ordered.first?.value {
                            copilotPanel(for: snapshot)
                        } else {
                            VStack(spacing: 8) {
                                let pairs = stride(from: 0, to: ordered.count, by: 2).map {
                                    Array(ordered[$0..<min($0 + 2, ordered.count)])
                                }
                                ForEach(pairs, id: \.first?.key) { pair in
                                    HStack(alignment: .top, spacing: MenuBarGrid.groupColumnGap) {
                                        ForEach(pair, id: \.key) { item in
                                            copilotPanel(for: item.value)
                                        }
                                        if pair.count == 1 {
                                            Color.clear.frame(maxWidth: .infinity)
                                        }
                                    }
                                }
                            }
                        }
                    } else if let q = fallbackQuota, let r = q.remaining, let t = q.total, t > 0 {
                        let frac = menuBarQuotaFraction(remainingFraction: Double(r) / Double(t), resetAt: q.resetAt, now: now)
                        let used = t - r
                        MenuBarQuotaPanel(
                            tool: .copilot,
                            title: "Copilot 余量",
                            fraction: frac,
                            primaryValue: menuBarQuotaPercentText(frac),
                            countdown: q.resetAt.map { menuBarShortResetString(for: $0) },
                            footer: menuBarQuotaRefreshFooter(resetAt: q.resetAt, now: now) ?? "\(used)/\(t)",
                            isExpired: menuBarQuotaIsExpired(resetAt: q.resetAt, now: now)
                        )
                    } else {
                        MenuBarQuotaUnavailable()
                    }
                }
                .padding(.horizontal, MenuBarGrid.horizontalInset)
                .padding(.top, 10)
                .padding(.bottom, 12)
            }
        }
    }

    private func copilotPanel(for snapshot: CopilotSnapshot) -> some View {
        let isInf = snapshot.unlimited ?? false
        let fraction = menuBarQuotaFraction(
            remainingFraction: snapshot.percentRemaining.map { $0 / 100 },
            resetAt: resetAt,
            now: now
        )
        let countsText: String? = {
            if let remaining = snapshot.remaining, let entitlement = snapshot.entitlement {
                return "\(max(0, remaining))/\(entitlement)"
            }
            return nil
        }()

        return MenuBarQuotaPanel(
            tool: .copilot,
            title: snapshot.displayName,
            fraction: isInf ? 1.0 : fraction,
            primaryValue: isInf ? "∞" : menuBarQuotaPercentText(fraction),
            countdown: resetAt.map { menuBarShortResetString(for: $0) },
            footer: isInf ? countsText : (menuBarQuotaRefreshFooter(resetAt: resetAt, now: now) ?? countsText),
            isExpired: !isInf && menuBarQuotaIsExpired(resetAt: resetAt, now: now)
        )
    }
}

// MARK: - Antigravity

private struct AGMenuBarGroupCard: View {
    @Environment(\.menuBarQuotaNow) private var now
    let group: AGQuotaGroup
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(group.displayName)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            let fiveHourFraction = agQuotaDisplayFraction(for: group.fiveHour)
            let weeklyFraction = agQuotaDisplayFraction(for: group.weekly)
            let fiveHourReset = group.fiveHour?.resetTime.flatMap { $0 > now ? $0 : nil }
            let weeklyReset = group.weekly?.resetTime.flatMap { $0 > now ? $0 : nil }
            let isWeeklyExhausted = weeklyFraction.map { $0 <= 0.001 } ?? false
            let is5hUnusable = isWeeklyExhausted || (fiveHourFraction.map { $0 <= 0.001 } ?? false)
            HStack(alignment: .top, spacing: MenuBarGrid.groupColumnGap) {
                MenuBarQuotaPanel(
                    tool: .antigravity,
                    title: "5小时余量",
                    shortBadge: "5H",
                    fraction: fiveHourFraction,
                    primaryValue: menuBarQuotaPercentText(fiveHourFraction),
                    countdown: fiveHourReset.map { menuBarCompactClockString(for: $0) },
                    footer: isWeeklyExhausted ? String(localized: "本周额度已耗尽") : nil,
                    isExhaustedOverride: is5hUnusable
                )
                MenuBarQuotaPanel(
                    tool: .antigravity,
                    title: "本周余量",
                    shortBadge: "7D",
                    fraction: weeklyFraction,
                    primaryValue: menuBarQuotaPercentText(weeklyFraction),
                    countdown: weeklyReset.map { menuBarShortResetString(for: $0) },
                    footer: nil
                )
            }
        }
    }
}

private struct AGMenuBarColumnDescriptor: Identifiable {
    let id: String
    let fullTitle: String
    let shortTitle: String
}

private struct AGMenuBarMatrixRow: View {
    @Environment(\.menuBarQuotaNow) private var now
    @Environment(\.colorScheme) private var colorScheme
    let account: AGAccountQuota
    let allEmails: [String]
    let columns: [AGMenuBarColumnDescriptor]

    private var healthFraction: Double? {
        let fractions = account.groups.flatMap { group -> [Double] in
            let weekly = agQuotaDisplayFraction(for: group.weekly)
            let fiveHour = agQuotaDisplayFraction(for: group.fiveHour)
            let effectiveFiveHour: Double? = {
                if let weekly, weekly <= 0.001 { return 0 }
                return fiveHour
            }()
            return [effectiveFiveHour, weekly].compactMap { $0 }
        }
        return fractions.min()
    }

    private var displayEmail: String {
        menuBarShortAccountName(account.email, allIdentifiers: allEmails)
    }

    var body: some View {
        let accent = menuBarToolAccentColor(for: .antigravity, colorScheme: colorScheme)
        MenuBarHoverRow(hoverTint: accent) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        MenuBarHealthDot(fraction: healthFraction, brandAccent: accent)
                        Text(displayEmail)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(account.email)
                    }
                    Text(account.badgeLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.leading, 12)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if account.groups.isEmpty {
                    MenuBarQuotaUnavailable()
                        .frame(
                            width: CGFloat(columns.count) * MenuBarGrid.groupColumnWidth
                                + CGFloat(max(0, columns.count - 1)) * MenuBarGrid.groupColumnGap,
                            alignment: .leading
                        )
                } else {
                    HStack(alignment: .center, spacing: 0) {
                        ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                            if index > 0 {
                                Rectangle()
                                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.07))
                                    .frame(width: 0.5, height: 26)
                                    .padding(.horizontal, (MenuBarGrid.groupColumnGap - 0.5) / 2)
                            }
                            groupCells(for: account.groups.first(where: { $0.id == column.id }))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func groupCells(for group: AGQuotaGroup?) -> some View {
        let fiveHourFraction = agQuotaDisplayFraction(for: group?.fiveHour)
        let weeklyFraction = agQuotaDisplayFraction(for: group?.weekly)
        let fiveHourReset = group?.fiveHour?.resetTime.flatMap { $0 > now ? $0 : nil }
        let weeklyReset = group?.weekly?.resetTime.flatMap { $0 > now ? $0 : nil }
        let isWeeklyExhausted = weeklyFraction.map { $0 <= 0.001 } ?? false
        let is5hUnusable = isWeeklyExhausted || (fiveHourFraction.map { $0 <= 0.001 } ?? false)

        HStack(alignment: .top, spacing: MenuBarGrid.cellGap) {
            MenuBarMatrixGauge(
                tool: .antigravity,
                fraction: fiveHourFraction,
                primaryValue: menuBarQuotaPercentText(fiveHourFraction),
                resetText: fiveHourReset.map { menuBarCompactClockString(for: $0) },
                resetHelp: fiveHourReset.map { String(localized: "\(menuBarTimeOnlyResetString(for: $0)) 重置") },
                isExhaustedOverride: is5hUnusable
            )
            MenuBarMatrixGauge(
                tool: .antigravity,
                fraction: weeklyFraction,
                primaryValue: menuBarQuotaPercentText(weeklyFraction),
                resetText: weeklyReset.map { menuBarCompactDateString(for: $0) },
                resetHelp: weeklyReset.map { String(localized: "\(menuBarShortResetString(for: $0)) 重置") }
            )
        }
        .frame(width: MenuBarGrid.groupColumnWidth, alignment: .leading)
    }
}

private struct AGMenuBarAccountQuotaBody: View {
    @Environment(\.colorScheme) private var colorScheme
    let account: AGAccountQuota

    private var healthFraction: Double? {
        let fractions = account.groups.flatMap { group -> [Double] in
            let weekly = agQuotaDisplayFraction(for: group.weekly)
            let fiveHour = agQuotaDisplayFraction(for: group.fiveHour)
            let effectiveFiveHour: Double? = {
                if let weekly, weekly <= 0.001 { return 0 }
                return fiveHour
            }()
            return [effectiveFiveHour, weekly].compactMap { $0 }
        }
        return fractions.min()
    }

    var body: some View {
        let accent = menuBarToolAccentColor(for: .antigravity, colorScheme: colorScheme)
        MenuBarHoverRow(hoverTint: accent) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 6) {
                    MenuBarHealthDot(fraction: healthFraction, brandAccent: accent)
                    Text(account.email)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(account.badgeLabel)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if account.groups.isEmpty {
                    MenuBarQuotaUnavailable()
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(account.groups) { group in
                            AGMenuBarGroupCard(group: group)
                        }
                    }
                }
            }
        }
    }
}

func menuBarVisibleAntigravityAccounts(
    _ accounts: [AGAccountQuota],
    hiddenAccountEmailsRaw: String
) -> [AGAccountQuota] {
    let hiddenEmails = Set(hiddenAccountEmailsRaw.components(separatedBy: ",").filter { !$0.isEmpty })
    return accounts.filter { !hiddenEmails.contains($0.email) }
}

private struct AGDisplayModeSwitcher: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var mode: String
    @Namespace private var switcherNamespace
    @State private var hoveredID: String?

    var body: some View {
        let accent = menuBarToolAccentColor(for: .antigravity, colorScheme: colorScheme)
        HStack(spacing: 1) {
            modeButton(id: "accounts", icon: "list.bullet", help: String(localized: "逐账号"), accent: accent)
            modeButton(id: "aggregate", icon: "square.stack.3d.up", help: String(localized: "聚合 Pro 账号"), accent: accent)
        }
        .padding(2)
        .background(Color.primary.opacity(colorScheme == .dark ? 0.11 : 0.065), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08), lineWidth: 0.5)
        }
        .animation(.smooth(duration: 0.22), value: mode)
    }

    private func modeButton(id: String, icon: String, help: String, accent: Color) -> some View {
        let isSelected = mode == id
        let isHovered = hoveredID == id
        return Button {
            mode = id
        } label: {
            Image(systemName: icon)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(isSelected ? accent : (isHovered ? .primary : .secondary))
                .frame(width: 22, height: 18)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(colorScheme == .dark ? Color.white.opacity(0.18) : Color.white.opacity(0.95))
                            .matchedGeometryEffect(id: "agModeSelection", in: switcherNamespace)
                            .shadow(color: Color.black.opacity(0.08), radius: 1, y: 0.5)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredID = hovering ? id : (hoveredID == id ? nil : hoveredID)
        }
        .focusEffectDisabled()
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Telemetry matrix for Antigravity accounts: column headers once at top,
/// aligned account rows underneath for instant side-by-side comparison.
struct AntigravityMultiAccountCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let accounts: [AGAccountQuota]
    let todayTokens: Int
    @AppStorage("ag.hiddenAccountEmails") private var hiddenAccountEmailsRaw = ""
    @AppStorage("menubar.antigravityDisplayMode") private var antigravityDisplayMode = "accounts"

    private var visibleAccounts: [AGAccountQuota] {
        menuBarVisibleAntigravityAccounts(accounts, hiddenAccountEmailsRaw: hiddenAccountEmailsRaw)
    }

    private var matrixColumns: [AGMenuBarColumnDescriptor] {
        var seen: Set<String> = []
        var result: [AGMenuBarColumnDescriptor] = []
        for account in visibleAccounts {
            for group in account.groups where seen.insert(group.id).inserted {
                result.append(
                    AGMenuBarColumnDescriptor(
                        id: group.id,
                        fullTitle: group.displayName,
                        shortTitle: menuBarShortAGGroupTitle(group.displayName)
                    )
                )
            }
        }
        return result
    }

    var body: some View {
        let visible = visibleAccounts
        let columns = matrixColumns
        let allEmails = visible.map(\.email)
        let accent = menuBarToolAccentColor(for: .antigravity, colorScheme: colorScheme)

        MenuBarToolShell(tool: .antigravity) {
            MenuBarToolIdentity(
                tool: .antigravity,
                accountCount: visible.count > 1 ? visible.count : nil,
                todayTokens: todayTokens
            ) {
                HStack(spacing: 5) {
                    if visible.count > 1 {
                        AGDisplayModeSwitcher(mode: $antigravityDisplayMode)
                    }
                    ConfigShortcutButton(tool: .antigravity)
                }
            }
        } content: {
            if visible.isEmpty {
                Text("暂无可用账号额度")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, MenuBarGrid.horizontalInset)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if !columns.isEmpty && columns.count <= 2 {
                VStack(spacing: 0) {
                    // Column header strip printed once, gently tinted with provider accent
                    HStack(alignment: .bottom, spacing: 8) {
                        Text("ACCOUNT")
                            .font(.system(size: 8.5, weight: .bold))
                            .tracking(0.5)
                            .foregroundStyle(.secondary.opacity(0.75))
                            .padding(.leading, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(alignment: .bottom, spacing: MenuBarGrid.groupColumnGap) {
                            ForEach(columns) { column in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(column.shortTitle.uppercased())
                                        .font(.system(size: 9, weight: .bold))
                                        .tracking(0.4)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .help(column.fullTitle)
                                    HStack(spacing: MenuBarGrid.cellGap) {
                                        Text("5H")
                                            .frame(width: MenuBarGrid.cellWidth, alignment: .leading)
                                        Text("7D")
                                            .frame(width: MenuBarGrid.cellWidth, alignment: .leading)
                                    }
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                }
                                .frame(width: MenuBarGrid.groupColumnWidth, alignment: .leading)
                            }
                        }
                    }
                    .padding(.horizontal, MenuBarGrid.horizontalInset)
                    .padding(.vertical, 5.5)
                    .background(accent.opacity(colorScheme == .dark ? 0.08 : 0.045))

                    MenuBarHairline(opacity: 0.08)

                    VStack(spacing: 0) {
                        ForEach(Array(visible.enumerated()), id: \.element.id) { index, account in
                            if index > 0 {
                                MenuBarHairline(opacity: 0.06)
                                    .padding(.horizontal, MenuBarGrid.horizontalInset)
                            }
                            AGMenuBarMatrixRow(
                                account: account,
                                allEmails: allEmails,
                                columns: columns
                            )
                        }
                    }
                    .padding(.vertical, 3)
                }
            } else {
                VStack(spacing: 0) {
                    MenuBarHairline(opacity: 0.06)
                    VStack(spacing: 0) {
                        ForEach(Array(visible.enumerated()), id: \.element.id) { index, account in
                            if index > 0 {
                                MenuBarHairline(opacity: 0.06)
                                    .padding(.horizontal, MenuBarGrid.horizontalInset)
                            }
                            AGMenuBarAccountQuotaBody(account: account)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }
}

struct AntigravityAggregateCard: View {
    let accounts: [AGAccountQuota]
    let todayTokens: Int
    @AppStorage("ag.hiddenAccountEmails") private var hiddenAccountEmailsRaw = ""
    @AppStorage("menubar.antigravityDisplayMode") private var antigravityDisplayMode = "accounts"

    private var visibleAccounts: [AGAccountQuota] {
        menuBarVisibleAntigravityAccounts(accounts, hiddenAccountEmailsRaw: hiddenAccountEmailsRaw)
    }

    var body: some View {
        let visible = visibleAccounts
        let summary = visible.isEmpty ? nil : AntigravityProAggregator.aggregate(accounts: visible)

        MenuBarToolShell(tool: .antigravity) {
            MenuBarToolIdentity(
                tool: .antigravity,
                subtitle: summary.map { String(localized: "账号额度聚合 (\($0.proAccountCount)个账号)") },
                todayTokens: todayTokens
            ) {
                HStack(spacing: 5) {
                    if visible.count > 1 {
                        AGDisplayModeSwitcher(mode: $antigravityDisplayMode)
                    }
                    ConfigShortcutButton(tool: .antigravity)
                }
            }
        } content: {
            VStack(spacing: 0) {
                MenuBarHairline(opacity: 0.06)
                if let summary {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(summary.groups) { group in
                            AGMenuBarGroupCard(group: group)
                        }
                    }
                    .padding(.horizontal, MenuBarGrid.horizontalInset)
                    .padding(.top, 10)
                    .padding(.bottom, 12)
                } else {
                    Text("暂无可用账号额度")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, MenuBarGrid.horizontalInset)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// Content for a single Antigravity account (email + tier badge + quota groups).
struct AntigravityAccountSection: View {
    let account: AGAccountQuota
    @AppStorage("ag.hiddenAccountEmails") private var hiddenAccountEmailsRaw = ""

    private var isAccountHidden: Bool {
        Set(hiddenAccountEmailsRaw.components(separatedBy: ",").filter { !$0.isEmpty }).contains(account.email)
    }

    var body: some View {
        if isAccountHidden { EmptyView() } else {
            AGMenuBarAccountQuotaBody(account: account)
        }
    }
}

struct AntigravityFallbackCard: View {
    @Environment(\.menuBarQuotaNow) private var now
    let quota: QuotaRecord
    let todayTokens: Int
    var body: some View {
        MenuBarToolShell(tool: .antigravity) {
            MenuBarToolIdentity(
                tool: .antigravity,
                todayTokens: todayTokens
            ) {
                ConfigShortcutButton(tool: .antigravity)
            }
        } content: {
            VStack(spacing: 0) {
                MenuBarHairline(opacity: 0.06)
                Group {
                    if let r = quota.remaining, let t = quota.total, t > 0 {
                        let frac = menuBarQuotaFraction(remainingFraction: Double(r) / Double(t), resetAt: quota.resetAt, now: now)
                        MenuBarQuotaPanel(
                            tool: .antigravity,
                            title: "总余量",
                            fraction: frac,
                            primaryValue: menuBarQuotaPercentText(frac),
                            countdown: quota.resetAt.map { menuBarShortResetString(for: $0) },
                            footer: menuBarQuotaRefreshFooter(resetAt: quota.resetAt, now: now),
                            isExpired: menuBarQuotaIsExpired(resetAt: quota.resetAt, now: now)
                        )
                    } else {
                        MenuBarQuotaUnavailable()
                    }
                }
                .padding(.horizontal, MenuBarGrid.horizontalInset)
                .padding(.top, 10)
                .padding(.bottom, 12)
            }
        }
    }
}

// MARK: - Window capture for global hotkey

/// Invisible background view that registers the MenuBarExtra window with GlobalHotkeyService
/// each time the popover opens. Uses viewDidMoveToWindow which fires reliably on every open.
private struct MenuBarWindowCapture: NSViewRepresentable {
    func makeNSView(context: Context) -> _MenuBarCaptureView { _MenuBarCaptureView() }
    func updateNSView(_ nsView: _MenuBarCaptureView, context: Context) {}
}

final class _MenuBarCaptureView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        Task { @MainActor in
            AppLogger.shared.recordDiagnostic(scope: "menubar.open", message: "menu bar window attached")
        }
    }
}
