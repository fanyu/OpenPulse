import Foundation
import Testing

@testable import OpenPulse

final class RouterMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responseStatus: Int = 200
    nonisolated(unsafe) static var responseBody: Data = Data()
    nonisolated(unsafe) static var responseError: Error?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let responseError = Self.responseError {
            client?.urlProtocol(self, didFailWithError: responseError)
            return
        }

        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: Self.responseStatus,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct CodexRouterIntegrationTests {
    @Test
    func coordinatorReturnsReadyWhenRouterConfigAndHealthPass() async throws {
        let fixtures = try createFixtures(includeRouterSection: true, modelProvider: "codex-router")
        defer { cleanup(fixtures.rootURL) }

        let session = makeSession(responsePayload: ["service": "codex-router"])

        let coordinator = CodexRouterCoordinator(
            fileManager: FileManager.default,
            session: session,
            configURL: fixtures.configURL
        )
        await coordinator.setUserEnabled(true)
        RouterMockURLProtocol.responseStatus = 200
        RouterMockURLProtocol.responseBody = try JSONSerialization.data(withJSONObject: ["service": "codex-router"])

        let status = await coordinator.loadStatus()

        #expect(status.isConfigured)
        #expect(status.isUserEnabled)
        #expect(status.isRouterHealthy)
        #expect(status.canUseRouter)
        #expect(status.currentModelProvider == "codex-router")
        #expect(status.healthService == "codex-router")
        #expect(status.statusText == "Router 已就绪")
    }

    @Test
    func coordinatorFailsWhenHealthServiceMismatches() async throws {
        let fixtures = try createFixtures(includeRouterSection: true, modelProvider: "codex-router")
        defer { cleanup(fixtures.rootURL) }

        let session = makeSession(responsePayload: ["service": "not-codex-router"])
        let coordinator = CodexRouterCoordinator(
            fileManager: FileManager.default,
            session: session,
            configURL: fixtures.configURL
        )
        await coordinator.setUserEnabled(true)
        RouterMockURLProtocol.responseStatus = 200
        RouterMockURLProtocol.responseBody = try JSONSerialization.data(withJSONObject: ["service": "not-codex-router"])

        let status = await coordinator.loadStatus()

        #expect(status.isConfigured)
        #expect(status.isUserEnabled)
        #expect(!status.isRouterHealthy)
        #expect(!status.canUseRouter)
        #expect(status.healthService == "not-codex-router")
        #expect(status.healthError == "服务类型不匹配：not-codex-router")
        #expect(status.statusText == "Router 健康检查失败：服务类型不匹配：not-codex-router")
    }

    @Test
    func coordinatorParsesOpenAIBaseURLWithInlineComment() async throws {
        let fixtures = try createFixtures(includeRouterSection: true, modelProvider: "codex-router")
        defer { cleanup(fixtures.rootURL) }

        var configContent = try String(contentsOf: fixtures.configURL, encoding: .utf8)
        configContent = configContent.replacingOccurrences(
            of: "openai_base_url = \"http://127.0.0.1:12345\"",
            with: "openai_base_url = \"http://127.0.0.1:12345\" # inline comment"
        )
        try configContent.write(to: fixtures.configURL, atomically: true, encoding: .utf8)

        let session = makeSession(responsePayload: ["service": "codex-router"])
        let coordinator = CodexRouterCoordinator(
            fileManager: FileManager.default,
            session: session,
            configURL: fixtures.configURL
        )
        await coordinator.setUserEnabled(true)
        RouterMockURLProtocol.responseStatus = 200
        RouterMockURLProtocol.responseBody = try JSONSerialization.data(withJSONObject: ["service": "codex-router"])

        let status = await coordinator.loadStatus()

        #expect(status.isRouterHealthy)
        #expect(status.canUseRouter)
        #expect(status.healthError == nil)
    }

    @Test
    func coordinatorExpandsOpenAIBaseURLVariable() async throws {
        let fixtures = try createFixtures(includeRouterSection: true, modelProvider: "codex-router")
        defer { cleanup(fixtures.rootURL) }

        let variableName = "OPENPULSE_ROUTER_BASE_URL"
        let previousValue = ProcessInfo.processInfo.environment[variableName]
        setenv(variableName, "http://127.0.0.1:12345", 1)
        defer {
            if let previousValue {
                setenv(variableName, previousValue, 1)
            } else {
                unsetenv(variableName)
            }
        }

        var configContent = try String(contentsOf: fixtures.configURL, encoding: .utf8)
        configContent = configContent.replacingOccurrences(
            of: "openai_base_url = \"http://127.0.0.1:12345\"",
            with: "openai_base_url = \"${OPENPULSE_ROUTER_BASE_URL}\""
        )
        try configContent.write(to: fixtures.configURL, atomically: true, encoding: .utf8)

        let session = makeSession(responsePayload: ["service": "codex-router"])
        let coordinator = CodexRouterCoordinator(
            fileManager: FileManager.default,
            session: session,
            configURL: fixtures.configURL
        )
        await coordinator.setUserEnabled(true)
        RouterMockURLProtocol.responseStatus = 200
        RouterMockURLProtocol.responseBody = try JSONSerialization.data(withJSONObject: ["service": "codex-router"])

        let status = await coordinator.loadStatus()

        #expect(status.isRouterHealthy)
        #expect(status.canUseRouter)
        #expect(status.healthError == nil)
    }

    @Test
    func coordinatorHonorsUserDisabledRouter() async throws {
        let fixtures = try createFixtures(includeRouterSection: true, modelProvider: "codex-router")
        defer { cleanup(fixtures.rootURL) }
        let preferenceKey = CodexRouterConstants.userEnabledDefaultsKey
        let priorPreference = UserDefaults.standard.object(forKey: preferenceKey)

        let coordinator = CodexRouterCoordinator(
            fileManager: FileManager.default,
            configURL: fixtures.configURL
        )
        defer {
            if let priorPreference {
                UserDefaults.standard.set(priorPreference, forKey: preferenceKey)
            } else {
                UserDefaults.standard.removeObject(forKey: preferenceKey)
            }
        }

        await coordinator.setUserEnabled(false)
        let status = await coordinator.loadStatus()

        #expect(status.isConfigured)
        #expect(!status.isUserEnabled)
        #expect(!status.isRouterHealthy)
        #expect(!status.canUseRouter)
        #expect(status.statusText == "Router 已关闭（可在 Provider 中开启）")
    }

    @Test
    func providerSwitchUsesCodexRouterForThirdPartyAndOpenAIDirectly() async throws {
        let fixtures = try createFixtures(
            includeRouterSection: true,
            modelProvider: "openai",
            includeThirdParty: true
        )
        defer { cleanup(fixtures.rootURL) }

        let service = CodexProviderConfigService(
            fileManager: FileManager.default,
            configURL: fixtures.configURL,
            defaultsURL: fixtures.defaultsURL
        )
        _ = try await service.saveProvider(
            CodexProviderConfig(
                id: "mimo",
                name: "Mimo",
                baseURL: "https://api.mimo.ai",
                envKey: "OPENPULSE_CODEX_MIMO_API_KEY",
                defaultModel: "mimo-basic",
                isBuiltIn: false
            ),
            apiKey: nil
        )

        let withThirdParty = try await service.switchProvider(id: "mimo", allowThirdParty: true)
        let afterThirdPartyContent = try String(contentsOf: fixtures.configURL, encoding: .utf8)

        #expect(withThirdParty.currentProviderID == "mimo")
        #expect(afterThirdPartyContent.contains("model_provider = \"codex-router\""))
        #expect(afterThirdPartyContent.contains("model = \"mimo-basic\""))

        let backToOpenAI = try await service.switchProvider(id: "openai", allowThirdParty: true)
        let afterOpenAIContent = try String(contentsOf: fixtures.configURL, encoding: .utf8)

        #expect(backToOpenAI.currentProviderID == "openai")
        #expect(afterOpenAIContent.contains("model_provider = \"openai\""))
        #expect(afterOpenAIContent.contains("model = \"gpt-5.5\""))
    }

    @Test
    func providerSwitchRejectsThirdPartyWithoutRouterConfig() async throws {
        let fixtures = try createFixtures(includeRouterSection: false, modelProvider: "openai", includeThirdParty: true)
        defer { cleanup(fixtures.rootURL) }

        let service = CodexProviderConfigService(
            fileManager: FileManager.default,
            configURL: fixtures.configURL,
            defaultsURL: fixtures.defaultsURL
        )
        let state = try await service.loadState()
        #expect(state.providers.contains(where: { $0.id == "mimo" }))

        do {
            _ = try await service.switchProvider(id: "mimo", allowThirdParty: true)
            #expect(Bool(false))
        } catch {
            #expect(error.localizedDescription == "未检测到 codex-router 配置。请先按 codex-router 指南完成安装后再切换。")
        }
    }

    private func createFixtures(
        includeRouterSection: Bool,
        modelProvider: String,
        includeThirdParty: Bool = false
    ) throws -> (
        rootURL: URL,
        configURL: URL,
        defaultsURL: URL
    ) {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appending(path: "OpenPulse-RouterFixtures-\(UUID().uuidString)")
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let codexDir = rootURL.appending(path: ".codex")
        try fileManager.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let catalogURL = codexDir
            .appending(path: "codex-router")
            .appending(path: "merged-models.json")
        try fileManager.createDirectory(at: catalogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{}".data(using: .utf8)!.write(to: catalogURL)

        let configURL = codexDir.appending(path: "config.toml")
        let defaultsURL = rootURL.appending(path: ".openpulse/codex-provider-default-models.json")
        try fileManager.createDirectory(at: defaultsURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let defaultsStore: [String: Any] = [
            "selectedProviderID": "openai",
            "defaultModels": ["openai": "gpt-5.5", "mimo": "mimo-basic"],
        ]
        let defaultsData = try JSONSerialization.data(withJSONObject: defaultsStore)
        try defaultsData.write(to: defaultsURL)

        var lines: [String] = []
        if includeRouterSection {
            lines.append("# BEGIN codex-router-managed")
            lines.append("openai_base_url = \"http://127.0.0.1:12345\"")
            lines.append("model_catalog_json = \"\(catalogURL.path)\"")
        }
        lines.append(contentsOf: [
            "model_provider = \"\(modelProvider)\"",
            "model = \"gpt-5.5\"",
            "",
            "[model_providers.openai]",
            "name = \"OpenAI\"",
            "base_url = \"https://api.openai.com/v1\"",
            "env_key = \"OPENAI_API_KEY\"",
            "wire_api = \"responses\"",
            ""
        ])

        if includeRouterSection {
            lines.append(contentsOf: [
                "[model_providers.codex-router]",
                "name = \"codex-router\"",
                "base_url = \"http://127.0.0.1:12345\"",
                "env_key = \"OPENAI_API_KEY\"",
                "wire_api = \"responses\"",
                ""
            ])
        }

        if includeThirdParty {
            lines.append(contentsOf: [
                "[model_providers.mimo]",
                "name = \"Mimo\"",
                "base_url = \"https://api.mimo.ai\"",
                "env_key = \"OPENPULSE_CODEX_MIMO_API_KEY\"",
                "wire_api = \"responses\"",
                ""
            ])
        }

        let configContent = lines.joined(separator: "\n")
        try configContent.data(using: .utf8)!.write(to: configURL)

        return (rootURL: rootURL, configURL: configURL, defaultsURL: defaultsURL)
    }

    private func makeSession(responsePayload: [String: String]?) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RouterMockURLProtocol.self]
        RouterMockURLProtocol.responseError = nil
        RouterMockURLProtocol.responseStatus = 200
        if let responsePayload {
            RouterMockURLProtocol.responseBody = (try? JSONSerialization.data(withJSONObject: responsePayload)) ?? Data()
        } else {
            RouterMockURLProtocol.responseBody = Data()
        }
        return URLSession(configuration: configuration)
    }

    private func cleanup(_ rootURL: URL) {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
