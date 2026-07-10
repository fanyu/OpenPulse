import SwiftUI

struct AGTierBadge: View {
    let account: AGAccountQuota
    var body: some View {
        Text(account.badgeLabel)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(account.isPaid ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.08),
                        in: Capsule())
            .foregroundStyle(account.isPaid ? Color.accentColor : .secondary)
    }
}

struct AGWindowRow: View {
    let title: String
    let window: AGWindow?
    
    var body: some View {
        let usedPercent = window?.remainingFraction.map { Int(round((1.0 - $0) * 100)) }
        UnifiedQuotaRow(
            title: NSLocalizedString(title, comment: ""),
            fraction: window?.remainingFraction,
            primaryValue: window?.remainingPercentText ?? "—",
            secondaryValue: usedPercent.map { "\($0)% used" },
            countdown: window?.resetCountdown
        )
        .help(window?.description ?? "")
    }
}

struct AGGroupCard: View {
    let group: AGQuotaGroup
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(group.displayName).font(.system(size: 11, weight: .bold))
            AGWindowRow(title: "5小时余量", window: group.fiveHour)
            AGWindowRow(title: "本周余量", window: group.weekly)
        }
        .padding(10)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct AGAccountQuotaBody: View {
    let account: AGAccountQuota
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(account.email).font(.system(size: 13, weight: .bold)).lineLimit(1)
                AGTierBadge(account: account)
                Spacer()
            }
            ForEach(account.groups) { AGGroupCard(group: $0) }
        }
    }
}
