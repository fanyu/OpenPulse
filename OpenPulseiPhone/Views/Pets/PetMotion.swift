import SwiftUI

struct PetMovement: Equatable {
    let offset: CGSize
    let facingScaleX: CGFloat
    let stride: CGFloat
    let shadowScaleX: CGFloat
}

enum PetMotion {
    static func movement(for style: DeskMotionStyle, phase: CGFloat) -> PetMovement {
        switch style {
        case .patrol:
            patrolMovement(phase: phase, range: 48, pauseFraction: 0.12, bobAmplitude: 3)
        case .pause:
            patrolMovement(phase: phase, range: 28, pauseFraction: 0.16, bobAmplitude: 2)
        case .alert:
            patrolMovement(phase: phase, range: 34, pauseFraction: 0.06, bobAmplitude: 2.5, jitter: 1.5)
        case .exhausted:
            .init(
                offset: .init(width: 0, height: 10 + sin(phase * 0.8) * 1.5),
                facingScaleX: 1,
                stride: 0,
                shadowScaleX: 1
            )
        case .waiting:
            .init(
                offset: .init(width: sin(phase * 0.45) * 1.5, height: sin(phase) * 2),
                facingScaleX: 1,
                stride: 0,
                shadowScaleX: 1
            )
        }
    }

    static func offset(for style: DeskMotionStyle, phase: CGFloat) -> CGSize {
        movement(for: style, phase: phase).offset
    }

    static func phase(at date: Date, for style: DeskMotionStyle) -> CGFloat {
        let time = date.timeIntervalSinceReferenceDate
        let speed: Double

        switch style {
        case .patrol:
            speed = 1.2
        case .pause:
            speed = 0.8
        case .alert:
            speed = 2.8
        case .exhausted:
            speed = 0.25
        case .waiting:
            speed = 0.55
        }

        return CGFloat(time * speed)
    }

    static func squash(for style: DeskMotionStyle, phase: CGFloat) -> CGFloat {
        switch style {
        case .patrol:
            return 1 + (cos(phase * 2.4) * 0.035)
        case .pause:
            return 1 + (cos(phase * 2) * 0.018)
        case .alert:
            return 1 + (sin(phase * 4.8) * 0.045)
        case .exhausted:
            return 0.95 + (sin(phase * 0.6) * 0.01)
        case .waiting:
            return 1 + (sin(phase * 1.2) * 0.012)
        }
    }

    static func rotation(for style: DeskMotionStyle, phase: CGFloat) -> Angle {
        let degrees: CGFloat

        switch style {
        case .patrol:
            degrees = sin(phase * 1.1) * 5
        case .pause:
            degrees = sin(phase) * 2
        case .alert:
            degrees = sin(phase * 4.4) * 8
        case .exhausted:
            degrees = -5 + sin(phase * 0.6)
        case .waiting:
            degrees = sin(phase) * 1.5
        }

        return .degrees(Double(degrees))
    }

    static func limbSwing(for style: DeskMotionStyle, phase: CGFloat, index: Int, strideScale: CGFloat = 1) -> CGFloat {
        let direction: CGFloat = index.isMultiple(of: 2) ? 1 : -1

        switch style {
        case .patrol:
            return sin(phase * 2.4 + (direction * .pi / 3)) * 14 * strideScale
        case .pause:
            return sin(phase * 1.8 + (direction * .pi / 4)) * 6 * strideScale
        case .alert:
            return sin(phase * 5.2 + CGFloat(index)) * 18 * strideScale
        case .exhausted:
            return direction * -8
        case .waiting:
            return sin(phase * 1.4 + CGFloat(index)) * 4
        }
    }

    static func limbLift(for style: DeskMotionStyle, phase: CGFloat, index: Int, strideScale: CGFloat = 1) -> CGFloat {
        let stepLift = max(0, sin(phase * 2.4 + (index.isMultiple(of: 2) ? 0 : .pi)))

        switch style {
        case .patrol:
            return stepLift * -5 * strideScale
        case .pause:
            return max(0, sin(phase * 1.8 + CGFloat(index))) * -2 * strideScale
        case .alert:
            return max(0, sin(phase * 5 + CGFloat(index))) * -4 * strideScale
        case .exhausted:
            return 3
        case .waiting:
            return max(0, sin(phase * 1.2 + CGFloat(index))) * -1.5
        }
    }

    static func blinkScale(for style: DeskMotionStyle, phase: CGFloat) -> CGFloat {
        let blink = abs(sin(phase * 0.55))

        switch style {
        case .patrol, .pause, .waiting:
            return blink > 0.985 ? 0.22 : 1
        case .alert:
            return 1
        case .exhausted:
            return 0.58
        }
    }

    static func pupilOffset(for style: DeskMotionStyle, phase: CGFloat) -> CGSize {
        switch style {
        case .patrol:
            return .init(width: sin(phase * 0.8) * 1.5, height: 0)
        case .pause:
            return .init(width: 0, height: sin(phase * 0.6) * 0.5)
        case .alert:
            return .init(width: sin(phase * 3.6) * 2.5, height: 0)
        case .exhausted:
            return .init(width: 0, height: 1)
        case .waiting:
            return .zero
        }
    }

    private static func patrolMovement(
        phase: CGFloat,
        range: CGFloat,
        pauseFraction: CGFloat,
        bobAmplitude: CGFloat,
        jitter: CGFloat = 0
    ) -> PetMovement {
        let fullCycle = 2 * CGFloat.pi
        let cycle = (phase / fullCycle).truncatingRemainder(dividingBy: 1)
        let walkingDuration = 0.5 - pauseFraction
        let position: CGFloat
        let facingScaleX: CGFloat
        let stride: CGFloat

        switch cycle {
        case ..<pauseFraction:
            position = -range
            facingScaleX = 1
            stride = 0
        case ..<(0.5 - pauseFraction):
            let progress = (cycle - pauseFraction) / walkingDuration
            position = -range + (2 * range * eased(progress))
            facingScaleX = 1
            stride = 1
        case ..<(0.5 + pauseFraction):
            position = range
            facingScaleX = -1
            stride = 0
        default:
            let progress = (cycle - 0.5 - pauseFraction) / walkingDuration
            position = range - (2 * range * eased(progress))
            facingScaleX = -1
            stride = 1
        }

        let bob = abs(sin(phase * 3.2)) * bobAmplitude * stride
        let shake = sin(phase * 7) * jitter * stride
        let shadowScaleX = 1 - (abs(sin(phase * 3.2)) * 0.14 * stride)
        return .init(
            offset: .init(width: position + shake, height: -bob),
            facingScaleX: facingScaleX,
            stride: stride,
            shadowScaleX: shadowScaleX
        )
    }

    private static func eased(_ progress: CGFloat) -> CGFloat {
        0.5 - (cos(progress * .pi) * 0.5)
    }
}
