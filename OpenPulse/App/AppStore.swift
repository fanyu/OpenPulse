import SwiftUI
import SwiftData

@MainActor
@Observable
final class AppStore {
    static let shared = AppStore()

    var selectedTab: AppTab = .trends
    var lastSyncDate: Date?
    let codexAccountService = CodexAccountService()

    let modelContainer: ModelContainer
    private(set) var syncService: DataSyncService?

    init() {
        let schema = Schema([
            SessionRecord.self,
            DailyStatsRecord.self,
            QuotaRecord.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            modelContainer = try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    func startSync() {
        guard syncService == nil else { return }
        // Use the container's main context so @Query views see writes immediately
        let context = modelContainer.mainContext
        // DataSyncService already performs explicit saves after each sync cycle.
        // Disabling SwiftData autosave avoids a long-lived background timer that
        // repeatedly re-validates the entire context on the main thread.
        context.autosaveEnabled = false
        let service = DataSyncService(modelContext: context, codexAccountService: codexAccountService)
        syncService = service
        service.start()
    }
}

enum AppTab: String, CaseIterable {
    case trends    = "总览"
    case quota     = "配额"
    case activity  = "活动"
    case providers = "接入"
    case configs   = "配置"
    case settings  = "设置"
    case logs      = "日志"

    var icon: String {
        switch self {
        case .trends:    "chart.line.uptrend.xyaxis"
        case .quota:     "chart.pie.fill"
        case .activity:  "list.bullet.rectangle.fill"
        case .providers: "cable.connector"
        case .configs:   "folder.badge.gearshape"
        case .settings:  "gearshape.fill"
        case .logs:      "scroll"
        }
    }
}
