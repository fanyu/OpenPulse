import Foundation
import Security

/// Thread-safe Keychain wrapper for storing API tokens.
enum KeychainService {
    struct GenericPasswordRecord: Sendable {
        let account: String?
        let value: String
    }

    private static let service = "com.fanyu.openpulse"

    static func store(key: String, value: String) throws {
        let data = Data(value.utf8)
        // Delete from both keychains to handle migration from legacy items.
        let legacyQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
        ]
        SecItemDelete(legacyQuery as CFDictionary)
        let dpQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecUseDataProtectionKeychain: true,
        ]
        SecItemDelete(dpQuery as CFDictionary)
        let attributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
            kSecUseDataProtectionKeychain: true,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.storeFailed(status)
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
        let base: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
        ]
        SecItemDelete(base as CFDictionary)
        SecItemDelete((base.merging([kSecUseDataProtectionKeychain: true]) { $1 }) as CFDictionary)
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
    case retrieveFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .storeFailed(let s): "Keychain store failed: \(s)"
        case .retrieveFailed(let s): "Keychain retrieve failed: \(s)"
        }
    }
}
