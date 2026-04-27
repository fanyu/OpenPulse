import SwiftUI
import AppKit
import SwiftData

@main
struct OpenPulseApp: App {
    @NSApplicationDelegateAdaptor(StatusBarAppDelegate.self) private var statusBarDelegate
    private let appStore = AppStore.shared

    init() {
        Task { @MainActor in
            AppStore.shared.startSync()
            GlobalHotkeyService.shared.applyFromDefaults()
        }
    }

    var body: some Scene {
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

@MainActor
final class StatusBarAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let appStore = AppStore.shared
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var refreshTimer: Timer?
    private var userDefaultsObserver: NSObjectProtocol?
    private var lastSnapshot: StatusBarSnapshot?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private let imageRenderer = StatusBarImageRenderer()
    private var userDefaultsDebounceTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = NSHostingController(
            rootView: MenuBarView()
                .environment(appStore)
                .modelContainer(appStore.modelContainer)
        )
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.image = nil
            button.title = ""
            button.attributedTitle = NSAttributedString(string: "")
            button.imagePosition = .imageOnly
            GlobalHotkeyService.shared.registerStatusBarButton(button)
        }

        // Inject handlers so the global hotkey uses the same NSPopover.show() path as clicking the icon.
        GlobalHotkeyService.shared.toggleHandler = { [weak self] in self?.togglePopover(nil) }
        GlobalHotkeyService.shared.closeHandler  = { [weak self] in self?.popover.performClose(nil) }

        refreshStatusItem()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshStatusItem()
            }
        }
        userDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Debounce: UserDefaults fires on every @AppStorage write; batch into one refresh.
            self?.userDefaultsDebounceTask?.cancel()
            self?.userDefaultsDebounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                self?.refreshStatusItem()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        userDefaultsDebounceTask?.cancel()
        userDefaultsDebounceTask = nil
        removeClickMonitors()
        if let userDefaultsObserver {
            NotificationCenter.default.removeObserver(userDefaultsObserver)
            self.userDefaultsObserver = nil
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            refreshStatusItem(force: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            installClickMonitors()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        removeClickMonitors()
        refreshStatusItem(force: true)
    }

    private func refreshStatusItem(force: Bool = false) {
        guard let button = statusItem?.button else { return }
        if popover.isShown && !force {
            return
        }

        let snapshot = StatusBarSnapshot.build(appStore: appStore)
        if !force, snapshot == lastSnapshot {
            return
        }

        let rendered = imageRenderer.render(snapshot: snapshot)
        button.image = rendered.image
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        let targetWidth = ceil(rendered.size.width)
        if let statusItem, abs(statusItem.length - targetWidth) > 0.5 {
            statusItem.length = targetWidth
        }
        lastSnapshot = snapshot
    }

    private func installClickMonitors() {
        removeClickMonitors()

        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleOutsideClick(event)
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleOutsideClick(event)
            }
        }
    }

    private func removeClickMonitors() {
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
    }

    private func handleOutsideClick(_ event: NSEvent) {
        guard popover.isShown else { return }
        guard let button = statusItem?.button else {
            popover.performClose(nil)
            return
        }

        if let popoverWindow = popover.contentViewController?.view.window,
           event.window === popoverWindow {
            return
        }

        if let eventWindow = event.window {
            let locationInWindow = event.locationInWindow
            let locationInButton = button.convert(locationInWindow, from: nil)
            if button.bounds.contains(locationInButton) {
                return
            }

            if let popoverWindow = popover.contentViewController?.view.window {
                let locationOnScreen = eventWindow.convertPoint(toScreen: locationInWindow)
                if popoverWindow.frame.contains(locationOnScreen) {
                    return
                }
            }
        }

        popover.performClose(nil)
    }
}

@MainActor
private struct StatusBarRenderedImage {
    let image: NSImage
    let size: NSSize
}

@MainActor
private final class StatusBarImageRenderer {
    private let iconSize = NSSize(width: 16, height: 16)
    private let horizontalPadding: CGFloat = 8
    private let spacing: CGFloat = 5
    private let topFont = NSFont.monospacedSystemFont(ofSize: 8, weight: .semibold)
    private let bottomFont = NSFont.monospacedSystemFont(ofSize: 8, weight: .semibold)

    func render(snapshot: StatusBarSnapshot) -> StatusBarRenderedImage {
        let lines = Array(snapshot.lines.prefix(2))
        let topText = lines[safe: 0] ?? ""
        let bottomText = lines[safe: 1] ?? ""
        let hasText = !topText.isEmpty || !bottomText.isEmpty

        let topAttributes: [NSAttributedString.Key: Any] = [.font: topFont, .foregroundColor: NSColor.black]
        let bottomAttributes: [NSAttributedString.Key: Any] = [.font: bottomFont, .foregroundColor: NSColor.black]
        let topSize = (topText as NSString).size(withAttributes: topAttributes)
        let bottomSize = (bottomText as NSString).size(withAttributes: bottomAttributes)
        let textWidth = ceil(max(topSize.width, bottomSize.width))

        let width = max(28, horizontalPadding + iconSize.width + (hasText ? spacing + textWidth : 0) + horizontalPadding)
        let height = NSStatusBar.system.thickness
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        defer { image.unlockFocus() }

        let rect = NSRect(origin: .zero, size: image.size)
        NSColor.clear.set()
        rect.fill()

        let iconOrigin = NSPoint(x: horizontalPadding, y: floor((rect.height - iconSize.height) / 2))
        if let icon = NSImage(named: "MenuBarIcon") {
            let iconRect = NSRect(origin: iconOrigin, size: iconSize)
            icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
        }

        if hasText {
            let textX = horizontalPadding + iconSize.width + spacing
            let topY = floor(rect.midY + 1)
            let bottomY = floor(rect.midY - bottomSize.height - 1)
            (topText as NSString).draw(at: NSPoint(x: textX, y: topY), withAttributes: topAttributes)
            (bottomText as NSString).draw(at: NSPoint(x: textX, y: bottomY), withAttributes: bottomAttributes)
        }

        image.isTemplate = true
        return StatusBarRenderedImage(image: image, size: NSSize(width: width, height: height))
    }
}

@MainActor
private struct StatusBarSnapshot: Equatable {
    let lines: [String]

    static func build(appStore: AppStore) -> StatusBarSnapshot {
        let selected = Set(
            (UserDefaults.standard.string(forKey: "menubar.titleQuotaTools") ?? "")
                .components(separatedBy: ",")
                .filter { !$0.isEmpty }
        )
        let orderRaw = UserDefaults.standard.string(forKey: "menubar.toolOrder") ?? Tool.defaultOrderRaw
        let orderedTools = orderRaw.components(separatedBy: ",").compactMap { Tool(rawValue: $0) }
        let tools = (orderedTools + Tool.allCases.filter { !orderedTools.contains($0) })
            .filter { selected.contains($0.rawValue) && $0.supportsMenuBarFiveHourDisplay }

        let items = tools.map { tool in
            StatusBarQuotaItem.build(tool: tool, appStore: appStore)
        }

        let lines: [String]
        if let item = items.first, items.count == 1 {
            lines = ["5H \(item.fiveHourText)", "7D \(item.sevenDayText)"]
        } else {
            lines = items.map { "\($0.shortLabel) \($0.fiveHourText) \($0.sevenDayText)" }
        }
        return StatusBarSnapshot(lines: lines)
    }
}

@MainActor
private struct StatusBarQuotaItem: Equatable {
    let shortLabel: String
    let fiveHourText: String
    let sevenDayText: String

    static func build(tool: Tool, appStore: AppStore) -> StatusBarQuotaItem {
        switch tool {
        case .codex:
            let account = appStore.syncService?.latestCodexAccounts.first(where: \.isCurrent)
                ?? appStore.syncService?.latestCodexAccounts.first
            let fiveHour = account?.limits?.fiveHourWindow?.usedPercent.map { max(0, 100 - Int($0.rounded())) }
            let sevenDay = account?.limits?.oneWeekWindow?.usedPercent.map { max(0, 100 - Int($0.rounded())) }
            return StatusBarQuotaItem(shortLabel: "CX", fiveHourText: format(fiveHour), sevenDayText: format(sevenDay))
        case .claudeCode:
            let fiveHour = appStore.syncService?.latestClaudeUsage?.fiveHour?.utilization.map { max(0, 100 - Int($0.rounded())) }
            let sevenDay = appStore.syncService?.latestClaudeUsage?.sevenDay?.utilization.map { max(0, 100 - Int($0.rounded())) }
            return StatusBarQuotaItem(shortLabel: "CC", fiveHourText: format(fiveHour), sevenDayText: format(sevenDay))
        case .copilot, .antigravity, .opencode:
            return StatusBarQuotaItem(shortLabel: tool.displayName.prefix(1).uppercased(), fiveHourText: "--", sevenDayText: "--")
        }
    }

    private static func format(_ value: Int?) -> String {
        guard let value else { return " --%" }
        return String(format: "%3d%%", value)
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
