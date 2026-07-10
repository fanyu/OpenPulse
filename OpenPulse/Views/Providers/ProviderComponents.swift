import SwiftUI
import SwiftData
import Charts

// MARK: - Claude Code Content

struct ClaudeProviderContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("数据源: \(Provider.claudeCode.dataSourcePath)", systemImage: "folder.badge.gearshape").font(.caption).foregroundStyle(.secondary)
            Text("Claude Code 将对话记录存储在本地 JSONL 文件，无需额外配置即可自动同步。").font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Codex CLI Content

struct CodexProviderContent: View {
    let appStore: AppStore
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var providerManager = CodexProviderManagerViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("数据源: \(Provider.codex.dataSourcePath)", systemImage: "folder.badge.gearshape").font(.caption).foregroundStyle(.secondary)
            Text("支持多账户导入、OpenAI OAuth 登录、额度轮询，以及将任一账户切换为当前 `~/.codex/auth.json`。")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("导入当前账号") {
                    runAsyncAction {
                        try await appStore.codexAccountService.importCurrentAuth()
                    }
                }
                .buttonStyle(ProminentActionButtonStyle(fillColor: Color.black.opacity(0.58)))
                .controlSize(.small)
                Button(isWorking ? "登录中..." : "新增 OpenAI 登录") {
                    runAsyncAction {
                        try await appStore.codexAccountService.addAccountViaOAuth()
                    }
                }
                .buttonStyle(ProminentActionButtonStyle(fillColor: Color.black.opacity(0.82)))
                .controlSize(.small)
                .disabled(isWorking)
                Button("刷新额度") {
                    runAsyncAction {
                        _ = await appStore.codexAccountService.refreshAllUsage(force: true)
                    }
                }
                .buttonStyle(ProminentActionButtonStyle(fillColor: Color.black.opacity(0.58)))
                .controlSize(.small)
                .disabled(isWorking)
            }

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }

            if let accounts = appStore.syncService?.latestCodexAccounts, !accounts.isEmpty {
                VStack(spacing: 12) {
                    ForEach(accounts) { account in
                        CodexProviderAccountCard(
                            account: account,
                            isWorking: isWorking,
                            onSwitch: {
                                runAsyncAction {
                                    _ = try await appStore.codexAccountService.switchAccount(id: account.id)
                                }
                            },
                            onDelete: {
                                runAsyncAction {
                                    await appStore.codexAccountService.deleteAccount(id: account.id)
                                }
                            }
                        )
                    }
                }
            } else {
                Text("还没有 Codex 账号。先导入当前 `~/.codex/auth.json`，或者直接新增 OpenAI 登录。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Divider().opacity(0.12)

            CodexProviderManagerSection(
                viewModel: providerManager,
                appStore: appStore
            )
        }
        .task {
            if providerManager.providers.isEmpty {
                await providerManager.load(using: appStore.codexProviderConfigService)
            }
        }
    }

    private func runAsyncAction(_ action: @escaping () async throws -> Void) {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await action()
                await appStore.syncService?.sync(tool: .codex)
                await MainActor.run { isWorking = false }
            } catch {
                await MainActor.run {
                    isWorking = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

private struct CodexProviderManagerSection: View {
    @Bindable var viewModel: CodexProviderManagerViewModel
    let appStore: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Providers")
                        .font(.headline)
                    Text("维护第三方 Provider，并为每个 Provider 指定默认模型。菜单栏切换时会同步切换到这里配置的默认模型。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("新增 Provider") {
                    viewModel.beginCreate()
                }
                .buttonStyle(ProminentActionButtonStyle(fillColor: Color.black.opacity(0.82)))
                .controlSize(.small)
                .disabled(viewModel.isWorking)
            }

            HStack(alignment: .top, spacing: 16) {
                providerList
                    .frame(minWidth: 220, maxWidth: 240)
                providerEditor
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if let statusMessage = viewModel.statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var providerList: some View {
        VStack(alignment: .leading, spacing: 10) {
            if viewModel.isLoading {
                ProgressView("读取 Provider…")
                    .controlSize(.small)
            } else {
                ForEach(viewModel.providers) { provider in
                    Button {
                        Task {
                            await viewModel.selectProvider(
                                id: provider.id,
                                using: appStore.codexProviderConfigService
                            )
                        }
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(provider.name)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.primary)
                                    if provider.id == viewModel.currentProviderID {
                                        Text("当前")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(.green)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2)
                                            .background(Color.green.opacity(0.12), in: Capsule())
                                    }
                                }
                                Text(provider.id)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                Text(provider.defaultModel.isEmpty ? "未配置默认模型" : provider.defaultModel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(viewModel.selectedProviderID == provider.id ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(viewModel.selectedProviderID == provider.id ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.05), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var providerEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.draft.isBuiltIn ? "OpenAI 内建 Provider" : (viewModel.isCreatingNew ? "新建 Provider" : "编辑 Provider"))
                        .font(.system(size: 14, weight: .bold))
                    Text(viewModel.draft.isBuiltIn ? "OpenAI 使用内建 Provider；这里只维护默认模型。" : "保存后会回写 `~/.codex/config.toml`。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !viewModel.draft.isBuiltIn, !viewModel.isCreatingNew {
                    Button(role: .destructive) {
                        Task {
                            await viewModel.delete(using: appStore.codexProviderConfigService)
                        }
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                    .disabled(viewModel.isWorking || viewModel.draft.id == viewModel.currentProviderID)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    fieldLabel("内部 ID")
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("provider-id", text: $viewModel.draft.id)
                            .textFieldStyle(.roundedBorder)
                            .disabled(viewModel.isWorking || viewModel.draft.isBuiltIn || !viewModel.isCreatingNew)
                        if !viewModel.draft.isBuiltIn {
                            Text("用于写入 Codex 配置、切换 provider，以及生成环境变量名。建议使用短的英文标识，例如 `mimo`、`openrouter`。")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                GridRow {
                    fieldLabel("名称")
                    TextField("Provider Name", text: $viewModel.draft.name)
                        .textFieldStyle(.roundedBorder)
                        .disabled(viewModel.isWorking || viewModel.draft.isBuiltIn)
                }
                GridRow {
                    fieldLabel("Base URL")
                    TextField("https://example.com/v1", text: $viewModel.draft.baseURL)
                        .textFieldStyle(.roundedBorder)
                        .disabled(viewModel.isWorking || viewModel.draft.isBuiltIn)
                }
                GridRow {
                    fieldLabel("默认模型")
                    TextField("model-name", text: $viewModel.draft.defaultModel)
                        .textFieldStyle(.roundedBorder)
                        .disabled(viewModel.isWorking)
                }
                GridRow {
                    fieldLabel("API Key")
                    VStack(alignment: .leading, spacing: 4) {
                        SecureField("输入真实 API Key", text: $viewModel.draftAPIKey)
                            .textFieldStyle(.roundedBorder)
                            .disabled(viewModel.isWorking || viewModel.draft.isBuiltIn)
                        if !viewModel.draft.isBuiltIn {
                            Text("这里填写的是真实 API Key。OpenPulse 会自动生成环境变量 `\(viewModel.environmentVariableName())`，并在保存时写入 Keychain 和 `launchctl`。清空后保存会删除该变量。")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                Button("保存") {
                    Task {
                        await viewModel.save(using: appStore.codexProviderConfigService)
                    }
                }
                .buttonStyle(ProminentActionButtonStyle(fillColor: Color.black.opacity(0.82)))
                .controlSize(.small)
                .disabled(viewModel.isWorking)

                Button("设为当前") {
                    Task {
                        await viewModel.setCurrent(
                            using: appStore.codexProviderConfigService,
                            codexAccountService: appStore.codexAccountService
                        )
                    }
                }
                .buttonStyle(ProminentActionButtonStyle(fillColor: Color.green.opacity(0.78)))
                .controlSize(.small)
                .disabled(viewModel.isWorking || viewModel.draft.id.isEmpty || viewModel.draft.id == viewModel.currentProviderID)

                if viewModel.isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .padding(16)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }

    private func fieldLabel(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 82, alignment: .leading)
    }
}

private struct CodexProviderAccountCard: View {
    let account: CodexAccountSnapshot
    let isWorking: Bool
    let onSwitch: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(account.titleText).font(.headline)
                        if account.isCurrent {
                            Text("当前")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.green.opacity(0.12), in: Capsule())
                        }
                    }
                    if let subtitleText = account.subtitleText {
                        Text(subtitleText).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        if let metaText = account.metaText {
                            Text(metaText).font(.caption2).foregroundStyle(.tertiary)
                        }
                        if let planType = account.planType, !planType.isEmpty, planType != account.metaText {
                            Text(planType).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer()
                HStack(spacing: 8) {
                    Button("切换", action: onSwitch)
                        .buttonStyle(.bordered)
                        .disabled(isWorking || account.isCurrent)
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .disabled(isWorking)
                }
            }
            if let error = account.usageError {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.05), lineWidth: 1))
    }
}

// MARK: - GitHub Copilot Content

struct CopilotProviderContent: View {
    @State private var githubToken = ""
    @State private var didImport = false
    @State private var importError: String?
    @State private var isVerifying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("GitHub OAuth Token").font(.caption.bold()).foregroundStyle(.secondary)
                    Spacer()
                    if isVerifying {
                        ProgressView().controlSize(.small)
                    } else if !githubToken.isEmpty && importError == nil {
                        Label("已验证", systemImage: "checkmark.shield.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.green)
                    }
                }
                SecureField("输入 Token 或点击下方导入", text: $githubToken).textFieldStyle(.roundedBorder)
            }
            
            HStack(spacing: 12) {
                Button("从本地配置导入") { importToken() }.buttonStyle(.bordered)
                if didImport { Label("导入成功", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption) }
                Spacer()
                Button("保存并验证") { saveToken() }
                    .buttonStyle(ProminentActionButtonStyle(fillColor: Color.black.opacity(0.82)))
                    .disabled(githubToken.isEmpty || isVerifying)
            }
            if let error = importError { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .onAppear { loadAndAutoImport() }
    }

    private func loadAndAutoImport() {
        githubToken = (try? KeychainService.retrieve(key: KeychainService.Keys.githubToken)) ?? ""
        if githubToken.isEmpty { importToken(silent: true) }
    }

    private func importToken(silent: Bool = false) {
        importError = nil; didImport = false
        let proxyDir = URL.homeDirectory.appending(path: ".cli-proxy-api")
        guard let files = try? FileManager.default.contentsOfDirectory(at: proxyDir, includingPropertiesForKeys: nil).filter({ $0.lastPathComponent.hasPrefix("github-copilot-") && $0.pathExtension == "json" }), let file = files.first else {
            if !silent { importError = "未找到配置文件" }
            return
        }
        do {
            let data = try Data(contentsOf: file)
            let auth = try JSONDecoder().decode([String: String].self, from: data)
            if let token = auth["access_token"], !token.isEmpty {
                githubToken = token; didImport = true
                if silent { saveToken() }
            }
        } catch { if !silent { importError = "读取失败" } }
    }
    
    private func saveToken() {
        isVerifying = true
        Task {
            do {
                try KeychainService.store(key: KeychainService.Keys.githubToken, value: githubToken)
                _ = try await CopilotAPIClient().fetchQuota()
                await MainActor.run { isVerifying = false; importError = nil }
            } catch { await MainActor.run { isVerifying = false; importError = "验证失败" } }
        }
    }
}

// MARK: - Antigravity Content

struct AntigravityProviderContent: View {
    let appStore: AppStore
    @AppStorage("ag.hiddenAccountEmails") private var hiddenAccountEmailsRaw = ""
    @State private var ownedAccounts: [AGStoredAccount] = []
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var hiddenAccountEmails: Set<String> { Set(hiddenAccountEmailsRaw.components(separatedBy: ",").filter { !$0.isEmpty }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("扫描本地 `~/.cli-proxy-api` 授权，或直接在 App 内用 Google 登录添加账号；额度按 5 小时 / 每周窗口显示。")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button(isWorking ? "登录中..." : "添加 Antigravity 账号") {
                    runAsyncAction {
                        _ = try await appStore.antigravityAccountService.addAccountViaOAuth()
                        await reload()
                        await appStore.syncService?.refreshTool(.antigravity)
                    }
                }
                .buttonStyle(ProminentActionButtonStyle(fillColor: Color.black.opacity(0.82)))
                .controlSize(.small)
                .disabled(isWorking)
                Button("刷新额度") {
                    runAsyncAction { await appStore.syncService?.refreshTool(.antigravity) }
                }
                .buttonStyle(ProminentActionButtonStyle(fillColor: Color.black.opacity(0.58)))
                .controlSize(.small)
                .disabled(isWorking)
            }

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }

            if !ownedAccounts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("App 内登录的账号").font(.caption).foregroundStyle(.tertiary)
                    ForEach(ownedAccounts, id: \.email) { account in
                        HStack {
                            Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                            Text(account.label).font(.system(size: 12, weight: .medium))
                            Spacer()
                            Button {
                                runAsyncAction {
                                    await appStore.antigravityAccountService.deleteAccount(email: account.email)
                                    await reload()
                                    await appStore.syncService?.refreshTool(.antigravity)
                                }
                            } label: { Image(systemName: "trash").foregroundStyle(.red) }
                            .buttonStyle(.plain)
                            .disabled(isWorking)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }

            if let accounts = appStore.syncService?.latestAntigravityAccounts, !accounts.isEmpty {
                VStack(spacing: 16) {
                    ForEach(accounts) { account in
                        AGAccountCard(account: account, isAccountHidden: hiddenAccountEmails.contains(account.email)) { setHiddenAccount(account.email, $0) }
                    }
                }
            } else {
                Text("正在加载账号数据...").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .task { await reload() }
    }

    private func reload() async {
        ownedAccounts = await appStore.antigravityAccountService.listAccounts()
    }

    private func runAsyncAction(_ action: @escaping () async throws -> Void) {
        isWorking = true
        errorMessage = nil
        Task {
            do { try await action() }
            catch {
                errorMessage = error.localizedDescription
                AppLogger.shared.warning("[antigravity] \(error.localizedDescription)")
            }
            isWorking = false
        }
    }

    private func setHiddenAccount(_ email: String, _ isVisible: Bool) {
        var emails = hiddenAccountEmails; if isVisible { emails.remove(email) } else { emails.insert(email) }
        hiddenAccountEmailsRaw = emails.joined(separator: ",")
    }
}

struct AGAccountCard: View {
    let account: AGAccountQuota
    let isAccountHidden: Bool
    let onToggleAccount: (Bool) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer()
                Toggle("", isOn: Binding(get: { !isAccountHidden }, set: { onToggleAccount($0) }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            AGAccountQuotaBody(account: account)
        }
        .padding(14)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.05), lineWidth: 1))
    }
}
