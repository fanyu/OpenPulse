import SwiftUI

struct LogView: View {
    @State private var logger = AppLogger.shared
    @State private var filterLevel: LogLevel? = nil

    private var displayedEntries: [LogEntry] {
        guard let level = filterLevel else { return logger.entries.reversed() }
        return logger.entries.filter { $0.level == level }.reversed()
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                filterBar
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                Divider()
            }
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("系统日志")
                                .font(.title3.bold())
                            Text("共 \(displayedEntries.count) 条记录")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        
                        Spacer()
                        
                        Button(action: { logger.clear() }) {
                            Label("清除日志", systemImage: "trash")
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.primary.opacity(0.05), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }

                    if displayedEntries.isEmpty {
                        ContentUnavailableView(
                            "暂无日志",
                            systemImage: "scroll",
                            description: Text("应用运行期间的日志信息将显示在这里。")
                        )
                        .frame(maxWidth: .infinity, minHeight: 300)
                        .glassEffect(.regular, in: .rect(cornerRadius: 24))
                    } else {
                        VStack(spacing: 0) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(displayedEntries.enumerated()), id: \.element.id) { index, entry in
                                    ModernLogRowView(entry: entry, isAlternate: index % 2 == 1)
                                }
                            }
                        }
                        .padding(.vertical, 8)
                        .background(Color(NSColor.textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
                        )
                    }
                }
                .padding(24)
            }
        }
        .navigationTitle("日志")
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                FilterChip(label: "全部级别", isSelected: filterLevel == nil) {
                    withAnimation(.spring(duration: 0.3)) { filterLevel = nil }
                }
                
                ForEach(LogLevel.allCases, id: \.self) { level in
                    let count = logger.entries.filter { $0.level == level }.count
                    FilterChip(label: "\(level.rawValue) (\(count))", isSelected: filterLevel == level) {
                        withAnimation(.spring(duration: 0.3)) { filterLevel = level }
                    }
                }
            }
        }
    }
}

private struct ModernLogRowView: View {
    let entry: LogEntry
    let isAlternate: Bool
    
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private var levelColor: Color {
        switch entry.level {
        case .info:    .secondary
        case .warning: .orange
        case .error:   .red
        }
    }
    
    private var levelBgColor: Color {
        switch entry.level {
        case .info:    .clear
        case .warning: .orange.opacity(0.1)
        case .error:   .red.opacity(0.1)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(Self.timeFormatter.string(from: entry.date))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 85, alignment: .leading)

            Text(entry.level.rawValue.prefix(1))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(levelColor)
                .frame(width: 16, height: 16)
                .background(levelColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))

            Text(entry.message)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(entry.level == .error ? .red : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(isAlternate ? Color.primary.opacity(0.02) : Color.clear)
        .background(levelBgColor)
    }
}
