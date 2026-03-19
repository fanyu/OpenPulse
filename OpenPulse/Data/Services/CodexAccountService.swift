import Foundation
import AppKit
import CryptoKit
import Network
import Security

actor CodexAccountService {
    private enum OAuthConfiguration {
        static let issuer = URL(string: "https://auth.openai.com")!
        static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
        static let originator = "codex_cli_rs"
        static let callbackPath = "/auth/callback"
        static let callbackPort: UInt16 = 1455
        static let maxPortOffset: UInt16 = 12
        static let scopes = "openid profile email offline_access api.connectors.read api.connectors.invoke"
    }

    private enum UsageRefreshPolicy {
        static let minimumRefreshInterval: TimeInterval = 25

        static func shouldRefresh(lastFetchedAt: Date?, now: Date) -> Bool {
            guard let lastFetchedAt else { return true }
            return now.timeIntervalSince(lastFetchedAt) >= minimumRefreshInterval
        }
    }

    private enum ServiceError: LocalizedError {
        case invalidAuthFile
        case missingAccountID
        case callbackOpenFailed
        case callbackFailed(String)
        case accountNotFound

        var errorDescription: String? {
            switch self {
            case .invalidAuthFile: "Codex auth.json 格式无效。"
            case .missingAccountID: "未能从 Codex 认证信息中提取账号 ID。"
            case .callbackOpenFailed: "无法打开浏览器完成 OpenAI 登录。"
            case .callbackFailed(let message): message
            case .accountNotFound: "未找到对应的 Codex 账号。"
            }
        }
    }

    private struct ExtractedAuth: Sendable {
        let accountID: String
        let accessToken: String
        let email: String?
        let planType: String?
        let teamName: String?
    }

    private struct TokenExchangeResponse: Decodable {
        let accessToken: String
        let refreshToken: String
        let idToken: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case idToken = "id_token"
        }
    }

    private struct APIKeyExchangeResponse: Decodable {
        let accessToken: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
        }
    }

    private let fileManager: FileManager
    private let session: URLSession
    private let supportDir: URL
    private let storeURL: URL
    private let codexAuthURL: URL
    private let codexConfigURL: URL

    init(fileManager: FileManager = .default, session: URLSession = .shared) {
        self.fileManager = fileManager
        self.session = session
        supportDir = URL.homeDirectory.appending(path: ".openpulse")
        storeURL = supportDir.appending(path: "codex-accounts.json")
        codexAuthURL = URL.homeDirectory.appending(path: ".codex/auth.json")
        codexConfigURL = URL.homeDirectory.appending(path: ".codex/config.toml")
    }

    func listAccounts() async -> [CodexAccountSnapshot] {
        let store = loadStore()
        let currentAccountID = currentAccountID(from: store)
        return store.accounts.map {
            CodexAccountSnapshot(
                id: $0.id,
                label: $0.label,
                email: $0.email,
                accountID: $0.accountID,
                planType: $0.planType,
                teamName: $0.teamName,
                addedAt: $0.addedAt,
                updatedAt: $0.updatedAt,
                lastFetchedAt: $0.lastFetchedAt,
                limits: $0.lastUsage,
                usageError: $0.usageError,
                isCurrent: currentAccountID == $0.accountID
            )
        }
        .sorted { lhs, rhs in
            if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent && !rhs.isCurrent }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }
    }

    func importCurrentAuth(customLabel: String? = nil) async throws {
        let auth = try readCurrentAuthString()
        _ = try upsertAccount(authJSONString: auth, customLabel: customLabel, setAsCurrent: true)
    }

    func addAccountViaOAuth(customLabel: String? = nil, timeoutSeconds: TimeInterval = 600) async throws {
        let tokens = try await signInWithChatGPT(timeoutSeconds: timeoutSeconds)
        let authJSONString = try await makeChatGPTAuthJSONString(tokens: tokens)
        _ = try upsertAccount(authJSONString: authJSONString, customLabel: customLabel, setAsCurrent: false)
    }

    func switchAccount(id: String) async throws {
        var store = loadStore()
        guard let account = store.accounts.first(where: { $0.id == id }) else {
            throw ServiceError.accountNotFound
        }
        try writeCurrentAuthString(account.authJSONString)
        store.currentAccountID = account.accountID
        saveStore(store)
    }

    func deleteAccount(id: String) {
        var store = loadStore()
        if let removed = store.accounts.first(where: { $0.id == id }), store.currentAccountID == removed.accountID {
            store.currentAccountID = currentAuthAccountID()
        }
        store.accounts.removeAll { $0.id == id }
        saveStore(store)
    }

    func refreshAllUsage(force: Bool = false) async -> [CodexAccountSnapshot] {
        let now = Date()
        var store = reconcileCurrentAuthIntoStore()
        let usageURLs = resolveUsageURLs()
        let accounts = store.accounts

        let refreshedAccounts = await withTaskGroup(of: CodexStoredAccount.self, returning: [CodexStoredAccount].self) { group in
            for account in accounts {
                group.addTask { [session] in
                    await Self.refreshAccount(
                        account,
                        now: now,
                        forceRefresh: force,
                        session: session,
                        usageURLs: usageURLs
                    )
                }
            }

            var refreshed: [CodexStoredAccount] = []
            refreshed.reserveCapacity(accounts.count)
            for await account in group {
                refreshed.append(account)
            }
            return refreshed
        }

        let refreshedByAccountID = Dictionary(uniqueKeysWithValues: refreshedAccounts.map { ($0.accountID, $0) })
        store.accounts = store.accounts.map { refreshedByAccountID[$0.accountID] ?? $0 }
        store.currentAccountID = currentAccountID(from: store)
        saveStore(store)
        return await listAccounts()
    }

    func syncCurrentSelectionFromAuthFile() async {
        let store = reconcileCurrentAuthIntoStore()
        saveStore(store)
    }

    private func currentAccountID(from store: CodexAccountsStore) -> String? {
        if let current = currentAuthAccountID() { return current }
        return store.currentAccountID
    }

    private func reconcileCurrentAuthIntoStore() -> CodexAccountsStore {
        var store = loadStore()
        guard let authJSONString = try? readCurrentAuthString(),
              let extracted = try? extractAuth(from: authJSONString) else {
            store.currentAccountID = currentAuthAccountID()
            return store
        }

        let now = Date()
        if let index = store.accounts.firstIndex(where: { $0.accountID == extracted.accountID }) {
            store.accounts[index].email = extracted.email
            store.accounts[index].planType = extracted.planType
            store.accounts[index].teamName = extracted.teamName
            store.accounts[index].authJSONString = authJSONString
            store.accounts[index].updatedAt = now
        } else {
            store.accounts.append(
                CodexStoredAccount(
                    id: UUID().uuidString,
                    label: normalizedLabel(nil, email: extracted.email, teamName: extracted.teamName, accountID: extracted.accountID),
                    email: extracted.email,
                    accountID: extracted.accountID,
                    planType: extracted.planType,
                    teamName: extracted.teamName,
                    authJSONString: authJSONString,
                    addedAt: now,
                    updatedAt: now,
                    lastFetchedAt: nil,
                    lastUsage: nil,
                    usageError: nil
                )
            )
        }

        store.currentAccountID = extracted.accountID
        return store
    }

    private func upsertAccount(authJSONString: String, customLabel: String?, setAsCurrent: Bool) throws -> CodexStoredAccount {
        let extracted = try extractAuth(from: authJSONString)
        var store = loadStore()
        let now = Date()
        let label = normalizedLabel(customLabel, email: extracted.email, teamName: extracted.teamName, accountID: extracted.accountID)

        let account: CodexStoredAccount
        if let index = store.accounts.firstIndex(where: { $0.accountID == extracted.accountID }) {
            store.accounts[index].label = label
            store.accounts[index].email = extracted.email
            store.accounts[index].planType = extracted.planType
            store.accounts[index].teamName = extracted.teamName
            store.accounts[index].authJSONString = authJSONString
            store.accounts[index].updatedAt = now
            account = store.accounts[index]
        } else {
            let newAccount = CodexStoredAccount(
                id: UUID().uuidString,
                label: label,
                email: extracted.email,
                accountID: extracted.accountID,
                planType: extracted.planType,
                teamName: extracted.teamName,
                authJSONString: authJSONString,
                addedAt: now,
                updatedAt: now,
                lastFetchedAt: nil,
                lastUsage: nil,
                usageError: nil
            )
            store.accounts.append(newAccount)
            account = newAccount
        }

        if setAsCurrent {
            try writeCurrentAuthString(authJSONString)
            store.currentAccountID = extracted.accountID
        }

        saveStore(store)
        return account
    }

    private func normalizedLabel(_ customLabel: String?, email: String?, teamName: String?, accountID: String) -> String {
        let trimmed = customLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        if let teamName = teamName?.trimmingCharacters(in: .whitespacesAndNewlines), !teamName.isEmpty {
            return teamName
        }
        if let email, !email.isEmpty { return email }
        return "Codex \(String(accountID.prefix(8)))"
    }

    private func loadStore() -> CodexAccountsStore {
        guard fileManager.fileExists(atPath: storeURL.path),
              let data = try? Data(contentsOf: storeURL),
              let store = try? JSONDecoder().decode(CodexAccountsStore.self, from: data) else {
            return CodexAccountsStore()
        }
        return store
    }

    private func saveStore(_ store: CodexAccountsStore) {
        do {
            try fileManager.createDirectory(at: supportDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(store)
            try data.write(to: storeURL, options: .atomic)
            chmod(storeURL.path, S_IRUSR | S_IWUSR)
        } catch {
            print("[OpenPulse] Codex account store save failed: \(error.localizedDescription)")
        }
    }

    private func readCurrentAuthString() throws -> String {
        guard fileManager.fileExists(atPath: codexAuthURL.path) else {
            throw ServiceError.invalidAuthFile
        }
        return try String(decoding: Data(contentsOf: codexAuthURL), as: UTF8.self)
    }

    private func writeCurrentAuthString(_ jsonString: String) throws {
        let parent = codexAuthURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data(jsonString.utf8).write(to: codexAuthURL, options: .atomic)
        chmod(codexAuthURL.path, S_IRUSR | S_IWUSR)
    }

    private func currentAuthAccountID() -> String? {
        guard let jsonString = try? readCurrentAuthString() else { return nil }
        return try? extractAuth(from: jsonString).accountID
    }

    private func extractAuth(from jsonString: String) throws -> ExtractedAuth {
        try Self.extractAuth(from: jsonString)
    }

    private func decodeJWTPayload(_ token: String) throws -> [String: Any] {
        try Self.decodeJWTPayload(token)
    }

    private func extractTeamName(from auth: [String: Any], claims: [String: Any], accountIDHint: String?) -> String? {
        Self.extractTeamName(from: auth, claims: claims, accountIDHint: accountIDHint)
    }

    private func fetchUsage(accessToken: String, accountID: String) async throws -> CodexRateLimits {
        try await Self.fetchUsage(
            accessToken: accessToken,
            accountID: accountID,
            session: session,
            urls: resolveUsageURLs()
        )
    }

    private func signInWithChatGPT(timeoutSeconds: TimeInterval) async throws -> TokenExchangeResponse {
        let callback = OAuthCallbackBox<TokenExchangeResponse>()
        let verifier = Self.randomBase64URL(byteCount: 32)
        let challenge = Self.sha256Base64URL(verifier)
        let state = Self.randomBase64URL(byteCount: 32)
        let (server, port) = try makeCallbackServer(callback: callback, verifier: verifier, state: state)
        let redirectURI = "http://localhost:\(port)\(OAuthConfiguration.callbackPath)"
        let forcedWorkspaceID = resolveForcedWorkspaceID()
        let authorizeURL = try makeAuthorizeURL(
            redirectURI: redirectURI,
            challenge: challenge,
            state: state,
            forcedWorkspaceID: forcedWorkspaceID
        )

        try await server.start()
        defer { server.stop() }

        guard NSWorkspace.shared.open(authorizeURL) else {
            throw ServiceError.callbackOpenFailed
        }

        let tokens = try await callback.wait(timeoutSeconds: timeoutSeconds)
        if let forcedWorkspaceID {
            let accountID = try extractAccountID(fromIDToken: tokens.idToken)
            guard accountID == forcedWorkspaceID else {
                throw ServiceError.callbackFailed("登录账号与配置中的 forced_chatgpt_workspace_id 不一致。")
            }
        }
        return tokens
    }

    private func makeCallbackServer(
        callback: OAuthCallbackBox<TokenExchangeResponse>,
        verifier: String,
        state: String
    ) throws -> (SimpleHTTPServer, UInt16) {
        var candidatePort = OAuthConfiguration.callbackPort
        let maxPort = OAuthConfiguration.callbackPort + OAuthConfiguration.maxPortOffset
        var lastError: Error?

        while candidatePort <= maxPort {
            do {
                let redirectURI = "http://localhost:\(candidatePort)\(OAuthConfiguration.callbackPath)"
                let server = try SimpleHTTPServer(port: candidatePort) { [session] request in
                    let params = Dictionary(uniqueKeysWithValues: request.queryItems.compactMap { item in
                        item.value.map { (item.name, $0) }
                    })

                    guard request.path == OAuthConfiguration.callbackPath else {
                        return .text(statusCode: 404, text: "Not Found")
                    }
                    guard params["state"] == state else {
                        callback.fail(ServiceError.callbackFailed("OpenAI 登录状态校验失败。"))
                        return .text(statusCode: 400, text: "State mismatch")
                    }
                    guard let code = params["code"], !code.isEmpty else {
                        let message = params["error_description"] ?? params["error"] ?? "Missing code"
                        callback.fail(ServiceError.callbackFailed(message))
                        return .text(statusCode: 400, text: message)
                    }

                    do {
                        let tokens = try await Self.exchangeCodeForTokens(
                            session: session,
                            code: code,
                            verifier: verifier,
                            redirectURI: redirectURI
                        )
                        callback.succeed(tokens)
                        return .html(statusCode: 200, body: "<html><body><h3>OpenPulse 登录成功，可以回到应用。</h3></body></html>")
                    } catch {
                        callback.fail(error)
                        return .text(statusCode: 500, text: error.localizedDescription)
                    }
                }
                return (server, candidatePort)
            } catch {
                lastError = error
                candidatePort += 1
            }
        }

        throw lastError ?? ServiceError.callbackFailed("无法启动本地回调服务。")
    }

    private func makeAuthorizeURL(
        redirectURI: String,
        challenge: String,
        state: String,
        forcedWorkspaceID: String?
    ) throws -> URL {
        var components = URLComponents(url: OAuthConfiguration.issuer.appending(path: "/oauth/authorize"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: OAuthConfiguration.clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: OAuthConfiguration.scopes),
            .init(name: "id_token_add_organizations", value: "true"),
            .init(name: "codex_cli_simplified_flow", value: "true"),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "originator", value: OAuthConfiguration.originator)
        ]
        if let forcedWorkspaceID, !forcedWorkspaceID.isEmpty {
            components?.queryItems?.append(.init(name: "allowed_workspace_id", value: forcedWorkspaceID))
        }
        guard let url = components?.url else {
            throw ServiceError.callbackFailed("无法生成 OpenAI 授权地址。")
        }
        return url
    }

    private static func exchangeCodeForTokens(
        session: URLSession,
        code: String,
        verifier: String,
        redirectURI: String
    ) async throws -> TokenExchangeResponse {
        var request = URLRequest(url: OAuthConfiguration.issuer.appending(path: "/oauth/token"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncodedBody([
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("client_id", OAuthConfiguration.clientID),
            ("code_verifier", verifier)
        ])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(decoding: data, as: UTF8.self)
            throw ServiceError.callbackFailed("OpenAI token 交换失败: \(String(body.prefix(160)))")
        }
        return try JSONDecoder().decode(TokenExchangeResponse.self, from: data)
    }

    private func makeChatGPTAuthJSONString(tokens: TokenExchangeResponse) async throws -> String {
        let claims = try decodeJWTPayload(tokens.idToken)
        let authClaims = claims["https://api.openai.com/auth"] as? [String: Any]
        let accountID = authClaims?["chatgpt_account_id"] as? String
        let apiKey = try? await awaitExchangeAPIKey(idToken: tokens.idToken)

        var tokenObject: [String: Any] = [
            "access_token": tokens.accessToken,
            "refresh_token": tokens.refreshToken,
            "id_token": tokens.idToken
        ]
        if let accountID, !accountID.isEmpty {
            tokenObject["account_id"] = accountID
        }

        var payload: [String: Any] = [
            "auth_mode": "chatgpt",
            "last_refresh": ISO8601DateFormatter().string(from: Date()),
            "tokens": tokenObject
        ]
        if let apiKey, !apiKey.isEmpty {
            payload["OPENAI_API_KEY"] = apiKey
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func extractAccountID(fromIDToken idToken: String) throws -> String {
        let claims = try decodeJWTPayload(idToken)
        let authClaims = claims["https://api.openai.com/auth"] as? [String: Any]
        guard let accountID = authClaims?["chatgpt_account_id"] as? String, !accountID.isEmpty else {
            throw ServiceError.missingAccountID
        }
        return accountID
    }

    private func awaitExchangeAPIKey(idToken: String) async throws -> String {
        var request = URLRequest(url: OAuthConfiguration.issuer.appending(path: "/oauth/token"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncodedBody([
            ("grant_type", "urn:ietf:params:oauth:grant-type:token-exchange"),
            ("client_id", OAuthConfiguration.clientID),
            ("requested_token", "openai-api-key"),
            ("subject_token", idToken),
            ("subject_token_type", "urn:ietf:params:oauth:token-type:id_token")
        ])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ServiceError.callbackFailed("OpenAI API key 交换失败。")
        }
        return try JSONDecoder().decode(APIKeyExchangeResponse.self, from: data).accessToken
    }

    private static func formEncodedBody(_ items: [(String, String)]) -> Data? {
        let body = items.map { key, value in
            "\(percentEncode(key))=\(percentEncode(value))"
        }.joined(separator: "&")
        return body.data(using: .utf8)
    }

    private static func percentEncode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&=?/"))) ?? string
    }

    private func resolveForcedWorkspaceID() -> String? {
        guard let raw = try? String(contentsOf: codexConfigURL, encoding: .utf8), !raw.isEmpty else { return nil }
        for line in raw.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("forced_chatgpt_workspace_id"),
                  let equalIndex = trimmed.firstIndex(of: "=") else { continue }
            let value = trimmed[trimmed.index(after: equalIndex)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !value.isEmpty { return value }
        }
        return nil
    }

    private func resolveChatGPTBaseURL() -> String {
        guard let raw = try? String(contentsOf: codexConfigURL, encoding: .utf8), !raw.isEmpty else {
            return "https://chatgpt.com"
        }
        for line in raw.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("chatgpt_base_url"),
                  let equalIndex = trimmed.firstIndex(of: "=") else { continue }
            let value = trimmed[trimmed.index(after: equalIndex)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !value.isEmpty {
                return value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
        }
        return "https://chatgpt.com"
    }

    private func resolveUsageURLs() -> [String] {
        let baseOrigin = resolveChatGPTBaseURL()
        let backendPrefix = "/backend-api"
        let whamPath = "/wham/usage"
        let codexPath = "/api/codex/usage"
        var candidates: [String] = []

        if baseOrigin.hasSuffix(backendPrefix) {
            let originWithoutBackend = String(baseOrigin.dropLast(backendPrefix.count))
            candidates.append("\(baseOrigin)\(whamPath)")
            candidates.append("\(originWithoutBackend)\(backendPrefix)\(whamPath)")
            candidates.append("\(originWithoutBackend)\(codexPath)")
        } else {
            candidates.append("\(baseOrigin)\(backendPrefix)\(whamPath)")
            candidates.append("\(baseOrigin)\(whamPath)")
            candidates.append("\(baseOrigin)\(codexPath)")
        }

        candidates.append("https://chatgpt.com/backend-api/wham/usage")
        candidates.append("https://chatgpt.com/api/codex/usage")

        var deduped: [String] = []
        for item in candidates where !deduped.contains(item) {
            deduped.append(item)
        }
        return deduped
    }

    private static func refreshAccount(
        _ account: CodexStoredAccount,
        now: Date,
        forceRefresh: Bool,
        session: URLSession,
        usageURLs: [String]
    ) async -> CodexStoredAccount {
        var account = account
        guard forceRefresh || UsageRefreshPolicy.shouldRefresh(lastFetchedAt: account.lastFetchedAt, now: now) else {
            return account
        }

        do {
            let extracted = try extractAuth(from: account.authJSONString)
            let limits = try await fetchUsage(
                accessToken: extracted.accessToken,
                accountID: extracted.accountID,
                session: session,
                urls: usageURLs
            )
            account.email = extracted.email
            account.planType = extracted.planType ?? limits.planType ?? account.planType
            account.teamName = extracted.teamName ?? account.teamName
            account.lastUsage = limits
            account.lastFetchedAt = now
            account.usageError = nil
        } catch {
            account.usageError = error.localizedDescription
            account.lastFetchedAt = now
        }

        account.updatedAt = now
        return account
    }

    private static func fetchUsage(
        accessToken: String,
        accountID: String,
        session: URLSession,
        urls: [String]
    ) async throws -> CodexRateLimits {
        var lastError: Error?
        for raw in urls {
            guard let url = URL(string: raw) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 18
            request.httpMethod = "GET"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("codex-tools-swift/0.1", forHTTPHeaderField: "User-Agent")

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw ServiceError.callbackFailed("Codex usage 响应无效。")
                }
                guard (200..<300).contains(http.statusCode) else {
                    let body = String(decoding: data, as: UTF8.self)
                    throw ServiceError.callbackFailed("Codex usage 获取失败: HTTP \(http.statusCode) \(String(body.prefix(120)))")
                }
                let payload = try JSONDecoder().decode(CodexUsageAPIResponse.self, from: data)
                return payload.toRateLimits()
            } catch {
                lastError = error
            }
        }

        throw lastError ?? ServiceError.callbackFailed("Codex usage 获取失败。")
    }

    private static func extractAuth(from jsonString: String) throws -> ExtractedAuth {
        guard let data = jsonString.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError.invalidAuthFile
        }

        let authMode = (json["auth_mode"] as? String)?.lowercased()
        let tokensObject = (json["tokens"] as? [String: Any]) ?? json
        guard authMode == nil || authMode == "chatgpt" || authMode == "chatgpt_auth_tokens",
              let accessToken = tokensObject["access_token"] as? String,
              let idToken = tokensObject["id_token"] as? String else {
            throw ServiceError.invalidAuthFile
        }

        let claims = try decodeJWTPayload(idToken)
        let authClaims = claims["https://api.openai.com/auth"] as? [String: Any]
        let accountID = (tokensObject["account_id"] as? String) ?? (authClaims?["chatgpt_account_id"] as? String)
        guard let accountID, !accountID.isEmpty else { throw ServiceError.missingAccountID }

        return ExtractedAuth(
            accountID: accountID,
            accessToken: accessToken,
            email: claims["email"] as? String,
            planType: authClaims?["chatgpt_plan_type"] as? String,
            teamName: extractTeamName(from: json, claims: claims, accountIDHint: accountID)
        )
    }

    private static func decodeJWTPayload(_ token: String) throws -> [String: Any] {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count > 1 else { throw ServiceError.invalidAuthFile }
        var base64 = String(segments[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: base64),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError.invalidAuthFile
        }
        return json
    }

    private static func extractTeamName(from auth: [String: Any], claims: [String: Any], accountIDHint: String?) -> String? {
        let authClaims = claims["https://api.openai.com/auth"] as? [String: Any]
        let preferredIDs = [accountIDHint, authClaims?["chatgpt_account_id"] as? String]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let teamName = extractTeamNameFromContainers(in: claims, preferredIDs: preferredIDs)
            ?? extractTeamNameFromContainers(in: auth, preferredIDs: preferredIDs) {
            return teamName
        }

        let candidatePaths: [[String]] = [
            ["https://api.openai.com/auth", "chatgpt_team_name"],
            ["https://api.openai.com/auth", "chatgpt_workspace_slug"],
            ["https://api.openai.com/auth", "workspace_slug"],
            ["https://api.openai.com/auth", "team_slug"],
            ["https://api.openai.com/auth", "organization_slug"],
            ["organization", "name"],
            ["org", "name"],
            ["team", "name"],
            ["workspace", "name"]
        ]

        for path in candidatePaths {
            if let value = nestedString(path, in: claims) ?? nestedString(path, in: auth), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func nestedString(_ path: [String], in root: [String: Any]) -> String? {
        var current: Any = root
        for component in path {
            guard let dict = current as? [String: Any], let next = dict[component] else { return nil }
            current = next
        }
        guard let value = current as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func extractTeamNameFromContainers(in root: [String: Any], preferredIDs: [String]) -> String? {
        let containerKeys = ["organizations", "workspaces", "teams"]
        for key in containerKeys {
            let containers = root[key] as? [[String: Any]] ?? []
            if let preferred = matchContainerName(in: containers, preferredIDs: preferredIDs) {
                return preferred
            }
        }
        return nil
    }

    private static func matchContainerName(in containers: [[String: Any]], preferredIDs: [String]) -> String? {
        for preferredID in preferredIDs {
            if let match = containers.first(where: { matchesWorkspaceID($0, preferredID: preferredID) }),
               let name = containerName(match) {
                return name
            }
        }
        return containers.lazy.compactMap(containerName).first
    }

    private static func matchesWorkspaceID(_ container: [String: Any], preferredID: String) -> Bool {
        ["id", "workspace_id", "organization_id", "account_id"].contains { key in
            guard let value = container[key] as? String else { return false }
            return value == preferredID
        }
    }

    private static func containerName(_ container: [String: Any]) -> String? {
        for key in ["name", "workspace_name", "display_name", "slug"] {
            if let value = container[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    private static func randomBase64URL(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func sha256Base64URL(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private struct CodexUsageAPIResponse: Decodable {
    let planType: String?
    let rateLimit: CodexUsageRateLimit?
    let additionalRateLimits: [CodexUsageAdditionalRateLimit]?
    let credits: CodexCredits?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case additionalRateLimits = "additional_rate_limits"
        case credits
    }

    func toRateLimits() -> CodexRateLimits {
        var windows: [CodexWindow] = []
        if let primary = rateLimit?.primaryWindow { windows.append(primary) }
        if let secondary = rateLimit?.secondaryWindow { windows.append(secondary) }
        for item in additionalRateLimits ?? [] {
            if let primary = item.rateLimit?.primaryWindow { windows.append(primary) }
            if let secondary = item.rateLimit?.secondaryWindow { windows.append(secondary) }
        }

        let primary = windows.min { abs($0.durationSeconds - 5 * 60 * 60) < abs($1.durationSeconds - 5 * 60 * 60) }
        let secondary = windows.min { abs($0.durationSeconds - 7 * 24 * 60 * 60) < abs($1.durationSeconds - 7 * 24 * 60 * 60) }
        return CodexRateLimits(primary: primary, secondary: secondary, credits: credits, planType: planType)
    }
}

private struct CodexUsageRateLimit: Decodable {
    let primaryWindow: CodexWindow?
    let secondaryWindow: CodexWindow?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

private struct CodexUsageAdditionalRateLimit: Decodable {
    let rateLimit: CodexUsageRateLimit?

    enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
    }
}

private final class OAuthCallbackBox<Value: Sendable>: @unchecked Sendable {
    private var continuation: CheckedContinuation<Value, Error>?

    func wait(timeoutSeconds: TimeInterval) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
                    self.continuation = continuation
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                throw NSError(domain: "OpenPulse.CodexOAuth", code: 1, userInfo: [NSLocalizedDescriptionKey: "OpenAI 登录超时，请重试。"])
            }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }

    func succeed(_ value: Value) {
        continuation?.resume(returning: value)
        continuation = nil
    }

    func fail(_ error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

private struct HTTPRequest {
    let path: String
    let queryItems: [URLQueryItem]
}

private struct HTTPResponse {
    let statusCode: Int
    let contentType: String
    let body: Data

    static func text(statusCode: Int, text: String) -> HTTPResponse {
        HTTPResponse(statusCode: statusCode, contentType: "text/plain; charset=utf-8", body: Data(text.utf8))
    }

    static func html(statusCode: Int, body: String) -> HTTPResponse {
        HTTPResponse(statusCode: statusCode, contentType: "text/html; charset=utf-8", body: Data(body.utf8))
    }
}

private final class SimpleHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "OpenPulse.CodexOAuthServer")
    private let handler: @Sendable (HTTPRequest) async -> HTTPResponse

    init(port: UInt16, handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) throws {
        guard let port = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }
        listener = try NWListener(using: .tcp, on: port)
        self.handler = handler
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            final class StartState: @unchecked Sendable {
                let lock = NSLock()
                var resumed = false
            }

            let state = StartState()

            listener.stateUpdateHandler = { newState in
                state.lock.lock()
                defer { state.lock.unlock() }
                guard !state.resumed else { return }
                switch newState {
                case .ready:
                    state.resumed = true
                    continuation.resume()
                case .failed(let error):
                    state.resumed = true
                    continuation.resume(throwing: error)
                case .cancelled:
                    state.resumed = true
                    continuation.resume(throwing: NSError(
                        domain: "OpenPulse.CodexOAuth",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "本地登录回调服务已取消。"]
                    ))
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [handler] connection in
                connection.start(queue: DispatchQueue(label: "OpenPulse.CodexOAuthConnection"))
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                    let request = parseRequest(from: data ?? Data())
                    Task {
                        let response = await handler(request)
                        connection.send(content: renderResponse(response), completion: .contentProcessed { _ in
                            connection.cancel()
                        })
                    }
                }
            }

            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }
}

private func parseRequest(from data: Data) -> HTTPRequest {
    let requestLine = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n").first ?? "GET / HTTP/1.1"
    let parts = requestLine.split(separator: " ")
    let target = parts.count > 1 ? String(parts[1]) : "/"
    let components = URLComponents(string: "http://127.0.0.1\(target)")
    return HTTPRequest(path: components?.path ?? "/", queryItems: components?.queryItems ?? [])
}

private func renderResponse(_ response: HTTPResponse) -> Data {
    let header = """
    HTTP/1.1 \(response.statusCode) OK\r
    Content-Type: \(response.contentType)\r
    Content-Length: \(response.body.count)\r
    Connection: close\r
    \r
    """
    return Data(header.utf8) + response.body
}
