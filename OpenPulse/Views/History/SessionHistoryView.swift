import SwiftUI
import SwiftData
import Observation
import AppKit
import os

struct SessionHistoryView: View {
    @Environment(AppStore.self) private var appStore
    @State private var history = ActivityHistoryModel()

    var body: some View {
        ActivityHistoryBrowser(history: history)
            .navigationTitle("活动记录")
            .background(Color(nsColor: .windowBackgroundColor))
            .background {
                UsageSnapshotRefreshObserver {
                    history.reload(container: appStore.modelContainer)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let message = history.reloadError {
                    UsageSnapshotErrorBanner(message: message) {
                        history.reload(container: appStore.modelContainer)
                    }
                }
            }
            .onDisappear { history.cancel() }
    }
}

// MARK: - Activity Filter & Sort Enums

enum ActivityTimeFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case today
    case last7Days
    case last30Days

    var id: String { rawValue }

    var localizationKey: String.LocalizationValue {
        switch self {
        case .all:        "全部时间"
        case .today:      "今天"
        case .last7Days:  "近 7 天"
        case .last30Days: "近 30 天"
        }
    }

    var localizedTitle: LocalizedStringKey {
        switch self {
        case .all:        "全部时间"
        case .today:      "今天"
        case .last7Days:  "近 7 天"
        case .last30Days: "近 30 天"
        }
    }

    func cutoffDate(relativeTo now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let dayStart = calendar.startOfDay(for: now)
        switch self {
        case .all:
            return nil
        case .today:
            return dayStart
        case .last7Days:
            return calendar.date(byAdding: .day, value: -6, to: dayStart)
        case .last30Days:
            return calendar.date(byAdding: .day, value: -29, to: dayStart)
        }
    }
}

enum ActivitySortOrder: String, CaseIterable, Identifiable, Sendable {
    case newest
    case oldest
    case mostTokens
    case longestDuration

    var id: String { rawValue }

    var localizationKey: String.LocalizationValue {
        switch self {
        case .newest:          "最新优先"
        case .oldest:          "最早优先"
        case .mostTokens:      "Token 最多"
        case .longestDuration: "耗时最长"
        }
    }

    var localizedTitle: LocalizedStringKey {
        switch self {
        case .newest:          "最新优先"
        case .oldest:          "最早优先"
        case .mostTokens:      "Token 最多"
        case .longestDuration: "耗时最长"
        }
    }

    var supportsDateGrouping: Bool {
        self == .newest || self == .oldest
    }
}

// MARK: - Project Option Model

struct ActivityProjectOption: Identifiable, Hashable, Sendable {
    let path: String
    let name: String
    let parentHint: String?
    let sessionCount: Int
    let totalTokens: Int
    let isTemporary: Bool

    var id: String { path }

    var displayLabel: String {
        if let parentHint, !parentHint.isEmpty {
            return "\(parentHint)/\(name)"
        }
        return name
    }
}

// MARK: - Immutable Snapshot Models

struct ActivitySessionSnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let tool: Tool
    let startedAt: Date
    let endedAt: Date?
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let task: String
    let model: String
    let projectPath: String
    let branch: String?

    init(
        id: UUID = UUID(),
        tool: Tool,
        startedAt: Date,
        endedAt: Date? = nil,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        task: String = "",
        model: String = "",
        projectPath: String = "",
        branch: String? = nil
    ) {
        self.id = id
        self.tool = tool
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.task = task
        self.model = model
        self.projectPath = projectPath
        self.branch = branch
    }

    init(_ record: SessionRecord) {
        self.init(
            id: record.id,
            tool: record.tool,
            startedAt: record.startedAt,
            endedAt: record.endedAt,
            inputTokens: record.inputTokens,
            outputTokens: record.outputTokens,
            cacheReadTokens: record.cacheReadTokens,
            cacheWriteTokens: record.cacheWriteTokens,
            task: record.taskDescription,
            model: record.model,
            projectPath: record.cwd,
            branch: record.gitBranch
        )
    }

    var totalTokens: Int { inputTokens + outputTokens }
    var title: String { task.isEmpty ? String(localized: "Untitled session") : task }

    /// Cleaned single-paragraph title suitable for list display (handles legacy persisted records too).
    var displayTitle: String {
        guard !task.isEmpty else { return String(localized: "未命名会话") }
        let stripped = CodexParser.cleanCodexTitle(
            AntigravityParser.extractUserPromptTitle(from: task)
        )
        let cleaned = PiAgentSessionScanner.cleanDisplayTitle(stripped)
        return cleaned.isEmpty ? String(localized: "未命名会话") : cleaned
    }

    var projectName: String {
        guard !projectPath.isEmpty else { return "" }
        let url = URL(fileURLWithPath: projectPath)
        let name = url.lastPathComponent
        return name == "/" ? projectPath : name
    }

    var projectParentName: String? {
        guard !projectPath.isEmpty else { return nil }
        let parent = URL(fileURLWithPath: projectPath).deletingLastPathComponent().lastPathComponent
        let homeName = URL.homeDirectory.lastPathComponent
        guard !parent.isEmpty,
              parent != "/",
              parent != "Users",
              parent != homeName else { return nil }
        return parent
    }

    var abbreviatedProjectPath: String {
        guard !projectPath.isEmpty else { return "" }
        let home = URL.homeDirectory.path
        if projectPath == home { return "~" }
        if projectPath.hasPrefix(home + "/") {
            return "~" + projectPath.dropFirst(home.count)
        }
        return projectPath
    }

    var isTemporaryProject: Bool {
        guard !projectPath.isEmpty else { return false }
        return AntigravityParser.isInternalOrTempWorkspacePath(projectPath)
    }

    var compactModelName: String {
        guard !model.isEmpty else { return "" }
        if let slash = model.lastIndex(of: "/") {
            return String(model[model.index(after: slash)...])
        }
        return model
    }

    var durationSeconds: TimeInterval? {
        guard let endedAt else { return nil }
        let interval = endedAt.timeIntervalSince(startedAt)
        return interval > 0 ? interval : nil
    }

    var compactDuration: String? {
        guard let durationSeconds else { return nil }
        let totalMinutes = Int(durationSeconds / 60)
        if totalMinutes < 1 {
            return "<1m"
        }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(minutes)m"
    }

    var formattedDuration: String? {
        guard let durationSeconds else { return nil }
        let totalMinutes = Int(durationSeconds / 60)
        if totalMinutes < 1 {
            return String(localized: "< 1 分钟")
        }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return minutes > 0
                ? String(localized: "\(hours) 小时 \(minutes) 分")
                : String(localized: "\(hours) 小时")
        }
        return String(localized: "\(minutes) 分钟")
    }

    var deletionTarget: SessionDeletionTarget {
        SessionDeletionTarget(id: id, tool: tool, title: displayTitle, projectPath: projectPath)
    }

    func matches(_ search: String) -> Bool {
        search.isEmpty
            || task.localizedStandardContains(search)
            || projectPath.localizedStandardContains(search)
            || (branch?.localizedStandardContains(search) ?? false)
            || model.localizedStandardContains(search)
            || id.uuidString.localizedStandardContains(search)
    }
}

struct ActivityToolSummary: Equatable, Sendable {
    var count = 0
    var tokens = 0
    var favoriteProject: String?
    var averageTokens: Int { count > 0 ? tokens / count : 0 }
}

// Immutable reference containers keep 50k-row arrays out of SwiftUI's deep
// value comparisons. Every row crossing the model actor boundary is a value.
final class ActivityHistorySnapshot: Sendable {
    let sessions: [ActivitySessionSnapshot]
    let sessionsByID: [UUID: ActivitySessionSnapshot]
    let sessionsByTool: [Tool: [ActivitySessionSnapshot]]
    let summaries: [Tool: ActivityToolSummary]
    let allSummary: ActivityToolSummary
    let allProjects: [ActivityProjectOption]
    let projectsByTool: [Tool: [ActivityProjectOption]]

    static let empty = ActivityHistorySnapshot()

    private init() {
        sessions = []
        sessionsByID = [:]
        sessionsByTool = [:]
        summaries = [:]
        allSummary = ActivityToolSummary()
        allProjects = []
        projectsByTool = [:]
    }

    init(sessions: [ActivitySessionSnapshot]) throws {
        let interval = ActivityHistoryPerformance.signposter.beginInterval("ActivityHistoryAggregate", id: ActivityHistoryPerformance.signposter.makeSignpostID())
        defer { ActivityHistoryPerformance.signposter.endInterval("ActivityHistoryAggregate", interval) }
        var indexed: [UUID: ActivitySessionSnapshot] = [:]
        indexed.reserveCapacity(sessions.count)
        var byTool: [Tool: [ActivitySessionSnapshot]] = [:]
        var toolSummaries: [Tool: ActivityToolSummary] = [:]
        var projectTokens: [Tool: [String: Int]] = [:]
        var projectCounts: [Tool: [String: Int]] = [:]
        var allProjectTokens: [String: Int] = [:]
        var allProjectCounts: [String: Int] = [:]
        var total = ActivityToolSummary()

        for (index, session) in sessions.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            indexed[session.id] = session
            byTool[session.tool, default: []].append(session)
            toolSummaries[session.tool, default: ActivityToolSummary()].count += 1
            toolSummaries[session.tool, default: ActivityToolSummary()].tokens += session.totalTokens
            total.count += 1
            total.tokens += session.totalTokens
            if !session.projectPath.isEmpty {
                projectTokens[session.tool, default: [:]][session.projectPath, default: 0] += session.totalTokens
                projectCounts[session.tool, default: [:]][session.projectPath, default: 0] += 1
                allProjectTokens[session.projectPath, default: 0] += session.totalTokens
                allProjectCounts[session.projectPath, default: 0] += 1
            }
        }

        var toolProjectOptions: [Tool: [ActivityProjectOption]] = [:]
        for tool in toolSummaries.keys {
            toolSummaries[tool]?.favoriteProject = Self.favoriteProject(in: projectTokens[tool] ?? [:])
            toolProjectOptions[tool] = Self.buildProjectOptions(
                counts: projectCounts[tool] ?? [:],
                tokens: projectTokens[tool] ?? [:]
            )
        }
        total.favoriteProject = Self.favoriteProject(in: allProjectTokens)

        self.sessions = sessions
        sessionsByID = indexed
        sessionsByTool = byTool
        summaries = toolSummaries
        allSummary = total
        allProjects = Self.buildProjectOptions(counts: allProjectCounts, tokens: allProjectTokens)
        projectsByTool = toolProjectOptions
    }

    func projects(for tool: Tool?) -> [ActivityProjectOption] {
        tool.map { projectsByTool[$0] ?? [] } ?? allProjects
    }

    func filtered(
        tool: Tool?,
        search: String,
        projectPath: String? = nil,
        timeFilter: ActivityTimeFilter = .all,
        sortOrder: ActivitySortOrder = .newest,
        referenceDate: Date = Date()
    ) throws -> ActivityHistoryFilterResult {
        let interval = ActivityHistoryPerformance.signposter.beginInterval("ActivityHistoryFilter", id: ActivityHistoryPerformance.signposter.makeSignpostID())
        defer { ActivityHistoryPerformance.signposter.endInterval("ActivityHistoryFilter", interval) }
        let candidates = tool.map { sessionsByTool[$0] ?? [] } ?? sessions
        let cutoff = timeFilter.cutoffDate(relativeTo: referenceDate)

        var matches: [ActivitySessionSnapshot]
        if search.isEmpty && cutoff == nil && projectPath == nil {
            matches = candidates
        } else {
            matches = []
            matches.reserveCapacity(min(candidates.count, 1024))
            for (index, session) in candidates.enumerated() {
                if index.isMultiple(of: 256) { try Task.checkCancellation() }
                if let projectPath, session.projectPath != projectPath { continue }
                if let cutoff, session.startedAt < cutoff { continue }
                if !search.isEmpty && !session.matches(search) { continue }
                matches.append(session)
            }
        }

        switch sortOrder {
        case .newest:
            break // reader already orders startedAt descending
        case .oldest:
            matches.sort { $0.startedAt < $1.startedAt }
        case .mostTokens:
            matches.sort { lhs, rhs in
                lhs.totalTokens == rhs.totalTokens ? lhs.startedAt > rhs.startedAt : lhs.totalTokens > rhs.totalTokens
            }
        case .longestDuration:
            matches.sort { lhs, rhs in
                let lDur = lhs.durationSeconds ?? 0
                let rDur = rhs.durationSeconds ?? 0
                return lDur == rDur ? lhs.startedAt > rhs.startedAt : lDur > rDur
            }
        }

        return try ActivityHistoryFilterResult(sessions: matches)
    }

    private static func favoriteProject(in totals: [String: Int]) -> String? {
        let realTotals = totals.filter { !AntigravityParser.isInternalOrTempWorkspacePath($0.key) }
        let pool = realTotals.isEmpty ? totals : realTotals
        return pool.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        }?.key
    }

    private static func buildProjectOptions(
        counts: [String: Int],
        tokens: [String: Int]
    ) -> [ActivityProjectOption] {
        guard !counts.isEmpty else { return [] }
        var nameFrequency: [String: Int] = [:]
        for path in counts.keys {
            let name = URL(fileURLWithPath: path).lastPathComponent
            nameFrequency[name, default: 0] += 1
        }

        let homeName = URL.homeDirectory.lastPathComponent
        return counts.map { path, count in
            let url = URL(fileURLWithPath: path)
            let name = url.lastPathComponent == "/" ? path : url.lastPathComponent
            let parent = url.deletingLastPathComponent().lastPathComponent
            let needsParent = (nameFrequency[name] ?? 0) > 1
                && !parent.isEmpty
                && parent != "/"
                && parent != "Users"
                && parent != homeName
            return ActivityProjectOption(
                path: path,
                name: name,
                parentHint: needsParent ? parent : nil,
                sessionCount: count,
                totalTokens: tokens[path] ?? 0,
                isTemporary: AntigravityParser.isInternalOrTempWorkspacePath(path)
            )
        }.sorted { lhs, rhs in
            if lhs.isTemporary != rhs.isTemporary { return !lhs.isTemporary }
            if lhs.sessionCount != rhs.sessionCount { return lhs.sessionCount > rhs.sessionCount }
            if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens > rhs.totalTokens }
            return lhs.path < rhs.path
        }
    }
}

final class ActivityHistoryFilterResult: Sendable {
    let sessions: [ActivitySessionSnapshot]
    let visibleIDs: Set<UUID>
    let positionsByID: [UUID: Int]
    static let empty = ActivityHistoryFilterResult()

    private init() {
        sessions = []
        visibleIDs = []
        positionsByID = [:]
    }

    init(sessions: [ActivitySessionSnapshot]) throws {
        var ids = Set<UUID>()
        ids.reserveCapacity(sessions.count)
        var positions: [UUID: Int] = [:]
        positions.reserveCapacity(sessions.count)
        for (index, session) in sessions.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            ids.insert(session.id)
            positions[session.id] = index
        }
        self.sessions = sessions
        visibleIDs = ids
        positionsByID = positions
    }
}

struct ActivityHistoryFilterIdentity: Equatable, Sendable {
    let tool: Tool?
    let search: String
    let projectPath: String?
    let timeFilter: ActivityTimeFilter
    let sortOrder: ActivitySortOrder

    init(
        tool: Tool?,
        search: String,
        projectPath: String? = nil,
        timeFilter: ActivityTimeFilter = .all,
        sortOrder: ActivitySortOrder = .newest
    ) {
        self.tool = tool
        self.search = search
        self.projectPath = projectPath
        self.timeFilter = timeFilter
        self.sortOrder = sortOrder
    }
}

// MARK: - Day Grouping Helper

struct ActivitySessionDayGroup: Identifiable {
    let dayStart: Date
    let title: String
    let totalTokens: Int
    let sessions: [ActivitySessionSnapshot]

    var id: Date { dayStart }

    static func group(
        _ sessions: ArraySlice<ActivitySessionSnapshot>,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> [ActivitySessionDayGroup] {
        guard !sessions.isEmpty else { return [] }
        var groups: [ActivitySessionDayGroup] = []
        var currentDay: Date?
        var bucket: [ActivitySessionSnapshot] = []
        var bucketTokens = 0

        func flush() {
            guard let day = currentDay, !bucket.isEmpty else { return }
            groups.append(ActivitySessionDayGroup(
                dayStart: day,
                title: formattedDayHeader(day, calendar: calendar, now: now),
                totalTokens: bucketTokens,
                sessions: bucket
            ))
            bucket.removeAll(keepingCapacity: true)
            bucketTokens = 0
        }

        for session in sessions {
            let day = calendar.startOfDay(for: session.startedAt)
            if day != currentDay {
                flush()
                currentDay = day
            }
            bucket.append(session)
            bucketTokens += session.totalTokens
        }
        flush()
        return groups
    }

    static func formattedDayHeader(_ dayStart: Date, calendar: Calendar = .current, now: Date = Date()) -> String {
        let dateText = dayStart.formatted(.dateTime.month().day())
        if calendar.isDate(dayStart, inSameDayAs: now) {
            return String(localized: "今天 · \(dateText)")
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)),
           calendar.isDate(dayStart, inSameDayAs: yesterday) {
            return String(localized: "昨天 · \(dateText)")
        }
        if calendar.component(.year, from: dayStart) == calendar.component(.year, from: now) {
            return dayStart.formatted(.dateTime.month().day().weekday(.abbreviated))
        }
        return dayStart.formatted(.dateTime.year().month().day())
    }
}

// Bound the row IDs SwiftUI must diff, while keeping the complete result and
// selection available. Advancing only the current boundary rejects repeated
// callbacks from a footer that has already moved.
struct ActivitySessionRenderWindow: Equatable {
    static let batchSize = 200
    private var loadedCount = Self.batchSize

    func visibleCount(total: Int) -> Int {
        min(max(0, total), loadedCount)
    }

    mutating func update(total: Int, selectedIndex: Int?, reset: Bool) {
        if reset { loadedCount = Self.batchSize }
        if let selectedIndex, selectedIndex >= 0, selectedIndex < total {
            let selectedBatch = ((selectedIndex / Self.batchSize) + 1) * Self.batchSize
            loadedCount = max(loadedCount, selectedBatch)
        }
        loadedCount = min(max(0, total), max(Self.batchSize, loadedCount))
    }

    @discardableResult
    mutating func revealNext(total: Int, boundary: Int) -> Bool {
        guard boundary == visibleCount(total: total), boundary < total else { return false }
        loadedCount = min(total, boundary + Self.batchSize)
        return true
    }

    mutating func revealAll(total: Int) {
        loadedCount = max(0, total)
    }
}

@ModelActor
actor ActivityHistorySnapshotReader {
    func read() throws -> ActivityHistorySnapshot {
        let interval = ActivityHistoryPerformance.signposter.beginInterval("ActivityHistoryRead", id: ActivityHistoryPerformance.signposter.makeSignpostID())
        defer { ActivityHistoryPerformance.signposter.endInterval("ActivityHistoryRead", interval) }
        try Task.checkCancellation()
        let records = try fetchRecords()
        let materializeInterval = ActivityHistoryPerformance.signposter.beginInterval("ActivityHistoryMaterialize", id: ActivityHistoryPerformance.signposter.makeSignpostID())
        defer { ActivityHistoryPerformance.signposter.endInterval("ActivityHistoryMaterialize", materializeInterval) }
        var snapshots: [ActivitySessionSnapshot] = []
        snapshots.reserveCapacity(records.count)
        for (index, record) in records.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            snapshots.append(ActivitySessionSnapshot(record))
        }
        return try ActivityHistorySnapshot(sessions: snapshots)
    }

    private func fetchRecords() throws -> [SessionRecord] {
        let interval = ActivityHistoryPerformance.signposter.beginInterval("ActivityHistoryFetch", id: ActivityHistoryPerformance.signposter.makeSignpostID())
        defer { ActivityHistoryPerformance.signposter.endInterval("ActivityHistoryFetch", interval) }
        return try modelContext.fetch(FetchDescriptor<SessionRecord>(
            predicate: #Predicate {
                $0.toolRaw == "codex" || $0.toolRaw == "claude" || $0.toolRaw == "antigravity"
            },
            sortBy: [SortDescriptor(\SessionRecord.startedAt, order: .reverse)]
        ))
    }
}

private enum ActivityHistoryPerformance {
    static let signposter = OSSignposter(subsystem: "com.fanyu.openpulse", category: "ActivityHistory")
}

@MainActor
@Observable
final class ActivityHistoryModel {
    private(set) var snapshot = ActivityHistorySnapshot.empty
    private(set) var filtered = ActivityHistoryFilterResult.empty
    private(set) var snapshotRevision: UInt64 = 0
    private(set) var filterRevision: UInt64 = 0
    private(set) var appliedFilter = ActivityHistoryFilterIdentity(tool: nil, search: "")
    private(set) var isLoading = false
    private(set) var isFiltering = false
    private(set) var reloadError: String?
    @ObservationIgnored private var reloadGeneration: UInt64 = 0
    @ObservationIgnored private var filterGeneration: UInt64 = 0
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var filterTask: Task<Void, Never>?
    @ObservationIgnored private var latestFilterTool: Tool?
    @ObservationIgnored private var latestFilterSearch = ""
    @ObservationIgnored private var latestProjectPath: String?
    @ObservationIgnored private var latestTimeFilter: ActivityTimeFilter = .all
    @ObservationIgnored private var latestSortOrder: ActivitySortOrder = .newest

    @discardableResult
    func reload(container: ModelContainer) -> Task<Void, Never> {
        reload {
            let reader = ActivityHistorySnapshotReader(modelContainer: container)
            return try await reader.read()
        }
    }

    @discardableResult
    func reload(using load: @escaping @Sendable () async throws -> ActivityHistorySnapshot) -> Task<Void, Never> {
        reloadTask?.cancel()
        reloadGeneration &+= 1
        let generation = reloadGeneration
        isLoading = true
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let result = try await load()
            try Task.checkCancellation()
            return result
        }
        let completion = Task { [weak self] in
            do {
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard let self, !Task.isCancelled, generation == self.reloadGeneration else { return }
                let interval = ActivityHistoryPerformance.signposter.beginInterval("ActivityHistoryApplySnapshot", id: ActivityHistoryPerformance.signposter.makeSignpostID())
                defer { ActivityHistoryPerformance.signposter.endInterval("ActivityHistoryApplySnapshot", interval) }
                self.snapshot = result
                self.snapshotRevision &+= 1
                if let path = self.latestProjectPath,
                   !result.projects(for: self.latestFilterTool).contains(where: { $0.path == path }) {
                    self.latestProjectPath = nil
                }
                self.isLoading = false
                self.reloadError = nil
                self.filter(
                    tool: self.latestFilterTool,
                    search: self.latestFilterSearch,
                    projectPath: self.latestProjectPath,
                    timeFilter: self.latestTimeFilter,
                    sortOrder: self.latestSortOrder
                )
            } catch {
                guard let self, !Task.isCancelled, generation == self.reloadGeneration else { return }
                self.isLoading = false
                if !(error is CancellationError) { self.reloadError = error.localizedDescription }
            }
        }
        reloadTask = completion
        return completion
    }

    @discardableResult
    func filter(
        tool: Tool?,
        search: String,
        projectPath: String? = nil,
        timeFilter: ActivityTimeFilter = .all,
        sortOrder: ActivitySortOrder = .newest
    ) -> Task<Void, Never> {
        runFilter(tool: tool, search: search, projectPath: projectPath, timeFilter: timeFilter, sortOrder: sortOrder) { snapshot, tool, search in
            try snapshot.filtered(
                tool: tool,
                search: search,
                projectPath: projectPath,
                timeFilter: timeFilter,
                sortOrder: sortOrder
            )
        }
    }

    @discardableResult
    func filter(
        tool: Tool?,
        search: String,
        using operation: @escaping @Sendable (ActivityHistorySnapshot, Tool?, String) async throws -> ActivityHistoryFilterResult
    ) -> Task<Void, Never> {
        runFilter(
            tool: tool,
            search: search,
            projectPath: latestProjectPath,
            timeFilter: latestTimeFilter,
            sortOrder: latestSortOrder,
            operation: operation
        )
    }

    private func runFilter(
        tool: Tool?,
        search: String,
        projectPath: String?,
        timeFilter: ActivityTimeFilter,
        sortOrder: ActivitySortOrder,
        operation: @escaping @Sendable (ActivityHistorySnapshot, Tool?, String) async throws -> ActivityHistoryFilterResult
    ) -> Task<Void, Never> {
        latestFilterTool = tool
        latestFilterSearch = search
        latestProjectPath = projectPath
        latestTimeFilter = timeFilter
        latestSortOrder = sortOrder
        filterTask?.cancel()
        filterGeneration &+= 1
        let generation = filterGeneration
        let sourceRevision = snapshotRevision
        let source = snapshot
        isFiltering = true
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let result = try await operation(source, tool, search)
            try Task.checkCancellation()
            return result
        }
        let completion = Task { [weak self] in
            do {
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard let self, !Task.isCancelled,
                      generation == self.filterGeneration,
                      sourceRevision == self.snapshotRevision else { return }
                let interval = ActivityHistoryPerformance.signposter.beginInterval("ActivityHistoryApplyFilter", id: ActivityHistoryPerformance.signposter.makeSignpostID())
                defer { ActivityHistoryPerformance.signposter.endInterval("ActivityHistoryApplyFilter", interval) }
                self.filtered = result
                self.appliedFilter = ActivityHistoryFilterIdentity(
                    tool: tool,
                    search: search,
                    projectPath: projectPath,
                    timeFilter: timeFilter,
                    sortOrder: sortOrder
                )
                self.filterRevision &+= 1
                self.isFiltering = false
            } catch {
                guard let self, !Task.isCancelled, generation == self.filterGeneration else { return }
                self.isFiltering = false
            }
        }
        filterTask = completion
        return completion
    }

    func waitForPendingFilter() async {
        await filterTask?.value
    }

    func cancel() {
        reloadGeneration &+= 1
        filterGeneration &+= 1
        reloadTask?.cancel()
        filterTask?.cancel()
        isLoading = false
        isFiltering = false
    }
}

// MARK: - Activity Browser

private struct ActivityFeedbackMessage: Equatable {
    let text: String
    let isWarning: Bool
}

private struct ActivityHistoryBrowser: View {
    @Environment(AppStore.self) private var appStore
    @AppStorage("menubar.toolOrder") private var toolOrderRaw = Tool.defaultOrderRaw

    let history: ActivityHistoryModel
    @State private var selectedTool: Tool?
    @State private var selectedProjectPath: String?
    @State private var search = ""
    @State private var timeFilter: ActivityTimeFilter = .all
    @State private var sortOrder: ActivitySortOrder = .newest
    @State private var selectedID: UUID?
    @State private var detailIsPresented = false

    // Session Management state
    @State private var isManaging = false
    @State private var batchSelectedIDs: Set<UUID> = []
    @State private var pendingDeletionTargets: [SessionDeletionTarget] = []
    @State private var showingDeleteConfirm = false
    @State private var isDeleting = false
    @State private var isRestoringHidden = false
    @State private var hiddenCount = SessionManagementService.hiddenSessionCount()
    @State private var feedbackMessage: ActivityFeedbackMessage?
    @State private var supportsSplitDetail = true

    private var activityTools: [Tool] {
        Tool.orderedTools(from: toolOrderRaw).filter { $0 != .copilot }
    }

    private var summary: ActivityToolSummary {
        selectedTool.map { history.snapshot.summaries[$0] ?? ActivityToolSummary() } ?? history.snapshot.allSummary
    }

    private var availableProjects: [ActivityProjectOption] {
        history.snapshot.projects(for: selectedTool)
    }

    private var latestActiveDate: Date? {
        let list = selectedTool.map { history.snapshot.sessionsByTool[$0] ?? [] } ?? history.snapshot.sessions
        return list.first?.startedAt
    }

    private var deleteAlertTitle: String {
        pendingDeletionTargets.count == 1
            ? String(localized: "确认删除会话？")
            : String(localized: "确认删除 \(pendingDeletionTargets.count) 条会话？")
    }

    private var deleteAlertMessage: String {
        let hasCodex = pendingDeletionTargets.contains { $0.tool == .codex }
        let suffix = hasCodex
            ? String(localized: "本地会话文件将移至系统废纸篓，Codex 线程将标记为已归档，可在废纸篓找回。")
            : String(localized: "本地会话文件将移至系统废纸篓，可在系统废纸篓找回。")

        if let single = pendingDeletionTargets.first, pendingDeletionTargets.count == 1 {
            let preview = String(single.title.prefix(60))
            return String(localized: "将从本地删除“\(preview)”。\(suffix)")
        }
        return String(localized: "将从本地删除所选的 \(pendingDeletionTargets.count) 条会话。\(suffix)")
    }

    var body: some View {
        let selectedSession = isManaging ? nil : selectedID.flatMap { history.snapshot.sessionsByID[$0] }
        let content = ActivityBrowserContent(
            activityTools: activityTools,
            projects: availableProjects,
            sessionCount: summary.count,
            totalTokens: summary.tokens,
            averageTokens: summary.averageTokens,
            favoriteProject: summary.favoriteProject,
            latestActiveDate: latestActiveDate,
            selectedTool: $selectedTool,
            selectedProjectPath: $selectedProjectPath,
            search: $search,
            timeFilter: $timeFilter,
            sortOrder: $sortOrder,
            counts: history.snapshot.summaries.mapValues(\.count),
            totalCount: history.snapshot.allSummary.count,
            result: history.filtered,
            filterIdentity: history.appliedFilter,
            selection: $selectedID,
            hasSessions: !history.snapshot.sessions.isEmpty,
            isLoading: history.isLoading || history.isFiltering,
            isManaging: $isManaging,
            batchSelectedIDs: $batchSelectedIDs,
            hiddenCount: hiddenCount,
            isRestoringHidden: isRestoringHidden,
            feedbackMessage: feedbackMessage,
            onDismissFeedback: { feedbackMessage = nil },
            onRestoreHidden: { Task { await restoreHiddenSessions() } },
            onOpenDetail: { detailIsPresented = true },
            onSelectProjectFilter: { path in
                withAnimation(.smooth(duration: 0.18)) {
                    selectedProjectPath = (selectedProjectPath == path) ? nil : path
                }
            },
            onRequestDelete: { targets in requestDeletion(of: targets) },
            onRevealSource: { session in revealSessionSource(session) },
            onCopyResume: { session in copySessionResume(session) }
        )

        HSplitView {
            content.frame(minWidth: supportsSplitDetail && detailIsPresented && selectedSession != nil ? 540 : 0)
            if supportsSplitDetail, detailIsPresented, let session = selectedSession {
                ActivitySessionDetail(
                    session: session,
                    isFilteredByProject: selectedProjectPath == session.projectPath && !session.projectPath.isEmpty,
                    onClose: { detailIsPresented = false },
                    onToggleProjectFilter: {
                        guard !session.projectPath.isEmpty else { return }
                        selectedProjectPath = (selectedProjectPath == session.projectPath) ? nil : session.projectPath
                    },
                    onRequestDelete: { requestDeletion(of: [session.deletionTarget]) },
                    onRevealSource: { revealSessionSource(session) },
                    onCopyResume: { copySessionResume(session) }
                )
                .frame(minWidth: 310, idealWidth: 350, maxWidth: 400)
            }
        }
        .onGeometryChange(for: Bool.self) { proxy in
            proxy.size.width >= 900
        } action: { next in
            if supportsSplitDetail != next {
                supportsSplitDetail = next
            }
        }
        .sheet(isPresented: Binding(
            get: { detailIsPresented && !supportsSplitDetail && selectedSession != nil },
            set: { if !$0 && !supportsSplitDetail { detailIsPresented = false } }
        )) {
            if let session = selectedSession {
                ActivitySessionDetail(
                    session: session,
                    isFilteredByProject: selectedProjectPath == session.projectPath && !session.projectPath.isEmpty,
                    onClose: { detailIsPresented = false },
                    onToggleProjectFilter: {
                        guard !session.projectPath.isEmpty else { return }
                        selectedProjectPath = (selectedProjectPath == session.projectPath) ? nil : session.projectPath
                    },
                    onRequestDelete: { requestDeletion(of: [session.deletionTarget]) },
                    onRevealSource: { revealSessionSource(session) },
                    onCopyResume: { copySessionResume(session) }
                )
                .frame(minWidth: 440, idealWidth: 500, maxWidth: 620, minHeight: 420, idealHeight: 580, maxHeight: 740)
            }
        }
        .alert(deleteAlertTitle, isPresented: $showingDeleteConfirm) {
            Button("取消", role: .cancel) {
                pendingDeletionTargets = []
            }
            Button(isDeleting ? "正在删除…" : "删除", role: .destructive) {
                let targets = pendingDeletionTargets
                Task { await performLocalDeletion(targets: targets) }
            }
            .disabled(isDeleting)
        } message: {
            Text(deleteAlertMessage)
        }
        .onAppear {
            hiddenCount = SessionManagementService.hiddenSessionCount()
        }
        .onChange(of: selectedTool) { _, newTool in
            if let path = selectedProjectPath,
               !history.snapshot.projects(for: newTool).contains(where: { $0.path == path }) {
                selectedProjectPath = nil
            }
            applyFilters()
        }
        .onChange(of: selectedProjectPath) { _, _ in applyFilters() }
        .onChange(of: search) { _, _ in applyFilters() }
        .onChange(of: timeFilter) { _, _ in applyFilters() }
        .onChange(of: sortOrder) { _, _ in applyFilters() }
        .onChange(of: isManaging) { _, managing in
            if managing {
                detailIsPresented = false
            } else {
                batchSelectedIDs.removeAll()
            }
        }
        .onChange(of: history.snapshotRevision) { _, _ in
            if let path = selectedProjectPath,
               !history.snapshot.projects(for: selectedTool).contains(where: { $0.path == path }) {
                selectedProjectPath = nil
            }
        }
        .onChange(of: history.filterRevision) { _, _ in
            if let selectedID, !history.filtered.visibleIDs.contains(selectedID) {
                self.selectedID = nil
            }
            if !batchSelectedIDs.isEmpty {
                batchSelectedIDs = batchSelectedIDs.intersection(history.filtered.visibleIDs)
            }
        }
        .onChange(of: selectedID) { _, selection in
            if !isManaging {
                detailIsPresented = selection != nil
            }
        }
    }

    private func applyFilters() {
        history.filter(
            tool: selectedTool,
            search: search,
            projectPath: selectedProjectPath,
            timeFilter: timeFilter,
            sortOrder: sortOrder
        )
    }

    private func requestDeletion(of targets: [SessionDeletionTarget]) {
        guard !targets.isEmpty, !isDeleting else { return }
        pendingDeletionTargets = targets
        showingDeleteConfirm = true
    }

    private func performLocalDeletion(targets: [SessionDeletionTarget]) async {
        guard !targets.isEmpty else { return }
        isDeleting = true
        defer {
            isDeleting = false
            pendingDeletionTargets = []
        }

        do {
            let report = try await SessionManagementService.deleteSessions(
                targets,
                mode: .trashLocalFiles,
                modelContainer: appStore.modelContainer
            )
            let removedIDs = Set(targets.map(\.id))
            if let selectedID, removedIDs.contains(selectedID) {
                self.selectedID = nil
                self.detailIsPresented = false
            }
            batchSelectedIDs.subtract(removedIDs)
            if batchSelectedIDs.isEmpty && isManaging {
                isManaging = false
            }
            hiddenCount = SessionManagementService.hiddenSessionCount()
            appStore.syncService?.notifyUsageRecordsMutated()
            history.reload(container: appStore.modelContainer)

            var parts: [String] = [String(localized: "已删除 \(report.deletedRecords) 条会话")]
            if !report.trashedURLs.isEmpty {
                parts.append(String(localized: "将 \(report.trashedURLs.count) 个本地文件移至废纸篓"))
            }
            if report.archivedCodexThreads > 0 {
                parts.append(String(localized: "归档 \(report.archivedCodexThreads) 条 Codex 线程"))
            }
            if let firstWarning = report.warnings.first {
                parts.append(firstWarning)
            }
            feedbackMessage = ActivityFeedbackMessage(
                text: parts.joined(separator: "，"),
                isWarning: !report.warnings.isEmpty
            )
        } catch {
            feedbackMessage = ActivityFeedbackMessage(
                text: String(localized: "删除会话失败：\(error.localizedDescription)"),
                isWarning: true
            )
        }
    }

    private func restoreHiddenSessions() async {
        isRestoringHidden = true
        defer { isRestoringHidden = false }

        if let syncService = appStore.syncService {
            await syncService.restoreHiddenSessionsAndResync()
        } else {
            SessionManagementService.unhideAllSessions()
        }
        hiddenCount = SessionManagementService.hiddenSessionCount()
        history.reload(container: appStore.modelContainer)
        feedbackMessage = ActivityFeedbackMessage(
            text: String(localized: "已恢复所有隐藏会话并触发重新同步。"),
            isWarning: false
        )
    }

    private func revealSessionSource(_ session: ActivitySessionSnapshot) {
        if let url = SessionManagementService.locateSourceURL(for: session.tool, sessionID: session.id) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else if !session.projectPath.isEmpty, FileManager.default.fileExists(atPath: session.projectPath) {
            NSWorkspace.shared.open(URL(fileURLWithPath: session.projectPath))
            feedbackMessage = ActivityFeedbackMessage(
                text: String(localized: "未找到对应会话源文件，已为你打开项目目录。"),
                isWarning: true
            )
        } else {
            feedbackMessage = ActivityFeedbackMessage(
                text: String(localized: "未在本地找到该会话对应的源文件。"),
                isWarning: true
            )
        }
    }

    private func copySessionResume(_ session: ActivitySessionSnapshot) {
        let value = SessionManagementService.resumeCommand(
            for: session.tool,
            sessionID: session.id,
            projectPath: session.projectPath
        ) ?? session.id.uuidString.lowercased()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        feedbackMessage = ActivityFeedbackMessage(
            text: session.tool == .antigravity
                ? String(localized: "已复制会话 ID")
                : String(localized: "已复制恢复命令：\(value)"),
            isWarning: false
        )
    }
}

// MARK: - Main Content Column

private struct ActivityBrowserContent: View {
    let activityTools: [Tool]
    let projects: [ActivityProjectOption]
    let sessionCount: Int
    let totalTokens: Int
    let averageTokens: Int
    let favoriteProject: String?
    let latestActiveDate: Date?
    @Binding var selectedTool: Tool?
    @Binding var selectedProjectPath: String?
    @Binding var search: String
    @Binding var timeFilter: ActivityTimeFilter
    @Binding var sortOrder: ActivitySortOrder
    let counts: [Tool: Int]
    let totalCount: Int
    let result: ActivityHistoryFilterResult
    let filterIdentity: ActivityHistoryFilterIdentity
    @Binding var selection: UUID?
    let hasSessions: Bool
    let isLoading: Bool
    @Binding var isManaging: Bool
    @Binding var batchSelectedIDs: Set<UUID>
    let hiddenCount: Int
    let isRestoringHidden: Bool
    let feedbackMessage: ActivityFeedbackMessage?
    let onDismissFeedback: () -> Void
    let onRestoreHidden: () -> Void
    let onOpenDetail: () -> Void
    let onSelectProjectFilter: (String) -> Void
    let onRequestDelete: ([SessionDeletionTarget]) -> Void
    let onRevealSource: (ActivitySessionSnapshot) -> Void
    let onCopyResume: (ActivitySessionSnapshot) -> Void

    private enum WidthClass: Equatable {
        case compact   // < 660pt
        case medium    // 660..<820pt
        case wide      // >= 820pt

        var isWideSummary: Bool { self != .compact }
        var isWideToolbar: Bool { self == .wide }

        static func from(width: CGFloat) -> Self {
            if width >= 820 { return .wide }
            if width >= 660 { return .medium }
            return .compact
        }
    }

    @State private var widthClass: WidthClass = .wide

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ActivityPageHeader(
                hiddenCount: hiddenCount,
                isRestoringHidden: isRestoringHidden,
                onRestoreHidden: onRestoreHidden
            )

            if let feedbackMessage {
                ActivityFeedbackBanner(
                    message: feedbackMessage,
                    onDismiss: onDismissFeedback
                )
            }

            ActivitySummaryView(
                sessionCount: sessionCount,
                totalTokens: totalTokens,
                averageTokens: averageTokens,
                favoriteProject: favoriteProject,
                latestActiveDate: latestActiveDate,
                tool: selectedTool,
                isWide: widthClass.isWideSummary
            )

            HStack(alignment: .center, spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    ActivityToolCapsuleBar(
                        tools: activityTools,
                        selectedTool: $selectedTool,
                        counts: counts,
                        totalCount: totalCount
                    )
                }
                .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    if isLoading {
                        ProgressView().controlSize(.mini)
                    }
                    Text("\(result.sessions.count) 条记录")
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            ActivitySessionList(
                projects: projects,
                selectedProjectPath: $selectedProjectPath,
                search: $search,
                timeFilter: $timeFilter,
                sortOrder: $sortOrder,
                isWide: widthClass.isWideToolbar,
                result: result,
                filterIdentity: filterIdentity,
                selection: $selection,
                isSearching: !search.isEmpty || timeFilter != .all || selectedProjectPath != nil,
                hasSessions: hasSessions,
                isLoading: isLoading,
                isManaging: $isManaging,
                batchSelectedIDs: $batchSelectedIDs,
                onOpenDetail: onOpenDetail,
                onSelectProjectFilter: onSelectProjectFilter,
                onRequestDelete: onRequestDelete,
                onRevealSource: onRevealSource,
                onCopyResume: onCopyResume
            )
        }
        .frame(maxWidth: 1120, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, widthClass.isWideToolbar ? 28 : 20)
        .padding(.top, 8)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: WidthClass.self) { proxy in
            WidthClass.from(width: proxy.size.width)
        } action: { next in
            if widthClass != next {
                widthClass = next
            }
        }
    }
}

// MARK: - Header & Feedback Banner

private struct ActivityPageHeader: View {
    @Environment(AppStore.self) private var appStore
    @Environment(\.colorScheme) private var colorScheme
    let hiddenCount: Int
    let isRestoringHidden: Bool
    let onRestoreHidden: () -> Void
    @Namespace private var glassNamespace

    private var isSyncing: Bool { appStore.syncService?.isSyncingActive ?? false }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("活动记录")
                    .font(.system(size: 28, weight: .semibold))
                    .tracking(-0.4)
                Text("检索、筛选与管理各工具的本地会话历史。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            HStack(spacing: 10) {
                if hiddenCount > 0 {
                    Button(action: onRestoreHidden) {
                        HStack(spacing: 5) {
                            if isRestoringHidden {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.system(size: 10.5, weight: .semibold))
                            }
                            Text("恢复 \(hiddenCount) 条已隐藏")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(
                            Color.orange.opacity(colorScheme == .dark ? 0.16 : 0.10),
                            in: Capsule()
                        )
                        .overlay {
                            Capsule()
                                .strokeBorder(Color.orange.opacity(0.32), lineWidth: 0.6)
                        }
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .disabled(isRestoringHidden)
                    .help("取消隐藏并重新导入已隐藏的历史会话")
                }

                GlassEffectContainer(spacing: 8) {
                    Button {
                        guard !isSyncing else { return }
                        Task { await appStore.syncService?.sync() }
                    } label: {
                        Group {
                            if isSyncing {
                                ProgressView()
                                    .controlSize(.mini)
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                        }
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .glassEffectID("activityRefresh", in: glassNamespace)
                    .focusEffectDisabled()
                    .keyboardShortcut("r", modifiers: .command)
                    .help(isSyncing ? String(localized: "同步中…") : String(localized: "刷新同步 (⌘R)"))
                    .accessibilityLabel("刷新同步")
                }
                .animation(.smooth(duration: 0.25), value: isSyncing)
            }
        }
    }
}

private struct ActivityFeedbackBanner: View {
    @Environment(\.colorScheme) private var colorScheme
    let message: ActivityFeedbackMessage
    let onDismiss: () -> Void

    var body: some View {
        let tint: Color = message.isWarning ? .orange : .green
        HStack(spacing: 10) {
            Image(systemName: message.isWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
            Text(message.text)
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.9))
                .lineLimit(2)
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(
            tint.opacity(colorScheme == .dark ? 0.14 : 0.08),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tint.opacity(colorScheme == .dark ? 0.28 : 0.18), lineWidth: 0.75)
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

// MARK: - Compact Single-Row Summary Strip

private struct ActivitySummaryView: View {
    @Environment(\.colorScheme) private var colorScheme
    let sessionCount: Int
    let totalTokens: Int
    let averageTokens: Int
    let favoriteProject: String?
    let latestActiveDate: Date?
    let tool: Tool?
    let isWide: Bool

    private var isAntigravityZeroToken: Bool {
        tool == .antigravity && totalTokens == 0
    }

    var body: some View {
        Group {
            if isWide {
                HStack(spacing: 0) {
                    metricColumn(
                        title: "累计会话",
                        value: sessionCount.formatted(),
                        isMonospaced: true
                    )
                    verticalDivider
                    metricColumn(
                        title: "累计 Token",
                        value: isAntigravityZeroToken ? "—" : totalTokens.compactTokenString,
                        isMonospaced: true
                    )
                    verticalDivider
                    metricColumn(
                        title: isAntigravityZeroToken ? "最近活跃" : "平均消耗",
                        value: isAntigravityZeroToken
                            ? (latestActiveDate?.formatted(.dateTime.month().day().hour().minute()) ?? "—")
                            : averageTokens.compactTokenString,
                        isMonospaced: true
                    )
                    verticalDivider
                    metricColumn(
                        title: "最常服务项目",
                        value: favoriteProject.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "—",
                        isMonospaced: false,
                        helpText: favoriteProject
                    )
                }
            } else {
                LazyVGrid(
                    columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                    spacing: 12
                ) {
                    metricColumn(title: "累计会话", value: sessionCount.formatted(), isMonospaced: true)
                    metricColumn(title: "累计 Token", value: isAntigravityZeroToken ? "—" : totalTokens.compactTokenString, isMonospaced: true)
                    metricColumn(
                        title: isAntigravityZeroToken ? "最近活跃" : "平均消耗",
                        value: isAntigravityZeroToken
                            ? (latestActiveDate?.formatted(.dateTime.month().day().hour().minute()) ?? "—")
                            : averageTokens.compactTokenString,
                        isMonospaced: true
                    )
                    metricColumn(
                        title: "最常服务项目",
                        value: favoriteProject.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "—",
                        isMonospaced: false,
                        helpText: favoriteProject
                    )
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .dashboardSurface(cornerRadius: 15, accent: tool?.brandAccentColor(for: colorScheme))
    }

    private var verticalDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.065))
            .frame(width: 0.5, height: 28)
            .padding(.horizontal, 16)
    }

    private func metricColumn(
        title: LocalizedStringKey,
        value: String,
        isMonospaced: Bool,
        helpText: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: isMonospaced ? 18 : 16, weight: .semibold))
                .monospacedDigit()
                .tracking(-0.2)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .truncationMode(.middle)
                .contentTransition(.numericText())
                .frame(height: 22, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(helpText ?? "")
    }
}

// MARK: - Filter Controls

private enum ActivityMenuEntry {
    case item(title: String, isSelected: Bool, action: @MainActor () -> Void)
    case divider
    case submenu(title: String, items: [ActivityMenuEntry])
}

@MainActor
private final class ActivityMenuActionBox: NSObject {
    let action: @MainActor () -> Void

    init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    @objc func invoke(_ sender: NSMenuItem) {
        action()
    }
}

private final class ActivityMenuAnchorNSView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct ActivityMenuAnchorCapture: NSViewRepresentable {
    let onCapture: (NSView) -> Void

    func makeNSView(context: Context) -> ActivityMenuAnchorNSView {
        let view = ActivityMenuAnchorNSView(frame: .zero)
        DispatchQueue.main.async { onCapture(view) }
        return view
    }

    func updateNSView(_ nsView: ActivityMenuAnchorNSView, context: Context) {
        DispatchQueue.main.async { onCapture(nsView) }
    }
}

private struct ActivityToolbarMenu: View {
    @Environment(\.colorScheme) private var colorScheme
    let icon: String?
    let title: String
    let isActive: Bool
    let maxWidth: CGFloat?
    let helpText: LocalizedStringKey
    let entries: () -> [ActivityMenuEntry]

    @State private var isHovered = false
    @State private var anchorView: NSView?

    init(
        icon: String? = nil,
        title: String,
        isActive: Bool = false,
        maxWidth: CGFloat? = nil,
        help: LocalizedStringKey,
        entries: @escaping () -> [ActivityMenuEntry]
    ) {
        self.icon = icon
        self.title = title
        self.isActive = isActive
        self.maxWidth = maxWidth
        self.helpText = help
        self.entries = entries
    }

    private var fillColor: Color {
        if isActive {
            return Color.accentColor.opacity(
                colorScheme == .dark ? (isHovered ? 0.22 : 0.16) : (isHovered ? 0.14 : 0.10)
            )
        }
        return Color.primary.opacity(
            colorScheme == .dark ? (isHovered ? 0.10 : 0.06) : (isHovered ? 0.075 : 0.04)
        )
    }

    private var borderColor: Color {
        if isActive {
            return Color.accentColor.opacity(isHovered ? 0.45 : 0.32)
        }
        return Color.primary.opacity(isHovered ? 0.14 : 0.09)
    }

    var body: some View {
        Button {
            presentMenu()
        } label: {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(isActive ? Color.accentColor : .secondary)
                }
                Text(title)
                    .font(.system(size: 11.5, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(isActive ? Color.accentColor : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(isActive ? Color.accentColor.opacity(0.75) : Color.secondary.opacity(0.65))
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .frame(maxWidth: maxWidth)
            .background(fillColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 0.75)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .fixedSize(horizontal: true, vertical: false)
        .background(
            ActivityMenuAnchorCapture { view in
                if anchorView !== view {
                    anchorView = view
                }
            }
            .allowsHitTesting(false)
        )
        .onHover { hovering in
            isHovered = hovering
        }
        .help(helpText)
        .accessibilityLabel(title)
    }

    @MainActor
    private func presentMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        populate(menu: menu, with: entries())

        if let anchorView, anchorView.window != nil {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchorView.bounds.height + 4), in: anchorView)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
        isHovered = false
    }

    @MainActor
    private func populate(menu: NSMenu, with items: [ActivityMenuEntry]) {
        for entry in items {
            switch entry {
            case .divider:
                menu.addItem(.separator())
            case .item(let title, let isSelected, let action):
                let box = ActivityMenuActionBox(action)
                let item = NSMenuItem(
                    title: title,
                    action: #selector(ActivityMenuActionBox.invoke(_:)),
                    keyEquivalent: ""
                )
                item.target = box
                item.representedObject = box
                item.state = isSelected ? .on : .off
                menu.addItem(item)
            case .submenu(let title, let subitems):
                let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                let submenu = NSMenu(title: title)
                submenu.autoenablesItems = false
                populate(menu: submenu, with: subitems)
                parent.submenu = submenu
                menu.addItem(parent)
            }
        }
    }
}

private struct ActivityToolbarActionButton: View {
    @Environment(\.colorScheme) private var colorScheme
    let icon: String
    let title: LocalizedStringKey
    let isDisabled: Bool
    let helpText: LocalizedStringKey
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                Color.primary.opacity(
                    colorScheme == .dark
                        ? (isHovered && !isDisabled ? 0.11 : 0.06)
                        : (isHovered && !isDisabled ? 0.08 : 0.04)
                ),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        Color.primary.opacity(isHovered && !isDisabled ? 0.14 : 0.09),
                        lineWidth: 0.75
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
        .fixedSize(horizontal: true, vertical: false)
        .onHover { hovering in
            isHovered = hovering
        }
        .help(helpText)
    }
}

private struct ActivityProjectFilterMenu: View {
    let projects: [ActivityProjectOption]
    @Binding var selectedProjectPath: String?

    private var realProjects: [ActivityProjectOption] {
        projects.filter { !$0.isTemporary }
    }

    private var tempProjects: [ActivityProjectOption] {
        projects.filter(\.isTemporary)
    }

    private var activeProject: ActivityProjectOption? {
        guard let path = selectedProjectPath else { return nil }
        return projects.first(where: { $0.path == path })
    }

    private var activeLabel: String {
        activeProject?.displayLabel ?? String(localized: "全部项目")
    }

    var body: some View {
        let isFiltered = activeProject != nil
        ActivityToolbarMenu(
            icon: isFiltered ? "folder.fill" : "folder",
            title: activeLabel,
            isActive: isFiltered,
            maxWidth: 172,
            help: "按所属项目筛选"
        ) {
            var items: [ActivityMenuEntry] = [
                .item(title: String(localized: "全部项目"), isSelected: selectedProjectPath == nil) {
                    selectedProjectPath = nil
                }
            ]

            if !realProjects.isEmpty {
                items.append(.divider)
                for project in realProjects.prefix(25) {
                    items.append(
                        .item(
                            title: "\(project.displayLabel)  (\(project.sessionCount))",
                            isSelected: selectedProjectPath == project.path
                        ) {
                            selectedProjectPath = project.path
                        }
                    )
                }
            }

            if !tempProjects.isEmpty {
                let subitems: [ActivityMenuEntry] = tempProjects.prefix(20).map { project in
                    .item(
                        title: "\(project.name)  (\(project.sessionCount))",
                        isSelected: selectedProjectPath == project.path
                    ) {
                        selectedProjectPath = project.path
                    }
                }
                items.append(.submenu(title: String(localized: "临时与探针目录 (\(tempProjects.count))"), items: subitems))
            }

            return items
        }
    }
}

private struct ActivityTimeFilterMenu: View {
    @Binding var timeFilter: ActivityTimeFilter

    var body: some View {
        ActivityToolbarMenu(
            title: String(localized: timeFilter.localizationKey),
            isActive: timeFilter != .all,
            help: "按时间范围筛选"
        ) {
            ActivityTimeFilter.allCases.map { item in
                .item(
                    title: String(localized: item.localizationKey),
                    isSelected: timeFilter == item
                ) {
                    timeFilter = item
                }
            }
        }
    }
}

private struct ActivitySortOrderMenu: View {
    @Binding var sortOrder: ActivitySortOrder

    var body: some View {
        ActivityToolbarMenu(
            title: String(localized: sortOrder.localizationKey),
            isActive: sortOrder != .newest,
            help: "调整会话排序"
        ) {
            ActivitySortOrder.allCases.map { item in
                .item(
                    title: String(localized: item.localizationKey),
                    isSelected: sortOrder == item
                ) {
                    sortOrder = item
                }
            }
        }
    }
}

private struct ActivityToolCapsuleBar: View {
    @Environment(\.colorScheme) private var colorScheme
    let tools: [Tool]
    @Binding var selectedTool: Tool?
    let counts: [Tool: Int]
    let totalCount: Int
    @Namespace private var thumbNamespace
    @State private var hoveredKey: String?

    var body: some View {
        HStack(spacing: 2) {
            segment(
                key: "all",
                tool: nil,
                title: String(localized: "全部"),
                count: totalCount,
                accent: .accentColor
            )
            ForEach(tools, id: \.self) { tool in
                segment(
                    key: tool.rawValue,
                    tool: tool,
                    title: tool.displayName,
                    count: counts[tool] ?? 0,
                    accent: tool.brandAccentColor(for: colorScheme)
                )
            }
        }
        .padding(3)
        .background(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.055), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08), lineWidth: 0.5)
        }
    }

    private func segment(
        key: String,
        tool: Tool?,
        title: String,
        count: Int,
        accent: Color
    ) -> some View {
        let isSelected = selectedTool == tool
        let isHovered = hoveredKey == key
        return Button {
            withAnimation(.smooth(duration: 0.22)) {
                selectedTool = tool
            }
        } label: {
            HStack(spacing: 6) {
                if let tool {
                    ToolBrandIconWell(tool: tool, size: 16, iconSize: 10)
                }
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? .primary : (isHovered ? .primary : .secondary))
                    .lineLimit(1)
                Text("\(count)")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isSelected ? accent : .secondary)
                    .padding(.horizontal, 5.5)
                    .padding(.vertical, 1.5)
                    .background(
                        (isSelected ? accent : Color.primary).opacity(colorScheme == .dark ? 0.16 : 0.08),
                        in: Capsule()
                    )
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 5.5)
            .background {
                if isSelected {
                    Capsule()
                        .fill(colorScheme == .dark ? Color.white.opacity(0.16) : Color.white)
                        .overlay {
                            Capsule()
                                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.06), lineWidth: 0.5)
                        }
                        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.07), radius: 2, y: 1)
                        .matchedGeometryEffect(id: "activityToolThumb", in: thumbNamespace)
                } else if isHovered {
                    Capsule()
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.04))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering in
            hoveredKey = hovering ? key : (hoveredKey == key ? nil : hoveredKey)
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ActivitySearchField: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var search: String
    @State private var text = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索任务、项目、分支、模型或会话 ID…", text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("清除搜索")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(
            Color.primary.opacity(colorScheme == .dark ? 0.055 : 0.035),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.085), lineWidth: 0.75)
        }
        .task(id: text) {
            do {
                try await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                search = text.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {}
        }
    }
}

// MARK: - Session List & Batch Management (Date-Grouped Card Rows)

private struct ActivitySessionList: View {
    @Environment(\.colorScheme) private var colorScheme
    let projects: [ActivityProjectOption]
    @Binding var selectedProjectPath: String?
    @Binding var search: String
    @Binding var timeFilter: ActivityTimeFilter
    @Binding var sortOrder: ActivitySortOrder
    let isWide: Bool
    let result: ActivityHistoryFilterResult
    let filterIdentity: ActivityHistoryFilterIdentity
    @Binding var selection: UUID?
    let isSearching: Bool
    let hasSessions: Bool
    let isLoading: Bool
    @Binding var isManaging: Bool
    @Binding var batchSelectedIDs: Set<UUID>
    let onOpenDetail: () -> Void
    let onSelectProjectFilter: (String) -> Void
    let onRequestDelete: ([SessionDeletionTarget]) -> Void
    let onRevealSource: (ActivitySessionSnapshot) -> Void
    let onCopyResume: (ActivitySessionSnapshot) -> Void

    @State private var renderWindow = ActivitySessionRenderWindow()
    @State private var renderedFilterIdentity: ActivityHistoryFilterIdentity?
    @State private var renderedResultID: ObjectIdentifier?
    @State private var viewportID = UUID()
    @State private var viewportSize: CGSize = .zero

    private var selectedBatchTargets: [SessionDeletionTarget] {
        result.sessions.compactMap { session in
            batchSelectedIDs.contains(session.id) ? session.deletionTarget : nil
        }
    }

    private var projectLabelByPath: [String: String] {
        Dictionary(uniqueKeysWithValues: projects.map { ($0.path, $0.displayLabel) })
    }

    var body: some View {
        let total = result.sessions.count
        let visibleCount = renderWindow.visibleCount(total: total)
        let visibleSlice = result.sessions.prefix(visibleCount)
        let useDayGrouping = filterIdentity.sortOrder.supportsDateGrouping

        VStack(alignment: .leading, spacing: 0) {
            // Integrated Toolbar inside the unified list surface
            Group {
                if isManaging {
                    let hasSelection = !batchSelectedIDs.isEmpty
                    HStack(spacing: 10) {
                        HStack(spacing: 8) {
                            Text("已选 \(batchSelectedIDs.count) 项")
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                .foregroundStyle(hasSelection ? Color.accentColor : Color.secondary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)

                            Button {
                                let visibleIDs = Set(visibleSlice.map(\.id))
                                if batchSelectedIDs.isSuperset(of: visibleIDs) && !visibleIDs.isEmpty {
                                    batchSelectedIDs.subtract(visibleIDs)
                                } else {
                                    batchSelectedIDs.formUnion(visibleIDs)
                                }
                            } label: {
                                Text(batchSelectedIDs.count == visibleCount && visibleCount > 0 ? "取消全选" : "全选当前显示")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .padding(.horizontal, 10)
                                    .frame(height: 26)
                                    .background(
                                        Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05),
                                        in: Capsule()
                                    )
                                    .overlay {
                                        Capsule()
                                            .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.6)
                                    }
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                            .disabled(visibleCount == 0)
                            .opacity(visibleCount == 0 ? 0.45 : 1)

                            if total > visibleCount {
                                Button {
                                    batchSelectedIDs = result.visibleIDs
                                } label: {
                                    Text("全选全部 (\(total))")
                                        .font(.system(size: 11.5, weight: .medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                        .padding(.horizontal, 10)
                                        .frame(height: 26)
                                        .background(
                                            Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05),
                                            in: Capsule()
                                        )
                                        .overlay {
                                            Capsule()
                                                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.6)
                                        }
                                }
                                .buttonStyle(.plain)
                                .focusEffectDisabled()
                            }

                            if hasSelection {
                                Button("清空选择") {
                                    batchSelectedIDs.removeAll()
                                }
                                .buttonStyle(.plain)
                                .focusEffectDisabled()
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 4)
                            }
                        }

                        Spacer(minLength: 8)

                        HStack(spacing: 8) {
                            Button(role: .destructive) {
                                onRequestDelete(selectedBatchTargets)
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "trash")
                                        .font(.system(size: 10.5, weight: .semibold))
                                    if hasSelection {
                                        Text("删除 (\(batchSelectedIDs.count))")
                                            .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                                            .lineLimit(1)
                                            .fixedSize(horizontal: true, vertical: false)
                                    } else {
                                        Text("删除")
                                            .font(.system(size: 11.5, weight: .medium))
                                            .lineLimit(1)
                                            .fixedSize(horizontal: true, vertical: false)
                                    }
                                }
                                .foregroundStyle(hasSelection ? Color.red : Color.secondary.opacity(0.65))
                                .padding(.horizontal, 11)
                                .frame(height: 26)
                                .background(
                                    hasSelection
                                        ? Color.red.opacity(colorScheme == .dark ? 0.20 : 0.11)
                                        : Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.04),
                                    in: Capsule()
                                )
                                .overlay {
                                    Capsule()
                                        .strokeBorder(
                                            hasSelection
                                                ? Color.red.opacity(colorScheme == .dark ? 0.42 : 0.28)
                                                : Color.primary.opacity(0.08),
                                            lineWidth: 0.75
                                        )
                                }
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                            .disabled(!hasSelection)

                            Button {
                                withAnimation(.smooth(duration: 0.18)) {
                                    isManaging = false
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .semibold))
                                    Text("完成管理")
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 11)
                                .frame(height: 26)
                                .background(Color.accentColor, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                        }
                    }
                    .frame(height: 28)
                } else {
                    let layout = isWide
                        ? AnyLayout(HStackLayout(spacing: 8))
                        : AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                    layout {
                        ActivitySearchField(search: $search)
                            .frame(minWidth: isWide ? 180 : nil, maxWidth: .infinity)

                        HStack(spacing: 6) {
                            if !projects.isEmpty {
                                ActivityProjectFilterMenu(
                                    projects: projects,
                                    selectedProjectPath: $selectedProjectPath
                                )
                            }

                            ActivityTimeFilterMenu(timeFilter: $timeFilter)

                            ActivitySortOrderMenu(sortOrder: $sortOrder)

                            if !isWide {
                                Spacer(minLength: 4)
                            }

                            Rectangle()
                                .fill(Color.primary.opacity(0.08))
                                .frame(width: 1, height: 16)
                                .padding(.horizontal, 2)

                            ActivityToolbarActionButton(
                                icon: "checklist",
                                title: "批量管理",
                                isDisabled: result.sessions.isEmpty,
                                helpText: "批量选择并管理会话"
                            ) {
                                withAnimation(.smooth(duration: 0.18)) {
                                    isManaging = true
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(colorScheme == .dark ? 0.03 : 0.018))

            TelemetryHairline()

            if result.sessions.isEmpty {
                VStack {
                    if isLoading {
                        ProgressView()
                    } else {
                        ContentUnavailableView(
                            isSearching || hasSessions ? "未找到匹配会话" : "暂无会话记录",
                            systemImage: "doc.text.magnifyingglass",
                            description: Text(isSearching || hasSessions ? "请尝试更改搜索词、项目、时间范围或工具筛选。" : "开始使用 AI 编程工具后将在此记录详情。")
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let coordinateSpace = viewportID
                let resultID = ObjectIdentifier(result)
                let labels = projectLabelByPath

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if useDayGrouping {
                            let groups = ActivitySessionDayGroup.group(visibleSlice)
                            ForEach(groups) { group in
                                let selectedInGroup = isManaging
                                    ? group.sessions.reduce(into: 0) { count, session in
                                        if batchSelectedIDs.contains(session.id) {
                                            count += 1
                                        }
                                    }
                                    : 0
                                ActivityDaySectionHeader(
                                    group: group,
                                    isManaging: isManaging,
                                    selectedCount: selectedInGroup,
                                    onToggleGroupSelection: { toggleBatchSelection(for: group) }
                                )
                                .padding(.top, group.id == groups.first?.id ? 10 : 20)
                                .padding(.bottom, 6)

                                ForEach(Array(group.sessions.enumerated()), id: \.element.id) { index, session in
                                    rowView(for: session, groupedByDay: true, projectDisplayLabel: labels[session.projectPath])
                                    if index < group.sessions.count - 1 {
                                        TelemetryHairline(opacity: colorScheme == .dark ? 0.06 : 0.045)
                                            .padding(.leading, isManaging ? 84 : 56)
                                            .padding(.trailing, 16)
                                    }
                                }
                            }
                        } else {
                            let items = Array(visibleSlice)
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, session in
                                rowView(for: session, groupedByDay: false, projectDisplayLabel: labels[session.projectPath])
                                if index < items.count - 1 {
                                    TelemetryHairline(opacity: colorScheme == .dark ? 0.06 : 0.045)
                                        .padding(.leading, isManaging ? 84 : 56)
                                        .padding(.trailing, 16)
                                }
                            }
                        }

                        if visibleCount < total {
                            HStack(spacing: 10) {
                                Spacer()
                                Button("加载更多会话 (\(total - visibleCount) 条剩余)") {
                                    renderWindow.revealNext(total: total, boundary: visibleCount)
                                }
                                .buttonStyle(.link)
                                .font(.system(size: 12))
                                Text("·")
                                    .foregroundStyle(.quaternary)
                                Button("显示全部") {
                                    renderWindow.revealAll(total: total)
                                }
                                .buttonStyle(.link)
                                .font(.system(size: 12))
                                Spacer()
                            }
                            .padding(.vertical, 16)
                            .onGeometryChange(for: Bool.self) { geometry in
                                let frame = geometry.frame(in: .named(coordinateSpace))
                                return frame.height > 0 && frame.width > 0 &&
                                    frame.maxY > 0 && frame.minY < viewportSize.height &&
                                    frame.maxX > 0 && frame.minX < viewportSize.width
                            } action: { isVisible in
                                guard isVisible, renderedResultID == resultID else { return }
                                renderWindow.revealNext(total: total, boundary: visibleCount)
                            }
                            .id(visibleCount)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
                .scrollEdgeEffectStyle(.soft, for: .vertical)
                .coordinateSpace(name: coordinateSpace)
                .onGeometryChange(for: CGSize.self) { proxy in
                    proxy.size
                } action: { next in
                    if abs(viewportSize.width - next.width) > 1 || abs(viewportSize.height - next.height) > 1 {
                        viewportSize = next
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dashboardSurface()
        .onChange(of: ObjectIdentifier(result), initial: true) { _, _ in
            renderedResultID = ObjectIdentifier(result)
            renderWindow.update(
                total: result.sessions.count,
                selectedIndex: selection.flatMap { result.positionsByID[$0] },
                reset: renderedFilterIdentity != filterIdentity
            )
            renderedFilterIdentity = filterIdentity
        }
    }

    @ViewBuilder
    private func rowView(
        for session: ActivitySessionSnapshot,
        groupedByDay: Bool,
        projectDisplayLabel: String?
    ) -> some View {
        let isSelected = !isManaging && selection == session.id
        ActivitySessionRow(
            session: session,
            projectDisplayLabel: projectDisplayLabel ?? session.projectName,
            groupedByDay: groupedByDay,
            isSelected: isSelected,
            isProjectFiltered: selectedProjectPath == session.projectPath && !session.projectPath.isEmpty,
            isManaging: isManaging,
            isBatchSelected: batchSelectedIDs.contains(session.id),
            onToggleBatchSelection: { toggleBatchSelection(session.id) },
            onSelectProject: { onSelectProjectFilter(session.projectPath) },
            onCopyResume: { onCopyResume(session) },
            onRevealSource: { onRevealSource(session) },
            onRequestDelete: { onRequestDelete([session.deletionTarget]) }
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture {
            if isManaging {
                toggleBatchSelection(session.id)
            } else {
                selection = session.id
                onOpenDetail()
            }
        }
        .contextMenu {
            Button("查看详情", systemImage: "sidebar.right") {
                isManaging = false
                selection = session.id
                onOpenDetail()
            }
            Button(
                session.tool == .antigravity ? "复制会话 ID" : "复制恢复命令",
                systemImage: "terminal"
            ) {
                onCopyResume(session)
            }
            Button("在 Finder 中定位源文件", systemImage: "folder") {
                onRevealSource(session)
            }
            if !session.projectPath.isEmpty {
                Button(
                    selectedProjectPath == session.projectPath ? "取消项目筛选" : "仅查看“\(session.projectName)”",
                    systemImage: "line.3.horizontal.decrease.circle"
                ) {
                    onSelectProjectFilter(session.projectPath)
                }
                if FileManager.default.fileExists(atPath: session.projectPath) {
                    Button("打开项目目录", systemImage: "folder.badge.gearshape") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: session.projectPath))
                    }
                }
            }
            Divider()
            Button("删除会话…", systemImage: "trash", role: .destructive) {
                onRequestDelete([session.deletionTarget])
            }
        }
    }

    private func toggleBatchSelection(_ id: UUID) {
        if batchSelectedIDs.contains(id) {
            batchSelectedIDs.remove(id)
        } else {
            batchSelectedIDs.insert(id)
        }
    }

    private func toggleBatchSelection(for group: ActivitySessionDayGroup) {
        let groupIDs = Set(group.sessions.map(\.id))
        guard !groupIDs.isEmpty else { return }
        if groupIDs.isSubset(of: batchSelectedIDs) {
            batchSelectedIDs.subtract(groupIDs)
        } else {
            batchSelectedIDs.formUnion(groupIDs)
        }
    }
}

private struct ActivityDaySectionHeader: View {
    @Environment(\.colorScheme) private var colorScheme
    let group: ActivitySessionDayGroup
    let isManaging: Bool
    let selectedCount: Int
    let onToggleGroupSelection: () -> Void

    @State private var isHovered = false

    private var totalCount: Int { group.sessions.count }
    private var isAllSelected: Bool { totalCount > 0 && selectedCount >= totalCount }
    private var isPartiallySelected: Bool { selectedCount > 0 && selectedCount < totalCount }

    private var selectionIcon: String {
        if isAllSelected { return "checkmark.circle.fill" }
        if isPartiallySelected { return "minus.circle.fill" }
        return "circle"
    }

    private var hasAnySelection: Bool { selectedCount > 0 }

    var body: some View {
        HStack(spacing: 8) {
            if isManaging {
                Button(action: onToggleGroupSelection) {
                    HStack(spacing: 13) {
                        Image(systemName: selectionIcon)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(
                                hasAnySelection
                                    ? Color.accentColor
                                    : (isHovered ? Color.primary.opacity(0.75) : Color.secondary)
                            )
                            .frame(width: 20, height: 20)

                        HStack(spacing: 8) {
                            Text(group.title)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(hasAnySelection || isHovered ? .primary : .secondary)

                            Text(hasAnySelection ? "\(selectedCount)/\(totalCount)" : "\(totalCount)")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(hasAnySelection ? Color.accentColor : .secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(
                                    (hasAnySelection ? Color.accentColor : Color.primary)
                                        .opacity(colorScheme == .dark ? (hasAnySelection ? 0.18 : 0.08) : (hasAnySelection ? 0.12 : 0.05)),
                                    in: Capsule()
                                )
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .onHover { hovering in
                    isHovered = hovering
                }
                .help(isAllSelected ? "取消全选当天会话" : "全选当天会话")
            } else {
                Text(group.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text("\(totalCount)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(
                        Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05),
                        in: Capsule()
                    )
            }

            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 1)

            if group.totalTokens > 0 {
                Text("\(group.totalTokens.compactTokenString) tokens")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
    }
}

private struct ActivitySessionRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let session: ActivitySessionSnapshot
    let projectDisplayLabel: String
    let groupedByDay: Bool
    let isSelected: Bool
    let isProjectFiltered: Bool
    let isManaging: Bool
    let isBatchSelected: Bool
    let onToggleBatchSelection: () -> Void
    let onSelectProject: () -> Void
    let onCopyResume: () -> Void
    let onRevealSource: () -> Void
    let onRequestDelete: () -> Void

    @State private var isHovered = false

    private var hasRealProject: Bool {
        !session.projectPath.isEmpty && !session.isTemporaryProject
    }

    private var rowBackground: Color {
        let brand = session.tool.brandAccentColor(for: colorScheme)
        if isManaging && isBatchSelected {
            return Color.accentColor.opacity(colorScheme == .dark ? 0.16 : 0.09)
        }
        if isSelected {
            return brand.opacity(colorScheme == .dark ? 0.14 : 0.08)
        }
        if isHovered {
            return Color.primary.opacity(colorScheme == .dark ? 0.05 : 0.032)
        }
        return .clear
    }

    private var rowBorderColor: Color {
        let brand = session.tool.brandAccentColor(for: colorScheme)
        if isManaging && isBatchSelected {
            return Color.accentColor.opacity(0.45)
        }
        if isSelected {
            return brand.opacity(colorScheme == .dark ? 0.42 : 0.32)
        }
        return .clear
    }

    var body: some View {
        let brand = session.tool.brandAccentColor(for: colorScheme)
        HStack(alignment: .center, spacing: 13) {
            if isManaging {
                Button(action: onToggleBatchSelection) {
                    Image(systemName: isBatchSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(isBatchSelected ? Color.accentColor : .secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }

            ToolBrandIconWell(tool: session.tool, size: 28, iconSize: 15)
                .help(session.tool.displayName)

            VStack(alignment: .leading, spacing: 6) {
                // Line 1: Clean single-line title
                Text(session.displayTitle)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                // Line 2: Real project badge + quiet model & branch (no temp hash clutter or time noise)
                HStack(spacing: 7) {
                    if hasRealProject {
                        projectBadge
                            .layoutPriority(2)
                    }

                    if !session.compactModelName.isEmpty {
                        if hasRealProject {
                            Text("·").foregroundStyle(.quaternary)
                        }
                        Text(session.compactModelName)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if let branch = session.branch, !branch.isEmpty {
                        if hasRealProject || !session.compactModelName.isEmpty {
                            Text("·").foregroundStyle(.quaternary)
                        }
                        HStack(spacing: 2.5) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 9, weight: .medium))
                            Text(branch)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .foregroundStyle(.tertiary)
                    }
                }
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Trailing: fixed-width slot that cross-fades tokens+time ↔ quick actions in place (zero layout shift)
            let showHoverActions = !isManaging && isHovered
            ZStack(alignment: .trailing) {
                VStack(alignment: .trailing, spacing: 5) {
                    if session.tool == .antigravity && session.totalTokens == 0 {
                        Text("任务记录")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(brand)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(brand.opacity(colorScheme == .dark ? 0.16 : 0.10), in: Capsule())
                    } else {
                        Text(session.totalTokens.compactTokenString)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }

                    HStack(spacing: 4) {
                        if groupedByDay {
                            Text(session.startedAt, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                        } else {
                            Text(session.startedAt, format: .dateTime.month().day().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                        }
                        if let duration = session.compactDuration {
                            Text("·")
                            Text(duration)
                        }
                    }
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                }
                .opacity(showHoverActions ? 0 : 1)
                .allowsHitTesting(!showHoverActions)

                HStack(spacing: 6) {
                    Button(action: onCopyResume) {
                        Image(systemName: session.tool == .antigravity ? "doc.on.doc" : "terminal")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 26, height: 26)
                            .background(Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.06), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .focusEffectDisabled()
                    .help(session.tool == .antigravity ? "复制会话 ID" : "复制恢复命令")

                    Button(action: onRevealSource) {
                        Image(systemName: "folder")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 26, height: 26)
                            .background(Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.06), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .focusEffectDisabled()
                    .help("在 Finder 中定位源文件")

                    Button(action: onRequestDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 26, height: 26)
                            .background(Color.red.opacity(colorScheme == .dark ? 0.18 : 0.11), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .focusEffectDisabled()
                    .help("从本地删除会话")
                }
                .opacity(showHoverActions ? 1 : 0)
                .allowsHitTesting(showHoverActions)
            }
            .frame(width: 108, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            rowBackground,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(rowBorderColor, lineWidth: 1)
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var projectBadge: some View {
        let label = HStack(spacing: 4) {
            Image(systemName: "folder.fill")
                .font(.system(size: 9, weight: .semibold))
            Text(projectDisplayLabel)
                .fontWeight(.medium)
                .lineLimit(1)
        }
        .font(.system(size: 11))
        .truncationMode(.middle)
        .foregroundStyle(isProjectFiltered ? .white : Color.accentColor)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(
            isProjectFiltered
                ? Color.accentColor
                : Color.accentColor.opacity(colorScheme == .dark ? 0.15 : 0.085),
            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
        )
        .help(session.abbreviatedProjectPath)

        if isManaging {
            label
        } else {
            Button(action: onSelectProject) {
                label
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
        }
    }
}

// MARK: - Detail Inspector

private struct ActivitySessionDetail: View {
    @Environment(\.colorScheme) private var colorScheme
    let session: ActivitySessionSnapshot
    let isFilteredByProject: Bool
    let onClose: () -> Void
    let onToggleProjectFilter: () -> Void
    let onRequestDelete: () -> Void
    let onRevealSource: () -> Void
    let onCopyResume: () -> Void

    @State private var copiedID = false

    var body: some View {
        let brand = session.tool.brandAccentColor(for: colorScheme)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Header with tool brand identity
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        ToolBrandIconWell(tool: session.tool, size: 28, iconSize: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.tool.displayName)
                                .font(.system(size: 13, weight: .semibold))
                            if let duration = session.formattedDuration {
                                Text(duration)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .medium))
                                .frame(width: 24, height: 24)
                                .background(Color.primary.opacity(colorScheme == .dark ? 0.07 : 0.045), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.cancelAction)
                        .foregroundStyle(.secondary)
                        .focusEffectDisabled()
                        .help("关闭详情")
                        .accessibilityLabel("关闭详情")
                    }

                    Text(session.displayTitle)
                        .font(.system(size: 15.5, weight: .semibold))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    // Quick Action Strip
                    HStack(spacing: 8) {
                        Button(action: onCopyResume) {
                            Label(
                                session.tool == .antigravity ? "复制 ID" : "恢复命令",
                                systemImage: session.tool == .antigravity ? "doc.on.doc" : "terminal"
                            )
                            .font(.system(size: 11.5, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button(action: onRevealSource) {
                            Label("源文件", systemImage: "folder")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Spacer(minLength: 4)

                        Button(role: .destructive, action: onRequestDelete) {
                            Image(systemName: "trash")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("从本地删除此会话")
                        .accessibilityLabel("从本地删除此会话")
                    }
                }
                .padding(16)
                .dashboardSurface(cornerRadius: 15, accent: brand)

                ActivityTokenDetails(
                    tool: session.tool,
                    input: session.inputTokens,
                    output: session.outputTokens,
                    cacheRead: session.cacheReadTokens,
                    cacheWrite: session.cacheWriteTokens
                )

                ActivityContextDetails(
                    session: session,
                    isFilteredByProject: isFilteredByProject,
                    copiedID: copiedID,
                    onToggleProjectFilter: onToggleProjectFilter,
                    onCopyID: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(session.id.uuidString.lowercased(), forType: .string)
                        copiedID = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.2))
                            copiedID = false
                        }
                    }
                )
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollEdgeEffectStyle(.soft, for: .vertical)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct ActivityTokenDetails: View {
    @Environment(\.colorScheme) private var colorScheme
    let tool: Tool
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int

    private var total: Int { input + output }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Token 明细")
                .font(.system(size: 13, weight: .semibold))

            if tool == .antigravity && total == 0 && cacheRead == 0 && cacheWrite == 0 {
                Text("该 Antigravity 会话为本地任务摘要目录，不包含 Token 用量明细。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                    spacing: 8
                ) {
                    tokenTile(label: "Input", value: input)
                    tokenTile(label: "Output", value: output)
                    tokenTile(label: "Cache Read", value: cacheRead)
                    tokenTile(label: "Cache Write", value: cacheWrite)
                }

                if total > 0 {
                    let inputFraction = Double(input) / Double(total)
                    let inputColor = colorScheme == .dark
                        ? Color(red: 0.36, green: 0.62, blue: 1.00)
                        : Color(red: 0.18, green: 0.46, blue: 0.92)
                    let outputColor = colorScheme == .dark
                        ? Color(red: 0.78, green: 0.52, blue: 1.00)
                        : Color(red: 0.58, green: 0.32, blue: 0.88)

                    VStack(alignment: .leading, spacing: 5) {
                        Canvas { context, size in
                            guard size.width > 0, size.height > 0 else { return }
                            let gap: CGFloat = 2
                            let usableW = max(0, size.width - gap)
                            let leftW = max(size.height, min(usableW - size.height, usableW * CGFloat(inputFraction)))
                            let rightW = max(size.height, usableW - leftW)

                            let leftPath = Path(roundedRect: CGRect(x: 0, y: 0, width: leftW, height: size.height), cornerRadius: size.height / 2, style: .continuous)
                            let rightPath = Path(roundedRect: CGRect(x: leftW + gap, y: 0, width: rightW, height: size.height), cornerRadius: size.height / 2, style: .continuous)
                            context.fill(leftPath, with: .color(inputColor))
                            context.fill(rightPath, with: .color(outputColor))
                        }
                        .frame(height: 5)
                        .accessibilityHidden(true)

                        HStack {
                            Text("输入 \(Int((inputFraction * 100).rounded()))%")
                            Spacer()
                            Text("输出 \(100 - Int((inputFraction * 100).rounded()))%")
                        }
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardSurface(cornerRadius: 15)
    }

    private func tokenTile(label: LocalizedStringKey, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value, format: .number)
                .font(.system(size: 13.5, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(colorScheme == .dark ? 0.045 : 0.025),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
    }
}

private struct ActivityContextDetails: View {
    @Environment(\.colorScheme) private var colorScheme
    let session: ActivitySessionSnapshot
    let isFilteredByProject: Bool
    let copiedID: Bool
    let onToggleProjectFilter: () -> Void
    let onCopyID: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("会话详情")
                .font(.system(size: 13, weight: .semibold))

            if !session.projectPath.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.accentColor)
                        Text(session.projectName)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Button(action: onToggleProjectFilter) {
                            Text(isFilteredByProject ? "取消筛选" : "筛选此项目")
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.accentColor)

                        if FileManager.default.fileExists(atPath: session.projectPath) {
                            Button {
                                NSWorkspace.shared.open(URL(fileURLWithPath: session.projectPath))
                            } label: {
                                Label("打开", systemImage: "arrow.up.forward.square")
                                    .font(.system(size: 10.5, weight: .medium))
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                        }
                    }

                    Text(session.abbreviatedProjectPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color.accentColor.opacity(colorScheme == .dark ? 0.10 : 0.055),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.20), lineWidth: 0.6)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("会话 ID")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(action: onCopyID) {
                        Label(copiedID ? "已复制" : "复制", systemImage: copiedID ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(copiedID ? .green : .secondary)
                }
                Text(session.id.uuidString.lowercased())
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.88))
                    .textSelection(.enabled)
            }

            Divider().opacity(0.4)

            ActivityMetadataRow(title: "开始时间", value: session.startedAt.formatted(date: .abbreviated, time: .shortened))
            if let endedAt = session.endedAt {
                ActivityMetadataRow(title: "结束时间", value: endedAt.formatted(date: .abbreviated, time: .shortened))
            }
            if let duration = session.formattedDuration {
                ActivityMetadataRow(title: "持续时长", value: duration)
            }
            if !session.model.isEmpty {
                ActivityMetadataRow(title: "模型", value: session.model, isMonospaced: true)
            }
            if let branch = session.branch, !branch.isEmpty {
                ActivityMetadataRow(title: "分支", value: branch, isMonospaced: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardSurface(cornerRadius: 14)
    }
}

private struct ActivityMetadataRow: View {
    let title: String
    let value: String
    var isMonospaced: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(title))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, design: isMonospaced ? .monospaced : .default))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
