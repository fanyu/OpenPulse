import SwiftUI

@main
struct OpenPulseiPhoneApp: App {
    @State private var appStore = DeskModeAppStore()

    var body: some Scene {
        WindowGroup {
            DeskModeRootView()
                .environment(appStore)
                .task { await appStore.refresh() }
        }
    }
}
