import SwiftUI

struct ClaudePetView: View {
    let motion: DeskMotionStyle

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
            let phase = PetMotion.phase(at: timeline.date, for: motion)
            let movement = PetMotion.movement(for: motion, phase: phase)
            let squash = PetMotion.squash(for: motion, phase: phase)
            let blink = PetMotion.blinkScale(for: motion, phase: phase)
            let pupilOffset = PetMotion.pupilOffset(for: motion, phase: phase)

            ZStack {
                Ellipse()
                    .fill(Color.black.opacity(0.16))
                    .frame(width: 132, height: 18)
                    .blur(radius: 2)
                    .scaleEffect(x: movement.shadowScaleX, y: 1, anchor: .center)
                    .offset(x: movement.offset.width, y: 56)

                ZStack {
                    HStack(spacing: 70) {
                        claw(direction: -1, phase: phase, index: 0, strideScale: movement.stride)
                        claw(direction: 1, phase: phase, index: 1, strideScale: movement.stride)
                    }
                    .offset(y: -6)

                    bodyShell

                    HStack(spacing: 18) {
                        eye(blink: blink, pupilOffset: pupilOffset)
                        eye(blink: blink, pupilOffset: pupilOffset)
                    }
                    .offset(y: -14)

                    HStack(spacing: 14) {
                        ForEach(0..<4, id: \.self) { index in
                            leg(index: index, phase: phase, strideScale: movement.stride)
                        }
                    }
                    .offset(y: 40)
                }
                .scaleEffect(x: movement.facingScaleX, y: squash, anchor: .center)
                .rotationEffect(PetMotion.rotation(for: motion, phase: phase))
                .offset(movement.offset)
                .shadow(color: Color(red: 0.93, green: 0.49, blue: 0.26).opacity(motion == .alert ? 0.35 : 0.2), radius: motion == .alert ? 20 : 10)
                .opacity(motion == .waiting ? 0.92 : 1)
            }
            .frame(width: 180, height: 160)
        }
    }

    private var bodyShell: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.98, green: 0.66, blue: 0.31),
                        Color(red: 0.91, green: 0.42, blue: 0.16),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 2)
            }
            .frame(width: 110, height: 78)
    }

    private func eye(blink: CGFloat, pupilOffset: CGSize) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(.white)
                .frame(width: 18, height: motion == .exhausted ? 14 : 18)
                .scaleEffect(y: blink, anchor: .center)

            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color(red: 0.25, green: 0.14, blue: 0.08))
                .frame(width: 6, height: motion == .alert ? 9 : 7)
                .offset(pupilOffset)
        }
    }

    private func claw(direction: CGFloat, phase: CGFloat, index: Int, strideScale: CGFloat) -> some View {
        VStack(spacing: 2) {
            Capsule()
                .fill(Color(red: 0.98, green: 0.66, blue: 0.31))
                .frame(width: 12, height: 26)
                .rotationEffect(.degrees(Double(PetMotion.limbSwing(for: motion, phase: phase, index: index, strideScale: strideScale) * direction * 0.35)))

            HStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(red: 0.91, green: 0.42, blue: 0.16))
                    .frame(width: 18, height: 10)
                    .rotationEffect(.degrees(Double(direction * -18)))

                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(red: 0.91, green: 0.42, blue: 0.16))
                    .frame(width: 18, height: 10)
                    .rotationEffect(.degrees(Double(direction * 18)))
            }
        }
        .offset(y: PetMotion.limbLift(for: motion, phase: phase, index: index, strideScale: strideScale) * 0.5)
    }

    private func leg(index: Int, phase: CGFloat, strideScale: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color(red: 0.77, green: 0.31, blue: 0.13))
            .frame(width: 10, height: 24)
            .rotationEffect(.degrees((index.isMultiple(of: 2) ? -18 : 18) + Double(PetMotion.limbSwing(for: motion, phase: phase, index: index, strideScale: strideScale) * 0.45)))
            .offset(y: PetMotion.limbLift(for: motion, phase: phase, index: index, strideScale: strideScale))
    }
}
