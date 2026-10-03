import SwiftUI
import SwiftData

struct MainWindowView: View {
    @Environment(AppStore.self) private var appStore

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .environment(appStore)
        } detail: {
            detailView
                .environment(appStore)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, minHeight: 560)
        .background(OpenWindowActionCapture())
        .background(MainWindowCapture())
    }

    @ViewBuilder
    private var detailView: some View {
        switch appStore.selectedTab {
        case .trends:    TrendsView()
        case .quota:     QuotaView()
        case .activity:  SessionHistoryView()
        case .menuBar:   MenuBarSettingsView()
        case .providers: ProviderView()
        case .configs:   ConfigsView()
        case .settings:  SettingsView()
        case .logs:      LogView()
        }
    }
}

struct SidebarView: View {
    @Environment(AppStore.self) private var appStore

    var body: some View {
        @Bindable var store = appStore
        List(selection: $store.selectedTab) {
            Section("监控") {
                ForEach([AppTab.trends, .quota, .activity], id: \.self) { tab in
                    SidebarDestination(tab: tab)
                }
            }
            Section("工作空间") {
                ForEach([AppTab.providers, .configs], id: \.self) { tab in
                    SidebarDestination(tab: tab)
                }
            }
            Section("应用") {
                ForEach([AppTab.menuBar, .settings, .logs], id: \.self) { tab in
                    SidebarDestination(tab: tab)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            SidebarIdentity()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarSyncStatus()
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 204, max: 240)
    }
}

private struct SidebarIdentity: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 20, weight: .medium))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("OpenPulse")
                    .font(.system(size: 16, weight: .semibold))
                Text("AI 用量与额度")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 20)
    }
}

private struct SidebarDestination: View {
    let tab: AppTab

    var body: some View {
        Label {
            Text(tab.localizedTitle)
        } icon: {
            Image(systemName: tab.icon)
                .foregroundStyle(.secondary)
        }
            .font(.system(size: 13))
            .padding(.vertical, 3)
            .tag(tab)
    }
}

private struct SidebarSyncStatus: View {
    @Environment(AppStore.self) private var appStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if appStore.syncService?.isSyncingActive == true {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text("正在同步")
                }
            } else if appStore.syncService?.syncError != nil {
                Button {
                    appStore.selectedTab = .logs
                } label: {
                    Label("同步遇到问题", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help("查看同步日志")
            } else {
                Label("本地用量监控", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
            }
            if let date = appStore.syncService?.lastSyncDate ?? appStore.lastSyncDate {
                Text("更新于 \(date, style: .relative)前")
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            } else {
                Text("等待首次同步")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
    }
}
