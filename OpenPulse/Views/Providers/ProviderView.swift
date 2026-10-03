import SwiftUI

/// Account access and connection settings for every supported tool.
struct ProviderView: View {
    @State private var selected: Provider? = nil

    private var visibleProviders: [Provider] {
        selected.map { [$0] } ?? Provider.allCases
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ProviderPageHeader(selection: $selected)
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(visibleProviders) { provider in
                        ProviderCardContainer(provider: provider)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("接入")
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct ProviderPageHeader: View {
    @Binding var selection: Provider?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("接入")
                    .font(.system(size: 30, weight: .semibold))
                Text("管理工具账号、授权与模型路由。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                ProviderFilterPicker(selection: $selection, usesMenu: false)
                ProviderFilterPicker(selection: $selection, usesMenu: true)
            }
        }
    }
}

private struct ProviderFilterPicker: View {
    @Binding var selection: Provider?
    let usesMenu: Bool

    var body: some View {
        if usesMenu {
            picker.pickerStyle(.menu)
        } else {
            picker.pickerStyle(.segmented).fixedSize(horizontal: true, vertical: false)
        }
    }

    private var picker: some View {
        Picker("工具", selection: $selection) {
            Text("全部").tag(Optional<Provider>.none)
            ForEach(Provider.allCases) { provider in
                Text(provider.displayName).tag(Optional(provider))
            }
        }
    }
}

private struct ProviderCardContainer: View {
    @Environment(AppStore.self) private var appStore
    let provider: Provider

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ProviderSectionHeader(provider: provider)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                switch provider {
                case .claudeCode: ClaudeProviderContent()
                case .codex: CodexProviderContent(appStore: appStore)
                case .copilot: CopilotProviderContent()
                case .antigravity: AntigravityProviderContent(appStore: appStore)
                }
            }
        }
        .padding(24)
        .dashboardSurface()
    }
}

private struct ProviderSectionHeader: View {
    @Environment(AppStore.self) private var appStore
    let provider: Provider

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                identity
                Spacer(minLength: 16)
                status
            }
            VStack(alignment: .leading, spacing: 10) {
                identity
                status
            }
        }
    }

    private var identity: some View {
        HStack(spacing: 12) {
            ToolLogoImage(tool: provider.tool, size: 30)
            Text(provider.displayName).font(.title3.weight(.semibold))
        }
    }

    private var status: some View {
        // Describe observed data without probing credentials while rendering.
        let hasData: Bool = switch provider {
        case .codex: !(appStore.syncService?.latestCodexAccounts.isEmpty ?? true)
        case .claudeCode: appStore.syncService?.latestClaudeUsage != nil
        case .copilot: appStore.syncService?.latestCopilotSnapshots != nil
        case .antigravity: !(appStore.syncService?.latestAntigravityAccounts?.isEmpty ?? true)
        }
        return Label(hasData ? String(localized: "已获取数据") : String(localized: "等待数据"), systemImage: hasData ? "checkmark.circle" : "clock")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
