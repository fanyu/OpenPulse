import SwiftUI

enum PetMotion {
    static func offset(for style: DeskMotionStyle, phase: CGFloat) -> CGSize {
        switch style {
        case .patrol: .init(width: sin(phase) * 16, height: cos(phase * 2.4) * 5)
        case .pause: .init(width: sin(phase * 0.8) * 4, height: cos(phase * 2.1) * 2.5)
        case .alert: .init(width: sin(phase * 4.6) * 8, height: cos(phase * 6) * 1.5)
        case .exhausted: .init(width: 0, height: 10 + sin(phase * 0.8) * 1.5)
        case .waiting: .init(width: sin(phase * 0.45) * 1.5, height: sin(phase) * 2)
        }
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

    static func limbSwing(for style: DeskMotionStyle, phase: CGFloat, index: Int) -> CGFloat {
        let direction: CGFloat = index.isMultiple(of: 2) ? 1 : -1

        switch style {
        case .patrol:
            return sin(phase * 2.4 + (direction * .pi / 3)) * 14
        case .pause:
            return sin(phase * 1.8 + (direction * .pi / 4)) * 6
        case .alert:
            return sin(phase * 5.2 + CGFloat(index)) * 18
        case .exhausted:
            return direction * -8
        case .waiting:
            return sin(phase * 1.4 + CGFloat(index)) * 4
        }
    }

    static func limbLift(for style: DeskMotionStyle, phase: CGFloat, index: Int) -> CGFloat {
        let stride = max(0, sin(phase * 2.4 + (index.isMultiple(of: 2) ? 0 : .pi)))

        switch style {
        case .patrol:
            return stride * -5
        case .pause:
            return max(0, sin(phase * 1.8 + CGFloat(index))) * -2
        case .alert:
            return max(0, sin(phase * 5 + CGFloat(index))) * -4
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
}
