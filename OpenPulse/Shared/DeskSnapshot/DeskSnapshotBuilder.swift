import Foundation

enum DeskSnapshotBuilder {
    static func build(
        now: Date,
        codexAccounts: [CodexAccountSnapshot],
        claudeUsage: ClaudeUsageResponse?,
        fallbackQuotas: [QuotaRecord]
    ) -> DeskSnapshot? {
        guard
            let codexQuota = codexAccounts.first(where: \.isCurrent)?.quota
                ?? fallbackQuotas.first(where: { $0.tool == .codex })?.toModel(),
            let claudeQuota = toolQuota(from: claudeUsage, now: now)
                ?? fallbackQuotas.first(where: { $0.tool == .claudeCode })?.toModel()
        else {
            return nil
        }

        return DeskSnapshot(
            snapshotID: "desk-current",
            sourceDeviceID: sourceDeviceID(),
            schemaVersion: 1,
            updatedAt: now,
            codex: makeToolSnapshot(from: codexQuota, label: "Codex", now: now),
            claude: makeToolSnapshot(from: claudeQuota, label: "Claude", now: now)
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

    private static func makeToolSnapshot(from quota: ToolQuota, label: String, now: Date) -> DeskToolSnapshot {
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
            status: status,
            petState: petState(for: status)
        )
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
