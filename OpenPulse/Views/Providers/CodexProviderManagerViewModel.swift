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

    func environmentVariableName() -> String {
        if draft.isBuiltIn {
            return draft.envKey
        }
        guard !draft.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "OPENPULSE_CODEX_<PROVIDER_ID>_API_KEY"
        }
        return CodexProviderConfigService.environmentVariableName(forProviderID: draft.id)
    }

    func load(using service: CodexProviderConfigService) async {
        isLoading = true
        errorMessage = nil
        do {
            let state = try await service.loadState()
            apply(state: state)
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

    func setCurrent(
        using service: CodexProviderConfigService,
        codexAccountService: CodexAccountService
    ) async {
        isWorking = true
        errorMessage = nil
        statusMessage = nil
        do {
            let state = try await service.switchProvider(id: draft.id)
            _ = try await codexAccountService.relaunchCodex()
            apply(state: state)
            if let saved = providers.first(where: { $0.id == draft.id }) {
                draft = saved
            }
            statusMessage = "已切换到 \(draft.name)"
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
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

    private func apply(state: CodexProviderConfigurationState) {
        providers = state.providers
        currentProviderID = state.currentProviderID
    }
}
