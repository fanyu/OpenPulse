import SwiftUI
import AppKit

@MainActor
final class WindowCoordinator {
    static let shared = WindowCoordinator()

    private var openWindowHandler: ((String) -> Void)?
    private weak var mainWindow: NSWindow?
    private let mainWindowDelegate = MainWindowLifecycleDelegate()

    private init() {}

    func registerOpenWindowHandler(_ handler: @escaping (String) -> Void) {
        openWindowHandler = handler
    }

    func registerMainWindow(_ window: NSWindow) {
        window.delegate = mainWindowDelegate
        window.isReleasedWhenClosed = false
        mainWindow = window
    }

    func showMainWindow(select tab: AppTab? = nil) {
        if let tab {
            AppStore.shared.selectedTab = tab
        }
        NSApp.activate(ignoringOtherApps: true)
        if let mainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
            mainWindow.orderFrontRegardless()
            return
        }
        openWindowHandler?("main")
    }
}

@MainActor
private final class MainWindowLifecycleDelegate: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

struct OpenWindowActionCapture: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                WindowCoordinator.shared.registerOpenWindowHandler { id in
                    openWindow(id: id)
                }
            }
    }
}

struct MainWindowCapture: NSViewRepresentable {
    func makeNSView(context: Context) -> _MainWindowCaptureView { _MainWindowCaptureView() }
    func updateNSView(_ nsView: _MainWindowCaptureView, context: Context) {}
}

final class _MainWindowCaptureView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        Task { @MainActor in
            WindowCoordinator.shared.registerMainWindow(window)
        }
    }
}
