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

/// Menubar icon: shows a waveform symbol normally; switches to warning style
/// and adds a badge when any tool's remaining quota drops below 15%.
private struct MenuBarIcon: View {
    @Query private var quotas: [QuotaRecord]
    @Environment(AppStore.self) private var appStore

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
        Image(systemName: "gauge.open.with.lines.needle.67percent.and.arrowtriangle")
            .symbolRenderingMode(isWarning ? .multicolor : .monochrome)
            .background(MenuBarButtonCapture())
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
