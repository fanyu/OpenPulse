import SwiftUI

struct ToolCockpitPanel: View {
    let presentation: DeskPetPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(presentation.title)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    //.fill(.white.opacity(0.06))

                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    petStage
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 174)

            VStack(spacing: 8) {
                usageRow(presentation.session)
                usageRow(presentation.weekly)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(brandTint.opacity(0.04))
        .glassEffect(.regular, in: .rect(cornerRadius: 32))
        .overlay {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1.5)
        }
    }

    @ViewBuilder
    private func usageRow(_ usage: DeskUsagePresentation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(usage.label)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))

                Spacer()

                Text(usage.resetText)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .lineLimit(1)

                Text(usage.percentText)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(usage.isAvailable ? .white : .white.opacity(0.55))
                    .monospacedDigit()
            }

            GeometryReader { proxy in
                let usageAccent = accent(for: usage)

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.1))

                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [usageAccent.opacity(0.72), usageAccent],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: proxy.size.width * CGFloat(max(0, min(usage.fraction ?? 0, 1))))
                }
            }
            .frame(height: 8)
        }
    }

    private var brandTint: Color {
        switch presentation.tool {
        case .codex:
            return Color(red: 0.26, green: 0.63, blue: 0.96)
        case .claudeCode:
            return Color(red: 0.93, green: 0.49, blue: 0.26)
        case .copilot:
            return Color(red: 0.29, green: 0.59, blue: 0.98)
        case .antigravity:
            return Color(red: 0.67, green: 0.46, blue: 0.96)
        }
    }

    private var accent: Color {
        switch presentation.status {
        case .healthy:
            return brandTint
        case .warning:
            return Color(red: 0.95, green: 0.72, blue: 0.24)
        case .critical:
            return Color(red: 0.98, green: 0.39, blue: 0.31)
        case .exhausted:
            return Color(red: 0.68, green: 0.30, blue: 0.29)
        case .stale:
            return Color(red: 0.50, green: 0.54, blue: 0.62)
        }
    }

    private func accent(for usage: DeskUsagePresentation) -> Color {
        guard usage.isAvailable, let fraction = usage.fraction else {
            return Color(red: 0.50, green: 0.54, blue: 0.62)
        }
        if fraction <= 0 {
            return Color(red: 0.68, green: 0.30, blue: 0.29)
        }
        if fraction < 0.2 {
            return Color(red: 0.98, green: 0.39, blue: 0.31)
        }
        if fraction < 0.4 {
            return Color(red: 0.95, green: 0.72, blue: 0.24)
        }
        return brandTint
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

    @ViewBuilder
    private var petStage: some View {
        ZStack {
            Circle()
                .fill(accent.opacity(0.14))
                .frame(width: 124, height: 124)
                .blur(radius: 10)

            switch presentation.tool {
            case .codex:
                CodexPetView(motion: presentation.motion)
                    .scaleEffect(0.74)
            case .claudeCode:
                ClaudePetView(motion: presentation.motion)
                    .scaleEffect(0.74)
            case .copilot, .antigravity:
                Circle()
                    .fill(brandTint.opacity(0.9))
                    .frame(width: 96, height: 96)
                    .overlay {
                        Text(symbol)
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
            }
        }
        .overlay(alignment: .topTrailing) {
            quotaBubble
        }
    }

    private var quotaBubble: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
            let phase = PetMotion.phase(at: timeline.date, for: presentation.motion)

            VStack(alignment: .trailing, spacing: 1) {
                Text(presentation.session.percentText)
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()

                Text(bubbleLabel)
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .tracking(0.9)
                    .textCase(.uppercase)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.1), lineWidth: 1)
            }
            .shadow(color: accent.opacity(0.22), radius: 14, y: 6)
            .offset(x: sin(phase * 0.9) * 1.5, y: cos(phase * 1.2) * 2)
            .scaleEffect(1 + (sin(phase * 1.6) * 0.02))
            //.glassEffect(.regular, in: .rect(cornerRadius: 14))
        }
    }

    private var bubbleLabel: String {
        switch presentation.status {
        case .healthy:
            return "5h left"
        case .warning:
            return "watch 5h"
        case .critical:
            return "low 5h"
        case .exhausted:
            return "reset soon"
        case .stale:
            return "sync stale"
        }
    }

}
