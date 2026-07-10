import SwiftUI

struct TwinCockpitView: View {
    let codex: DeskPetPresentation
    let claude: DeskPetPresentation
    let statusText: String

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                syncBanner
                    .padding(.top, 10)
                    .padding(.bottom, 18)

                HStack(spacing: 16) {
                    ToolCockpitPanel(presentation: codex)
                    ToolCockpitPanel(presentation: claude)
                }
                .frame(maxWidth: 1_240)
                .frame(height: min(max(proxy.size.height - 108, 340), 448))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 8)
                .padding(.bottom, 14)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.08, green: 0.11, blue: 0.18),
                        Color(red: 0.15, green: 0.11, blue: 0.16),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
    }

    private var syncBanner: some View {
        HStack(spacing: 10) {
            OpenPulseBrandView(compact: true)

            Rectangle()
                .fill(.white.opacity(0.12))
                .frame(width: 1, height: 12)

            Text(statusText)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .monospaced()
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.black.opacity(0.18), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        }
    }
}
