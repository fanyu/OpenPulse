import Foundation
import SwiftUI

enum DeskMotionStyle: Equatable, Sendable {
    case patrol
    case pause
    case alert
    case exhausted
    case waiting
}

struct DeskUsagePresentation: Equatable, Sendable {
    let label: String
    let percentText: String
    let resetText: String
    let fraction: Double?
    let isAvailable: Bool
}

struct DeskPetPresentation: Equatable, Sendable {
    let tool: Tool
    let title: String
    let session: DeskUsagePresentation
    let weekly: DeskUsagePresentation
    let status: DeskQuotaStatus
    let motion: DeskMotionStyle
    let isStale: Bool

    static func make(from snapshot: DeskToolSnapshot, now: Date) -> DeskPetPresentation {
        return DeskPetPresentation(
            tool: snapshot.tool,
            title: snapshot.displayLabel,
            session: usagePresentation(from: snapshot.session, fallbackLabel: "5h Session", now: now),
            weekly: usagePresentation(from: snapshot.weekly, fallbackLabel: "7d Weekly", now: now),
            status: snapshot.status,
            motion: motionStyle(for: snapshot.petState),
            isStale: snapshot.status == .stale
        )
    }

    private static func usagePresentation(
        from window: DeskQuotaWindowSnapshot?,
        fallbackLabel: String,
        now: Date
    ) -> DeskUsagePresentation {
        let resolvedFraction: Double? = if let window {
            window.fraction ?? fallbackFraction(remaining: window.remaining, total: window.total)
        } else {
            nil
        }

        return DeskUsagePresentation(
            label: displayLabel(window?.label ?? fallbackLabel),
            percentText: percentText(from: resolvedFraction),
            resetText: resetText(resetAt: window?.resetAt, now: now),
            fraction: resolvedFraction,
            isAvailable: resolvedFraction != nil
        )
    }

    private static func fallbackFraction(remaining: Int?, total: Int?) -> Double? {
        guard let remaining, let total, total > 0 else { return nil }
        return Double(remaining) / Double(total)
    }

    private static func percentText(from fraction: Double?) -> String {
        guard let fraction else { return "--%" }
        return "\(Int((fraction * 100).rounded()))%"
    }

    private static func resetText(resetAt: Date?, now: Date) -> String {
        guard let resetAt else { return "Reset unavailable" }
        if Calendar.current.isDate(resetAt, inSameDayAs: now) {
            return "Today \(timeFormatter.string(from: resetAt))"
        }
        return dateTimeFormatter.string(from: resetAt)
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

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter
    }()

    private static func displayLabel(_ label: String) -> String {
        switch label.lowercased() {
        case "5h session":
            return "5h limit"
        case "7d weekly":
            return "7d limit"
        default:
            return label
        }
    }
}
