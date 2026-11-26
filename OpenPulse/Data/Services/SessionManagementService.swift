import Foundation
import CryptoKit
import SwiftData
import SQLite
import os

enum SessionDeletionMode: String, CaseIterable, Identifiable, Sendable {
    case hideInOpenPulse
    case trashLocalFiles

    var id: String { rawValue }
}

struct SessionDeletionTarget: Identifiable, Hashable, Sendable {
    let id: UUID
    let tool: Tool
    let title: String
    let projectPath: String
}

struct SessionDeletionReport: Equatable, Sendable {
    let mode: SessionDeletionMode
    let deletedRecords: Int
    let trashedURLs: [URL]
    let archivedCodexThreads: Int
    let hiddenIDsAdded: Int
    let warnings: [String]
}

struct SessionManagementPaths: Sendable {
    let claudeProjectsDir: URL
    let configClaudeProjectsDir: URL
    let additionalClaudeProjectDirs: [URL]
    let claudeDesktopSessionsDir: URL?
    let codexDir: URL
    let additionalCodexDirs: [URL]
    let antigravityBrainDir: URL
    let additionalAntigravityBrainDirs: [URL]
    let geminiDir: URL?
    let t3AntigravityProvidersDir: URL?
    let piAgentSessionRoots: [URL]

    init(
        claudeProjectsDir: URL,
        configClaudeProjectsDir: URL,
        codexDir: URL,
        antigravityBrainDir: URL,
        t3AntigravityProvidersDir: URL? = nil,
        geminiDir: URL? = nil,
        additionalCodexDirs: [URL] = [],
        additionalClaudeProjectDirs: [URL] = [],
        additionalAntigravityBrainDirs: [URL] = [],
        claudeDesktopSessionsDir: URL? = nil,
        piAgentSessionRoots: [URL] = []
    ) {
        self.claudeProjectsDir = claudeProjectsDir
        self.configClaudeProjectsDir = configClaudeProjectsDir
        self.additionalClaudeProjectDirs = additionalClaudeProjectDirs
        self.claudeDesktopSessionsDir = claudeDesktopSessionsDir
        self.codexDir = codexDir
        self.additionalCodexDirs = additionalCodexDirs
        self.antigravityBrainDir = antigravityBrainDir
        self.additionalAntigravityBrainDirs = additionalAntigravityBrainDirs
        self.geminiDir = geminiDir
        self.t3AntigravityProvidersDir = t3AntigravityProvidersDir
        self.piAgentSessionRoots = piAgentSessionRoots
    }

    static var standard: SessionManagementPaths {
        let registry = SessionSourceRegistry.shared
        let claudeDirs = registry.enabledURLs(for: .claudeProjects)
        let codexDirs = registry.enabledURLs(for: .codexHome)
        let agDirs = registry.enabledURLs(for: .antigravityBrain)
        let piDirs = registry.enabledURLs(for: .piAgentSessions)

        return SessionManagementPaths(
            claudeProjectsDir: .homeDirectory.appending(path: ".claude/projects"),
            configClaudeProjectsDir: .homeDirectory.appending(path: ".config/claude/projects"),
            codexDir: CodexParser.defaultCodexDir,
            antigravityBrainDir: AntigravityParser.defaultBrainDir,
            t3AntigravityProvidersDir: AntigravityParser.defaultT3ProvidersDir,
            geminiDir: AntigravityParser.defaultGeminiDir,
            additionalCodexDirs: codexDirs + [CodexParser.defaultOrcaCodexHomeDir],
            additionalClaudeProjectDirs: claudeDirs,
            additionalAntigravityBrainDirs: agDirs,
            claudeDesktopSessionsDir: .homeDirectory
                .appending(path: "Library/Application Support/Claude/claude-code-sessions"),
            piAgentSessionRoots: piDirs.isEmpty ? PiAgentSessionScanner.defaultSessionRoots : piDirs
        )
    }

    var allClaudeProjectDirs: [URL] {
        Self.deduplicate([claudeProjectsDir, configClaudeProjectsDir] + additionalClaudeProjectDirs)
    }

    var allCodexDirs: [URL] {
        Self.deduplicate([codexDir] + additionalCodexDirs)
    }

    var allAntigravityBrainDirs: [URL] {
        let discovered = AntigravityParser.discoveredBrainRoots(
            primaryBrainDir: antigravityBrainDir,
            geminiDir: geminiDir,
            t3ProvidersDir: t3AntigravityProvidersDir
        )
        return Self.deduplicate(discovered + additionalAntigravityBrainDirs)
    }

    private static func deduplicate(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}

// MARK: - Format-Based Session Source Auto-Discovery & Registry

/// Underlying local session storage format (decoupled from host app names like T3 / Orca / Rex / IDE).
enum SessionSourceFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case claudeProjects
    case codexHome
    case antigravityBrain
    case piAgentSessions

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeProjects:   String(localized: "Claude JSONL")
        case .codexHome:        String(localized: "Codex 会话目录")
        case .antigravityBrain: String(localized: "Antigravity Brain")
        case .piAgentSessions:  String(localized: "Pi / OMP JSONL")
        }
    }

    var systemImage: String {
        switch self {
        case .claudeProjects:   "doc.plaintext"
        case .codexHome:        "cylinder.split.1x2"
        case .antigravityBrain: "brain.head.profile"
        case .piAgentSessions:  "square.stack.3d.up"
        }
    }

    var associatedTools: [Tool] {
        switch self {
        case .claudeProjects:   [.claudeCode]
        case .codexHome:        [.codex]
        case .antigravityBrain: [.antigravity]
        case .piAgentSessions:  [.antigravity, .claudeCode, .codex]
        }
    }
}

enum SessionSourceOrigin: String, Codable, Sendable {
    case standard
    case environment
    case autoDiscovered
    case custom

    var badgeTitle: String {
        switch self {
        case .standard:       String(localized: "默认")
        case .environment:    String(localized: "环境变量")
        case .autoDiscovered: String(localized: "自动发现")
        case .custom:         String(localized: "自定义")
        }
    }
}

struct SessionSourceEntry: Codable, Identifiable, Equatable, Sendable {
    let path: String
    let format: SessionSourceFormat
    let origin: SessionSourceOrigin
    var isEnabled: Bool

    var id: String { "\(format.rawValue)::\(path)" }
    var url: URL { URL(fileURLWithPath: path) }

    var abbreviatedPath: String {
        let home = URL.homeDirectory.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

/// Discovers local session storage directories by structural markers (not hardcoded app names)
/// while strictly skipping secondary index caches (e.g. Orca ai-vault, Rex snapshot.db).
enum SessionSourceDiscovery {
    private static let ignoredDirectoryNames: Set<String> = [
        "ai-vault", "cache", "caches", "code cache", "gpucache", "dawngraphitecache",
        "dawnwebgpucache", "indexeddb", "local storage", "session storage", "webstorage",
        "crashpad", "blob_storage", "partitions", "shared dictionary", "node_modules",
        ".git", "deriveddata", "trash", ".trash", "logs", "log", "backups", "extensions",
        "plugins", "plugins-data", "daemon-host", "worktrees", "attachments", "snapshot",
        "snapshots", "uploads", "terminal", "terminal-history", "crashes", "builtin",
        "annotations", "conversations", "implicit", "chrome", "downloads", "documents",
        "desktop", "movies", "music", "pictures", "public", "applications", "library",
        "developer", "xcode", "google", "apple", "com.apple", "mozilla", "firefox",
        "slack", "discord", "spotify", "telegram", "wechat", "notion", "obsidian",
    ]

    /// Standard + env-var + shallow structural probe across `~/.*`, `~/.config`, `~/.local/share`, `~/Library/Application Support`.
    static func discoverAll(
        homeDirectory: URL = .homeDirectory,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [SessionSourceEntry] {
        let fm = FileManager.default
        var results: [String: SessionSourceEntry] = [:]

        func register(_ url: URL, format: SessionSourceFormat, origin: SessionSourceOrigin) {
            let std = url.standardizedFileURL.path
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: std, isDirectory: &isDir), isDir.boolValue else { return }
            let key = "\(format.rawValue)::\(std)"
            if results[key] == nil {
                results[key] = SessionSourceEntry(path: std, format: format, origin: origin, isEnabled: true)
            }
        }

        // 1. Environment variables (honors user-configured isolated homes across any host)
        if let raw = environment["CLAUDE_CONFIG_DIR"], !raw.isEmpty {
            let url = URL(fileURLWithPath: raw)
            register(url.appending(path: "projects"), format: .claudeProjects, origin: .environment)
            if url.lastPathComponent == "projects" {
                register(url, format: .claudeProjects, origin: .environment)
            }
        }
        if let raw = environment["CODEX_HOME"], !raw.isEmpty {
            register(URL(fileURLWithPath: raw), format: .codexHome, origin: .environment)
        }
        for key in ["ANTIGRAVITY_HOME", "GEMINI_HOME"] {
            if let raw = environment[key], !raw.isEmpty {
                let url = URL(fileURLWithPath: raw)
                register(url.appending(path: "brain"), format: .antigravityBrain, origin: .environment)
                if url.lastPathComponent == "brain" {
                    register(url, format: .antigravityBrain, origin: .environment)
                }
            }
        }
        for key in ["PI_CODING_AGENT_DIR", "OMP_AGENT_DIR"] {
            if let raw = environment[key], !raw.isEmpty {
                let url = URL(fileURLWithPath: raw)
                register(url.appending(path: "sessions"), format: .piAgentSessions, origin: .environment)
                if url.lastPathComponent == "sessions" {
                    register(url, format: .piAgentSessions, origin: .environment)
                }
            }
        }

        // 2. Standard canonical engine roots
        register(homeDirectory.appending(path: ".claude/projects"), format: .claudeProjects, origin: .standard)
        register(homeDirectory.appending(path: ".config/claude/projects"), format: .claudeProjects, origin: .standard)
        register(homeDirectory.appending(path: ".codex"), format: .codexHome, origin: .standard)
        register(homeDirectory.appending(path: ".gemini/antigravity/brain"), format: .antigravityBrain, origin: .standard)
        register(homeDirectory.appending(path: ".gemini/antigravity-cli/brain"), format: .antigravityBrain, origin: .standard)
        register(homeDirectory.appending(path: ".gemini/antigravity-acp/brain"), format: .antigravityBrain, origin: .standard)
        register(homeDirectory.appending(path: ".omp/agent/sessions"), format: .piAgentSessions, origin: .standard)
        register(homeDirectory.appending(path: ".pi/agent/sessions"), format: .piAgentSessions, origin: .standard)

        // 3. Shallow structural auto-discovery (host-agnostic: finds T3, Orca, Rex, or future isolated homes automatically)
        let probeRoots: [(url: URL, hiddenOnly: Bool, maxDepth: Int)] = [
            (homeDirectory, true, 4),
            (homeDirectory.appending(path: ".config"), false, 3),
            (homeDirectory.appending(path: ".local/share"), false, 3),
            (homeDirectory.appending(path: "Library/Application Support"), false, 3),
        ]

        for (probeRoot, hiddenOnly, maxDepth) in probeRoots where fm.fileExists(atPath: probeRoot.path) {
            guard let topChildren = try? fm.contentsOfDirectory(
                at: probeRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            ) else { continue }

            for child in topChildren {
                let name = child.lastPathComponent
                if hiddenOnly && !name.hasPrefix(".") { continue }
                if isIgnoredDirectoryName(name) { continue }
                guard isRealDirectory(child) else { continue }

                probeDirectory(child, depth: 1, maxDepth: maxDepth) { matchedURL, format in
                    register(matchedURL, format: format, origin: .autoDiscovered)
                }
            }
        }

        return results.values.sorted { lhs, rhs in
            if lhs.format != rhs.format {
                return formatSortIndex(lhs.format) < formatSortIndex(rhs.format)
            }
            if lhs.origin != rhs.origin {
                return originSortIndex(lhs.origin) < originSortIndex(rhs.origin)
            }
            return lhs.path < rhs.path
        }
    }

    /// Sniffs a user-chosen custom folder (and up to 3 levels inside it) to identify supported session format(s).
    static func sniffSources(at directory: URL) -> [SessionSourceEntry] {
        let std = directory.standardizedFileURL
        guard isRealDirectory(std) else { return [] }

        var matched: [String: SessionSourceEntry] = [:]
        func add(_ url: URL, _ format: SessionSourceFormat) {
            let path = url.standardizedFileURL.path
            let key = "\(format.rawValue)::\(path)"
            if matched[key] == nil {
                matched[key] = SessionSourceEntry(path: path, format: format, origin: .custom, isEnabled: true)
            }
        }

        // Direct check on the selected folder itself first
        if let directFormat = detectDirectFormat(of: std) {
            add(std, directFormat)
        }

        // Also check shallow subdirectories (e.g., user picked ~/.t3 or a custom host root)
        if matched.isEmpty {
            probeDirectory(std, depth: 0, maxDepth: 4) { url, format in
                add(url, format)
            }
        }

        return matched.values.sorted { lhs, rhs in
            if lhs.format != rhs.format {
                return formatSortIndex(lhs.format) < formatSortIndex(rhs.format)
            }
            return lhs.path < rhs.path
        }
    }

    private static func probeDirectory(
        _ dir: URL,
        depth: Int,
        maxDepth: Int,
        onMatch: (URL, SessionSourceFormat) -> Void
    ) {
        if let format = detectDirectFormat(of: dir) {
            onMatch(dir, format)
            // Don't descend into already-matched leaf session directories.
            return
        }

        let nameLower = dir.lastPathComponent.lowercased()
        // Allow stepping deeper through standard provider nesting (e.g. userdata/providers/<provider>/<hash>/...)
        let effectiveMaxDepth = (nameLower == "userdata" || nameLower == "providers" || nameLower == "antigravity" || nameLower == "codex-runtime-home")
            ? max(maxDepth, depth + 3)
            : maxDepth
        guard depth < effectiveMaxDepth else { return }

        guard let children = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        // Cap breadth on huge unrelated directories so discovery stays sub-50ms.
        guard children.count <= 120 else { return }

        for child in children {
            let childName = child.lastPathComponent
            if isIgnoredDirectoryName(childName) { continue }
            guard isRealDirectory(child) else { continue }
            probeDirectory(child, depth: depth + 1, maxDepth: effectiveMaxDepth, onMatch: onMatch)
        }
    }

    private static func detectDirectFormat(of dir: URL) -> SessionSourceFormat? {
        let fm = FileManager.default
        let nameLower = dir.lastPathComponent.lowercased()

        // 1. Codex home: state_5.sqlite + (sessions or config.toml or archived_sessions)
        let stateDB = dir.appending(path: "state_5.sqlite").path
        if fm.fileExists(atPath: stateDB) {
            return .codexHome
        }
        if nameLower == "home",
           fm.fileExists(atPath: dir.appending(path: "sessions").path),
           dir.path.lowercased().contains("codex") {
            return .codexHome
        }

        // 2. Antigravity brain: directory named "brain" with sibling conversation_summaries.db/conversations or brain artifacts
        if nameLower == "brain" {
            let parent = dir.deletingLastPathComponent()
            if fm.fileExists(atPath: parent.appending(path: "conversation_summaries.db").path)
                || fm.fileExists(atPath: parent.appending(path: "conversations").path)
                || parent.lastPathComponent.lowercased().contains("antigravity")
                || containsAntigravityBrainConversation(in: dir) {
                return .antigravityBrain
            }
        }

        // 3. Pi / OMP agent sessions: */agent/sessions or directory whose JSONLs start with Pi v3 session schema
        if nameLower == "sessions",
           dir.deletingLastPathComponent().lastPathComponent.lowercased() == "agent" {
            return .piAgentSessions
        }

        // 4. Claude projects: directory named "projects" with Claude-style JSONL sessions
        if nameLower == "projects",
           containsClaudeProjectJSONL(in: dir) {
            return .claudeProjects
        }

        // 5. Fallback for user-selected custom directories with non-standard names
        if containsPiSessionJSONL(in: dir) {
            return .piAgentSessions
        }
        if containsAntigravityBrainConversation(in: dir) {
            return .antigravityBrain
        }
        if containsClaudeProjectJSONL(in: dir) {
            return .claudeProjects
        }

        return nil
    }

    private static func containsAntigravityBrainConversation(in dir: URL) -> Bool {
        let fm = FileManager.default
        guard let subdirs = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return false
        }
        for sub in subdirs.prefix(8) where isRealDirectory(sub) {
            if fm.fileExists(atPath: sub.appending(path: ".system_generated/logs/transcript.jsonl").path)
                || fm.fileExists(atPath: sub.appending(path: "task.md.metadata.json").path)
                || fm.fileExists(atPath: sub.appending(path: "task.md").path) {
                return true
            }
        }
        return false
    }

    private static func containsClaudeProjectJSONL(in dir: URL) -> Bool {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return false
        }
        for entry in entries.prefix(12) {
            if entry.pathExtension.lowercased() == "jsonl", isClaudeJSONL(entry) {
                return true
            }
            if isRealDirectory(entry),
               let nested = try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil) {
                for file in nested.prefix(6) where file.pathExtension.lowercased() == "jsonl" {
                    if isClaudeJSONL(file) { return true }
                }
            }
        }
        return false
    }

    private static func isClaudeJSONL(_ url: URL) -> Bool {
        var matched = false
        JSONLReader.forEachLine(of: url, until: { line, idx in
            if idx >= 8 { return true }
            if let text = String(data: line, encoding: .utf8),
               text.contains("\"sessionId\""),
               (text.contains("\"type\":\"assistant\"") || text.contains("\"type\": \"assistant\"")
                || text.contains("\"type\":\"user\"") || text.contains("\"type\": \"user\"")) {
                matched = true
                return true
            }
            return false
        })
        return matched
    }

    private static func containsPiSessionJSONL(in dir: URL) -> Bool {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return false
        }
        for entry in entries.prefix(10) {
            if entry.pathExtension.lowercased() == "jsonl", isPiJSONL(entry) {
                return true
            }
            if isRealDirectory(entry),
               let nested = try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil) {
                for file in nested.prefix(5) where file.pathExtension.lowercased() == "jsonl" {
                    if isPiJSONL(file) { return true }
                }
            }
        }
        return false
    }

    private static func isPiJSONL(_ url: URL) -> Bool {
        var matched = false
        JSONLReader.forEachLine(of: url, until: { line, idx in
            if idx >= 5 { return true }
            if let text = String(data: line, encoding: .utf8),
               text.contains("\"type\":\"session\""),
               text.contains("\"version\":3") {
                matched = true
                return true
            }
            return false
        })
        return matched
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func isIgnoredDirectoryName(_ name: String) -> Bool {
        let lower = name.lowercased()
        if ignoredDirectoryNames.contains(lower) { return true }
        if lower.hasPrefix("com.apple.") { return true }
        return false
    }

    private static func formatSortIndex(_ format: SessionSourceFormat) -> Int {
        switch format {
        case .claudeProjects:   0
        case .codexHome:        1
        case .antigravityBrain: 2
        case .piAgentSessions:  3
        }
    }

    private static func originSortIndex(_ origin: SessionSourceOrigin) -> Int {
        switch origin {
        case .standard:       0
        case .environment:    1
        case .autoDiscovered: 2
        case .custom:         3
        }
    }
}

/// Thread-safe, UserDefaults-backed registry of discovered & custom local session sources.
/// Auto-discovery runs once on demand and caches results so background/startup overhead stays near zero.
final class SessionSourceRegistry: Sendable {
    static let shared = SessionSourceRegistry()

    private static let discoveredKey = "sessions.sources.discovered.v1"
    private static let customKey = "sessions.sources.custom.v1"
    private static let disabledKey = "sessions.sources.disabled.v1"

    private struct State: Sendable {
        var hasLoaded = false
        var discovered: [SessionSourceEntry] = []
        var custom: [SessionSourceEntry] = []
        var disabledIDs: Set<String> = []
    }

    private let defaultsSuiteName: String?
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(defaultsSuiteName: String? = nil) {
        self.defaultsSuiteName = defaultsSuiteName
    }

    private func defaults() -> UserDefaults {
        defaultsSuiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    /// Loads cached sources from UserDefaults, running shallow auto-discovery once if no cache exists yet.
    func ensureDiscovered(
        homeDirectory: URL = .homeDirectory,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let needsLoad = state.withLock { !$0.hasLoaded }
        guard needsLoad else { return }

        let ud = defaults()
        let decoder = JSONDecoder()
        let cachedDiscovered = ud.data(forKey: Self.discoveredKey)
            .flatMap { try? decoder.decode([SessionSourceEntry].self, from: $0) }
        let cachedCustom = ud.data(forKey: Self.customKey)
            .flatMap { try? decoder.decode([SessionSourceEntry].self, from: $0) } ?? []
        let disabled = Set(ud.stringArray(forKey: Self.disabledKey) ?? [])

        let discovered: [SessionSourceEntry]
        if let cachedDiscovered, !cachedDiscovered.isEmpty {
            discovered = cachedDiscovered
        } else {
            discovered = SessionSourceDiscovery.discoverAll(homeDirectory: homeDirectory, environment: environment)
            if let encoded = try? JSONEncoder().encode(discovered) {
                ud.set(encoded, forKey: Self.discoveredKey)
            }
        }

        state.withLock { s in
            s.hasLoaded = true
            s.discovered = discovered
            s.custom = cachedCustom
            s.disabledIDs = disabled
        }
    }

    /// Re-runs shallow structural discovery on disk and updates the persistent cache.
    @discardableResult
    func rediscover(
        homeDirectory: URL = .homeDirectory,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [SessionSourceEntry] {
        ensureDiscovered(homeDirectory: homeDirectory, environment: environment)
        let fresh = SessionSourceDiscovery.discoverAll(homeDirectory: homeDirectory, environment: environment)
        let ud = defaults()
        if let encoded = try? JSONEncoder().encode(fresh) {
            ud.set(encoded, forKey: Self.discoveredKey)
        }
        state.withLock { s in
            s.discovered = fresh
        }
        return allEntries()
    }

    func allEntries() -> [SessionSourceEntry] {
        ensureDiscovered()
        return state.withLock { s in
            var merged: [String: SessionSourceEntry] = [:]
            for var entry in s.discovered {
                entry.isEnabled = !s.disabledIDs.contains(entry.id)
                merged[entry.id] = entry
            }
            for var entry in s.custom {
                entry.isEnabled = !s.disabledIDs.contains(entry.id)
                merged[entry.id] = entry
            }
            return merged.values.sorted { lhs, rhs in
                if lhs.format != rhs.format { return lhs.format.rawValue < rhs.format.rawValue }
                return lhs.path < rhs.path
            }
        }
    }

    func enabledURLs(for format: SessionSourceFormat) -> [URL] {
        allEntries()
            .filter { $0.format == format && $0.isEnabled }
            .map(\.url)
    }

    func enabledFSEventWatchPaths() -> [String] {
        let fm = FileManager.default
        var seen = Set<String>()
        var paths: [String] = []
        for entry in allEntries() where entry.isEnabled {
            let watchPath: String
            switch entry.format {
            case .antigravityBrain:
                // Watch parent dir when conversation_summaries.db lives alongside brain/.
                let parent = entry.url.deletingLastPathComponent()
                if fm.fileExists(atPath: parent.appending(path: "conversation_summaries.db").path) {
                    watchPath = parent.standardizedFileURL.path
                } else {
                    watchPath = entry.path
                }
            case .codexHome:
                let sessions = entry.url.appending(path: "sessions").standardizedFileURL.path
                watchPath = fm.fileExists(atPath: sessions) ? sessions : entry.path
            case .claudeProjects, .piAgentSessions:
                watchPath = entry.path
            }
            if fm.fileExists(atPath: watchPath), seen.insert(watchPath).inserted {
                paths.append(watchPath)
            }
        }
        return paths
    }

    func toolsAffected(by changedPath: String) -> Set<Tool> {
        var tools = Set<Tool>()
        for entry in allEntries() where entry.isEnabled {
            let rootPath = entry.format == .antigravityBrain
                ? entry.url.deletingLastPathComponent().standardizedFileURL.path
                : entry.path
            if changedPath == rootPath || changedPath.hasPrefix(rootPath + "/") {
                tools.formUnion(entry.format.associatedTools)
            }
        }
        return tools
    }

    func setEnabled(_ enabled: Bool, for entryID: String) {
        ensureDiscovered()
        let updatedDisabled: [String] = state.withLock { s in
            if enabled {
                s.disabledIDs.remove(entryID)
            } else {
                s.disabledIDs.insert(entryID)
            }
            return s.disabledIDs.sorted()
        }
        defaults().set(updatedDisabled, forKey: Self.disabledKey)
    }

    /// Sniffs a custom folder and registers any detected session source(s). Returns the added entries.
    @discardableResult
    func addCustomDirectory(_ directory: URL) -> [SessionSourceEntry] {
        ensureDiscovered()
        let detected = SessionSourceDiscovery.sniffSources(at: directory)
        guard !detected.isEmpty else { return [] }

        let persistedCustom: [SessionSourceEntry] = state.withLock { s in
            var byID = Dictionary(uniqueKeysWithValues: s.custom.map { ($0.id, $0) })
            for entry in detected {
                byID[entry.id] = entry
                s.disabledIDs.remove(entry.id)
            }
            s.custom = Array(byID.values)
            return s.custom
        }
        let ud = defaults()
        if let encoded = try? JSONEncoder().encode(persistedCustom) {
            ud.set(encoded, forKey: Self.customKey)
        }
        ud.set(state.withLock { $0.disabledIDs.sorted() }, forKey: Self.disabledKey)
        return detected
    }

    func removeCustomSource(id: String) {
        ensureDiscovered()
        let persistedCustom: [SessionSourceEntry] = state.withLock { s in
            s.custom.removeAll { $0.id == id }
            s.disabledIDs.remove(id)
            return s.custom
        }
        let ud = defaults()
        if let encoded = try? JSONEncoder().encode(persistedCustom) {
            ud.set(encoded, forKey: Self.customKey)
        }
        ud.set(state.withLock { $0.disabledIDs.sorted() }, forKey: Self.disabledKey)
    }
}

// MARK: - Shared Pi / OMP (Orca) Agent Session Scanner

/// Parses Pi / Oh-My-Pi (`~/.omp/agent/sessions`, `~/.pi/agent/sessions`) JSONL session logs,
/// used by Orca and Pi CLI agents when routing through Antigravity, Claude, or Codex models.
enum PiAgentSessionScanner {
    static let defaultSessionRoots: [URL] = [
        .homeDirectory.appending(path: ".omp/agent/sessions"),
        .homeDirectory.appending(path: ".pi/agent/sessions"),
    ]

    private static let isoWithFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let isoPlain = Date.ISO8601FormatStyle()

    private struct CachedParsedFile: Sendable {
        let modifiedAt: Date
        let size: Int
        let session: ToolSession?
    }

    /// File-level mtime+size cache so unchanged OMP/Pi JSONL files are never re-read across tools or incremental scans.
    private static let fileCache = OSAllocatedUnfairLock(initialState: [String: CachedParsedFile]())

    static func parseSessions(
        for targetTool: Tool,
        since cutoff: Date? = nil,
        roots: [URL] = defaultSessionRoots
    ) -> [ToolSession] {
        let fm = FileManager.default
        var byID: [UUID: ToolSession] = [:]

        for root in roots where fm.fileExists(atPath: root.path) {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let url as URL in enumerator where url.pathExtension.lowercased() == "jsonl" {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                if let cutoff, let modDate = values?.contentModificationDate, modDate < cutoff {
                    continue
                }
                let parsed: ToolSession?
                if let modDate = values?.contentModificationDate, let fileSize = values?.fileSize {
                    let key = url.standardizedFileURL.path
                    if let cached = fileCache.withLock({ $0[key] }),
                       cached.modifiedAt == modDate,
                       cached.size == fileSize {
                        parsed = cached.session
                    } else {
                        let fresh = parseSessionFile(url)
                        fileCache.withLock { cache in
                            if cache.count > 2_000 { cache.removeAll(keepingCapacity: true) }
                            cache[key] = CachedParsedFile(modifiedAt: modDate, size: fileSize, session: fresh)
                        }
                        parsed = fresh
                    }
                } else {
                    parsed = parseSessionFile(url)
                }

                guard let parsed, parsed.tool == targetTool else { continue }
                if let existing = byID[parsed.id] {
                    if parsed.totalTokens > existing.totalTokens
                        || (parsed.totalTokens == existing.totalTokens && (parsed.endedAt ?? parsed.startedAt) > (existing.endedAt ?? existing.startedAt)) {
                        byID[parsed.id] = parsed
                    }
                } else {
                    byID[parsed.id] = parsed
                }
            }
        }

        return byID.values.sorted { $0.startedAt < $1.startedAt }
    }

    static func locateSessionURLs(sessionID: UUID, roots: [URL] = defaultSessionRoots) -> [URL] {
        let fm = FileManager.default
        let needle = sessionID.uuidString.lowercased()
        var matches: [URL] = []

        for root in roots where fm.fileExists(atPath: root.path) {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let url as URL in enumerator where url.pathExtension.lowercased() == "jsonl" {
                let name = url.lastPathComponent.lowercased()
                if name.contains(needle) || deterministicSessionID(for: url) == sessionID {
                    matches.append(url)
                }
            }
        }
        return matches
    }

    static func parseSessionFile(_ url: URL) -> ToolSession? {
        let decoder = JSONDecoder()

        var rawSessionID: String?
        var sessionCwd = ""
        var title = ""
        var firstUserPrompt = ""
        var firstTimestamp: Date?
        var lastTimestamp: Date?
        var latestModelRaw = ""
        var providerCounts: [Tool: Int] = [:]
        var fallbackToolFromModelChange: Tool?
        var totalInput = 0
        var totalOutput = 0
        var totalCacheRead = 0
        var totalCacheWrite = 0

        JSONLReader.forEachLine(of: url) { lineData, _ in
            guard !lineData.isEmpty,
                  let entry = try? decoder.decode(PiSessionEntry.self, from: lineData) else { return }

            if let ts = entry.timestamp.flatMap(parseTimestamp) {
                if firstTimestamp == nil { firstTimestamp = ts }
                lastTimestamp = ts
            }

            switch entry.type {
            case "title":
                if let t = entry.title, !t.isEmpty {
                    let cleaned = cleanDisplayTitle(t)
                    if !cleaned.isEmpty { title = cleaned }
                }

            case "session":
                if rawSessionID == nil, let id = entry.id, !id.isEmpty {
                    rawSessionID = id
                }
                if sessionCwd.isEmpty, let cwd = entry.cwd, !cwd.isEmpty {
                    sessionCwd = cwd
                }
                if title.isEmpty, let t = entry.title, !t.isEmpty {
                    title = cleanDisplayTitle(t)
                }

            case "model_change":
                if let modelStr = entry.model, !modelStr.isEmpty {
                    latestModelRaw = modelStr
                    if let mapped = resolveTool(provider: nil, model: modelStr) {
                        fallbackToolFromModelChange = mapped
                    }
                }

            case "message":
                guard let msg = entry.message else { return }
                if msg.role == "user", firstUserPrompt.isEmpty, let text = msg.textContent {
                    let cleaned = cleanDisplayTitle(text)
                    if !cleaned.isEmpty { firstUserPrompt = cleaned }
                } else if msg.role == "assistant" {
                    if let m = msg.model, !m.isEmpty {
                        latestModelRaw = m
                    }
                    if let mapped = resolveTool(provider: msg.provider, model: msg.model) {
                        providerCounts[mapped, default: 0] += 1
                    }
                    if let u = msg.usage {
                        totalInput += u.input ?? 0
                        totalOutput += u.output ?? 0
                        totalCacheRead += u.cacheRead ?? 0
                        totalCacheWrite += u.cacheWrite ?? 0
                    }
                }

            default:
                break
            }
        }

        let resolvedTool: Tool? = providerCounts
            .max(by: { lhs, rhs in lhs.value == rhs.value ? lhs.key.rawValue > rhs.key.rawValue : lhs.value < rhs.value })?
            .key ?? fallbackToolFromModelChange

        guard let tool = resolvedTool, tool != .copilot else { return nil }

        let startDate = firstTimestamp
            ?? (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard let startDate else { return nil }
        let endDate = lastTimestamp.flatMap { $0 > startDate ? $0 : nil }

        let resolvedTitle = !title.isEmpty ? title : firstUserPrompt
        if totalInput + totalOutput + totalCacheRead + totalCacheWrite == 0 && resolvedTitle.isEmpty {
            return nil
        }

        let id = rawSessionID.flatMap(UUID.init(uuidString:))
            ?? extractUUIDFromFilename(url)
            ?? deterministicSessionID(for: url)

        let displayModel: String
        if let slashIdx = latestModelRaw.lastIndex(of: "/") {
            displayModel = String(latestModelRaw[latestModelRaw.index(after: slashIdx)...])
        } else {
            displayModel = latestModelRaw
        }

        return ToolSession(
            id: id,
            tool: tool,
            startedAt: startDate,
            endedAt: endDate,
            inputTokens: totalInput,
            outputTokens: totalOutput,
            cacheReadTokens: totalCacheRead,
            cacheWriteTokens: totalCacheWrite,
            taskDescription: resolvedTitle,
            model: displayModel,
            cwd: sessionCwd
        )
    }

    static func resolveTool(provider: String?, model: String?) -> Tool? {
        let p = (provider ?? "").lowercased()
        let m = (model ?? "").lowercased()

        if p.contains("antigravity") || p.contains("google") || m.hasPrefix("google-antigravity/") {
            return .antigravity
        }
        if p.contains("copilot") || m.hasPrefix("github-copilot/") {
            return .copilot
        }
        if p.contains("anthropic") || m.hasPrefix("anthropic/") {
            return .claudeCode
        }
        if p.contains("openai") || p.contains("codex") || m.hasPrefix("openai") || m.hasPrefix("codex/") {
            return .codex
        }

        // Fallback to model name (e.g., cliproxy/gpt-5.6-sol, cliproxy/claude-..., cliproxy/gemini-...)
        let modelBase = m.split(separator: "/").last.map(String.init) ?? m
        if modelBase.contains("gemini") {
            return .antigravity
        }
        if modelBase.contains("claude") {
            return .claudeCode
        }
        if modelBase.contains("gpt") || modelBase.contains("codex") || modelBase.hasPrefix("o1") || modelBase.hasPrefix("o3") || modelBase.hasPrefix("o4") {
            return .codex
        }
        return nil
    }

    static func cleanDisplayTitle(_ raw: String) -> String {
        // Strip Private Use Area Nerd Font icons commonly prefixed by omp titles (e.g., "󰑐 ORDER: ...")
        let filteredScalars = raw.unicodeScalars.filter { scalar in
            let v = scalar.value
            let isBMPPUA = (0xE000...0xF8FF).contains(v)
            let isSuppPUA = (0xF0000...0xFFFFD).contains(v) || (0x100000...0x10FFFD).contains(v)
            return !isBMPPUA && !isSuppPUA
        }
        let collapsed = String(String.UnicodeScalarView(filteredScalars))
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(collapsed.prefix(240))
    }

    private static func parseTimestamp(_ raw: String) -> Date? {
        if let d = try? isoWithFraction.parse(raw) { return d }
        return try? isoPlain.parse(raw)
    }

    private static func extractUUIDFromFilename(_ url: URL) -> UUID? {
        let stem = url.deletingPathExtension().lastPathComponent
        if let underscore = stem.lastIndex(of: "_") {
            let candidate = String(stem[stem.index(after: underscore)...])
            if let uuid = UUID(uuidString: candidate) { return uuid }
        }
        return UUID(uuidString: stem)
    }

    private static func deterministicSessionID(for url: URL) -> UUID {
        let namespace = "com.fanyu.OpenPulse.PiAgentSession\0"
        let source = Data((namespace + url.standardizedFileURL.path).utf8)
        var bytes = Array(SHA256.hash(data: source).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private struct PiSessionEntry: Decodable {
        let type: String?
        let id: String?
        let timestamp: String?
        let cwd: String?
        let title: String?
        let model: String?
        let message: PiMessage?
    }

    private struct PiMessage: Decodable {
        let role: String?
        let provider: String?
        let model: String?
        let content: PiMessageContent?
        let usage: PiUsage?

        var textContent: String? {
            switch content {
            case .string(let s): return s
            case .blocks(let blocks): return blocks.compactMap(\.text).joined(separator: " ")
            case nil: return nil
            }
        }
    }

    private enum PiMessageContent: Decodable {
        case string(String)
        case blocks([PiContentBlock])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let s = try? container.decode(String.self) {
                self = .string(s)
            } else {
                self = .blocks((try? container.decode([PiContentBlock].self)) ?? [])
            }
        }
    }

    private struct PiContentBlock: Decodable {
        let text: String?
    }

    private struct PiUsage: Decodable {
        let input: Int?
        let output: Int?
        let cacheRead: Int?
        let cacheWrite: Int?
    }
}

/// Manages session hiding, source-file resolution, resume commands, and safe local file cleanup (via Trash / Codex archive).
enum SessionManagementService {
    static let hiddenSessionIDsKey = "activity.hiddenSessionIDs"

    // MARK: - Hidden Session Registry

    static func hiddenSessionIDs(defaults: UserDefaults = .standard) -> Set<UUID> {
        let raw = defaults.stringArray(forKey: hiddenSessionIDsKey) ?? []
        return Set(raw.compactMap { UUID(uuidString: $0) })
    }

    static func hiddenSessionCount(defaults: UserDefaults = .standard) -> Int {
        hiddenSessionIDs(defaults: defaults).count
    }

    static func hideSessionIDs(_ ids: [UUID], defaults: UserDefaults = .standard) {
        guard !ids.isEmpty else { return }
        var set = hiddenSessionIDs(defaults: defaults)
        set.formUnion(ids)
        defaults.set(set.map(\.uuidString).sorted(), forKey: hiddenSessionIDsKey)
    }

    static func unhideAllSessions(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: hiddenSessionIDsKey)
    }

    // MARK: - Resume Commands & Source Locators

    static func resumeCommand(for tool: Tool, sessionID: UUID, projectPath: String) -> String? {
        let idString = sessionID.uuidString.lowercased()
        switch tool {
        case .claudeCode:
            if !projectPath.isEmpty {
                let escaped = projectPath.replacingOccurrences(of: "'", with: "'\\''")
                return "cd '\(escaped)' && claude --resume \(idString)"
            }
            return "claude --resume \(idString)"
        case .codex:
            if !projectPath.isEmpty {
                let escaped = projectPath.replacingOccurrences(of: "'", with: "'\\''")
                return "cd '\(escaped)' && codex resume \(idString)"
            }
            return "codex resume \(idString)"
        case .antigravity, .copilot:
            return nil
        }
    }

    static func locateSourceURL(
        for tool: Tool,
        sessionID: UUID,
        paths: SessionManagementPaths = .standard
    ) -> URL? {
        switch tool {
        case .claudeCode:
            if let primary = locateClaudeSourceURLs(sessionID: sessionID, paths: paths).first {
                return primary
            }
            return PiAgentSessionScanner.locateSessionURLs(sessionID: sessionID, roots: paths.piAgentSessionRoots).first
        case .codex:
            for dir in paths.allCodexDirs {
                if let url = locateCodexRolloutURLs(sessionID: sessionID, codexDir: dir).first {
                    return url
                }
            }
            return PiAgentSessionScanner.locateSessionURLs(sessionID: sessionID, roots: paths.piAgentSessionRoots).first
        case .antigravity:
            if let dir = locateAntigravityBrainDir(sessionID: sessionID, paths: paths) {
                return dir
            }
            return PiAgentSessionScanner.locateSessionURLs(sessionID: sessionID, roots: paths.piAgentSessionRoots).first
        case .copilot:
            return PiAgentSessionScanner.locateSessionURLs(sessionID: sessionID, roots: paths.piAgentSessionRoots).first
        }
    }

    // MARK: - Deletion Pipeline

    static func deleteSessions(
        _ targets: [SessionDeletionTarget],
        mode: SessionDeletionMode = .trashLocalFiles,
        modelContainer: ModelContainer,
        paths: SessionManagementPaths = .standard,
        defaultsSuiteName: String? = nil,
        trashItem: @escaping @Sendable (URL) throws -> Void = { url in
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        }
    ) async throws -> SessionDeletionReport {
        guard !targets.isEmpty else {
            return SessionDeletionReport(
                mode: mode,
                deletedRecords: 0,
                trashedURLs: [],
                archivedCodexThreads: 0,
                hiddenIDsAdded: 0,
                warnings: []
            )
        }

        let (report, idsToHide) = try await Task.detached(priority: .userInitiated) { () throws -> (SessionDeletionReport, [UUID]) in
            var trashedURLs: [URL] = []
            var archivedCodexThreads = 0
            var idsToHide: [UUID] = []
            var warnings: [String] = []

            switch mode {
            case .hideInOpenPulse:
                idsToHide = targets.map(\.id)

            case .trashLocalFiles:
                var codexTargets: [SessionDeletionTarget] = []

                for target in targets {
                    switch target.tool {
                    case .claudeCode:
                        var urls = locateClaudeSourceURLs(sessionID: target.id, paths: paths)
                        urls.append(contentsOf: locateClaudeDesktopSessionURLs(sessionID: target.id, paths: paths))
                        urls.append(contentsOf: PiAgentSessionScanner.locateSessionURLs(sessionID: target.id, roots: paths.piAgentSessionRoots))
                        for url in deduplicatedURLs(urls) {
                            do {
                                try trashItem(url)
                                trashedURLs.append(url)
                            } catch {
                                warnings.append("\(url.lastPathComponent): \(error.localizedDescription)")
                                idsToHide.append(target.id)
                            }
                        }

                    case .antigravity:
                        var urls: [URL] = []
                        if let dir = locateAntigravityBrainDir(sessionID: target.id, paths: paths) {
                            urls.append(dir)
                        }
                        urls.append(contentsOf: PiAgentSessionScanner.locateSessionURLs(sessionID: target.id, roots: paths.piAgentSessionRoots))
                        for url in deduplicatedURLs(urls) {
                            do {
                                try trashItem(url)
                                trashedURLs.append(url)
                            } catch {
                                warnings.append("\(url.lastPathComponent): \(error.localizedDescription)")
                                idsToHide.append(target.id)
                            }
                        }

                    case .codex:
                        codexTargets.append(target)

                    case .copilot:
                        let urls = PiAgentSessionScanner.locateSessionURLs(sessionID: target.id, roots: paths.piAgentSessionRoots)
                        if urls.isEmpty {
                            idsToHide.append(target.id)
                        } else {
                            for url in deduplicatedURLs(urls) {
                                do {
                                    try trashItem(url)
                                    trashedURLs.append(url)
                                } catch {
                                    warnings.append("\(url.lastPathComponent): \(error.localizedDescription)")
                                    idsToHide.append(target.id)
                                }
                            }
                        }
                    }
                }

                if !codexTargets.isEmpty {
                    let codexResult = cleanCodexSessions(
                        codexTargets,
                        paths: paths,
                        trashItem: trashItem
                    )
                    trashedURLs.append(contentsOf: codexResult.trashedURLs)
                    archivedCodexThreads += codexResult.archivedCount
                    idsToHide.append(contentsOf: codexResult.fallbackHideIDs)
                    warnings.append(contentsOf: codexResult.warnings)
                }
            }

            let targetIDs = targets.map(\.id)
            let context = ModelContext(modelContainer)
            context.autosaveEnabled = false
            let descriptor = FetchDescriptor<SessionRecord>(
                predicate: #Predicate { targetIDs.contains($0.id) }
            )
            let records = try context.fetch(descriptor)
            for record in records {
                context.delete(record)
            }
            if !records.isEmpty {
                try context.save()
            }

            let report = SessionDeletionReport(
                mode: mode,
                deletedRecords: records.count,
                trashedURLs: trashedURLs,
                archivedCodexThreads: archivedCodexThreads,
                hiddenIDsAdded: Set(idsToHide).count,
                warnings: warnings
            )
            return (report, idsToHide)
        }.value

        if !idsToHide.isEmpty {
            let defaults = defaultsSuiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
            hideSessionIDs(idsToHide, defaults: defaults)
        }
        return report
    }

    // MARK: - Tool-Specific Source Resolution

    private static func deduplicatedURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private static func locateClaudeSourceURLs(sessionID: UUID, paths: SessionManagementPaths) -> [URL] {
        let fm = FileManager.default
        let needle = sessionID.uuidString.lowercased()
        let searchRoots = paths.allClaudeProjectDirs.filter {
            fm.fileExists(atPath: $0.path)
        }
        var found: [URL] = []

        // Fast path: filename stem matches session UUID (<uuid>.jsonl + optional sibling <uuid>/ dir)
        for root in searchRoots {
            guard let projectDirs = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey]
            ) else { continue }

            for projectDir in projectDirs {
                guard (try? projectDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                      let entries = try? fm.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: nil) else {
                    continue
                }
                for entry in entries {
                    let stem = entry.deletingPathExtension().lastPathComponent.lowercased()
                    if entry.pathExtension.lowercased() == "jsonl", stem == needle {
                        found.append(entry)
                    } else if entry.lastPathComponent.lowercased() == needle {
                        found.append(entry)
                    }
                }
            }
        }
        if !found.isEmpty { return found }

        // Fallback: check JSONL files whose embedded sessionId matches (e.g. non-UUID filenames)
        let sessionNeedle = Data(needle.utf8)
        for root in searchRoots {
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "jsonl" {
                var matched = false
                JSONLReader.forEachLine(of: url, until: { line, lineIndex in
                    if lineIndex > 40 { return true }
                    if let text = String(data: line, encoding: .utf8),
                       text.lowercased().contains(String(decoding: sessionNeedle, as: UTF8.self)),
                       text.contains("\"sessionId\"") {
                        matched = true
                        return true
                    }
                    return false
                })
                if matched {
                    found.append(url)
                    break
                }
            }
        }
        return found
    }

    private static func locateClaudeDesktopSessionURLs(sessionID: UUID, paths: SessionManagementPaths) -> [URL] {
        guard let root = paths.claudeDesktopSessionsDir,
              FileManager.default.fileExists(atPath: root.path),
              let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        let needle = sessionID.uuidString.lowercased()
        var matches: [URL] = []

        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "json",
                  url.lastPathComponent.hasPrefix("local_"),
                  !url.path.contains("/deleted_") else { continue }
            if url.lastPathComponent.lowercased().contains(needle) {
                matches.append(url)
                continue
            }
            if let data = try? Data(contentsOf: url),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let cliID = obj["cliSessionId"] as? String,
               cliID.lowercased() == needle {
                matches.append(url)
            }
        }
        return matches
    }

    private static func locateCodexRolloutURLs(sessionID: UUID, codexDir: URL) -> [URL] {
        let fm = FileManager.default
        let suffix = "-\(sessionID.uuidString.lowercased()).jsonl"
        let exact = "\(sessionID.uuidString.lowercased()).jsonl"
        let roots = [
            codexDir.appending(path: "sessions"),
            codexDir.appending(path: "archived_sessions"),
        ].filter { fm.fileExists(atPath: $0.path) }

        var matches: [URL] = []
        for root in roots {
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "jsonl" {
                let name = url.lastPathComponent.lowercased()
                if name.hasSuffix(suffix) || name == exact {
                    matches.append(url)
                }
            }
        }
        return matches
    }

    private static func locateAntigravityBrainDir(sessionID: UUID, paths: SessionManagementPaths) -> URL? {
        let fm = FileManager.default
        let brainRoots = paths.allAntigravityBrainDirs
        let targetLower = sessionID.uuidString.lowercased()

        for brainDir in brainRoots {
            guard let subdirs = try? fm.contentsOfDirectory(
                at: brainDir,
                includingPropertiesForKeys: [.isDirectoryKey]
            ) else { continue }
            for dir in subdirs {
                guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                if dir.lastPathComponent.lowercased() == targetLower {
                    return dir
                }
            }
        }
        for brainDir in brainRoots {
            guard let subdirs = try? fm.contentsOfDirectory(
                at: brainDir,
                includingPropertiesForKeys: [.isDirectoryKey]
            ) else { continue }
            for dir in subdirs {
                guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                if AntigravityParser.sessionID(for: dir) == sessionID {
                    return dir
                }
            }
        }
        return nil
    }

    private static func cleanCodexSessions(
        _ targets: [SessionDeletionTarget],
        paths: SessionManagementPaths,
        trashItem: (URL) throws -> Void
    ) -> (trashedURLs: [URL], archivedCount: Int, fallbackHideIDs: [UUID], warnings: [String]) {
        var trashedURLs: [URL] = []
        var archivedCount = 0
        var fallbackHideIDs: [UUID] = []
        var warnings: [String] = []

        // 1. Trash rollout JSONL files across all Codex homes + Pi/OMP sessions
        for target in targets {
            var candidateURLs: [URL] = []
            for codexDir in paths.allCodexDirs {
                candidateURLs.append(contentsOf: locateCodexRolloutURLs(sessionID: target.id, codexDir: codexDir))
            }
            candidateURLs.append(contentsOf: PiAgentSessionScanner.locateSessionURLs(sessionID: target.id, roots: paths.piAgentSessionRoots))
            for file in deduplicatedURLs(candidateURLs) {
                do {
                    try trashItem(file)
                    trashedURLs.append(file)
                } catch {
                    warnings.append("\(file.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }

        // 2. Mark threads archived = 1 in each Codex state_5.sqlite (non-destructive to Codex schema)
        for codexDir in paths.allCodexDirs {
            let dbURL = codexDir.appending(path: "state_5.sqlite")
            guard FileManager.default.fileExists(atPath: dbURL.path) else { continue }

            do {
                let db = try Connection(dbURL.path)
                db.busyTimeout = 3.0
                let hasArchived = (try db.scalar("SELECT COUNT(*) FROM pragma_table_info('threads') WHERE name = 'archived'") as? Int64) == 1
                if hasArchived {
                    for target in targets {
                        let statement = try db.prepare("UPDATE threads SET archived = 1 WHERE lower(id) = lower(?)")
                        try statement.run(target.id.uuidString)
                        if db.changes > 0 {
                            archivedCount += 1
                        }
                    }
                } else {
                    fallbackHideIDs.append(contentsOf: targets.map(\.id))
                }
            } catch {
                warnings.append(String(localized: "Codex 数据库正被占用，已在 OpenPulse 中隐藏所选会话：\(error.localizedDescription)"))
                fallbackHideIDs.append(contentsOf: targets.map(\.id))
            }
        }

        return (trashedURLs, archivedCount, fallbackHideIDs, warnings)
    }
}
