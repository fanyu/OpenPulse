import SwiftUI

struct TwinCockpitView: View {
    let codex: DeskPetPresentation
    let claude: DeskPetPresentation
    let statusText: String

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 16) {
                ToolCockpitPanel(presentation: codex)
                ToolCockpitPanel(presentation: claude)
            }
            .padding(24)
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.08, green: 0.11, blue: 0.18), Color(red: 0.15, green: 0.11, blue: 0.16)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(alignment: .top) {
                Text(statusText)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(.top, 10)
            }
        }
    }
}
