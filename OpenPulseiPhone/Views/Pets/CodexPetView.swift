import SwiftUI

struct CodexPetView: View {
    let motion: DeskMotionStyle

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
            let phase = PetMotion.phase(at: timeline.date, for: motion)
            let offset = PetMotion.offset(for: motion, phase: phase)
            let squash = PetMotion.squash(for: motion, phase: phase)

            ZStack {
                Ellipse()
                    .fill(Color.black.opacity(0.18))
                    .frame(width: 124, height: 20)
                    .blur(radius: 2)
                    .offset(y: 60)

                ZStack {
                    RoundedRectangle(cornerRadius: 32, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.36, green: 0.80, blue: 0.98),
                                    Color(red: 0.18, green: 0.54, blue: 0.92),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 32, style: .continuous)
                                .strokeBorder(.white.opacity(0.24), lineWidth: 2)
                        }
                        .frame(width: 116, height: 96)

                    HStack(spacing: 54) {
                        Circle()
                            .fill(Color(red: 0.44, green: 0.91, blue: 0.98))
                            .frame(width: 12, height: 12)

                        Circle()
                            .fill(Color(red: 0.44, green: 0.91, blue: 0.98))
                            .frame(width: 12, height: 12)
                    }
                    .offset(y: -38)

                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color(red: 0.09, green: 0.14, blue: 0.22))
                        .frame(width: 76, height: 44)
                        .overlay {
                            HStack(spacing: 14) {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(faceLight)
                                    .frame(width: 10, height: motion == .alert ? 10 : 8)

                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(faceLight)
                                    .frame(width: 10, height: motion == .alert ? 10 : 8)
                            }
                            .opacity(motion == .exhausted ? 0.55 : 1)
                        }
                        .offset(y: -6)

                    HStack(spacing: 44) {
                        leg
                        leg
                    }
                    .offset(y: 56)
                }
                .scaleEffect(x: 1.0, y: squash, anchor: .bottom)
                .rotationEffect(PetMotion.rotation(for: motion, phase: phase))
                .offset(offset)
                .shadow(color: faceLight.opacity(motion == .alert ? 0.45 : 0.22), radius: motion == .alert ? 22 : 12)
                .opacity(motion == .waiting ? 0.9 : 1)
            }
            .frame(width: 180, height: 160)
        }
    }

    private var faceLight: Color {
        motion == .exhausted
            ? Color(red: 0.37, green: 0.65, blue: 0.72)
            : Color(red: 0.52, green: 0.95, blue: 0.99)
    }

    private var leg: some View {
        Capsule()
            .fill(Color(red: 0.14, green: 0.39, blue: 0.74))
            .frame(width: 14, height: 22)
    }
}
