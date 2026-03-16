import SwiftUI
import SwiftData

struct SessionHistoryView: View {
    @Environment(AppStore.self) private var appStore
    @Query(sort: \SessionRecord.startedAt, order: .reverse) private var sessions: [SessionRecord]
    
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var selectedTool: Tool? = nil
    @State private var expandedID: UUID?
    // Cached per-tool session counts for the filter bar — one O(n) pass instead of 8.
    @State private var toolSessionCounts: [Tool: Int] = [:]

    private func rebuildToolCounts() {
        var map: [Tool: Int] = [:]
        for session in sessions { map[session.tool, default: 0] += 1 }
        toolSessionCounts = map
    }

    private var filtered: [SessionRecord] {
        sessions.filter { session in
            let matchesTool = selectedTool == nil || session.tool == selectedTool
            let matchesSearch = debouncedSearchText.isEmpty ||
                session.taskDescription.localizedStandardContains(debouncedSearchText) ||
                session.cwd.localizedStandardContains(debouncedSearchText) ||
                (session.gitBranch?.localizedStandardContains(debouncedSearchText) ?? false)
            return matchesTool && matchesSearch
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Horizontal Filter Bar - Standardized Pills
            ZStack(alignment: .bottom) {
                filterBar
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                Divider()
            }
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    // Tool Deep Analysis (Pop-up context header)
                    if let tool = selectedTool {
                        toolDeepAnalysisHeader(for: tool)
                            .padding(.top, 8)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    
                    // Main Activity List
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(selectedTool == nil ? "所有活动" : "\(selectedTool!.displayName) 活动记录")
                                    .font(.title3.bold())
                                Text("共 \(filtered.count) 条记录")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            searchBar
                                .frame(width: 280)
                        }
                        
                        if filtered.isEmpty {
                            ContentUnavailableView(
                                searchText.isEmpty ? "暂无会话记录" : "未找到匹配会话",
                                systemImage: "doc.text.magnifyingglass",
                                description: Text(searchText.isEmpty ? "开始使用 AI 编程工具后将在此记录详情。" : "请尝试更改搜索词。")
                            )
                            .frame(maxWidth: .infinity, minHeight: 300)
                            .glassEffect(.regular, in: .rect(cornerRadius: 24))
                        } else {
                            LazyVStack(spacing: 12) {
                                ForEach(filtered) { session in
                                    UnifiedSessionRow(
                                        session: session,
                                        isExpanded: expandedID == session.id,
                                        onToggle: {
                                            withAnimation(.spring(duration: 0.3, bounce: 0.2)) {
                                                expandedID = (expandedID == session.id) ? nil : session.id
                                            }
                                        }
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(24)
            }
        }
        .navigationTitle("活动记录")
        .background(Color(NSColor.windowBackgroundColor))
        .task { rebuildToolCounts() }
        .onChange(of: sessions.count) { _, _ in rebuildToolCounts() }
        .task(id: searchText) {
            try? await Task.sleep(for: .milliseconds(300))
            debouncedSearchText = searchText
        }
    }

    // MARK: - Components

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                FilterChip(label: "全部", isSelected: selectedTool == nil) {
                    withAnimation(.spring(duration: 0.3)) { selectedTool = nil }
                }
                ForEach(Tool.allCases, id: \.self) { tool in
                    let count = toolSessionCounts[tool] ?? 0
                    FilterChip(label: "\(tool.displayName) (\(count))", isSelected: selectedTool == tool) {
                        withAnimation(.spring(duration: 0.3)) {
                            selectedTool = (selectedTool == tool) ? nil : tool
                        }
                    }
                }
            }
        }
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
            TextField("搜索任务、项目、分支...", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func toolDeepAnalysisHeader(for tool: Tool) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            let toolSessions = sessions.filter { $0.tool == tool }
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(tool.displayName) 深度分析")
                        .font(.title2.bold())
                    Text("基于近期使用情况的工具效能评估")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                HStack(spacing: 12) {
                    summaryBadge(label: "累计会话", value: "\(toolSessions.count)")
                    summaryBadge(label: "累计 Token", value: toolSessions.reduce(0) { $0 + $1.totalTokens }.compactTokenString)
                }
            }

            switch tool {
            case .antigravity:
                AGAnalysisView(sessions: sessions, range: .month)
            case .copilot:
                CopilotAnalysisView(
                    snapshots: appStore.syncService?.latestCopilotSnapshots,
                    resetAt: appStore.syncService?.latestCopilotResetAt
                )
            case .claudeCode, .codex:
                HStack(spacing: 16) {
                    StatCard(title: "平均消耗", value: (toolSessions.count > 0 ? toolSessions.reduce(0) { $0 + $1.totalTokens } / toolSessions.count : 0).compactTokenString, icon: "chart.bar.fill", color: .blue, isGlass: true)
                    StatCard(title: "最常服务项目", value: favoriteProject(for: toolSessions), icon: "folder.fill", color: .indigo, isGlass: true)
                }
            default:
                EmptyView()
            }
        }
        .padding(24)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.primary.opacity(0.05), lineWidth: 1))
    }

    private func summaryBadge(label: String, value: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(label).font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
            Text(value).font(.system(size: 13, weight: .bold, design: .monospaced))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private func favoriteProject(for toolSessions: [SessionRecord]) -> String {
        var map: [String: Int] = [:]
        for s in toolSessions {
            let name = s.cwd.components(separatedBy: "/").last ?? ""
            if !name.isEmpty { map[name, default: 0] += s.totalTokens }
        }
        return map.sorted { $0.value > $1.value }.first?.key ?? "—"
    }
}
