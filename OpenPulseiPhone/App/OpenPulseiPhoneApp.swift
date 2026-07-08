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

private struct DeskModeRootView: View {
    @Environment(DeskModeAppStore.self) private var appStore

    var body: some View {
        VStack(spacing: 12) {
            Text(appStore.statusText)
                .font(.headline)

            if let snapshot = appStore.snapshot {
                Text(snapshot.updatedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
