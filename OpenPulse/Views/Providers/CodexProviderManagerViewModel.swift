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
    var isLoadingAPIKey = false
    var isWorking = false
    var errorMessage: String?
    var statusMessage: String?
    var routerStatus: CodexRouterStatus?
    var isRouterEnabled: Bool = false
    var isApplyingRouterState: Bool = false
    var isRefreshingRouterState: Bool = false
    @ObservationIgnored private var selectionRequestID = UUID()
    @ObservationIgnored private var originalAPIKey = ""
    @ObservationIgnored private var hasLoaded = false

    var isBusy: Bool {
        isLoading || isLoadingAPIKey || isWorking || isApplyingRouterState || isRefreshingRouterState
    }

    var hasUnsavedChanges: Bool {
        guard let saved = providers.first(where: { $0.id == draft.id }) else { return true }
        return draft != saved || draftAPIKey != originalAPIKey
    }

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
        guard !isBusy else { return }
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil
        do {
            let state = try await service.loadState()
            apply(state: state)
            routerStatus = await coordinator.loadStatus()
            isRouterEnabled = routerStatus?.isUserEnabled ?? false
            if !hasLoaded { selectedProviderID = currentProviderID }
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
            originalAPIKey = draftAPIKey
            hasLoaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectProvider(id: String, using service: CodexProviderConfigService) async {
        guard !isLoading, !isWorking, !isApplyingRouterState, !isRefreshingRouterState else { return }
        guard let provider = providers.first(where: { $0.id == id }) else { return }
        let requestID = UUID()
        selectionRequestID = requestID
        isLoadingAPIKey = true
        defer {
            if selectionRequestID == requestID { isLoadingAPIKey = false }
        }
        selectedProviderID = id
        draft = provider
        draftAPIKey = ""
        isCreatingNew = false
        errorMessage = nil
        statusMessage = nil
        let apiKey = await service.loadAPIKey(for: id) ?? ""
        guard selectionRequestID == requestID, selectedProviderID == id, !isCreatingNew else { return }
        draftAPIKey = apiKey
        originalAPIKey = apiKey
    }

    func beginCreate() {
        guard !isBusy else { return }
        selectionRequestID = UUID()
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
        originalAPIKey = ""
        errorMessage = nil
        statusMessage = nil
    }

    func save(using service: CodexProviderConfigService) async {
        guard !isBusy else { return }
        let providerID = draft.id.trimmingCharacters(in: .whitespacesAndNewlines)
        if isCreatingNew, providers.contains(where: { $0.id == providerID }) {
            errorMessage = String(localized: "Provider ID 已存在，请使用其他标识。")
            return
        }
        let submittedDraft = draft
        let submittedAPIKey = draftAPIKey
        let isNewProvider = isCreatingNew
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        statusMessage = nil
        do {
            let state = try await service.saveProvider(submittedDraft, apiKey: submittedAPIKey, isNew: isNewProvider)
            apply(state: state)
            selectedProviderID = providerID
            if let saved = providers.first(where: { $0.id == providerID }) {
                draft = saved
            }
            draftAPIKey = submittedAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            originalAPIKey = draftAPIKey
            isCreatingNew = false
            statusMessage = String(localized: "Provider 已保存")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshRouterStatus(using coordinator: CodexRouterCoordinator) async {
        guard !isBusy else { return }
        isRefreshingRouterState = true
        defer { isRefreshingRouterState = false }

        routerStatus = await coordinator.loadStatus()
        statusMessage = String(localized: "Router 状态已刷新")
        isRouterEnabled = routerStatus?.isUserEnabled ?? false
    }

    func setCurrent(using service: CodexProviderConfigService, coordinator: CodexRouterCoordinator) async {
        guard !isBusy else { return }
        guard !isCreatingNew, !hasUnsavedChanges else {
            errorMessage = String(localized: "请先保存 Provider 修改，再应用路由。")
            return
        }
        guard canSelectCurrentProvider() else { return }
        isWorking = true
        errorMessage = nil
        statusMessage = nil
        defer { isWorking = false }
        let targetProviderID = draft.id
        let fallbackProviderID = currentProviderID

        do {
            let state = try await service.switchProvider(
                id: targetProviderID,
                allowThirdParty: true
            )
            apply(state: state)
            routerStatus = await coordinator.loadStatus()
            if let saved = providers.first(where: { $0.id == draft.id }) {
                draft = saved
            }
            statusMessage = String(localized: "已应用到当前路由：\(draft.name)")
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
                    selectedProviderID = draft.id
                    draftAPIKey = await service.loadAPIKey(for: draft.id) ?? ""
                    originalAPIKey = draftAPIKey
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
        guard !isBusy else { return }
        isApplyingRouterState = true
        defer { isApplyingRouterState = false }
        errorMessage = nil
        statusMessage = nil
        // Keep Router enabled until the replacement route was written successfully.
        if !enabled && currentProviderID != CodexRouterConstants.openAIProviderID {
            do {
                let state = try await service.switchProvider(id: CodexRouterConstants.openAIProviderID, allowThirdParty: true)
                apply(state: state)
            } catch {
                errorMessage = error.localizedDescription
                routerStatus = await coordinator.loadStatus()
                isRouterEnabled = routerStatus?.isUserEnabled ?? false
                return
            }
        }
        await coordinator.setUserEnabled(enabled)
        routerStatus = await coordinator.loadStatus()
        isRouterEnabled = routerStatus?.isUserEnabled ?? enabled
        statusMessage = enabled
            ? String(localized: "Router 已开启")
            : String(localized: "Router 已关闭，已切回 OpenAI 模型路由")
    }

    func delete(using service: CodexProviderConfigService) async {
        guard !isBusy, !draft.isBuiltIn, draft.id != currentProviderID else { return }
        isWorking = true
        defer { isWorking = false }
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
                originalAPIKey = draftAPIKey
            }
            isCreatingNew = false
            statusMessage = String(localized: "Provider 已删除")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func canSelect(_ provider: CodexProviderConfig) -> Bool {
        unavailableReason(for: provider) == nil
    }

    func unavailableReason(for provider: CodexProviderConfig) -> String? {
        if provider.defaultModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "请填写默认模型名")
        }
        if provider.id == CodexRouterConstants.openAIProviderID { return nil }
        if !isRouterEnabled { return String(localized: "请先开启 Router") }
        guard let routerStatus else { return String(localized: "Router 状态尚未就绪") }
        guard routerStatus.canSelectThirdParty else { return routerStatus.healthError ?? String(localized: "Router 未就绪") }
        return nil
    }

    func canSelectCurrentProvider() -> Bool {
        guard let provider = providers.first(where: { $0.id == draft.id }) else {
            errorMessage = String(localized: "请先保存 Provider。")
            return false
        }
        if let reason = unavailableReason(for: provider) {
            errorMessage = reason
            return false
        }
        return true
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
