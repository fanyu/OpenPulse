import Testing
@testable import OpenPulse
import Foundation

struct AntigravityCredentialMergeTests {
    @Test func openPulseWinsOnDuplicateEmail() {
        let url = URL(fileURLWithPath: "/tmp/antigravity-a_gmail_com.json")
        let cli = [AGCredential(email: "a@gmail.com", source: .cliProxy(url)),
                   AGCredential(email: "b@gmail.com", source: .cliProxy(url))]
        let op  = [AGCredential(email: "a@gmail.com", source: .openPulse)]
        let merged = AntigravityParser.mergeCredentials(cliProxy: cli, openPulse: op)
        #expect(merged.count == 2)
        let a = merged.first { $0.email == "a@gmail.com" }
        if case .openPulse = a?.source {} else { Issue.record("expected openPulse source to win") }
    }
}

struct OAuthCallbackParameterTests {
    @Test func uniqueCallbackParametersPreserveDecodedValues() {
        let items = [
            URLQueryItem(name: "state", value: "synthetic-state"),
            URLQueryItem(name: "code", value: "synthetic+code/value"),
            URLQueryItem(name: "empty", value: ""),
            URLQueryItem(name: "missing", value: nil)
        ]
        let parameters = oauthCallbackParameters(items)
        #expect(parameters?["state"] == "synthetic-state")
        #expect(parameters?["code"] == "synthetic+code/value")
        #expect(parameters?["empty"] == "")
        #expect(parameters?["missing"] == nil)
    }

    @Test func duplicateStateParametersAreRejected() {
        #expect(oauthCallbackParameters([
            URLQueryItem(name: "state", value: "first"),
            URLQueryItem(name: "state", value: "second")
        ]) == nil)
    }

    @Test func duplicateCodeParametersAreRejectedEvenWhenValuesMatch() {
        #expect(oauthCallbackParameters([
            URLQueryItem(name: "code", value: "same"),
            URLQueryItem(name: "code", value: "same")
        ]) == nil)
    }

    @Test func duplicateNilValuedParametersAreRejected() {
        #expect(oauthCallbackParameters([
            URLQueryItem(name: "state", value: nil),
            URLQueryItem(name: "state", value: "synthetic-state")
        ]) == nil)
    }

    @Test func emptyParameterListIsSafe() {
        #expect(oauthCallbackParameters([]) == [:])
    }
}

struct AntigravitySessionIdentityTests {
    @Test func UUIDBrainDirectoryKeepsIdentityWhenTaskChanges() async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory.appending(path: "OpenPulse-AGSession-\(UUID())")
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let sourceID = UUID()
        let conversation = fixtureRoot.appending(path: sourceID.uuidString)
        try writeTaskFixture(at: conversation, title: "Synthetic first task")
        let parser = AntigravityParser(brainDir: fixtureRoot, accountService: nil)

        let first = try await parser.parseSessions()
        try writeTaskFixture(at: conversation, title: "Synthetic updated task")
        let second = try await parser.parseSessions()

        #expect(first.count == 1)
        #expect(second.count == 1)
        #expect(first.first?.id == sourceID)
        #expect(second.first?.id == sourceID)
        #expect(second.first?.taskDescription == "Synthetic updated task")
    }

    @Test func nonUUIDBrainDirectoriesStayDistinctAcrossParserInstances() async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory.appending(path: "OpenPulse-AGSession-\(UUID())")
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        try writeTaskFixture(at: fixtureRoot.appending(path: "session-a"), title: "Synthetic task A")
        try writeTaskFixture(at: fixtureRoot.appending(path: "session-b"), title: "Synthetic task B")

        let firstParser = AntigravityParser(brainDir: fixtureRoot, accountService: nil)
        let secondParser = AntigravityParser(brainDir: fixtureRoot, accountService: nil)
        let first = try await firstParser.parseSessions()
        let second = try await secondParser.parseSessions()

        #expect(first.count == 2)
        #expect(second.count == 2)
        #expect(Set(first.map(\.id)).count == 2)
        #expect(Set(first.map(\.id)) == Set(second.map(\.id)))
    }

    private func writeTaskFixture(at directory: URL, title: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let metadata = #"{"updatedAt":"2026-10-03T04:00:00Z","summary":"Synthetic task"}"#
        try Data(metadata.utf8).write(to: directory.appending(path: "task.md.metadata.json"))
        try Data("# \(title)\n\n- [x] Synthetic fixture item\n".utf8)
            .write(to: directory.appending(path: "task.md.resolved"))
    }
}

struct ClaudeSessionParsingRegressionTests {
    @Test func fallbackProjectsAreReadWhenPrimaryDirectoryIsMissing() async throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fallback = root.appending(path: "config/projects")
        let id = UUID()
        try writeSession(at: fallback, id: id, usages: [["input_tokens": 100, "output_tokens": 20]])

        let parser = ClaudeCodeParser(claudeDir: root.appending(path: "missing-primary"), configProjectsDir: fallback)
        let sessions = try await parser.parseSessions()

        #expect(sessions.count == 1)
        #expect(sessions.first?.id == id)
        #expect(sessions.first?.inputTokens == 100)
    }

    @Test func laterPartialAndUsageMissingChunksKeepKnownCounts() async throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let primary = root.appending(path: "claude/projects")
        try writeSession(at: primary, id: UUID(), usages: [
            ["input_tokens": 100, "output_tokens": 20, "cache_read_input_tokens": 40, "cache_creation_input_tokens": 5],
            ["output_tokens": 30],
            nil
        ])
        let parser = ClaudeCodeParser(claudeDir: root.appending(path: "claude"), configProjectsDir: root.appending(path: "missing-fallback"))
        let sessions = try await parser.parseSessions()
        let session = try #require(sessions.first)

        #expect(session.inputTokens == 100)
        #expect(session.outputTokens == 30)
        #expect(session.cacheReadTokens == 40)
        #expect(session.cacheWriteTokens == 5)
    }

    @Test func explicitZeroUsageReplacesEarlierCount() async throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSession(at: root.appending(path: "claude/projects"), id: UUID(), usages: [
            ["input_tokens": 100, "output_tokens": 20, "cache_read_input_tokens": 40],
            ["input_tokens": 0, "output_tokens": 30, "cache_read_input_tokens": 0]
        ])
        let parser = ClaudeCodeParser(claudeDir: root.appending(path: "claude"), configProjectsDir: root.appending(path: "missing-fallback"))
        let sessions = try await parser.parseSessions()
        let session = try #require(sessions.first)

        #expect(session.inputTokens == 0)
        #expect(session.outputTokens == 30)
        #expect(session.cacheReadTokens == 0)
    }

    private func makeFixtureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "OpenPulse-ClaudeSessions-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeSession(at projects: URL, id: UUID, usages: [[String: Int]?]) throws {
        let project = projects.appending(path: "synthetic-project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var data = Data()
        for (index, usage) in usages.enumerated() {
            var message: [String: Any] = ["id": "synthetic-message", "model": "fixture-model"]
            if let usage { message["usage"] = usage }
            let record: [String: Any] = [
                "type": "assistant", "sessionId": id.uuidString,
                "timestamp": "2026-10-03T04:00:0\(index)Z", "message": message
            ]
            data.append(try JSONSerialization.data(withJSONObject: record))
            data.append(0x0A)
        }
        try data.write(to: project.appending(path: "synthetic-session.jsonl"))
    }
}

struct AntigravityRefreshPersistenceTests {
    @Test func refreshFormKeepsReservedCharactersInsideTokenValue() throws {
        let token = "synthetic+token&part=value/more?space #"
        let body = AntigravityParser.refreshRequestBody(refreshToken: token)
        let encoded = try #require(String(data: body, encoding: .utf8))
        var components = URLComponents()
        components.percentEncodedQuery = encoded
        let items = components.queryItems ?? []

        #expect(items.count == 4)
        #expect(items.first(where: { $0.name == "refresh_token" })?.value == token)
        #expect(items.first(where: { $0.name == "grant_type" })?.value == "refresh_token")
        #expect(!encoded.contains("+"))
        #expect(encoded.contains("refresh_token=synthetic%2Btoken%26part%3Dvalue%2Fmore%3Fspace%20%23"))
    }

    @Test func refreshedTokenPreservesFieldsEditedDuringNetworkRequest() throws {
        let fixture = try makeAuthFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = try Data(contentsOf: fixture.file)
        var current = try #require(try JSONSerialization.jsonObject(with: original) as? [String: Any])
        current["project_id"] = "synthetic-project-after-request"
        current["custom"] = ["keep": "synthetic-new-field"]
        try JSONSerialization.data(withJSONObject: current).write(to: fixture.file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.file.path)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(AntigravityParser.persistRefreshedToken(at: fixture.file, originalData: original, newToken: "synthetic-refreshed", expiresIn: 3600, now: now))
        let result = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.file)) as? [String: Any])
        #expect(result["access_token"] as? String == "synthetic-refreshed")
        #expect(result["refresh_token"] as? String == "synthetic-refresh")
        #expect(result["project_id"] as? String == "synthetic-project-after-request")
        #expect((result["custom"] as? [String: String])?["keep"] == "synthetic-new-field")
        #expect(result["expires_in"] as? Int == 3600)
        #expect((result["timestamp"] as? NSNumber)?.int64Value == Int64(now.timeIntervalSince1970 * 1000))
        let permissions = try FileManager.default.attributesOfItem(atPath: fixture.file.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test(arguments: ["access_token", "refresh_token", "email", "type"])
    func externallyChangedCredentialIsNotOverwritten(field: String) throws {
        let fixture = try makeAuthFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = try Data(contentsOf: fixture.file)
        var current = try #require(try JSONSerialization.jsonObject(with: original) as? [String: Any])
        current[field] = "synthetic-external-change"
        let edited = try JSONSerialization.data(withJSONObject: current, options: .sortedKeys)
        try edited.write(to: fixture.file)

        #expect(!AntigravityParser.persistRefreshedToken(at: fixture.file, originalData: original, newToken: "synthetic-refreshed", expiresIn: 3600))
        #expect(try Data(contentsOf: fixture.file) == edited)
    }

    @Test func malformedCurrentAuthFileIsNotOverwritten() throws {
        let fixture = try makeAuthFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = try Data(contentsOf: fixture.file)
        let edited = Data("synthetic unfinished JSON {".utf8)
        try edited.write(to: fixture.file)

        #expect(!AntigravityParser.persistRefreshedToken(at: fixture.file, originalData: original, newToken: "synthetic-refreshed", expiresIn: 3600))
        #expect(try Data(contentsOf: fixture.file) == edited)
    }

    private func makeAuthFixture() throws -> (root: URL, file: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "OpenPulse-AGRefresh-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "synthetic-auth.json")
        let fields: [String: Any] = [
            "access_token": "synthetic-old", "refresh_token": "synthetic-refresh",
            "email": "synthetic@example.invalid", "type": "antigravity",
            "project_id": "synthetic-project-before-request", "expired": "2026-01-01T00:00:00Z"
        ]
        try JSONSerialization.data(withJSONObject: fields).write(to: file)
        return (root, file)
    }
}
