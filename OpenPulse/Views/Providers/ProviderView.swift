import SwiftUI

/// Provider Tab — configure auth, accounts, and model visibility per provider.
struct ProviderView: View {
    @Environment(AppStore.self) private var appStore
    @State private var selected: Provider? = nil

    var body: some View {
        VStack(spacing: 0) {
            providerFilterBar
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 12)
            
            Divider().opacity(0.1)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if let provider = selected {
                        ProviderCardContainer(provider: provider)
                    } else {
                        ForEach(Provider.allCases, id: \.self) { provider in
                            ProviderCardContainer(provider: provider)
                        }
                    }
                }
                .padding(24)
            }
        }
        .navigationTitle("接入")
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var providerFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                FilterChip(label: "全部", isSelected: selected == nil) {
                    withAnimation(.spring(duration: 0.3)) { selected = nil }
                }
                ForEach(Provider.allCases, id: \.self) { provider in
                    FilterChip(label: provider.displayName, isSelected: selected == provider) {
                        withAnimation(.spring(duration: 0.3)) {
                            selected = (selected == provider) ? nil : provider
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Card Container

private struct ProviderCardContainer: View {
    let provider: Provider
    @Environment(AppStore.self) private var appStore

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                ToolLogoImage(tool: provider.tool, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName).font(.title3.bold())
                    Text(provider.tool.displayName).font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                statusBadge
            }
            
            Divider().opacity(0.1)
            
            providerContent
        }
        .padding(24)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.primary.opacity(0.05), lineWidth: 1))
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }
    
    @ViewBuilder
    private var providerContent: some View {
        switch provider {
        case .claudeCode:   ClaudeProviderContent()
        case .codex:        CodexProviderContent(appStore: appStore)
        case .copilot:      CopilotProviderContent()
        case .antigravity:  AntigravityProviderContent(appStore: appStore)
        case .opencode:     OpenCodeProviderContent()
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        let configured = isConfigured
        HStack(spacing: 5) {
            Circle()
                .fill(configured ? Color.green : Color.orange)
                .frame(width: 6, height: 6)
            Text(configured ? "已配置" : "待配置")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(configured ? .green : .orange)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background((configured ? Color.green : Color.orange).opacity(0.1), in: Capsule())
    }

    private var isConfigured: Bool {
        switch provider {
        case .codex:
            return !(appStore.syncService?.latestCodexAccounts.isEmpty ?? true)
                || FileManager.default.fileExists(atPath: URL.homeDirectory.appending(path: ".codex/auth.json").path)
        case .claudeCode, .antigravity, .opencode: return true
        case .copilot:
            guard let token = try? KeychainService.retrieve(key: KeychainService.Keys.githubToken) else { return false }
            return !token.isEmpty
        }
    }
}
