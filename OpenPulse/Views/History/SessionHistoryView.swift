import SwiftUI
import SwiftData

struct SessionHistoryView: View {
    @Environment(AppStore.self) private var appStore
    @Query(
        filter: #Predicate<SessionRecord> { $0.toolRaw == "codex" || $0.toolRaw == "claude" },
        sort: \SessionRecord.startedAt,
        order: .reverse
    ) private var sessions: [SessionRecord]
    @State private var snapshots: [ActivitySessionSnapshot] = []

    var body: some View {
        // Snapshot model fields here so query updates refresh the browser, while
        // selection and search state do not repeatedly walk every stored session.
        ActivityHistoryBrowser(sessions: snapshots)
            .navigationTitle("活动记录")
            .background(Color(nsColor: .windowBackgroundColor))
            .onChange(of: sessions.map(ActivitySessionSnapshot.init), initial: true) { _, _ in refreshSnapshots() }
            .onChange(of: appStore.syncService?.dataRevision) { _, _ in refreshSnapshots() }
    }

    private func refreshSnapshots() {
        // A service save can precede the @Query merge. Read an independent
        // context on that revision so in-place token updates reach this view.
        let context = ModelContext(appStore.modelContainer)
        let descriptor = FetchDescriptor<SessionRecord>(
            predicate: #Predicate { $0.toolRaw == "codex" || $0.toolRaw == "claude" },
            sortBy: [SortDescriptor(\SessionRecord.startedAt, order: .reverse)]
        )
        snapshots = ((try? context.fetch(descriptor)) ?? sessions).map(ActivitySessionSnapshot.init)
    }
}

private struct ActivitySessionSnapshot: Identifiable, Equatable {
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

    init(_ record: SessionRecord) {
        id = record.id
        tool = record.tool
        startedAt = record.startedAt
        endedAt = record.endedAt
        inputTokens = record.inputTokens
        outputTokens = record.outputTokens
        cacheReadTokens = record.cacheReadTokens
        cacheWriteTokens = record.cacheWriteTokens
        task = record.taskDescription
        model = record.model
        projectPath = record.cwd
        branch = record.gitBranch
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

private struct ActivityToolSummary {
    var count = 0
    var tokens = 0
    var projectTokens: [String: Int] = [:]
    var favoriteProject: String?

    var averageTokens: Int { count > 0 ? tokens / count : 0 }
}

private struct ActivityHistoryBrowser: View {
    let sessions: [ActivitySessionSnapshot]
    @State private var selectedTool: Tool?
    @State private var search = ""
    @State private var selectedID: UUID?
    @State private var detailIsPresented = false
    @State private var filteredSessions: [ActivitySessionSnapshot] = []
    @State private var sessionsByID: [UUID: ActivitySessionSnapshot] = [:]
    @State private var summaries: [Tool: ActivityToolSummary] = [:]
    @State private var allSummary = ActivityToolSummary()

    private var summary: ActivityToolSummary {
        selectedTool.map { summaries[$0] ?? ActivityToolSummary() } ?? allSummary
    }

    var body: some View {
        GeometryReader { geometry in
            let supportsSplitDetail = geometry.size.width >= 900
            let selectedSession = selectedID.flatMap { sessionsByID[$0] }
            let content = ActivityBrowserContent(
                sessionCount: summary.count,
                totalTokens: summary.tokens,
                averageTokens: summary.averageTokens,
                favoriteProject: summary.favoriteProject,
                selectedTool: $selectedTool,
                search: $search,
                counts: summaries.mapValues(\.count),
                totalCount: allSummary.count,
                sessions: filteredSessions,
                selection: $selectedID,
                hasSessions: !sessions.isEmpty,
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
        .onChange(of: sessions, initial: true) { _, _ in rebuildData() }
        .onChange(of: selectedTool) { _, _ in rebuildFilter() }
        .onChange(of: search) { _, _ in rebuildFilter() }
        .onChange(of: selectedID) { _, selection in detailIsPresented = selection != nil }
    }

    private func rebuildData() {
        var map: [Tool: ActivityToolSummary] = [:]
        var total = ActivityToolSummary()
        var indexed: [UUID: ActivitySessionSnapshot] = [:]
        for session in sessions {
            map[session.tool, default: ActivityToolSummary()].count += 1
            map[session.tool, default: ActivityToolSummary()].tokens += session.totalTokens
            total.count += 1
            total.tokens += session.totalTokens
            if !session.projectPath.isEmpty {
                map[session.tool, default: ActivityToolSummary()].projectTokens[session.projectPath, default: 0] += session.totalTokens
                total.projectTokens[session.projectPath, default: 0] += session.totalTokens
            }
            indexed[session.id] = session
        }
        for tool in map.keys {
            var toolSummary = map[tool] ?? ActivityToolSummary()
            toolSummary.favoriteProject = favoriteProject(in: toolSummary.projectTokens)
            map[tool] = toolSummary
        }
        total.favoriteProject = favoriteProject(in: total.projectTokens)
        summaries = map
        allSummary = total
        sessionsByID = indexed
        rebuildFilter()
    }

    private func favoriteProject(in totals: [String: Int]) -> String? {
        totals.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        }?.key
    }

    private func rebuildFilter() {
        filteredSessions = sessions.filter {
            (selectedTool == nil || $0.tool == selectedTool) && $0.matches(search)
        }
        if let selectedID, !filteredSessions.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
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
    let sessions: [ActivitySessionSnapshot]
    @Binding var selection: UUID?
    let hasSessions: Bool
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
                    sessions: sessions,
                    selection: $selection,
                    isSearching: !search.isEmpty,
                    hasSessions: hasSessions,
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
    let sessions: [ActivitySessionSnapshot]
    @Binding var selection: UUID?
    let isSearching: Bool
    let hasSessions: Bool
    let onOpenDetail: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("会话记录")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(sessions.count) 条记录")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            Divider().padding(.horizontal, 16)
            if sessions.isEmpty {
                ContentUnavailableView(
                    isSearching || hasSessions ? "未找到匹配会话" : "暂无会话记录",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(isSearching || hasSessions ? "请尝试更改搜索词或工具筛选。" : "开始使用 AI 编程工具后将在此记录详情。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(sessions) { session in
                        ActivitySessionRow(session: session)
                            .tag(session.id)
                            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selection = session.id
                                onOpenDetail()
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dashboardSurface()
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
