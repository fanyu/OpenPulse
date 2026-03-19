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
                    .buttonStyle(.bordered)
                Button(isWorking ? "登录中..." : "新增 OpenAI 登录") {
                    runAsyncAction {
                        try await appStore.codexAccountService.addAccountViaOAuth()
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(isWorking)
                Button("刷新额度") {
                    runAsyncAction {
                        _ = await appStore.codexAccountService.refreshAllUsage(force: true)
                    }
                }
                .buttonStyle(.bordered)
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
                Button("保存并验证") { saveToken() }.buttonStyle(.glassProminent).disabled(githubToken.isEmpty || isVerifying)
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
    @AppStorage("ag.syncModelConfig") private var syncModelConfig = true
    @AppStorage("ag.hiddenAccountEmails") private var hiddenAccountEmailsRaw = ""
    @AppStorage("ag.hiddenModelIds") private var globalHiddenModelIdsRaw = ""

    private var hiddenAccountEmails: Set<String> { Set(hiddenAccountEmailsRaw.components(separatedBy: ",").filter { !$0.isEmpty }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Toggle("同步所有账号的模型显示配置", isOn: $syncModelConfig).font(.subheadline)
            if let accounts = appStore.syncService?.latestAntigravityAccounts, !accounts.isEmpty {
                VStack(spacing: 16) {
                    ForEach(accounts) { account in
                        AGAccountCard(account: account, syncModelConfig: syncModelConfig, isAccountHidden: hiddenAccountEmails.contains(account.email), globalHiddenIdsRaw: $globalHiddenModelIdsRaw) { setHiddenAccount(account.email, $0) }
                    }
                }
            } else {
                Text("正在加载账号数据...").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func setHiddenAccount(_ email: String, _ isVisible: Bool) {
        var emails = hiddenAccountEmails; if isVisible { emails.remove(email) } else { emails.insert(email) }
        hiddenAccountEmailsRaw = emails.joined(separator: ",")
    }
}

struct AGAccountCard: View {
    let account: AGAccountQuota
    let syncModelConfig: Bool
    let isAccountHidden: Bool
    @Binding var globalHiddenIdsRaw: String
    let onToggleAccount: (Bool) -> Void
    
    @State private var modelsExpanded = false
    @State private var localHiddenIdsRaw: String = ""

    private var hiddenIdsBinding: Binding<String> { syncModelConfig ? $globalHiddenIdsRaw : $localHiddenIdsRaw }
    private var hiddenIds: Set<String> { Set(hiddenIdsBinding.wrappedValue.components(separatedBy: ",").filter { !$0.isEmpty }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.email).font(.system(size: 13, weight: .bold))
                    Text("\(account.models.count) models available").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Spacer()
                HStack(spacing: 16) {
                    Toggle("", isOn: Binding(get: { !isAccountHidden }, set: { onToggleAccount($0) })).toggleStyle(.switch).labelsHidden().controlSize(.small)
                    Button(action: { withAnimation(.spring(duration: 0.3, bounce: 0.1)) { modelsExpanded.toggle() } }) {
                        Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).rotationEffect(.degrees(modelsExpanded ? 180 : 0)).foregroundStyle(.secondary).frame(width: 24, height: 24).background(Color.primary.opacity(0.05), in: Circle())
                    }.buttonStyle(.plain)
                }
            }
            .padding(14).contentShape(Rectangle())
            .onTapGesture { withAnimation(.spring(duration: 0.3, bounce: 0.1)) { modelsExpanded.toggle() } }
            
            if modelsExpanded && !isAccountHidden {
                Divider().opacity(0.05).padding(.horizontal, 14)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
                    ForEach(account.models, id: \.id) { model in
                        let isSelected = !hiddenIds.contains(model.id)
                        Button { toggleModel(model.id) } label: {
                            HStack(spacing: 6) {
                                Circle().fill(isSelected ? Color.green : Color.primary.opacity(0.2)).frame(width: 6, height: 6)
                                Text(model.displayName).font(.system(size: 10, weight: isSelected ? .bold : .medium)).foregroundStyle(isSelected ? .primary : .secondary).lineLimit(1)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading).background(isSelected ? Color.green.opacity(0.1) : Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? Color.green.opacity(0.2) : Color.clear, lineWidth: 1))
                        }.buttonStyle(.plain)
                    }
                }.padding(14).transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .background(Color.primary.opacity(0.03)).clipShape(RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.05), lineWidth: 1))
        .onAppear { localHiddenIdsRaw = UserDefaults.standard.string(forKey: "ag.hiddenModelIds.\(account.email)") ?? "" }
    }

    private func toggleModel(_ id: String) {
        var ids = hiddenIds; if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        let newValue = ids.joined(separator: ","); hiddenIdsBinding.wrappedValue = newValue
        if !syncModelConfig { UserDefaults.standard.set(newValue, forKey: "ag.hiddenModelIds.\(account.email)") }
    }
}

// MARK: - OpenCode Content

struct OpenCodeProviderContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("数据源: \(Provider.opencode.dataSourcePath)", systemImage: "folder.badge.gearshape").font(.caption).foregroundStyle(.secondary)
            Text("OpenCode 使用本地 SQLite 数据库，无需额外配置即可自动同步。").font(.subheadline).foregroundStyle(.secondary)
        }
    }
}
