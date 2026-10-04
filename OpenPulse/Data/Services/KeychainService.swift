import Foundation
import Security

/// Thread-safe Keychain wrapper for storing API tokens.
enum KeychainService {
    struct GenericPasswordRecord: Sendable {
        let account: String?
        let value: String
    }

    private static let service = "com.fanyu.openpulse"

    /// Per-call operations make failure paths testable without a shared override or real Keychain access.
    struct StoreOperations {
        let update: ([CFString: Any], [CFString: Any]) -> OSStatus
        let add: ([CFString: Any]) -> OSStatus
        let deleteLegacy: ([CFString: Any]) -> OSStatus

        static var security: Self {
            final class State: @unchecked Sendable {
                var storedInLegacy = false
            }
            let state = State()
            return Self(
                update: { query, changes in
                    let status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
                    if (status == errSecMissingEntitlement || status == errSecNotAvailable) && (query[kSecUseDataProtectionKeychain] as? Bool == true) {
                        state.storedInLegacy = true
                        var fallbackQuery = query
                        fallbackQuery.removeValue(forKey: kSecUseDataProtectionKeychain)
                        return SecItemUpdate(fallbackQuery as CFDictionary, changes as CFDictionary)
                    }
                    return status
                },
                add: { query in
                    let status = SecItemAdd(query as CFDictionary, nil)
                    if (status == errSecMissingEntitlement || status == errSecNotAvailable) && (query[kSecUseDataProtectionKeychain] as? Bool == true) {
                        state.storedInLegacy = true
                        var fallbackQuery = query
                        fallbackQuery.removeValue(forKey: kSecUseDataProtectionKeychain)
                        return SecItemAdd(fallbackQuery as CFDictionary, nil)
                    }
                    return status
                },
                deleteLegacy: { query in
                    if state.storedInLegacy {
                        return errSecSuccess
                    }
                    return SecItemDelete(query as CFDictionary)
                }
            )
        }
    }

    static func store(key: String, value: String) throws {
        try store(key: key, value: value, operations: .security)
    }

    static func store(key: String, value: String, operations: StoreOperations) throws {
        let data = Data(value.utf8)
        let legacyQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
        ]
        let dpQuery = legacyQuery.merging([kSecUseDataProtectionKeychain: true]) { $1 }
        let changes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        // Never remove a working item to replace it: a failed write must preserve existing credentials.
        var status = operations.update(dpQuery, changes)
        if status == errSecItemNotFound {
            status = operations.add(dpQuery.merging(changes) { $1 })
            if status == errSecDuplicateItem {
                // Another writer may have inserted between the update and add.
                status = operations.update(dpQuery, changes)
            }
        }

        guard status == errSecSuccess else {
            throw KeychainError.storeFailed(status)
        }
        // The Data Protection item is saved before the legacy credential is removed.
        let cleanupStatus = operations.deleteLegacy(legacyQuery)
        guard cleanupStatus == errSecSuccess || cleanupStatus == errSecItemNotFound else {
            throw KeychainError.legacyCleanupFailed(cleanupStatus)
        }
    }

    static func retrieve(key: String) throws -> String? {
        // Try Data Protection Keychain first (new location), fall back to legacy.
        let dpQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain: true,
        ]
        var result: AnyObject?
        var status = SecItemCopyMatching(dpQuery as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            return String(decoding: data, as: UTF8.self)
        }
        // Legacy fallback (items stored before this change).
        let legacyQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        result = nil
        status = SecItemCopyMatching(legacyQuery as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.retrieveFailed(status)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Retrieve a generic password from any service (used to read tokens stored by other apps).
    /// Optionally filter by account; pass nil to return the first match for the service.
    static func retrieveGenericPassword(service: String, account: String? = nil) throws -> String? {
        try retrieveGenericPasswordRecord(service: service, account: account)?.value
    }

    static func retrieveGenericPasswordRecord(service: String, account: String? = nil) throws -> GenericPasswordRecord? {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnData: true,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        if let account { query[kSecAttrAccount] = account }
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let item = result as? [CFString: Any],
              let data = item[kSecValueData] as? Data else {
            throw KeychainError.retrieveFailed(status)
        }
        return GenericPasswordRecord(
            account: item[kSecAttrAccount] as? String,
            value: String(decoding: data, as: UTF8.self)
        )
    }

    static func delete(key: String) {
        try? deleteChecked(key: key)
    }

    static func deleteChecked(key: String) throws {
        try deleteChecked(key: key, operation: { SecItemDelete($0 as CFDictionary) })
    }

    /// Attempt both locations and report failures, so account metadata can remain until credential deletion succeeds.
    static func deleteChecked(key: String, operation: ([CFString: Any]) -> OSStatus) throws {
        let base: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
        ]
        let legacyStatus = operation(base)
        let dataProtectionStatus = operation(base.merging([kSecUseDataProtectionKeychain: true]) { $1 })
        for status in [legacyStatus, dataProtectionStatus] {
            guard status == errSecSuccess || status == errSecItemNotFound || status == errSecMissingEntitlement || status == errSecNotAvailable else {
                throw KeychainError.deleteFailed(status)
            }
        }
    }

    enum Keys {
        static let githubToken = "github_copilot_token"
        static let anthropicKey = "anthropic_api_key"
        static let openAIKey = "openai_api_key"
        static let dotAPIKey = "dot_api_key"
    }
}

enum KeychainError: Error, LocalizedError {
    case storeFailed(OSStatus)
    case legacyCleanupFailed(OSStatus)
    case deleteFailed(OSStatus)
    case retrieveFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .storeFailed(let s): "Keychain store failed: \(s)"
        case .legacyCleanupFailed(let s): "Credential saved, but legacy Keychain cleanup failed: \(s)"
        case .deleteFailed(let s): "Keychain delete failed: \(s)"
        case .retrieveFailed(let s): "Keychain retrieve failed: \(s)"
        }
    }
}
