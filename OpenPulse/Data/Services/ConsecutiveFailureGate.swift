import Foundation

/// Prevents transient network/file errors from immediately clearing UI data.
///
/// A provider keeps showing its last-known data until `surfaceThreshold` consecutive
/// failures have accumulated. On the first failure after a long clean run the gate is
/// "silent" — the error is suppressed and the stale snapshot stays visible. Once the
/// failure streak crosses the threshold the error is surfaced and the snapshot cleared.
///
/// The gate resets to zero on the next successful fetch.
final class ConsecutiveFailureGate {
    // Number of consecutive failures required before the error is surfaced to the UI.
    private let surfaceThreshold: Int
    private var failureStreak: Int = 0

    init(surfaceThreshold: Int = 3) {
        self.surfaceThreshold = surfaceThreshold
    }

    /// Call after a successful fetch. Resets the streak.
    func recordSuccess() {
        failureStreak = 0
    }

    /// Call after a failed fetch.
    /// - Parameters:
    ///   - onFailureWithPriorData: Pass `true` when the store already holds a snapshot for
    ///     this provider. When `false` (first-ever fetch) errors are always surfaced immediately.
    /// - Returns: `true` when the error should be shown in the UI and the snapshot cleared.
    func shouldSurfaceError(onFailureWithPriorData hasPriorData: Bool) -> Bool {
        failureStreak += 1
        // No prior data → surface immediately so the UI doesn't look stuck loading.
        guard hasPriorData else { return true }
        return failureStreak >= surfaceThreshold
    }

    /// Resets streak without recording an explicit success (e.g. when a provider is disabled).
    func reset() {
        failureStreak = 0
    }

    var currentStreak: Int { failureStreak }
}
