import SwiftUI

/// Clamp display values consistently; a missing or invalid balance stays unknown.
func agQuotaDisplayFraction(for window: AGWindow?) -> Double? {
    guard let fraction = window?.remainingFraction, fraction.isFinite else { return nil }
    return min(1, max(0, fraction))
}

struct AGTierBadge: View {
    let account: AGAccountQuota

    var body: some View {
        SubscriptionTag(text: account.badgeLabel, isPaid: account.isPaid)
    }
}
