import Foundation
import AppKit
import CryptoKit

actor AntigravityAccountService {
    private let fileManager: FileManager
    private let session: URLSession
    private let supportDir: URL
    private let storeURL: URL
    private let credentialOperations: CredentialOperations
    private let writeStoreData: @Sendable (Data, URL) throws -> Void

    struct CredentialOperations: Sendable {
        let retrieve: @Sendable (String) throws -> String?
        let store: @Sendable (String, String) throws -> Void
        let delete: @Sendable (String) throws -> Void

        static var keychain: Self {
            Self(
                retrieve: { try KeychainService.retrieve(key: $0) },
                store: { try KeychainService.store(key: $0, value: $1) },
                delete: { try KeychainService.deleteChecked(key: $0) }
            )
        }
    }

    init(
        fileManager: FileManager = .default,
        session: URLSession = .shared,
        storeURL: URL? = nil,
        credentialOperations: CredentialOperations = .keychain,
        writeStoreData: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
    ) {
        self.fileManager = fileManager
        self.session = session
        let resolvedStoreURL = storeURL ?? URL.homeDirectory.appending(path: ".openpulse/antigravity-accounts.json")
        self.storeURL = resolvedStoreURL
        supportDir = resolvedStoreURL.deletingLastPathComponent()
        self.credentialOperations = credentialOperations
        self.writeStoreData = writeStoreData
    }

    static func keychainKey(email: String) -> String { "antigravity_refresh_\(email)" }

    func listAccounts() async throws -> [AGStoredAccount] { try loadStore() }

    func deleteAccount(email: String) async throws {
        var store = try loadStore()
        store.removeAll { $0.email == email }
        // Keep the credential usable if the durable account-list update fails.
        try saveStore(store)
        try credentialOperations.delete(Self.keychainKey(email: email))
    }

    func refreshToken(for email: String) async -> String? {
        try? credentialOperations.retrieve(Self.keychainKey(email: email))
    }

    func addAccountViaOAuth(timeoutSeconds: TimeInterval = 600) async throws -> AGStoredAccount {
        let verifier = OAuthPKCE.randomBase64URL(byteCount: 32)
        let challenge = OAuthPKCE.sha256Base64URL(verifier)
        let state = OAuthPKCE.randomBase64URL(byteCount: 32)
        let callback = OAuthCallbackBox<GoogleTokens>()
        let (server, port) = try await makeCallbackServer(callback: callback, verifier: verifier, state: state)
        defer { server.stop() }
        let redirectURI = "http://127.0.0.1:\(port)/callback"
        let authorizeURL = makeAuthorizeURL(redirectURI: redirectURI, challenge: challenge, state: state)

        guard NSWorkspace.shared.open(authorizeURL) else { throw ServiceError.openFailed }

        let tokens = try await callback.wait(timeoutSeconds: timeoutSeconds)
        let email = try Self.email(fromIDToken: tokens.idToken)
        guard let refresh = tokens.refreshToken, !refresh.isEmpty else { throw ServiceError.noRefreshToken }

        return try persistAccount(email: email, refreshToken: refresh)
    }

    /// Complete the account save without suspension between metadata validation and durable commit.
    func persistAccount(email: String, refreshToken: String) throws -> AGStoredAccount {
        var store = try loadStore()
        let key = Self.keychainKey(email: email)
        let previousCredential = try credentialOperations.retrieve(key)
        var credentialCleanupError: KeychainError?
        do {
            try credentialOperations.store(key, refreshToken)
        } catch KeychainError.legacyCleanupFailed(let status) {
            // The new Data Protection credential is durable despite this cleanup warning.
            credentialCleanupError = .legacyCleanupFailed(status)
        }

        store.removeAll { $0.email == email }
        let account = AGStoredAccount(email: email, label: email, tierId: nil, tierName: nil,
                                      addedAt: Date(), updatedAt: Date())
        store.append(account)
        do {
            try saveStore(store)
        } catch {
            do {
                if let previousCredential {
                    try credentialOperations.store(key, previousCredential)
                } else {
                    try credentialOperations.delete(key)
                }
            } catch KeychainError.legacyCleanupFailed(let status) {
                throw ServiceError.metadataSaveFailedWithLegacyCleanupFailure(status)
            } catch {
                throw ServiceError.credentialRestoreFailed
            }
            throw error
        }
        if let credentialCleanupError { throw credentialCleanupError }
        return account
    }

    // MARK: callback server (mirrors CodexAccountService.makeCallbackServer)
    private func makeCallbackServer(callback: OAuthCallbackBox<GoogleTokens>, verifier: String, state: String)
        async throws -> (SimpleHTTPServer, UInt16) {
        var port: UInt16 = 8123
        let maxPort: UInt16 = 8135
        var lastError: Error?
        while port <= maxPort {
            try Task.checkCancellation()
            do {
                let redirectURI = "http://127.0.0.1:\(port)/callback"
                let server = try SimpleHTTPServer(port: port) { [session] request in
                    guard request.path == "/callback" else { return .text(statusCode: 404, text: "Not Found") }
                    guard let params = oauthCallbackParameters(request.queryItems) else {
                        return .text(statusCode: 400, text: "Duplicate callback parameters")
                    }
                    guard params["state"] == state else {
                        return .text(statusCode: 400, text: "State mismatch")
                    }
                    guard let code = params["code"], !code.isEmpty else {
                        let msg = params["error_description"] ?? params["error"] ?? "Missing code"
                        callback.fail(ServiceError.callbackFailed(msg)); return .text(statusCode: 400, text: msg)
                    }
                    do {
                        let tokens = try await Self.exchangeCode(session: session, code: code, verifier: verifier, redirectURI: redirectURI)
                        callback.succeed(tokens)
                        let message = String(localized: "授权完成，请返回 OpenPulse 查看账号保存结果。")
                        return .html(statusCode: 200, body: "<html><body><h3>\(message)</h3></body></html>")
                    } catch { callback.fail(error); return .text(statusCode: 500, text: error.localizedDescription) }
                }
                do {
                    try await server.start()
                } catch {
                    server.stop()
                    throw error
                }
                return (server, port)
            } catch {
                try Task.checkCancellation()
                lastError = error
                port += 1
            }
        }
        throw lastError ?? ServiceError.callbackFailed("无法启动本地回调服务。")
    }

    private func makeAuthorizeURL(redirectURI: String, challenge: String, state: String) -> URL {
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: AntigravityOAuth.clientId),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: AntigravityOAuth.scopes),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        return c.url!
    }

    private static func exchangeCode(session: URLSession, code: String, verifier: String, redirectURI: String) async throws -> GoogleTokens {
        var req = URLRequest(url: URL(string: AntigravityOAuth.tokenEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = [
            "grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI,
            "client_id": AntigravityOAuth.clientId, "client_secret": AntigravityOAuth.clientSecret,
            "code_verifier": verifier,
        ]
        req.httpBody = formEncodedBody(form)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ServiceError.callbackFailed("token exchange HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0): \(String(decoding: data, as: UTF8.self).prefix(160))")
        }
        return try JSONDecoder().decode(GoogleTokens.self, from: data)
    }

    /// `application/x-www-form-urlencoded` body encoding (mirrors CodexAccountService.formEncodedBody).
    private static func formEncodedBody(_ items: [String: String]) -> Data? {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&=?/"))
        let body = items.map { key, value in
            "\(key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
        return body.data(using: .utf8)
    }

    static func email(fromIDToken idToken: String) throws -> String {
        let parts = idToken.components(separatedBy: ".")
        guard parts.count >= 2 else { throw ServiceError.callbackFailed("bad id_token") }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = json["email"] as? String else { throw ServiceError.callbackFailed("no email in id_token") }
        return email
    }

    private func loadStore() throws -> [AGStoredAccount] {
        let data: Data
        do {
            data = try Data(contentsOf: storeURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        } catch {
            throw ServiceError.metadataReadFailed
        }
        do {
            return try JSONDecoder().decode([AGStoredAccount].self, from: data)
        } catch {
            throw ServiceError.metadataReadFailed
        }
    }

    private func saveStore(_ store: [AGStoredAccount]) throws {
        do {
            let data = try JSONEncoder().encode(store)
            try fileManager.createDirectory(at: supportDir, withIntermediateDirectories: true)
            try writeStoreData(data, storeURL)
        } catch {
            throw ServiceError.metadataSaveFailed
        }
    }

    struct GoogleTokens: Decodable, Sendable {
        let accessToken: String
        let refreshToken: String?
        let idToken: String
        enum CodingKeys: String, CodingKey { case accessToken = "access_token"; case refreshToken = "refresh_token"; case idToken = "id_token" }
    }
    enum ServiceError: LocalizedError {
        case openFailed, noRefreshToken, stateMismatch, callbackFailed(String)
        case metadataReadFailed, metadataSaveFailed, credentialRestoreFailed
        case metadataSaveFailedWithLegacyCleanupFailure(Int32)
        var errorDescription: String? {
            switch self {
            case .openFailed: "无法打开浏览器完成 Google 登录。"
            case .noRefreshToken: "Google 未返回 refresh_token（请确认已授予离线访问）。"
            case .stateMismatch: "登录状态校验失败。"
            case .callbackFailed(let m): m
            case .metadataReadFailed: String(localized: "无法读取 Antigravity 账号信息。请检查本地账号文件后重试。")
            case .metadataSaveFailed: String(localized: "无法保存 Antigravity 账号信息。请检查文件访问权限后重试。")
            case .credentialRestoreFailed: String(localized: "账号信息保存失败，且原授权恢复失败。请重新登录该账号。")
            case .metadataSaveFailedWithLegacyCleanupFailure(let status):
                String(localized: "账号信息保存失败，原授权已恢复，但旧授权清理失败（\(status)）。")
            }
        }
    }
}

struct AGStoredAccount: Codable, Sendable {
    let email: String
    var label: String
    var tierId: String?
    var tierName: String?
    let addedAt: Date
    var updatedAt: Date
}
