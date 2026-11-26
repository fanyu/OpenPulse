import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct EmbeddedLogPanel: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var logger = AppLogger.shared
    @State private var filterLevel: LogLevel?
    @State private var searchText = ""
    @State private var isExporting = false
    @State private var exportDocument = LogExportDocument(text: "")
    @State private var exportError: String?

    var body: some View {
        let snapshot = LogPresentationSnapshot(entries: logger.entries, level: filterLevel, search: searchText)

        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    LogFilterBar(
                        filterLevel: $filterLevel,
                        totalCount: logger.entries.count,
                        levelCounts: snapshot.levelCounts
                    )
                    Spacer(minLength: 8)

                    HStack(spacing: 6) {
                        Button {
                            openLogsFolder()
                        } label: {
                            Image(systemName: "folder")
                                .font(.system(size: 11, weight: .medium))
                                .frame(width: 28, height: 28)
                                .background(
                                    Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.045),
                                    in: Circle()
                                )
                                .overlay {
                                    Circle()
                                        .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08), lineWidth: 0.5)
                                }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                        .focusEffectDisabled()
                        .help("在 Finder 中打开持久日志目录")
                        .accessibilityLabel("在 Finder 中打开持久日志目录")

                        Button {
                            exportDocument = LogExportDocument(entries: snapshot.entries)
                            isExporting = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 10.5, weight: .semibold))
                                Text("导出")
                                    .font(.system(size: 11.5, weight: .medium))
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(
                                Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.045),
                                in: Capsule()
                            )
                            .overlay {
                                Capsule()
                                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08), lineWidth: 0.5)
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                        .focusEffectDisabled()
                        .disabled(snapshot.entries.isEmpty)
                        .opacity(snapshot.entries.isEmpty ? 0.45 : 1)
                        .help("导出当前筛选结果")

                        Button(role: .destructive) {
                            logger.clear()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "trash")
                                    .font(.system(size: 10.5, weight: .semibold))
                                Text("清除")
                                    .font(.system(size: 11.5, weight: .medium))
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(
                                Color.red.opacity(colorScheme == .dark ? 0.15 : 0.08),
                                in: Capsule()
                            )
                            .overlay {
                                Capsule()
                                    .strokeBorder(Color.red.opacity(colorScheme == .dark ? 0.28 : 0.18), lineWidth: 0.5)
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .focusEffectDisabled()
                        .disabled(logger.entries.isEmpty)
                        .opacity(logger.entries.isEmpty ? 0.45 : 1)
                        .help("清除内存中的运行日志")
                    }
                }

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索日志", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button("清除搜索", systemImage: "xmark.circle.fill") { searchText = "" }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 12.5))
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(
                    Color.primary.opacity(colorScheme == .dark ? 0.055 : 0.035),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.085), lineWidth: 0.75)
                }

                HStack(spacing: 12) {
                    Text("共 \(snapshot.entries.count) 条记录")
                        .font(.system(size: 11.5))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("最新记录在前")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
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
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(snapshot.entries.enumerated()), id: \.element.id) { index, entry in
                            ModernLogRowView(
                                entry: entry,
                                showDivider: index < snapshot.entries.count - 1
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 420)
                .scrollEdgeEffectStyle(.soft, for: .vertical)
                .background(
                    Color.primary.opacity(colorScheme == .dark ? 0.035 : 0.022),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.075), lineWidth: 0.75)
                }
            }
        }
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

    private func openLogsFolder() {
        let dir = logger.logsDirectoryURL
        if FileManager.default.fileExists(atPath: dir.path) {
            NSWorkspace.shared.open(dir)
        } else {
            let parent = dir.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: parent.path) {
                NSWorkspace.shared.open(parent)
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
    @Environment(\.colorScheme) private var colorScheme
    @Binding var filterLevel: LogLevel?
    let totalCount: Int
    let levelCounts: [LogLevel: Int]
    @Namespace private var thumbNamespace

    private func levelTint(_ level: LogLevel?) -> Color {
        switch level {
        case nil:      .accentColor
        case .info:    .secondary
        case .warning: .orange
        case .error:   .red
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                LogFilterButton(
                    label: String(localized: "全部级别"),
                    count: totalCount,
                    tint: levelTint(nil),
                    isSelected: filterLevel == nil,
                    thumbNamespace: thumbNamespace
                ) {
                    withAnimation(.smooth(duration: 0.2)) {
                        filterLevel = nil
                    }
                }
                ForEach(LogLevel.allCases, id: \.self) { level in
                    LogFilterButton(
                        label: level.rawValue,
                        count: levelCounts[level, default: 0],
                        tint: levelTint(level),
                        isSelected: filterLevel == level,
                        thumbNamespace: thumbNamespace
                    ) {
                        withAnimation(.smooth(duration: 0.2)) {
                            filterLevel = level
                        }
                    }
                }
            }
            .padding(3)
            .background(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.055), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08), lineWidth: 0.5)
            }
        }
    }
}

private struct LogFilterButton: View {
    @Environment(\.colorScheme) private var colorScheme
    let label: String
    let count: Int
    let tint: Color
    let isSelected: Bool
    let thumbNamespace: Namespace.ID
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(label)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? .primary : (isHovered ? .primary : .secondary))
                Text(count, format: .number)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isSelected ? tint : .secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        (isSelected ? tint : Color.primary).opacity(colorScheme == .dark ? 0.16 : 0.08),
                        in: Capsule()
                    )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                if isSelected {
                    Capsule()
                        .fill(colorScheme == .dark ? Color.white.opacity(0.16) : Color.white)
                        .overlay {
                            Capsule()
                                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.06), lineWidth: 0.5)
                        }
                        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.07), radius: 2, y: 1)
                        .matchedGeometryEffect(id: "logFilterThumb", in: thumbNamespace)
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
            isHovered = hovering
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct LogEmptyState: View {
    @Environment(\.colorScheme) private var colorScheme
    let isFiltered: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: isFiltered ? "magnifyingglass" : "scroll")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.secondary)
            Text(isFiltered ? String(localized: "没有匹配的日志") : String(localized: "暂无日志"))
                .font(.system(size: 13.5, weight: .medium))
            Text(isFiltered ? String(localized: "试试其他关键词或日志级别。") : String(localized: "应用运行期间的日志信息将显示在这里。"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .background(
            Color.primary.opacity(colorScheme == .dark ? 0.035 : 0.022),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.065), lineWidth: 0.75)
        }
    }
}

private struct ModernLogRowView: View {
    @Environment(\.colorScheme) private var colorScheme
    let entry: LogEntry
    var showDivider: Bool = true
    @State private var isHovered = false
    @State private var didCopy = false

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private var levelColor: Color {
        switch entry.level {
        case .info:    .secondary
        case .warning: .orange
        case .error:   .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(Self.timeFormatter.string(from: entry.date))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)

                Text(entry.level.rawValue)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(levelColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(
                        levelColor.opacity(colorScheme == .dark ? 0.18 : 0.11),
                        in: Capsule()
                    )

                Spacer(minLength: 0)

                if isHovered || didCopy {
                    Button {
                        let line = "\(entry.date.ISO8601Format()) [\(entry.level.rawValue)] \(entry.message)"
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(line, forType: .string)
                        didCopy = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.2))
                            didCopy = false
                        }
                    } label: {
                        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(didCopy ? .green : .secondary)
                            .frame(width: 22, height: 22)
                            .background(
                                Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05),
                                in: Circle()
                            )
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help(didCopy ? String(localized: "已复制") : String(localized: "复制此条日志"))
                    .accessibilityLabel("复制此条日志")
                }
            }

            Text(entry.message)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(
            isHovered
                ? Color.primary.opacity(colorScheme == .dark ? 0.04 : 0.025)
                : Color.clear
        )
        .overlay(alignment: .bottom) {
            if showDivider {
                TelemetryHairline(opacity: colorScheme == .dark ? 0.08 : 0.055)
                    .padding(.horizontal, 16)
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
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
