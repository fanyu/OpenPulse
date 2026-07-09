import SwiftUI

enum PetMotion {
    static func offset(for style: DeskMotionStyle, phase: CGFloat) -> CGSize {
        switch style {
        case .patrol: .init(width: sin(phase) * 18, height: cos(phase * 2) * 4)
        case .pause: .init(width: sin(phase) * 6, height: cos(phase * 2) * 3)
        case .alert: .init(width: sin(phase * 4) * 10, height: 0)
        case .exhausted: .init(width: 0, height: 10)
        case .waiting: .init(width: 0, height: sin(phase) * 2)
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
            return 1 + (cos(phase * 2) * 0.03)
        case .pause:
            return 1 + (cos(phase * 2) * 0.02)
        case .alert:
            return 1 + (sin(phase * 4) * 0.04)
        case .exhausted:
            return 0.96
        case .waiting:
            return 1 + (sin(phase) * 0.015)
        }
    }

    static func rotation(for style: DeskMotionStyle, phase: CGFloat) -> Angle {
        let degrees: CGFloat

        switch style {
        case .patrol:
            degrees = sin(phase) * 4
        case .pause:
            degrees = sin(phase) * 2
        case .alert:
            degrees = sin(phase * 4) * 6
        case .exhausted:
            degrees = -4
        case .waiting:
            degrees = sin(phase) * 1.5
        }

        return .degrees(Double(degrees))
    }
}
