import Foundation

@MainActor
final class DotTextAPIService {
    private enum DefaultsKey {
        static let isEnabled = "dot.textAPI.enabled"
        static let deviceID = "dot.textAPI.deviceID"
        static let taskKey = "dot.textAPI.taskKey"
    }

    private struct RequestBody: Encodable {
        let refreshNow: Bool
        let title: String
        let message: String
        let signature: String
        let taskKey: String?
    }

    private struct APIResponse: Decodable {
        let code: Int
        let message: String

        private enum CodingKeys: String, CodingKey {
            case code
            case message
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let intCode = try? container.decode(Int.self, forKey: .code) {
                code = intCode
            } else if let stringCode = try? container.decode(String.self, forKey: .code),
                      let intCode = Int(stringCode) {
                code = intCode
            } else {
                code = 200
            }
            message = (try? container.decode(String.self, forKey: .message)) ?? ""
        }
    }

    private let baseURL = URL(string: "https://dot.mindreset.tech")!
    private var lastSentFingerprint: String?

    func pushQuotaSnapshot(
        codexAccounts: [CodexAccountSnapshot],
        claudeUsage: ClaudeUsageResponse?,
        fallbackQuotas: [QuotaRecord],
        force: Bool = false
    ) async {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: DefaultsKey.isEnabled) else { return }

        let deviceID = defaults.string(forKey: DefaultsKey.deviceID)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !deviceID.isEmpty else {
            AppLogger.shared.recordDiagnostic(level: .warning, scope: "dot.text.skip", message: "Dot Text API device ID is empty")
            return
        }

        let apiKey = ((try? KeychainService.retrieve(key: KeychainService.Keys.dotAPIKey)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            AppLogger.shared.recordDiagnostic(level: .warning, scope: "dot.text.skip", message: "Dot Text API key is empty")
            return
        }

        let taskKey = defaults.string(forKey: DefaultsKey.taskKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshot = makeQuotaMessage(codexAccounts: codexAccounts, claudeUsage: claudeUsage, fallbackQuotas: fallbackQuotas)
        let fingerprint = [deviceID, taskKey ?? "", snapshot].joined(separator: "\u{1F}")
        guard force || lastSentFingerprint != fingerprint else { return }

        let body = RequestBody(
            refreshNow: true,
            title: "",
            message: snapshot,
            signature: "",
            taskKey: taskKey?.isEmpty == false ? taskKey : nil
        )

        do {
            try await send(body: body, deviceID: deviceID, apiKey: apiKey)
            lastSentFingerprint = fingerprint
            AppLogger.shared.recordDiagnostic(scope: "dot.text.push", message: "Dot Text API quota snapshot pushed")
        } catch {
            AppLogger.shared.recordSyncError(
                scope: "dot.text.push",
                tool: nil,
                error: error,
                source: "Dot Text API",
                path: nil,
                details: error.localizedDescription
            )
        }
    }

    private func send(body: RequestBody, deviceID: String, apiKey: String) async throws {
        let url = baseURL.appending(path: "/api/authV2/open/device/\(deviceID)/text")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let apiResponse = try? JSONDecoder().decode(APIResponse.self, from: data)
        guard (200..<300).contains(statusCode),
              apiResponse?.code ?? 200 == 200 else {
            throw DotTextAPIError.requestFailed(statusCode: statusCode, code: apiResponse?.code, message: apiResponse?.message)
        }
    }

    private func makeQuotaMessage(
        codexAccounts: [CodexAccountSnapshot],
        claudeUsage: ClaudeUsageResponse?,
        fallbackQuotas: [QuotaRecord]
    ) -> String {
        [
            makeCodexLabel(accounts: codexAccounts),
            makeCodexLine(accounts: codexAccounts, fallbackQuotas: fallbackQuotas),
            makeClaudeLabel(usage: claudeUsage),
            makeClaudeLine(usage: claudeUsage, fallbackQuotas: fallbackQuotas),
        ].joined(separator: "\n")
    }

    private func makeCodexLabel(accounts: [CodexAccountSnapshot]) -> String {
        guard let account = accounts.first(where: \.isCurrent) ?? accounts.first,
              let resetAt = account.limits?.oneWeekWindow?.resetDate else {
            return "Codex:"
        }
        return "Codex 7d \(formatSevenDayReset(resetAt))"
    }

    private func makeClaudeLabel(usage: ClaudeUsageResponse?) -> String {
        guard let resetAt = usage?.sevenDay?.resetDate else {
            return "Claude:"
        }
        return "Claude 7d \(formatSevenDayReset(resetAt))"
    }

    private func makeCodexLine(accounts: [CodexAccountSnapshot], fallbackQuotas: [QuotaRecord]) -> String {
        if let account = accounts.first(where: \.isCurrent) ?? accounts.first {
            guard let limits = account.limits else { return "--" }
            return "5h \(formatCodexFiveHourWindow(limits.fiveHourWindow)) | 7d \(formatCodexSevenDayWindow(limits.oneWeekWindow))"
        }

        if let quota = fallbackQuotas.first(where: { $0.tool == .codex && $0.accountKey == nil }) {
            return "5h \(formatFiveHourWindow(percent: formatQuotaPercent(remaining: quota.remaining, total: quota.total), resetAt: quota.resetAt)) | 7d --"
        }
        return "5h -- | 7d --"
    }

    private func makeClaudeLine(usage: ClaudeUsageResponse?, fallbackQuotas: [QuotaRecord]) -> String {
        if let usage {
            return "5h \(formatClaudeFiveHourWindow(usage.fiveHour)) | 7d \(formatClaudeSevenDayWindow(usage.sevenDay))"
        }

        if let quota = fallbackQuotas.first(where: { $0.tool == .claudeCode }) {
            return "5h \(formatFiveHourWindow(percent: formatQuotaPercent(remaining: quota.remaining, total: quota.total), resetAt: quota.resetAt)) | 7d --"
        }
        return "5h -- | 7d --"
    }

    private func formatCodexFiveHourWindow(_ window: CodexWindow?) -> String {
        formatFiveHourWindow(percent: formatCodexPercent(window), resetAt: window?.resetDate)
    }

    private func formatCodexSevenDayWindow(_ window: CodexWindow?) -> String {
        formatPercentValue(formatCodexPercent(window))
    }

    private func formatClaudeFiveHourWindow(_ window: UsageWindow?) -> String {
        formatFiveHourWindow(percent: formatClaudePercent(window), resetAt: window?.resetDate)
    }

    private func formatClaudeSevenDayWindow(_ window: UsageWindow?) -> String {
        formatPercentValue(formatClaudePercent(window))
    }

    private func formatFiveHourWindow(percent: String, resetAt: Date?) -> String {
        let value = formatPercentValue(percent)
        guard let resetAt else { return value }
        let time = resetAt.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        return "\(value) @\(time)"
    }

    private func formatSevenDayReset(_ resetAt: Date) -> String {
        resetAt.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    private func formatPercentValue(_ percent: String) -> String {
        percent == "--" ? percent : "\(percent)%"
    }

    private func formatCodexPercent(_ window: CodexWindow?) -> String {
        guard let usedPercent = window?.usedPercent else { return "--" }
        return "\(max(0, 100 - Int(usedPercent.rounded())))"
    }

    private func formatClaudePercent(_ window: UsageWindow?) -> String {
        guard let utilization = window?.utilization else { return "--" }
        return "\(max(0, 100 - Int(utilization.rounded())))"
    }

    private func formatQuotaPercent(remaining: Int?, total: Int?) -> String {
        guard let remaining, let total, total > 0 else { return "--" }
        return "\(Int((Double(remaining) / Double(total) * 100).rounded()))"
    }
}

enum DotTextAPIError: LocalizedError {
    case requestFailed(statusCode: Int, code: Int?, message: String?)

    var errorDescription: String? {
        switch self {
        case .requestFailed(let statusCode, let code, let message):
            let apiCode = code.map { ", code=\($0)" } ?? ""
            let apiMessage = message.map { ", message=\($0)" } ?? ""
            return "Dot Text API request failed: HTTP \(statusCode)\(apiCode)\(apiMessage)"
        }
    }
}
