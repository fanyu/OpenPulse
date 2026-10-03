import SwiftUI

// MARK: - Shared connection presentation

private struct ProviderMessage: View {
    let text: String
    var isError = false

    var body: some View {
        Label {
            Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: isError ? "exclamationmark.circle" : "checkmark.circle")
        }
        .font(.callout)
        .foregroundStyle(isError ? Color.red : Color.secondary)
        .accessibilityElement(children: .combine)
    }
}

private struct ProviderEmptyState: View {
    let title: LocalizedStringKey
    let description: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.medium))
            Text(description).font(.callout).foregroundStyle(.secondary)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProviderSourceRow: View {
    let path: String

    var body: some View {
        LabeledContent("数据源") {
            Text(path)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .font(.callout)
    }
}

private struct ProviderField<Content: View>: View {
    let title: LocalizedStringKey
    var detail: LocalizedStringKey? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.medium))
            content().textFieldStyle(.roundedBorder)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Claude Code

struct ClaudeProviderContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Claude Code 的本地对话记录会自动同步，无需额外配置。")
                .font(.callout)
                .foregroundStyle(.secondary)
            ProviderSourceRow(path: Provider.claudeCode.dataSourcePath)
        }
    }
}

// MARK: - Codex accounts

struct CodexProviderContent: View {
    let appStore: AppStore
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var providerManager = CodexProviderManagerViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            CodexConnectionSummary()
            CodexAccountActions(isWorking: isWorking, onImport: {
                runAsyncAction { try await appStore.codexAccountService.importCurrentAuth() }
            }, onLogin: {
                runAsyncAction { try await appStore.codexAccountService.addAccountViaOAuth() }
            }, onRefresh: {
                runAsyncAction { _ = try await appStore.codexAccountService.refreshAllUsage(force: true) }
            })

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
            Divider()
            CodexProviderManagerSection(viewModel: providerManager, appStore: appStore)
        }
        .task {
            if providerManager.providers.isEmpty {
                await providerManager.load(using: appStore.codexProviderConfigService, coordinator: appStore.codexRouterCoordinator)
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

private struct CodexConnectionSummary: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加多个 OpenAI 账号，查看额度并切换当前 Codex 账号。切换账号时会重新启动 Codex。")
                .font(.callout)
                .foregroundStyle(.secondary)
            ProviderSourceRow(path: Provider.codex.dataSourcePath)
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
            Button("新增 OpenAI 登录", action: onLogin).buttonStyle(.borderedProminent)
            Menu("更多操作") {
                Button("导入当前账号", action: onImport)
                Button("刷新额度", action: onRefresh)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            if isWorking { ProgressView().controlSize(.small) }
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
        VStack(alignment: .leading, spacing: 0) {
            if accounts.isEmpty {
                ProviderEmptyState(title: "还没有 Codex 账号", description: "新增 OpenAI 登录，或从“更多操作”导入当前账号。")
            } else {
                ForEach(accounts) { account in
                    CodexProviderAccountCard(account: account, isWorking: isWorking,
                        onSwitch: { onSwitch(account.id) }, onDelete: { onDelete(account.id) })
                    if account.id != accounts.last?.id { Divider() }
                }
            }
        }
    }
}

private struct CodexProviderAccountCard: View {
    let account: CodexAccountSnapshot
    let isWorking: Bool
    let onSwitch: () -> Void
    let onDelete: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 20) {
                identity
                Spacer(minLength: 12)
                actions
            }
            VStack(alignment: .leading, spacing: 12) {
                identity
                actions
            }
        }
        .padding(.vertical, 16)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(account.titleText).font(.callout.weight(.semibold)).textSelection(.enabled)
                if account.isCurrent {
                    Label("当前账号", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                }
            }
            if let subtitle = account.subtitleText { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
            if let meta = account.metaText { Text(meta).font(.caption).foregroundStyle(.secondary) }
            if let plan = account.displaySubscriptionName { Text(plan).font(.caption).foregroundStyle(.secondary) }
            if let error = account.usageError { ProviderMessage(text: error, isError: true) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button("切换", action: onSwitch).buttonStyle(.bordered).disabled(isWorking || account.isCurrent)
            Button(role: .destructive, action: onDelete) { Label("删除", systemImage: "trash") }
                .buttonStyle(.borderless)
                .disabled(isWorking || account.isCurrent)
                .help(account.isCurrent
                    ? String(localized: "请先切换到其他账号，再删除当前账号。")
                    : String(localized: "删除已保存的账号"))
        }
    }
}

// MARK: - Codex model routing

private struct CodexProviderManagerSection: View {
    let viewModel: CodexProviderManagerViewModel
    let appStore: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            CodexProviderManagerHeader(viewModel: viewModel)
            CodexRouterControlPanel(viewModel: viewModel, appStore: appStore)
            if viewModel.isLoading {
                ProgressView("读取 Provider…").controlSize(.small)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 28) {
                        CodexProviderList(viewModel: viewModel, appStore: appStore).frame(width: 220)
                        CodexProviderEditor(viewModel: viewModel, appStore: appStore).frame(minWidth: 340)
                    }
                    VStack(alignment: .leading, spacing: 24) {
                        CodexProviderList(viewModel: viewModel, appStore: appStore)
                        Divider()
                        CodexProviderEditor(viewModel: viewModel, appStore: appStore)
                    }
                }
            }
            CodexProviderManagerFeedback(viewModel: viewModel)
        }
    }
}

private struct CodexProviderManagerHeader: View {
    let viewModel: CodexProviderManagerViewModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 20) {
                title
                Spacer(minLength: 12)
                addButton
            }
            VStack(alignment: .leading, spacing: 12) {
                title
                addButton
            }
        }
    }

    private var title: some View {
        DashboardSectionTitle(title: "模型路由", subtitle: "OpenAI 模型直接连接；第三方模型通过 Router 接入。")
    }

    private var addButton: some View {
        Button("新增 Provider") { viewModel.beginCreate() }
            .buttonStyle(.bordered)
            .disabled(viewModel.isBusy)
    }
}

private struct CodexProviderList: View {
    let viewModel: CodexProviderManagerViewModel
    let appStore: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if viewModel.providers.isEmpty {
                ProviderEmptyState(title: "无法读取 Provider", description: "检查 Codex 配置文件后重试。")
                Button("重新读取") {
                    Task { await viewModel.load(using: appStore.codexProviderConfigService, coordinator: appStore.codexRouterCoordinator) }
                }
                .disabled(viewModel.isBusy)
            } else {
                ForEach(viewModel.providers) { provider in
                    CodexProviderSelectionRow(
                        name: provider.name, id: provider.id, model: provider.defaultModel,
                        isCurrent: provider.id == viewModel.currentProviderID,
                        isSelected: provider.id == viewModel.selectedProviderID,
                        unavailableReason: viewModel.unavailableReason(for: provider),
                        isDisabled: viewModel.isBusy
                    ) {
                        Task { await viewModel.selectProvider(id: provider.id, using: appStore.codexProviderConfigService) }
                    }
                }
            }
        }
    }
}

private struct CodexProviderSelectionRow: View {
    let name: String
    let id: String
    let model: String
    let isCurrent: Bool
    let isSelected: Bool
    let unavailableReason: String?
    let isDisabled: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(name).font(.callout.weight(.semibold))
                    Text(id).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text(model.isEmpty ? String(localized: "未配置默认模型") : model).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    if isCurrent { Label("当前路由", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green) }
                    if let unavailableReason {
                        Text(unavailableReason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                if isSelected { Image(systemName: "checkmark").font(.caption.weight(.semibold)) }
            }
            .foregroundStyle(.primary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.primary.opacity(0.055) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityValue(isSelected ? String(localized: "已选择") : "")
    }
}

private struct CodexProviderEditor: View {
    @Bindable var viewModel: CodexProviderManagerViewModel
    let appStore: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            CodexProviderEditorHeader(viewModel: viewModel, appStore: appStore)
            VStack(alignment: .leading, spacing: 16) {
                if !viewModel.draft.isBuiltIn {
                    ProviderField(title: "内部 ID", detail: "使用简短英文标识，例如 mimo 或 openrouter。") {
                        TextField("provider-id", text: $viewModel.draft.id)
                            .disabled(!viewModel.isCreatingNew)
                    }
                    ProviderField(title: "名称") { TextField("Provider Name", text: $viewModel.draft.name) }
                    ProviderField(title: "Base URL") { TextField("https://example.com/v1", text: $viewModel.draft.baseURL) }
                }
                ProviderField(title: "默认模型") { TextField("model-name", text: $viewModel.draft.defaultModel) }
                if !viewModel.draft.isBuiltIn {
                    ProviderField(title: "API Key", detail: "授权保存在钥匙串。清空后保存会删除已保存的授权。") {
                        SecureField("输入 API Key", text: $viewModel.draftAPIKey)
                    }
                    DisclosureGroup("环境变量") {
                        Text(viewModel.environmentVariableName())
                            .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            .padding(.top, 6)
                    }
                    .font(.caption)
                }
            }
            .disabled(viewModel.isBusy)
            CodexProviderEditorActions(viewModel: viewModel, appStore: appStore)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CodexProviderEditorHeader: View {
    let viewModel: CodexProviderManagerViewModel
    let appStore: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(viewModel.draft.isBuiltIn ? "OpenAI" : (viewModel.isCreatingNew ? String(localized: "新建 Provider") : String(localized: "编辑 Provider")))
                    .font(.headline)
                Spacer(minLength: 12)
                if !viewModel.draft.isBuiltIn, !viewModel.isCreatingNew {
                    Button(role: .destructive) {
                        Task { await viewModel.delete(using: appStore.codexProviderConfigService) }
                    } label: { Label("删除", systemImage: "trash") }
                    .disabled(viewModel.isBusy || viewModel.draft.id == viewModel.currentProviderID)
                }
            }
            Text(viewModel.draft.isBuiltIn
                ? String(localized: "维护 OpenAI 默认模型；账号授权由上方账号管理。")
                : String(localized: "保存后更新 Codex 配置；应用后切换当前模型路由。"))
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

private struct CodexProviderEditorActions: View {
    let viewModel: CodexProviderManagerViewModel
    let appStore: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button("保存") { Task { await viewModel.save(using: appStore.codexProviderConfigService) } }
                    .buttonStyle(.borderedProminent).disabled(viewModel.isBusy)
                Button("应用") {
                    Task { await viewModel.setCurrent(using: appStore.codexProviderConfigService, coordinator: appStore.codexRouterCoordinator) }
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isBusy || viewModel.isCreatingNew || viewModel.hasUnsavedChanges || viewModel.draft.id == viewModel.currentProviderID)
                if viewModel.isWorking || viewModel.isLoadingAPIKey { ProgressView().controlSize(.small) }
            }
            if viewModel.hasUnsavedChanges, !viewModel.isCreatingNew {
                Text("先保存修改，再应用路由。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct CodexProviderManagerFeedback: View {
    let viewModel: CodexProviderManagerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = viewModel.errorMessage { ProviderMessage(text: error, isError: true) }
            else if let status = viewModel.statusMessage { ProviderMessage(text: status) }
        }
    }
}

private struct CodexRouterControlPanel: View {
    let viewModel: CodexProviderManagerViewModel
    let appStore: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    routerToggle
                    Spacer(minLength: 12)
                    checkButton
                }
                VStack(alignment: .leading, spacing: 12) {
                    routerToggle
                    checkButton
                }
            }
            if let status = viewModel.routerStatus {
                Label(status.statusText, systemImage: status.canUseRouter ? "checkmark.circle" : "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if status.isConfigured && !status.catalogFileExists {
                    ProviderMessage(text: String(localized: "模型目录不存在：\(status.modelCatalogPath ?? "merged-models.json")"), isError: true)
                }
            } else {
                Text(viewModel.isLoading ? String(localized: "正在检测 Router 配置…") : String(localized: "尚未获取 Router 状态"))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var routerToggle: some View {
        Toggle("启用 Router", isOn: Binding(
            get: { viewModel.isRouterEnabled },
            set: { enabled in
                Task { await viewModel.setRouterEnabled(enabled, using: appStore.codexProviderConfigService, coordinator: appStore.codexRouterCoordinator) }
            }
        ))
        .toggleStyle(.switch)
        .disabled(viewModel.isBusy)
    }

    private var checkButton: some View {
        HStack(spacing: 8) {
            if viewModel.isRefreshingRouterState || viewModel.isApplyingRouterState { ProgressView().controlSize(.small) }
            Button(viewModel.isRefreshingRouterState ? String(localized: "检测中…") : String(localized: "检测状态")) {
                Task { await viewModel.refreshRouterStatus(using: appStore.codexRouterCoordinator) }
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isBusy)
        }
    }
}

// MARK: - GitHub Copilot

struct CopilotProviderContent: View {
    @Environment(AppStore.self) private var appStore
    @State private var githubToken = ""
    @State private var savedToken = ""
    @State private var verifiedToken: String?
    @State private var importedToken: String?
    @State private var importError: String?
    @State private var isVerifying = false
    @State private var isImporting = false
    @State private var isLoading = true

    private var isBusy: Bool { isVerifying || isImporting || isLoading }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("使用 GitHub OAuth Token 获取 Copilot 额度，可从本地配置导入。")
                .font(.callout).foregroundStyle(.secondary)
            ProviderField(title: "GitHub OAuth Token") {
                SecureField("输入 Token 或从本地配置导入", text: $githubToken)
                    .disabled(isBusy)
            }
            HStack(spacing: 10) {
                Button("保存并验证") { saveToken() }
                    .buttonStyle(.borderedProminent)
                    .disabled(githubToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBusy)
                Button("从本地配置导入") { Task { await importToken() } }
                    .buttonStyle(.bordered).disabled(isBusy)
                if isBusy { ProgressView().controlSize(.small) }
            }
            if let error = importError {
                ProviderMessage(text: error, isError: true)
            } else if verifiedToken == githubToken, !githubToken.isEmpty {
                ProviderMessage(text: String(localized: "授权已验证并保存"))
            } else if importedToken == githubToken, !githubToken.isEmpty {
                Text("已导入授权，保存前将验证可用性。")
                    .font(.callout).foregroundStyle(.secondary)
            } else if !savedToken.isEmpty, githubToken == savedToken {
                Text("已保存授权；可重新验证可用性。")
                    .font(.callout).foregroundStyle(.secondary)
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

// MARK: - Antigravity

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

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("使用 Google 登录添加账号，或自动读取本地授权。每个账号分别显示 5 小时与每周额度。")
                .font(.callout).foregroundStyle(.secondary)
            AntigravityAccountActions(isWorking: isWorking || isLoading, onLogin: {
                runAsyncAction {
                    _ = try await appStore.antigravityAccountService.addAccountViaOAuth()
                    try await reload()
                    await appStore.syncService?.refreshTool(.antigravity)
                }
            }, onRefresh: {
                runAsyncAction {
                    try await reload()
                    await appStore.syncService?.refreshTool(.antigravity)
                }
            })
            if let errorMessage { ProviderMessage(text: errorMessage, isError: true) }
            if !ownedAccounts.isEmpty {
                AntigravityOwnedAccounts(accounts: ownedAccounts, isWorking: isWorking) { email in
                    runAsyncAction {
                        try await appStore.antigravityAccountService.deleteAccount(email: email)
                        try await reload()
                        await appStore.syncService?.refreshTool(.antigravity)
                    }
                }
            }
            AntigravityQuotaAccounts(
                accounts: appStore.syncService?.latestAntigravityAccounts ?? [],
                hiddenEmails: hiddenAccountEmails,
                isLoading: isLoading || isWorking,
                onSetVisibility: { email, isVisible in
                    setHiddenAccount(email, isVisible)
                }
            )
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
            Button("添加 Google 账号", action: onLogin).buttonStyle(.borderedProminent)
            Button("刷新额度", action: onRefresh).buttonStyle(.bordered)
            if isWorking { ProgressView().controlSize(.small) }
        }
        .disabled(isWorking)
    }
}

private struct AntigravityOwnedAccounts: View {
    let accounts: [AGStoredAccount]
    let isWorking: Bool
    let onDelete: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("已保存的 Google 账号").font(.callout.weight(.semibold)).padding(.bottom, 8)
            ForEach(accounts, id: \.email) { account in
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                    Text(account.label).font(.callout).textSelection(.enabled)
                    Spacer(minLength: 12)
                    Button(role: .destructive) { onDelete(account.email) } label: { Label("删除", systemImage: "trash") }
                        .buttonStyle(.borderless).disabled(isWorking)
                }
                .padding(.vertical, 12)
                if account.email != accounts.last?.email { Divider().padding(.leading, 28) }
            }
        }
    }
}

private struct AntigravityQuotaAccounts: View {
    let accounts: [AGAccountQuota]
    let hiddenEmails: Set<String>
    let isLoading: Bool
    let onSetVisibility: @MainActor @Sendable (String, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if accounts.isEmpty {
                if isLoading {
                    ProgressView("正在读取账号…").controlSize(.small)
                } else {
                    ProviderEmptyState(title: "尚未获取账号额度", description: "添加 Google 账号，或刷新已配置的本地授权。")
                }
            } else {
                ForEach(accounts) { account in
                    AGAccountCard(account: account, isAccountHidden: hiddenEmails.contains(account.email)) {
                        onSetVisibility(account.email, $0)
                    }
                    if account.id != accounts.last?.id { Divider() }
                }
            }
        }
    }
}

struct AGAccountCard: View {
    let account: AGAccountQuota
    let isAccountHidden: Bool
    let onToggleAccount: @MainActor @Sendable (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AGAccountQuotaBody(account: account)
            Toggle("在菜单栏显示此账号", isOn: Binding(get: { !isAccountHidden }, set: onToggleAccount))
                .toggleStyle(.checkbox)
                .font(.callout)
        }
    }
}
