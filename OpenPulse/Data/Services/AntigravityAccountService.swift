import Foundation
import AppKit
import CryptoKit

actor AntigravityAccountService {
    private let fileManager: FileManager
    private let session: URLSession
    private let supportDir: URL
    private let storeURL: URL

    init(fileManager: FileManager = .default, session: URLSession = .shared) {
        self.fileManager = fileManager
        self.session = session
        supportDir = URL.homeDirectory.appending(path: ".openpulse")
        storeURL = supportDir.appending(path: "antigravity-accounts.json")
    }

    static func keychainKey(email: String) -> String { "antigravity_refresh_\(email)" }

    func listAccounts() async -> [AGStoredAccount] { loadStore() }

    func deleteAccount(email: String) async {
        var store = loadStore()
        store.removeAll { $0.email == email }
        saveStore(store)
        KeychainService.delete(key: Self.keychainKey(email: email))
    }

    func refreshToken(for email: String) async -> String? {
        try? KeychainService.retrieve(key: Self.keychainKey(email: email))
    }

    func addAccountViaOAuth(timeoutSeconds: TimeInterval = 600) async throws -> AGStoredAccount {
        let verifier = OAuthPKCE.randomBase64URL(byteCount: 32)
        let challenge = OAuthPKCE.sha256Base64URL(verifier)
        let state = OAuthPKCE.randomBase64URL(byteCount: 32)
        let callback = OAuthCallbackBox<GoogleTokens>()
        let (server, port) = try makeCallbackServer(callback: callback, verifier: verifier, state: state)
        let redirectURI = "http://127.0.0.1:\(port)/callback"
        let authorizeURL = makeAuthorizeURL(redirectURI: redirectURI, challenge: challenge, state: state)

        try await server.start()
        defer { server.stop() }
        guard NSWorkspace.shared.open(authorizeURL) else { throw ServiceError.openFailed }

        let tokens = try await callback.wait(timeoutSeconds: timeoutSeconds)
        let email = try Self.email(fromIDToken: tokens.idToken)
        guard let refresh = tokens.refreshToken, !refresh.isEmpty else { throw ServiceError.noRefreshToken }
        try KeychainService.store(key: Self.keychainKey(email: email), value: refresh)

        var store = loadStore()
        store.removeAll { $0.email == email }
        let account = AGStoredAccount(email: email, label: email, tierId: nil, tierName: nil,
                                      addedAt: Date(), updatedAt: Date())
        store.append(account)
        saveStore(store)
        return account
    }

    // MARK: callback server (mirrors CodexAccountService.makeCallbackServer)
    private func makeCallbackServer(callback: OAuthCallbackBox<GoogleTokens>, verifier: String, state: String)
        throws -> (SimpleHTTPServer, UInt16) {
        var port: UInt16 = 8123
        let maxPort: UInt16 = 8135
        var lastError: Error?
        while port <= maxPort {
            do {
                let redirectURI = "http://127.0.0.1:\(port)/callback"
                let server = try SimpleHTTPServer(port: port) { [session] request in
                    let params = Dictionary(uniqueKeysWithValues: request.queryItems.compactMap { i in i.value.map { (i.name, $0) } })
                    guard request.path == "/callback" else { return .text(statusCode: 404, text: "Not Found") }
                    guard params["state"] == state else { callback.fail(ServiceError.stateMismatch); return .text(statusCode: 400, text: "State mismatch") }
                    guard let code = params["code"], !code.isEmpty else {
                        let msg = params["error_description"] ?? params["error"] ?? "Missing code"
                        callback.fail(ServiceError.callbackFailed(msg)); return .text(statusCode: 400, text: msg)
                    }
                    do {
                        let tokens = try await Self.exchangeCode(session: session, code: code, verifier: verifier, redirectURI: redirectURI)
                        callback.succeed(tokens)
                        return .html(statusCode: 200, body: "<html><body><h3>OpenPulse 登录成功，可以回到应用。</h3></body></html>")
                    } catch { callback.fail(error); return .text(statusCode: 500, text: error.localizedDescription) }
                }
                return (server, port)
            } catch { lastError = error; port += 1 }
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

    private func loadStore() -> [AGStoredAccount] {
        guard let data = try? Data(contentsOf: storeURL) else { return [] }
        return (try? JSONDecoder().decode([AGStoredAccount].self, from: data)) ?? []
    }
    private func saveStore(_ store: [AGStoredAccount]) {
        try? fileManager.createDirectory(at: supportDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(store) { try? data.write(to: storeURL) }
    }

    struct GoogleTokens: Decodable, Sendable {
        let accessToken: String
        let refreshToken: String?
        let idToken: String
        enum CodingKeys: String, CodingKey { case accessToken = "access_token"; case refreshToken = "refresh_token"; case idToken = "id_token" }
    }
    enum ServiceError: LocalizedError {
        case openFailed, noRefreshToken, stateMismatch, callbackFailed(String)
        var errorDescription: String? {
            switch self {
            case .openFailed: "无法打开浏览器完成 Google 登录。"
            case .noRefreshToken: "Google 未返回 refresh_token（请确认已授予离线访问）。"
            case .stateMismatch: "登录状态校验失败。"
            case .callbackFailed(let m): m
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
