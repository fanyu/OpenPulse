import Foundation
import Observation

@MainActor
@Observable
final class CodexProviderManagerViewModel {
    var providers: [CodexProviderConfig] = []
    var currentProviderID: String = "openai"
    var selectedProviderID: String = "openai"
    var draft = CodexProviderConfig(
        id: "openai",
        name: "OpenAI",
        baseURL: "",
        envKey: "OPENAI_API_KEY",
        defaultModel: "gpt-5.5",
        isBuiltIn: true
    )
    var draftAPIKey: String = ""
    var isCreatingNew = false
    var isLoading = false
    var isWorking = false
    var errorMessage: String?
    var statusMessage: String?
    var routerStatus: CodexRouterStatus?
    var isRouterEnabled: Bool = false
    var isApplyingRouterState: Bool = false
    var isRefreshingRouterState: Bool = false

    func environmentVariableName() -> String {
        if draft.isBuiltIn {
            return draft.envKey
        }
        guard !draft.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "OPENPULSE_CODEX_<PROVIDER_ID>_API_KEY"
        }
        return CodexProviderConfigService.environmentVariableName(forProviderID: draft.id)
    }

    func load(using service: CodexProviderConfigService, coordinator: CodexRouterCoordinator) async {
        isLoading = true
        errorMessage = nil
        do {
            let state = try await service.loadState()
            apply(state: state)
            routerStatus = await coordinator.loadStatus()
            if let explicitEnabled = UserDefaults.standard.object(forKey: CodexRouterConstants.userEnabledDefaultsKey) as? Bool {
                isRouterEnabled = explicitEnabled
            } else {
                isRouterEnabled = false
            }
            if let selected = providers.first(where: { $0.id == selectedProviderID }) {
                draft = selected
            } else if let current = providers.first(where: { $0.id == currentProviderID }) {
                selectedProviderID = current.id
                draft = current
            } else if let first = providers.first {
                selectedProviderID = first.id
                draft = first
            }
            draftAPIKey = await service.loadAPIKey(for: draft.id) ?? ""
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func selectProvider(id: String, using service: CodexProviderConfigService) async {
        guard let provider = providers.first(where: { $0.id == id }) else { return }
        selectedProviderID = id
        draft = provider
        draftAPIKey = await service.loadAPIKey(for: id) ?? ""
        isCreatingNew = false
        errorMessage = nil
        statusMessage = nil
    }

    func beginCreate() {
        draft = CodexProviderConfig(
            id: "",
            name: "",
            baseURL: "",
            envKey: "",
            defaultModel: "",
            isBuiltIn: false
        )
        selectedProviderID = ""
        isCreatingNew = true
        draftAPIKey = ""
        errorMessage = nil
        statusMessage = nil
    }

    func save(using service: CodexProviderConfigService) async {
        isWorking = true
        errorMessage = nil
        statusMessage = nil
        do {
            let state = try await service.saveProvider(draft, apiKey: draftAPIKey)
            apply(state: state)
            selectedProviderID = draft.id
            if let saved = providers.first(where: { $0.id == draft.id }) {
                draft = saved
            }
            isCreatingNew = false
            statusMessage = "Provider 已保存"
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
    }

    func refreshRouterStatus(using coordinator: CodexRouterCoordinator) async {
        isRefreshingRouterState = true
        defer { isRefreshingRouterState = false }

        routerStatus = await coordinator.loadStatus()
        statusMessage = "Router 状态已刷新"
        if let explicitEnabled = UserDefaults.standard.object(forKey: CodexRouterConstants.userEnabledDefaultsKey) as? Bool {
            isRouterEnabled = explicitEnabled
        } else {
            isRouterEnabled = false
        }
    }

    func setCurrent(using service: CodexProviderConfigService, coordinator: CodexRouterCoordinator) async {
        isWorking = true
        errorMessage = nil
        statusMessage = nil
        defer { isWorking = false }
        let targetProviderID = draft.id
        let fallbackProviderID = currentProviderID

        do {
            let state = try await service.switchProvider(
                id: targetProviderID,
                allowThirdParty: canSelectCurrentProvider()
            )
            apply(state: state)
            routerStatus = await coordinator.loadStatus()
            if let saved = providers.first(where: { $0.id == draft.id }) {
                draft = saved
            }
            statusMessage = "已应用到当前路由：\(draft.name)"
        } catch {
            let originalError = error.localizedDescription
            AppLogger.shared.recordDiagnostic(
                level: .warning,
                scope: CodexRouterDiagnostics.diagnosticScope,
                message: CodexRouterDiagnostics.switchProviderFailedMessage(
                    target: targetProviderID,
                    reason: originalError
                )
            )
            if fallbackProviderID != targetProviderID {
                do {
                    let rollbackState = try await service.switchProvider(
                        id: fallbackProviderID,
                        allowThirdParty: true
                    )
                    apply(state: rollbackState)
                    draft = rollbackState.providers.first(where: { $0.id == fallbackProviderID }) ?? draft
                    let rollbackSnapshot = describeRollbackTarget(
                        providerID: fallbackProviderID,
                        in: rollbackState,
                        at: Date()
                    )
                    errorMessage = CodexRouterDiagnostics.userRollbackNoticeMessage(
                        snapshot: rollbackSnapshot,
                        reason: originalError
                    )
                    AppLogger.shared.recordDiagnostic(
                        level: .info,
                        scope: CodexRouterDiagnostics.diagnosticScope,
                        message: CodexRouterDiagnostics.rollbackSucceededMessage(snapshot: rollbackSnapshot)
                    )
                    routerStatus = await coordinator.loadStatus()
                } catch {
                    errorMessage = CodexRouterDiagnostics.userRollbackFailureMessage(
                        rollbackError: error.localizedDescription,
                        originalReason: originalError
                    )
                    AppLogger.shared.recordDiagnostic(
                        level: .error,
                        scope: CodexRouterDiagnostics.diagnosticScope,
                        message: CodexRouterDiagnostics.rollbackFailedMessage(
                            target: targetProviderID,
                            fallback: fallbackProviderID,
                            reason: error.localizedDescription
                        )
                    )
                }
            } else {
                errorMessage = originalError
            }
        }
    }

    func setRouterEnabled(_ enabled: Bool, using service: CodexProviderConfigService, coordinator: CodexRouterCoordinator) async {
        isApplyingRouterState = true
        errorMessage = nil
        statusMessage = nil
        isRouterEnabled = enabled
        await coordinator.setUserEnabled(enabled)
        if !enabled && currentProviderID != CodexRouterConstants.openAIProviderID {
            do {
                let state = try await service.switchProvider(id: CodexRouterConstants.openAIProviderID, allowThirdParty: true)
                apply(state: state)
            } catch {
                errorMessage = error.localizedDescription
                isApplyingRouterState = false
                routerStatus = await coordinator.loadStatus()
                return
            }
        }
        routerStatus = await coordinator.loadStatus()
        statusMessage = enabled ? "Router 已开启" : "Router 已关闭，已切回 OpenAI 模型路由"
        isApplyingRouterState = false
    }

    func delete(using service: CodexProviderConfigService) async {
        guard !draft.isBuiltIn else { return }
        isWorking = true
        errorMessage = nil
        statusMessage = nil
        let deletingID = draft.id
        do {
            let state = try await service.deleteProvider(id: deletingID)
            apply(state: state)
            if let current = providers.first(where: { $0.id == currentProviderID }) ?? providers.first {
                selectedProviderID = current.id
                draft = current
                draftAPIKey = await service.loadAPIKey(for: current.id) ?? ""
            }
            isCreatingNew = false
            statusMessage = "Provider 已删除"
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
    }

    func canSelect(_ provider: CodexProviderConfig) -> Bool {
        if provider.id == CodexRouterConstants.openAIProviderID {
            return true
        }
        guard let routerStatus, routerStatus.canSelectThirdParty else {
            return false
        }
        return !provider.defaultModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func canSelectCurrentProvider() -> Bool {
        guard let provider = providers.first(where: { $0.id == draft.id }) else { return false }
        if provider.id == CodexRouterConstants.openAIProviderID { return true }
        if canSelect(provider) { return true }
        if provider.defaultModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errorMessage = "该模型未填写默认模型名"
        }
        if !isRouterEnabled {
            errorMessage = "请先开启 Router"
        } else if routerStatus == nil {
            errorMessage = "Router 状态尚未就绪"
        } else if let status = routerStatus, !status.isRouterHealthy {
            errorMessage = status.healthError ?? "Router 未就绪"
        }
        return false
    }

    private func apply(state: CodexProviderConfigurationState) {
        providers = state.providers
        currentProviderID = state.currentProviderID
    }

    private func describeRollbackTarget(
        providerID: String,
        in state: CodexProviderConfigurationState,
        at timestamp: Date
    ) -> String {
        CodexRouterDiagnostics.rollbackSnapshot(providerID: providerID, in: state, at: timestamp)
    }
}
