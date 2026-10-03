import SwiftUI
import SwiftData

@MainActor
@Observable
final class AppStore {
    static let shared = AppStore()

    /// Hosted tests must not import personal data, install hooks, or contact APIs.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    var selectedTab: AppTab = .trends
    var lastSyncDate: Date?
    let codexAccountService = CodexAccountService()
    let codexProviderConfigService = CodexProviderConfigService()
    let codexRouterCoordinator = CodexRouterCoordinator()
    let antigravityAccountService = AntigravityAccountService()
    let configsViewModel = ConfigsViewModel()

    let modelContainer: ModelContainer
    private(set) var syncService: DataSyncService?

    init(inMemory: Bool = AppStore.isRunningTests) {
        let schema = Schema([
            SessionRecord.self,
            DailyStatsRecord.self,
            QuotaRecord.self,
        ])
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: .none
        )
        do {
            modelContainer = try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    func startSync() {
        guard !Self.isRunningTests else { return }
        guard syncService == nil else { return }
        ClaudeCodeBridgeInstaller.installIfNeeded()
        // Sync writes use short-lived dedicated contexts to avoid the main context
        // retaining a huge registered object graph after long-running imports.
        modelContainer.mainContext.autosaveEnabled = false
        let service = DataSyncService(
            modelContainer: modelContainer,
            codexAccountService: codexAccountService,
            deskSnapshotPublisher: DeskSnapshotPublisher.makeIfAvailable()
        )
        syncService = service
        service.start()
    }

    func clearUsageCache() throws {
        guard syncService?.isSyncingActive != true,
              syncService?.refreshingAntigravityAccountEmails.isEmpty != false else {
            throw NSError(domain: "OpenPulse.Cache", code: 1, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "同步完成后再清除缓存。")
            ])
        }
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        try context.delete(model: SessionRecord.self)
        try context.delete(model: DailyStatsRecord.self)
        try context.delete(model: QuotaRecord.self)
        try context.save()
        syncService?.usageCacheWasCleared()
        lastSyncDate = nil
    }
}

enum AppTab: String, CaseIterable {
    case trends    = "总览"
    case quota     = "配额"
    case activity  = "活动"
    case menuBar   = "菜单栏"
    case providers = "接入"
    case configs   = "配置"
    case settings  = "设置"
    case logs      = "日志"

    var icon: String {
        switch self {
        case .trends:    "chart.line.uptrend.xyaxis"
        case .quota:     "chart.pie.fill"
        case .activity:  "terminal.fill"
        case .menuBar:   "menubar.dock.rectangle"
        case .providers: "cable.connector"
        case .configs:   "doc.badge.gearshape.fill"
        case .settings:  "gearshape.fill"
        case .logs:      "scroll"
        }
    }

    var localizedTitle: LocalizedStringKey {
        switch self {
        case .trends:    "总览"
        case .quota:     "配额"
        case .activity:  "活动"
        case .menuBar:   "菜单栏"
        case .providers: "接入"
        case .configs:   "配置"
        case .settings:  "设置"
        case .logs:      "日志"
        }
    }
}
