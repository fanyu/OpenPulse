import SwiftUI
import UniformTypeIdentifiers

struct LogView: View {
    @State private var logger = AppLogger.shared
    @State private var filterLevel: LogLevel?
    @State private var searchText = ""
    @State private var isExporting = false
    @State private var exportDocument = LogExportDocument(text: "")
    @State private var exportError: String?

    var body: some View {
        let snapshot = LogPresentationSnapshot(entries: logger.entries, level: filterLevel, search: searchText)

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("系统日志")
                        .font(.system(size: 28, weight: .semibold))
                    Text("查看运行状态，搜索并导出当前日志。")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 14) {
                    LogFilterBar(
                        filterLevel: $filterLevel,
                        totalCount: logger.entries.count,
                        levelCounts: snapshot.levelCounts
                    )

                    HStack(spacing: 16) {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                            TextField("搜索日志", text: $searchText)
                                .textFieldStyle(.plain)
                            if !searchText.isEmpty {
                                Button("清除搜索", systemImage: "xmark.circle.fill") { searchText = "" }
                                    .labelStyle(.iconOnly)
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.system(size: 13))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .dashboardSurface(cornerRadius: 8)

                        Menu {
                            Button("导出日志", systemImage: "square.and.arrow.up") {
                                exportDocument = LogExportDocument(entries: snapshot.entries)
                                isExporting = true
                            }
                            .disabled(snapshot.entries.isEmpty)
                            .help("导出当前筛选结果")

                            Button("清除日志", systemImage: "trash", role: .destructive) {
                                logger.clear()
                            }
                            .disabled(logger.entries.isEmpty)
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 28, height: 28)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("日志操作")
                        .accessibilityLabel("日志操作")
                    }

                    HStack(spacing: 12) {
                        Text("共 \(snapshot.entries.count) 条记录")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("最新记录在前")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    if let exportError {
                        Text(exportError)
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                    }
                }

                if snapshot.entries.isEmpty {
                    LogEmptyState(isFiltered: filterLevel != nil || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(snapshot.entries) { entry in
                            ModernLogRowView(entry: entry)
                        }
                    }
                    .padding(.vertical, 4)
                    .dashboardSurface()
                }
            }
            .frame(maxWidth: 1180, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("日志")
        .background(Color(NSColor.windowBackgroundColor))
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .plainText,
            defaultFilename: "OpenPulse Logs"
        ) { result in
            switch result {
            case .success:
                exportError = nil
            case .failure(let error):
                exportError = error.localizedDescription
            }
        }
    }
}

/// Compute counts and the filtered, newest-first list in one pass.
private struct LogPresentationSnapshot {
    let entries: [LogEntry]
    let levelCounts: [LogLevel: Int]

    init(entries: [LogEntry], level: LogLevel?, search: String) {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var visible: [LogEntry] = []
        var counts: [LogLevel: Int] = [:]
        visible.reserveCapacity(entries.count)
        for entry in entries.reversed() {
            counts[entry.level, default: 0] += 1
            guard level == nil || entry.level == level else { continue }
            guard term.isEmpty || entry.message.localizedStandardContains(term)
                    || entry.level.rawValue.localizedStandardContains(term) else { continue }
            visible.append(entry)
        }
        self.entries = visible
        levelCounts = counts
    }
}

private struct LogFilterBar: View {
    @Binding var filterLevel: LogLevel?
    let totalCount: Int
    let levelCounts: [LogLevel: Int]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                LogFilterButton(label: String(localized: "全部级别"), count: totalCount, isSelected: filterLevel == nil) {
                    filterLevel = nil
                }
                ForEach(LogLevel.allCases, id: \.self) { level in
                    LogFilterButton(label: level.rawValue, count: levelCounts[level, default: 0], isSelected: filterLevel == level) {
                        filterLevel = level
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }
}

private struct LogFilterButton: View {
    let label: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                Text(count, format: .number)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct LogEmptyState: View {
    let isFiltered: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: isFiltered ? "magnifyingglass" : "scroll")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text(isFiltered ? String(localized: "没有匹配的日志") : String(localized: "暂无日志"))
                .font(.system(size: 15, weight: .medium))
            Text(isFiltered ? String(localized: "试试其他关键词或日志级别。") : String(localized: "应用运行期间的日志信息将显示在这里。"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .dashboardSurface()
    }
}

private struct ModernLogRowView: View {
    let entry: LogEntry

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private var levelColor: Color {
        switch entry.level {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(Self.timeFormatter.string(from: entry.date))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(entry.level.rawValue)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(levelColor)
                Spacer(minLength: 0)
            }
            Text(entry.message)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.45).padding(.horizontal, 18)
        }
    }
}

private struct LogExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String

    init(text: String) { self.text = text }

    init(entries: [LogEntry]) {
        text = entries.map { "\($0.date.ISO8601Format()) [\($0.level.rawValue)] \($0.message)" }
            .joined(separator: "\n") + "\n"
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
