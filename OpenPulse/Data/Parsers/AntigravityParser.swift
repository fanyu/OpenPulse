import Foundation

/// Parses Antigravity (Gemini Code Assist) task data from ~/.gemini/antigravity/brain/
/// and fetches quota via the Google Cloud Code Assist internal API.
actor AntigravityParser {
    private let brainDir: URL
    private let proxyDir: URL
    private let session: URLSession

    /// OAuth credentials belonging to the Antigravity CLI application itself — not personal credentials.
    /// Extracted from the open-source Antigravity/Quotio CLI tool source code.
    /// Source: https://github.com/nguyenphutrong/quotio
    private let oauthClientId = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    private let oauthClientSecret = "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"
    private let tokenEndpoint = "https://oauth2.googleapis.com/token"
    private let loadCodeAssistEndpoint = "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
    private let fetchModelsEndpoint = "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels"
    private let userAgent = "antigravity/1.11.3 Darwin/arm64"

    init(session: URLSession = .shared) {
        brainDir = URL.homeDirectory.appending(path: ".gemini/antigravity/brain")
        proxyDir = URL.homeDirectory.appending(path: ".cli-proxy-api")
        self.session = session
    }

    // MARK: - Public API

    func parseTodayTasks() async throws -> [TaskItem] {
        guard FileManager.default.fileExists(atPath: brainDir.path) else { return [] }

        let today = Calendar.current.startOfDay(for: Date())
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!

        var items: [TaskItem] = []
        let subdirs = (try? FileManager.default.contentsOfDirectory(
            at: brainDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }) ?? []

        for dir in subdirs {
            let metaURL = dir.appending(path: "task.md.metadata.json")
            let taskURL = dir.appending(path: "task.md.resolved")

            guard FileManager.default.fileExists(atPath: metaURL.path),
                  FileManager.default.fileExists(atPath: taskURL.path),
                  let meta = try? parseMetadata(at: metaURL),
                  let updatedAt = meta.updatedAt,
                  updatedAt >= today && updatedAt < tomorrow else { continue }

            let tasks = (try? parseTaskMarkdown(at: taskURL)) ?? []
            items.append(contentsOf: tasks)
        }

        return items
    }

    func parseSessions(since date: Date? = nil) async throws -> [ToolSession] {
        guard FileManager.default.fileExists(atPath: brainDir.path) else { return [] }

        var sessions: [ToolSession] = []
        let subdirs = (try? FileManager.default.contentsOfDirectory(
            at: brainDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }) ?? []

        for dir in subdirs {
            let metaURL = dir.appending(path: "task.md.metadata.json")
            let taskURL = dir.appending(path: "task.md.resolved")

            guard let meta = try? parseMetadata(at: metaURL),
                  let updatedAt = meta.updatedAt else { continue }

            if let cutoff = date, updatedAt < cutoff { continue }

            let taskItems = (try? parseTaskMarkdown(at: taskURL)) ?? []
            let taskContent = (try? String(contentsOf: taskURL, encoding: .utf8)) ?? ""
            let firstLine = taskContent.components(separatedBy: "\n")
                .first(where: { $0.hasPrefix("# ") })
                .map { String($0.dropFirst(2)) } ?? meta.summary ?? ""

            sessions.append(ToolSession(
                tool: .antigravity,
                startedAt: updatedAt,
                endedAt: updatedAt,
                taskDescription: firstLine,
                taskItems: taskItems
            ))
        }

        return sessions.sorted { $0.startedAt < $1.startedAt }
    }

    // MARK: - Quota via Google Cloud Code Assist API

    /// Fetches quota for ALL Antigravity accounts found in ~/.cli-proxy-api/antigravity-*.json.
    /// Returns a ToolQuota whose `raw` value is `[AGAccountQuota]` (one per account).
    /// The summary `remaining` is the minimum remaining fraction across all accounts/models.
    func fetchQuota() async throws -> ToolQuota {
        guard FileManager.default.fileExists(atPath: proxyDir.path) else {
            throw AntigravityError.noAuthFile
        }
        let authFiles = (try? FileManager.default.contentsOfDirectory(at: proxyDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("antigravity-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }) ?? []
        guard !authFiles.isEmpty else { throw AntigravityError.noAuthFile }

        var accounts: [AGAccountQuota] = []
        var lastError: Error?

        for file in authFiles {
            do {
                let account = try await fetchAccountQuota(from: file)
                accounts.append(account)
            } catch {
                print("[OpenPulse] Antigravity account \(file.lastPathComponent) failed: \(error.localizedDescription)")
                lastError = error
            }
        }

        // If all accounts failed, propagate the last error
        if accounts.isEmpty, let err = lastError { throw err }

        // Derive summary: minimum remaining fraction across all accounts/models that have data
        let allFractions = accounts.flatMap(\.models).compactMap(\.remainingFraction)
        let minFraction = allFractions.min() ?? 1.0

        // Earliest reset time across everything
        let resetAt: Date? = accounts.flatMap(\.models).compactMap { m -> Date? in
            guard let t = m.resetTime else { return nil }
            return parseISO8601(t)
        }.min()

        let remainingPct = Int((minFraction * 100).rounded())

        return ToolQuota(
            id: Tool.antigravity.rawValue,
            tool: .antigravity,
            accountKey: nil,
            accountLabel: nil,
            remaining: remainingPct,
            total: 100,
            unit: .requests,
            resetAt: resetAt,
            updatedAt: Date(),
            raw: accounts as (any Sendable)
        )
    }

    /// Fetches quota for a single auth file, returns an `AGAccountQuota`.
    private func fetchAccountQuota(from file: URL) async throws -> AGAccountQuota {
        let rawData = try Data(contentsOf: file)
        var auth = try JSONDecoder().decode(AntigravityAuthFile.self, from: rawData)
        guard !auth.accessToken.isEmpty else { throw AntigravityError.tokenParseFailure }

        if auth.isExpired, let refreshToken = auth.refreshToken, !refreshToken.isEmpty {
            let (newToken, expiresIn) = try await refreshAccessToken(refreshToken: refreshToken)
            auth.accessToken = newToken
            persistRefreshedToken(at: file, originalData: rawData, newToken: newToken, expiresIn: expiresIn)
        }

        let token = auth.accessToken
        // Derive email from filename: "antigravity-user_gmail_com.json" → "user@gmail.com"
        let email = auth.email ?? emailFromFilename(file.deletingPathExtension().lastPathComponent)

        let projectId = try await fetchProjectId(token: token)
        let models = try await fetchAllModels(token: token, projectId: projectId)

        return AGAccountQuota(email: email, models: models)
    }

    // MARK: - Auth

    private func refreshAccessToken(refreshToken: String) async throws -> (String, Int) {
        var request = URLRequest(url: URL(string: tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let params = [
            "client_id": oauthClientId,
            "client_secret": oauthClientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ]
        request.httpBody = params.map { "\($0.key)=\($0.value)" }.joined(separator: "&").data(using: .utf8)
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AntigravityError.apiFailed("Token refresh HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let tokenResp = try JSONDecoder().decode(AGTokenRefreshResponse.self, from: data)
        return (tokenResp.accessToken, tokenResp.expiresIn)
    }

    private func persistRefreshedToken(at url: URL, originalData: Data, newToken: String, expiresIn: Int) {
        guard var json = try? JSONSerialization.jsonObject(with: originalData) as? [String: Any] else { return }
        json["access_token"] = newToken
        let expiry = Date().addingTimeInterval(TimeInterval(expiresIn))
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        json["expired"] = fmt.string(from: expiry)
        json["expires_in"] = expiresIn
        json["timestamp"] = Int64(Date().timeIntervalSince1970 * 1000)
        if let updated = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) {
            try? updated.write(to: url)
        }
    }

    // MARK: - API calls

    private func fetchProjectId(token: String) async throws -> String? {
        var request = URLRequest(url: URL(string: loadCodeAssistEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["metadata": ["ideType": "ANTIGRAVITY"]])
        request.timeoutInterval = 10

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AntigravityError.apiFailed("loadCodeAssist HTTP \(http.statusCode): \(body.prefix(200))")
        }

        let info = (try? JSONDecoder().decode(AGSubscriptionInfo.self, from: data))
        return info?.cloudaicompanionProject
    }

    private func fetchAllModels(token: String, projectId: String?) async throws -> [AGModelQuota] {
        var request = URLRequest(url: URL(string: fetchModelsEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        var payload: [String: Any] = [:]
        if let pid = projectId { payload["project"] = pid }
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 10

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AntigravityError.apiFailed("No HTTP response from fetchAvailableModels")
        }
        if http.statusCode == 403 { throw AntigravityError.apiFailed("403 Forbidden – check Google auth") }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AntigravityError.apiFailed("fetchAvailableModels HTTP \(http.statusCode): \(body.prefix(200))")
        }

        let apiResp = try JSONDecoder().decode(AGQuotaAPIResponse.self, from: data)

        // Build display order: recommended (agentModelSorts) first, then any remaining models
        let recommendedIds: [String] = apiResp.agentModelSorts
            .flatMap { $0.groups }
            .flatMap { $0.modelIds }

        var seen = Set<String>()
        var orderedIds = recommendedIds.filter { seen.insert($0).inserted }
        // Append any models not in agentModelSorts (alphabetically for stability)
        let remaining = apiResp.models.keys.filter { !seen.contains($0) }.sorted()
        orderedIds.append(contentsOf: remaining)

        var seenDisplayNames = Set<String>()
        return orderedIds.compactMap { modelId -> AGModelQuota? in
            guard let info = apiResp.models[modelId] else { return nil }
            let displayName = info.displayName ?? modelId
            // 过滤 displayName 等于 id 的内部测试模型（chat_*、tab_* 等无友好名称）
            guard displayName != modelId else { return nil }
            // 同一 displayName 可能对应多个 modelId（如 gemini-2.5-pro / gemini-2.5-pro-exp）
            guard seenDisplayNames.insert(displayName).inserted else { return nil }
            let quotaInfo = info.quotaInfo
            // nil = API returned no quota info for this model
            let fraction = quotaInfo?.remainingFraction.map { min(1.0, max(0.0, $0)) }
            return AGModelQuota(
                id: modelId,
                displayName: displayName,
                remainingFraction: fraction,
                resetTime: quotaInfo?.resetTime
            )
        }
    }

    // MARK: - Helpers

    /// Converts a filename stem like "antigravity-user_gmail_com" to "user@gmail.com"
    private func emailFromFilename(_ stem: String) -> String {
        // Strip the "antigravity-" prefix
        let stripped = stem.hasPrefix("antigravity-") ? String(stem.dropFirst("antigravity-".count)) : stem
        // The format is "user_domain_tld" where the last two "_" become "." and the preceding one becomes "@"
        // Strategy: split on "_", rejoin with "." except replace the last separator before domain with "@"
        // Example: "user_gmail_com" → parts = ["user", "gmail", "com"]
        // We assume last two parts form the domain, everything before is local part (joined by ".")
        let parts = stripped.components(separatedBy: "_")
        guard parts.count >= 3 else {
            // Fallback: just replace last underscore with "@" and others with "."
            return stripped.replacing("_", with: ".")
        }
        let domain = parts.suffix(2).joined(separator: ".")
        let local = parts.dropLast(2).joined(separator: ".")
        return "\(local)@\(domain)"
    }

    private func parseISO8601(_ string: String) -> Date? {
        parseISO8601Flexible(string)
    }

    // MARK: - Private parsing helpers

    private func parseMetadata(at url: URL) throws -> BrainMetadata {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BrainMetadata.self, from: data)
    }

    private func parseTaskMarkdown(at url: URL) throws -> [TaskItem] {
        let content = try String(contentsOf: url, encoding: .utf8)
        return content.components(separatedBy: "\n")
            .compactMap { line -> TaskItem? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
                    return TaskItem(title: String(trimmed.dropFirst(6)), isCompleted: true, source: .antigravity)
                } else if trimmed.hasPrefix("- [ ] ") {
                    return TaskItem(title: String(trimmed.dropFirst(6)), isCompleted: false, source: .antigravity)
                }
                return nil
            }
    }
}

// MARK: - Per-account quota (returned in ToolQuota.raw and exposed via DataSyncService)

/// Quota data for one Antigravity account, containing all of its models.
struct AGAccountQuota: Sendable, Identifiable {
    /// Derived from the auth file name, e.g. "user@gmail.com"
    let email: String
    /// All models returned by the API for this account (recommended first, then the rest)
    let models: [AGModelQuota]

    var id: String { email }
}

struct AGModelQuota: Sendable {
    let id: String
    let displayName: String
    /// nil = API returned no quota info for this model (no data, not necessarily unlimited)
    let remainingFraction: Double?
    let resetTime: String?

    /// Remaining percentage string, e.g. "82%" or "—" when no data
    var formattedPercentage: String {
        guard let f = remainingFraction else { return "—" }
        return "\(Int((f * 100).rounded()))%"
    }

    /// Countdown string derived from ISO 8601 resetTime, e.g. "3h 12m".
    /// Delegates to the shared countdownString(to:) free function for consistent output.
    var resetCountdown: String? {
        guard let t = resetTime,
              let date = parseISO8601Flexible(t) else { return nil }
        return countdownString(to: date)
    }
}

// MARK: - Decodable models (file-private)

private struct BrainMetadata: Decodable {
    let artifactType: String?
    let summary: String?
    let updatedAt: Date?
    let version: String?
}

private struct AntigravityAuthFile: Decodable {
    var accessToken: String
    let email: String?
    let refreshToken: String?
    let expired: String?
    let expiresIn: Int?
    let timestamp: Int?
    let type: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case email
        case refreshToken = "refresh_token"
        case expired
        case expiresIn = "expires_in"
        case timestamp
        case type
    }

    var isExpired: Bool {
        guard let expired,
              let date = parseISO8601Flexible(expired) else { return false }
        return Date() > date
    }
}

private struct AGTokenRefreshResponse: Decodable {
    let accessToken: String
    let expiresIn: Int
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
    }
}

private struct AGSubscriptionInfo: Decodable {
    let cloudaicompanionProject: String?
}

private struct AGQuotaAPIResponse: Decodable {
    let models: [String: AGModelInfo]
    let agentModelSorts: [AGModelSort]

    enum CodingKeys: String, CodingKey {
        case models
        case agentModelSorts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        models = try container.decodeIfPresent([String: AGModelInfo].self, forKey: .models) ?? [:]
        agentModelSorts = try container.decodeIfPresent([AGModelSort].self, forKey: .agentModelSorts) ?? []
    }
}

private struct AGModelSort: Decodable {
    let groups: [AGModelGroup]
}

private struct AGModelGroup: Decodable {
    let modelIds: [String]
}

private struct AGModelInfo: Decodable {
    let displayName: String?
    let quotaInfo: AGQuotaInfo?
}

private struct AGQuotaInfo: Decodable {
    let remainingFraction: Double?
    let resetTime: String?
}

// MARK: - Errors

enum AntigravityError: Error, LocalizedError {
    case noAuthFile
    case tokenParseFailure
    case apiFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAuthFile: "Antigravity auth file not found in ~/.cli-proxy-api/"
        case .tokenParseFailure: "Could not parse access_token from Antigravity auth file."
        case .apiFailed(let msg): "Antigravity API error: \(msg)"
        }
    }
}
