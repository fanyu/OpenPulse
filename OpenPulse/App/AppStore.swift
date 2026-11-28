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
    var selectedSettingsSection: SettingsSection = .general
    var lastSyncDate: Date?
    let codexAccountService = CodexAccountService()
    let antigravityAccountService = AntigravityAccountService()

    func openDiagnosticsLogs() {
        selectedSettingsSection = .diagnostics
        selectedTab = .settings
    }

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
            deskSnapshotPublisher: DeskSnapshotPublisher.makeIfAvailable(),
            sessionScanningActive: WindowCoordinator.shared.isMainWindowVisible,
            antigravityParser: AntigravityParser(accountService: antigravityAccountService)
        )
        syncService = service
        service.start()
    }

    func clearUsageCache() throws {
        guard syncService?.hasAnyRefreshInFlight != true,
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
    case providers = "接入"
    case menuBar   = "菜单栏"
    case settings  = "设置"

    var icon: String {
        switch self {
        case .trends:    "square.grid.2x2"
        case .quota:     "gauge.with.needle"
        case .activity:  "bubble.left.and.text.bubble.right"
        case .providers: "puzzlepiece.extension"
        case .menuBar:   "menubar.rectangle"
        case .settings:  "gearshape"
        }
    }

    var activeIcon: String {
        switch self {
        case .trends:    "square.grid.2x2.fill"
        case .quota:     "gauge.with.needle.fill"
        case .activity:  "bubble.left.and.text.bubble.right.fill"
        case .providers: "puzzlepiece.extension.fill"
        case .menuBar:   "menubar.rectangle"
        case .settings:  "gearshape.fill"
        }
    }

    func sidebarAccentColor(for colorScheme: ColorScheme) -> Color {
        switch self {
        case .trends:
            colorScheme == .dark
                ? Color(red: 0.16, green: 0.80, blue: 0.80)
                : Color(red: 0.05, green: 0.56, blue: 0.60)
        case .quota:
            colorScheme == .dark
                ? Color(red: 0.24, green: 0.82, blue: 0.54)
                : Color(red: 0.12, green: 0.64, blue: 0.40)
        case .activity:
            colorScheme == .dark
                ? Color(red: 0.38, green: 0.66, blue: 1.00)
                : Color(red: 0.16, green: 0.46, blue: 0.90)
        case .providers:
            colorScheme == .dark
                ? Color(red: 0.72, green: 0.52, blue: 0.98)
                : Color(red: 0.52, green: 0.32, blue: 0.84)
        case .menuBar:
            colorScheme == .dark
                ? Color(red: 0.96, green: 0.68, blue: 0.26)
                : Color(red: 0.80, green: 0.48, blue: 0.08)
        case .settings:
            colorScheme == .dark
                ? Color(red: 0.66, green: 0.70, blue: 0.78)
                : Color(red: 0.38, green: 0.42, blue: 0.50)
        }
    }

    var shortcutDigit: KeyEquivalent {
        switch self {
        case .trends:    "1"
        case .quota:     "2"
        case .activity:  "3"
        case .providers: "4"
        case .menuBar:   "5"
        case .settings:  "6"
        }
    }

    var shortcutLabel: String {
        switch self {
        case .trends:    "⌘1"
        case .quota:     "⌘2"
        case .activity:  "⌘3"
        case .providers: "⌘4"
        case .menuBar:   "⌘5"
        case .settings:  "⌘6"
        }
    }

    var localizedTitle: LocalizedStringKey {
        switch self {
        case .trends:    "总览"
        case .quota:     "配额"
        case .activity:  "活动"
        case .providers: "接入"
        case .menuBar:   "菜单栏"
        case .settings:  "设置"
        }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general     = "general"
    case sync        = "sync"
    case diagnostics = "diagnostics"

    var id: String { rawValue }

    var localizedTitle: LocalizedStringKey {
        switch self {
        case .general:     "通用"
        case .sync:        "同步与集成"
        case .diagnostics: "数据与诊断"
        }
    }
}
