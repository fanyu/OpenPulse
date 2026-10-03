import Foundation

struct CodexAccountsStore: Codable, Sendable {
    var version: Int = 2
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

    // Auth is hydrated from Keychain. The legacy JSON field is decode-only so an
    // atomic metadata rewrite can finish migration without encoding credentials.
    private enum CodingKeys: String, CodingKey {
        case id, label, email, accountID, planType, teamName, authJSONString
        case addedAt, updatedAt, lastFetchedAt, lastUsage, usageError
    }

    init(id: String, label: String, email: String?, accountID: String, planType: String?, teamName: String?,
         authJSONString: String, addedAt: Date, updatedAt: Date, lastFetchedAt: Date?,
         lastUsage: CodexRateLimits?, usageError: String?) {
        self.id = id
        self.label = label
        self.email = email
        self.accountID = accountID
        self.planType = planType
        self.teamName = teamName
        self.authJSONString = authJSONString
        self.addedAt = addedAt
        self.updatedAt = updatedAt
        self.lastFetchedAt = lastFetchedAt
        self.lastUsage = lastUsage
        self.usageError = usageError
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        label = try values.decode(String.self, forKey: .label)
        email = try values.decodeIfPresent(String.self, forKey: .email)
        accountID = try values.decode(String.self, forKey: .accountID)
        planType = try values.decodeIfPresent(String.self, forKey: .planType)
        teamName = try values.decodeIfPresent(String.self, forKey: .teamName)
        authJSONString = try values.decodeIfPresent(String.self, forKey: .authJSONString) ?? ""
        addedAt = try values.decode(Date.self, forKey: .addedAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        lastFetchedAt = try values.decodeIfPresent(Date.self, forKey: .lastFetchedAt)
        lastUsage = try values.decodeIfPresent(CodexRateLimits.self, forKey: .lastUsage)
        usageError = try values.decodeIfPresent(String.self, forKey: .usageError)
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(label, forKey: .label)
        try values.encodeIfPresent(email, forKey: .email)
        try values.encode(accountID, forKey: .accountID)
        try values.encodeIfPresent(planType, forKey: .planType)
        try values.encodeIfPresent(teamName, forKey: .teamName)
        try values.encode(addedAt, forKey: .addedAt)
        try values.encode(updatedAt, forKey: .updatedAt)
        try values.encodeIfPresent(lastFetchedAt, forKey: .lastFetchedAt)
        try values.encodeIfPresent(lastUsage, forKey: .lastUsage)
        try values.encodeIfPresent(usageError, forKey: .usageError)
    }

    mutating func migrateLegacyUsageObservation() {
        guard usageError == nil,
              let lastUsage,
              lastUsage.observedAt == nil,
              lastUsage.hasKnownGeneralWindow else { return }
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
        let weeklyExhausted = limits?.oneWeekWindow?.remainingPercent == 0
        let window = weeklyExhausted ? limits?.oneWeekWindow : (limits?.fiveHourWindow ?? limits?.oneWeekWindow)
        let remainingPct = window?.remainingPercent.map { Int($0) }
        return ToolQuota(
            id: "codex:\(accountID)",
            tool: .codex,
            accountKey: accountID,
            accountLabel: label,
            remaining: remainingPct,
            total: 100,
            unit: .tokens,
            resetAt: window?.resetDate,
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
