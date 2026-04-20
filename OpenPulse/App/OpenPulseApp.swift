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
    private var statusContentView: StatusBarContentView?
    private let popover = NSPopover()
    private var refreshTimer: Timer?
    private var userDefaultsObserver: NSObjectProtocol?

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
            button.imagePosition = .imageLeading
            let contentView = StatusBarContentView()
            contentView.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(contentView)
            NSLayoutConstraint.activate([
                contentView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                contentView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                contentView.topAnchor.constraint(equalTo: button.topAnchor),
                contentView.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
            statusContentView = contentView
            GlobalHotkeyService.shared.registerStatusBarButton(button)
        }

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
            Task { @MainActor [weak self] in
                self?.refreshStatusItem()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
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
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            if let window = popover.contentViewController?.view.window {
                GlobalHotkeyService.shared.registerMenuBarWindow(window)
            }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        refreshStatusItem()
    }

    private func refreshStatusItem() {
        guard let button = statusItem?.button, let statusContentView else { return }
        let snapshot = StatusBarSnapshot.build(appStore: appStore)
        statusContentView.apply(snapshot: snapshot)
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        statusItem?.length = statusContentView.fittingSize.width
        button.needsLayout = true
    }
}

@MainActor
private final class StatusBarContentView: NSView {
    private let iconView = NSImageView()
    private let topLabel = NSTextField(labelWithString: "")
    private let bottomLabel = NSTextField(labelWithString: "")
    private let textStack = NSStackView()
    private let rootStack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override var intrinsicContentSize: NSSize {
        let hasText = !topLabel.stringValue.isEmpty || !bottomLabel.stringValue.isEmpty
        let textWidth = max(
            topLabel.attributedStringValue.size().width,
            bottomLabel.attributedStringValue.size().width
        )
        let iconWidth: CGFloat = 16
        let spacing: CGFloat = hasText ? 5 : 0
        let width = 8 + iconWidth + spacing + (hasText ? ceil(textWidth) : 0) + 8
        return NSSize(width: max(28, width), height: NSStatusBar.system.thickness)
    }

    func apply(snapshot: StatusBarSnapshot) {
        let lines = snapshot.lines.prefix(2)
        let topText = lines[safe: 0] ?? ""
        let bottomText = lines[safe: 1] ?? ""
        topLabel.attributedStringValue = lineString(topText)
        bottomLabel.attributedStringValue = lineString(bottomText)
        let tintColor = NSColor.labelColor
        topLabel.textColor = tintColor
        bottomLabel.textColor = tintColor
        textStack.isHidden = topText.isEmpty && bottomText.isEmpty

        if let symbolImage = NSImage(systemSymbolName: "aqi.medium.gauge.open", accessibilityDescription: "OpenPulse") {
            let iconPointSize = min(14, NSStatusBar.system.thickness - 6)
            iconView.image = symbolImage.withSymbolConfiguration(.init(pointSize: iconPointSize, weight: .medium))
            iconView.contentTintColor = tintColor
        } else {
            iconView.image = nil
        }

        invalidateIntrinsicContentSize()
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        configureLabel(topLabel)
        configureLabel(bottomLabel)

        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = -2
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.addArrangedSubview(topLabel)
        textStack.addArrangedSubview(bottomLabel)

        rootStack.orientation = .horizontal
        rootStack.alignment = .centerY
        rootStack.spacing = 5
        rootStack.edgeInsets = NSEdgeInsets(top: 1, left: 8, bottom: 1, right: 8)
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.addArrangedSubview(iconView)
        rootStack.addArrangedSubview(textStack)

        addSubview(rootStack)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: NSStatusBar.system.thickness),
        ])
    }

    private func configureLabel(_ label: NSTextField) {
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isBezeled = false
        label.isBordered = false
        label.drawsBackground = false
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        label.font = NSFont.monospacedSystemFont(ofSize: 8, weight: .semibold)
        label.alignment = .left
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)
    }

    private func lineString(_ text: String) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 8, weight: .semibold),
            ]
        )
    }
}

@MainActor
private struct StatusBarSnapshot {
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
private struct StatusBarQuotaItem {
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
