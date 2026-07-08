import Foundation

enum DeskQuotaStatus: String, Codable, Sendable {
    case healthy
    case warning
    case critical
    case exhausted
    case stale

    static func resolve(remaining: Int?, total: Int?, updatedAt: Date, now: Date) -> DeskQuotaStatus {
        if now.timeIntervalSince(updatedAt) > 600 {
            return .stale
        }
        if let remaining, remaining == 0 {
            return .exhausted
        }
        guard let remaining, let total, total > 0 else {
            return .warning
        }
        let fraction = Double(remaining) / Double(total)
        if fraction >= 0.5 {
            return .healthy
        }
        if fraction >= 0.2 {
            return .warning
        }
        return .critical
    }
}

enum DeskPetState: String, Codable, Sendable {
    case patrol
    case pause
    case alert
    case exhausted
    case waiting
}
