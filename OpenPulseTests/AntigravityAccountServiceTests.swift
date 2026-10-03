import Testing
import Foundation
import Security
@testable import OpenPulse

struct AntigravityAccountServiceTests {
    @Test func emailFromIDTokenReadsEmailClaim() throws {
        let payload = try JSONSerialization.data(withJSONObject: ["email": "x@y.com"])
        let payloadBase64URL = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let fakeJWT = "header.\(payloadBase64URL).sig"

        let email = try AntigravityAccountService.email(fromIDToken: fakeJWT)
        #expect(email == "x@y.com")
    }

    @Test func keychainKeyFormatsEmail() {
        #expect(AntigravityAccountService.keychainKey(email: "x@y.com") == "antigravity_refresh_x@y.com")
    }
}

struct KeychainStorePreservationTests {
    @Test func updateFailurePreservesBothExistingCredentials() {
        let mock = KeychainStoreMock(updateStatuses: [errSecAuthFailed])
        expectStoreFailure(errSecAuthFailed, using: mock)
        #expect(mock.events == ["update"])
        #expect(mock.dataProtectionValue == Data("existing-dp".utf8))
        #expect(mock.legacyValue == Data("existing-legacy".utf8))
    }

    @Test func addFailurePreservesLegacyCredential() {
        let mock = KeychainStoreMock(updateStatuses: [errSecItemNotFound], dataProtectionValue: nil)
        mock.addStatus = errSecMissingEntitlement
        expectStoreFailure(errSecMissingEntitlement, using: mock)
        #expect(mock.events == ["update", "add"])
        #expect(mock.dataProtectionValue == nil)
        #expect(mock.legacyValue == Data("existing-legacy".utf8))
    }

    @Test func successfulUpdateCleansLegacyOnlyAfterSavingReplacement() throws {
        let mock = KeychainStoreMock()
        try KeychainService.store(key: "test-account", value: "replacement", operations: mock.operations)
        #expect(mock.events == ["update", "cleanup"])
        #expect(mock.dataProtectionValue == Data("replacement".utf8))
        #expect(mock.legacyValue == nil)
        #expect(mock.usedDataProtectionQueries)
        #expect(mock.cleanedLegacyOnly)
        #expect(mock.updatedAccessibility == kSecAttrAccessibleAfterFirstUnlock as String)
    }

    @Test func successfulAddCleansLegacyOnlyAfterSavingReplacement() throws {
        let mock = KeychainStoreMock(updateStatuses: [errSecItemNotFound], dataProtectionValue: nil)
        try KeychainService.store(key: "test-account", value: "replacement", operations: mock.operations)
        #expect(mock.events == ["update", "add", "cleanup"])
        #expect(mock.dataProtectionValue == Data("replacement".utf8))
        #expect(mock.legacyValue == nil)
        #expect(mock.usedDataProtectionQueries)
        #expect(mock.cleanedLegacyOnly)
    }

    @Test func concurrentInsertRetriesUpdateWithoutDeletingEitherItem() throws {
        let mock = KeychainStoreMock(updateStatuses: [errSecItemNotFound, errSecSuccess], dataProtectionValue: nil)
        mock.addStatus = errSecDuplicateItem
        try KeychainService.store(key: "test-account", value: "replacement", operations: mock.operations)
        #expect(mock.events == ["update", "add", "update", "cleanup"])
        #expect(mock.dataProtectionValue == Data("replacement".utf8))
        #expect(mock.legacyValue == nil)
    }

    @Test func failedConcurrentInsertRetryPreservesOtherWritersCredential() {
        let mock = KeychainStoreMock(updateStatuses: [errSecItemNotFound, errSecInteractionNotAllowed], dataProtectionValue: nil)
        mock.addStatus = errSecDuplicateItem
        expectStoreFailure(errSecInteractionNotAllowed, using: mock)
        #expect(mock.events == ["update", "add", "update"])
        #expect(mock.dataProtectionValue == Data("concurrent-dp".utf8))
        #expect(mock.legacyValue == Data("existing-legacy".utf8))
    }

    @Test func legacyCleanupFailureReportsThatReplacementWasSaved() {
        let mock = KeychainStoreMock()
        mock.cleanupStatus = errSecAuthFailed
        do {
            try KeychainService.store(key: "test-account", value: "replacement", operations: mock.operations)
            Issue.record("Expected a legacy cleanup error")
        } catch KeychainError.legacyCleanupFailed(let status) {
            #expect(status == errSecAuthFailed)
        } catch {
            Issue.record("Expected the specific legacy cleanup error")
        }
        #expect(mock.events == ["update", "cleanup"])
        #expect(mock.dataProtectionValue == Data("replacement".utf8))
        #expect(mock.legacyValue == Data("existing-legacy".utf8))
    }

    private func expectStoreFailure(_ expectedStatus: OSStatus, using mock: KeychainStoreMock) {
        do {
            try KeychainService.store(key: "test-account", value: "replacement", operations: mock.operations)
            Issue.record("Expected a Keychain store error")
        } catch KeychainError.storeFailed(let status) {
            #expect(status == expectedStatus)
        } catch {
            Issue.record("Expected the specific Keychain store error")
        }
    }
}

/// In-memory Security stand-in. Every test supplies this per call, so no real Keychain API executes.
private final class KeychainStoreMock {
    var updateStatuses: [OSStatus]
    var addStatus: OSStatus = errSecSuccess
    var cleanupStatus: OSStatus = errSecSuccess
    var dataProtectionValue: Data?
    var legacyValue: Data? = Data("existing-legacy".utf8)
    var events: [String] = []
    var usedDataProtectionQueries = true
    var cleanedLegacyOnly = true
    var updatedAccessibility: String?

    init(updateStatuses: [OSStatus] = [errSecSuccess], dataProtectionValue: Data? = Data("existing-dp".utf8)) {
        self.updateStatuses = updateStatuses
        self.dataProtectionValue = dataProtectionValue
    }

    var operations: KeychainService.StoreOperations {
        KeychainService.StoreOperations(
            update: { [self] query, attributes in
                events.append("update")
                usedDataProtectionQueries = usedDataProtectionQueries && (query[kSecUseDataProtectionKeychain] as? Bool == true)
                updatedAccessibility = attributes[kSecAttrAccessible] as? String
                let status = updateStatuses.isEmpty ? errSecParam : updateStatuses.removeFirst()
                if status == errSecSuccess { dataProtectionValue = attributes[kSecValueData] as? Data }
                return status
            },
            add: { [self] attributes in
                events.append("add")
                usedDataProtectionQueries = usedDataProtectionQueries && (attributes[kSecUseDataProtectionKeychain] as? Bool == true)
                if addStatus == errSecSuccess { dataProtectionValue = attributes[kSecValueData] as? Data }
                else if addStatus == errSecDuplicateItem { dataProtectionValue = Data("concurrent-dp".utf8) }
                return addStatus
            },
            deleteLegacy: { [self] query in
                events.append("cleanup")
                cleanedLegacyOnly = cleanedLegacyOnly && query[kSecUseDataProtectionKeychain] == nil
                if cleanupStatus == errSecSuccess { legacyValue = nil }
                return cleanupStatus
            }
        )
    }
}

struct OAuthCallbackLifecycleRegressionTests {
    @Test func timeoutCompletesWithoutAnOAuthCallback() async {
        let box = OAuthCallbackBox<Int>()
        let start = ContinuousClock.now
        do {
            _ = try await box.wait(timeoutSeconds: 0.02)
            Issue.record("Expected timeout")
        } catch {
            #expect(ContinuousClock.now - start < .seconds(1))
        }
    }

    @Test func callbackBeforeWaitAndDuplicatesCompleteExactlyOnce() async throws {
        let box = OAuthCallbackBox<Int>()
        box.succeed(42)
        box.succeed(99)
        box.fail(CancellationError())
        #expect(try await box.wait(timeoutSeconds: 1) == 42)
    }

    @Test func cancelledWaitCompletesPromptly() async {
        let box = OAuthCallbackBox<Int>()
        let task = Task { try await box.wait(timeoutSeconds: 30) }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch { #expect(error is CancellationError) }
    }
}

struct KeychainDeletionTests {
    @Test func checkedDeleteAttemptsBothKeychainLocations() throws {
        let mock = KeychainDeleteMock(statuses: [errSecSuccess, errSecSuccess])
        try KeychainService.deleteChecked(key: "test-account", operation: mock.delete)
        #expect(mock.locations == ["legacy", "data-protection"])
        #expect(mock.accounts == ["test-account", "test-account"])
        #expect(mock.services == ["com.fanyu.openpulse", "com.fanyu.openpulse"])
    }

    @Test func checkedDeleteAcceptsMissingItemsInBothLocations() throws {
        let mock = KeychainDeleteMock(statuses: [errSecItemNotFound, errSecItemNotFound])
        try KeychainService.deleteChecked(key: "test-account", operation: mock.delete)
        #expect(mock.locations == ["legacy", "data-protection"])
    }

    @Test func checkedDeleteAcceptsOneMissingLocation() throws {
        let mock = KeychainDeleteMock(statuses: [errSecSuccess, errSecItemNotFound])
        try KeychainService.deleteChecked(key: "test-account", operation: mock.delete)
        #expect(mock.locations == ["legacy", "data-protection"])
    }

    @Test func legacyFailureStillAttemptsDataProtectionAndPreservesOriginalStatus() {
        let mock = KeychainDeleteMock(statuses: [errSecAuthFailed, errSecSuccess])
        expectDeletionFailure(errSecAuthFailed, using: mock)
        #expect(mock.locations == ["legacy", "data-protection"])
    }

    @Test func dataProtectionFailurePropagatesOriginalStatus() {
        let mock = KeychainDeleteMock(statuses: [errSecSuccess, errSecInteractionNotAllowed])
        expectDeletionFailure(errSecInteractionNotAllowed, using: mock)
        #expect(mock.locations == ["legacy", "data-protection"])
    }

    @Test func failureInBothLocationsReportsFirstFailure() {
        let mock = KeychainDeleteMock(statuses: [errSecAuthFailed, errSecInteractionNotAllowed])
        expectDeletionFailure(errSecAuthFailed, using: mock)
        #expect(mock.locations == ["legacy", "data-protection"])
    }

    private func expectDeletionFailure(_ expected: OSStatus, using mock: KeychainDeleteMock) {
        do {
            try KeychainService.deleteChecked(key: "test-account", operation: mock.delete)
            Issue.record("Expected a Keychain deletion error")
        } catch KeychainError.deleteFailed(let status) {
            #expect(status == expected)
        } catch {
            Issue.record("Expected the specific Keychain deletion error")
        }
    }
}

/// Synthetic deletion responses only; tests always inject this instead of calling Security.
private final class KeychainDeleteMock {
    var statuses: [OSStatus]
    var locations: [String] = []
    var accounts: [String] = []
    var services: [String] = []

    init(statuses: [OSStatus]) { self.statuses = statuses }

    func delete(_ query: [CFString: Any]) -> OSStatus {
        locations.append(query[kSecUseDataProtectionKeychain] as? Bool == true ? "data-protection" : "legacy")
        accounts.append(query[kSecAttrAccount] as? String ?? "")
        services.append(query[kSecAttrService] as? String ?? "")
        return statuses.isEmpty ? errSecParam : statuses.removeFirst()
    }
}

struct AntigravityAccountStorageTests {
    @Test func missingMetadataStoreIsAnEmptyAccountList() async throws {
        let fixture = try AGAccountStorageFixture()
        defer { fixture.cleanUp() }
        let credentials = AGCredentialStorageFixture()
        let service = fixture.service(credentials: credentials.operations)

        let accounts = try await service.listAccounts()

        #expect(accounts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.storeURL.path))
        #expect(credentials.events.isEmpty)
    }

    @Test func corruptedMetadataFailsWithoutChangingExistingBytes() async throws {
        let fixture = try AGAccountStorageFixture()
        defer { fixture.cleanUp() }
        let original = Data("invalid account metadata".utf8)
        try original.write(to: fixture.storeURL)
        let credentials = AGCredentialStorageFixture()
        let service = fixture.service(credentials: credentials.operations)

        do {
            _ = try await service.listAccounts()
            Issue.record("Corrupted metadata must be reported, not converted into an empty list")
        } catch AntigravityAccountService.ServiceError.metadataReadFailed {
        } catch { Issue.record("Expected a metadata read error") }

        #expect(try Data(contentsOf: fixture.storeURL) == original)
        #expect(credentials.events.isEmpty)
    }

    @Test func corruptedMetadataRejectsAddBeforeCredentialMutation() async throws {
        let fixture = try AGAccountStorageFixture()
        defer { fixture.cleanUp() }
        let original = Data("invalid account metadata".utf8)
        try original.write(to: fixture.storeURL)
        let credentials = AGCredentialStorageFixture(values: [Self.firstKey: "fixture-existing"])
        let service = fixture.service(credentials: credentials.operations)

        do {
            _ = try await service.persistAccount(email: Self.firstEmail, refreshToken: "fixture-replacement")
            Issue.record("Adding an account must not overwrite corrupted metadata")
        } catch AntigravityAccountService.ServiceError.metadataReadFailed {
        } catch { Issue.record("Expected a metadata read error") }

        #expect(try Data(contentsOf: fixture.storeURL) == original)
        #expect(credentials.value(for: Self.firstKey) == "fixture-existing")
        #expect(credentials.events.isEmpty)
    }

    @Test func unreadableMetadataLocationDoesNotBecomeAnEmptyAccountList() async throws {
        let fixture = try AGAccountStorageFixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(at: fixture.storeURL, withIntermediateDirectories: false)
        let credentials = AGCredentialStorageFixture()
        let service = fixture.service(credentials: credentials.operations)

        do {
            _ = try await service.listAccounts()
            Issue.record("A non-file metadata location must be reported as a read error")
        } catch AntigravityAccountService.ServiceError.metadataReadFailed {
        } catch { Issue.record("Expected a metadata read error") }

        #expect(credentials.events.isEmpty)
    }

    @Test func corruptedMetadataStopsQuotaRefreshBeforeExternalCredentialOrAPIAccess() async throws {
        let fixture = try AGAccountStorageFixture()
        defer { fixture.cleanUp() }
        try Data("invalid account metadata".utf8).write(to: fixture.storeURL)
        let credentials = AGCredentialStorageFixture()
        let service = fixture.service(credentials: credentials.operations)
        // Owned metadata is validated first, so neither parser call reads the real CLI directory.
        let parser = AntigravityParser(brainDir: fixture.directory, accountService: service)

        do {
            _ = try await parser.fetchAllAccountQuotas()
            Issue.record("Full quota refresh must surface account metadata corruption")
        } catch AntigravityAccountService.ServiceError.metadataReadFailed {
        } catch { Issue.record("Expected the original metadata read error") }
        do {
            _ = try await parser.fetchQuota(forAccountEmail: Self.firstEmail)
            Issue.record("Single-account quota refresh must surface account metadata corruption")
        } catch AntigravityAccountService.ServiceError.metadataReadFailed {
        } catch { Issue.record("Expected the original metadata read error") }

        #expect(credentials.events.isEmpty)
    }

    @Test func metadataSaveFailurePreservesFileAndRestoresPreviousCredential() async throws {
        let fixture = try AGAccountStorageFixture()
        defer { fixture.cleanUp() }
        try fixture.write([Self.account(email: Self.firstEmail)])
        let original = try Data(contentsOf: fixture.storeURL)
        let credentials = AGCredentialStorageFixture(values: [Self.firstKey: "fixture-existing"])
        let service = fixture.service(credentials: credentials.operations, writeStoreData: { _, _ in
            throw AGAccountFixtureError.writeFailure
        })

        do {
            _ = try await service.persistAccount(email: Self.firstEmail, refreshToken: "fixture-replacement")
            Issue.record("An account save failure must not be reported as OAuth success")
        } catch AntigravityAccountService.ServiceError.metadataSaveFailed {
        } catch { Issue.record("Expected a metadata save error") }

        #expect(try Data(contentsOf: fixture.storeURL) == original)
        #expect(credentials.value(for: Self.firstKey) == "fixture-existing")
    }

    @Test func metadataSaveFailureRemovesNewCredential() async throws {
        let fixture = try AGAccountStorageFixture()
        defer { fixture.cleanUp() }
        let credentials = AGCredentialStorageFixture()
        let service = fixture.service(credentials: credentials.operations, writeStoreData: { _, _ in
            throw AGAccountFixtureError.writeFailure
        })

        do {
            _ = try await service.persistAccount(email: Self.firstEmail, refreshToken: "fixture-new")
            Issue.record("A new account must not succeed without durable metadata")
        } catch AntigravityAccountService.ServiceError.metadataSaveFailed {
        } catch { Issue.record("Expected a metadata save error") }

        #expect(!FileManager.default.fileExists(atPath: fixture.storeURL.path))
        #expect(credentials.value(for: Self.firstKey) == nil)
    }

    @Test func metadataDeletionFailurePreservesAccountAndCredential() async throws {
        let fixture = try AGAccountStorageFixture()
        defer { fixture.cleanUp() }
        try fixture.write([Self.account(email: Self.firstEmail)])
        let original = try Data(contentsOf: fixture.storeURL)
        let credentials = AGCredentialStorageFixture(values: [Self.firstKey: "fixture-existing"])
        let service = fixture.service(credentials: credentials.operations, writeStoreData: { _, _ in
            throw AGAccountFixtureError.writeFailure
        })

        do {
            try await service.deleteAccount(email: Self.firstEmail)
            Issue.record("Deletion must fail before removing credentials if metadata cannot save")
        } catch AntigravityAccountService.ServiceError.metadataSaveFailed {
        } catch { Issue.record("Expected a metadata save error") }

        #expect(try Data(contentsOf: fixture.storeURL) == original)
        #expect(credentials.value(for: Self.firstKey) == "fixture-existing")
        #expect(credentials.events.isEmpty)
    }

    @Test func credentialWriteFailurePreservesMetadata() async throws {
        let fixture = try AGAccountStorageFixture()
        defer { fixture.cleanUp() }
        try fixture.write([Self.account(email: Self.firstEmail)])
        let original = try Data(contentsOf: fixture.storeURL)
        let credentials = AGCredentialStorageFixture(values: [Self.firstKey: "fixture-existing"], storeOutcomes: [.failBeforeWrite])
        let service = fixture.service(credentials: credentials.operations)

        do {
            _ = try await service.persistAccount(email: Self.firstEmail, refreshToken: "fixture-replacement")
            Issue.record("A credential write error must not succeed")
        } catch AGAccountFixtureError.writeFailure {
        } catch { Issue.record("Expected a credential write error") }

        #expect(try Data(contentsOf: fixture.storeURL) == original)
        #expect(credentials.value(for: Self.firstKey) == "fixture-existing")
    }

    @Test func credentialCleanupFailureSavesDurableMetadataAndReportsPartialSuccess() async throws {
        let fixture = try AGAccountStorageFixture()
        defer { fixture.cleanUp() }
        let credentials = AGCredentialStorageFixture(storeOutcomes: [.legacyCleanupFailure])
        let service = fixture.service(credentials: credentials.operations)

        do {
            _ = try await service.persistAccount(email: Self.firstEmail, refreshToken: "fixture-new")
            Issue.record("Legacy cleanup failure must remain visible after the durable account save")
        } catch KeychainError.legacyCleanupFailed(let status) {
            #expect(status == errSecAuthFailed)
        } catch { Issue.record("Expected the specific legacy credential cleanup error") }

        let accounts = try await service.listAccounts()
        #expect(accounts.map(\.email) == [Self.firstEmail])
        #expect(credentials.value(for: Self.firstKey) == "fixture-new")
    }

    @Test func credentialCleanupThenMetadataFailureRestoresPreviousCredential() async throws {
        let fixture = try AGAccountStorageFixture()
        defer { fixture.cleanUp() }
        try fixture.write([Self.account(email: Self.firstEmail)])
        let original = try Data(contentsOf: fixture.storeURL)
        let credentials = AGCredentialStorageFixture(values: [Self.firstKey: "fixture-existing"], storeOutcomes: [.legacyCleanupFailure, .success])
        let service = fixture.service(credentials: credentials.operations, writeStoreData: { _, _ in
            throw AGAccountFixtureError.writeFailure
        })

        do {
            _ = try await service.persistAccount(email: Self.firstEmail, refreshToken: "fixture-replacement")
            Issue.record("Metadata failure must roll back even after credential cleanup reported partial success")
        } catch AntigravityAccountService.ServiceError.metadataSaveFailed {
        } catch { Issue.record("Expected a metadata save error") }

        #expect(try Data(contentsOf: fixture.storeURL) == original)
        #expect(credentials.value(for: Self.firstKey) == "fixture-existing")
    }

    @Test func rollbackFailureIsExplicitAndMetadataRemainsUntouched() async throws {
        let fixture = try AGAccountStorageFixture()
        defer { fixture.cleanUp() }
        try fixture.write([Self.account(email: Self.firstEmail)])
        let original = try Data(contentsOf: fixture.storeURL)
        let credentials = AGCredentialStorageFixture(values: [Self.firstKey: "fixture-existing"], storeOutcomes: [.success, .failBeforeWrite])
        let service = fixture.service(credentials: credentials.operations, writeStoreData: { _, _ in
            throw AGAccountFixtureError.writeFailure
        })

        do {
            _ = try await service.persistAccount(email: Self.firstEmail, refreshToken: "fixture-replacement")
            Issue.record("Credential rollback failure must be distinguished from a fully rolled-back save")
        } catch AntigravityAccountService.ServiceError.credentialRestoreFailed {
        } catch { Issue.record("Expected a credential restore error") }

        #expect(try Data(contentsOf: fixture.storeURL) == original)
        #expect(credentials.value(for: Self.firstKey) == "fixture-replacement")
    }

    @Test func accountRoundTripPreservesOtherAccountsAndDeletesOnlyTargetCredential() async throws {
        let fixture = try AGAccountStorageFixture()
        defer { fixture.cleanUp() }
        let secondEmail = "second@example.invalid"
        let secondKey = AntigravityAccountService.keychainKey(email: secondEmail)
        let credentials = AGCredentialStorageFixture(values: [secondKey: "fixture-second"])
        try fixture.write([Self.account(email: secondEmail)])
        let service = fixture.service(credentials: credentials.operations)

        let added = try await service.persistAccount(email: Self.firstEmail, refreshToken: "fixture-first")
        #expect(added.email == Self.firstEmail)
        #expect(try await service.listAccounts().map(\.email) == [secondEmail, Self.firstEmail])
        try await service.deleteAccount(email: Self.firstEmail)
        #expect(try await service.listAccounts().map(\.email) == [secondEmail])
        #expect(credentials.value(for: Self.firstKey) == nil)
        #expect(credentials.value(for: secondKey) == "fixture-second")
    }

    private static let firstEmail = "first@example.invalid"
    private static let firstKey = AntigravityAccountService.keychainKey(email: firstEmail)

    private static func account(email: String) -> AGStoredAccount {
        AGStoredAccount(email: email, label: email, tierId: nil, tierName: nil,
                        addedAt: Date(timeIntervalSince1970: 1_700_000_000),
                        updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }
}

private enum AGAccountFixtureError: Error { case writeFailure }

/// All metadata files are generated in a uniquely owned temporary directory.
private struct AGAccountStorageFixture {
    let directory: URL
    let storeURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "OpenPulse-AG-Storage-\(UUID().uuidString)")
        storeURL = directory.appending(path: "antigravity-accounts.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func write(_ accounts: [AGStoredAccount]) throws {
        try JSONEncoder().encode(accounts).write(to: storeURL, options: .atomic)
    }

    func service(
        credentials: AntigravityAccountService.CredentialOperations,
        writeStoreData: (@Sendable (Data, URL) throws -> Void)? = nil
    ) -> AntigravityAccountService {
        if let writeStoreData {
            return AntigravityAccountService(storeURL: storeURL, credentialOperations: credentials, writeStoreData: writeStoreData)
        }
        return AntigravityAccountService(storeURL: storeURL, credentialOperations: credentials)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}

/// Synthetic credentials only; no fixture calls a real Security API.
private final class AGCredentialStorageFixture: @unchecked Sendable {
    enum StoreOutcome { case success, failBeforeWrite, legacyCleanupFailure }
    private let lock = NSLock()
    private var values: [String: String]
    private var storeOutcomes: [StoreOutcome]
    private var recordedEvents: [String] = []

    init(values: [String: String] = [:], storeOutcomes: [StoreOutcome] = []) {
        self.values = values
        self.storeOutcomes = storeOutcomes
    }

    var events: [String] { lock.withLock { recordedEvents } }
    func value(for key: String) -> String? { lock.withLock { values[key] } }

    var operations: AntigravityAccountService.CredentialOperations {
        AntigravityAccountService.CredentialOperations(
            retrieve: { [self] key in value(for: key) },
            store: { [self] key, value in
                try lock.withLock {
                    recordedEvents.append("store")
                    let outcome = storeOutcomes.isEmpty ? .success : storeOutcomes.removeFirst()
                    if outcome == .failBeforeWrite { throw AGAccountFixtureError.writeFailure }
                    values[key] = value
                    if outcome == .legacyCleanupFailure { throw KeychainError.legacyCleanupFailed(errSecAuthFailed) }
                }
            },
            delete: { [self] key in
                lock.withLock {
                    recordedEvents.append("delete")
                    _ = values.removeValue(forKey: key)
                }
            }
        )
    }
}
