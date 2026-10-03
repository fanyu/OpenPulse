import SwiftUI

/// Clamp display values consistently; a missing or invalid balance stays unknown.
func agQuotaDisplayFraction(for window: AGWindow?) -> Double? {
    guard let fraction = window?.remainingFraction, fraction.isFinite else { return nil }
    return min(1, max(0, fraction))
}

struct AGTierBadge: View {
    let account: AGAccountQuota

    var body: some View {
        Text(account.badgeLabel)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }
}

struct AGWindowRow: View {
    @Environment(\.locale) private var locale
    let title: LocalizedStringResource
    let window: AGWindow?
    var isBlockedByWeeklyLimit = false

    private var localizedTitle: String {
        var resource = title
        resource.locale = locale
        return String(localized: resource)
    }

    var body: some View {
        let fraction = agQuotaDisplayFraction(for: window)
        let primaryValue = fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
        let usedPercent = fraction.map { Int(((1 - $0) * 100).rounded()) }
        UnifiedQuotaRow(
            title: localizedTitle,
            fraction: fraction,
            primaryValue: primaryValue,
            secondaryValue: isBlockedByWeeklyLimit
                ? String(localized: "本周额度已耗尽", locale: locale)
                : usedPercent.map { String(localized: "已用 \($0.formatted(.number.locale(locale)))%", locale: locale) },
            countdown: window?.resetCountdown
        )
        .help(window?.description ?? "")
    }
}

struct AGGroupCard: View {
    let group: AGQuotaGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(group.displayName).font(.system(size: 12, weight: .semibold))
            AGWindowRow(
                title: "5小时余量",
                window: group.fiveHour,
                isBlockedByWeeklyLimit: agQuotaDisplayFraction(for: group.weekly).map { $0 <= 0.001 } ?? false
            )
            AGWindowRow(title: "本周余量", window: group.weekly)
        }
        .padding(.vertical, 8)
    }
}

struct AGAccountQuotaBody: View {
    let account: AGAccountQuota

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text(account.email)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                AGTierBadge(account: account)
                Spacer()
            }
            if account.groups.isEmpty {
                Text("尚未获取额度")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(account.groups) { group in
                    AGGroupCard(group: group)
                }
            }
        }
    }
}
