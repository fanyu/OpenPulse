import Testing
@testable import OpenPulse
import Foundation
import SQLite

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

    @Test func fallbackArtifactsAndPlainTaskMarkdownAreParsed() async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory.appending(path: "OpenPulse-AGFallback-\(UUID())")
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let planID = UUID()
        let planDir = fixtureRoot.appending(path: planID.uuidString)
        try FileManager.default.createDirectory(at: planDir, withIntermediateDirectories: true)
        try Data(#"{"updatedAt":"2026-10-05T08:00:00Z","summary":"Plan summary"}"#.utf8)
            .write(to: planDir.appending(path: "implementation_plan.md.metadata.json"))
        try Data("# Upgrade Activity Page\n\nDetails\n".utf8)
            .write(to: planDir.appending(path: "implementation_plan.md"))

        let plainID = UUID()
        let plainDir = fixtureRoot.appending(path: plainID.uuidString)
        try FileManager.default.createDirectory(at: plainDir, withIntermediateDirectories: true)
        try Data("# Plain Task Without Metadata\n- [ ] Step 1\n".utf8)
            .write(to: plainDir.appending(path: "task.md"))

        let parser = AntigravityParser(brainDir: fixtureRoot, accountService: nil)
        let sessions = try await parser.parseSessions()
        let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })

        #expect(byID[planID]?.taskDescription == "Upgrade Activity Page")
        #expect(byID[plainID]?.taskDescription == "Plain Task Without Metadata")
    }

    @Test func t3CodeAntigravityTranscriptAndSummaryDBAreParsedAndLocated() async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory.appending(path: "OpenPulse-T3AG-\(UUID())")
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let acpRoot = fixtureRoot.appending(path: "t3/hash-1/antigravity-acp")
        let convID = UUID()
        let convDir = acpRoot.appending(path: "brain").appending(path: convID.uuidString.lowercased())
        let logsDir = convDir.appending(path: ".system_generated/logs")
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        // Write conversation_summaries.db with workspace_uris (preferring user workspace over /private/tmp)
        let db = try Connection(acpRoot.appending(path: "conversation_summaries.db").path)
        try db.execute("CREATE TABLE conversation_summaries (conversation_id TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '', workspace_uris TEXT NOT NULL DEFAULT '')")
        try db.run(
            "INSERT INTO conversation_summaries (conversation_id, title, workspace_uris) VALUES (?, ?, ?)",
            convID.uuidString.lowercased(),
            "",
            #"["file:///private/tmp/scratch","file:///Users/fixture/OpenPulse"]"#
        )

        // Write transcript.jsonl with USER_INPUT + PLANNER_RESPONSE token telemetry
        let lines: [[String: Any]] = [
            [
                "type": "USER_INPUT",
                "created_at": "2026-11-26T06:00:00Z",
                "content": "<t3_code_instructions>System</t3_code_instructions>\n<user_request>\nAudit activity view\n</user_request>"
            ],
            [
                "type": "PLANNER_RESPONSE",
                "created_at": "2026-11-26T06:02:00Z",
                "model": "gemini-4-neon-medium",
                "input_tokens": 12_000,
                "output_tokens": 850,
                "cache_read_tokens": 40_000
            ],
            [
                "type": "PLANNER_RESPONSE",
                "created_at": "2026-11-26T06:05:00Z",
                "model": "gemini-4-neon-high",
                "input_tokens": 8_000,
                "output_tokens": 1_150,
                "cache_read_tokens": 10_000
            ]
        ]
        var payload = Data()
        for obj in lines {
            payload.append(try JSONSerialization.data(withJSONObject: obj))
            payload.append(0x0A)
        }
        try payload.write(to: logsDir.appending(path: "transcript.jsonl"))

        let parser = AntigravityParser(
            brainDir: fixtureRoot.appending(path: "missing-gemini-brain"),
            t3ProvidersDir: fixtureRoot.appending(path: "t3"),
            accountService: nil
        )
        let sessions = try await parser.parseSessions()
        let session = try #require(sessions.first)

        #expect(sessions.count == 1)
        #expect(session.id == convID)
        #expect(session.tool == .antigravity)
        #expect(session.taskDescription == "Audit activity view")
        #expect(session.inputTokens == 20_000)
        #expect(session.outputTokens == 2_000)
        #expect(session.cacheReadTokens == 50_000)
        #expect(session.model == "gemini-4-neon-high")
        #expect(session.cwd == "/Users/fixture/OpenPulse")
        #expect(session.duration == 300)

        let paths = SessionManagementPaths(
            claudeProjectsDir: fixtureRoot.appending(path: "none"),
            configClaudeProjectsDir: fixtureRoot.appending(path: "none2"),
            codexDir: fixtureRoot.appending(path: "none3"),
            antigravityBrainDir: fixtureRoot.appending(path: "missing-gemini-brain"),
            t3AntigravityProvidersDir: fixtureRoot.appending(path: "t3")
        )
        #expect(SessionManagementService.locateSourceURL(for: .antigravity, sessionID: convID, paths: paths)?.standardizedFileURL == convDir.standardizedFileURL)
    }

    @Test func orcaAntigravityCLIAndPiAgentSessionsAreScannedAndLocated() async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory.appending(path: "OpenPulse-OrcaAG-\(UUID())")
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        // 1. Orca / agy CLI brain under ~/.gemini/antigravity-cli/brain
        let geminiDir = fixtureRoot.appending(path: "gemini")
        let cliRoot = geminiDir.appending(path: "antigravity-cli")
        let agyID = UUID()
        let agyConvDir = cliRoot.appending(path: "brain").appending(path: agyID.uuidString.lowercased())
        let agyLogsDir = agyConvDir.appending(path: ".system_generated/logs")
        try FileManager.default.createDirectory(at: agyLogsDir, withIntermediateDirectories: true)

        let db = try Connection(cliRoot.appending(path: "conversation_summaries.db").path)
        try db.execute("CREATE TABLE conversation_summaries (conversation_id TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '', workspace_uris TEXT NOT NULL DEFAULT '')")
        try db.run(
            "INSERT INTO conversation_summaries (conversation_id, title, workspace_uris) VALUES (?, ?, ?)",
            agyID.uuidString.lowercased(),
            "T3 Code Interaction Mode",
            #"["file:///Users/fixture/.t3/userdata/attachments","file:///Users/fixture/Developer/Mine/OpenPulse"]"#
        )
        let agyLines: [[String: Any]] = [
            [
                "type": "USER_INPUT",
                "created_at": "2026-11-26T07:00:00Z",
                "content": "<USER_REQUEST>\nReview Orca session scan\n</USER_REQUEST>"
            ],
            [
                "type": "PLANNER_RESPONSE",
                "created_at": "2026-11-26T07:03:00Z",
                "model": "gemini-4-neon-high",
                "input_tokens": 5_000,
                "output_tokens": 900,
                "cache_read_tokens": 2_000
            ]
        ]
        var agyData = Data()
        for line in agyLines {
            agyData.append(try JSONSerialization.data(withJSONObject: line))
            agyData.append(0x0A)
        }
        try agyData.write(to: agyLogsDir.appending(path: "transcript.jsonl"))

        // 2. Orca / OMP session under ~/.omp/agent/sessions
        let ompRoot = fixtureRoot.appending(path: "omp/sessions")
        let ompProjectDir = ompRoot.appending(path: "-Developer-Mine-OpenPulse")
        try FileManager.default.createDirectory(at: ompProjectDir, withIntermediateDirectories: true)
        let ompID = UUID()
        let ompFile = ompProjectDir.appending(path: "2026-11-26T08-00-00Z_\(ompID.uuidString.lowercased()).jsonl")
        let ompLines: [[String: Any]] = [
            ["type": "title", "title": "\u{F0450} ORDER: Fix Refresh Bug"],
            ["type": "session", "id": ompID.uuidString.lowercased(), "timestamp": "2026-11-26T08:00:00Z", "cwd": "/Users/fixture/Developer/Mine/OpenPulse"],
            ["type": "model_change", "timestamp": "2026-11-26T08:00:01Z", "model": "google-antigravity/gemini-3.8-flash"],
            [
                "type": "message",
                "timestamp": "2026-11-26T08:04:00Z",
                "message": [
                    "role": "assistant",
                    "provider": "google-antigravity",
                    "model": "gemini-3.8-flash",
                    "usage": ["input": 10_000, "output": 450, "cacheRead": 1_200, "cacheWrite": 0]
                ]
            ]
        ]
        var ompData = Data()
        for line in ompLines {
            ompData.append(try JSONSerialization.data(withJSONObject: line))
            ompData.append(0x0A)
        }
        try ompData.write(to: ompFile)

        let parser = AntigravityParser(
            brainDir: fixtureRoot.appending(path: "missing-primary"),
            geminiDir: geminiDir,
            t3ProvidersDir: nil,
            piSessionRoots: [ompRoot],
            accountService: nil
        )
        let sessions = try await parser.parseSessions()
        let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })

        let agySession = try #require(byID[agyID])
        #expect(agySession.taskDescription == "Review Orca session scan")
        #expect(agySession.cwd == "/Users/fixture/Developer/Mine/OpenPulse")
        #expect(agySession.inputTokens == 5_000)
        #expect(agySession.outputTokens == 900)

        let ompSession = try #require(byID[ompID])
        #expect(ompSession.taskDescription == "ORDER: Fix Refresh Bug")
        #expect(ompSession.cwd == "/Users/fixture/Developer/Mine/OpenPulse")
        #expect(ompSession.model == "gemini-3.8-flash")
        #expect(ompSession.inputTokens == 10_000)
        #expect(ompSession.outputTokens == 450)
        #expect(ompSession.duration == 240)

        let paths = SessionManagementPaths(
            claudeProjectsDir: fixtureRoot.appending(path: "none"),
            configClaudeProjectsDir: fixtureRoot.appending(path: "none2"),
            codexDir: fixtureRoot.appending(path: "none3"),
            antigravityBrainDir: fixtureRoot.appending(path: "missing-primary"),
            t3AntigravityProvidersDir: nil,
            geminiDir: geminiDir,
            piAgentSessionRoots: [ompRoot]
        )
        #expect(SessionManagementService.locateSourceURL(for: .antigravity, sessionID: agyID, paths: paths)?.standardizedFileURL == agyConvDir.standardizedFileURL)
        #expect(SessionManagementService.locateSourceURL(for: .antigravity, sessionID: ompID, paths: paths)?.standardizedFileURL == ompFile.standardizedFileURL)
    }

    @Test func codexParserReadsUpdatedAtModelAndOrcaRuntimeHome() async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory.appending(path: "OpenPulse-CodexOrca-\(UUID())")
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let primaryDir = fixtureRoot.appending(path: "codex-primary")
        let orcaDir = fixtureRoot.appending(path: "orca-codex-home")
        try FileManager.default.createDirectory(at: primaryDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: orcaDir, withIntermediateDirectories: true)

        let threadID = UUID()
        let db = try Connection(orcaDir.appending(path: "state_5.sqlite").path)
        try db.execute("""
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                created_at INTEGER NOT NULL,
                updated_at INTEGER,
                title TEXT,
                first_user_message TEXT,
                tokens_used INTEGER,
                cwd TEXT,
                git_branch TEXT,
                model TEXT,
                model_provider TEXT,
                archived INTEGER DEFAULT 0
            )
        """)
        try db.run(
            "INSERT INTO threads (id, created_at, updated_at, title, first_user_message, tokens_used, cwd, git_branch, model, model_provider, archived) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            threadID.uuidString.lowercased(),
            Int64(1_795_000_000),
            Int64(1_795_000_900),
            "Refactor\n  Session List",
            "Raw prompt",
            Int64(10_000),
            "/Users/fixture/Developer/Mine/OpenPulse",
            "main",
            "gpt-5.4",
            "openai",
            Int64(0)
        )

        let parser = CodexParser(
            codexDir: primaryDir,
            additionalCodexDirs: [orcaDir],
            piSessionRoots: []
        )
        let sessions = try await parser.parseSessions()
        let session = try #require(sessions.first)
        #expect(session.id == threadID)
        #expect(session.model == "gpt-5.4")
        #expect(session.taskDescription == "Refactor Session List")
        #expect(session.duration == 900)
        #expect(session.cwd == "/Users/fixture/Developer/Mine/OpenPulse")
    }

    @Test func sessionSourceDiscoveryFindsFormatsSkipsCachesAndSniffsCustomFolders() async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory.appending(path: "OpenPulse-SourceDiscovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        // 1. Standard Claude projects JSONL
        let claudeProj = fixtureRoot.appending(path: ".claude/projects/-Users-fixture-App")
        try FileManager.default.createDirectory(at: claudeProj, withIntermediateDirectories: true)
        try Data(#"{"type":"assistant","sessionId":"11111111-1111-1111-1111-111111111111"}"#.utf8)
            .write(to: claudeProj.appending(path: "session.jsonl"))

        // 2. Host-isolated Antigravity brain (like T3 / future hosts under ~/.custom-host/userdata/providers/antigravity/h1/antigravity-acp/brain)
        let hostBrain = fixtureRoot.appending(path: ".my-host/userdata/providers/antigravity/h1/antigravity-acp/brain")
        try FileManager.default.createDirectory(at: hostBrain, withIntermediateDirectories: true)
        try Data().write(to: hostBrain.deletingLastPathComponent().appending(path: "conversation_summaries.db"))

        // 3. Isolated Codex home under ~/Library/Application Support/some-orchestrator/codex-runtime-home/home
        let codexHome = fixtureRoot.appending(path: "Library/Application Support/some-orchestrator/codex-runtime-home/home")
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try Data().write(to: codexHome.appending(path: "state_5.sqlite"))

        // 4. Secondary index cache (ai-vault) must NEVER be discovered as a session source
        let fakeCache = fixtureRoot.appending(path: "Library/Application Support/orca/ai-vault/projects/sub")
        try FileManager.default.createDirectory(at: fakeCache, withIntermediateDirectories: true)
        try Data(#"{"type":"assistant","sessionId":"22222222-2222-2222-2222-222222222222"}"#.utf8)
            .write(to: fakeCache.appending(path: "cached.jsonl"))

        // 5. Env-var CODEX_HOME
        let envCodex = fixtureRoot.appending(path: "custom-env-codex")
        try FileManager.default.createDirectory(at: envCodex, withIntermediateDirectories: true)

        let discovered = SessionSourceDiscovery.discoverAll(
            homeDirectory: fixtureRoot,
            environment: ["CODEX_HOME": envCodex.path]
        )

        #expect(discovered.contains { $0.format == .claudeProjects && $0.path == fixtureRoot.appending(path: ".claude/projects").standardizedFileURL.path })
        #expect(discovered.contains { $0.format == .antigravityBrain && $0.path == hostBrain.standardizedFileURL.path })
        #expect(discovered.contains { $0.format == .codexHome && $0.path == codexHome.standardizedFileURL.path })
        #expect(discovered.contains { $0.format == .codexHome && $0.origin == .environment && $0.path == envCodex.standardizedFileURL.path })
        #expect(!discovered.contains { $0.path.contains("ai-vault") })

        // 6. Sniffing a user-added custom Pi/OMP folder works and persists via SessionSourceRegistry
        let customPi = fixtureRoot.appending(path: "external-pi-backup/proj")
        try FileManager.default.createDirectory(at: customPi, withIntermediateDirectories: true)
        try Data(#"{"type":"session","version":3,"id":"33333333-3333-3333-3333-333333333333"}"#.utf8)
            .write(to: customPi.appending(path: "log.jsonl"))

        let suite = "OpenPulse.SourceRegistryTests.\(UUID())"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let registry = SessionSourceRegistry(defaultsSuiteName: suite)
        registry.ensureDiscovered(homeDirectory: fixtureRoot, environment: [:])

        let added = registry.addCustomDirectory(fixtureRoot.appending(path: "external-pi-backup"))
        #expect(added.count == 1)
        #expect(added.first?.format == .piAgentSessions)
        let entryID = try #require(added.first?.id)

        #expect(registry.enabledURLs(for: .piAgentSessions).contains { $0.standardizedFileURL.path == fixtureRoot.appending(path: "external-pi-backup").standardizedFileURL.path })
        registry.setEnabled(false, for: entryID)
        #expect(!registry.enabledURLs(for: .piAgentSessions).contains { $0.standardizedFileURL.path == fixtureRoot.appending(path: "external-pi-backup").standardizedFileURL.path })
        registry.removeCustomSource(id: entryID)
        #expect(!registry.allEntries().contains { $0.id == entryID })
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
