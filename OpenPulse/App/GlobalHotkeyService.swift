import AppKit
import Carbon.HIToolbox

/// Manages the global keyboard shortcut that toggles the OpenPulse menu bar popover.
/// Singleton — call `applyFromDefaults()` once at launch, then use `startRecording()`
/// in Settings to let the user pick a new shortcut.
// Weak reference to the MenuBarExtra window, set by MenuBarWindowCapture on each open.
// nonisolated(unsafe): always written/read on main thread, bypasses actor checks.
nonisolated(unsafe) private var _menuBarWindow: NSWindow?

// NSStatusBarButton captured at launch from MenuBarIcon label view hierarchy.
// Used as a reliable fallback before the popover has ever been opened.
nonisolated(unsafe) private var _statusBarButton: NSStatusBarButton?

@MainActor
@Observable
final class GlobalHotkeyService {
    static let shared = GlobalHotkeyService()

    private(set) var isRecording = false

    private var hotKeyRef: EventHotKeyRef?
    private var recordingMonitor: Any?

    private static let keyCodeKey   = "menubar.hotkey.keyCode"
    private static let modifiersKey = "menubar.hotkey.modifiers"

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind:  UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            Task { @MainActor in GlobalHotkeyService.shared.toggle() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// Called by MenuBarWindowCapture whenever the popover window appears.
    nonisolated func registerMenuBarWindow(_ window: NSWindow) {
        _menuBarWindow = window
    }

    /// Called by MenuBarButtonCapture at launch from the label view's superview chain.
    nonisolated func registerStatusBarButton(_ button: NSStatusBarButton) {
        _statusBarButton = button
    }

    @MainActor private func toggle() {
        if let window = _menuBarWindow {
            if window.isVisible {
                window.orderOut(nil)
            } else {
                NSApp.activate(ignoringOtherApps: true)
                window.orderFront(nil)
            }
            return
        }
        // Fallback before popover has ever been opened.
        // Do NOT call NSApp.activate here — activating the app before performClick
        // can cause the non-activating panel to open then immediately close.
        if let button = _statusBarButton {
            button.performClick(nil)
            return
        }
        // Last resort: KVC (macOS 13–14)
        (NSStatusBar.system.value(forKey: "statusItems") as? [NSStatusItem])?.first?.button?.performClick(nil)
    }

    @MainActor func closeMenuBar() {
        _menuBarWindow?.orderOut(nil)
    }

    // MARK: - Registration

    /// Load saved shortcut from UserDefaults and register it.
    func applyFromDefaults() {
        let kc   = UInt32(UserDefaults.standard.integer(forKey: Self.keyCodeKey))
        let mods = UInt32(UserDefaults.standard.integer(forKey: Self.modifiersKey))
        apply(keyCode: kc, carbonModifiers: mods)
    }

    /// Register `keyCode` + `carbonModifiers` as the global hotkey.
    /// Pass `keyCode == 0` to unregister without setting a new one.
    func apply(keyCode: UInt32, carbonModifiers: UInt32) {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        guard keyCode != 0 else { return }
        let id = EventHotKeyID(signature: openpulseFCC, id: 1)
        RegisterEventHotKey(keyCode, carbonModifiers, id,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    /// Persist + apply a new shortcut.
    func save(keyCode: UInt32, carbonModifiers: UInt32) {
        UserDefaults.standard.set(Int(keyCode),         forKey: Self.keyCodeKey)
        UserDefaults.standard.set(Int(carbonModifiers), forKey: Self.modifiersKey)
        apply(keyCode: keyCode, carbonModifiers: carbonModifiers)
    }

    // MARK: - Interactive recording

    /// Enter recording mode: the next key press with at least one modifier is captured.
    /// Escape cancels. The captured shortcut is saved automatically.
    func startRecording() {
        isRecording = true
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let carbonMods = event.modifierFlags.carbonModifiers
            let kc = UInt32(event.keyCode)
            if event.keyCode == 53 {            // Escape — cancel
                Task { @MainActor [weak self] in self?.stopRecording() }
                return nil
            }
            guard carbonMods != 0 else { return event }
            Task { @MainActor [weak self] in
                self?.save(keyCode: kc, carbonModifiers: carbonMods)
                self?.stopRecording()
            }
            return nil                          // consume the event
        }
    }

    func stopRecording() {
        isRecording = false
        if let m = recordingMonitor { NSEvent.removeMonitor(m); recordingMonitor = nil }
    }

    // MARK: - Display

    static func displayString(keyCode: UInt32, carbonModifiers: UInt32) -> String {
        guard keyCode != 0 else { return "无" }
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        s += keyCodeChar(keyCode)
        return s
    }

    private static func keyCodeChar(_ code: UInt32) -> String {
        let map: [UInt32: String] = [
            0:"A",  1:"S",  2:"D",  3:"F",  4:"H",  5:"G",  6:"Z",  7:"X",
            8:"C",  9:"V",  11:"B", 12:"Q", 13:"W", 14:"E", 15:"R",
            16:"Y", 17:"T", 31:"O", 32:"U", 34:"I", 35:"P",
            37:"L", 38:"J", 40:"K", 45:"N", 46:"M",
            18:"1", 19:"2", 20:"3", 21:"4", 22:"6", 23:"5",
            25:"9", 26:"7", 28:"8", 29:"0",
            49:"Space", 123:"←", 124:"→", 125:"↓", 126:"↑",
            122:"F1", 120:"F2", 99:"F3", 118:"F4", 96:"F5",  97:"F6",
            98:"F7", 100:"F8", 101:"F9", 109:"F10", 103:"F11", 111:"F12",
        ]
        return map[code] ?? "?"
    }
}

extension NSEvent.ModifierFlags {
    /// Convert SwiftUI/AppKit modifier flags to Carbon modifier flags.
    var carbonModifiers: UInt32 {
        var r: UInt32 = 0
        if contains(.command) { r |= UInt32(cmdKey) }
        if contains(.option)  { r |= UInt32(optionKey) }
        if contains(.control) { r |= UInt32(controlKey) }
        if contains(.shift)   { r |= UInt32(shiftKey) }
        return r
    }
}

private let openpulseFCC: FourCharCode =
    "OPLS".unicodeScalars.reduce(0) { ($0 << 8) + FourCharCode($1.value) }
