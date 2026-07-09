import SwiftUI

struct DeskModeRootView: View {
    @Environment(DeskModeAppStore.self) private var appStore

    var body: some View {
        Group {
            if let codex = appStore.codexPresentation,
               let claude = appStore.claudePresentation {
                TwinCockpitView(
                    codex: codex,
                    claude: claude,
                    statusText: appStore.statusText
                )
            } else {
                ZStack {
                    LinearGradient(
                        colors: [
                            Color(red: 0.08, green: 0.11, blue: 0.18),
                            Color(red: 0.15, green: 0.11, blue: 0.16),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .ignoresSafeArea()

                    VStack(spacing: 14) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white.opacity(0.85))

                        Text(appStore.statusText)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)

                        Text("Twin cockpit will appear once the Mac snapshot arrives.")
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    .padding(24)
                }
            }
        }
        .task {
            appStore.tick()

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                appStore.tick()
            }
        }
    }
}
