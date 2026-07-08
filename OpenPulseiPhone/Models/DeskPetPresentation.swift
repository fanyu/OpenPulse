import Foundation
import SwiftUI

enum DeskMotionStyle: Equatable, Sendable {
    case patrol
    case pause
    case alert
    case exhausted
    case waiting
}

struct DeskPetPresentation: Equatable, Sendable {
    let tool: Tool
    let title: String
    let primaryText: String
    let resetText: String
    let fraction: Double?
    let motion: DeskMotionStyle
    let isStale: Bool

    static func make(from snapshot: DeskToolSnapshot, now: Date) -> DeskPetPresentation {
        let resolvedFraction = snapshot.fraction ?? fallbackFraction(
            remaining: snapshot.remaining,
            total: snapshot.total
        )

        return DeskPetPresentation(
            tool: snapshot.tool,
            title: snapshot.displayLabel,
            primaryText: percentText(from: resolvedFraction),
            resetText: resetText(resetAt: snapshot.resetAt, now: now),
            fraction: resolvedFraction,
            motion: motionStyle(for: snapshot.petState),
            isStale: snapshot.status == .stale
        )
    }

    private static func fallbackFraction(remaining: Int?, total: Int?) -> Double? {
        guard let remaining, let total, total > 0 else { return nil }
        return Double(remaining) / Double(total)
    }

    private static func percentText(from fraction: Double?) -> String {
        guard let fraction else { return "--" }
        return "\(Int((fraction * 100).rounded()))%"
    }

    private static func resetText(resetAt: Date?, now _: Date) -> String {
        guard let resetAt else { return "Reset unavailable" }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return "Resets \(formatter.string(from: resetAt))"
    }

    private static func motionStyle(for petState: DeskPetState) -> DeskMotionStyle {
        switch petState {
        case .patrol:
            return .patrol
        case .pause:
            return .pause
        case .alert:
            return .alert
        case .exhausted:
            return .exhausted
        case .waiting:
            return .waiting
        }
    }
}
