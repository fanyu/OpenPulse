import Foundation

/// Fetches GitHub Copilot quota via GitHub internal API.
/// Auth token is read from ~/.cli-proxy-api/github-copilot-*.json
actor CopilotAPIClient {
    private let session: URLSession
    private let proxyDir: URL

    init(session: URLSession = .shared) {
        self.session = session
        proxyDir = URL.homeDirectory.appending(path: ".cli-proxy-api")
    }

    func fetchQuota() async throws -> (quota: ToolQuota, snapshots: [String: CopilotSnapshot], plan: String?) {
        let token = try resolveAccessToken()
        return try await fetchUserQuota(token: token)
    }

    // MARK: - Token resolution

    private func resolveAccessToken() throws -> String {
        // 1. Prefer local auth file (written by cli-proxy or Copilot CLI)
        if FileManager.default.fileExists(atPath: proxyDir.path) {
            let files = (try? FileManager.default.contentsOfDirectory(at: proxyDir, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("github-copilot-") && $0.pathExtension == "json" }) ?? []
            if let file = files.first,
               let data = try? Data(contentsOf: file),
               let json = try? JSONDecoder().decode(CopilotAuthFile.self, from: data),
               let token = json.accessToken, !token.isEmpty {
                return token
            }
        }
        // 2. Fall back to token saved in Keychain via ProviderView
        if let token = try? KeychainService.retrieve(key: KeychainService.Keys.githubToken),
           !token.isEmpty {
            return token
        }
        throw CopilotError.noLocalFile
    }

    // MARK: - API call

    private func fetchUserQuota(token: String) async throws -> (ToolQuota, [String: CopilotSnapshot], String?) {
        var request = URLRequest(url: URL(string: "https://api.github.com/copilot_internal/user")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("OpenPulse/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CopilotError.apiFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0): \(body.prefix(200))")
        }

        let decoder = JSONDecoder()
        let user = try decoder.decode(CopilotUserResponse.self, from: data)
        let snapshots = user.quotaSnapshots ?? [:]

        // Reset date from top-level quota_reset_date_utc
        // Must use withFractionalSeconds — value is "2026-04-01T00:00:00.000Z"
        let resetAt: Date? = user.quotaResetDateUtc.flatMap { raw -> Date? in
            let fmtMs = ISO8601DateFormatter()
            fmtMs.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = fmtMs.date(from: raw) { return d }
            return ISO8601DateFormatter().date(from: raw)  // fallback without ms
        }

        // Find the most constrained non-unlimited quota for the summary record
        let limited = snapshots.values.filter { !($0.unlimited ?? false) }
        if let snap = limited.min(by: { ($0.percentRemaining ?? 100) < ($1.percentRemaining ?? 100) }) {
            let remaining = snap.remaining ?? 0
            let total = snap.entitlement ?? 0
            let quota = ToolQuota(
                id: Tool.copilot.rawValue, tool: .copilot,
                accountKey: nil, accountLabel: nil,
                remaining: total > 0 ? remaining : nil,
                total: total > 0 ? total : nil,
                unit: .requests, resetAt: resetAt, updatedAt: Date(),
                raw: snapshots as (any Sendable)
            )
            return (quota, snapshots, user.copilotPlan)
        }

        // All unlimited — store nil so UI shows "unlimited"
        let quota = ToolQuota(
            id: Tool.copilot.rawValue, tool: .copilot,
            accountKey: nil, accountLabel: nil,
            remaining: nil, total: nil,
            unit: .requests, resetAt: resetAt, updatedAt: Date(),
            raw: snapshots as (any Sendable)
        )
        return (quota, snapshots, user.copilotPlan)
    }
}

// MARK: - JSON models

private struct CopilotAuthFile: Decodable {
    let accessToken: String?
    enum CodingKeys: String, CodingKey { case accessToken = "access_token" }
}

struct CopilotUserResponse: Decodable, Sendable {
    let quotaSnapshots: [String: CopilotSnapshot]?
    let quotaResetDateUtc: String?
    let copilotPlan: String?

    enum CodingKeys: String, CodingKey {
        case quotaSnapshots = "quota_snapshots"
        case quotaResetDateUtc = "quota_reset_date_utc"
        case copilotPlan = "copilot_plan"
    }
}

public struct CopilotSnapshot: Decodable, Sendable {
    /// Human-readable name for this quota type, e.g. "premium_interactions"
    public let quotaId: String?
    /// Absolute remaining count
    public let remaining: Int?
    /// Total entitlement (limit)
    public let entitlement: Int?
    /// 0-100 percentage remaining
    public let percentRemaining: Double?
    /// Whether this quota is unlimited for the user's plan
    public let unlimited: Bool?

    public enum CodingKeys: String, CodingKey {
        case quotaId = "quota_id"
        case remaining
        case entitlement
        case percentRemaining = "percent_remaining"
        case unlimited
    }

    /// Display name: prettify snake_case id
    public var displayName: String {
        guard let id = quotaId else { return "—" }
        return id.replacing("_", with: " ").capitalized
    }
}

// MARK: - Errors

enum CopilotError: Error, LocalizedError {
    case noToken
    case noLocalFile
    case tokenParseFailure
    case apiFailed(String)

    var errorDescription: String? {
        switch self {
        case .noToken: "No GitHub token configured."
        case .noLocalFile: "Copilot auth file not found in ~/.cli-proxy-api/"
        case .tokenParseFailure: "Could not parse access_token from Copilot auth file."
        case .apiFailed(let msg): "GitHub API error: \(msg)"
        }
    }
}
