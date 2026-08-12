import Foundation

enum CodexRouterConstants {
    static let openAIProviderID = "openai"
    static let codexRouterProviderID = "codex-router"
    static let userEnabledDefaultsKey = "codex.router.enabled"
    static let expectedHealthService = "codex-router"
    static let defaultCatalogPath = URL.homeDirectory
        .appending(path: ".codex/codex-router/merged-models.json").path
}

struct CodexRouterStatus: Sendable {
    let isManaged: Bool
    let hasConfiguredProviderSection: Bool
    let openAIBaseURL: String?
    let modelCatalogPath: String?
    let catalogFileExists: Bool
    let currentModelProvider: String
    let currentModel: String
    let isUserEnabled: Bool
    let isRouterHealthy: Bool
    let healthService: String?
    let healthError: String?
    let lastCheckedAt: Date?

    var hasBaseConfig: Bool {
        !(openAIBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    var isConfigured: Bool {
        isManaged || (hasConfiguredProviderSection && hasBaseConfig)
    }

    var canUseRouter: Bool {
        isConfigured && isUserEnabled && isRouterHealthy
    }

    var canSelectThirdParty: Bool {
        canUseRouter && !currentModelProvider.isEmpty
    }

    var statusText: String {
        if !isConfigured {
            return "未检测到 codex-router 配置"
        }
        if !isUserEnabled {
            return "Router 已关闭（可在 Provider 中开启）"
        }
        if !isRouterHealthy {
            if let healthError {
                return "Router 健康检查失败：\(healthError)"
            }
            return "Router 健康检查失败"
        }
        return "Router 已就绪"
    }
}

    private struct ParsedCodexConfig {
        var openAIBaseURL: String?
        var modelCatalogPath: String?
        var modelProvider: String = CodexRouterConstants.openAIProviderID
        var currentModel: String = ""
        var hasManagedMarker: Bool = false
        var hasCodexRouterProviderSection: Bool = false

    var isManagedLikeRouterConfig: Bool {
        if let value = openAIBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return hasManagedMarker || value.contains("http://127.0.0.1") || value.contains("http://localhost")
        }
        return false
    }
}

actor CodexRouterCoordinator {
    private struct HealthResponse: Decodable {
        let service: String?
    }

    private let configURL: URL
    private let fileManager: FileManager
    private let session: URLSession
    private let userDefaults: UserDefaults

    init(
        fileManager: FileManager = .default,
        session: URLSession = .shared,
        userDefaults: UserDefaults = .standard,
        configURL: URL? = nil
    ) {
        self.configURL = configURL ?? URL.homeDirectory.appending(path: ".codex/config.toml")
        self.fileManager = fileManager
        self.session = session
        self.userDefaults = userDefaults
    }

    func setUserEnabled(_ enabled: Bool) {
        userDefaults.set(enabled, forKey: CodexRouterConstants.userEnabledDefaultsKey)
    }

    func loadStatus() async -> CodexRouterStatus {
        let parsed = parseConfig()
        let explicitEnabled = userDefaults.object(forKey: CodexRouterConstants.userEnabledDefaultsKey) as? Bool
        let isUserEnabled = explicitEnabled ?? false

        guard isUserEnabled else {
            return CodexRouterStatus(
                isManaged: parsed.isManagedLikeRouterConfig,
                hasConfiguredProviderSection: parsed.hasCodexRouterProviderSection,
                openAIBaseURL: parsed.openAIBaseURL,
                modelCatalogPath: parsed.modelCatalogPath,
                catalogFileExists: catalogExists(parsed.modelCatalogPath),
                currentModelProvider: parsed.modelProvider,
                currentModel: parsed.currentModel,
                isUserEnabled: false,
                isRouterHealthy: false,
                healthService: nil,
                healthError: nil,
                lastCheckedAt: Date()
            )
        }

        guard let openAIBaseURL = parsed.openAIBaseURL, let healthURL = makeHealthURL(from: openAIBaseURL) else {
            return CodexRouterStatus(
                isManaged: parsed.isManagedLikeRouterConfig,
                hasConfiguredProviderSection: parsed.hasCodexRouterProviderSection,
                openAIBaseURL: parsed.openAIBaseURL,
                modelCatalogPath: parsed.modelCatalogPath,
                catalogFileExists: catalogExists(parsed.modelCatalogPath),
                currentModelProvider: parsed.modelProvider,
                currentModel: parsed.currentModel,
                isUserEnabled: true,
                isRouterHealthy: false,
                healthService: nil,
                healthError: "无法从 openai_base_url 解析健康检查地址",
                lastCheckedAt: Date()
            )
        }

        let health = await probeHealth(url: healthURL)
        return CodexRouterStatus(
            isManaged: parsed.isManagedLikeRouterConfig,
            hasConfiguredProviderSection: parsed.hasCodexRouterProviderSection,
            openAIBaseURL: parsed.openAIBaseURL,
            modelCatalogPath: parsed.modelCatalogPath,
            catalogFileExists: catalogExists(parsed.modelCatalogPath),
            currentModelProvider: parsed.modelProvider,
            currentModel: parsed.currentModel,
            isUserEnabled: true,
            isRouterHealthy: health.ok,
            healthService: health.service,
            healthError: health.error,
            lastCheckedAt: Date()
        )
    }

    private func parseConfig() -> ParsedCodexConfig {
        guard fileManager.fileExists(atPath: configURL.path),
              let content = try? String(contentsOf: configURL, encoding: .utf8)
        else {
            return ParsedCodexConfig()
        }

        var result = ParsedCodexConfig()
        var currentSectionPath: String?
        let codexRouterSectionPath = "model_providers.\(CodexRouterConstants.codexRouterProviderID)"

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# BEGIN codex-router-managed") {
                result.hasManagedMarker = true
            }
            if let sectionPath = parseSectionPath(from: trimmed) {
                currentSectionPath = sectionPath
                if sectionPath
                    .lowercased()
                    .caseInsensitiveCompare(codexRouterSectionPath) == .orderedSame
                {
                    result.hasCodexRouterProviderSection = true
                }
                continue
            }
            guard let (key, value) = parseKeyValue(from: trimmed) else { continue }
            let normalizedKey = key.lowercased()
            let isInCodexRouterSection = currentSectionPath?.lowercased() == codexRouterSectionPath
            let acceptRootOrRouterSection = currentSectionPath == nil || isInCodexRouterSection
            let atRoot = currentSectionPath == nil
            switch normalizedKey {
            case "openai_base_url" where acceptRootOrRouterSection:
                if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.openAIBaseURL = value
                }
            case "base_url" where isInCodexRouterSection:
                if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && result.openAIBaseURL == nil {
                    result.openAIBaseURL = value
                }
            case "model_catalog_json" where acceptRootOrRouterSection:
                let trimmedPath = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedPath.isEmpty {
                    result.modelCatalogPath = trimmedPath
                }
            case "model_provider" where atRoot:
                result.modelProvider = value
            case "model" where atRoot:
                result.currentModel = value
            default:
                break
            }
        }

        if (result.openAIBaseURL == nil || result.openAIBaseURL!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
           let envURL = ProcessInfo.processInfo.environment["OPENAI_BASE_URL"],
           !envURL.isEmpty
        {
            result.openAIBaseURL = normalizeBaseURL(envURL)
        }

        if result.modelCatalogPath == nil || result.modelCatalogPath!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.modelCatalogPath = CodexRouterConstants.defaultCatalogPath
        }

        return result
    }

    private func catalogExists(_ path: String?) -> Bool {
        guard let path else { return false }
        if !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return fileManager.fileExists(atPath: path)
        }
        return fileManager.fileExists(atPath: CodexRouterConstants.defaultCatalogPath)
    }

    private func makeHealthURL(from baseURL: String) -> URL? {
        let normalizedBase = normalizeBaseURL(baseURL)
        guard var components = URLComponents(string: normalizedBase) else { return nil }
        components.path = "/health"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private func normalizeBaseURL(_ baseURL: String) -> String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if URLComponents(string: trimmed)?.scheme == nil {
            return "http://\(trimmed)"
        }
        return trimmed
    }

    private func parseKeyValue(from trimmedLine: String) -> (String, String)? {
        guard let equalsIndex = trimmedLine.firstIndex(of: "=") else { return nil }
        let key = trimmedLine[..<equalsIndex].trimmingCharacters(in: .whitespaces)
        let rawValue = String(trimmedLine[trimmedLine.index(after: equalsIndex)...])
        let valuePortion = stripInlineComment(from: rawValue).trimmingCharacters(in: .whitespaces)
        guard !valuePortion.isEmpty else { return nil }
        guard valuePortion.first == "\"" && valuePortion.last == "\"" ||
              valuePortion.first == "'" && valuePortion.last == "'" else {
            return (key, expandVariables(in: unescape(valuePortion)))
        }
        let start = valuePortion.index(after: valuePortion.startIndex)
        let end = valuePortion.index(before: valuePortion.endIndex)
        let unquoted = String(valuePortion[start..<end])
        return (key, expandVariables(in: unescape(unquoted)))
    }

    private func stripInlineComment(from line: String) -> String {
        var inSingleQuote = false
        var inDoubleQuote = false
        var escaping = false
        var parsed = ""

        for scalar in line.unicodeScalars {
            if escaping {
                parsed.append(String(scalar))
                escaping = false
                continue
            }
            if scalar == "\\" {
                escaping = true
                parsed.append(String(scalar))
                continue
            }
            if scalar == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
            } else if scalar == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
            } else if scalar == "#" && !inSingleQuote && !inDoubleQuote {
                break
            }
            parsed.append(String(scalar))
        }

        return parsed
    }

    private func expandVariables(in value: String) -> String {
        let pattern = #"\$\{([A-Za-z_][A-Za-z0-9_]*)\}"#
        let altPattern = #"\$([A-Za-z_][A-Za-z0-9_]*)"#
        let withBraces = replaceVariableTokens(in: value, pattern: pattern)
        return replaceVariableTokens(in: withBraces, pattern: altPattern)
    }

    private func replaceVariableTokens(in value: String, pattern: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return value
        }

        let range = NSRange(location: 0, length: value.utf16.count)
        var result = value
        let matches = regex.matches(in: result, options: [], range: range).reversed()
        guard !matches.isEmpty else { return value }
        for match in matches {
            let tokenRange = match.range(at: 0)
            let keyRange = match.range(at: 1)
            guard
                let tokenRangeInResult = Range(tokenRange, in: result),
                let keyRangeInResult = Range(keyRange, in: result)
            else { continue }
            let key = String(result[keyRangeInResult])
            let replacement = ProcessInfo.processInfo.environment[key] ?? ""
            result.replaceSubrange(tokenRangeInResult, with: replacement)
        }
        return result
    }

    private func parseSectionPath(from trimmedLine: String) -> String? {
        guard trimmedLine.first == "[", trimmedLine.last == "]" else { return nil }
        let start = trimmedLine.index(after: trimmedLine.startIndex)
        let end = trimmedLine.index(before: trimmedLine.endIndex)
        let path = trimmedLine[start..<end].trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : path
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
        if isEscaping { result.append("\\") }
        return result
    }

    private func probeHealth(url: URL) async -> (ok: Bool, service: String?, error: String?) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 3
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
                return (false, nil, "健康检查返回非 2xx")
            }
            let payload = try JSONDecoder().decode(HealthResponse.self, from: data)
            let service = payload.service
            if service == nil {
                return (false, nil, "健康返回缺少 service 字段")
            }
            if service != CodexRouterConstants.expectedHealthService {
                return (false, service, "服务类型不匹配：\(service ?? "unknown")")
            }
            return (true, service, nil)
        } catch {
            return (false, nil, error.localizedDescription)
        }
    }
}
