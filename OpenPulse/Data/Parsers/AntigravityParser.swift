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
    private let retrieveUserQuotaSummaryEndpoint = "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"
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

    func fetchAllAccountQuotas() async throws -> AGQuotaFetchResult {
        let authFiles = try authFilesByEmail()
        guard !authFiles.isEmpty else { throw AntigravityError.noAuthFile }

        var accounts: [AGAccountQuota] = []
        var lastError: Error?

        for (_, file) in authFiles {
            do {
                let account = try await fetchAccountQuota(from: file)
                accounts.append(account)
            } catch {
                print("[OpenPulse] Antigravity account \(file.lastPathComponent) failed: \(error.localizedDescription)")
                lastError = error
            }
        }

        if accounts.isEmpty, let err = lastError { throw err }
        return AGQuotaFetchResult(accounts: accounts, orderedEmails: authFiles.map(\.key))
    }

    /// Fetches quota for ALL Antigravity accounts found in ~/.cli-proxy-api/antigravity-*.json.
    /// Returns a ToolQuota whose `raw` value is `[AGAccountQuota]` (one per account).
    /// The summary `remaining` is the minimum remaining fraction across all accounts/models.
    func fetchQuota() async throws -> ToolQuota {
        let result = try await fetchAllAccountQuotas()
        return toolQuota(from: result.accounts)
    }

    func fetchQuota(forAccountEmail email: String) async throws -> AGAccountQuota {
        let authFiles = try authFilesByEmail()
        guard let file = authFiles.first(where: { $0.key == email })?.value else {
            throw AntigravityError.noAuthFile
        }
        return try await fetchAccountQuota(from: file)
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

        let (projectId, tier) = try await fetchProjectAndTier(token: token)
        let groups = try await fetchQuotaSummary(token: token, projectId: projectId)
        return AGAccountQuota(email: email, tier: tier, groups: groups)
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

    private func fetchProjectAndTier(token: String) async throws -> (projectId: String?, tier: AGTier?) {
        var request = URLRequest(url: URL(string: loadCodeAssistEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["metadata": ["ideType": "ANTIGRAVITY"]])
        request.timeoutInterval = 10

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return (nil, nil) }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AntigravityError.apiFailed("loadCodeAssist HTTP \(http.statusCode): \(body.prefix(200))")
        }
        let info = try? JSONDecoder().decode(AGLoadCodeAssistResponse.self, from: data)
        let tier = Self.decodeTier(from: data)
        return (info?.cloudaicompanionProject, tier)
    }

    private func fetchQuotaSummary(token: String, projectId: String?) async throws -> [AGQuotaGroup] {
        var request = URLRequest(url: URL(string: retrieveUserQuotaSummaryEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        var payload: [String: Any] = [:]
        if let projectId { payload["project"] = projectId }
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 10

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AntigravityError.apiFailed("No HTTP response from retrieveUserQuotaSummary")
        }
        if http.statusCode == 403 { throw AntigravityError.apiFailed("403 Forbidden – check Google auth") }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AntigravityError.apiFailed("retrieveUserQuotaSummary HTTP \(http.statusCode): \(body.prefix(200))")
        }
        return try Self.decodeQuotaGroups(from: data)
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

    private func authFilesByEmail() throws -> [(key: String, value: URL)] {
        guard FileManager.default.fileExists(atPath: proxyDir.path) else {
            throw AntigravityError.noAuthFile
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: proxyDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("antigravity-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }) ?? []
        guard !files.isEmpty else { throw AntigravityError.noAuthFile }

        var items: [(key: String, value: URL)] = []
        for file in files {
            let rawData = try? Data(contentsOf: file)
            let email = rawData
                .flatMap { try? JSONDecoder().decode(AntigravityAuthFile.self, from: $0).email }
                ?? emailFromFilename(file.deletingPathExtension().lastPathComponent)
            items.append((key: email, value: file))
        }
        return items
    }

    private func toolQuota(from accounts: [AGAccountQuota]) -> ToolQuota {
        let minFraction = accounts.compactMap(\.geminiRemainingFraction).min()
        let resetAt = accounts.compactMap(\.geminiEarliestReset).min()
        let remainingPct = minFraction.map { Int(($0 * 100).rounded()) }

        return ToolQuota(
            id: Tool.antigravity.rawValue,
            tool: .antigravity,
            accountKey: nil,
            accountLabel: nil,
            remaining: remainingPct,
            total: remainingPct == nil ? nil : 100,
            unit: .requests,
            resetAt: resetAt,
            updatedAt: Date(),
            raw: accounts as (any Sendable)
        )
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

struct AGWindow: Sendable {
    enum Kind: Sendable { case fiveHour, weekly }
    let kind: Kind
    let remainingFraction: Double?
    let resetTime: Date?
    let description: String?

    var remainingPercentText: String {
        guard let f = remainingFraction else { return "—" }
        return "\(Int((min(1, max(0, f)) * 100).rounded()))%"
    }
    /// Future-only; Antigravity sometimes returns reference-date placeholders.
    var validatedResetDate: Date? {
        guard let resetTime, resetTime > Date() else { return nil }
        return resetTime
    }
    var resetCountdown: String? {
        validatedResetDate.map { countdownString(to: $0) }
    }
}

struct AGQuotaGroup: Sendable, Identifiable {
    let id: String            // bucket prefix, e.g. "gemini" / "3p"
    let displayName: String
    let fiveHour: AGWindow?
    let weekly: AGWindow?
}

struct AGTier: Sendable {
    let id: String
    let name: String
    var isPaid: Bool { id != "free-tier" }
    var badgeLabel: String { isPaid ? "Google AI Pro" : "Free" }
}

/// Quota data for one Antigravity account, grouped by provider (Gemini / third-party) and time window.
struct AGAccountQuota: Sendable, Identifiable {
    /// Derived from the auth file name, e.g. "user@gmail.com"
    let email: String
    let tier: AGTier?
    let groups: [AGQuotaGroup]
    var id: String { email }

    /// Gemini group's worst remaining fraction (drives menu-bar aggregate).
    var geminiRemainingFraction: Double? {
        guard let g = groups.first(where: { $0.id == "gemini" }) else { return nil }
        return [g.fiveHour?.remainingFraction, g.weekly?.remainingFraction].compactMap { $0 }.min()
    }
    var geminiEarliestReset: Date? {
        guard let g = groups.first(where: { $0.id == "gemini" }) else { return nil }
        return [g.fiveHour?.validatedResetDate, g.weekly?.validatedResetDate].compactMap { $0 }.min()
    }

    // ponytail: temporary compat shim so MenuBarView/QuotaView/ProviderComponents/DataSyncService
    // (still built against the flat per-model shape) keep compiling until Tasks 2-5 rewire them
    // onto AGQuotaGroup/AGWindow directly. Remove once those call sites are migrated.
    @available(*, deprecated, message: "Task 2-5: migrate call sites to AGQuotaGroup/AGWindow, then delete")
    var models: [AGModelQuota] {
        groups.flatMap { group -> [AGModelQuota] in
            [
                (group.fiveHour, "5h"),
                (group.weekly, "Weekly")
            ].compactMap { window, label in
                guard let window else { return nil }
                return AGModelQuota(
                    id: "\(group.id)-\(label)",
                    displayName: "\(group.displayName) (\(label))",
                    remainingFraction: window.remainingFraction,
                    resetTime: window.resetTime.map { ISO8601DateFormatter().string(from: $0) }
                )
            }
        }
    }

    @available(*, deprecated, message: "Task 2-5: migrate call sites to AGQuotaGroup/AGWindow, then delete")
    var geminiModels: [AGModelQuota] { models.filter { $0.id.hasPrefix("gemini-") } }

    @available(*, deprecated, message: "Task 2-5: migrate to group-level refresh, then delete")
    func mergedPreferBetter(with newer: AGAccountQuota) -> AGAccountQuota {
        var order = groups.map(\.id)
        var byId = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        for group in newer.groups {
            if byId[group.id] == nil { order.append(group.id) }
            byId[group.id] = group
        }
        return AGAccountQuota(email: email, tier: newer.tier ?? tier, groups: order.compactMap { byId[$0] })
    }
}

@available(*, deprecated, message: "Task 2-5: migrate call sites to AGQuotaGroup/AGWindow, then delete")
struct AGModelQuota: Sendable {
    let id: String
    let displayName: String
    let remainingFraction: Double?
    let resetTime: String?

    var validatedResetDate: Date? {
        guard let t = resetTime, let date = parseISO8601Flexible(t), date > Date() else { return nil }
        return date
    }
    var formattedPercentage: String {
        guard let f = remainingFraction else { return "—" }
        return "\(Int((f * 100).rounded()))%"
    }
    var primaryValueText: String { formattedPercentage }
    var secondaryStatusText: String? {
        remainingFraction == nil && validatedResetDate != nil ? "额度未知" : nil
    }
    var resetCountdown: String? {
        validatedResetDate.map { countdownString(to: $0) }
    }
}

extension AntigravityParser {
    static func decodeQuotaGroups(from data: Data) throws -> [AGQuotaGroup] {
        let resp = try JSONDecoder().decode(AGQuotaSummaryResponse.self, from: data)
        return resp.groups.map { group in
            let byWindow = Dictionary(grouping: group.buckets, by: \.window)
            func window(_ key: String, _ kind: AGWindow.Kind) -> AGWindow? {
                guard let b = byWindow[key]?.first else { return nil }
                return AGWindow(
                    kind: kind,
                    remainingFraction: b.remainingFraction.map { min(1, max(0, $0)) },
                    resetTime: b.resetTime.flatMap(parseISO8601Flexible),
                    description: b.description
                )
            }
            return AGQuotaGroup(
                id: group.buckets.first?.bucketId.components(separatedBy: "-").first ?? group.displayName,
                displayName: group.displayName,
                fiveHour: window("5h", .fiveHour),
                weekly: window("weekly", .weekly)
            )
        }
    }

    static func decodeTier(from data: Data) -> AGTier? {
        guard let info = try? JSONDecoder().decode(AGLoadCodeAssistResponse.self, from: data),
              let tier = info.currentTier else { return nil }
        return AGTier(id: tier.id, name: tier.name)
    }
}

private struct AGQuotaSummaryResponse: Decodable {
    struct Group: Decodable { let displayName: String; let buckets: [Bucket] }
    struct Bucket: Decodable {
        let bucketId: String
        let window: String
        let resetTime: String?
        let remainingFraction: Double?
        let description: String?
    }
    let groups: [Group]
}

private struct AGLoadCodeAssistResponse: Decodable {
    struct Tier: Decodable { let id: String; let name: String }
    let currentTier: Tier?
    let cloudaicompanionProject: String?
}

struct AGQuotaFetchResult: Sendable {
    let accounts: [AGAccountQuota]
    let orderedEmails: [String]
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
