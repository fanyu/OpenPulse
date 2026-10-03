import SwiftUI

@main
struct OpenPulseiPhoneApp: App {
    /// Hosted fixtures must not start the app UI's real cloud transports or timers.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    @State private var appStore = DeskModeAppStore()

    var body: some Scene {
        WindowGroup {
            DeskModeRootView()
                .environment(appStore)
        }
    }
}
