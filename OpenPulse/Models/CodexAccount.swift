import Foundation

struct CodexAccountsStore: Codable, Sendable {
    var version: Int = 1
    var currentAccountID: String?
    var accounts: [CodexStoredAccount] = []
}

struct CodexStoredAccount: Codable, Identifiable, Sendable {
    var id: String
    var label: String
    var email: String?
    var accountID: String
    var planType: String?
    var teamName: String?
    var authJSONString: String
    var addedAt: Date
    var updatedAt: Date
    var lastFetchedAt: Date?
    var lastUsage: CodexRateLimits?
    var usageError: String?

    mutating func migrateLegacyUsageObservation() {
        guard let lastUsage, lastUsage.observedAt == nil else { return }
        self.lastUsage = lastUsage.replacingObservedAt(lastFetchedAt ?? updatedAt)
    }
}

struct CodexAccountSnapshot: Identifiable, Sendable {
    var id: String
    var label: String
    var email: String?
    var accountID: String
    var planType: String?
    var teamName: String?
    var addedAt: Date
    var updatedAt: Date
    var lastFetchedAt: Date?
    var limits: CodexRateLimits?
    var usageError: String?
    var isCurrent: Bool

    var titleText: String {
        if let trimmedEmail = normalizedEmail {
            let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLabel.isEmpty || trimmedLabel.caseInsensitiveCompare(trimmedEmail) == .orderedSame {
                return trimmedEmail
            }
        }
        return label
    }

    var subtitleText: String? {
        guard let trimmedEmail = normalizedEmail else { return nil }
        return titleText.caseInsensitiveCompare(trimmedEmail) == .orderedSame ? nil : trimmedEmail
    }

    var metaText: String? {
        if let normalizedTeamName, !normalizedTeamName.isEmpty {
            return normalizedTeamName
        }
        return nil
    }

    var displaySubscriptionName: String? {
        normalizedSubscriptionDisplayName(planType ?? limits?.planType)
    }

    var displayName: String {
        if let subtitleText {
            return "\(titleText) · \(subtitleText)"
        }
        return titleText
    }

    var quota: ToolQuota {
        let remainingPct = limits?.fiveHourWindow.map { Int($0.remainingPercent) }
        return ToolQuota(
            id: "codex:\(accountID)",
            tool: .codex,
            accountKey: accountID,
            accountLabel: label,
            remaining: remainingPct,
            total: 100,
            unit: .tokens,
            resetAt: limits?.fiveHourWindow?.resetDate,
            updatedAt: limits?.observedAt ?? updatedAt,
            raw: limits
        )
    }

    var generalQuota: ToolQuota? {
        limits?.hasKnownGeneralWindow == true ? quota : nil
    }

    private var normalizedEmail: String? {
        guard let email else { return nil }
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var normalizedTeamName: String? {
        guard let teamName else { return nil }
        let trimmed = teamName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.caseInsensitiveCompare("team") == .orderedSame { return nil }
        return trimmed
    }
}
