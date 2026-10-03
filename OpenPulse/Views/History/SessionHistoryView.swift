import SwiftUI
import SwiftData
import Observation
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
    var projectName: String { URL(fileURLWithPath: projectPath).lastPathComponent }

    func matches(_ search: String) -> Bool {
        search.isEmpty || task.localizedStandardContains(search) ||
            projectPath.localizedStandardContains(search) ||
            (branch?.localizedStandardContains(search) ?? false)
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

    static let empty = ActivityHistorySnapshot()

    private init() {
        sessions = []
        sessionsByID = [:]
        sessionsByTool = [:]
        summaries = [:]
        allSummary = ActivityToolSummary()
    }

    init(sessions: [ActivitySessionSnapshot]) throws {
        let interval = ActivityHistoryPerformance.signposter.beginInterval("ActivityHistoryAggregate", id: ActivityHistoryPerformance.signposter.makeSignpostID())
        defer { ActivityHistoryPerformance.signposter.endInterval("ActivityHistoryAggregate", interval) }
        var indexed: [UUID: ActivitySessionSnapshot] = [:]
        indexed.reserveCapacity(sessions.count)
        var byTool: [Tool: [ActivitySessionSnapshot]] = [:]
        var toolSummaries: [Tool: ActivityToolSummary] = [:]
        var projectTokens: [Tool: [String: Int]] = [:]
        var allProjectTokens: [String: Int] = [:]
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
                allProjectTokens[session.projectPath, default: 0] += session.totalTokens
            }
        }
        for tool in toolSummaries.keys {
            toolSummaries[tool]?.favoriteProject = Self.favoriteProject(in: projectTokens[tool] ?? [:])
        }
        total.favoriteProject = Self.favoriteProject(in: allProjectTokens)
        self.sessions = sessions
        sessionsByID = indexed
        sessionsByTool = byTool
        summaries = toolSummaries
        allSummary = total
    }

    func filtered(tool: Tool?, search: String) throws -> ActivityHistoryFilterResult {
        let interval = ActivityHistoryPerformance.signposter.beginInterval("ActivityHistoryFilter", id: ActivityHistoryPerformance.signposter.makeSignpostID())
        defer { ActivityHistoryPerformance.signposter.endInterval("ActivityHistoryFilter", interval) }
        let candidates = tool.map { sessionsByTool[$0] ?? [] } ?? sessions
        if search.isEmpty { return try ActivityHistoryFilterResult(sessions: candidates) }
        var matches: [ActivitySessionSnapshot] = []
        for (index, session) in candidates.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            if session.matches(search) { matches.append(session) }
        }
        return try ActivityHistoryFilterResult(sessions: matches)
    }

    private static func favoriteProject(in totals: [String: Int]) -> String? {
        totals.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        }?.key
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
            predicate: #Predicate { $0.toolRaw == "codex" || $0.toolRaw == "claude" },
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

    @discardableResult
    func reload(container: ModelContainer) -> Task<Void, Never> {
        reload {
            // This closure executes inside the detached worker below. Creating
            // the actor here gives it a fresh background ModelContext per read.
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
                self.isLoading = false
                self.reloadError = nil
                self.filter(tool: self.latestFilterTool, search: self.latestFilterSearch)
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
        using operation: @escaping @Sendable (ActivityHistorySnapshot, Tool?, String) async throws -> ActivityHistoryFilterResult = { snapshot, tool, search in
            try snapshot.filtered(tool: tool, search: search)
        }
    ) -> Task<Void, Never> {
        latestFilterTool = tool
        latestFilterSearch = search
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
                self.appliedFilter = ActivityHistoryFilterIdentity(tool: tool, search: search)
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

private struct ActivityHistoryBrowser: View {
    let history: ActivityHistoryModel
    @State private var selectedTool: Tool?
    @State private var search = ""
    @State private var selectedID: UUID?
    @State private var detailIsPresented = false

    private var summary: ActivityToolSummary {
        selectedTool.map { history.snapshot.summaries[$0] ?? ActivityToolSummary() } ?? history.snapshot.allSummary
    }

    var body: some View {
        GeometryReader { geometry in
            let supportsSplitDetail = geometry.size.width >= 900
            let selectedSession = selectedID.flatMap { history.snapshot.sessionsByID[$0] }
            let content = ActivityBrowserContent(
                sessionCount: summary.count,
                totalTokens: summary.tokens,
                averageTokens: summary.averageTokens,
                favoriteProject: summary.favoriteProject,
                selectedTool: $selectedTool,
                search: $search,
                counts: history.snapshot.summaries.mapValues(\.count),
                totalCount: history.snapshot.allSummary.count,
                result: history.filtered,
                filterIdentity: history.appliedFilter,
                selection: $selectedID,
                hasSessions: !history.snapshot.sessions.isEmpty,
                isLoading: history.isLoading || history.isFiltering,
                onOpenDetail: { detailIsPresented = true }
            )
            HSplitView {
                content.frame(minWidth: supportsSplitDetail && detailIsPresented && selectedSession != nil ? 540 : 0)
                if supportsSplitDetail, detailIsPresented, let session = selectedSession {
                    ActivitySessionDetail(session: session) { detailIsPresented = false }
                        .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
                }
            }
            .sheet(isPresented: Binding(
                get: { detailIsPresented && !supportsSplitDetail && selectedSession != nil },
                set: { if !$0 && !supportsSplitDetail { detailIsPresented = false } }
            )) {
                if let session = selectedSession {
                    ActivitySessionDetail(session: session) { detailIsPresented = false }
                        .frame(minWidth: 420, idealWidth: 480, maxWidth: 600, minHeight: 400, idealHeight: 560, maxHeight: 720)
                }
            }
        }
        .onChange(of: selectedTool) { _, _ in history.filter(tool: selectedTool, search: search) }
        .onChange(of: search) { _, _ in history.filter(tool: selectedTool, search: search) }
        .onChange(of: history.filterRevision) { _, _ in
            if let selectedID, !history.filtered.visibleIDs.contains(selectedID) { self.selectedID = nil }
        }
        .onChange(of: selectedID) { _, selection in detailIsPresented = selection != nil }
    }
}

private struct ActivityBrowserContent: View {
    let sessionCount: Int
    let totalTokens: Int
    let averageTokens: Int
    let favoriteProject: String?
    @Binding var selectedTool: Tool?
    @Binding var search: String
    let counts: [Tool: Int]
    let totalCount: Int
    let result: ActivityHistoryFilterResult
    let filterIdentity: ActivityHistoryFilterIdentity
    @Binding var selection: UUID?
    let hasSessions: Bool
    let isLoading: Bool
    let onOpenDetail: () -> Void

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 22) {
                ActivityPageHeader()
                ActivitySummaryView(
                    sessionCount: sessionCount,
                    totalTokens: totalTokens,
                    averageTokens: averageTokens,
                    favoriteProject: favoriteProject,
                    tool: selectedTool,
                    isWide: geometry.size.width >= 740
                )
                ActivityFilterBar(
                    selectedTool: $selectedTool,
                    search: $search,
                    counts: counts,
                    totalCount: totalCount,
                    isWide: geometry.size.width >= 680,
                    usesSegmentedPicker: geometry.size.width >= 600
                )
                ActivitySessionList(
                    result: result,
                    filterIdentity: filterIdentity,
                    selection: $selection,
                    isSearching: !search.isEmpty,
                    hasSessions: hasSessions,
                    isLoading: isLoading,
                    onOpenDetail: onOpenDetail
                )
            }
            .padding(geometry.size.width < 760 ? 20 : 28)
        }
    }
}

private struct ActivityPageHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("活动记录")
                .font(.system(size: 28, weight: .semibold))
                .tracking(-0.6)
            Text("浏览任务、项目与每次会话的 Token 用量")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }
}

private struct ActivitySummaryView: View {
    let sessionCount: Int
    let totalTokens: Int
    let averageTokens: Int
    let favoriteProject: String?
    let tool: Tool?
    let isWide: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            DashboardSectionTitle(
                title: tool?.displayName ?? String(localized: "所有活动"),
                subtitle: String(localized: "累计会话统计")
            )
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: isWide ? 4 : 2), alignment: .leading, spacing: 18) {
                DashboardMetric(title: "累计会话", value: sessionCount.formatted())
                DashboardMetric(title: "累计 Token", value: totalTokens.compactTokenString)
                DashboardMetric(title: "平均消耗", value: averageTokens.compactTokenString)
                ActivityFavoriteProject(path: favoriteProject)
            }
        }
        .padding(20)
        .dashboardSurface()
    }
}

private struct ActivityFavoriteProject: View {
    let path: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最常服务项目")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "—")
                .font(.system(size: 19, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text("按 Token 用量")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(path ?? "")
    }
}

private struct ActivityFilterBar: View {
    @Binding var selectedTool: Tool?
    @Binding var search: String
    let counts: [Tool: Int]
    let totalCount: Int
    let isWide: Bool
    let usesSegmentedPicker: Bool

    var body: some View {
        let layout = isWide ? AnyLayout(HStackLayout(spacing: 18)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
        layout {
            if usesSegmentedPicker {
                ActivityToolPicker(selectedTool: $selectedTool, counts: counts, totalCount: totalCount)
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: isWide ? 430 : .infinity)
            } else {
                ActivityToolPicker(selectedTool: $selectedTool, counts: counts, totalCount: totalCount)
                    .pickerStyle(.menu)
                    .fixedSize(horizontal: true, vertical: false)
            }
            ActivitySearchField(search: $search)
                .frame(maxWidth: .infinity)
        }
    }
}

private struct ActivityToolPicker: View {
    @Binding var selectedTool: Tool?
    let counts: [Tool: Int]
    let totalCount: Int

    var body: some View {
        Picker("工具", selection: $selectedTool) {
            Text("全部 (\(totalCount))").tag(nil as Tool?)
            ForEach([Tool.codex, Tool.claudeCode], id: \.self) { tool in
                Text("\(tool.displayName) (\(counts[tool] ?? 0))").tag(tool as Tool?)
            }
        }
    }
}

private struct ActivitySearchField: View {
    @Binding var search: String
    @State private var text = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索任务、项目、分支...", text: $text)
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
                .help("清除搜索")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: text) {
            do {
                try await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                search = text.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch { }
        }
    }
}

private struct ActivitySessionList: View {
    let result: ActivityHistoryFilterResult
    let filterIdentity: ActivityHistoryFilterIdentity
    @Binding var selection: UUID?
    let isSearching: Bool
    let hasSessions: Bool
    let isLoading: Bool
    let onOpenDetail: () -> Void
    @State private var renderWindow = ActivitySessionRenderWindow()
    @State private var renderedFilterIdentity: ActivityHistoryFilterIdentity?
    @State private var renderedResultID: ObjectIdentifier?
    @State private var viewportID = UUID()

    var body: some View {
        let total = result.sessions.count
        let visibleCount = renderWindow.visibleCount(total: total)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("会话记录")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
                if visibleCount < total {
                    Button("显示全部") { renderWindow.revealAll(total: total) }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                }
                Text("\(total) 条记录")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            Divider().padding(.horizontal, 16)
            if result.sessions.isEmpty {
                VStack {
                    if isLoading {
                        ProgressView()
                    } else {
                        ContentUnavailableView(
                            isSearching || hasSessions ? "未找到匹配会话" : "暂无会话记录",
                            systemImage: "doc.text.magnifyingglass",
                            description: Text(isSearching || hasSessions ? "请尝试更改搜索词或工具筛选。" : "开始使用 AI 编程工具后将在此记录详情。")
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { viewport in
                    let viewportSize = viewport.size
                    let coordinateSpace = viewportID
                    let resultID = ObjectIdentifier(result)
                    List(selection: $selection) {
                        ForEach(result.sessions.prefix(visibleCount)) { session in
                            ActivitySessionRow(session: session)
                                .tag(session.id)
                                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selection = session.id
                                    onOpenDetail()
                                }
                        }
                        if visibleCount < total {
                            HStack {
                                Spacer()
                                Button("显示更多会话") {
                                    renderWindow.revealNext(total: total, boundary: visibleCount)
                                }
                                .buttonStyle(.link)
                                Spacer()
                            }
                            .padding(.vertical, 12)
                            .listRowSeparator(.hidden)
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
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .coordinateSpace(name: coordinateSpace)
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
}

private struct ActivitySessionRow: View {
    let session: ActivitySessionSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ToolLogoImage(tool: session.tool, size: 24)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                Text(session.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(session.startedAt, format: .dateTime.month().day().hour().minute())
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    if !session.projectPath.isEmpty {
                        Text("·").foregroundStyle(.tertiary)
                        Text(session.projectName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 6) {
                Text(session.totalTokens.compactTokenString)
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                if let branch = session.branch, !branch.isEmpty {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .lineLimit(1)
                } else if !session.model.isEmpty {
                    Text(session.model).lineLimit(1)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: 160, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct ActivitySessionDetail: View {
    let session: ActivitySessionSnapshot
    let onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        ToolLogoImage(tool: session.tool, size: 24)
                        Text(session.tool.displayName)
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .medium))
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.borderless)
                        .keyboardShortcut(.cancelAction)
                        .foregroundStyle(.secondary)
                        .help("关闭详情")
                        .accessibilityLabel("关闭详情")
                    }
                    Text(session.title)
                        .font(.system(size: 17, weight: .semibold))
                        .textSelection(.enabled)
                }
                ActivityTokenDetails(
                    input: session.inputTokens,
                    output: session.outputTokens,
                    cacheRead: session.cacheReadTokens,
                    cacheWrite: session.cacheWriteTokens
                )
                ActivityContextDetails(
                    startedAt: session.startedAt,
                    endedAt: session.endedAt,
                    model: session.model,
                    projectPath: session.projectPath,
                    branch: session.branch
                )
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct ActivityTokenDetails: View {
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DashboardSectionTitle(title: String(localized: "Token 明细"))
            ActivityTokenDetailRow(title: "Input", tokens: input)
            ActivityTokenDetailRow(title: "Output", tokens: output)
            ActivityTokenDetailRow(title: "Cache Read", tokens: cacheRead)
            ActivityTokenDetailRow(title: "Cache Write", tokens: cacheWrite)
        }
    }
}

private struct ActivityTokenDetailRow: View {
    let title: String
    let tokens: Int

    var body: some View {
        HStack {
            Text(LocalizedStringKey(title)).foregroundStyle(.secondary)
            Spacer()
            Text(tokens, format: .number).monospacedDigit()
        }
        .font(.system(size: 12))
    }
}

private struct ActivityContextDetails: View {
    let startedAt: Date
    let endedAt: Date?
    let model: String
    let projectPath: String
    let branch: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            DashboardSectionTitle(title: String(localized: "会话详情"))
            ActivityMetadataRow(title: "开始时间", value: startedAt.formatted(date: .abbreviated, time: .shortened))
            if let endedAt {
                ActivityMetadataRow(title: "结束时间", value: endedAt.formatted(date: .abbreviated, time: .shortened))
            }
            if !model.isEmpty { ActivityMetadataRow(title: "模型", value: model) }
            if !projectPath.isEmpty { ActivityMetadataRow(title: "项目路径", value: projectPath) }
            if let branch, !branch.isEmpty { ActivityMetadataRow(title: "分支", value: branch) }
        }
    }
}

private struct ActivityMetadataRow: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(LocalizedStringKey(title))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
