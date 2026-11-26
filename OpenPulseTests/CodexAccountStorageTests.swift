import Foundation
import Testing

@testable import OpenPulse

@Suite(.serialized)
struct CodexAccountStorageTests {
    @Test
    func metadataEncodingNeverIncludesCredentials() throws {
        let record = try fixtureRecord(id: "record-a", accountID: "account-a", revision: "original")
        let data = try JSONEncoder().encode(CodexAccountsStore(accounts: [record]))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let account = try #require((json["accounts"] as? [[String: Any]])?.first)
        #expect(account["authJSONString"] == nil)
        #expect(!String(decoding: data, as: UTF8.self).contains("access-original"))
        #expect(!String(decoding: data, as: UTF8.self).contains("refresh-original"))
        #expect(!String(decoding: data, as: UTF8.self).contains("api-key-original"))
    }

    @Test
    func migrationSecuresEveryCredentialBeforeReplacingLegacyMetadata() async throws {
        let fixture = try CodexAccountFixture()
        defer { fixture.cleanup() }
        let records = try [fixtureRecord(id: "record-a", accountID: "account-a"), fixtureRecord(id: "record-b", accountID: "account-b")]
        try writeLegacyStore(records, to: fixture.storeURL)
        let credentials = CodexAccountFixtureCredentials()
        let service = fixture.service(credentials: credentials, writer: { data, url in
            #expect(credentials.value(for: CodexAccountService.keychainKey(recordID: "record-a")) == records[0].authJSONString)
            #expect(credentials.value(for: CodexAccountService.keychainKey(recordID: "record-b")) == records[1].authJSONString)
            try data.write(to: url, options: .atomic)
        })

        let accounts = try await service.listAccounts()
        let data = try Data(contentsOf: fixture.storeURL)
        let store = try JSONDecoder().decode(CodexAccountsStore.self, from: data)
        #expect(store.version == 2)
        #expect(Set(accounts.map(\.id)) == Set(records.map(\.id)))
        #expect(store.accounts.allSatisfy { $0.authJSONString.isEmpty })
        #expect(!String(decoding: data, as: UTF8.self).contains("authJSONString"))
        #expect(accounts.first(where: { $0.id == "record-a" })?.label == records[0].label)
        #expect(accounts.first(where: { $0.id == "record-a" })?.addedAt == records[0].addedAt)
    }

    @Test
    func migrationCredentialFailurePreservesOriginalFile() async throws {
        let fixture = try CodexAccountFixture()
        defer { fixture.cleanup() }
        let records = try [fixtureRecord(id: "record-a", accountID: "account-a"), fixtureRecord(id: "record-b", accountID: "account-b")]
        let original = try writeLegacyStore(records, to: fixture.storeURL)
        let credentials = CodexAccountFixtureCredentials()
        credentials.failStore(for: CodexAccountService.keychainKey(recordID: "record-b"))
        let service = fixture.service(credentials: credentials)

        await #expect(throws: CodexAccountFixtureError.self) { try await service.listAccounts() }
        #expect(try Data(contentsOf: fixture.storeURL) == original)
        #expect(credentials.value(for: CodexAccountService.keychainKey(recordID: "record-a")) == records[0].authJSONString)
    }

    @Test
    func migrationMustVerifyCredentialWrite() async throws {
        let fixture = try CodexAccountFixture()
        defer { fixture.cleanup() }
        let original = try writeLegacyStore([fixtureRecord(id: "record-a", accountID: "account-a")], to: fixture.storeURL)
        let credentials = CodexAccountFixtureCredentials()
        let operations = CodexAccountService.CredentialOperations(
            retrieve: { _ in nil }, store: { _, _ in }, delete: { _ in }
        )
        let service = fixture.service(credentials: credentials, operations: operations)

        await #expect(throws: (any Error).self) { try await service.listAccounts() }
        #expect(try Data(contentsOf: fixture.storeURL) == original)
    }

    @Test
    func migrationMetadataFailurePreservesOriginalFile() async throws {
        let fixture = try CodexAccountFixture()
        defer { fixture.cleanup() }
        let original = try writeLegacyStore([fixtureRecord(id: "record-a", accountID: "account-a")], to: fixture.storeURL)
        let service = fixture.service(credentials: CodexAccountFixtureCredentials(), writer: { _, _ in throw CodexAccountFixtureError.writeFailed })

        await #expect(throws: CodexAccountFixtureError.self) { try await service.listAccounts() }
        #expect(try Data(contentsOf: fixture.storeURL) == original)
    }

    @Test
    func corruptStoreIsNotReplacedByCurrentAuth() async throws {
        let fixture = try CodexAccountFixture()
        defer { fixture.cleanup() }
        let original = Data("invalid account metadata".utf8)
        try original.write(to: fixture.storeURL)
        try Data(fixtureAuth(accountID: "account-a").utf8).write(to: fixture.authURL)
        let service = fixture.service(credentials: CodexAccountFixtureCredentials())

        await #expect(throws: (any Error).self) { try await service.syncCurrentSelectionFromAuthFile() }
        #expect(try Data(contentsOf: fixture.storeURL) == original)
    }

    @Test
    func versionTwoMissingCredentialFailsWithoutReplacingMetadata() async throws {
        let fixture = try CodexAccountFixture()
        defer { fixture.cleanup() }
        let data = try JSONEncoder().encode(CodexAccountsStore(accounts: [fixtureRecord(id: "record-a", accountID: "account-a")]))
        try data.write(to: fixture.storeURL)
        let service = fixture.service(credentials: CodexAccountFixtureCredentials())

        await #expect(throws: (any Error).self) { try await service.listAccounts() }
        #expect(try Data(contentsOf: fixture.storeURL) == data)
    }

    @Test
    func reimportRestoresMatchingMissingVersionTwoCredential() async throws {
        let fixture = try CodexAccountFixture()
        defer { fixture.cleanup() }
        let record = try fixtureRecord(id: "record-a", accountID: "account-a")
        try JSONEncoder().encode(CodexAccountsStore(accounts: [record])).write(to: fixture.storeURL)
        try Data(record.authJSONString.utf8).write(to: fixture.authURL)
        let credentials = CodexAccountFixtureCredentials()
        let service = fixture.service(credentials: credentials)

        try await service.importCurrentAuth(customLabel: "Recovered")
        let accounts = try await service.listAccounts()
        #expect(accounts.count == 1)
        #expect(accounts.first?.id == record.id)
        #expect(accounts.first?.label == "Recovered")
        #expect(credentials.value(for: CodexAccountService.keychainKey(recordID: record.id)) == record.authJSONString)
    }

    @Test
    func accountUpdateMetadataFailureRestoresPreviousCredential() async throws {
        let fixture = try CodexAccountFixture()
        defer { fixture.cleanup() }
        let credentials = CodexAccountFixtureCredentials()
        let writer = CodexAccountFixtureWriter()
        let service = fixture.service(credentials: credentials, writer: { try writer.write($0, to: $1) })
        let originalAuth = try fixtureAuth(accountID: "account-a", revision: "original")
        let record = try await service.upsertAccount(authJSONString: originalAuth, customLabel: "Original", setAsCurrent: false)
        let original = try Data(contentsOf: fixture.storeURL)
        writer.failWrites()
        let newAuth = try fixtureAuth(accountID: "account-a", revision: "rotated")

        await #expect(throws: CodexAccountFixtureError.self) {
            try await service.upsertAccount(authJSONString: newAuth, customLabel: "New", setAsCurrent: false)
        }
        #expect(try Data(contentsOf: fixture.storeURL) == original)
        #expect(credentials.value(for: CodexAccountService.keychainKey(recordID: record.id)) == originalAuth)
    }

    @Test
    func failedNewAccountMetadataWriteRemovesUncommittedCredential() async throws {
        let fixture = try CodexAccountFixture()
        defer { fixture.cleanup() }
        let credentials = CodexAccountFixtureCredentials()
        let service = fixture.service(credentials: credentials, writer: { _, _ in throw CodexAccountFixtureError.writeFailed })
        let auth = try fixtureAuth(accountID: "account-a")

        await #expect(throws: CodexAccountFixtureError.self) {
            try await service.upsertAccount(authJSONString: auth, customLabel: nil, setAsCurrent: false)
        }
        #expect(credentials.count == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.storeURL.path))
    }

    @Test
    func failedSwitchMetadataWriteRestoresActiveAuth() async throws {
        let fixture = try CodexAccountFixture()
        defer { fixture.cleanup() }
        let credentials = CodexAccountFixtureCredentials()
        let writer = CodexAccountFixtureWriter()
        let service = fixture.service(credentials: credentials, writer: { try writer.write($0, to: $1) })
        let activeAuth = try fixtureAuth(accountID: "account-a")
        try Data(activeAuth.utf8).write(to: fixture.authURL)
        _ = try await service.upsertAccount(authJSONString: activeAuth, customLabel: nil, setAsCurrent: true)
        let target = try await service.upsertAccount(authJSONString: fixtureAuth(accountID: "account-b"), customLabel: nil, setAsCurrent: false)
        let originalStore = try Data(contentsOf: fixture.storeURL)
        writer.failWrites()

        await #expect(throws: CodexAccountFixtureError.self) { try await service.switchAccount(id: target.id, relaunchCodex: false) }
        #expect(try String(contentsOf: fixture.authURL, encoding: .utf8) == activeAuth)
        #expect(try Data(contentsOf: fixture.storeURL) == originalStore)
    }

    @Test
    func relaunchFailureStillReportsAppliedAccountSelection() async throws {
        let fixture = try CodexAccountFixture()
        defer { fixture.cleanup() }
        let service = fixture.service(credentials: CodexAccountFixtureCredentials(), relaunch: { throw CodexAccountFixtureError.relaunchFailed })
        let targetAuth = try fixtureAuth(accountID: "account-b")
        let target = try await service.upsertAccount(authJSONString: targetAuth, customLabel: nil, setAsCurrent: false)

        await #expect(throws: (any Error).self) { try await service.switchAccount(id: target.id) }
        #expect(try String(contentsOf: fixture.authURL, encoding: .utf8) == targetAuth)
        #expect(try await service.listAccounts().first(where: \.isCurrent)?.id == target.id)
    }

    @Test
    func deletionMetadataFailureRetainsCredentialAndDeleteFailureIsExplicit() async throws {
        let fixture = try CodexAccountFixture()
        defer { fixture.cleanup() }
        let credentials = CodexAccountFixtureCredentials()
        let writer = CodexAccountFixtureWriter()
        let service = fixture.service(credentials: credentials, writer: { try writer.write($0, to: $1) })
        let auth = try fixtureAuth(accountID: "account-a")
        let record = try await service.upsertAccount(authJSONString: auth, customLabel: nil, setAsCurrent: false)
        let original = try Data(contentsOf: fixture.storeURL)
        writer.failWrites()

        await #expect(throws: CodexAccountFixtureError.self) { try await service.deleteAccount(id: record.id) }
        #expect(try Data(contentsOf: fixture.storeURL) == original)
        #expect(credentials.value(for: CodexAccountService.keychainKey(recordID: record.id)) == auth)

        writer.allowWrites()
        credentials.failDeletes()
        await #expect(throws: CodexAccountFixtureError.self) { try await service.deleteAccount(id: record.id) }
        #expect(try await service.listAccounts().isEmpty)
        #expect(credentials.value(for: CodexAccountService.keychainKey(recordID: record.id)) == auth)
    }

    @Test
    func importingCurrentAuthDoesNotRewriteAuthAndCurrentDeleteIsRejected() async throws {
        let fixture = try CodexAccountFixture()
        defer { fixture.cleanup() }
        let auth = try fixtureAuth(accountID: "account-a")
        try Data(auth.utf8).write(to: fixture.authURL)
        let service = fixture.service(credentials: CodexAccountFixtureCredentials(), authWriter: { _, _ in throw CodexAccountFixtureError.writeFailed })

        try await service.importCurrentAuth(customLabel: "Imported")
        let account = try #require(try await service.listAccounts().first)
        #expect(account.isCurrent)
        #expect(account.label == "Imported")
        await #expect(throws: (any Error).self) { try await service.deleteAccount(id: account.id) }
        #expect(try await service.listAccounts().count == 1)
        #expect(try String(contentsOf: fixture.authURL, encoding: .utf8) == auth)
    }

    @Test(arguments: ["delete", "import", "rotate"])
    func suspendedRefreshPreservesConcurrentAccountMutations(_ mutation: String) async throws {
        let fixture = try CodexAccountFixture()
        defer { fixture.cleanup() }
        let credentials = CodexAccountFixtureCredentials()
        let gate = CodexAccountFixtureNetworkGate()
        CodexAccountFixtureURLProtocol.gate = gate
        defer { CodexAccountFixtureURLProtocol.gate = nil }
        let service = fixture.service(credentials: credentials)
        let originalAuth = try fixtureAuth(accountID: "account-a", revision: "original")
        let rotatedAuth = try fixtureAuth(accountID: "account-a", revision: "rotated")
        let original = try await service.upsertAccount(authJSONString: originalAuth, customLabel: "Original", setAsCurrent: false)
        let refresh = Task { try await service.refreshAllUsage(force: true) }
        await gate.waitUntilStarted()

        switch mutation {
        case "delete": try await service.deleteAccount(id: original.id)
        case "import":
            try Data(fixtureAuth(accountID: "account-b").utf8).write(to: fixture.authURL)
            try await service.importCurrentAuth(customLabel: "Imported")
        default:
            _ = try await service.upsertAccount(authJSONString: rotatedAuth, customLabel: "Rotated", setAsCurrent: false)
        }
        await gate.release()
        let accounts = try await refresh.value
        switch mutation {
        case "delete":
            #expect(accounts.isEmpty)
            #expect(credentials.value(for: CodexAccountService.keychainKey(recordID: original.id)) == nil)
        case "import":
            #expect(accounts.count == 2)
            #expect(accounts.first(where: \.isCurrent)?.accountID == "account-b")
            #expect(accounts.first(where: { $0.accountID == "account-a" })?.limits?.fiveHourWindow?.usedPercent == 25)
        default:
            #expect(accounts.first?.label == "Rotated")
            #expect(accounts.first?.lastFetchedAt == nil)
            let persistedAuth = try #require(credentials.value(for: CodexAccountService.keychainKey(recordID: original.id)))
            #expect(persistedAuth == rotatedAuth)
            let persistedJSON = try #require(JSONSerialization.jsonObject(with: Data(persistedAuth.utf8)) as? [String: Any])
            let persistedTokens = try #require(persistedJSON["tokens"] as? [String: String])
            #expect(persistedTokens["access_token"] == "access-rotated")
            #expect(persistedTokens["refresh_token"] == "refresh-rotated")
        }
    }

    @Test(arguments: [false, true])
    func concurrentAutoSwitchOwnsRestartUntilCompletionAndClearsOnFailure(_ failFirstRestart: Bool) async throws {
        let fixture = try CodexAccountFixture()
        defer { fixture.cleanup() }
        let suiteName = "codex-auto-switch-fixture-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let restart = CodexAccountFixtureRestartGate(failFirst: failFirstRestart)
        let service = fixture.service(credentials: CodexAccountFixtureCredentials(), defaultsSuiteName: suiteName,
                                      relaunch: { try await restart.relaunch() })
        let activeAuth = try fixtureAuth(accountID: "account-a")
        try Data(activeAuth.utf8).write(to: fixture.authURL)
        _ = try await service.upsertAccount(authJSONString: activeAuth, customLabel: nil, setAsCurrent: true)
        let target = try await service.upsertAccount(authJSONString: fixtureAuth(accountID: "account-b"), customLabel: nil, setAsCurrent: false)
        var candidates = try await service.listAccounts()
        for index in candidates.indices {
            candidates[index].limits = CodexRateLimits(
                primary: CodexWindow(usedPercent: candidates[index].isCurrent ? 100 : 10, windowMinutes: 300, windowSeconds: nil,
                                     resetsAt: Date().addingTimeInterval(3_600).timeIntervalSince1970),
                secondary: CodexWindow(usedPercent: candidates[index].isCurrent ? 100 : 10, windowMinutes: 10_080, windowSeconds: nil,
                                       resetsAt: Date().addingTimeInterval(86_400).timeIntervalSince1970),
                credits: nil, resetCredits: nil, planType: "pro", observedAt: Date()
            )
        }
        let originalCandidates = candidates
        let first = Task { try await service.autoSmartSwitchIfNeeded(accounts: originalCandidates) }
        await restart.waitUntilStarted()
        let overlapping = try await service.autoSmartSwitchIfNeeded(accounts: originalCandidates)
        #expect(overlapping == nil)
        #expect(await restart.count == 1)
        #expect(defaults.object(forKey: "codex.smartSwitch.lastAt") == nil)
        await restart.release()

        if failFirstRestart {
            await #expect(throws: (any Error).self) { try await first.value }
            #expect(defaults.object(forKey: "codex.smartSwitch.lastAt") == nil)
            let retry = try await service.autoSmartSwitchIfNeeded(accounts: originalCandidates)
            #expect(retry?.account.id == target.id)
            #expect(await restart.count == 2)
        } else {
            #expect(try await first.value?.account.id == target.id)
            #expect(defaults.object(forKey: "codex.smartSwitch.lastAt") is Date)
            #expect(try await service.autoSmartSwitchIfNeeded(accounts: originalCandidates) == nil)
            #expect(await restart.count == 1)
        }
    }

    @Test
    func processRunnerDrainsOutputLargerThanPipeBufferBeforeWaitingForExit() async throws {
        let fixture = try CodexAccountFixture()
        defer { fixture.cleanup() }
        let service = fixture.service(credentials: CodexAccountFixtureCredentials())
        // A deterministic synthetic child; it reads no account or tool files.
        let result = try await service.runProcess("/usr/bin/awk", arguments: ["BEGIN { for (i = 0; i < 262144; i++) printf \"x\" }"])
        #expect(result.terminationStatus == 0)
        #expect(result.output.count == 262_144)
        #expect(result.output.allSatisfy { $0 == 0x78 })
    }

    @Test(arguments: ["failed", "stale", "expired", "unknown", "exhausted", "missing-percent", "nonfinite-percent", "future"])
    func autoSwitchSkipsUnusableAlternativeEvenWhenItsOldScoreWouldWin(_ state: String) async throws {
        let fixture = try CodexAccountFixture()
        defer { fixture.cleanup() }
        let restart = CodexAccountFixtureRestartGate(failFirst: false)
        await restart.release()
        let service = fixture.service(credentials: CodexAccountFixtureCredentials(),
                                      relaunch: { try await restart.relaunch() })
        let activeAuth = try fixtureAuth(accountID: "account-a")
        try Data(activeAuth.utf8).write(to: fixture.authURL)
        _ = try await service.upsertAccount(authJSONString: activeAuth, customLabel: nil, setAsCurrent: true)
        let invalid = try await service.upsertAccount(authJSONString: fixtureAuth(accountID: "account-b"), customLabel: nil, setAsCurrent: false)
        let valid = try await service.upsertAccount(authJSONString: fixtureAuth(accountID: "account-c"), customLabel: nil, setAsCurrent: false)
        var candidates = try await service.listAccounts()
        for index in candidates.indices {
            if candidates[index].isCurrent {
                candidates[index].limits = fixtureLimits(usedPercent: 100, weeklyUsedPercent: 100)
            } else if candidates[index].id == valid.id {
                candidates[index].limits = fixtureLimits(usedPercent: 80, weeklyUsedPercent: 80)
            } else {
                candidates[index].limits = fixtureLimits()
                switch state {
                case "failed": candidates[index].usageError = "synthetic authorization failure"
                case "stale": candidates[index].limits = fixtureLimits(observedAt: Date().addingTimeInterval(-601))
                case "expired": candidates[index].limits = fixtureLimits(sessionReset: Date().addingTimeInterval(-1))
                case "unknown": candidates[index].limits = nil
                case "exhausted": candidates[index].limits = fixtureLimits(weeklyUsedPercent: 100)
                case "missing-percent": candidates[index].limits = fixtureLimits(usedPercent: nil)
                case "nonfinite-percent": candidates[index].limits = fixtureLimits(usedPercent: .nan)
                default: candidates[index].limits = fixtureLimits(observedAt: Date().addingTimeInterval(3_600))
                }
                candidates[index].lastFetchedAt = Date() // Attempt time cannot make an old observation fresh.
            }
        }

        let decision = try await service.autoSmartSwitchIfNeeded(accounts: candidates)
        #expect(decision?.account.id == valid.id)
        #expect(decision?.account.id != invalid.id)
        #expect(await restart.count == 1)
    }

    @Test(arguments: ["failed", "stale", "expired", "unknown", "missing-observation", "no-current"])
    func autoSwitchRequiresReliableCurrentExhaustion(_ state: String) async throws {
        let fixture = try CodexAccountFixture()
        defer { fixture.cleanup() }
        let restart = CodexAccountFixtureRestartGate(failFirst: false)
        await restart.release()
        let service = fixture.service(credentials: CodexAccountFixtureCredentials(),
                                      relaunch: { try await restart.relaunch() })
        let activeAuth = try fixtureAuth(accountID: "account-a")
        try Data(activeAuth.utf8).write(to: fixture.authURL)
        _ = try await service.upsertAccount(authJSONString: activeAuth, customLabel: nil, setAsCurrent: true)
        _ = try await service.upsertAccount(authJSONString: fixtureAuth(accountID: "account-b"), customLabel: nil, setAsCurrent: false)
        var candidates = try await service.listAccounts()
        for index in candidates.indices {
            candidates[index].limits = fixtureLimits()
            if candidates[index].isCurrent {
                candidates[index].limits = fixtureLimits(usedPercent: 100, weeklyUsedPercent: 100)
                switch state {
                case "failed": candidates[index].usageError = "synthetic fetch failure"
                case "stale": candidates[index].limits = fixtureLimits(usedPercent: 100, weeklyUsedPercent: 100, observedAt: Date().addingTimeInterval(-601))
                case "expired": candidates[index].limits = fixtureLimits(usedPercent: 100, weeklyUsedPercent: 100, sessionReset: Date().addingTimeInterval(-1))
                case "unknown": candidates[index].limits = nil
                case "missing-observation": candidates[index].limits = fixtureLimits(usedPercent: 100, weeklyUsedPercent: 100, observedAt: nil)
                default: candidates[index].isCurrent = false
                }
                candidates[index].lastFetchedAt = Date()
            }
        }

        #expect(try await service.autoSmartSwitchIfNeeded(accounts: candidates) == nil)
        #expect(await restart.count == 0)
        #expect(try await service.listAccounts().first(where: \.isCurrent)?.accountID == "account-a")
    }

    @Test
    func explicitSwitchStillAcceptsAccountWithoutQuotaObservation() async throws {
        let fixture = try CodexAccountFixture()
        defer { fixture.cleanup() }
        let service = fixture.service(credentials: CodexAccountFixtureCredentials())
        let auth = try fixtureAuth(accountID: "account-b")
        let account = try await service.upsertAccount(authJSONString: auth, customLabel: nil, setAsCurrent: false)
        #expect(try await service.listAccounts().first?.limits == nil)
        _ = try await service.switchAccount(id: account.id, relaunchCodex: false)
        #expect(try await service.listAccounts().first?.isCurrent == true)
        #expect(try String(contentsOf: fixture.authURL, encoding: .utf8) == auth)
    }

    @Test
    func applyLocalRateLimitsToCurrentAccountPersistsMergedLimits() async throws {
        let fixture = try CodexAccountFixture()
        defer { fixture.cleanup() }
        let service = fixture.service(credentials: CodexAccountFixtureCredentials())
        let auth = try fixtureAuth(accountID: "account-local")
        try Data(auth.utf8).write(to: fixture.authURL)
        _ = try await service.upsertAccount(authJSONString: auth, customLabel: "Local", setAsCurrent: true)

        let freshLimits = fixtureLimits(
            usedPercent: 18,
            weeklyUsedPercent: 42,
            observedAt: Date(),
            sessionReset: Date().addingTimeInterval(3_600),
            weeklyReset: Date().addingTimeInterval(86_400)
        )
        let accounts = try await service.applyLocalRateLimitsToCurrentAccount(freshLimits)
        let persisted = try await service.listAccounts()

        #expect(accounts.first?.limits?.fiveHourWindow?.usedPercent == 18)
        #expect(accounts.first?.limits?.oneWeekWindow?.usedPercent == 42)
        #expect(persisted.first?.limits?.fiveHourWindow?.usedPercent == 18)
        #expect(persisted.first?.limits?.oneWeekWindow?.usedPercent == 42)
    }

    @Test
    func refreshStaleUsageRefreshesExpiredWeeklyWindowWhenFiveHourIsFresh() async throws {
        let fixture = try CodexAccountFixture()
        defer { fixture.cleanup() }
        let credentials = CodexAccountFixtureCredentials()
        let service = fixture.service(credentials: credentials)
        let auth = try fixtureAuth(accountID: "account-weekly-stale")
        try Data(auth.utf8).write(to: fixture.authURL)
        _ = try await service.upsertAccount(authJSONString: auth, customLabel: "WeeklyStale", setAsCurrent: true)

        let staleWeeklyLimits = fixtureLimits(
            usedPercent: 80,
            weeklyUsedPercent: 90,
            observedAt: Date().addingTimeInterval(-300),
            sessionReset: Date().addingTimeInterval(3_600),
            weeklyReset: Date().addingTimeInterval(-60)
        )
        _ = try await service.applyLocalRateLimitsToCurrentAccount(staleWeeklyLimits)

        let refreshed = try await service.refreshStaleUsage(excludingCurrentAccount: false)

        #expect(refreshed.first?.limits?.fiveHourWindow?.usedPercent == 25)
    }

    @Test
    func refreshAllUsageBypassesCooldownWhenWindowResetOccurredAfterLastFetch() async throws {
        let fixture = try CodexAccountFixture()
        defer { fixture.cleanup() }
        let credentials = CodexAccountFixtureCredentials()
        let service = fixture.service(credentials: credentials)
        let auth = try fixtureAuth(accountID: "account-reset-cooldown")
        try Data(auth.utf8).write(to: fixture.authURL)
        _ = try await service.upsertAccount(authJSONString: auth, customLabel: "ResetCooldown", setAsCurrent: true)

        // Seed a recent fetch (within the 25s cooldown) whose 7D reset is 0.5s in the future.
        let imminentReset = Date().addingTimeInterval(0.5)
        let seeded = fixtureLimits(
            usedPercent: 60,
            weeklyUsedPercent: 85,
            observedAt: Date().addingTimeInterval(-10),
            sessionReset: Date().addingTimeInterval(3_600),
            weeklyReset: imminentReset
        )
        _ = try await service.applyLocalRateLimitsToCurrentAccount(seeded)

        // Before the reset passes, non-forced refresh stays throttled.
        let throttled = try await service.refreshAllUsage(force: false)
        #expect(throttled.first?.limits?.fiveHourWindow?.usedPercent == 60)

        // Once the window reset time has passed since lastFetchedAt, non-forced refresh runs immediately.
        try await Task.sleep(for: .milliseconds(600))
        let afterReset = try await service.refreshAllUsage(force: false)
        #expect(afterReset.first?.limits?.fiveHourWindow?.usedPercent == 25)
    }

    private func fixtureLimits(usedPercent: Double? = 0, weeklyUsedPercent: Double? = 0, observedAt: Date? = Date(),
                               sessionReset: Date? = Date().addingTimeInterval(3_600),
                               weeklyReset: Date? = Date().addingTimeInterval(86_400)) -> CodexRateLimits {
        CodexRateLimits(primary: CodexWindow(usedPercent: usedPercent, windowMinutes: 300, windowSeconds: nil,
                                            resetsAt: sessionReset?.timeIntervalSince1970),
                        secondary: CodexWindow(usedPercent: weeklyUsedPercent, windowMinutes: 10_080, windowSeconds: nil,
                                              resetsAt: weeklyReset?.timeIntervalSince1970),
                        credits: nil, resetCredits: nil, planType: "pro", observedAt: observedAt)
    }

    private func fixtureRecord(id: String, accountID: String, revision: String = "fixture") throws -> CodexStoredAccount {
        CodexStoredAccount(id: id, label: "Saved \(accountID)", email: "\(accountID)@example.test", accountID: accountID,
                           planType: "pro", teamName: nil, authJSONString: try fixtureAuth(accountID: accountID, revision: revision),
                           addedAt: Date(timeIntervalSince1970: 1_000), updatedAt: Date(timeIntervalSince1970: 2_000),
                           lastFetchedAt: nil, lastUsage: nil, usageError: nil)
    }

    private func fixtureAuth(accountID: String, revision: String = "fixture") throws -> String {
        let payload = try JSONSerialization.data(withJSONObject: ["email": "\(accountID)@example.test", "https://api.openai.com/auth": ["chatgpt_account_id": accountID, "chatgpt_plan_type": "pro"]], options: [.sortedKeys])
        let encoded = payload.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let auth: [String: Any] = ["auth_mode": "chatgpt", "OPENAI_API_KEY": "api-key-\(revision)", "tokens": ["access_token": "access-\(revision)", "refresh_token": "refresh-\(revision)", "id_token": "fixture.\(encoded).signature", "account_id": accountID]]
        return String(decoding: try JSONSerialization.data(withJSONObject: auth, options: [.sortedKeys]), as: UTF8.self)
    }

    @discardableResult
    private func writeLegacyStore(_ records: [CodexStoredAccount], to url: URL) throws -> Data {
        let accounts = try records.map { record -> [String: Any] in
            var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
            json["authJSONString"] = record.authJSONString
            return json
        }
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "accounts": accounts], options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
        return data
    }
}

private enum CodexAccountFixtureError: Error { case writeFailed, credentialFailed, deleteFailed, relaunchFailed }

private struct CodexAccountFixture {
    let rootURL: URL
    let storeURL: URL
    let authURL: URL
    let configURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory.appending(path: "codex-account-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        storeURL = rootURL.appending(path: "accounts.json")
        authURL = rootURL.appending(path: "auth.json")
        configURL = rootURL.appending(path: "config.toml")
    }

    func service(
        credentials: CodexAccountFixtureCredentials,
        operations: CodexAccountService.CredentialOperations? = nil,
        defaultsSuiteName: String? = nil,
        writer: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) },
        authWriter: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) },
        relaunch: @escaping @Sendable () async throws -> Bool = { false }
    ) -> CodexAccountService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexAccountFixtureURLProtocol.self]
        // Transfer a fresh instance to the actor; assertions and cleanup open
        // independent instances of the same isolated fixture domain.
        return CodexAccountService(session: URLSession(configuration: configuration),
                                   userDefaults: UserDefaults(suiteName: defaultsSuiteName ?? rootURL.lastPathComponent)!,
                                   storeURL: storeURL, codexAuthURL: authURL,
                                   codexConfigURL: configURL, credentialOperations: operations ?? credentials.operations,
                                   writeStoreData: writer, writeAuthData: authWriter, relaunchOperation: relaunch)
    }

    func cleanup() {
        UserDefaults(suiteName: rootURL.lastPathComponent)?.removePersistentDomain(forName: rootURL.lastPathComponent)
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private final class CodexAccountFixtureCredentials: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var failedStoreKey: String?
    private var deletionFails = false
    var count: Int { lock.withLock { values.count } }
    func value(for key: String) -> String? { lock.withLock { values[key] } }
    func failStore(for key: String) { lock.withLock { failedStoreKey = key } }
    func failDeletes() { lock.withLock { deletionFails = true } }
    var operations: CodexAccountService.CredentialOperations {
        .init(retrieve: { self.value(for: $0) }, store: { key, value in
            try self.lock.withLock {
                if self.failedStoreKey == key { throw CodexAccountFixtureError.credentialFailed }
                self.values[key] = value
            }
        }, delete: { key in
            try self.lock.withLock {
                if self.deletionFails { throw CodexAccountFixtureError.deleteFailed }
                self.values.removeValue(forKey: key)
            }
        })
    }
}

private final class CodexAccountFixtureWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = false
    func failWrites() { lock.withLock { shouldFail = true } }
    func allowWrites() { lock.withLock { shouldFail = false } }
    func write(_ data: Data, to url: URL) throws {
        if lock.withLock({ shouldFail }) { throw CodexAccountFixtureError.writeFailed }
        try data.write(to: url, options: .atomic)
    }
}

private actor CodexAccountFixtureNetworkGate {
    private var started = false
    private var released = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }
    func requestStarted() async {
        started = true
        startedWaiters.forEach { $0.resume() }
        startedWaiters.removeAll()
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }
    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private actor CodexAccountFixtureRestartGate {
    private let gate = CodexAccountFixtureNetworkGate()
    private let failFirst: Bool
    private(set) var count = 0
    init(failFirst: Bool) { self.failFirst = failFirst }
    func waitUntilStarted() async { await gate.waitUntilStarted() }
    func release() async { await gate.release() }
    func relaunch() async throws -> Bool {
        count += 1
        let attempt = count
        await gate.requestStarted()
        if failFirst && attempt == 1 { throw CodexAccountFixtureError.relaunchFailed }
        return false
    }
}

private final class CodexAccountFixtureURLProtocol: URLProtocol {
    nonisolated(unsafe) static var gate: CodexAccountFixtureNetworkGate?
    private let transport = CodexAccountFixtureResponseTransport()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let gate = Self.gate
        let delivery = transport
        delivery.configure(protocolInstance: self, client: client, url: url)
        Task { [delivery, gate] in
            if let gate { await gate.requestStarted() }
            delivery.finish()
        }
    }
    override func stopLoading() { transport.cancel() }
}

/// The async worker owns only this narrow, synchronized callback transport.
/// URLProtocol itself remains non-Sendable and its request is read synchronously.
private final class CodexAccountFixtureResponseTransport: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var protocolInstance: URLProtocol?
    private var client: (any URLProtocolClient)?
    private var url: URL?
    private var cancelled = false

    func configure(protocolInstance: URLProtocol, client: (any URLProtocolClient)?, url: URL) {
        lock.withLock {
            guard !cancelled else { return }
            self.protocolInstance = protocolInstance
            self.client = client
            self.url = url
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            protocolInstance = nil
            client = nil
            url = nil
        }
    }

    func finish() {
        lock.withLock {
            guard !cancelled, let protocolInstance, let client, let url else { return }
            defer {
                self.protocolInstance = nil
                self.client = nil
                self.url = nil
            }
            let body = url.path.contains("rate-limit-reset-credits")
                ? #"{"available_count":0,"credits":[]}"#
                : #"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":25,"limit_window_seconds":18000,"reset_at":2000000000}}}"#
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
            guard !cancelled else { return }
            client.urlProtocol(protocolInstance, didLoad: Data(body.utf8))
            guard !cancelled else { return }
            client.urlProtocolDidFinishLoading(protocolInstance)
        }
    }
}
