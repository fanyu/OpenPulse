import SwiftUI

struct AGTierBadge: View {
    let tier: AGTier?
    var body: some View {
        if let tier {
            Text(tier.badgeLabel)
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(tier.isPaid ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.08),
                            in: Capsule())
                .foregroundStyle(tier.isPaid ? Color.accentColor : .secondary)
        }
    }
}

struct AGWindowRow: View {
    let title: LocalizedStringKey
    let window: AGWindow?
    private var color: Color {
        let f = window?.remainingFraction ?? 1
        return f < 0.1 ? .red : (f < 0.3 ? .orange : Color("AntigravityPurple"))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text(window?.remainingPercentText ?? "—").font(.system(size: 10, weight: .bold))
                if let cd = window?.resetCountdown {
                    Text(cd).font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
            QuotaProgressBar(fraction: window?.remainingFraction, color: color)
        }
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
                AGTierBadge(tier: account.tier)
                Spacer()
            }
            ForEach(account.groups) { AGGroupCard(group: $0) }
        }
    }
}
