import SwiftUI

struct ToolCockpitPanel: View {
    let presentation: DeskPetPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(presentation.title)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text(presentation.resetText)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                }

                Spacer(minLength: 12)

                Text(presentation.primaryText)
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
            }

            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.white.opacity(0.06))

                VStack(spacing: 12) {
                    Circle()
                        .fill(tint.opacity(0.9))
                        .frame(width: 96, height: 96)
                        .overlay {
                            Text(symbol)
                                .font(.system(size: 36, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                        }

                    Text(motionLabel)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.78))
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                Capsule()
                    .fill(tint)
                    .frame(width: 10, height: 10)

                Text(presentation.isStale ? "Snapshot stale" : "Snapshot live")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.78))

                Spacer()
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(.black.opacity(0.18))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        }
    }

    private var tint: Color {
        switch presentation.tool {
        case .codex:
            return Color(red: 0.21, green: 0.79, blue: 0.58)
        case .claudeCode:
            return Color(red: 0.93, green: 0.49, blue: 0.26)
        case .copilot:
            return Color(red: 0.29, green: 0.59, blue: 0.98)
        case .antigravity:
            return Color(red: 0.67, green: 0.46, blue: 0.96)
        }
    }

    private var symbol: String {
        switch presentation.tool {
        case .codex:
            return "C"
        case .claudeCode:
            return "A"
        case .copilot:
            return "G"
        case .antigravity:
            return "O"
        }
    }

    private var motionLabel: String {
        switch presentation.motion {
        case .patrol:
            return "Patrol"
        case .pause:
            return "Pause"
        case .alert:
            return "Alert"
        case .exhausted:
            return "Exhausted"
        case .waiting:
            return "Waiting"
        }
    }
}
