import SwiftUI
import SwiftData
import AppKit

@main
struct OpenPulseApp: App {
    private let appStore = AppStore.shared

    init() {
        Task { @MainActor in
            AppStore.shared.startSync()
            GlobalHotkeyService.shared.applyFromDefaults()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appStore)
                .modelContainer(appStore.modelContainer)
        } label: {
            MenuBarIcon()
                .environment(appStore)
                .modelContainer(appStore.modelContainer)
        }
        .menuBarExtraStyle(.window)

        Window("OpenPulse", id: "main") {
            MainWindowView()
                .environment(appStore)
                .modelContainer(appStore.modelContainer)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 960, height: 640)
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// Menu bar title: falls back to the app icon by default, or renders the
/// user-selected 5-hour quota items as tool logo + remaining percentage.
private struct MenuBarIcon: View {
    @Query private var quotas: [QuotaRecord]
    @Environment(AppStore.self) private var appStore
    @AppStorage("menubar.titleQuotaTools") private var titleQuotaToolsRaw = ""

    private var orderedTitleQuotaTools: [Tool] {
        let selected = Set(titleQuotaToolsRaw.components(separatedBy: ",").filter { !$0.isEmpty })
        let order = UserDefaults.standard.string(forKey: "menubar.toolOrder") ?? Tool.defaultOrderRaw
        let orderedTools = order.components(separatedBy: ",").compactMap { Tool(rawValue: $0) }
        let tools = orderedTools + Tool.allCases.filter { !orderedTools.contains($0) }
        return tools.filter { selected.contains($0.rawValue) && $0.supportsMenuBarFiveHourDisplay }
    }

    private var titleQuotaItems: [MenuBarQuotaItem] {
        orderedTitleQuotaTools.map { tool in
            switch tool {
            case .codex:
                let remaining = appStore.syncService?.latestCodexAccounts
                    .first(where: \.isCurrent)?
                    .limits?
                    .fiveHourWindow?
                    .usedPercent
                    .map { max(0, 100 - Int($0.rounded())) }
                return MenuBarQuotaItem(tool: .codex, remainingPercent: remaining)
            case .claudeCode:
                let remaining = appStore.syncService?.latestClaudeUsage?
                    .fiveHour?
                    .utilization
                    .map { max(0, 100 - Int($0.rounded())) }
                return MenuBarQuotaItem(tool: .claudeCode, remainingPercent: remaining)
            case .copilot, .antigravity, .opencode:
                return MenuBarQuotaItem(tool: tool, remainingPercent: nil)
            }
        }
    }

    private var isWarning: Bool {
        var fractions: [Double] = []
        let hasCodexAccounts = !(appStore.syncService?.latestCodexAccounts.isEmpty ?? true)
        if let primary = appStore.syncService?.latestCodexAccounts.first(where: \.isCurrent)?.limits?.fiveHourWindow,
           let used = primary.usedPercent {
            fractions.append(max(0, (100 - used) / 100))
        }
        if let usage = appStore.syncService?.latestClaudeUsage,
           let window = usage.fiveHour,
           let util = window.utilization {
            fractions.append(max(0, (100 - util) / 100))
        }
        for q in quotas where Tool(rawValue: q.toolRaw) != nil {
            if hasCodexAccounts && q.tool == .codex {
                continue
            }
            guard let r = q.remaining, let t = q.total, t > 0 else { continue }
            fractions.append(Double(r) / Double(t))
        }
        return (fractions.min() ?? 1.0) < 0.15
    }

    var body: some View {
        HStack(spacing: 3) {
            if titleQuotaItems.isEmpty {
                Image(systemName: "aqi.medium.gauge.open")
                    .symbolRenderingMode(isWarning ? .multicolor : .monochrome)
            } else {
                ForEach(titleQuotaItems) { item in
                    Text("\(item.label)\(item.displayText)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(item.isWarning ? .orange : .primary)
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .background(MenuBarButtonCapture())
    }
}

private struct MenuBarQuotaItem: Identifiable {
    let tool: Tool
    let remainingPercent: Int?

    var id: Tool { tool }

    var label: String {
        switch tool {
        case .codex:
            "O"
        case .claudeCode:
            "C"
        case .copilot, .antigravity, .opencode:
            tool.displayName.prefix(1).uppercased()
        }
    }

    var displayText: String {
        if let remainingPercent {
            return "\(remainingPercent)%"
        }
        return "--"
    }

    var isWarning: Bool {
        guard let remainingPercent else { return false }
        return remainingPercent < 15
    }
}

/// Captures the NSStatusBarButton at launch (label view is always live in the menu bar).
/// Traverses the superview chain to find NSStatusBarButton and registers it with
/// GlobalHotkeyService so the hotkey works before the popover has ever been opened.
private struct MenuBarButtonCapture: NSViewRepresentable {
    func makeNSView(context: Context) -> _MenuBarButtonCaptureView { _MenuBarButtonCaptureView() }
    func updateNSView(_ nsView: _MenuBarButtonCaptureView, context: Context) {}
}

final class _MenuBarButtonCaptureView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // DFS through the window's full view hierarchy — more reliable than
        // superview traversal, which can fail if SwiftUI wraps the hosting view
        // differently on different macOS versions.
        if let button = Self.findButton(in: window.contentView) {
            GlobalHotkeyService.shared.registerStatusBarButton(button)
        }
    }

    private static func findButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let btn = view as? NSStatusBarButton { return btn }
        for sub in view.subviews {
            if let found = findButton(in: sub) { return found }
        }
        return nil
    }
}
