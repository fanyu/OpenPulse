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
        .background(OpenWindowActionCapture())
        .background(MainWindowCapture())
    }

    @ViewBuilder
    private var detailView: some View {
        switch appStore.selectedTab {
        case .trends:    TrendsView()
        case .quota:     QuotaView()
        case .activity:  SessionHistoryView()
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
        List(AppTab.allCases, id: \.self, selection: $store.selectedTab) { tab in
            Label(tab.rawValue, systemImage: tab.icon)
                .tag(tab)
        }
        .listStyle(.sidebar)
        .navigationTitle("OpenPulse")
        .navigationSplitViewColumnWidth(min: 160, ideal: 180)
    }
}
