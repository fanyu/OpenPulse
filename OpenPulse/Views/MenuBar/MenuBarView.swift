import SwiftUI
import SwiftData

struct MenuBarView: View {
    @Environment(AppStore.self) private var appStore
    @Environment(\.openWindow) private var openWindow
    @Query private var sessions: [SessionRecord]
    @Query private var quotas: [QuotaRecord]

    @AppStorage("menubar.toolOrder") private var toolOrderRaw = Tool.defaultOrderRaw
    @AppStorage("menubar.hiddenTools") private var hiddenToolsRaw = ""

    init() {
        // Only load today's sessions — avoids scanning the entire session history
        // (which grows unboundedly) on every sync-triggered view refresh.
        let start = Calendar.current.startOfDay(for: Date())
        _sessions = Query(filter: #Predicate<SessionRecord> { $0.startedAt >= start })
    }

    private var orderedVisibleTools: [Tool] {
        let hidden = Set(hiddenToolsRaw.components(separatedBy: ",").filter { !$0.isEmpty })
        let order = toolOrderRaw.components(separatedBy: ",").compactMap { Tool(rawValue: $0) }
        let ordered = order + Tool.allCases.filter { !order.contains($0) }
        return ordered.filter { !hidden.contains($0.rawValue) }
    }

    @State private var contentHeight: CGFloat = 0
    // Cached per-tool today token counts — one pass over today's sessions only.
    @State private var todayTokensByTool: [Tool: Int] = [:]

    private func rebuildTodayTokens() {
        var map: [Tool: Int] = [:]
        for session in sessions {
            map[session.tool, default: 0] += session.totalTokens
        }
        todayTokensByTool = map
    }

    private var todayTokens: Int { todayTokensByTool.values.reduce(0, +) }

    private var isSyncing: Bool { appStore.syncService?.isSyncing ?? false }
    private var lastSyncDate: Date? { appStore.syncService?.lastSyncDate ?? appStore.lastSyncDate }

    private var maxScrollHeight: CGFloat {
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        return max(300, screenHeight - 58 - 52 - 22 - 24)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider().opacity(0.3).padding(.horizontal)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(orderedVisibleTools, id: \.self) { tool in
                        toolCard(for: tool)
                    }
                }
                .padding(12)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: min(contentHeight, maxScrollHeight))
            .scrollIndicators(.hidden)
            Divider().opacity(0.3).padding(.horizontal)
            footerSection
        }
        .frame(width: 380)
        .background(MenuBarWindowCapture())
        .task { rebuildTodayTokens() }
        .onChange(of: sessions.count) { _, _ in rebuildTodayTokens() }
    }

    @ViewBuilder
    private func toolCard(for tool: Tool) -> some View {
        switch tool {
        case .claudeCode:
            ClaudeQuotaCard(
                usage: appStore.syncService?.latestClaudeUsage,
                quota: quotas.first(where: { $0.tool == .claudeCode }),
                todayTokens: todaySessionTokens(for: .claudeCode),
                weeklyTokens: []
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
                fallbackQuota: quotas.first(where: { $0.tool == .copilot }),
                todayTokens: todaySessionTokens(for: .copilot)
            )
        case .antigravity:
            if let accounts = appStore.syncService?.latestAntigravityAccounts {
                ForEach(accounts) { account in
                    AntigravityAccountCard(
                        account: account,
                        todayTokens: todaySessionTokens(for: .antigravity)
                    )
                }
            } else if let fallback = quotas.first(where: { $0.tool == .antigravity }) {
                AntigravityFallbackCard(
                    quota: fallback,
                    todayTokens: todaySessionTokens(for: .antigravity)
                )
            }
        case .opencode:
            OpenCodeQuotaCard(todayTokens: todaySessionTokens(for: .opencode))
        }
    }

    private func todaySessionTokens(for tool: Tool) -> Int { todayTokensByTool[tool] ?? 0 }

    private var headerSection: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("OpenPulse")
                    .font(.system(.title3, design: .rounded))
                    .bold()
                HStack(spacing: 4) {
                    if isSyncing {
                        ProgressView().controlSize(.mini).scaleEffect(0.8)
                        Text("同步中…").font(.caption2).foregroundStyle(.secondary)
                    } else {
                        let activeCount = orderedVisibleTools.filter { todayTokensByTool[$0] != nil }.count
                        Text("\(todayTokens.compactTokenString) tokens")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if activeCount > 0 {
                            Text("·")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Text("\(activeCount) 个工具活跃")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Spacer()
            HStack(spacing: 5) {
                ForEach(orderedVisibleTools, id: \.self) { tool in
                    let active = todayTokensByTool[tool] != nil
                    Circle()
                        .fill(active ? Color(tool.accentColorName) : Color.gray.opacity(0.2))
                        .frame(width: 6, height: 6)
                        .overlay {
                            if active {
                                Circle()
                                    .stroke(Color(tool.accentColorName).opacity(0.35), lineWidth: 2)
                                    .scaleEffect(1.6)
                            }
                        }
                }
            }
            .padding(.trailing, 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var footerSection: some View {
        HStack {
            if let lastSync = lastSyncDate {
                Text("更新于 \(lastSync, style: .relative)前")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                Text("尚未同步")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            if let err = appStore.syncService?.syncError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .help(err.localizedDescription)
            }
            Spacer()
            HStack(spacing: 8) {
                Button(action: { Task { await appStore.syncService?.sync() } }) {
                    Image(systemName: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("刷新同步 (⌘R)")
                .disabled(isSyncing)
                Button(action: {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                }) {
                    Image(systemName: "macwindow")
                }
                .keyboardShortcut("m", modifiers: .command)
                .help("打开主窗口 (⌘M)")
                Button(action: {
                    appStore.selectedTab = .settings
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                }) {
                    Image(systemName: "gearshape")
                }
                .keyboardShortcut(",", modifiers: .command)
                .help("设置 (⌘,)")
                Button(action: { NSApp.terminate(nil) }) {
                    Image(systemName: "power")
                }
                .keyboardShortcut("q", modifiers: .command)
                .help("退出 (⌘Q)")
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .labelStyle(.iconOnly)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Claude Code

struct ClaudeQuotaCard: View {
    let usage: ClaudeUsageResponse?
    let quota: QuotaRecord?
    let todayTokens: Int
    let weeklyTokens: [Int]

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                ToolIconLabel(tool: .claudeCode)
                Spacer()
                if todayTokens > 0 { TodayTokenBadge(tokens: todayTokens) }
            }
            if let usage {
                VStack(spacing: 6) {
                    ClaudeWindowRow(label: "5h Session", window: usage.fiveHour)
                    ClaudeWindowRow(label: "7d Weekly", window: usage.sevenDay)
                }
            } else if let q = quota, let r = q.remaining, let t = q.total, t > 0 {
                let frac = Double(r) / Double(t)
                let pct = Int((frac * 100).rounded())
                UnifiedQuotaRow(style: .compact, showUsedAtTop: true, title: "5h Session", fraction: frac, primaryValue: "\(pct)%", secondaryValue: "\(max(0, 100 - pct))% used", countdown: q.toModel().resetCountdown)

            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}

struct ClaudeWindowRow: View {
    let label: String
    let window: UsageWindow?
    var body: some View {
        let frac = window?.utilization.map { max(0, min(1, (100 - $0) / 100)) }
        let usedPct = window?.utilization.map { Int($0.rounded()) }
        let remPct = usedPct.map { max(0, 100 - $0) }
        let isMultiDay = label.contains("7d") || label.contains("14d")
        let countdown = window?.resetsAt.flatMap(parseISO8601Flexible).map { date in
            isMultiDay ? countdownString(to: date) : date.formatted(.dateTime.hour().minute())
        }
        UnifiedQuotaRow(style: .compact, showUsedAtTop: true, title: label, fraction: frac, primaryValue: remPct.map { "\($0)%" }, secondaryValue: usedPct.map { "\($0)% used" }, countdown: countdown)
    }
}

// MARK: - Codex

struct CodexQuotaCard: View {
    let limits: CodexRateLimits?
    let fallbackQuota: QuotaRecord?
    let todayTokens: Int
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                ToolIconLabel(tool: .codex)
                Spacer()
                if todayTokens > 0 { TodayTokenBadge(tokens: todayTokens) }
            }
            if let limits {
                VStack(spacing: 6) {
                    CodexWindowRow(label: "5h Session", window: limits.fiveHourWindow)
                    CodexWindowRow(label: "7d Weekly", window: limits.oneWeekWindow)
                }
            } else if let q = fallbackQuota, let r = q.remaining, let t = q.total {
                let frac = Double(r) / Double(t)
                let pct = Int((frac * 100).rounded())
                UnifiedQuotaRow(style: .compact, showUsedAtTop: true, title: "5h Session", fraction: frac, primaryValue: "\(pct)%", secondaryValue: "\(max(0, 100 - pct))% used", countdown: q.toModel().resetCountdown)
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}

struct CodexAccountQuotaCard: View {
    @Environment(AppStore.self) private var appStore
    let account: CodexAccountSnapshot
    let isSwitching: Bool
    let onSwitch: (String) -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.titleText).font(.system(size: 11, weight: .semibold))
                    if let subtitleText = account.subtitleText {
                        Text(subtitleText).font(.system(size: 9)).foregroundStyle(.tertiary)
                    } else if let metaText = account.metaText {
                        Text(metaText).font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 8)
                if account.isCurrent {
                    Text("当前")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.green.opacity(0.12), in: Capsule())
                } else {
                    Button("切换") {
                        onSwitch(account.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(isSwitching)
                }
            }
            if let limits = account.limits {
                VStack(spacing: 6) {
                    CodexWindowRow(label: "5h Session", window: limits.fiveHourWindow)
                    CodexWindowRow(label: "7d Weekly", window: limits.oneWeekWindow)
                }
            } else if let error = account.usageError {
                Text(error).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("尚未获取配额").font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct CodexMultiAccountQuotaCard: View {
    @Environment(AppStore.self) private var appStore
    let accounts: [CodexAccountSnapshot]
    let todayTokens: Int
    @State private var isSwitching = false
    @State private var statusMessage: String?

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top) {
                ToolIconLabel(tool: .codex)
                Spacer()
                Button("智能切换") {
                    runSwitch {
                        try await appStore.codexAccountService.smartSwitch()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(isSwitching)
                if todayTokens > 0 { TodayTokenBadge(tokens: todayTokens) }
            }

            VStack(spacing: 10) {
                ForEach(accounts) { account in
                    CodexAccountQuotaCard(
                        account: account,
                        isSwitching: isSwitching,
                        onSwitch: { id in
                            runSwitch {
                                _ = try await appStore.codexAccountService.switchAccount(id: id, relaunchCodex: true)
                                return nil as CodexAccountService.SmartSwitchDecision?
                            }
                        }
                    )
                    if account.id != accounts.last?.id {
                        Divider().opacity(0.25)
                    }
                }
            }
            if let statusMessage {
                Text(statusMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
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
                            ? "已自动切换到 \(decision.account.titleText)"
                            : "已切换到 \(decision.account.titleText)"
                    } else {
                        statusMessage = "当前账号已经是最优选择"
                    }
                }
            } catch {
                await MainActor.run {
                    isSwitching = false
                    statusMessage = error.localizedDescription
                }
            }
        }
    }
}

struct CodexWindowRow: View {
    let label: String
    let window: CodexWindow?
    var body: some View {
        let frac = window?.usedPercent.map { max(0, min(1, (100 - $0) / 100)) }
        let pct = frac.map { Int(($0 * 100).rounded()) }
        let usedPct = pct.map { max(0, 100 - $0) }
        let isMultiDay = (window?.windowMinutes ?? 0) > 24 * 60
        let countdown = window?.resetDate.map { isMultiDay ? $0.formatted(.dateTime.month().day()) : $0.formatted(.dateTime.hour().minute()) }
        UnifiedQuotaRow(style: .compact, showUsedAtTop: true, title: label, fraction: frac, primaryValue: pct.map { "\($0)%" }, secondaryValue: usedPct.map { "\($0)% used" }, countdown: countdown)
    }
}

// MARK: - Tool-Specific Components (MenuBar Version)

struct ToolIconLabel: View {
    let tool: Tool
    var body: some View {
        HStack(spacing: 6) {
            ToolLogoImage(tool: tool, size: 18)
            Text(tool.displayName).font(.system(size: 13, weight: .bold, design: .rounded))
        }
    }
}

// MARK: - Copilot

struct CopilotQuotaCard: View {
    let snapshots: [String: CopilotSnapshot]?
    let resetAt: Date?
    let fallbackQuota: QuotaRecord?
    let todayTokens: Int
    private var ordered: [(key: String, value: CopilotSnapshot)] {
        guard let s = snapshots else { return [] }
        return s.sorted { a, b in
            if a.key == "premium_interactions" { return true }
            if b.key == "premium_interactions" { return false }
            return a.key < b.key
        }
    }
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                ToolIconLabel(tool: .copilot)
                Spacer()
                if todayTokens > 0 { TodayTokenBadge(tokens: todayTokens) }
            }
            if !ordered.isEmpty {
                VStack(spacing: 5) {
                    ForEach(ordered, id: \.key) { item in
                        CopilotSnapshotRow(snapshot: item.value)
                    }
                }
                if let resetAt {
                    Divider().opacity(0.3)
                    HStack {
                        Image(systemName: "arrow.clockwise.circle").font(.system(size: 9))
                        Text("重置于 \(resetAt.formatted(.dateTime.month().day()))").font(.system(size: 9, weight: .medium))
                    }.foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if let q = fallbackQuota, let r = q.remaining, let t = q.total, t > 0 {
                let frac = Double(r) / Double(t)
                let used = t - r
                let pct = Int((frac * 100).rounded())
                UnifiedQuotaRow(style: .compact, showUsedAtTop: true, 
title: "Copilot", fraction: frac, primaryValue: "\(pct)%", secondaryValue: "\(used)/\(t)", countdown: q.toModel().resetCountdown)
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}

struct CopilotSnapshotRow: View {
    let snapshot: CopilotSnapshot
    private var isInf: Bool { snapshot.unlimited ?? false }
    var body: some View {
        let pct = snapshot.percentRemaining.map { Int($0.rounded()) }
        let secondary: String? = {
            if let r = snapshot.remaining, let t = snapshot.entitlement { return "\(t - r)/\(t)" }
            return nil
        }()
        UnifiedQuotaRow(
            style: .compact, 
            showUsedAtTop: true,
            title: snapshot.displayName,
            fraction: isInf ? 1.0 : (snapshot.percentRemaining.map { $0 / 100.0 }),
            primaryValue: isInf ? "∞" : pct.map { "\($0)%" },
            secondaryValue: secondary,
            countdown: nil
        )
    }
}

// MARK: - Antigravity

struct AntigravityAccountCard: View {
    let account: AGAccountQuota
    let todayTokens: Int
    @AppStorage("ag.hiddenModelIds") private var globalHiddenModelIdsRaw = ""
    @AppStorage("ag.hiddenAccountEmails") private var hiddenAccountEmailsRaw = ""
    @AppStorage("ag.syncModelConfig") private var syncModelConfig = true
    private var hiddenIds: Set<String> { Set(effectiveHiddenModelIdsRaw.components(separatedBy: ",").filter { !$0.isEmpty }) }
    private var effectiveHiddenModelIdsRaw: String { syncModelConfig ? globalHiddenModelIdsRaw : (UserDefaults.standard.string(forKey: "ag.hiddenModelIds.\(account.email)") ?? "") }
    private var isAccountHidden: Bool { Set(hiddenAccountEmailsRaw.components(separatedBy: ",").filter { !$0.isEmpty }).contains(account.email) }
    private var visibleModels: [AGModelQuota] { account.models.filter { !hiddenIds.contains($0.id) } }

    var body: some View {
        if isAccountHidden || (visibleModels.isEmpty && account.models.isEmpty) {
            EmptyView()
        } else {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    ToolLogoImage(tool: .antigravity, size: 18)
                    HStack(spacing: 4) {
                        Text(Tool.antigravity.displayName).font(.system(size: 13, weight: .bold, design: .rounded))
                        Text("·").font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
                        Text(account.email).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if todayTokens > 0 { TodayTokenBadge(tokens: todayTokens) }
                }
                if visibleModels.isEmpty {
                    Text("全部模型已隐藏").font(.system(size: 9)).foregroundStyle(.quaternary).frame(maxWidth: .infinity, alignment: .leading)
                } else if visibleModels.count == 1 {
                    AntigravityModelRow(model: visibleModels[0])
                } else {
                    let pairs = stride(from: 0, to: visibleModels.count, by: 2).map { Array(visibleModels[$0..<min($0 + 2, visibleModels.count)]) }
                    VStack(spacing: 5) {
                        ForEach(pairs, id: \.first?.id) { pair in
                            HStack(alignment: .top, spacing: 6) {
                                ForEach(pair, id: \.id) { model in
                                    AntigravityModelCell(model: model).frame(maxWidth: .infinity)
                                }
                                if pair.count == 1 { Color.clear.frame(maxWidth: .infinity) }
                            }
                        }
                    }
                }
            }
            .padding(12)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
        }
    }
}

struct AntigravityFallbackCard: View {
    let quota: QuotaRecord
    let todayTokens: Int
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                ToolIconLabel(tool: .antigravity)
                Spacer()
                if todayTokens > 0 { TodayTokenBadge(tokens: todayTokens) }
            }
            if let r = quota.remaining, let t = quota.total, t > 0 {
                let frac = Double(r) / Double(t)
                let pct = Int((frac * 100).rounded())
                UnifiedQuotaRow(style: .compact, showUsedAtTop: true, 
title: "Total Quota", fraction: frac, primaryValue: "\(pct)%", secondaryValue: "\(max(0, 100 - pct))% used", countdown: quota.toModel().resetCountdown)
            }

        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}

struct AntigravityModelCell: View {
    let model: AGModelQuota
    var body: some View {
        let pct = model.remainingFraction.map { Int(($0 * 100).rounded()) }
        let usedPct = pct.map { max(0, 100 - $0) }
                        UnifiedQuotaRow(style: .compact, title: 
 model.displayName, fraction: model.remainingFraction, primaryValue: pct.map { "\($0)%" }, secondaryValue: usedPct.map { "\($0)% used" }, countdown: model.resetCountdown)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 7))
    }
}

struct AntigravityModelRow: View {
    let model: AGModelQuota
    var body: some View {
        let pct = model.remainingFraction.map { Int(($0 * 100).rounded()) }
        let usedPct = pct.map { max(0, 100 - $0) }
                        UnifiedQuotaRow(style: .compact, title: 
 model.displayName, fraction: model.remainingFraction, primaryValue: pct.map { "\($0)%" }, secondaryValue: usedPct.map { "\($0)% used" }, countdown: model.resetCountdown)
    }
}

// MARK: - Simple Tool Card

struct SimpleQuotaCard: View {
    let tool: Tool
    let quota: QuotaRecord?
    let detail: String?
    let todayTokens: Int
    private var fraction: Double? {
        guard let r = quota?.remaining, let t = quota?.total, t > 0 else { return nil }
        return Double(r) / Double(t)
    }
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                ToolIconLabel(tool: tool)
                Spacer()
                if todayTokens > 0 { TodayTokenBadge(tokens: todayTokens) }
            }
            if let f = fraction {
                let pct = Int((f * 100).rounded())
                UnifiedQuotaRow(style: .compact, showUsedAtTop: true, 
title: tool.displayName, fraction: f, primaryValue: "\(pct)%", secondaryValue: detail, countdown: quota?.toModel().resetCountdown)
            } else {

                Text("未配置 API Key").font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}

// MARK: - OpenCode

struct OpenCodeQuotaCard: View {
    let todayTokens: Int
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                ToolIconLabel(tool: .opencode)
                Spacer()
                if todayTokens > 0 { TodayTokenBadge(tokens: todayTokens) }
            }
            if todayTokens == 0 {
                Text("暂无数据").font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
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
        guard let w = window else { return }
        Task { @MainActor in GlobalHotkeyService.shared.registerMenuBarWindow(w) }
    }
}
