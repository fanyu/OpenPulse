import Foundation

struct CodexProviderConfig: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var baseURL: String
    var envKey: String
    var defaultModel: String
    var isBuiltIn: Bool = false
}

struct CodexProviderConfigurationState: Sendable {
    var currentProviderID: String
    var currentModel: String
    var providers: [CodexProviderConfig]
}

actor CodexProviderConfigService {
    static func environmentVariableName(forProviderID providerID: String) -> String {
        let uppercase = providerID.uppercased()
        let sanitized = uppercase.replacingOccurrences(
            of: #"[^A-Z0-9]+"#,
            with: "_",
            options: .regularExpression
        )
        let trimmed = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let suffix = trimmed.isEmpty ? "PROVIDER" : trimmed
        return "OPENPULSE_CODEX_\(suffix)_API_KEY"
    }

    enum ServiceError: LocalizedError {
        case missingConfig
        case invalidProviderID
        case duplicateProviderID
        case missingRequiredField(String)
        case providerNotFound
        case cannotDeleteBuiltIn
        case cannotDeleteCurrent
        case launchctlFailed(String)
        var errorDescription: String? {
            switch self {
            case .missingConfig:
                "未找到 Codex 配置文件。"
            case .invalidProviderID:
                "Provider ID 只能包含字母、数字、连字符或下划线。"
            case .duplicateProviderID:
                "Provider ID 已存在。"
            case .missingRequiredField(let field):
                "\(field) 不能为空。"
            case .providerNotFound:
                "未找到对应的 Provider。"
            case .cannotDeleteBuiltIn:
                "内建 OpenAI Provider 不能删除。"
            case .cannotDeleteCurrent:
                "请先切换到其他 Provider，再删除当前 Provider。"
            case .launchctlFailed(let message):
                message
            }
        }
    }

    private struct DefaultsStore: Codable {
        var defaultModels: [String: String] = [:]
    }

    private struct ParsedProviderSection {
        var id: String
        var startLine: Int
        var endLine: Int
        var name: String = ""
        var baseURL: String = ""
        var envKey: String = ""
        var extraLines: [String] = []
    }

    private struct ParsedConfig {
        var lines: [String]
        var currentModel: String = ""
        var currentProviderID: String = "openai"
        var providerSections: [ParsedProviderSection] = []
    }

    private let fileManager: FileManager
    private let configURL: URL
    private let defaultsURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.configURL = URL.homeDirectory.appending(path: ".codex/config.toml")
        self.defaultsURL = URL.homeDirectory.appending(path: ".openpulse/codex-provider-default-models.json")
    }

    func loadState() throws -> CodexProviderConfigurationState {
        let parsed = try parseConfig()
        let defaults = loadDefaultsStore()

        var providers: [CodexProviderConfig] = []
        let openAIDefault = defaults.defaultModels["openai"]
            ?? (parsed.currentProviderID == "openai" ? parsed.currentModel : "gpt-5.5")
        providers.append(
            CodexProviderConfig(
                id: "openai",
                name: "OpenAI",
                baseURL: "",
                envKey: "OPENAI_API_KEY",
                defaultModel: openAIDefault,
                isBuiltIn: true
            )
        )

        for section in parsed.providerSections.sorted(by: { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }) {
            let defaultModel = defaults.defaultModels[section.id]
                ?? inferredDefaultModel(for: section.id, parsed: parsed)
            providers.append(
                CodexProviderConfig(
                    id: section.id,
                    name: section.name.isEmpty ? section.id : section.name,
                    baseURL: section.baseURL,
                    envKey: Self.environmentVariableName(forProviderID: section.id),
                    defaultModel: defaultModel
                )
            )
        }

        return CodexProviderConfigurationState(
            currentProviderID: parsed.currentProviderID,
            currentModel: parsed.currentModel,
            providers: providers
        )
    }

    func loadAPIKey(for providerID: String) -> String? {
        try? KeychainService.retrieve(key: apiKeyStorageKey(for: providerID))
    }

    func saveProvider(
        _ provider: CodexProviderConfig,
        apiKey: String?
    ) throws -> CodexProviderConfigurationState {
        if provider.isBuiltIn {
            guard !provider.defaultModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ServiceError.missingRequiredField("默认模型")
            }
            var defaults = loadDefaultsStore()
            defaults.defaultModels["openai"] = provider.defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
            try saveDefaultsStore(defaults)
            return try loadState()
        }

        let normalized = try normalizedProvider(provider)
        var parsed = try parseConfig()
        let existing = parsed.providerSections.first(where: { $0.id == normalized.id })

        if let existing {
            let replacement = renderSection(
                id: normalized.id,
                name: normalized.name,
                baseURL: normalized.baseURL,
                envKey: normalized.envKey,
                extraLines: existing.extraLines
            )
            parsed.lines.replaceSubrange(existing.startLine...existing.endLine, with: replacement)
        } else {
            if parsed.providerSections.contains(where: { $0.id == normalized.id }) {
                throw ServiceError.duplicateProviderID
            }
            let insertionIndex = providerInsertionIndex(in: parsed.lines)
            let block = renderSection(
                id: normalized.id,
                name: normalized.name,
                baseURL: normalized.baseURL,
                envKey: normalized.envKey,
                extraLines: []
            )
            let prefixBlank = insertionIndex > 0 && !parsed.lines[insertionIndex - 1].trimmingCharacters(in: .whitespaces).isEmpty
            let suffixBlank = insertionIndex < parsed.lines.count && !parsed.lines[insertionIndex].trimmingCharacters(in: .whitespaces).isEmpty
            var insertion = block
            if prefixBlank { insertion.insert("", at: 0) }
            if suffixBlank { insertion.append("") }
            parsed.lines.insert(contentsOf: insertion, at: insertionIndex)
        }

        try writeConfig(lines: parsed.lines)

        var defaults = loadDefaultsStore()
        defaults.defaultModels[normalized.id] = normalized.defaultModel
        try saveDefaultsStore(defaults)
        try syncProviderSecret(
            providerID: normalized.id,
            envKey: normalized.envKey,
            previousEnvKey: existing?.envKey,
            apiKey: apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        return try loadState()
    }

    func switchProvider(id: String) throws -> CodexProviderConfigurationState {
        let state = try loadState()
        guard let provider = state.providers.first(where: { $0.id == id }) else {
            throw ServiceError.providerNotFound
        }
        guard !provider.defaultModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ServiceError.missingRequiredField("默认模型")
        }

        var parsed = try parseConfig()
        setTopLevel(key: "model_provider", value: provider.id, in: &parsed.lines)
        setTopLevel(key: "model", value: provider.defaultModel, in: &parsed.lines)
        try writeConfig(lines: parsed.lines)

        var defaults = loadDefaultsStore()
        defaults.defaultModels[provider.id] = provider.defaultModel
        try saveDefaultsStore(defaults)

        return try loadState()
    }

    func deleteProvider(id: String) throws -> CodexProviderConfigurationState {
        if id == "openai" {
            throw ServiceError.cannotDeleteBuiltIn
        }

        let state = try loadState()
        if state.currentProviderID == id {
            throw ServiceError.cannotDeleteCurrent
        }

        var parsed = try parseConfig()
        guard let section = parsed.providerSections.first(where: { $0.id == id }) else {
            throw ServiceError.providerNotFound
        }

        var start = section.startLine
        var end = section.endLine
        if start > 0 && parsed.lines[start - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            start -= 1
        } else if end + 1 < parsed.lines.count && parsed.lines[end + 1].trimmingCharacters(in: .whitespaces).isEmpty {
            end += 1
        }
        parsed.lines.removeSubrange(start...end)
        try writeConfig(lines: parsed.lines)

        var defaults = loadDefaultsStore()
        defaults.defaultModels.removeValue(forKey: id)
        try saveDefaultsStore(defaults)
        removeProviderSecret(providerID: id, envKey: section.envKey)

        return try loadState()
    }

    private func normalizedProvider(_ provider: CodexProviderConfig) throws -> CodexProviderConfig {
        let id = provider.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = provider.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultModel = provider.defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !id.isEmpty else { throw ServiceError.missingRequiredField("Provider ID") }
        guard id.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
            throw ServiceError.invalidProviderID
        }
        guard !name.isEmpty else { throw ServiceError.missingRequiredField("名称") }
        guard !baseURL.isEmpty else { throw ServiceError.missingRequiredField("Base URL") }
        guard !defaultModel.isEmpty else { throw ServiceError.missingRequiredField("默认模型") }

        let envKey = Self.environmentVariableName(forProviderID: id)

        return CodexProviderConfig(
            id: id,
            name: name,
            baseURL: baseURL,
            envKey: envKey,
            defaultModel: defaultModel,
            isBuiltIn: provider.isBuiltIn
        )
    }

    private func inferredDefaultModel(for providerID: String, parsed: ParsedConfig) -> String {
        if parsed.currentProviderID == providerID {
            return parsed.currentModel
        }
        if parsed.providerSections.count == 1, !parsed.currentModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return parsed.currentModel
        }
        return ""
    }

    private func parseConfig() throws -> ParsedConfig {
        guard fileManager.fileExists(atPath: configURL.path) else {
            throw ServiceError.missingConfig
        }
        let content = try String(contentsOf: configURL, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)
        var parsed = ParsedConfig(lines: lines)

        var currentSectionPath: String?
        var sectionStartLine: Int?
        var sectionID: String?

        func finishSection(endLine: Int) {
            guard
                let currentSectionPath,
                currentSectionPath.hasPrefix("model_providers."),
                let sectionStartLine,
                let sectionID
            else { return }

            var section = ParsedProviderSection(id: sectionID, startLine: sectionStartLine, endLine: endLine)
            if sectionStartLine + 1 <= endLine {
                for line in lines[(sectionStartLine + 1)...endLine] {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty || trimmed.hasPrefix("#") {
                        section.extraLines.append(line)
                        continue
                    }
                    if let (key, value) = parseKeyValue(from: trimmed) {
                        switch key {
                        case "name":
                            section.name = value
                        case "base_url":
                            section.baseURL = value
                        case "env_key":
                            section.envKey = value
                        case "wire_api":
                            break
                        default:
                            section.extraLines.append(line)
                        }
                    } else {
                        section.extraLines.append(line)
                    }
                }
            }
            parsed.providerSections.append(section)
        }

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let path = sectionPath(for: trimmed) {
                if sectionStartLine != nil {
                    finishSection(endLine: index - 1)
                }
                currentSectionPath = path
                sectionStartLine = index
                if path.hasPrefix("model_providers.") {
                    sectionID = String(path.dropFirst("model_providers.".count))
                } else {
                    sectionID = nil
                }
                continue
            }

            if currentSectionPath == nil, let (key, value) = parseKeyValue(from: trimmed) {
                switch key {
                case "model":
                    parsed.currentModel = value
                case "model_provider":
                    parsed.currentProviderID = value
                default:
                    break
                }
            }
        }

        if sectionStartLine != nil {
            finishSection(endLine: lines.count - 1)
        }

        return parsed
    }

    private func parseKeyValue(from trimmedLine: String) -> (String, String)? {
        guard
            let equalsIndex = trimmedLine.firstIndex(of: "=")
        else { return nil }

        let key = trimmedLine[..<equalsIndex].trimmingCharacters(in: .whitespaces)
        let valuePortion = trimmedLine[trimmedLine.index(after: equalsIndex)...].trimmingCharacters(in: .whitespaces)
        guard valuePortion.first == "\"", valuePortion.last == "\"" else { return nil }
        let start = valuePortion.index(after: valuePortion.startIndex)
        let end = valuePortion.index(before: valuePortion.endIndex)
        return (String(key), unescape(String(valuePortion[start..<end])))
    }

    private func providerInsertionIndex(in lines: [String]) -> Int {
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let path = sectionPath(for: trimmed) else { continue }
            if !path.hasPrefix("model_providers.") {
                return index
            }
        }
        return lines.count
    }

    private func renderSection(
        id: String,
        name: String,
        baseURL: String,
        envKey: String,
        extraLines: [String]
    ) -> [String] {
        var block = [
            "[model_providers.\(id)]",
            "name = \"\(escape(name))\"",
            "base_url = \"\(escape(baseURL))\"",
            "env_key = \"\(escape(envKey))\"",
            "wire_api = \"responses\""
        ]
        let preserved = extraLines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty || trimmed.hasPrefix("#")
        }
        if !preserved.isEmpty {
            block.append(contentsOf: preserved)
        }
        return block
    }

    private func setTopLevel(key: String, value: String, in lines: inout [String]) {
        var currentSectionPath: String?

        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if let path = sectionPath(for: trimmed) {
                currentSectionPath = path
                continue
            }
            guard currentSectionPath == nil else { continue }
            if let (existingKey, _) = parseKeyValue(from: trimmed), existingKey == key {
                lines[index] = "\(key) = \"\(escape(value))\""
                return
            }
        }

        let insertionIndex = lines.firstIndex { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return sectionPath(for: trimmed) != nil
        } ?? lines.count
        lines.insert("\(key) = \"\(escape(value))\"", at: insertionIndex)
    }

    private func writeConfig(lines: [String]) throws {
        let content = lines.joined(separator: "\n")
        try content.write(to: configURL, atomically: true, encoding: .utf8)
    }

    private func loadDefaultsStore() -> DefaultsStore {
        guard
            let data = try? Data(contentsOf: defaultsURL),
            let store = try? JSONDecoder().decode(DefaultsStore.self, from: data)
        else {
            return DefaultsStore()
        }
        return store
    }

    private func saveDefaultsStore(_ store: DefaultsStore) throws {
        try fileManager.createDirectory(
            at: defaultsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        let data = try JSONEncoder().encode(store)
        try data.write(to: defaultsURL, options: .atomic)
    }

    private func sectionPath(for trimmedLine: String) -> String? {
        guard trimmedLine.first == "[", trimmedLine.last == "]" else { return nil }
        let start = trimmedLine.index(after: trimmedLine.startIndex)
        let end = trimmedLine.index(before: trimmedLine.endIndex)
        let path = trimmedLine[start..<end].trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : path
    }

    private func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func unescape(_ value: String) -> String {
        var result = ""
        var isEscaping = false
        for character in value {
            if isEscaping {
                result.append(character)
                isEscaping = false
            } else if character == "\\" {
                isEscaping = true
            } else {
                result.append(character)
            }
        }
        if isEscaping {
            result.append("\\")
        }
        return result
    }

    private func apiKeyStorageKey(for providerID: String) -> String {
        "codex_provider_api_key_\(providerID)"
    }

    private func syncProviderSecret(
        providerID: String,
        envKey: String,
        previousEnvKey: String?,
        apiKey: String?
    ) throws {
        let keychainKey = apiKeyStorageKey(for: providerID)
        let currentAPIKey = apiKey ?? (try? KeychainService.retrieve(key: keychainKey)) ?? ""

        if let previousEnvKey, previousEnvKey != envKey, !previousEnvKey.isEmpty {
            try launchctlUnsetenv(previousEnvKey)
        }

        if currentAPIKey.isEmpty {
            KeychainService.delete(key: keychainKey)
            if !envKey.isEmpty {
                try launchctlUnsetenv(envKey)
            }
            return
        }

        try KeychainService.store(key: keychainKey, value: currentAPIKey)
        if !envKey.isEmpty {
            try launchctlSetenv(envKey, value: currentAPIKey)
        }
    }

    private func removeProviderSecret(providerID: String, envKey: String) {
        KeychainService.delete(key: apiKeyStorageKey(for: providerID))
        if !envKey.isEmpty {
            try? launchctlUnsetenv(envKey)
        }
    }

    private func launchctlSetenv(_ key: String, value: String) throws {
        let result = try runProcess("/bin/launchctl", arguments: ["setenv", key, value])
        guard result.terminationStatus == 0 else {
            throw ServiceError.launchctlFailed("写入 launchctl 环境变量失败：\(key)")
        }
    }

    private func launchctlUnsetenv(_ key: String) throws {
        let result = try runProcess("/bin/launchctl", arguments: ["unsetenv", key])
        guard result.terminationStatus == 0 else {
            throw ServiceError.launchctlFailed("删除 launchctl 环境变量失败：\(key)")
        }
    }

    private func runProcess(_ launchPath: String, arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process
    }
}
