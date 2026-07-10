import Foundation

#if os(macOS)
enum DeskSnapshotBuilder {
    static func build(
        now: Date,
        codexAccounts: [CodexAccountSnapshot],
        claudeUsage: ClaudeUsageResponse?,
        fallbackQuotas: [QuotaRecord]
    ) -> DeskSnapshot? {
        let currentCodexQuota = codexAccounts
            .first(where: \.isCurrent)?
            .quota

        guard
            let codexQuota = preferredQuota(
                currentCodexQuota,
                fallback: fallbackQuota(for: .codex, in: fallbackQuotas)?.toModel()
            ),
            let claudeQuota = preferredQuota(
                toolQuota(from: claudeUsage, now: now),
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
            codex: makeCodexSnapshot(
                from: codexQuota,
                accounts: codexAccounts,
                fallbackQuotas: fallbackQuotas,
                now: now
            ),
            claude: makeClaudeSnapshot(
                from: claudeQuota,
                usage: claudeUsage,
                fallbackQuotas: fallbackQuotas,
                now: now
            )
        )
    }

    private static func toolQuota(from usage: ClaudeUsageResponse?, now: Date) -> ToolQuota? {
        guard let window = usage?.fiveHour else { return nil }

        let remaining = window.utilization.map { max(0, Int((100 - $0).rounded())) }
        return ToolQuota(
            id: "claude:five-hour",
            tool: .claudeCode,
            accountKey: nil,
            accountLabel: nil,
            remaining: remaining,
            total: 100,
            unit: .tokens,
            resetAt: window.resetDate,
            updatedAt: now,
            raw: usage
        )
    }

    private static func preferredQuota(_ primary: ToolQuota?, fallback: ToolQuota?) -> ToolQuota? {
        if let primary, isUsable(primary) {
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

    private static func makeCodexSnapshot(
        from quota: ToolQuota,
        accounts: [CodexAccountSnapshot],
        fallbackQuotas _: [QuotaRecord],
        now: Date
    ) -> DeskToolSnapshot {
        let weeklyWindow = accounts
            .first(where: \.isCurrent)?
            .limits?
            .oneWeekWindow
            .flatMap { makeWindowSnapshot(label: "7d Weekly", from: $0) }

        return makeToolSnapshot(
            from: quota,
            label: "Codex",
            weekly: weeklyWindow,
            now: now
        )
    }

    private static func makeClaudeSnapshot(
        from quota: ToolQuota,
        usage: ClaudeUsageResponse?,
        fallbackQuotas _: [QuotaRecord],
        now: Date
    ) -> DeskToolSnapshot {
        let weeklyWindow = usage?
            .sevenDay
            .flatMap { makeWindowSnapshot(label: "7d Weekly", from: $0) }

        return makeToolSnapshot(
            from: quota,
            label: "Claude",
            weekly: weeklyWindow,
            now: now
        )
    }

    private static func makeToolSnapshot(
        from quota: ToolQuota,
        label: String,
        weekly: DeskQuotaWindowSnapshot?,
        now: Date
    ) -> DeskToolSnapshot {
        let status = DeskQuotaStatus.resolve(
            remaining: quota.remaining,
            total: quota.total,
            updatedAt: quota.updatedAt,
            now: now
        )

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
        makeWindowSnapshot(
            label: label,
            remaining: Int(window.remainingPercent.rounded()),
            total: 100,
            resetAt: window.resetDate
        )
    }

    private static func makeWindowSnapshot(label: String, from window: UsageWindow) -> DeskQuotaWindowSnapshot? {
        guard let utilization = window.utilization else {
            return nil
        }

        return makeWindowSnapshot(
            label: label,
            remaining: max(0, Int((100 - utilization).rounded())),
            total: 100,
            resetAt: window.resetDate
        )
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
