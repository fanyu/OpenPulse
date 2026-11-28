import SwiftUI

// MARK: - Shared connection presentation

private struct ProviderMessage: View {
    @Environment(\.colorScheme) private var colorScheme
    let text: String
    var isError = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(isError ? Color.red : Color.green)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(isError ? Color.red : .secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            (isError ? Color.red : Color.green).opacity(colorScheme == .dark ? 0.12 : 0.07),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder((isError ? Color.red : Color.green).opacity(0.22), lineWidth: 0.75)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ProviderEmptyState: View {
    @Environment(\.colorScheme) private var colorScheme
    let icon: String
    let title: LocalizedStringKey
    let description: LocalizedStringKey

    init(icon: String = "tray", title: LocalizedStringKey, description: LocalizedStringKey) {
        self.icon = icon
        self.title = title
        self.description = description
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(.tertiary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(colorScheme == .dark ? 0.035 : 0.022),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.75)
        }
    }
}

private struct ProviderField<Content: View>: View {
    let title: LocalizedStringKey
    var detail: LocalizedStringKey? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
            content()
                .textFieldStyle(.roundedBorder)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ProviderMiniQuotaPill: View {
    @Environment(\.colorScheme) private var colorScheme
    let label: String
    let remainingPercent: Int?

    var body: some View {
        let fraction = remainingPercent.map { Double(max(0, min(100, $0))) / 100.0 }
        let tint: Color = fraction.map { quotaBarColor(fraction: $0) } ?? .secondary
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(remainingPercent.map { "\($0)%" } ?? "—")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(remainingPercent == nil ? .secondary : tint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(
            (remainingPercent == nil ? Color.primary : tint).opacity(colorScheme == .dark ? 0.14 : 0.09),
            in: Capsule()
        )
    }
}

// MARK: - Claude Code

struct ClaudeProviderContent: View {
    @Environment(AppStore.self) private var appStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var isRefreshing = false

    private var bridgeCacheExists: Bool {
        FileManager.default.fileExists(atPath: ClaudeCodeBridgeInstaller.cacheURL.path)
    }

    var body: some View {
        let info = appStore.syncService?.latestClaudeAccountInfo
        let usage = appStore.syncService?.latestClaudeUsage
        let fiveHour = usage?.effectiveRemainingPercent
        let sevenDay = usage?.sevenDay?.utilization.map { max(0, 100 - Int($0.rounded())) }
        let limitResets = usage?.cedarEmber
        let brand = Tool.claudeCode.brandAccentColor(for: colorScheme)

        SettingsCard(
            title: "订阅与同步状态",
            subtitle: "Claude Code 本地对话日志自动同步；额度优先通过零开销的 Statusline Bridge 缓存读取。"
        ) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 16) {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 180), spacing: 12)],
                        alignment: .leading,
                        spacing: 12
                    ) {
                        claudeStatTile(
                            label: "订阅账号",
                            value: info?.accountLabel ?? String(localized: "本地自动识别"),
                            badge: info?.displaySubscriptionName,
                            accent: brand
                        )

                        claudeStatTile(
                            label: "Statusline Bridge",
                            value: bridgeCacheExists ? String(localized: "已激活") : String(localized: "待写入缓存"),
                            badge: nil,
                            accent: bridgeCacheExists ? .green : .secondary
                        )

                        if let limitResets {
                            ForEach(limitResets.groupedResets()) { bucket in
                                let expiryBadge = bucket.expiryDates.first.map { date in
                                    let formatted = date.formatted(.dateTime.month(.twoDigits).day(.twoDigits))
                                    return String(localized: "\(formatted) 过期")
                                }
                                claudeStatTile(
                                    label: LocalizedStringKey(bucket.kind.displayTitle),
                                    value: String(localized: "\(bucket.count) 次"),
                                    badge: expiryBadge,
                                    accent: brand
                                )
                            }
                        }
                    }

                    Button {
                        guard !isRefreshing else { return }
                        isRefreshing = true
                        Task {
                            defer { isRefreshing = false }
                            await appStore.syncService?.refreshTool(.claudeCode)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if isRefreshing {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 11.5, weight: .semibold))
                            }
                            Text("刷新状态")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRefreshing)
                }

                if fiveHour != nil || sevenDay != nil {
                    Divider().opacity(0.45)
                    HStack(spacing: 16) {
                        if let fiveHour {
                            claudeQuotaMeter(
                                title: "5 小时窗口",
                                percent: fiveHour,
                                resetDate: usage?.fiveHour?.resetDate,
                                isWeekly: false
                            )
                        }
                        if let sevenDay {
                            claudeQuotaMeter(
                                title: "7 天窗口",
                                percent: sevenDay,
                                resetDate: usage?.sevenDay?.resetDate,
                                isWeekly: true
                            )
                        }
                    }
                }
            }
        }
    }

    private func claudeStatTile(label: LocalizedStringKey, value: String, badge: String?, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(value)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let badge, !badge.isEmpty {
                    Text(badge)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(accent.opacity(colorScheme == .dark ? 0.18 : 0.11), in: Capsule())
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(colorScheme == .dark ? 0.04 : 0.025),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.75)
        }
    }

    private func claudeQuotaMeter(title: LocalizedStringKey, percent: Int, resetDate: Date?, isWeekly: Bool) -> some View {
        let fraction = Double(max(0, min(100, percent))) / 100.0
        let tint = quotaBarColor(fraction: fraction)
        let resetLabel = resetDate.map { date -> String in
            let formatted = isWeekly
                ? date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits))
                : date.formatted(.dateTime.hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits))
            return String(localized: "重置于 \(formatted)")
        }
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                if let resetLabel {
                    Text("·")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Text(resetLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                Spacer()
                Text("\(percent)%")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tint)
            }
            QuotaProgressBar(fraction: fraction, color: tint, height: 5)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Codex

struct CodexProviderContent: View {
    let appStore: AppStore
    @AppStorage("codex.smartSwitch.enabled") private var codexSmartSwitchEnabled = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        SettingsCard(
            title: "OpenAI 账号",
            subtitle: "支持添加多个 OpenAI 账号并随时切换当前 Codex 登录状态；切换账号时会自动重启 Codex。"
        ) {
            VStack(alignment: .leading, spacing: 18) {
                CodexAccountActions(
                    isWorking: isWorking,
                    onImport: {
                        runAsyncAction { try await appStore.codexAccountService.importCurrentAuth() }
                    },
                    onLogin: {
                        runAsyncAction { try await appStore.codexAccountService.addAccountViaOAuth() }
                    },
                    onRefresh: {
                        runAsyncAction { _ = try await appStore.codexAccountService.refreshAllUsage(force: true) }
                    }
                )

                if let errorMessage { ProviderMessage(text: errorMessage, isError: true) }

                CodexProviderAccounts(
                    accounts: appStore.syncService?.latestCodexAccounts ?? [],
                    isWorking: isWorking,
                    onSwitch: { id in
                        runAsyncAction { _ = try await appStore.codexAccountService.switchAccount(id: id) }
                    },
                    onDelete: { id in
                        runAsyncAction { try await appStore.codexAccountService.deleteAccount(id: id) }
                    }
                )

                Divider().opacity(0.5)

                SettingsToggleRow(
                    title: "启用智能切换",
                    detail: "开启后，菜单栏会显示「智能切换」入口；后台监测到当前 Codex 账号 5h/7d 配额耗尽时，会自动切换到更优账号并重启 Codex。",
                    isOn: $codexSmartSwitchEnabled
                )
            }
        }
    }

    private func runAsyncAction(_ action: @escaping @MainActor () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                try await action()
                await appStore.syncService?.sync(tool: .codex)
            } catch {
                // A switch can commit before Codex fails to relaunch. Read back
                // selection without triggering another auto-switch or restart.
                try? await appStore.syncService?.reloadCodexAccountSnapshots()
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct CodexAccountActions: View {
    let isWorking: Bool
    let onImport: () -> Void
    let onLogin: () -> Void
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onLogin) {
                Label("新增 OpenAI 登录", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)

            Button("导入当前账号", action: onImport)
                .buttonStyle(.bordered)

            Button {
                onRefresh()
            } label: {
                Label("刷新额度", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)

            if isWorking { ProgressView().controlSize(.small) }
            Spacer(minLength: 0)
        }
        .controlSize(.regular)
        .disabled(isWorking)
    }
}

private struct CodexProviderAccounts: View {
    let accounts: [CodexAccountSnapshot]
    let isWorking: Bool
    let onSwitch: (String) -> Void
    let onDelete: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if accounts.isEmpty {
                ProviderEmptyState(
                    icon: "person.badge.plus",
                    title: "还没有 Codex 账号",
                    description: "点击「新增 OpenAI 登录」，或直接导入当前本机已登录的 Codex 账号。"
                )
            } else {
                ForEach(accounts) { account in
                    CodexProviderAccountCard(
                        account: account,
                        isWorking: isWorking,
                        onSwitch: { onSwitch(account.id) },
                        onDelete: { onDelete(account.id) }
                    )
                }
            }
        }
    }
}

private struct CodexProviderAccountCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let account: CodexAccountSnapshot
    let isWorking: Bool
    let onSwitch: () -> Void
    let onDelete: () -> Void
    @State private var isHovered = false

    private var fiveHourWindow: CodexWindow? {
        account.limits?.fiveHourWindow
    }

    private var sevenDayWindow: CodexWindow? {
        account.limits?.oneWeekWindow
    }

    private var fiveHourPercent: Int? {
        fiveHourWindow?.remainingPercent.map { Int($0.rounded()) }
    }

    private var sevenDayPercent: Int? {
        sevenDayWindow?.remainingPercent.map { Int($0.rounded()) }
    }

    var body: some View {
        let brand = Tool.codex.brandAccentColor(for: colorScheme)
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 14) {
                    identity
                    Spacer(minLength: 12)
                    actions
                }
                VStack(alignment: .leading, spacing: 10) {
                    identity
                    actions
                }
            }

            if fiveHourPercent != nil || sevenDayPercent != nil {
                Divider().opacity(0.4)
                HStack(spacing: 16) {
                    if let fiveHourPercent {
                        codexQuotaMeter(
                            title: "5 小时窗口",
                            percent: fiveHourPercent,
                            resetDate: fiveHourWindow?.resetDate,
                            isWeekly: false
                        )
                    }
                    if let sevenDayPercent {
                        codexQuotaMeter(
                            title: "7 天窗口",
                            percent: sevenDayPercent,
                            resetDate: sevenDayWindow?.resetDate,
                            isWeekly: true
                        )
                    }
                }
            }

            if let resetCredits = account.limits?.resetCredits, resetCredits.hasDisplayableCredits() {
                codexResetCreditsBadge(resetCredits: resetCredits, brand: brand)
            }

            if let error = account.usageError {
                ProviderMessage(text: error, isError: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            account.isCurrent
                ? brand.opacity(colorScheme == .dark ? 0.11 : 0.065)
                : (isHovered
                    ? Color.primary.opacity(colorScheme == .dark ? 0.05 : 0.03)
                    : Color.primary.opacity(colorScheme == .dark ? 0.03 : 0.018)),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(
                    account.isCurrent
                        ? brand.opacity(colorScheme == .dark ? 0.45 : 0.35)
                        : Color.primary.opacity(0.06),
                    lineWidth: account.isCurrent ? 1 : 0.75
                )
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }

    private var identity: some View {
        let brand = Tool.codex.brandAccentColor(for: colorScheme)
        return HStack(alignment: .center, spacing: 11) {
            ZStack {
                Circle()
                    .fill((account.isCurrent ? brand : Color.secondary).opacity(colorScheme == .dark ? 0.20 : 0.12))
                    .frame(width: 30, height: 30)
                Image(systemName: account.isCurrent ? "checkmark" : "person.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(account.isCurrent ? brand : .secondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(account.titleText)
                        .font(.system(size: 13, weight: .semibold))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if account.isCurrent {
                        Text("当前账号")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(brand)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(brand.opacity(colorScheme == .dark ? 0.20 : 0.12), in: Capsule())
                    }
                    if let plan = account.displaySubscriptionName, !plan.isEmpty {
                        SubscriptionTag(text: plan)
                    }
                }

                let secondaryParts = [account.subtitleText, account.metaText].compactMap { $0 }.filter { !$0.isEmpty }
                if !secondaryParts.isEmpty {
                    Text(secondaryParts.joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private func codexQuotaMeter(title: LocalizedStringKey, percent: Int, resetDate: Date?, isWeekly: Bool) -> some View {
        let fraction = Double(max(0, min(100, percent))) / 100.0
        let tint = quotaBarColor(fraction: fraction)
        let resetLabel = resetDate.map { date -> String in
            let formatted = isWeekly
                ? date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits))
                : date.formatted(.dateTime.hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits))
            return String(localized: "重置于 \(formatted)")
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                if let resetLabel {
                    Text("·")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                    Text(resetLabel)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                Spacer()
                Text("\(percent)%")
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tint)
            }
            QuotaProgressBar(fraction: fraction, color: tint, height: 4.5)
        }
        .frame(maxWidth: .infinity)
    }

    private func codexResetCreditsBadge(resetCredits: CodexResetCredits, brand: Color) -> some View {
        let count = resetCredits.resolvedAvailableCount()
        let expiryDates = resetCredits.expiryDates().map {
            $0.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits))
        }
        let expiryDetail: String? = {
            guard !expiryDates.isEmpty else { return nil }
            if expiryDates.count == 1, let first = expiryDates.first {
                return String(localized: "过期于 \(first)")
            }
            return String(localized: "分别过期于 \(expiryDates.formatted())")
        }()

        return HStack(spacing: 7) {
            Image(systemName: "arrow.counterclockwise.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(brand)
            Text("可用重置券")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
            Text(String(localized: "\(count) 次"))
                .font(.system(size: 11.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(brand)
            if let expiryDetail {
                Text("·")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text(expiryDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(brand.opacity(colorScheme == .dark ? 0.12 : 0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if !account.isCurrent {
                Button("切换", action: onSwitch)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isWorking)
            }
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.borderless)
            .disabled(isWorking || account.isCurrent)
            .opacity(account.isCurrent ? 0.3 : 0.85)
            .help(account.isCurrent
                ? String(localized: "请先切换到其他账号，再删除当前账号。")
                : String(localized: "删除已保存的账号"))
            .accessibilityLabel("删除")
        }
    }
}

// MARK: - GitHub Copilot

struct CopilotProviderContent: View {
    @Environment(AppStore.self) private var appStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var githubToken = ""
    @State private var savedToken = ""
    @State private var verifiedToken: String?
    @State private var importedToken: String?
    @State private var importError: String?
    @State private var isVerifying = false
    @State private var isImporting = false
    @State private var isLoading = true

    private var isBusy: Bool { isVerifying || isImporting || isLoading }

    private var remainingPercent: Int? {
        CopilotSnapshot.menuBarRemainingPercent(
            from: appStore.syncService?.latestCopilotSnapshots,
            resetAt: appStore.syncService?.latestCopilotResetAt
        )
    }

    var body: some View {
        let brand = Tool.copilot.brandAccentColor(for: colorScheme)
        SettingsCard(
            title: "GitHub 授权",
            subtitle: "使用 GitHub OAuth Token 读取 Copilot 高级交互配额，可从本地代理配置自动导入。"
        ) {
            VStack(alignment: .leading, spacing: 18) {
                if remainingPercent != nil || appStore.syncService?.latestCopilotPlan != nil {
                    HStack(spacing: 12) {
                        if let plan = appStore.syncService?.latestCopilotPlan, !plan.isEmpty {
                            Text(plan.capitalized)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(brand)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3.5)
                                .background(brand.opacity(colorScheme == .dark ? 0.18 : 0.11), in: Capsule())
                        }
                        if let pct = remainingPercent {
                            ProviderMiniQuotaPill(label: "剩余", remainingPercent: pct)
                        }
                        Spacer()
                        Button {
                            Task { await appStore.syncService?.refreshTool(.copilot) }
                        } label: {
                            Label("刷新额度", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isBusy)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        brand.opacity(colorScheme == .dark ? 0.10 : 0.055),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(brand.opacity(0.24), lineWidth: 0.75)
                    }
                }

                ProviderField(title: "GitHub OAuth Token") {
                    SecureField("输入 Token 或从本地配置导入", text: $githubToken)
                        .disabled(isBusy)
                }

                HStack(spacing: 10) {
                    Button("保存并验证") { saveToken() }
                        .buttonStyle(.borderedProminent)
                        .disabled(githubToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBusy)
                    Button("从本地配置导入") { Task { await importToken() } }
                        .buttonStyle(.bordered)
                        .disabled(isBusy)
                    if !savedToken.isEmpty {
                        Button("移除授权", role: .destructive) { removeToken() }
                            .buttonStyle(.borderless)
                            .disabled(isBusy)
                    }
                    if isBusy { ProgressView().controlSize(.small) }
                }

                if let error = importError {
                    ProviderMessage(text: error, isError: true)
                } else if verifiedToken == githubToken, !githubToken.isEmpty {
                    ProviderMessage(text: String(localized: "授权已验证并保存"))
                } else if importedToken == githubToken, !githubToken.isEmpty {
                    Text("已导入授权，保存前将验证可用性。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else if !savedToken.isEmpty, githubToken == savedToken {
                    Text("已保存授权；可随时重新验证或刷新配额。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task { await loadAndAutoImport() }
        .onChange(of: githubToken) { _, _ in
            if verifiedToken != githubToken { importError = nil }
        }
    }

    private func loadAndAutoImport() async {
        defer { isLoading = false }
        githubToken = await Task.detached(priority: .utility) {
            (try? KeychainService.retrieve(key: KeychainService.Keys.githubToken)) ?? ""
        }.value
        savedToken = githubToken
        if githubToken.isEmpty { await importToken(silent: true) }
    }

    private func removeToken() {
        KeychainService.delete(key: KeychainService.Keys.githubToken)
        githubToken = ""
        savedToken = ""
        verifiedToken = nil
        importedToken = nil
        importError = nil
    }

    private func importToken(silent: Bool = false) async {
        guard !isImporting, !isVerifying else { return }
        isImporting = true
        importError = nil
        importedToken = nil
        defer { isImporting = false }
        do {
            let token = try await Task.detached(priority: .utility) { try Self.readImportedToken() }.value
            githubToken = token
            importedToken = token
        } catch {
            if !silent { importError = error.localizedDescription }
        }
    }

    private nonisolated static func readImportedToken() throws -> String {
        struct ImportedCredential: Decodable {
            let accessToken: String?
            enum CodingKeys: String, CodingKey { case accessToken = "access_token" }
        }
        let directory = URL.homeDirectory.appending(path: ".cli-proxy-api")
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("github-copilot-") && $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch { throw ImportError.noConfiguration }
        guard !files.isEmpty else { throw ImportError.noConfiguration }
        for file in files {
            if let data = try? Data(contentsOf: file),
               let auth = try? JSONDecoder().decode(ImportedCredential.self, from: data),
               let token = auth.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
                return token
            }
        }
        throw ImportError.noToken
    }

    private enum ImportError: LocalizedError {
        case noConfiguration, noToken
        var errorDescription: String? {
            switch self {
            case .noConfiguration: String(localized: "未找到 Copilot 本地授权配置。")
            case .noToken: String(localized: "配置中没有可用的 access_token。")
            }
        }
    }

    private func saveToken() {
        guard !isBusy else { return }
        let token = githubToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        isVerifying = true
        importError = nil
        verifiedToken = nil
        Task {
            defer { isVerifying = false }
            do {
                _ = try await CopilotAPIClient().fetchQuota(token: token)
                try await Task.detached(priority: .utility) {
                    try KeychainService.store(key: KeychainService.Keys.githubToken, value: token)
                }.value
                githubToken = token
                savedToken = token
                verifiedToken = token
                importedToken = nil
                await appStore.syncService?.sync(tool: .copilot)
            } catch KeychainError.legacyCleanupFailed(let status) {
                githubToken = token
                savedToken = token
                verifiedToken = token
                importedToken = nil
                importError = String(localized: "授权已保存，但旧授权清理失败（\(status)）。")
            } catch {
                importError = String(localized: "验证或保存失败，请检查授权后重试。")
            }
        }
    }
}

// MARK: - Antigravity (Unified Accounts — zero duplicate list)

private struct UnifiedAntigravityAccount: Identifiable {
    let email: String
    let quota: AGAccountQuota?
    let quotaError: String?
    let isOpenPulseOwned: Bool

    var id: String { email }
}

struct AntigravityProviderContent: View {
    let appStore: AppStore
    @AppStorage("ag.hiddenAccountEmails") private var hiddenAccountEmailsRaw = ""
    @State private var ownedAccounts: [AGStoredAccount] = []
    @State private var isWorking = false
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var hiddenAccountEmails: Set<String> {
        Set(hiddenAccountEmailsRaw.components(separatedBy: ",").filter { !$0.isEmpty })
    }

    private var unifiedAccounts: [UnifiedAntigravityAccount] {
        let ownedSet = Set(ownedAccounts.map(\.email))
        let synced = appStore.syncService?.latestAntigravityAccounts ?? []
        let errors = appStore.syncService?.latestAntigravityAccountErrors ?? [:]
        var seen = Set<String>()
        var merged: [UnifiedAntigravityAccount] = []

        for account in synced {
            if seen.insert(account.email).inserted {
                merged.append(UnifiedAntigravityAccount(
                    email: account.email,
                    quota: account,
                    quotaError: errors[account.email],
                    isOpenPulseOwned: ownedSet.contains(account.email)
                ))
            }
        }
        for stored in ownedAccounts where seen.insert(stored.email).inserted {
            merged.append(UnifiedAntigravityAccount(
                email: stored.email,
                quota: nil,
                quotaError: errors[stored.email],
                isOpenPulseOwned: true
            ))
        }
        return merged
    }

    var body: some View {
        SettingsCard(
            title: "Google 账号与菜单栏显示",
            subtitle: "统一管理 OAuth 登录与本地代理授权账号，可按账号控制是否在菜单栏中显示。"
        ) {
            VStack(alignment: .leading, spacing: 18) {
                AntigravityAccountActions(
                    isWorking: isWorking || isLoading,
                    onLogin: {
                        runAsyncAction {
                            let added = try await appStore.antigravityAccountService.addAccountViaOAuth()
                            try await reload()
                            await appStore.syncService?.refreshAntigravityAccount(email: added.email)
                            if appStore.syncService?.latestAntigravityAccounts?.contains(where: { $0.email == added.email }) != true,
                               appStore.syncService?.latestAntigravityAccountErrors[added.email] == nil {
                                await appStore.syncService?.refreshTool(.antigravity)
                            }
                        }
                    },
                    onRefresh: {
                        runAsyncAction {
                            try await reload()
                            await appStore.syncService?.refreshTool(.antigravity)
                        }
                    }
                )

                if let errorMessage { ProviderMessage(text: errorMessage, isError: true) }

                let accounts = unifiedAccounts
                if accounts.isEmpty {
                    if isLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在读取账号…")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    } else {
                        ProviderEmptyState(
                            icon: "person.badge.plus",
                            title: "尚未获取账号额度",
                            description: "点击「添加 Google 账号」完成授权，或刷新已配置的本地代理文件。"
                        )
                    }
                } else {
                    VStack(spacing: 12) {
                        ForEach(accounts) { entry in
                            AGUnifiedAccountPlate(
                                entry: entry,
                                isVisibleInMenuBar: !hiddenAccountEmails.contains(entry.email),
                                isWorking: isWorking,
                                onToggleMenuBar: { isVisible in
                                    setHiddenAccount(entry.email, isVisible)
                                },
                                onDelete: entry.isOpenPulseOwned ? {
                                    runAsyncAction {
                                        try await appStore.antigravityAccountService.deleteAccount(email: entry.email)
                                        try await reload()
                                        await appStore.syncService?.refreshTool(.antigravity)
                                    }
                                } : nil
                            )
                        }
                    }
                }
            }
        }
        .task {
            do { try await reload() }
            catch { errorMessage = error.localizedDescription }
            isLoading = false
        }
    }

    private func reload() async throws {
        let accounts = try await appStore.antigravityAccountService.listAccounts()
        ownedAccounts = accounts
    }

    private func runAsyncAction(_ action: @escaping @MainActor () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do { try await action() }
            catch KeychainError.legacyCleanupFailed(let status) {
                // This specific error means the account and its replacement credential were saved.
                let warning = String(localized: "账号已保存，但旧授权清理失败（\(status)）。")
                do {
                    try await reload()
                    errorMessage = warning
                    await appStore.syncService?.refreshTool(.antigravity)
                } catch {
                    errorMessage = warning + " " + error.localizedDescription
                }
            }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func setHiddenAccount(_ email: String, _ isVisible: Bool) {
        var emails = hiddenAccountEmails
        if isVisible { emails.remove(email) } else { emails.insert(email) }
        hiddenAccountEmailsRaw = emails.sorted().joined(separator: ",")
    }
}

private struct AntigravityAccountActions: View {
    let isWorking: Bool
    let onLogin: () -> Void
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onLogin) {
                Label("添加 Google 账号", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)

            Button {
                onRefresh()
            } label: {
                Label("刷新额度", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)

            if isWorking { ProgressView().controlSize(.small) }
            Spacer(minLength: 0)
        }
        .disabled(isWorking)
    }
}

private struct AGUnifiedAccountPlate: View {
    @Environment(\.colorScheme) private var colorScheme
    let entry: UnifiedAntigravityAccount
    let isVisibleInMenuBar: Bool
    let isWorking: Bool
    let onToggleMenuBar: (Bool) -> Void
    let onDelete: (() -> Void)?

    var body: some View {
        let brand = Tool.antigravity.brandAccentColor(for: colorScheme)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(brand.opacity(colorScheme == .dark ? 0.18 : 0.11))
                        .frame(width: 28, height: 28)
                    Image(systemName: "person.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(brand)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(entry.email)
                            .font(.system(size: 13, weight: .semibold))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let quota = entry.quota {
                            AGTierBadge(account: quota)
                        }
                        Text(entry.isOpenPulseOwned ? String(localized: "OAuth 登录") : String(localized: "本地授权"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05), in: Capsule())
                    }
                }

                Spacer(minLength: 12)

                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Text("菜单栏")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Toggle("在菜单栏显示此账号", isOn: Binding(
                            get: { isVisibleInMenuBar },
                            set: onToggleMenuBar
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                    }

                    if let onDelete {
                        Button(role: .destructive, action: onDelete) {
                            Image(systemName: "trash")
                                .font(.system(size: 12))
                                .frame(width: 26, height: 26)
                        }
                        .buttonStyle(.borderless)
                        .disabled(isWorking)
                        .help("删除已保存的 Google 账号")
                        .accessibilityLabel("删除")
                    }
                }
            }

            if let groups = entry.quota?.groups, !groups.isEmpty {
                Divider().opacity(0.45)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 260), spacing: 14, alignment: .top)],
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(groups) { group in
                        AGCompactGroupTile(group: group)
                    }
                }
            } else if entry.quotaError == nil {
                Text("等待首次额度同步")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            if let error = entry.quotaError {
                ProviderMessage(text: error, isError: true)
            }
        }
        .padding(14)
        .background(
            Color.primary.opacity(colorScheme == .dark ? 0.035 : 0.02),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.065), lineWidth: 0.75)
        }
        .opacity(isVisibleInMenuBar ? 1 : 0.68)
    }
}

private struct AGCompactGroupTile: View {
    @Environment(\.colorScheme) private var colorScheme
    let group: AGQuotaGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(group.displayName)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.primary)

            compactWindowBar(
                label: "5H",
                window: group.fiveHour,
                isBlockedByWeekly: agQuotaDisplayFraction(for: group.weekly).map { $0 <= 0.001 } ?? false
            )
            compactWindowBar(label: "7D", window: group.weekly, isBlockedByWeekly: false)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(colorScheme == .dark ? 0.55 : 0.85),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.055), lineWidth: 0.6)
        }
    }

    private func compactWindowBar(label: String, window: AGWindow?, isBlockedByWeekly: Bool) -> some View {
        let fraction = agQuotaDisplayFraction(for: window)
        let pctText = fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
        let color = fraction.map { quotaBarColor(fraction: $0) } ?? .secondary
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, alignment: .leading)
                QuotaProgressBar(fraction: fraction, color: color, height: 4)
                Text(pctText)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(fraction == nil ? .secondary : color)
                    .frame(width: 34, alignment: .trailing)
            }
            if isBlockedByWeekly {
                Text("本周额度已耗尽")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .padding(.leading, 26)
            } else if let countdown = window?.resetCountdown {
                Text(countdown)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 26)
            }
        }
    }
}
