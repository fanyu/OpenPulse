import SwiftUI
import SwiftData
import AppKit

// MARK: - Quota Telemetry Clock Environment

private struct QuotaTelemetryNowKey: EnvironmentKey {
    static var defaultValue: Date { Date() }
}

private extension EnvironmentValues {
    var quotaTelemetryNow: Date {
        get { self[QuotaTelemetryNowKey.self] }
        set { self[QuotaTelemetryNowKey.self] = newValue }
    }
}

// MARK: - QuotaView (Root)

/// 配额页：与菜单栏统一的 Liquid Glass 遥测设计语言，按工具隔离观测与渲染。
struct QuotaView: View {
    @State private var selectedTool: Tool? = nil
    @State private var isWideLayout = true
    @AppStorage("menubar.toolOrder") private var toolOrderRaw = Tool.defaultOrderRaw

    private var orderedTools: [Tool] {
        Tool.orderedTools(from: toolOrderRaw)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                QuotaDashboardHeaderBar()

                QuotaToolFilterBar(
                    selectedTool: $selectedTool,
                    orderedTools: orderedTools
                )

                QuotaTelemetryDeck(
                    selectedTool: selectedTool,
                    orderedTools: orderedTools,
                    isWideLayout: isWideLayout
                )
            }
            .frame(maxWidth: 1120, alignment: .leading)
            .padding(.horizontal, isWideLayout ? 28 : 20)
            .padding(.top, 8)
            .padding(.bottom, 26)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollEdgeEffectStyle(.soft, for: .vertical)
        .onGeometryChange(for: Bool.self) { proxy in
            proxy.size.width >= 820
        } action: { wide in
            if isWideLayout != wide {
                isWideLayout = wide
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .navigationTitle("配额仪表盘")
    }
}

// MARK: - Canonical Data Helpers (Public/Internal API preserved for tests)

/// Canonical daily-stat aggregates for the quota dashboard.
struct QuotaUsageTotals {
    let today: Int
    let week: Int
    let total: Int
    let byTool: [Tool: Int]

    static func summarize(_ records: [DailyStatsRecord], at date: Date, calendar: Calendar) -> Self {
        let todayStart = calendar.startOfDay(for: date)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? todayStart
        var today = 0
        var week = 0
        var total = 0
        var byTool: [Tool: Int] = [:]
        for record in records where record.date < tomorrow {
            let tokens = record.totalInputTokens + record.totalOutputTokens
            total += tokens
            if record.date >= weekStart { week += tokens }
            if record.date >= todayStart {
                today += tokens
                byTool[record.tool, default: 0] += tokens
            }
        }
        return Self(today: today, week: week, total: total, byTool: byTool)
    }
}

/// A deadline passing invalidates the saved window; it cannot establish that
/// a newly started server window is unused.
struct CodexQuotaWindowDisplay {
    let isStale: Bool
    let used: Int?
    let remaining: Int?
    let fraction: Double?

    init(window: CodexWindow?, at now: Date) {
        isStale = window?.resetDate.map { $0 <= now } ?? false
        guard !isStale, let usedPercent = window?.usedPercent, usedPercent.isFinite else {
            used = nil
            remaining = nil
            fraction = nil
            return
        }
        let clamped = min(100, max(0, usedPercent))
        used = Int(clamped.rounded())
        remaining = 100 - Int(clamped.rounded())
        fraction = (100 - clamped) / 100
    }
}

// MARK: - Dashboard Header (Liquid Glass, unified with MenuBarHeader)

private struct QuotaDashboardHeaderBar: View {
    @Environment(AppStore.self) private var appStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var logger = AppLogger.shared
    @Namespace private var glassNamespace

    private var isSyncing: Bool { appStore.syncService?.isSyncingActive ?? false }
    private var lastSync: Date? { appStore.syncService?.lastSyncDate ?? appStore.lastSyncDate }
    private var syncError: String? { appStore.syncService?.syncError }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("配额仪表盘")
                    .font(.system(size: 28, weight: .semibold))
                    .tracking(-0.4)

                HStack(spacing: 10) {
                    Text("查看各工具实时可用额度、重置倒计时与多账号状态。")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    statusIndicator
                }
            }

            Spacer(minLength: 12)

            GlassEffectContainer(spacing: 8) {
                Button {
                    guard !isSyncing else { return }
                    Task { await appStore.syncService?.sync() }
                } label: {
                    Group {
                        if isSyncing {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12, weight: .semibold))
                        }
                    }
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .glassEffect(.regular.interactive(), in: .circle)
                .glassEffectID("quotaRefresh", in: glassNamespace)
                .focusEffectDisabled()
                .keyboardShortcut("r", modifiers: .command)
                .help(isSyncing ? String(localized: "同步中…") : String(localized: "刷新同步 (⌘R)"))
                .accessibilityLabel("刷新同步")
            }
            .animation(.smooth(duration: 0.25), value: isSyncing)
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if isSyncing {
            HStack(spacing: 5) {
                Text("·").foregroundStyle(.tertiary)
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.75)
                Text("数据同步中...")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
        } else if let syncError {
            HStack(spacing: 5) {
                Text("·").foregroundStyle(.tertiary)
                Button {
                    appStore.openDiagnosticsLogs()
                } label: {
                    Label("同步出现问题", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(quotaWarningColor(colorScheme: colorScheme))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(logger.latestPersistentSyncError?.summary ?? syncError)
            }
        } else if let lastSync {
            HStack(spacing: 5) {
                Text("·").foregroundStyle(.tertiary)
                Text("最近同步于 \(lastSync.formatted(.dateTime.hour().minute()))")
                    .monospacedDigit()
                    .help(lastSync.formatted(date: .abbreviated, time: .shortened))
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Tool Filter Bar (Liquid Glass Capsule Rail)

private struct QuotaToolFilterBar: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selectedTool: Tool?
    let orderedTools: [Tool]
    @Namespace private var filterNamespace

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                QuotaToolFilterPill(
                    label: String(localized: "全部"),
                    tool: nil,
                    isSelected: selectedTool == nil,
                    namespace: filterNamespace
                ) {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
                        selectedTool = nil
                    }
                }

                ForEach(orderedTools, id: \.self) { tool in
                    QuotaToolFilterPill(
                        label: tool.displayName,
                        tool: tool,
                        isSelected: selectedTool == tool,
                        namespace: filterNamespace
                    ) {
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
                            selectedTool = selectedTool == tool ? nil : tool
                        }
                    }
                }
            }
            .padding(3)
            .background(
                Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.045),
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.07), lineWidth: 0.5)
            }
        }
    }
}

private struct QuotaToolFilterPill: View {
    @Environment(\.colorScheme) private var colorScheme
    let label: String
    let tool: Tool?
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        let accent = tool?.brandAccentColor(for: colorScheme)
        Button(action: action) {
            HStack(spacing: 6) {
                if let tool {
                    ToolLogoImage(tool: tool, size: 13)
                        .opacity(isSelected ? 1.0 : (isHovered ? 0.9 : 0.72))
                }
                Text(label)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(
                        isSelected
                            ? (accent ?? Color.primary)
                            : (isHovered ? Color.primary : Color.secondary)
                    )
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background {
                if isSelected {
                    Capsule()
                        .fill(
                            colorScheme == .dark
                                ? Color.white.opacity(0.14)
                                : Color.white.opacity(0.95)
                        )
                        .overlay {
                            if let accent {
                                Capsule()
                                    .strokeBorder(accent.opacity(colorScheme == .dark ? 0.34 : 0.24), lineWidth: 0.6)
                            }
                        }
                        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.06), radius: 2, y: 1)
                        .matchedGeometryEffect(id: "quotaFilterSelection", in: namespace)
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
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Telemetry Deck (Single Timeline + Isolated Query + Balanced Row Packing)

private enum QuotaDeckRow: Identifiable {
    case full(Tool)
    case pair(Tool, Tool)

    var id: String {
        switch self {
        case .full(let tool): "full-\(tool.rawValue)"
        case .pair(let lhs, let rhs): "pair-\(lhs.rawValue)-\(rhs.rawValue)"
        }
    }
}

private struct QuotaTelemetryDeck: View {
    @Environment(AppStore.self) private var appStore
    @Query(sort: \QuotaRecord.updatedAt, order: .reverse) private var quotas: [QuotaRecord]
    let selectedTool: Tool?
    let orderedTools: [Tool]
    let isWideLayout: Bool

    /// O(N) pre-index so tool hosts never rescan `quotas` linearly.
    private var fallbackByTool: [Tool: QuotaRecord] {
        var map: [Tool: QuotaRecord] = [:]
        map.reserveCapacity(Tool.allCases.count)
        for record in quotas {
            guard let tool = Tool(rawValue: record.toolRaw) else { continue }
            if tool == .codex && record.accountKey != nil { continue }
            if map[tool] == nil {
                map[tool] = record
            }
        }
        return map
    }

    private func prefersFullWidth(_ tool: Tool) -> Bool {
        switch tool {
        case .antigravity:
            return !(appStore.syncService?.latestAntigravityAccounts?.isEmpty ?? true)
        case .codex:
            return !(appStore.syncService?.latestCodexAccounts.isEmpty ?? true)
        case .claudeCode, .copilot:
            return false
        }
    }

    private var packedRows: [QuotaDeckRow] {
        guard isWideLayout else {
            return orderedTools.map { .full($0) }
        }
        var rows: [QuotaDeckRow] = []
        var pendingCompact: Tool?
        for tool in orderedTools {
            if prefersFullWidth(tool) {
                if let pending = pendingCompact {
                    rows.append(.full(pending))
                    pendingCompact = nil
                }
                rows.append(.full(tool))
            } else if let pending = pendingCompact {
                rows.append(.pair(pending, tool))
                pendingCompact = nil
            } else {
                pendingCompact = tool
            }
        }
        if let pending = pendingCompact {
            rows.append(.full(pending))
        }
        return rows
    }

    var body: some View {
        let fallbacks = fallbackByTool
        // Single 60s clock shared across every tool card — replaces per-row TimelineViews.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 16) {
                if let selectedTool {
                    toolHost(for: selectedTool, fallback: fallbacks[selectedTool], isFullWidth: true)
                } else {
                    ForEach(packedRows) { row in
                        switch row {
                        case .full(let tool):
                            toolHost(for: tool, fallback: fallbacks[tool], isFullWidth: true)
                        case .pair(let lhs, let rhs):
                            HStack(alignment: .top, spacing: 16) {
                                toolHost(for: lhs, fallback: fallbacks[lhs], isFullWidth: false)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                                toolHost(for: rhs, fallback: fallbacks[rhs], isFullWidth: false)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                        }
                    }
                }
            }
            .environment(\.quotaTelemetryNow, context.date)
        }
    }

    @ViewBuilder
    private func toolHost(for tool: Tool, fallback: QuotaRecord?, isFullWidth: Bool) -> some View {
        switch tool {
        case .claudeCode:
            QuotaClaudeCardHost(fallbackQuota: fallback)
        case .codex:
            QuotaCodexCardHost(fallbackQuota: fallback, isWideRow: isWideLayout && isFullWidth)
        case .copilot:
            QuotaCopilotCardHost(fallbackQuota: fallback)
        case .antigravity:
            QuotaAntigravityCardHost(fallbackQuota: fallback, isWideRow: isWideLayout && isFullWidth)
        }
    }
}

// MARK: - Telemetry Visual Primitives (Unified with MenuBarView, Zero-GeometryReader Bars)

private func quotaWarningColor(colorScheme: ColorScheme) -> Color {
    colorScheme == .dark
        ? Color(red: 0.96, green: 0.65, blue: 0.14)
        : Color(red: 0.86, green: 0.51, blue: 0.00)
}

private func quotaCriticalColor(colorScheme: ColorScheme) -> Color {
    colorScheme == .dark
        ? Color(red: 1.00, green: 0.36, blue: 0.36)
        : Color(red: 0.86, green: 0.21, blue: 0.21)
}

private func quotaBarColor(fraction: Double?, tool: Tool, colorScheme: ColorScheme) -> Color {
    guard let fraction else { return Color.primary.opacity(0.16) }
    if fraction <= 0.001 { return Color.primary.opacity(0.16) }
    if fraction < 0.15 { return quotaCriticalColor(colorScheme: colorScheme) }
    if fraction < 0.40 { return quotaWarningColor(colorScheme: colorScheme) }
    return tool.brandAccentColor(for: colorScheme)
}

private func quotaPercentText(_ fraction: Double?) -> String {
    fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
}

private func quotaCompactClock(_ date: Date) -> String {
    let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
    return String(format: "%02d:%02d", comps.hour ?? 0, comps.minute ?? 0)
}

private func quotaCompactDate(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) {
        return quotaCompactClock(date)
    }
    let comps = calendar.dateComponents([.month, .day], from: date)
    return String(format: "%02d/%02d", comps.month ?? 0, comps.day ?? 0)
}

private func quotaShortResetString(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) {
        return quotaCompactClock(date)
    }
    let comps = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
    return String(format: "%02d/%02d %02d:%02d", comps.month ?? 0, comps.day ?? 0, comps.hour ?? 0, comps.minute ?? 0)
}

private func quotaShortAGGroupTitle(_ displayName: String) -> String {
    let lower = displayName.lowercased()
    if lower == "gemini models" { return "Gemini" }
    if lower == "claude and gpt models" { return "Claude & GPT" }
    return displayName
}

/// Zero-GeometryReader capsule fill shape for smooth 120fps scrolling & live window resizing.
private struct QuotaCapsuleFillShape: Shape {
    var fraction: Double
    var minWidth: CGFloat

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        guard fraction > 0.001, rect.width > 0, rect.height > 0 else { return Path() }
        let clamped = max(0, min(1, fraction))
        let width = min(rect.width, max(minWidth, rect.width * CGFloat(clamped)))
        return Path(
            roundedRect: CGRect(x: 0, y: 0, width: width, height: rect.height),
            cornerRadius: rect.height / 2,
            style: .continuous
        )
    }
}

/// Precision luminous progress bar matching MenuBarLuminousBar without GeometryReader layout passes.
private struct QuotaLuminousBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    let fraction: Double?
    let color: Color
    var height: CGFloat = 5
    var isExhausted: Bool = false

    private var effectiveFraction: Double {
        guard !isExhausted, let fraction, fraction.isFinite else { return 0 }
        return max(0, min(1, fraction))
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.15 : 0.095))

            if effectiveFraction > 0.001 {
                QuotaCapsuleFillShape(fraction: effectiveFraction, minWidth: height)
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.80), color],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .overlay(alignment: .top) {
                        QuotaCapsuleFillShape(fraction: effectiveFraction, minWidth: height)
                            .fill(Color.white.opacity(colorScheme == .dark ? 0.24 : 0.36))
                            .frame(height: 1)
                    }
                    .shadow(color: color.opacity(colorScheme == .dark ? 0.28 : 0.18), radius: 2, y: 0.75)
                    .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.9), value: effectiveFraction)
            }
        }
        .frame(height: height)
    }
}

private struct QuotaHairline: View {
    @Environment(\.colorScheme) private var colorScheme
    var opacity: Double? = nil

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(opacity ?? (colorScheme == .dark ? 0.10 : 0.07)))
            .frame(height: 0.5)
    }
}

/// Provider plate with soft top-leading radial brand glow & specular rim — mirrors MenuBarToolShell.
private struct QuotaToolShell<Identity: View, Content: View>: View {
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
        let accent = tool.brandAccentColor(for: colorScheme)
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

        VStack(alignment: .leading, spacing: 0) {
            identity
                .padding(.horizontal, 18)
                .padding(.vertical, 13)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background {
            ZStack(alignment: .topLeading) {
                shape
                    .fill(
                        Color(nsColor: .controlBackgroundColor)
                            .opacity(colorScheme == .dark ? 0.78 : 0.94)
                    )
                RadialGradient(
                    colors: [
                        accent.opacity(colorScheme == .dark ? 0.16 : 0.09),
                        accent.opacity(colorScheme == .dark ? 0.04 : 0.018),
                        Color.clear
                    ],
                    center: UnitPoint(x: 0.05, y: 0.0),
                    startRadius: 6,
                    endRadius: 260
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
                                : Color.white.opacity(0.94),
                            accent.opacity(colorScheme == .dark ? 0.16 : 0.12),
                            Color.primary.opacity(colorScheme == .dark ? 0.13 : 0.085)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.75
                )
        }
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.24 : 0.045),
            radius: 5,
            x: 0,
            y: 2
        )
    }
}

private struct QuotaToolHeader<Accessory: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let tool: Tool
    var subtitle: String? = nil
    var subtitleHelp: String? = nil
    var accountCount: Int? = nil
    var isRefreshing: Bool = false
    let onRefresh: () -> Void
    @ViewBuilder let accessory: () -> Accessory

    init(
        tool: Tool,
        subtitle: String? = nil,
        subtitleHelp: String? = nil,
        accountCount: Int? = nil,
        isRefreshing: Bool = false,
        onRefresh: @escaping () -> Void,
        @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }
    ) {
        self.tool = tool
        self.subtitle = subtitle
        self.subtitleHelp = subtitleHelp
        self.accountCount = accountCount
        self.isRefreshing = isRefreshing
        self.onRefresh = onRefresh
        self.accessory = accessory
    }

    var body: some View {
        let accent = tool.brandAccentColor(for: colorScheme)
        HStack(alignment: .center, spacing: 10) {
            ToolBrandIconWell(tool: tool, size: 28, iconSize: 16)

            HStack(alignment: .center, spacing: 7) {
                Text(tool.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(-0.2)
                    .lineLimit(1)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(accent)
                        .padding(.horizontal, 6.5)
                        .padding(.vertical, 2)
                        .background(accent.opacity(colorScheme == .dark ? 0.18 : 0.12), in: Capsule())
                        .lineLimit(1)
                        .help(subtitleHelp ?? "")
                }

                if let accountCount, accountCount > 1 {
                    Text("\(accountCount)")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(accent)
                        .padding(.horizontal, 6.5)
                        .padding(.vertical, 2)
                        .background(accent.opacity(colorScheme == .dark ? 0.18 : 0.12), in: Capsule())
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                accessory()
                QuotaIconButton(
                    systemName: "arrow.clockwise",
                    isSpinning: isRefreshing,
                    helpText: isRefreshing ? String(localized: "正在刷新") : String(localized: "刷新配额"),
                    action: onRefresh
                )
                QuotaConfigButton(tool: tool)
            }
        }
    }
}

private struct QuotaIconButton: View {
    let systemName: String
    var isSpinning: Bool = false
    let helpText: String
    var size: CGFloat = 24
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Group {
                if isSpinning {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.72)
                } else {
                    Image(systemName: systemName)
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .frame(width: size, height: size)
            .background(
                isHovered ? Color.primary.opacity(0.08) : Color.clear,
                in: Circle()
            )
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isHovered ? .primary : .secondary)
        .disabled(isSpinning)
        .focusEffectDisabled()
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .help(helpText)
        .accessibilityLabel(helpText)
    }
}

private struct QuotaConfigButton: View {
    let tool: Tool

    private var configFile: ToolConfigFileEntry? {
        ToolConfigFileEntry.entries(for: tool).first
    }

    var body: some View {
        if let configFile {
            QuotaIconButton(
                systemName: "gearshape",
                helpText: String(localized: "打开 \(configFile.displayName)")
            ) {
                if FileManager.default.fileExists(atPath: configFile.url.path) {
                    NSWorkspace.shared.open(configFile.url)
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([configFile.url.deletingLastPathComponent()])
                }
            }
        }
    }
}

private struct QuotaTintedChipButton: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    var icon: String? = nil
    let accent: Color
    var isDisabled: Bool = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 9.5, weight: .semibold))
                }
                Text(LocalizedStringKey(title))
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(accent)
            .padding(.horizontal, 8)
            .frame(height: 22)
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

private struct QuotaHoverRow<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let hoverTint: Color
    var accentLeading: Color? = nil
    @ViewBuilder let content: () -> Content
    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .leading) {
            content()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    isHovered
                        ? hoverTint.opacity(colorScheme == .dark ? 0.11 : 0.055)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
            if let accentLeading {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(accentLeading)
                    .frame(width: 2.5, height: 26)
                    .padding(.leading, 1)
            }
        }
        .padding(.horizontal, 6)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovered = hovering
            }
        }
    }
}

/// Primary telemetry gauge panel matching MenuBarQuotaPanel, scaled comfortably for the desktop dashboard.
private struct QuotaTelemetryPanel: View {
    @Environment(\.colorScheme) private var colorScheme
    let tool: Tool
    let title: String
    var shortBadge: String? = nil
    let fraction: Double?
    let primaryValue: String
    let countdown: String?
    var footer: String? = nil
    var isExpired: Bool = false
    var expiredDetail: String? = nil
    var isExhaustedOverride: Bool? = nil
    var compactMetric: Bool = false

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
        if fraction < 0.15 { return quotaCriticalColor(colorScheme: colorScheme) }
        if fraction < 0.40 { return quotaWarningColor(colorScheme: colorScheme) }
        return .primary
    }

    private var trailingHelp: String {
        if isExpired {
            let base = String(localized: "等待更新")
            if let expiredDetail, !expiredDetail.isEmpty {
                return "\(base) · \(expiredDetail)"
            }
            if let countdown {
                return "\(base) · \(String(localized: "\(countdown) 重置"))"
            }
            return base
        }
        if let countdown {
            return String(localized: "\(countdown) 重置")
        }
        return ""
    }

    var body: some View {
        let barColor = isExhausted
            ? Color.primary.opacity(0.16)
            : quotaBarColor(fraction: fraction, tool: tool, colorScheme: colorScheme)

        VStack(alignment: .leading, spacing: compactMetric ? 5 : 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let shortBadge {
                    Text(shortBadge)
                        .font(.system(size: compactMetric ? 10 : 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .help(Text(LocalizedStringKey(title)))
                } else {
                    Text(LocalizedStringKey(title))
                        .font(.system(size: compactMetric ? 11 : 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(primaryValue)
                    .font(.system(size: compactMetric ? 14.5 : 17.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(valueColor)
                    .lineLimit(1)

                Spacer(minLength: 6)

                if isExpired {
                    Text("待更新")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(quotaWarningColor(colorScheme: colorScheme))
                        .lineLimit(1)
                        .help(trailingHelp)
                } else if let countdown {
                    Text(countdown)
                        .font(.system(size: compactMetric ? 10 : 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary.opacity(0.88))
                        .lineLimit(1)
                        .help(trailingHelp)
                }
            }

            QuotaLuminousBar(
                fraction: fraction,
                color: barColor,
                height: compactMetric ? 4.5 : 5.5,
                isExhausted: isExhausted
            )

            if let footer, !footer.isEmpty {
                Text(LocalizedStringKey(footer))
                    .font(.system(size: 10.5, weight: isExhausted ? .medium : .regular))
                    .monospacedDigit()
                    .foregroundStyle(isExhausted ? quotaWarningColor(colorScheme: colorScheme) : Color.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Compact matrix cell matching MenuBarMatrixGauge, with zero-GeometryReader luminous micro-bar.
private struct QuotaMatrixGauge: View {
    @Environment(\.colorScheme) private var colorScheme
    let tool: Tool
    let fraction: Double?
    let primaryValue: String
    let resetText: String?
    let resetHelp: String?
    var isExhaustedOverride: Bool? = nil
    var cellWidth: CGFloat = 76

    private var isExhausted: Bool {
        isExhaustedOverride ?? ((fraction ?? 1.0) <= 0.001 || primaryValue == "0%")
    }

    private var isUnknown: Bool {
        fraction == nil && primaryValue == "—"
    }

    private var valueColor: Color {
        if isUnknown { return Color.secondary.opacity(0.50) }
        if isExhausted { return Color.secondary }
        guard let fraction else { return .primary }
        if fraction < 0.15 { return quotaCriticalColor(colorScheme: colorScheme) }
        if fraction < 0.40 { return quotaWarningColor(colorScheme: colorScheme) }
        return .primary
    }

    var body: some View {
        let barColor = isExhausted
            ? Color.primary.opacity(0.14)
            : quotaBarColor(fraction: fraction, tool: tool, colorScheme: colorScheme).opacity(0.90)

        VStack(alignment: .leading, spacing: 4) {
            Text(primaryValue)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(valueColor)
                .lineLimit(1)

            QuotaLuminousBar(
                fraction: fraction,
                color: barColor,
                height: 3.5,
                isExhausted: isExhausted
            )

            if let resetText, !resetText.isEmpty {
                Text(resetText)
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(width: cellWidth, alignment: .leading)
        .help(resetHelp ?? "")
    }
}

private struct QuotaUnavailableRow: View {
    var message: LocalizedStringKey = "尚未获取额度"

    var body: some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Claude Code Card

private struct QuotaClaudeCardHost: View {
    @Environment(AppStore.self) private var appStore
    @Environment(\.quotaTelemetryNow) private var now
    @State private var localRefreshInFlight = false
    let fallbackQuota: QuotaRecord?

    private var isRefreshing: Bool {
        localRefreshInFlight || (appStore.syncService?.states[.claudeCode].isRefreshing ?? false)
    }

    var body: some View {
        let usage = appStore.syncService?.latestClaudeUsage
        let accountInfo = appStore.syncService?.latestClaudeAccountInfo

        QuotaToolShell(tool: .claudeCode) {
            QuotaToolHeader(
                tool: .claudeCode,
                subtitle: accountInfo?.displaySubscriptionName,
                isRefreshing: isRefreshing,
                onRefresh: refresh
            )
        } content: {
            VStack(spacing: 0) {
                QuotaHairline(opacity: 0.06)
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
                        let fiveHourUsed = fiveHourFraction.map { Int(((1 - $0) * 100).rounded()) }
                        let weeklyUsed = weeklyFraction.map { Int(((1 - $0) * 100).rounded()) }

                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .top, spacing: 18) {
                                QuotaTelemetryPanel(
                                    tool: .claudeCode,
                                    title: "5小时余量",
                                    shortBadge: "5H",
                                    fraction: fiveHourFraction,
                                    primaryValue: quotaPercentText(fiveHourFraction),
                                    countdown: usage.fiveHour?.resetDate.map { quotaCompactClock($0) },
                                    footer: isWeeklyExhausted
                                        ? String(localized: "本周额度已耗尽")
                                        : fiveHourUsed.map { String(localized: "已用 \($0)%") },
                                    isExpired: menuBarQuotaIsExpired(resetAt: usage.fiveHour?.resetDate, now: now),
                                    isExhaustedOverride: isWeeklyExhausted ? true : nil
                                )
                                QuotaTelemetryPanel(
                                    tool: .claudeCode,
                                    title: "本周余量",
                                    shortBadge: "7D",
                                    fraction: weeklyFraction,
                                    primaryValue: quotaPercentText(weeklyFraction),
                                    countdown: usage.sevenDay?.resetDate.map { quotaShortResetString($0) },
                                    footer: weeklyUsed.map { String(localized: "已用 \($0)%") },
                                    isExpired: menuBarQuotaIsExpired(resetAt: usage.sevenDay?.resetDate, now: now)
                                )
                            }

                            if let limitResets = usage.cedarEmber, limitResets.hasDisplayableResets(now: now) {
                                QuotaClaudeLimitResetsLine(limitResets: limitResets, now: now)
                            }
                        }
                    } else if let q = fallbackQuota, let r = q.remaining, let t = q.total, t > 0 {
                        let frac = menuBarQuotaFraction(remainingFraction: Double(r) / Double(t), resetAt: q.resetAt, now: now)
                        let used = frac.map { Int(((1 - $0) * 100).rounded()) }
                        QuotaTelemetryPanel(
                            tool: .claudeCode,
                            title: "5小时余量",
                            shortBadge: "5H",
                            fraction: frac,
                            primaryValue: quotaPercentText(frac),
                            countdown: q.resetAt.map { quotaCompactClock($0) },
                            footer: used.map { String(localized: "已用 \($0)%") },
                            isExpired: menuBarQuotaIsExpired(resetAt: q.resetAt, now: now)
                        )
                    } else {
                        QuotaUnavailableRow()
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
        }
    }

    private func refresh() {
        guard !isRefreshing, let service = appStore.syncService else { return }
        localRefreshInFlight = true
        Task {
            await service.sync(tool: .claudeCode)
            localRefreshInFlight = false
        }
    }
}

private struct QuotaClaudeLimitResetsLine: View {
    @Environment(\.colorScheme) private var colorScheme
    let limitResets: ClaudeLimitResets
    let now: Date

    var body: some View {
        let accent = Tool.claudeCode.brandAccentColor(for: colorScheme)
        let buckets = limitResets.groupedResets(now: now)
        VStack(alignment: .leading, spacing: 6) {
            QuotaHairline(opacity: 0.06)
            ForEach(buckets) { bucket in
                let expiryText = bucket.expiryDates.map { quotaShortResetString($0) }.joined(separator: ", ")
                let labels = bucket.grants.compactMap(\.label).filter { !$0.isEmpty }
                HStack(spacing: 6) {
                    Image(systemName: "arrow.counterclockwise.circle.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(accent)
                    Text(bucket.kind.displayTitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("\(bucket.count)")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(accent)
                    if !expiryText.isEmpty {
                        Text("·")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        Text("过期")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(expiryText)
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .help(labels.isEmpty ? String(localized: "可用于提前重置 Claude 用量限制") : labels.joined(separator: " · "))
            }
        }
        .padding(.top, 2)
    }
}

// MARK: - Codex Card (Single & Multi-Account Unified Telemetry)

private struct QuotaCodexCardHost: View {
    @Environment(AppStore.self) private var appStore
    @Environment(\.quotaTelemetryNow) private var now
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("codex.smartSwitch.enabled") private var codexSmartSwitchEnabled = false
    @State private var localRefreshInFlight = false
    @State private var isSwitching = false
    @State private var statusMessage: String?
    let fallbackQuota: QuotaRecord?
    let isWideRow: Bool

    private var isRefreshing: Bool {
        localRefreshInFlight || (appStore.syncService?.states[.codex].isRefreshing ?? false)
    }

    var body: some View {
        let accounts = appStore.syncService?.latestCodexAccounts ?? []
        let accent = Tool.codex.brandAccentColor(for: colorScheme)

        QuotaToolShell(tool: .codex) {
            QuotaToolHeader(
                tool: .codex,
                subtitle: accounts.count == 1 ? accounts.first?.displaySubscriptionName : nil,
                accountCount: accounts.count > 1 ? accounts.count : nil,
                isRefreshing: isRefreshing,
                onRefresh: refresh
            ) {
                if codexSmartSwitchEnabled && accounts.count > 1 {
                    QuotaTintedChipButton(
                        title: "智能切换",
                        icon: "sparkles",
                        accent: accent,
                        isDisabled: isSwitching
                    ) {
                        runSwitch {
                            try await appStore.codexAccountService.smartSwitch()
                        }
                    }
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                QuotaHairline(opacity: 0.06)
                if !accounts.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                            if index > 0 {
                                QuotaHairline(opacity: 0.06)
                                    .padding(.horizontal, 18)
                            }
                            QuotaCodexAccountRow(
                                account: account,
                                isMultiAccount: accounts.count > 1,
                                isWideRow: isWideRow,
                                isSwitching: isSwitching
                            ) { id in
                                runSwitch {
                                    _ = try await appStore.codexAccountService.switchAccount(id: id, relaunchCodex: true)
                                    return nil
                                }
                            }
                        }

                        if let statusMessage {
                            Text(statusMessage)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 18)
                                .padding(.top, 4)
                                .padding(.bottom, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 6)
                } else if let q = fallbackQuota, let r = q.remaining, let t = q.total, t > 0 {
                    let frac = menuBarQuotaFraction(remainingFraction: Double(r) / Double(t), resetAt: q.resetAt, now: now)
                    let used = frac.map { Int(((1 - $0) * 100).rounded()) }
                    QuotaTelemetryPanel(
                        tool: .codex,
                        title: "5小时余量",
                        shortBadge: "5H",
                        fraction: frac,
                        primaryValue: quotaPercentText(frac),
                        countdown: q.resetAt.map { quotaCompactClock($0) },
                        footer: used.map { String(localized: "已用 \($0)%") },
                        isExpired: menuBarQuotaIsExpired(resetAt: q.resetAt, now: now)
                    )
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                } else {
                    QuotaUnavailableRow()
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                }
            }
        }
    }

    private func refresh() {
        guard !isRefreshing, let service = appStore.syncService else { return }
        localRefreshInFlight = true
        Task {
            await service.sync(tool: .codex)
            localRefreshInFlight = false
        }
    }

    private func runSwitch(
        _ action: @escaping () async throws -> CodexAccountService.SmartSwitchDecision?
    ) {
        isSwitching = true
        statusMessage = nil
        Task {
            do {
                let decision = try await action()
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

private struct QuotaCodexAccountRow: View {
    @Environment(\.quotaTelemetryNow) private var now
    @Environment(\.colorScheme) private var colorScheme
    let account: CodexAccountSnapshot
    let isMultiAccount: Bool
    let isWideRow: Bool
    let isSwitching: Bool
    let onSwitch: (String) -> Void

    var body: some View {
        let rows = account.limits.map { codexMenuBarQuotaRows(for: $0) } ?? []
        let accent = Tool.codex.brandAccentColor(for: colorScheme)

        QuotaHoverRow(hoverTint: accent, accentLeading: isMultiAccount && account.isCurrent ? accent : nil) {
            VStack(alignment: .leading, spacing: 10) {
                if isWideRow, rows.count == 1, let singleRow = rows.first, singleRow.id == "codex" {
                    HStack(alignment: .center, spacing: 18) {
                        identityColumn(accent: accent)
                            .frame(width: 280, alignment: .leading)

                        HStack(alignment: .top, spacing: 20) {
                            codexPanel(label: "5小时余量", shortBadge: "5H", isFiveHour: true, window: singleRow.fiveHourWindow, compact: true)
                            codexPanel(label: "本周余量", shortBadge: "7D", isFiveHour: false, window: singleRow.oneWeekWindow, compact: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    HStack(alignment: .center, spacing: 12) {
                        identityColumn(accent: accent)
                        Spacer(minLength: 8)
                    }

                    if !rows.isEmpty {
                        let hasMultipleRows = rows.count > 1
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(rows) { row in
                                VStack(alignment: .leading, spacing: 6) {
                                    if hasMultipleRows || row.id != "codex" {
                                        Text(verbatim: row.title)
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                    HStack(alignment: .top, spacing: 18) {
                                        codexPanel(label: "5小时余量", shortBadge: "5H", isFiveHour: true, window: row.fiveHourWindow, compact: false)
                                        codexPanel(label: "本周余量", shortBadge: "7D", isFiveHour: false, window: row.oneWeekWindow, compact: false)
                                    }
                                }
                            }
                        }
                    } else if let error = account.usageError {
                        Text(error)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    } else {
                        QuotaUnavailableRow(message: "尚未获取配额")
                    }
                }

                if let resetCredits = account.limits?.resetCredits, resetCredits.hasDisplayableCredits(now: now) {
                    QuotaCodexResetCreditsLine(resetCredits: resetCredits, now: now, leadingInset: 0)
                }
            }
        }
    }

    private func identityColumn(accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 7) {
                Text(account.titleText)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(account.titleText)

                if let displaySubscriptionName = account.displaySubscriptionName {
                    Text(displaySubscriptionName)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(accent.opacity(colorScheme == .dark ? 0.16 : 0.10), in: Capsule())
                        .fixedSize()
                }

                if isMultiAccount && account.isCurrent {
                    Text("当前")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(accent)
                        .fixedSize()
                } else if !account.isCurrent {
                    QuotaTintedChipButton(
                        title: "切换",
                        accent: accent,
                        isDisabled: isSwitching
                    ) {
                        onSwitch(account.id)
                    }
                    .fixedSize()
                }
            }

            if let subtitle = account.subtitleText, subtitle != account.titleText {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func codexPanel(
        label: String,
        shortBadge: String,
        isFiveHour: Bool,
        window: CodexWindow?,
        compact: Bool
    ) -> some View {
        let display = CodexQuotaWindowDisplay(window: window, at: now)
        let resetDate = window?.resetDate
        let countdown = resetDate.map { isFiveHour ? quotaCompactClock($0) : quotaShortResetString($0) }
        QuotaTelemetryPanel(
            tool: .codex,
            title: label,
            shortBadge: shortBadge,
            fraction: display.fraction,
            primaryValue: quotaPercentText(display.fraction),
            countdown: countdown,
            footer: display.isStale ? nil : display.used.map { String(localized: "已用 \($0)%") },
            isExpired: display.isStale,
            expiredDetail: account.usageError,
            compactMetric: compact
        )
    }
}

private struct QuotaCodexResetCreditsLine: View {
    @Environment(\.colorScheme) private var colorScheme
    let resetCredits: CodexResetCredits
    let now: Date
    var leadingInset: CGFloat = 14

    var body: some View {
        let accent = Tool.codex.brandAccentColor(for: colorScheme)
        let active = resetCredits.activeCredits(now: now)
        let availableCount = resetCredits.resolvedAvailableCount(now: now)
        let expiryValues = resetCredits.expiryDates(now: now).map { quotaShortResetString($0) }
        let expiryText = expiryValues.isEmpty ? nil : expiryValues.joined(separator: ", ")
        let titles = active.compactMap(\.title).filter { !$0.isEmpty }
        let helpText = titles.isEmpty
            ? String(localized: "可用于提前重置 Codex 用量限制")
            : titles.joined(separator: " · ")

        VStack(alignment: .leading, spacing: 6) {
            QuotaHairline(opacity: 0.06)
                .padding(.leading, leadingInset)
            HStack(spacing: 6) {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(accent)
                Text("可用重置券")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("\(availableCount)")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(accent)
                if let expiryText {
                    Text("·")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Text("过期")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(expiryText)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, leadingInset)
        }
        .padding(.top, 2)
        .help(helpText)
    }
}

// MARK: - Copilot Card

private struct QuotaCopilotCardHost: View {
    @Environment(AppStore.self) private var appStore
    @Environment(\.quotaTelemetryNow) private var now
    @State private var localRefreshInFlight = false
    let fallbackQuota: QuotaRecord?

    private var isRefreshing: Bool {
        localRefreshInFlight || (appStore.syncService?.states[.copilot].isRefreshing ?? false)
    }

    private func orderedSnapshots(from snapshots: [String: CopilotSnapshot]?) -> [(key: String, value: CopilotSnapshot)] {
        guard let snapshots, !snapshots.isEmpty else { return [] }
        let focused = snapshots.filter { $0.key != "chat" && $0.key != "completions" }
        let source = focused.isEmpty ? snapshots : focused
        return source.sorted { a, b in
            if a.key == "premium_interactions" { return true }
            if b.key == "premium_interactions" { return false }
            return a.key < b.key
        }
    }

    var body: some View {
        let snapshots = appStore.syncService?.latestCopilotSnapshots
        let resetAt = appStore.syncService?.latestCopilotResetAt
        let plan = appStore.syncService?.latestCopilotPlan
        let ordered = orderedSnapshots(from: snapshots)

        QuotaToolShell(tool: .copilot) {
            QuotaToolHeader(
                tool: .copilot,
                subtitle: normalizedCopilotPlanDisplayName(plan),
                isRefreshing: isRefreshing,
                onRefresh: refresh
            )
        } content: {
            VStack(spacing: 0) {
                QuotaHairline(opacity: 0.06)
                Group {
                    if !ordered.isEmpty {
                        if ordered.count == 1, let snapshot = ordered.first?.value {
                            copilotPanel(for: snapshot, resetAt: resetAt)
                        } else {
                            let pairs = stride(from: 0, to: ordered.count, by: 2).map {
                                Array(ordered[$0..<min($0 + 2, ordered.count)])
                            }
                            VStack(spacing: 14) {
                                ForEach(pairs, id: \.first?.key) { pair in
                                    HStack(alignment: .top, spacing: 18) {
                                        ForEach(pair, id: \.key) { item in
                                            copilotPanel(for: item.value, resetAt: resetAt)
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
                        QuotaTelemetryPanel(
                            tool: .copilot,
                            title: "Copilot 余量",
                            fraction: frac,
                            primaryValue: quotaPercentText(frac),
                            countdown: q.resetAt.map { quotaShortResetString($0) },
                            footer: "\(max(0, r))/\(t)",
                            isExpired: menuBarQuotaIsExpired(resetAt: q.resetAt, now: now)
                        )
                    } else {
                        QuotaUnavailableRow()
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
        }
    }

    private func copilotPanel(for snapshot: CopilotSnapshot, resetAt: Date?) -> some View {
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

        return QuotaTelemetryPanel(
            tool: .copilot,
            title: snapshot.displayName,
            fraction: isInf ? 1.0 : fraction,
            primaryValue: isInf ? "∞" : quotaPercentText(fraction),
            countdown: resetAt.map { quotaShortResetString($0) },
            footer: countsText,
            isExpired: !isInf && menuBarQuotaIsExpired(resetAt: resetAt, now: now)
        )
    }

    private func refresh() {
        guard !isRefreshing, let service = appStore.syncService else { return }
        localRefreshInFlight = true
        Task {
            await service.sync(tool: .copilot)
            localRefreshInFlight = false
        }
    }
}

// MARK: - Antigravity Card (Unified Multi-Account Telemetry Matrix + Aggregate Switcher)

private struct QuotaAGColumnDescriptor: Identifiable {
    let id: String
    let fullTitle: String
    let shortTitle: String
}

private struct QuotaAntigravityCardHost: View {
    @Environment(AppStore.self) private var appStore
    @Environment(\.quotaTelemetryNow) private var now
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("ag.hiddenAccountEmails") private var hiddenAccountEmailsRaw = ""
    @AppStorage("menubar.antigravityDisplayMode") private var displayMode = "accounts"
    @State private var localRefreshInFlight = false
    let fallbackQuota: QuotaRecord?
    let isWideRow: Bool

    private var isRefreshing: Bool {
        localRefreshInFlight || (appStore.syncService?.states[.antigravity].isRefreshing ?? false)
    }

    private func columns(for accounts: [AGAccountQuota]) -> [QuotaAGColumnDescriptor] {
        var seen: Set<String> = []
        var result: [QuotaAGColumnDescriptor] = []
        for account in accounts {
            for group in account.groups where seen.insert(group.id).inserted {
                result.append(
                    QuotaAGColumnDescriptor(
                        id: group.id,
                        fullTitle: group.displayName,
                        shortTitle: quotaShortAGGroupTitle(group.displayName)
                    )
                )
            }
        }
        return result
    }

    var body: some View {
        let allAccounts = appStore.syncService?.latestAntigravityAccounts
        let visibleAccounts = allAccounts.map {
            menuBarVisibleAntigravityAccounts($0, hiddenAccountEmailsRaw: hiddenAccountEmailsRaw)
        } ?? []
        let aggregateSummary = (displayMode == "aggregate" && !visibleAccounts.isEmpty)
            ? AntigravityProAggregator.aggregate(accounts: visibleAccounts)
            : nil
        let usesProAccounts = visibleAccounts.contains(where: \.isPaid)
        let aggregateBadge: String? = aggregateSummary.map { summary in
            let tier = usesProAccounts ? "Pro" : "Free"
            return summary.proAccountCount > 1 ? "\(tier) · \(summary.proAccountCount)" : tier
        }
        let aggregateHelp: String? = aggregateSummary.map {
            String(localized: "账号额度聚合 (\($0.proAccountCount)个账号)")
        }

        QuotaToolShell(tool: .antigravity) {
            QuotaToolHeader(
                tool: .antigravity,
                subtitle: displayMode == "aggregate" ? aggregateBadge : nil,
                subtitleHelp: displayMode == "aggregate" ? aggregateHelp : nil,
                accountCount: (displayMode != "aggregate" && visibleAccounts.count > 1) ? visibleAccounts.count : nil,
                isRefreshing: isRefreshing,
                onRefresh: refreshAll
            ) {
                if visibleAccounts.count > 1 {
                    QuotaAGDisplayModeSwitcher(mode: $displayMode)
                }
            }
        } content: {
            VStack(spacing: 0) {
                QuotaHairline(opacity: 0.06)
                if allAccounts != nil {
                    if visibleAccounts.isEmpty {
                        QuotaUnavailableRow(message: "暂无可用账号额度")
                            .padding(.horizontal, 18)
                            .padding(.vertical, 16)
                    } else if displayMode == "aggregate", let summary = aggregateSummary {
                        aggregateBody(summary: summary)
                    } else {
                        let matrixColumns = columns(for: visibleAccounts)
                        if isWideRow && !matrixColumns.isEmpty && matrixColumns.count <= 3 {
                            matrixBody(accounts: visibleAccounts, columns: matrixColumns)
                        } else {
                            stackedAccountsBody(accounts: visibleAccounts)
                        }
                    }
                } else if let q = fallbackQuota, let r = q.remaining, let t = q.total, t > 0 {
                    let frac = menuBarQuotaFraction(remainingFraction: Double(r) / Double(t), resetAt: q.resetAt, now: now)
                    QuotaTelemetryPanel(
                        tool: .antigravity,
                        title: "总余量",
                        fraction: frac,
                        primaryValue: quotaPercentText(frac),
                        countdown: q.resetAt.map { quotaShortResetString($0) },
                        isExpired: menuBarQuotaIsExpired(resetAt: q.resetAt, now: now)
                    )
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                } else {
                    QuotaUnavailableRow()
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                }
            }
        }
    }

    @ViewBuilder
    private func aggregateBody(summary: AGProAggregateSummary) -> some View {
        let columnsCount = isWideRow && summary.groups.count > 1 ? 2 : 1
        VStack(alignment: .leading, spacing: 14) {
            if columnsCount == 2 {
                let pairs = stride(from: 0, to: summary.groups.count, by: 2).map {
                    Array(summary.groups[$0..<min($0 + 2, summary.groups.count)])
                }
                ForEach(pairs, id: \.first?.id) { pair in
                    HStack(alignment: .top, spacing: 24) {
                        ForEach(pair) { group in
                            QuotaAGGroupPanel(group: group)
                        }
                        if pair.count == 1 {
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
            } else {
                ForEach(summary.groups) { group in
                    QuotaAGGroupPanel(group: group)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private func matrixBody(accounts: [AGAccountQuota], columns: [QuotaAGColumnDescriptor]) -> some View {
        let cellWidth: CGFloat = columns.count <= 2 ? 84 : 66
        let cellGap: CGFloat = 12
        let groupGap: CGFloat = 20
        let groupWidth = cellWidth * 2 + cellGap
        let refreshingEmails = appStore.syncService?.refreshingAntigravityAccountEmails ?? []

        VStack(spacing: 0) {
            // Neutral typographic column header strip matching AntigravityMultiAccountCard
            HStack(alignment: .bottom, spacing: 12) {
                Text("ACCOUNT")
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                        if index > 0 {
                            Rectangle()
                                .fill(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.07))
                                .frame(width: 0.5, height: 24)
                                .padding(.horizontal, (groupGap - 0.5) / 2)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(column.shortTitle.uppercased())
                                .font(.system(size: 9.5, weight: .bold))
                                .tracking(0.5)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .help(column.fullTitle)
                            HStack(spacing: cellGap) {
                                Text("5H").frame(width: cellWidth, alignment: .leading)
                                Text("7D").frame(width: cellWidth, alignment: .leading)
                            }
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        }
                        .frame(width: groupWidth, alignment: .leading)
                    }
                }

                // Alignment spacer for per-account refresh icon button
                Color.clear.frame(width: 24, height: 1)
            }
            .padding(.horizontal, 18)
            .padding(.top, 9)
            .padding(.bottom, 7)

            QuotaHairline(opacity: 0.07)
                .padding(.horizontal, 18)

            VStack(spacing: 0) {
                ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                    if index > 0 {
                        QuotaHairline(opacity: 0.06)
                            .padding(.horizontal, 18)
                    }
                    QuotaAGMatrixRow(
                        account: account,
                        columns: columns,
                        cellWidth: cellWidth,
                        cellGap: cellGap,
                        groupGap: groupGap,
                        isRefreshing: isRefreshing || refreshingEmails.contains(account.email)
                    ) {
                        refreshAccount(email: account.email)
                    }
                }
            }
            .padding(.vertical, 5)
        }
    }

    @ViewBuilder
    private func stackedAccountsBody(accounts: [AGAccountQuota]) -> some View {
        let refreshingEmails = appStore.syncService?.refreshingAntigravityAccountEmails ?? []
        VStack(spacing: 0) {
            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                if index > 0 {
                    QuotaHairline(opacity: 0.06)
                        .padding(.horizontal, 18)
                }
                QuotaAGStackedAccountRow(
                    account: account,
                    isRefreshing: isRefreshing || refreshingEmails.contains(account.email)
                ) {
                    refreshAccount(email: account.email)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func refreshAll() {
        guard !isRefreshing, let service = appStore.syncService else { return }
        localRefreshInFlight = true
        Task {
            await service.sync(tool: .antigravity)
            localRefreshInFlight = false
        }
    }

    private func refreshAccount(email: String) {
        guard let service = appStore.syncService else { return }
        Task {
            await service.refreshAntigravityAccount(email: email)
        }
    }
}

private struct QuotaAGDisplayModeSwitcher: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var mode: String
    @Namespace private var switcherNamespace
    @State private var hoveredID: String?

    var body: some View {
        let accent = Tool.antigravity.brandAccentColor(for: colorScheme)
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
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isSelected ? accent : (isHovered ? .primary : .secondary))
                .frame(width: 24, height: 20)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(colorScheme == .dark ? Color.white.opacity(0.18) : Color.white.opacity(0.95))
                            .matchedGeometryEffect(id: "quotaAGModeSelection", in: switcherNamespace)
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

private struct QuotaAGGroupPanel: View {
    @Environment(\.quotaTelemetryNow) private var now
    let group: AGQuotaGroup

    var body: some View {
        let fiveHourFraction = agQuotaDisplayFraction(for: group.fiveHour)
        let weeklyFraction = agQuotaDisplayFraction(for: group.weekly)
        let fiveHourReset = group.fiveHour?.resetTime.flatMap { $0 > now ? $0 : nil }
        let weeklyReset = group.weekly?.resetTime.flatMap { $0 > now ? $0 : nil }
        let isWeeklyExhausted = weeklyFraction.map { $0 <= 0.001 } ?? false
        let is5hUnusable = isWeeklyExhausted || (fiveHourFraction.map { $0 <= 0.001 } ?? false)

        VStack(alignment: .leading, spacing: 8) {
            Text(group.displayName)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(alignment: .top, spacing: 18) {
                QuotaTelemetryPanel(
                    tool: .antigravity,
                    title: "5小时余量",
                    shortBadge: "5H",
                    fraction: fiveHourFraction,
                    primaryValue: quotaPercentText(fiveHourFraction),
                    countdown: fiveHourReset.map { quotaCompactClock($0) },
                    footer: isWeeklyExhausted ? String(localized: "本周额度已耗尽") : nil,
                    isExhaustedOverride: is5hUnusable,
                    compactMetric: true
                )
                QuotaTelemetryPanel(
                    tool: .antigravity,
                    title: "本周余量",
                    shortBadge: "7D",
                    fraction: weeklyFraction,
                    primaryValue: quotaPercentText(weeklyFraction),
                    countdown: weeklyReset.map { quotaShortResetString($0) },
                    compactMetric: true
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct QuotaAGMatrixRow: View {
    @Environment(\.quotaTelemetryNow) private var now
    @Environment(\.colorScheme) private var colorScheme
    let account: AGAccountQuota
    let columns: [QuotaAGColumnDescriptor]
    let cellWidth: CGFloat
    let cellGap: CGFloat
    let groupGap: CGFloat
    let isRefreshing: Bool
    let onRefresh: () -> Void

    var body: some View {
        let accent = Tool.antigravity.brandAccentColor(for: colorScheme)
        let groupWidth = cellWidth * 2 + cellGap

        QuotaHoverRow(hoverTint: accent) {
            HStack(alignment: .center, spacing: 12) {
                HStack(alignment: .center, spacing: 7) {
                    Text(account.email)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(account.email)
                    Text(account.isPaid ? "Pro" : "Free")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(account.isPaid ? accent : .secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(
                            (account.isPaid ? accent : Color.primary).opacity(
                                colorScheme == .dark
                                    ? (account.isPaid ? 0.18 : 0.09)
                                    : (account.isPaid ? 0.11 : 0.06)
                            ),
                            in: Capsule()
                        )
                        .fixedSize()
                        .help(account.badgeLabel)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if account.groups.isEmpty {
                    QuotaUnavailableRow()
                        .frame(
                            width: CGFloat(columns.count) * groupWidth + CGFloat(max(0, columns.count - 1)) * groupGap,
                            alignment: .leading
                        )
                } else {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                            if index > 0 {
                                Rectangle()
                                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.07))
                                    .frame(width: 0.5, height: 32)
                                    .padding(.top, 2)
                                    .padding(.horizontal, (groupGap - 0.5) / 2)
                            }
                            groupCells(for: account.groups.first(where: { $0.id == column.id }), width: groupWidth)
                        }
                    }
                }

                QuotaIconButton(
                    systemName: "arrow.clockwise",
                    isSpinning: isRefreshing,
                    helpText: isRefreshing ? String(localized: "正在刷新") : String(localized: "刷新配额"),
                    size: 24,
                    action: onRefresh
                )
            }
        }
    }

    @ViewBuilder
    private func groupCells(for group: AGQuotaGroup?, width: CGFloat) -> some View {
        let fiveHourFraction = agQuotaDisplayFraction(for: group?.fiveHour)
        let weeklyFraction = agQuotaDisplayFraction(for: group?.weekly)
        let fiveHourReset = group?.fiveHour?.resetTime.flatMap { $0 > now ? $0 : nil }
        let weeklyReset = group?.weekly?.resetTime.flatMap { $0 > now ? $0 : nil }
        let isWeeklyExhausted = weeklyFraction.map { $0 <= 0.001 } ?? false
        let is5hUnusable = isWeeklyExhausted || (fiveHourFraction.map { $0 <= 0.001 } ?? false)

        HStack(alignment: .top, spacing: cellGap) {
            QuotaMatrixGauge(
                tool: .antigravity,
                fraction: fiveHourFraction,
                primaryValue: quotaPercentText(fiveHourFraction),
                resetText: fiveHourReset.map { quotaCompactClock($0) },
                resetHelp: fiveHourReset.map { String(localized: "\(quotaCompactClock($0)) 重置") },
                isExhaustedOverride: is5hUnusable,
                cellWidth: cellWidth
            )
            QuotaMatrixGauge(
                tool: .antigravity,
                fraction: weeklyFraction,
                primaryValue: quotaPercentText(weeklyFraction),
                resetText: weeklyReset.map { quotaCompactDate($0) },
                resetHelp: weeklyReset.map { String(localized: "\(quotaShortResetString($0)) 重置") },
                cellWidth: cellWidth
            )
        }
        .frame(width: width, alignment: .leading)
    }
}

private struct QuotaAGStackedAccountRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let account: AGAccountQuota
    let isRefreshing: Bool
    let onRefresh: () -> Void

    var body: some View {
        let accent = Tool.antigravity.brandAccentColor(for: colorScheme)
        QuotaHoverRow(hoverTint: accent) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 7) {
                    Text(account.email)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(account.isPaid ? "Pro" : "Free")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(account.isPaid ? accent : .secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(
                            (account.isPaid ? accent : Color.primary).opacity(
                                colorScheme == .dark
                                    ? (account.isPaid ? 0.18 : 0.09)
                                    : (account.isPaid ? 0.11 : 0.06)
                            ),
                            in: Capsule()
                        )
                        .fixedSize()
                        .help(account.badgeLabel)
                    Spacer(minLength: 6)
                    QuotaIconButton(
                        systemName: "arrow.clockwise",
                        isSpinning: isRefreshing,
                        helpText: isRefreshing ? String(localized: "正在刷新") : String(localized: "刷新配额"),
                        size: 24,
                        action: onRefresh
                    )
                }

                if account.groups.isEmpty {
                    QuotaUnavailableRow()
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(account.groups) { group in
                            QuotaAGGroupPanel(group: group)
                        }
                    }
                }
            }
        }
    }
}
