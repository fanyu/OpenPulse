import Foundation

#if os(macOS)
enum DeskSnapshotBuilder {
    static func build(
        now: Date,
        codexAccounts: [CodexAccountSnapshot],
        claudeUsage: ClaudeUsageResponse?,
        claudeObservedAt: Date? = nil,
        fallbackQuotas: [QuotaRecord]
    ) -> DeskSnapshot? {
        let currentCodexAccount = codexAccounts.first(where: \.isCurrent)
        let codexWeekly = currentCodexAccount?.limits?.oneWeekWindow
            .flatMap { makeWindowSnapshot(label: "7d Weekly", from: $0) }
        let claudeWeekly = claudeUsage?.sevenDay
            .flatMap { makeWindowSnapshot(label: "7d Weekly", from: $0) }

        guard
            let codexQuota = preferredQuota(
                toolQuota(from: currentCodexAccount),
                weekly: codexWeekly,
                fallback: fallbackQuota(for: .codex, in: fallbackQuotas)?.toModel()
            ),
            let claudeQuota = preferredQuota(
                toolQuota(from: claudeUsage, observedAt: claudeObservedAt),
                weekly: claudeWeekly,
                fallback: fallbackQuota(for: .claudeCode, in: fallbackQuotas)?.toModel()
            )
        else {
            return nil
        }

        return DeskSnapshot(
            snapshotID: "desk-current",
            sourceDeviceID: sourceDeviceID(),
            schemaVersion: 2,
            updatedAt: now,
            codex: makeToolSnapshot(
                from: codexQuota,
                label: "Codex",
                weekly: codexWeekly,
                now: now
            ),
            claude: makeToolSnapshot(
                from: claudeQuota,
                label: "Claude",
                weekly: claudeWeekly,
                now: now
            )
        )
    }

    private static func toolQuota(from account: CodexAccountSnapshot?) -> ToolQuota? {
        guard let account, let limits = account.limits,
              limits.hasKnownGeneralWindow else { return nil }
        let window = limits.fiveHourWindow
        return ToolQuota(
            id: "codex:\(account.accountID)",
            tool: .codex,
            accountKey: account.accountID,
            accountLabel: account.label,
            remaining: window?.remainingPercent.map { Int($0) },
            total: 100,
            unit: .tokens,
            resetAt: window?.resetDate,
            updatedAt: limits.observedAt ?? account.updatedAt,
            raw: limits
        )
    }

    private static func toolQuota(from usage: ClaudeUsageResponse?, observedAt: Date?) -> ToolQuota? {
        guard let usage, usage.fiveHour != nil || usage.sevenDay != nil else { return nil }
        return ToolQuota(
            id: "claude:five-hour",
            tool: .claudeCode,
            accountKey: nil,
            accountLabel: nil,
            remaining: remainingPercent(from: usage.fiveHour?.utilization),
            total: 100,
            unit: .tokens,
            resetAt: usage.fiveHour?.resetDate,
            updatedAt: observedAt ?? .distantPast,
            raw: usage
        )
    }

    private static func preferredQuota(
        _ primary: ToolQuota?,
        weekly: DeskQuotaWindowSnapshot?,
        fallback: ToolQuota?
    ) -> ToolQuota? {
        // A weekly-only source can describe a blocker without inventing a 5h value.
        if let primary, isUsable(primary) || weekly?.fraction != nil {
            return primary
        }
        if let fallback, isUsable(fallback) {
            return fallback
        }
        return nil
    }

    private static func isUsable(_ quota: ToolQuota) -> Bool {
        guard let remaining = quota.remaining,
              let total = quota.total,
              total > 0,
              quota.resetAt != nil else {
            return false
        }

        return remaining >= 0
    }

    private static func makeToolSnapshot(
        from quota: ToolQuota,
        label: String,
        weekly: DeskQuotaWindowSnapshot?,
        now: Date
    ) -> DeskToolSnapshot {
        let status: DeskQuotaStatus
        if now.timeIntervalSince(quota.updatedAt) > 600
            || quota.resetAt.map({ $0 <= now }) == true
            || weekly?.resetAt.map({ $0 <= now }) == true {
            status = .stale
        } else if weekly?.remaining == 0 {
            status = .exhausted
        } else {
            status = DeskQuotaStatus.resolve(
                remaining: quota.remaining,
                total: quota.total,
                updatedAt: quota.updatedAt,
                now: now
            )
        }

        return DeskToolSnapshot(
            tool: quota.tool,
            displayLabel: label,
            remaining: quota.remaining,
            total: quota.total,
            fraction: quota.fraction,
            resetAt: quota.resetAt,
            weekly: weekly,
            status: status,
            petState: petState(for: status)
        )
    }

    private static func makeWindowSnapshot(label: String, from window: CodexWindow) -> DeskQuotaWindowSnapshot? {
        guard let remaining = window.remainingPercent else { return nil }
        return makeWindowSnapshot(
            label: label,
            remaining: Int(remaining.rounded()),
            total: 100,
            resetAt: window.resetDate
        )
    }

    private static func makeWindowSnapshot(label: String, from window: UsageWindow) -> DeskQuotaWindowSnapshot? {
        guard let remaining = remainingPercent(from: window.utilization) else {
            return nil
        }

        return makeWindowSnapshot(
            label: label,
            remaining: remaining,
            total: 100,
            resetAt: window.resetDate
        )
    }

    private static func remainingPercent(from utilization: Double?) -> Int? {
        guard let utilization, utilization.isFinite else { return nil }
        return Int(min(100, max(0, 100 - utilization)).rounded())
    }

    private static func makeWindowSnapshot(
        label: String,
        remaining: Int?,
        total: Int?,
        resetAt: Date?
    ) -> DeskQuotaWindowSnapshot? {
        guard let resetAt else {
            return nil
        }

        let fraction: Double? = if let remaining, let total, total > 0 {
            Double(remaining) / Double(total)
        } else {
            nil
        }

        return DeskQuotaWindowSnapshot(
            label: label,
            remaining: remaining,
            total: total,
            fraction: fraction,
            resetAt: resetAt
        )
    }

    private static func fallbackQuota(for tool: Tool, in fallbackQuotas: [QuotaRecord]) -> QuotaRecord? {
        let matchingRecords = fallbackQuotas
            .filter { $0.tool == tool }
            .filter { isUsable($0.toModel()) }

        if tool == .codex {
            let genericRecord = bestFallbackQuota(
                from: matchingRecords.filter { $0.accountKey == nil }
            )
            if let genericRecord {
                return genericRecord
            }
        }

        return bestFallbackQuota(from: matchingRecords)
    }

    private static func bestFallbackQuota(from records: [QuotaRecord]) -> QuotaRecord? {
        records.max { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt < rhs.updatedAt
            }
            return (lhs.resetAt ?? .distantPast) < (rhs.resetAt ?? .distantPast)
        }
    }

    private static func petState(for status: DeskQuotaStatus) -> DeskPetState {
        switch status {
        case .healthy:
            return .patrol
        case .warning:
            return .pause
        case .critical:
            return .alert
        case .exhausted:
            return .exhausted
        case .stale:
            return .waiting
        }
    }

    private static func sourceDeviceID() -> String {
        #if os(macOS)
        Host.current().localizedName ?? "mac"
        #else
        ProcessInfo.processInfo.hostName
        #endif
    }
}
#endif
