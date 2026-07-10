import SwiftUI

struct OpenPulseBrandView: View {
    let compact: Bool

    init(compact: Bool = false) {
        self.compact = compact
    }

    var body: some View {
        HStack(spacing: compact ? 10 : 12) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.23, green: 0.68, blue: 0.95),
                                Color(red: 0.36, green: 0.96, blue: 0.72),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: compact ? 8 : 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.95))
            }
            .frame(width: compact ? 16 : 22, height: compact ? 16 : 22)
            .shadow(color: Color(red: 0.22, green: 0.83, blue: 0.84).opacity(0.28), radius: compact ? 6 : 10, y: 3)

            Text("OpenPulse")
                .font(.system(size: compact ? 12 : 22, weight: .heavy, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
        }
    }
}
