import Foundation

enum CodexRouterDiagnostics {
    static let diagnosticScope = "codex.router"

    private static let rollbackTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = .current
        return formatter
    }()

    static func switchedToProviderMessage(providerID: String) -> String {
        "已切换到 provider=\(providerID)"
    }

    static func switchProviderFailedMessage(target: String, reason: String) -> String {
        "切换 Provider 失败: target=\(target), reason=\(reason)"
    }

    static func rollbackSucceededMessage(snapshot: String) -> String {
        "已回退到 \(snapshot)"
    }

    static func rollbackFailedMessage(target: String, fallback: String, reason: String) -> String {
        "回退失败: target=\(target) -> fallback=\(fallback), reason=\(reason)"
    }

    static func userRollbackNoticeMessage(snapshot: String, reason: String) -> String {
        "切换失败，已回退到: \(snapshot)。原因：\(reason)"
    }

    static func userRollbackFailureMessage(originalReason: String) -> String {
        "切换失败，回退失败。原因：\(originalReason)"
    }

    static func userRollbackFailureMessage(rollbackError: String, originalReason: String) -> String {
        "切换失败，回退失败：\(rollbackError)。原因：\(originalReason)"
    }

    static func rollbackSnapshot(
        providerID: String,
        in state: CodexProviderConfigurationState,
        at timestamp: Date = Date()
    ) -> String {
        let provider = state.providers.first(where: { $0.id == providerID })
        let name = provider?.name ?? providerID
        let model = provider?.defaultModel ?? "-"
        let modelText = model.isEmpty ? "model=未设置" : "model=\(model)"
        return "\(name) (\(providerID)) | \(modelText) | \(rollbackTimeFormatter.string(from: timestamp))"
    }
}
