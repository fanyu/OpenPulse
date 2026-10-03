import Foundation
import AppKit
import CryptoKit
import Network
import Security

actor CodexAccountService {
    struct SmartSwitchDecision: Sendable {
        let account: CodexAccountSnapshot
        let usedCLIFallback: Bool
        let isAutomatic: Bool
    }

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

    private enum SmartSwitchPolicy {
        static let weeklyWeight = 0.7
        static let sessionWeight = 0.3
        static let minimumScoreGain = 15.0
        static let cooldown: TimeInterval = 10 * 60
        static let maximumObservationAge: TimeInterval = 10 * 60

        static func score(for account: CodexAccountSnapshot, at now: Date) -> Double {
            guard reliableWindows(for: account, at: now) != nil else { return 0 }
            let weeklyRemaining = account.limits?.oneWeekWindow?.remainingPercent ?? 0
            let sessionRemaining = account.limits?.fiveHourWindow?.remainingPercent ?? 0
            return weeklyRemaining * weeklyWeight + sessionRemaining * sessionWeight
        }

        static func isExhausted(_ account: CodexAccountSnapshot, at now: Date) -> Bool {
            guard let windows = reliableWindows(for: account, at: now) else { return false }
            return windows.contains { ($0.usedPercent ?? 0) >= 100 }
        }

        static func canSwitchTo(_ account: CodexAccountSnapshot, at now: Date) -> Bool {
            guard let windows = reliableWindows(for: account, at: now) else { return false }
            return windows.allSatisfy { ($0.usedPercent ?? 100) < 100 }
        }

        private static func reliableWindows(for account: CodexAccountSnapshot, at now: Date) -> [CodexWindow]? {
            guard account.usageError == nil,
                  let limits = account.limits,
                  let observedAt = limits.observedAt,
                  (0...maximumObservationAge).contains(now.timeIntervalSince(observedAt)),
                  limits.hasUsableGeneralWindow(at: now) else { return nil }
            let windows = [limits.fiveHourWindow, limits.oneWeekWindow].compactMap { $0 }
            guard !windows.isEmpty, windows.allSatisfy({ window in
                guard let used = window.usedPercent, used.isFinite, (0...100).contains(used),
                      let reset = window.resetsAt, reset.isFinite else { return false }
                return reset > now.timeIntervalSince1970
            }) else { return nil }
            return windows
        }
    }

    private enum ServiceError: LocalizedError {
        case invalidAuthFile
        case missingAccountID
        case callbackOpenFailed
        case callbackFailed(String)
        case accountNotFound
        case invalidAccountStore
        case missingCredential
        case credentialVerificationFailed
        case credentialRestoreFailed
        case currentAccountCannotBeDeleted
        case authRestoreFailed

        var errorDescription: String? {
            switch self {
            case .invalidAuthFile: "Codex auth.json 格式无效。"
            case .missingAccountID: "未能从 Codex 认证信息中提取账号 ID。"
            case .callbackOpenFailed: "无法打开浏览器完成 OpenAI 登录。"
            case .callbackFailed(let message): message
            case .accountNotFound: "未找到对应的 Codex 账号。"
            case .invalidAccountStore: String(localized: "Codex 账号文件无效，原文件已保留。")
            case .missingCredential: String(localized: "Codex 账号凭证不可用，请重新导入或登录。")
            case .credentialVerificationFailed: String(localized: "无法确认 Codex 账号凭证已安全保存，原账号文件已保留。")
            case .credentialRestoreFailed: String(localized: "Codex 账号保存失败，凭证恢复也未完成，请重新导入或登录。")
            case .currentAccountCannotBeDeleted: String(localized: "请先切换到其他 Codex 账号，再删除当前账号。")
            case .authRestoreFailed: String(localized: "Codex 账号状态保存失败，当前认证文件恢复也未完成。")
            }
        }
    }

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
    private let userDefaults: UserDefaults
    private let credentialOperations: CredentialOperations
    private let writeStoreData: @Sendable (Data, URL) throws -> Void
    private let writeAuthData: @Sendable (Data, URL) throws -> Void
    private let relaunchOperation: (@Sendable () async throws -> Bool)?
    private let autoSwitchTimestampKey = "codex.smartSwitch.lastAt"
    private var isAutoSwitching = false

    init(
        fileManager: FileManager = .default,
        session: URLSession = .shared,
        userDefaults: UserDefaults = .standard,
        storeURL: URL? = nil,
        codexAuthURL: URL? = nil,
        codexConfigURL: URL? = nil,
        credentialOperations: CredentialOperations = .keychain,
        writeStoreData: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) },
        writeAuthData: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) },
        relaunchOperation: (@Sendable () async throws -> Bool)? = nil
    ) {
        self.fileManager = fileManager
        self.session = session
        self.userDefaults = userDefaults
        let resolvedStoreURL = storeURL ?? URL.homeDirectory.appending(path: ".openpulse/codex-accounts.json")
        self.storeURL = resolvedStoreURL
        supportDir = resolvedStoreURL.deletingLastPathComponent()
        self.codexAuthURL = codexAuthURL ?? URL.homeDirectory.appending(path: ".codex/auth.json")
        self.codexConfigURL = codexConfigURL ?? URL.homeDirectory.appending(path: ".codex/config.toml")
        self.credentialOperations = credentialOperations
        self.writeStoreData = writeStoreData
        self.writeAuthData = writeAuthData
        self.relaunchOperation = relaunchOperation
    }

    static func keychainKey(recordID: String) -> String { "codex_account_auth_\(recordID)" }

    func listAccounts() async throws -> [CodexAccountSnapshot] {
        let store = try loadStore()
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

    func switchAccount(id: String, relaunchCodex: Bool = true) async throws -> Bool {
        var store = try loadStore()
        guard let account = store.accounts.first(where: { $0.id == id }) else {
            throw ServiceError.accountNotFound
        }
        let previousAuth = fileManager.fileExists(atPath: codexAuthURL.path) ? try Data(contentsOf: codexAuthURL) : nil
        try writeCurrentAuthString(account.authJSONString)
        store.currentAccountID = account.accountID
        do {
            try saveStore(store)
        } catch {
            do {
                if let previousAuth {
                    try writeAuthData(previousAuth, codexAuthURL)
                } else {
                    try fileManager.removeItem(at: codexAuthURL)
                }
            } catch {
                throw ServiceError.authRestoreFailed
            }
            throw error
        }
        if relaunchCodex {
            do {
                if let relaunchOperation { return try await relaunchOperation() }
                return try await relaunchCodexApp()
            } catch {
                throw ServiceError.callbackFailed(String(localized: "账号已切换，但 Codex 重新启动失败：\(error.localizedDescription)"))
            }
        }
        return false
    }

    func relaunchCodex() async throws -> Bool {
        try await relaunchCodexApp()
    }

    func smartSwitch() async throws -> SmartSwitchDecision? {
        let accounts = try await listAccounts()
        guard let target = bestAccountToSwitch(from: accounts, requireCurrentExhausted: false, enforceMinimumGain: false) else {
            return nil
        }
        let usedCLIFallback = try await switchAccount(id: target.id, relaunchCodex: true)
        await AppLogger.shared.info("Codex smart switch: switched to \(target.titleText)")
        return SmartSwitchDecision(account: target, usedCLIFallback: usedCLIFallback, isAutomatic: false)
    }

    func autoSmartSwitchIfNeeded(accounts: [CodexAccountSnapshot]? = nil) async throws -> SmartSwitchDecision? {
        guard !isAutoSwitching else { return nil }
        isAutoSwitching = true
        defer { isAutoSwitching = false }
        let candidates = if let accounts {
            accounts
        } else {
            try await listAccounts()
        }
        guard let target = bestAccountToSwitch(from: candidates, requireCurrentExhausted: true, enforceMinimumGain: true) else {
            return nil
        }
        let lastAt = userDefaults.object(forKey: autoSwitchTimestampKey) as? Date
        let now = Date()
        if let lastAt, now.timeIntervalSince(lastAt) < SmartSwitchPolicy.cooldown {
            return nil
        }

        let usedCLIFallback = try await switchAccount(id: target.id, relaunchCodex: true)
        userDefaults.set(now, forKey: autoSwitchTimestampKey)
        await AppLogger.shared.warning("Codex auto smart switch: switched to \(target.titleText)")
        return SmartSwitchDecision(account: target, usedCLIFallback: usedCLIFallback, isAutomatic: true)
    }

    func deleteAccount(id: String) async throws {
        var store = try loadStore()
        guard let removed = store.accounts.first(where: { $0.id == id }) else { return }
        guard currentAccountID(from: store) != removed.accountID else { throw ServiceError.currentAccountCannotBeDeleted }
        store.accounts.removeAll { $0.id == id }
        // Commit the list first; failed metadata writes must retain the credential.
        try saveStore(store)
        try credentialOperations.delete(Self.keychainKey(recordID: removed.id))
    }

    func refreshAllUsage(force: Bool = false) async throws -> [CodexAccountSnapshot] {
        let now = Date()
        let store = try reconcileCurrentAuthIntoStore()
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

        try mergeRefreshedAccounts(refreshedAccounts)
        return try await listAccounts()
    }

    func applyLocalRateLimitsToCurrentAccount(_ limits: CodexRateLimits) async throws -> [CodexAccountSnapshot] {
        let now = Date()
        var store = try reconcileCurrentAuthIntoStore()
        let currentAccountID = currentAccountID(from: store)

        if let currentAccountID,
           let index = store.accounts.firstIndex(where: { $0.accountID == currentAccountID }) {
            let mergedLimits = store.accounts[index].lastUsage?.merging(limits) ?? limits
            store.accounts[index].lastUsage = mergedLimits
            store.accounts[index].planType = mergedLimits.planType ?? store.accounts[index].planType
            store.accounts[index].lastFetchedAt = now
            store.accounts[index].updatedAt = now
            store.accounts[index].usageError = nil
            try saveStore(store)
        }

        return try await listAccounts()
    }

    func refreshCurrentUsage(force: Bool = true) async throws -> [CodexAccountSnapshot] {
        let now = Date()
        let store = try reconcileCurrentAuthIntoStore()
        guard let activeAccountID = currentAccountID(from: store),
              let account = store.accounts.first(where: { $0.accountID == activeAccountID }) else {
            return try await listAccounts()
        }

        let refreshed = await Self.refreshAccount(
            account,
            now: now,
            forceRefresh: force,
            session: session,
            usageURLs: resolveUsageURLs()
        )

        try mergeRefreshedAccounts([refreshed])
        return try await listAccounts()
    }

    func currentAccountHasResetCreditDetails() async throws -> Bool {
        let store = try reconcileCurrentAuthIntoStore()
        guard let currentAccountID = currentAccountID(from: store),
              let account = store.accounts.first(where: { $0.accountID == currentAccountID }) else {
            return false
        }
        return account.lastUsage?.resetCredits?.credits?.isEmpty == false
    }

    func refreshStaleUsage(excludingCurrentAccount: Bool) async throws -> [CodexAccountSnapshot] {
        let now = Date()
        let store = try reconcileCurrentAuthIntoStore()
        let activeAccountID = currentAccountID(from: store)
        let usageURLs = resolveUsageURLs()
        let accountsToRefresh = store.accounts.filter { account in
            if excludingCurrentAccount, account.accountID == activeAccountID {
                return false
            }
            return shouldRefreshStaleUsage(for: account, now: now)
        }

        guard !accountsToRefresh.isEmpty else {
            return try await listAccounts()
        }

        let refreshedAccounts = await withTaskGroup(of: CodexStoredAccount.self, returning: [CodexStoredAccount].self) { group in
            for account in accountsToRefresh {
                group.addTask { [session] in
                    await Self.refreshAccount(
                        account,
                        now: now,
                        forceRefresh: true,
                        session: session,
                        usageURLs: usageURLs
                    )
                }
            }

            var refreshed: [CodexStoredAccount] = []
            refreshed.reserveCapacity(accountsToRefresh.count)
            for await account in group {
                refreshed.append(account)
            }
            return refreshed
        }

        try mergeRefreshedAccounts(refreshedAccounts)
        return try await listAccounts()
    }

    func syncCurrentSelectionFromAuthFile() async throws {
        _ = try reconcileCurrentAuthIntoStore()
    }

    /// Actor reentrancy permits account edits while requests await their responses.
    /// Rebase onto durable state, retaining edits and ignoring deleted/rotated records.
    private func mergeRefreshedAccounts(_ refreshedAccounts: [CodexStoredAccount]) throws {
        var store = try reconcileCurrentAuthIntoStore()
        var changed = false
        for refreshed in refreshedAccounts {
            guard let index = store.accounts.firstIndex(where: { $0.id == refreshed.id }),
                  store.accounts[index].accountID == refreshed.accountID,
                  store.accounts[index].authJSONString == refreshed.authJSONString,
                  let fetchedAt = refreshed.lastFetchedAt,
                  fetchedAt >= (store.accounts[index].lastFetchedAt ?? .distantPast) else { continue }
            if let incoming = refreshed.lastUsage {
                store.accounts[index].lastUsage = store.accounts[index].lastUsage?.merging(incoming) ?? incoming
            }
            store.accounts[index].lastFetchedAt = fetchedAt
            store.accounts[index].usageError = refreshed.usageError
            if refreshed.usageError == nil {
                store.accounts[index].planType = refreshed.planType ?? store.accounts[index].planType
                store.accounts[index].updatedAt = max(store.accounts[index].updatedAt, refreshed.updatedAt)
            }
            changed = true
        }
        if changed { try saveStore(store) }
    }

    private func shouldRefreshStaleUsage(for account: CodexStoredAccount, now: Date) -> Bool {
        guard let window = account.lastUsage?.fiveHourWindow,
              let resetDate = window.resetDate else {
            return true
        }
        return resetDate <= now
    }

    private func currentAccountID(from store: CodexAccountsStore) -> String? {
        if let current = currentAuthAccountID() { return current }
        return store.currentAccountID
    }

    private func reconcileCurrentAuthIntoStore() throws -> CodexAccountsStore {
        let currentAuth = try? readCurrentAuthString()
        let currentExtracted = currentAuth.flatMap { try? extractAuth(from: $0) }
        var store = try loadStore(replacingCredentialFor: currentExtracted?.accountID)
        guard let authJSONString = currentAuth, let extracted = currentExtracted else {
            store.currentAccountID = currentAuthAccountID()
            return store
        }

        let now = Date()
        if let index = store.accounts.firstIndex(where: { $0.accountID == extracted.accountID }) {
            let original = store.accounts[index]
            store.accounts[index].migrateLegacyUsageObservation()
            store.accounts[index].email = extracted.email
            store.accounts[index].planType = extracted.planType
            store.accounts[index].teamName = extracted.teamName
            store.accounts[index].authJSONString = authJSONString
            let credentialChanged = original.authJSONString != authJSONString
            let metadataChanged = original.email != extracted.email || original.planType != extracted.planType
                || original.teamName != extracted.teamName || original.lastUsage?.observedAt != store.accounts[index].lastUsage?.observedAt
            if credentialChanged || metadataChanged { store.accounts[index].updatedAt = now }
            let selectionChanged = store.currentAccountID != extracted.accountID
            store.currentAccountID = extracted.accountID
            if credentialChanged {
                try persistCredential(authJSONString, recordID: original.id, store: store)
            } else if metadataChanged || selectionChanged {
                try saveStore(store)
            }
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
            store.currentAccountID = extracted.accountID
            try persistCredential(authJSONString, recordID: store.accounts[store.accounts.count - 1].id, store: store)
        }

        store.currentAccountID = extracted.accountID
        return store
    }

    // Also used by fixture tests; OAuth and import share this single transaction.
    func upsertAccount(authJSONString: String, customLabel: String?, setAsCurrent: Bool) throws -> CodexStoredAccount {
        let extracted = try extractAuth(from: authJSONString)
        var store = try loadStore(replacingCredentialFor: extracted.accountID)
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
            store.currentAccountID = extracted.accountID
        }

        try persistCredential(authJSONString, recordID: account.id, store: store)
        return account
    }

    private func persistCredential(_ authJSONString: String, recordID: String, store: CodexAccountsStore) throws {
        let key = Self.keychainKey(recordID: recordID)
        let previousCredential = try credentialOperations.retrieve(key)
        var cleanupWarning: KeychainError?
        do {
            try credentialOperations.store(key, authJSONString)
        } catch KeychainError.legacyCleanupFailed(let status) {
            cleanupWarning = .legacyCleanupFailed(status)
        }
        do {
            guard try credentialOperations.retrieve(key) == authJSONString else { throw ServiceError.credentialVerificationFailed }
            try saveStore(store)
        } catch {
            do {
                if let previousCredential {
                    try credentialOperations.store(key, previousCredential)
                } else {
                    try credentialOperations.delete(key)
                }
            } catch {
                throw ServiceError.credentialRestoreFailed
            }
            throw error
        }
        if let cleanupWarning { throw cleanupWarning }
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

    private func bestAccountToSwitch(
        from accounts: [CodexAccountSnapshot],
        requireCurrentExhausted: Bool,
        enforceMinimumGain: Bool
    ) -> CodexAccountSnapshot? {
        let now = Date()
        guard let current = accounts.first(where: \.isCurrent) else {
            return requireCurrentExhausted ? nil : rankedAccounts(accounts, at: now).first
        }
        if requireCurrentExhausted && !SmartSwitchPolicy.isExhausted(current, at: now) {
            return nil
        }

        let rankedAlternatives = rankedAccounts(accounts.filter { $0.id != current.id }, at: now)
        guard let best = rankedAlternatives.first else { return nil }

        if enforceMinimumGain {
            let gain = SmartSwitchPolicy.score(for: best, at: now) - SmartSwitchPolicy.score(for: current, at: now)
            guard gain >= SmartSwitchPolicy.minimumScoreGain else { return nil }
        }

        return best
    }

    private func rankedAccounts(_ accounts: [CodexAccountSnapshot], at now: Date) -> [CodexAccountSnapshot] {
        accounts.filter { SmartSwitchPolicy.canSwitchTo($0, at: now) }.sorted { lhs, rhs in
            let leftScore = SmartSwitchPolicy.score(for: lhs, at: now)
            let rightScore = SmartSwitchPolicy.score(for: rhs, at: now)
            if leftScore != rightScore { return leftScore > rightScore }
            if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent && !rhs.isCurrent }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private func loadStore(replacingCredentialFor replacementAccountID: String? = nil) throws -> CodexAccountsStore {
        guard fileManager.fileExists(atPath: storeURL.path) else { return CodexAccountsStore() }
        let data = try Data(contentsOf: storeURL)
        var store = try JSONDecoder().decode(CodexAccountsStore.self, from: data)
        guard (1...2).contains(store.version),
              store.accounts.allSatisfy({ !$0.id.isEmpty && !$0.accountID.isEmpty }),
              Set(store.accounts.map(\.id)).count == store.accounts.count,
              Set(store.accounts.map(\.accountID)).count == store.accounts.count else { throw ServiceError.invalidAccountStore }

        let requiresMigration = store.version < 2 || store.accounts.contains { !$0.authJSONString.isEmpty }
        for index in store.accounts.indices {
            let key = Self.keychainKey(recordID: store.accounts[index].id)
            let legacyAuth = store.accounts[index].authJSONString
            if !legacyAuth.isEmpty {
                guard try Self.extractAuth(from: legacyAuth).accountID == store.accounts[index].accountID else {
                    throw ServiceError.invalidAccountStore
                }
                // All credentials must be secured and verified before the original
                // legacy file is replaced. Any failure keeps its bytes untouched.
                try credentialOperations.store(key, legacyAuth)
                guard try credentialOperations.retrieve(key) == legacyAuth else { throw ServiceError.credentialVerificationFailed }
            } else {
                let credential = try credentialOperations.retrieve(key)
                if !requiresMigration, credential?.isEmpty != false, store.accounts[index].accountID == replacementAccountID {
                    // A validated re-import may restore this credential. All other
                    // reads still reject incomplete v2 metadata explicitly.
                    continue
                }
                guard let auth = credential, !auth.isEmpty,
                      try Self.extractAuth(from: auth).accountID == store.accounts[index].accountID else {
                    throw ServiceError.missingCredential
                }
                store.accounts[index].authJSONString = auth
            }
        }
        if requiresMigration {
            store.version = 2
            try saveStore(store)
        }
        return store
    }

    private func saveStore(_ store: CodexAccountsStore) throws {
        try fileManager.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var metadata = store
        metadata.version = 2
        let data = try encoder.encode(metadata)
        try writeStoreData(data, storeURL)
        chmod(storeURL.path, S_IRUSR | S_IWUSR)
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
        try writeAuthData(Data(jsonString.utf8), codexAuthURL)
        chmod(codexAuthURL.path, S_IRUSR | S_IWUSR)
    }

    private func relaunchCodexApp(workspacePath: String? = nil) async throws -> Bool {
        forceStopRunningCodex()
        try await waitForCodexProcessToExit(timeoutSeconds: 3)

        if let appPath = findCodexAppPath() {
            do {
                try launchCodexBundleApp(at: appPath, workspacePath: workspacePath)
                if await waitForCodexProcess(timeoutSeconds: 2) {
                    return false
                }
            } catch {
                await AppLogger.shared.warning("Codex relaunch via app failed: \(error.localizedDescription)")
            }
        }

        try launchViaCodexCLI(workspacePath: workspacePath)
        return true
    }

    private func forceStopRunningCodex() {
        _ = try? runProcess("/usr/bin/osascript", arguments: ["-e", "tell application \"Codex\" to quit"])
        _ = try? runProcess("/usr/bin/osascript", arguments: ["-e", "tell application \"Codex Desktop\" to quit"])
        _ = try? runProcess("/usr/bin/pkill", arguments: ["-9", "-x", "Codex"])
        _ = try? runProcess("/usr/bin/pkill", arguments: ["-9", "-x", "Codex Desktop"])
    }

    private func waitForCodexProcessToExit(timeoutSeconds: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if !isCodexProcessRunning() { return }
            try await Task.sleep(for: .milliseconds(120))
        }
    }

    private func waitForCodexProcess(timeoutSeconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if isCodexProcessRunning() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private func isCodexProcessRunning() -> Bool {
        let codex = try? runProcess("/usr/bin/pgrep", arguments: ["-x", "Codex"])
        if codex?.terminationStatus == 0 { return true }
        let desktop = try? runProcess("/usr/bin/pgrep", arguments: ["-x", "Codex Desktop"])
        return desktop?.terminationStatus == 0
    }

    private func findCodexAppPath() -> URL? {
        let home = fileManager.homeDirectoryForCurrentUser
        let candidates = [
            URL(fileURLWithPath: "/Applications/Codex.app"),
            URL(fileURLWithPath: "/Applications/Codex Desktop.app"),
            home.appendingPathComponent("Applications/Codex.app"),
            home.appendingPathComponent("Applications/Codex Desktop.app")
        ]
        if let found = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) {
            return found
        }
        return spotlightFindApp(named: "Codex.app") ?? spotlightFindApp(named: "Codex Desktop.app")
    }

    private func launchCodexBundleApp(at appPath: URL, workspacePath: String?) throws {
        var arguments = ["-na", appPath.path]
        if let workspacePath, !workspacePath.isEmpty {
            arguments.append(workspacePath)
        }
        let result = try runProcess("/usr/bin/open", arguments: arguments)
        guard result.terminationStatus == 0 else {
            throw ServiceError.callbackFailed("无法重启 Codex App。")
        }
    }

    private func launchViaCodexCLI(workspacePath: String?) throws {
        let codexPath = try findCodexCLIPath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: codexPath)
        process.arguments = workspacePath?.isEmpty == false ? ["app", workspacePath!] : ["app"]
        process.environment = mergedPathEnvironment(for: codexPath)
        do {
            try process.run()
        } catch {
            throw ServiceError.callbackFailed("无法通过 codex CLI 重启 Codex。")
        }
    }

    private func findCodexCLIPath() throws -> String {
        let home = fileManager.homeDirectoryForCurrentUser
        let candidates: [URL] = [
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
            URL(fileURLWithPath: "/usr/bin/codex"),
            home.appendingPathComponent(".local/bin/codex"),
            home.appendingPathComponent(".npm-global/bin/codex"),
            home.appendingPathComponent(".volta/bin/codex"),
            home.appendingPathComponent(".asdf/shims/codex"),
            home.appendingPathComponent("Library/pnpm/codex"),
            home.appendingPathComponent("bin/codex")
        ]

        if let fromPATH = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init)
            .map({ URL(fileURLWithPath: $0).appendingPathComponent("codex") })
            .first(where: isExecutable) {
            return fromPATH.path
        }

        if let match = candidates.first(where: isExecutable) {
            return match.path
        }

        throw ServiceError.callbackFailed("未找到 codex CLI。")
    }

    private func mergedPathEnvironment(for executablePath: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let current = env["PATH"] ?? ""
        let parent = URL(fileURLWithPath: executablePath).deletingLastPathComponent().path
        env["PATH"] = parent + (current.isEmpty ? "" : ":\(current)")
        return env
    }

    private func isExecutable(_ url: URL) -> Bool {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let type = attrs[.type] as? FileAttributeType,
              type == .typeRegular,
              let perm = attrs[.posixPermissions] as? NSNumber else {
            return false
        }
        return perm.intValue & 0o111 != 0
    }

    private func spotlightFindApp(named appName: String) -> URL? {
        guard let result = try? runProcess("/usr/bin/mdfind", arguments: ["kMDItemFSName == '\(appName)'"]),
              result.terminationStatus == 0 else {
            return nil
        }
        let firstLine = String(decoding: result.output, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        guard let path = firstLine, fileManager.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    @discardableResult
    func runProcess(_ launchPath: String, arguments: [String]) throws -> CodexAccountProcessResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Drain while the child runs: a full stdout/stderr pipe otherwise blocks
        // the child before it can exit and satisfy waitUntilExit().
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CodexAccountProcessResult(terminationStatus: process.terminationStatus, output: output)
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
        let verifier = OAuthPKCE.randomBase64URL(byteCount: 32)
        let challenge = OAuthPKCE.sha256Base64URL(verifier)
        let state = OAuthPKCE.randomBase64URL(byteCount: 32)
        let (server, port) = try await makeCallbackServer(callback: callback, verifier: verifier, state: state)
        defer { server.stop() }
        let redirectURI = "http://localhost:\(port)\(OAuthConfiguration.callbackPath)"
        let forcedWorkspaceID = resolveForcedWorkspaceID()
        let authorizeURL = try makeAuthorizeURL(
            redirectURI: redirectURI,
            challenge: challenge,
            state: state,
            forcedWorkspaceID: forcedWorkspaceID
        )

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
    ) async throws -> (SimpleHTTPServer, UInt16) {
        var candidatePort = OAuthConfiguration.callbackPort
        let maxPort = OAuthConfiguration.callbackPort + OAuthConfiguration.maxPortOffset
        var lastError: Error?

        while candidatePort <= maxPort {
            try Task.checkCancellation()
            do {
                let redirectURI = "http://localhost:\(candidatePort)\(OAuthConfiguration.callbackPath)"
                let server = try SimpleHTTPServer(port: candidatePort) { [session] request in
                    guard request.path == OAuthConfiguration.callbackPath else {
                        return .text(statusCode: 404, text: "Not Found")
                    }
                    guard let params = oauthCallbackParameters(request.queryItems) else {
                        return .text(statusCode: 400, text: "Duplicate callback parameters")
                    }
                    guard params["state"] == state else {
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
                do {
                    try await server.start()
                } catch {
                    server.stop()
                    throw error
                }
                return (server, candidatePort)
            } catch {
                try Task.checkCancellation()
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
            account.lastUsage = account.lastUsage?.merging(limits) ?? limits
            account.planType = account.planType ?? account.lastUsage?.planType
            account.lastFetchedAt = now
            account.updatedAt = now
            account.usageError = nil
        } catch {
            account.usageError = error.localizedDescription
            account.lastFetchedAt = now
        }

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
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let payload = try decoder.decode(CodexUsageAPIResponse.self, from: data)
                let limits = payload.toRateLimits(observedAt: Date())
                let resetCredits: CodexResetCredits?
                do {
                    resetCredits = try await fetchResetCredits(
                        accessToken: accessToken,
                        accountID: accountID,
                        session: session,
                        usageURL: url,
                        decoder: decoder
                    )
                } catch {
                    resetCredits = nil
                    await AppLogger.shared.recordDiagnostic(scope: "codex.resetCredits", message: error.localizedDescription)
                }
                return limits.replacingResetCredits(resetCredits ?? limits.resetCredits)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? ServiceError.callbackFailed("Codex usage 获取失败。")
    }

    private static func fetchResetCredits(
        accessToken: String,
        accountID: String,
        session: URLSession,
        usageURL: URL,
        decoder: JSONDecoder
    ) async throws -> CodexResetCredits {
        guard let url = resetCreditsURL(for: usageURL) else {
            throw ServiceError.callbackFailed("Codex reset credits 地址无效。")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 18
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex-tools-swift/0.1", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.callbackFailed("Codex reset credits 响应无效。")
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 {
                throw ServiceError.callbackFailed("Codex reset credits 获取失败: HTTP 401，凭证失效或 Authorization header 缺失。")
            }
            throw ServiceError.callbackFailed("Codex reset credits 获取失败: HTTP \(http.statusCode)")
        }
        return try decoder.decode(CodexResetCredits.self, from: data)
    }

    private static func resetCreditsURL(for usageURL: URL) -> URL? {
        let path = usageURL.path
        guard path.contains("/wham/usage") else {
            return nil
        }
        var components = URLComponents(url: usageURL, resolvingAgainstBaseURL: false)
        components?.path = path.replacingOccurrences(of: "/wham/usage", with: "/wham/rate-limit-reset-credits")
        components?.query = nil
        return components?.url
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

}

struct CodexAccountProcessResult: Sendable {
    let terminationStatus: Int32
    let output: Data
}

struct CodexUsageAPIResponse: Decodable {
    let planType: String?
    let rateLimit: CodexUsageRateLimit?
    let additionalRateLimits: [CodexUsageAdditionalRateLimit]?
    let credits: CodexCredits?
    let resetCredits: CodexResetCredits?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case additionalRateLimits = "additional_rate_limits"
        case credits
        case resetCredits = "rate_limit_reset_credits"
    }

    func toRateLimits(observedAt: Date? = nil) -> CodexRateLimits {
        let namedLimits = (additionalRateLimits ?? []).compactMap { item -> CodexNamedRateLimit? in
            guard let rawID = item.meteredFeature?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawID.isEmpty,
                  rawID.caseInsensitiveCompare("codex") != .orderedSame,
                  let rateLimit = item.rateLimit else { return nil }
            let primary = rateLimit.primaryWindow
            let secondary = rateLimit.secondaryWindow
            guard [primary, secondary]
                .compactMap({ $0 })
                .contains(where: { $0.durationSeconds == 5 * 60 * 60 || $0.durationSeconds == 7 * 24 * 60 * 60 }) else {
                return nil
            }
            return CodexNamedRateLimit(
                id: rawID.lowercased(),
                name: item.limitName,
                primary: primary,
                secondary: secondary,
                observedAt: observedAt
            )
        }.sorted { $0.id < $1.id }

        let hasGeneralRateLimit = [rateLimit?.primaryWindow, rateLimit?.secondaryWindow]
            .compactMap { $0 }
            .contains { $0.durationSeconds == 5 * 60 * 60 || $0.durationSeconds == 7 * 24 * 60 * 60 }
        return CodexRateLimits(
            primary: rateLimit?.primaryWindow,
            secondary: rateLimit?.secondaryWindow,
            credits: credits,
            resetCredits: resetCredits,
            planType: planType,
            limitID: hasGeneralRateLimit ? "codex" : nil,
            observedAt: hasGeneralRateLimit ? observedAt : nil,
            additionalLimits: namedLimits.isEmpty ? nil : namedLimits
        )
    }
}

struct CodexUsageRateLimit: Decodable {
    let primaryWindow: CodexWindow?
    let secondaryWindow: CodexWindow?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

struct CodexUsageAdditionalRateLimit: Decodable {
    let meteredFeature: String?
    let limitName: String?
    let rateLimit: CodexUsageRateLimit?

    enum CodingKeys: String, CodingKey {
        case meteredFeature = "metered_feature"
        case limitName = "limit_name"
        case rateLimit = "rate_limit"
    }
}
