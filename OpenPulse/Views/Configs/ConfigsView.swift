import SwiftUI
import AppKit
import WebKit

// MARK: - Data model

struct ConfigFile: Identifiable, Hashable {
    let id: String
    let toolName: String
    let displayName: String
    let url: URL
    let kind: ConfigFileKind

    enum ConfigFileKind { case config, prompt }

    var isJSON: Bool     { url.pathExtension.lowercased() == "json" }
    var isTOML: Bool     { url.pathExtension.lowercased() == "toml" }
    var isMarkdown: Bool { ["md", "markdown"].contains(url.pathExtension.lowercased()) }

    var kindIcon: String {
        switch kind {
        case .config: "doc.text"
        case .prompt: "text.quote"
        }
    }

    var kindColor: Color {
        switch kind {
        case .config: .blue
        case .prompt: .purple
        }
    }

    static func primaryConfig(for tool: Tool) -> ConfigFile? {
        allConfigFiles.first {
            $0.tool == tool && $0.kind == .config
        }
    }

    var tool: Tool? {
        switch toolName {
        case "Codex": .codex
        case "Claude Code": .claudeCode
        case "OpenCode": .opencode
        case "Antigravity": .antigravity
        case "Copilot": .copilot
        default: nil
        }
    }
}

// MARK: - Static catalog

private let home = URL.homeDirectory

private let allConfigFiles: [ConfigFile] = [
    ConfigFile(id: "codex-config",    toolName: "Codex",       displayName: "config.toml",   url: home.appending(path: ".codex/config.toml"),                  kind: .config),
    ConfigFile(id: "codex-agents",    toolName: "Codex",       displayName: "AGENTS.md",     url: home.appending(path: ".codex/AGENTS.md"),                    kind: .prompt),
    ConfigFile(id: "claude-settings", toolName: "Claude Code", displayName: "settings.json", url: home.appending(path: ".claude/settings.json"),               kind: .config),
    ConfigFile(id: "claude-md",       toolName: "Claude Code", displayName: "CLAUDE.md",     url: home.appending(path: ".claude/CLAUDE.md"),                   kind: .prompt),
    ConfigFile(id: "opencode-json",   toolName: "OpenCode",    displayName: "opencode.json", url: home.appending(path: ".config/opencode/opencode.json"),      kind: .config),
    ConfigFile(id: "ag-settings",     toolName: "Antigravity", displayName: "settings.json", url: home.appending(path: ".gemini/settings.json"),               kind: .config),
    ConfigFile(id: "ag-gemini-md",    toolName: "Antigravity", displayName: "GEMINI.md",     url: home.appending(path: ".gemini/GEMINI.md"),                   kind: .prompt),
    ConfigFile(id: "copilot-config",  toolName: "Copilot",     displayName: "config.json",   url: home.appending(path: ".config/github-copilot/config.json"),  kind: .config),
]

// MARK: - Line diff helpers

enum LineDiffKind { case equal, inserted, deleted }

struct LineDiff {
    let kind: LineDiffKind
    let line: String
}

private func lineDiff(original: String, modified: String) -> (left: [LineDiff], right: [LineDiff]) {
    let origLines = original.components(separatedBy: "\n")
    let modLines  = modified.components(separatedBy: "\n")
    let diff = modLines.difference(from: origLines)
    var removed = Set<Int>()
    var inserted = Set<Int>()
    for change in diff {
        switch change {
        case .remove(let offset, _, _): removed.insert(offset)
        case .insert(let offset, _, _): inserted.insert(offset)
        }
    }
    let leftDiffs  = origLines.enumerated().map { LineDiff(kind: removed.contains($0.offset)  ? .deleted  : .equal, line: $0.element) }
    let rightDiffs = modLines.enumerated().map  { LineDiff(kind: inserted.contains($0.offset) ? .inserted : .equal, line: $0.element) }
    return (leftDiffs, rightDiffs)
}

// MARK: - Format helpers

private func prettyPrintJSON(_ text: String) -> String? {
    guard let data = text.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data),
          let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
          let result = String(data: pretty, encoding: .utf8) else { return nil }
    return result
}

private func jsonError(_ text: String) -> String? {
    guard !text.isEmpty, let data = text.data(using: .utf8) else { return nil }
    do { _ = try JSONSerialization.jsonObject(with: data); return nil }
    catch { return error.localizedDescription }
}

// MARK: - Supporting types

struct CursorPosition { var line: Int = 1; var column: Int = 1 }

enum MarkdownMode: String { case edit, split, preview }

// MARK: - View Model

@Observable
final class ConfigsViewModel {
    var selectedFile: ConfigFile? {
        didSet {
            showDiff = false
            loadFile(selectedFile)
        }
    }
    var editorContent: String = ""
    var savedContent: String = ""
    var isDirty: Bool = false
    var showDiff: Bool = false
    var loadError: String?
    var saveError: String?
    var lastSavedTime: Date?
    var cursorPosition = CursorPosition()
    var searchText: String = ""
    var markdownModeRaw: String = MarkdownMode.split.rawValue

    func loadFile(_ file: ConfigFile?) {
        isDirty = false; saveError = nil; lastSavedTime = nil; loadError = nil
        editorContent = ""; savedContent = ""
        cursorPosition = CursorPosition()
        guard let file else { return }
        guard FileManager.default.fileExists(atPath: file.url.path) else {
            loadError = "文件不存在"; return
        }
        do {
            let text = try String(contentsOf: file.url, encoding: .utf8)
            editorContent = text; savedContent = text
        } catch {
            loadError = error.localizedDescription
        }
    }

    func saveFile(_ file: ConfigFile) {
        saveError = nil
        let backupURL = file.url.appendingPathExtension("bak")
        if FileManager.default.fileExists(atPath: file.url.path) {
            try? FileManager.default.copyItem(at: file.url, to: backupURL)
        }
        do {
            try editorContent.write(to: file.url, atomically: true, encoding: .utf8)
            savedContent = editorContent; isDirty = false; showDiff = false; lastSavedTime = Date()
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        } catch {
            saveError = "保存失败：\(error.localizedDescription)"
        }
    }

    func createFile(_ file: ConfigFile) {
        do {
            try FileManager.default.createDirectory(
                at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "".write(to: file.url, atomically: true, encoding: .utf8)
            loadFile(file)
        } catch {
            loadError = "创建失败：\(error.localizedDescription)"
        }
    }

    func revert() {
        editorContent = savedContent; isDirty = false; showDiff = false; saveError = nil
    }

    func formatJSON() {
        guard let formatted = prettyPrintJSON(editorContent) else { return }
        editorContent = formatted
    }

    var filteredGroupedFiles: [(tool: String, files: [ConfigFile])] {
        var seen: [String] = []
        var map: [String: [ConfigFile]] = [:]
        for f in allConfigFiles {
            if searchText.isEmpty || f.displayName.localizedCaseInsensitiveContains(searchText) || f.toolName.localizedCaseInsensitiveContains(searchText) {
                if map[f.toolName] == nil { seen.append(f.toolName) }
                map[f.toolName, default: []].append(f)
            }
        }
        return seen.map { (tool: $0, files: map[$0]!) }
    }
}

// MARK: - Main view

struct ConfigsView: View {
    @State private var viewModel = ConfigsViewModel()
    @Namespace private var tabNamespace

    @AppStorage("configs.wordWrap")     private var wordWrap: Bool   = true
    @AppStorage("configs.fontSize")     private var fontSize: Double = 13.0

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()
            editorSection
        }
        .navigationTitle("配置文件")
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if viewModel.selectedFile == nil {
                viewModel.selectedFile = allConfigFiles.first
            }
        }
        .background { keyboardShortcuts }
    }

    private var headerSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                supplierSelector
                Spacer()
                searchAndFontControls
            }
            fileTabs
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var supplierSelector: some View {
        HStack(spacing: 10) {
            ForEach(["Codex", "Claude Code", "OpenCode", "Antigravity"], id: \.self) { tool in
                let isSelected = viewModel.selectedFile?.toolName == tool
                FilterChip(label: tool, isSelected: isSelected) {
                    withAnimation(.spring(duration: 0.3)) {
                        if let first = allConfigFiles.first(where: { $0.toolName == tool }) {
                            viewModel.selectedFile = first
                        }
                    }
                }
            }
        }
    }

    private var searchAndFontControls: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.tertiary)
                TextField("搜索...", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.8), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.1), lineWidth: 0.5))
            .frame(width: 160)

            HStack(spacing: 8) {
                Button { withAnimation { fontSize = min(fontSize + 1, 28) } } label: { Image(systemName: "plus.magnifyingglass") }
                    .buttonStyle(.plain).help("增大字号")
                Button { withAnimation { fontSize = max(fontSize - 1, 9) } } label: { Image(systemName: "minus.magnifyingglass") }
                    .buttonStyle(.plain).help("减小字号")
            }
        }
        .foregroundStyle(.secondary)
    }

    private var fileTabs: some View {
        Group {
            if let currentTool = viewModel.selectedFile?.toolName {
                HStack(spacing: 4) {
                    ForEach(allConfigFiles.filter({ $0.toolName == currentTool })) { file in
                        let isSelected = viewModel.selectedFile?.id == file.id
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                viewModel.selectedFile = file
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: file.kindIcon)
                                    .font(.system(size: 11))
                                    .foregroundStyle(isSelected ? file.kindColor : .secondary)
                                Text(file.displayName)
                                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(isSelected ? Color(nsColor: .textBackgroundColor) : Color.clear, in: UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6))
                            .overlay(alignment: .bottom) {
                                if isSelected {
                                    Color.accentColor.frame(height: 2).offset(y: 1)
                                        .matchedGeometryEffect(id: "tab_underline", in: tabNamespace)
                                }
                            }
                            .foregroundStyle(isSelected ? .primary : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private var editorSection: some View {
        EditorPanel(
            file: viewModel.selectedFile,
            editorContent: $viewModel.editorContent,
            savedContent: viewModel.savedContent,
            isDirty: $viewModel.isDirty,
            showDiff: $viewModel.showDiff,
            loadError: $viewModel.loadError,
            saveError: $viewModel.saveError,
            lastSavedTime: $viewModel.lastSavedTime,
            cursorPosition: $viewModel.cursorPosition,
            markdownModeRaw: $viewModel.markdownModeRaw,
            wordWrap: $wordWrap,
            fontSize: $fontSize,
            onSave: { viewModel.saveFile($0) },
            onRevert: { viewModel.revert() },
            onFormat: { viewModel.formatJSON() },
            onCreate: { viewModel.createFile($0) }
        )
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private var keyboardShortcuts: some View {
        Group {
            Button("") { withAnimation { fontSize = min(fontSize + 1, 28) } }.keyboardShortcut("+", modifiers: .command)
            Button("") { withAnimation { fontSize = min(fontSize + 1, 28) } }.keyboardShortcut("=", modifiers: .command)
            Button("") { withAnimation { fontSize = max(fontSize - 1, 9) } }.keyboardShortcut("-", modifiers: .command)
        }
        .opacity(0).allowsHitTesting(false)
    }
}

// MARK: - Subviews

struct ConfigFileRow: View {
    let file: ConfigFile
    let isSelected: Bool
    let isDirty: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: file.kindIcon)
                .foregroundStyle(isSelected ? .white : file.kindColor)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 24, height: 24)
                .background(file.kindColor.opacity(isSelected ? 0 : 0.15), in: RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(file.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? .white : .primary)
                
                let ext = file.url.pathExtension.uppercased()
                Text(ext.isEmpty ? "OTHER" : ext)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary.opacity(0.8))
            }

            Spacer()

            if isDirty {
                Circle()
                    .fill(isSelected ? .white : .orange)
                    .frame(width: 7, height: 7)
                    .shadow(color: .black.opacity(0.1), radius: 1)
            }

            if !FileManager.default.fileExists(atPath: file.url.path) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(isSelected ? .white : .orange)
                    .font(.system(size: 11))
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct EditorPanel: View {
    let file: ConfigFile?
    @Binding var editorContent: String
    let savedContent: String
    @Binding var isDirty: Bool
    @Binding var showDiff: Bool
    @Binding var loadError: String?
    @Binding var saveError: String?
    @Binding var lastSavedTime: Date?
    @Binding var cursorPosition: CursorPosition
    @Binding var markdownModeRaw: String
    @Binding var wordWrap: Bool
    @Binding var fontSize: Double

    var onSave: (ConfigFile) -> Void
    var onRevert: () -> Void
    var onFormat: () -> Void
    var onCreate: (ConfigFile) -> Void

    @State private var triggerFind = false

    private var markdownMode: MarkdownMode { MarkdownMode(rawValue: markdownModeRaw) ?? .split }

    var body: some View {
        Group {
            if let file = file {
                VStack(spacing: 0) {
                    EditorToolbar(
                        file: file,
                        isDirty: isDirty,
                        showDiff: $showDiff,
                        markdownModeRaw: $markdownModeRaw,
                        wordWrap: $wordWrap,
                        loadError: loadError,
                        onSave: { onSave(file) },
                        onRevert: onRevert,
                        onFormat: onFormat,
                        onFind: { triggerFind = true }
                    )

                    Divider()

                    ZStack {
                        Color(nsColor: .textBackgroundColor)
                        
                        Group {
                            if let err = loadError {
                                FileNotFoundPanel(file: file, error: err, onCreate: { onCreate(file) })
                            } else if showDiff {
                                DiffPanel(savedContent: savedContent, editorContent: editorContent)
                            } else {
                                EditorArea(
                                    file: file,
                                    content: $editorContent,
                                    savedContent: savedContent,
                                    cursorPosition: $cursorPosition,
                                    triggerFind: $triggerFind,
                                    markdownMode: markdownMode,
                                    fontSize: fontSize,
                                    wordWrap: wordWrap,
                                    isDirty: $isDirty,
                                    saveError: $saveError
                                )
                            }
                        }
                    }
                    .background(Color(nsColor: .textBackgroundColor))

                    Divider()

                    EditorStatusBar(
                        file: file,
                        content: editorContent,
                        savedContent: savedContent,
                        isDirty: isDirty,
                        cursorPosition: cursorPosition,
                        loadError: loadError,
                        saveError: saveError,
                        lastSavedTime: lastSavedTime
                    )
                }
            } else {
                VStack {
                    Spacer()
                    ContentUnavailableView(
                        "选择配置文件",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("从上方选择 Agent 和文件开始编辑。")
                    )
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.3))
            }
        }
    }
}

struct EditorToolbar: View {
    let file: ConfigFile
    let isDirty: Bool
    @Binding var showDiff: Bool
    @Binding var markdownModeRaw: String
    @Binding var wordWrap: Bool
    let loadError: String?
    var onSave: () -> Void
    var onRevert: () -> Void
    var onFormat: () -> Void
    var onFind: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(file.displayName).font(.headline)
                    if isDirty {
                        Text("已修改")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.orange, in: Capsule())
                    }
                }
                Text(file.url.path.replacingOccurrences(of: home.path, with: "~"))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }

            Spacer()

            if file.isMarkdown && loadError == nil {
                Picker("", selection: $markdownModeRaw) {
                    Label("编辑", systemImage: "pencil").tag(MarkdownMode.edit.rawValue)
                    Label("分栏", systemImage: "rectangle.split.2x1").tag(MarkdownMode.split.rawValue)
                    Label("预览", systemImage: "eye").tag(MarkdownMode.preview.rawValue)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
                .controlSize(.small)

                Divider().frame(height: 16)
            }

            HStack(spacing: 8) {
                if loadError == nil {
                    Button(action: onFind) {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.plain)
                    .help("搜索 (⌘F)")
                }

                if file.isJSON && loadError == nil {
                    Button(action: onFormat) {
                        Image(systemName: "text.alignleft")
                    }
                    .buttonStyle(.plain)
                    .help("格式化 JSON (⌥⌘F)")
                    .keyboardShortcut("f", modifiers: [.option, .command])
                }

                Toggle(isOn: $wordWrap) {
                    Image(systemName: "text.word.spacing")
                }
                .toggleStyle(.button)
                .buttonStyle(.plain)
                .help("自动换行")

                if isDirty && loadError == nil {
                    Toggle(isOn: $showDiff) {
                        Image(systemName: "arrow.left.arrow.right")
                    }
                    .toggleStyle(.button)
                    .buttonStyle(.plain)
                    .help("查看差异 (⇧⌘D)")
                    .keyboardShortcut("d", modifiers: [.shift, .command])

                    Button(action: onRevert) {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.plain)
                    .help("还原修改")
                }

                Button(action: { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }) {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .help("在 Finder 中显示")

                Button(action: { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(file.url.path, forType: .string) }) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help("复制路径")
            }
            .foregroundStyle(.secondary)

            Divider().frame(height: 16)

            Button(action: onSave) {
                Text("保存")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!isDirty || loadError != nil)
            .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.bar)
    }
}

struct EditorArea: View {
    let file: ConfigFile
    @Binding var content: String
    let savedContent: String
    @Binding var cursorPosition: CursorPosition
    @Binding var triggerFind: Bool
    let markdownMode: MarkdownMode
    let fontSize: Double
    let wordWrap: Bool
    @Binding var isDirty: Bool
    @Binding var saveError: String?

    var body: some View {
        if file.isMarkdown {
            switch markdownMode {
            case .edit:
                editor
            case .split:
                HSplitView {
                    editor.frame(minWidth: 200)
                    MarkdownPreviewView(source: content).frame(minWidth: 200)
                }
            case .preview:
                MarkdownPreviewView(source: content)
            }
        } else {
            editor
        }
    }

    private var editor: some View {
        ConfigEditor(
            text: $content,
            cursorPosition: $cursorPosition,
            triggerFind: $triggerFind,
            isJSON: file.isJSON,
            isTOML: file.isTOML,
            fontSize: fontSize,
            wordWrap: wordWrap,
            onContentChange: {
                isDirty = content != savedContent
                saveError = nil
            }
        )
    }
}

struct EditorStatusBar: View {
    let file: ConfigFile
    let content: String
    let savedContent: String
    let isDirty: Bool
    let cursorPosition: CursorPosition
    let loadError: String?
    let saveError: String?
    let lastSavedTime: Date?

    var body: some View {
        HStack(spacing: 12) {
            if file.isJSON && loadError == nil {
                if let err = jsonError(content) {
                    Label("JSON 无效: \(err)", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                } else if !content.isEmpty {
                    Label("JSON 有效", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            if let err = saveError {
                Label(err, systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
            }

            Spacer()

            if isDirty {
                let (left, right) = lineDiff(original: savedContent, modified: content)
                let removed = left.filter  { $0.kind == .deleted  }.count
                let added   = right.filter { $0.kind == .inserted }.count
                if removed > 0 || added > 0 {
                    HStack(spacing: 4) {
                        if removed > 0 { Text("−\(removed)").foregroundStyle(.red) }
                        if added   > 0 { Text("+\(added)").foregroundStyle(.green) }
                    }
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    statusDivider
                }
            }

            if let t = lastSavedTime {
                Text("已保存 \(t.formatted(.dateTime.hour().minute().second()))")
                    .foregroundStyle(.secondary)
                statusDivider
            }

            Text("Ln \(cursorPosition.line), Col \(cursorPosition.column)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)

            statusDivider

            Text("\(content.components(separatedBy: .newlines).count) 行")
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .padding(.horizontal, 16).padding(.vertical, 4)
        .background(.bar)
    }

    private var statusDivider: some View {
        Divider().frame(height: 12).padding(.horizontal, 4)
    }
}

struct DiffPanel: View {
    let savedContent: String
    let editorContent: String

    var body: some View {
        let (leftDiffs, rightDiffs) = lineDiff(original: savedContent, modified: editorContent)
        HSplitView {
            DiffColumn(title: "原始版本", diffs: leftDiffs).frame(minWidth: 200)
            DiffColumn(title: "当前修改", diffs: rightDiffs).frame(minWidth: 200)
        }
    }
}

struct DiffColumn: View {
    let title: String
    let diffs: [LineDiff]

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.fill.tertiary)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diffs.enumerated()), id: \.offset) { idx, diff in
                        DiffRow(lineNumber: idx + 1, diff: diff)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

struct DiffRow: View {
    let lineNumber: Int
    let diff: LineDiff

    var body: some View {
        let bg: Color = switch diff.kind {
        case .deleted:  Color.red.opacity(0.12)
        case .inserted: Color.green.opacity(0.12)
        case .equal:    Color.clear
        }
        let prefix: String = switch diff.kind {
        case .deleted: "−"; case .inserted: "+"; case .equal: " "
        }
        let prefixColor: Color = switch diff.kind {
        case .deleted: .red; case .inserted: .green; case .equal: .clear
        }

        HStack(spacing: 0) {
            Text("\(lineNumber)")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                .frame(width: 32, alignment: .trailing).padding(.trailing, 8)
            Text(prefix)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(prefixColor).frame(width: 14)
            Text(diff.line.isEmpty ? " " : diff.line)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(diff.kind == .deleted ? .red : (diff.kind == .inserted ? .green : .primary))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 0.5)
        .background(bg)
    }
}

struct FileNotFoundPanel: View {
    let file: ConfigFile
    let error: String
    var onCreate: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            VStack(spacing: 8) {
                Text("配置文件缺失").font(.headline)
                Text(file.url.path.replacingOccurrences(of: home.path, with: "~"))
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            Button(action: onCreate) {
                Label("立即创建", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

// MARK: - Markdown preview (WKWebView)

struct MarkdownPreviewView: NSViewRepresentable {
    let source: String

    func makeNSView(context: Context) -> WKWebView {
        let wv = WKWebView()
        wv.setValue(false, forKey: "drawsBackground")
        return wv
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard source != context.coordinator.lastSource else { return }
        context.coordinator.lastSource = source
        let encoded = (try? JSONEncoder().encode(source)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        webView.loadHTMLString(markdownHTML(encoded), baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject { var lastSource: String = "" }
}

private func markdownHTML(_ encodedJSON: String) -> String {
    #"""
    <!DOCTYPE html><html><head><meta charset="utf-8"><style>
    :root{color-scheme:light dark}
    body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;font-size:14px;line-height:1.6;
         padding:30px 40px;max-width:800px;margin:0 auto;
         color:light-dark(#1d1d1f,#f5f5f7);background:transparent;word-break:break-word}
    h1,h2,h3,h4,h5,h6{margin:1.5em 0 0.5em;font-weight:600;line-height:1.25}
    h1{font-size:2em;border-bottom:1px solid light-dark(#d1d1d6,#3a3a3c);padding-bottom:.3em}
    h2{font-size:1.5em;border-bottom:1px solid light-dark(#ebebeb,#2c2c2e);padding-bottom:.2em}
    code{font-family:'SF Mono',Menlo,monospace;font-size:.9em;
         background:light-dark(rgba(0,0,0,.05),rgba(255,255,255,.1));
         padding:0.2em 0.4em;border-radius:6px}
    pre{background:light-dark(#f6f8fa,#161b22);
        border:1px solid light-dark(#d0d7de,#30363d);
        border-radius:8px;padding:16px;overflow-x:auto;margin:1em 0}
    pre code{background:none;padding:0;border-radius:0;font-size:.85em}
    blockquote{border-left:4px solid light-dark(#d0d7de,#30363d);
               margin:1em 0;padding:0 1em;
               color:light-dark(#57606a,#8b949e)}
    ul,ol{padding-left:2em}
    a{color:#0969da;text-decoration:none}a:hover{text-decoration:underline}
    hr{height:0.25em;padding:0;margin:24px 0;background-color:light-dark(#d0d7de,#30363d);border:0}
    table{border-collapse:collapse;width:100%;margin:1em 0}
    th,td{border:1px solid light-dark(#d0d7de,#30363d);padding:6px 13px}
    th{background-color:light-dark(#f6f8fa,#161b22);font-weight:600}
    </style></head><body><div id="c"></div><script>
    (function(){
    var src=\#(encodedJSON);
    function esc(s){return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');}
    function inline(s){
      s=esc(s);
      s=s.replace(/`([^`\n]+)`/g,'<code>$1</code>');
      s=s.replace(/\*\*\*(.+?)\*\*\*/g,'<strong><em>$1</em></strong>');
      s=s.replace(/\*\*(.+?)\*\*/g,'<strong>$1</strong>');
      s=s.replace(/\*(.+?)\*/g,'<em>$1</em>');
      s=s.replace(/~~(.+?)~~/g,'<del>$1</del>');
      s=s.replace(/\[([^\]]+)\]\(([^)]+)\)/g,'<a href="$2">$1</a>');
      return s;
    }
    var lines=src.split('\n'),html='',inFence=false,fenceLines=[],inUL=false,inOL=false;
    function closeList(){if(inUL){html+='</ul>';inUL=false;}if(inOL){html+='</ol>';inOL=false;}}
    for(var i=0;i<lines.length;i++){
      var line=lines[i];
      if(/^```/.test(line)){
        if(!inFence){inFence=true;fenceLines=[];closeList();}
        else{html+='<pre><code>'+esc(fenceLines.join('\n'))+'</code></pre>';inFence=false;}
        continue;
      }
      if(inFence){fenceLines.push(line);continue;}
      var hm=line.match(/^(#{1,6}) (.*)/);
      if(hm){closeList();html+='<h'+hm[1].length+'>'+inline(hm[2])+'</h'+hm[1].length+'>';continue;}
      if(/^[-*_]{3,}\s*$/.test(line.trim())&&line.trim().length>=3){closeList();html+='<hr>';continue;}
      if(/^> /.test(line)){closeList();html+='<blockquote><p>'+inline(line.slice(2))+'</p></blockquote>';continue;}
      var ulm=line.match(/^[ \t]*[-*+] (.*)/);
      if(ulm){if(!inUL){if(inOL){html+='</ol>';inOL=false;}html+='<ul>';inUL=true;}html+='<li>'+inline(ulm[1])+'</li>';continue;}
      var olm=line.match(/^[ \t]*\d+\. (.*)/);
      if(olm){if(!inOL){if(inUL){html+='</ul>';inUL=false;}html+='<ol>';inOL=true;}html+='<li>'+inline(olm[1])+'</li>';continue;}
      if(line.trim()===''){closeList();html+='<p></p>';continue;}
      closeList();html+='<p>'+inline(line)+'</p>';
    }
    closeList();
    document.getElementById('c').innerHTML=html;
    })();
    </script></body></html>
    """#
}

// MARK: - Config editor (NSTextView wrapper)

struct ConfigEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var cursorPosition: CursorPosition
    @Binding var triggerFind: Bool
    var isJSON: Bool
    var isTOML: Bool
    var fontSize: Double
    var wordWrap: Bool
    var onContentChange: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        // Prevent ruler from bleeding into header by clipping to bounds
        scrollView.contentView.clipsToBounds = true
        scrollView.clipsToBounds = true
        
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.delegate = context.coordinator
        textView.textStorage?.delegate = context.coordinator
        textView.isEditable = true
        textView.isRichText = false
        textView.font = context.coordinator.currentFont
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        scrollView.drawsBackground = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        // Line numbers
        if let scrollView = textView.enclosingScrollView {
            let gutter = LineNumberGutter(textView: textView)
            scrollView.verticalRulerView = gutter
            scrollView.hasVerticalRuler = true
            scrollView.rulersVisible = true
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        let newFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if textView.font?.pointSize != newFont.pointSize {
            context.coordinator.currentFont = newFont
            textView.font = newFont
            if let ts = textView.textStorage {
                ts.beginEditing()
                Highlighter.apply(to: ts, font: newFont, isJSON: isJSON, isTOML: isTOML)
                ts.endEditing()
            }
        }

        if textView.string != text {
            let sel = textView.selectedRange()
            textView.string = text
            let clamped = NSRange(location: min(sel.location, textView.string.count), length: 0)
            textView.setSelectedRange(clamped)
        }

        if wordWrap {
            textView.textContainer?.widthTracksTextView = true
            textView.isHorizontallyResizable = false
            scrollView.hasHorizontalScroller = false
        } else {
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = CGSize(width: 10_000, height: CGFloat.greatestFiniteMagnitude)
            textView.isHorizontallyResizable = true
            scrollView.hasHorizontalScroller = true
        }

        if triggerFind {
            let item = NSMenuItem()
            item.tag = NSTextFinder.Action.showFindInterface.rawValue
            textView.performFindPanelAction(item)
            let coordinator = context.coordinator
            DispatchQueue.main.async { coordinator.parent.triggerFind = false }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self, font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular))
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: ConfigEditor
        var currentFont: NSFont

        init(parent: ConfigEditor, font: NSFont) {
            self.parent = parent
            self.currentFont = font
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let str = textView.string as NSString
            let sel = textView.selectedRange()
            let lineRange = str.lineRange(for: NSRange(location: sel.location, length: 0))
            let line = str.substring(with: lineRange)
            var indent = ""
            for ch in line { if ch == " " || ch == "\t" { indent.append(ch) } else { break } }
            textView.insertText("\n" + indent, replacementRange: sel)
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            parent.onContentChange()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let loc = tv.selectedRange().location
            let str = tv.string as NSString
            var line = 1, col = 1, i = 0
            while i < loc && i < str.length {
                if str.character(at: i) == 10 { line += 1; col = 1 } else { col += 1 }
                i += 1
            }
            parent.cursorPosition = CursorPosition(line: line, column: col)

            // Redraw gutter to update current line highlight
            tv.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }

        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            Highlighter.apply(to: textStorage, font: currentFont, isJSON: parent.isJSON, isTOML: parent.isTOML)
        }
    }
}

// MARK: - Line Number Gutter

class LineNumberGutter: NSRulerView {
    weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        self.clientView = textView
        self.ruleThickness = 32 // Compacted ruler width
    }

    required init(coder: NSCoder) { fatalError() }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }

        let visibleRect = textView.visibleRect
        let nsString = textView.string as NSString
        let range = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        let firstIndex = layoutManager.characterIndexForGlyph(at: range.location)

        var lineNum = 1
        var idx = 0
        while idx < firstIndex {
            idx = nsString.lineRange(for: NSRange(location: idx, length: 0)).upperBound
            lineNum += 1
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        let selectedRange = textView.selectedRange()
        let currentLineRange = nsString.lineRange(for: NSRange(location: selectedRange.location, length: 0))

        idx = firstIndex
        while idx < NSMaxRange(range) {
            let lineRange = nsString.lineRange(for: NSRange(location: idx, length: 0))
            let rect = layoutManager.lineFragmentUsedRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: idx), effectiveRange: nil)
            let y = rect.origin.y - visibleRect.origin.y + textView.textContainerInset.height

            // Highlight current line number
            var currentAttrs = attributes
            if lineRange.contains(selectedRange.location) || (lineRange.upperBound == selectedRange.location && selectedRange.length == 0) {
                currentAttrs[.foregroundColor] = NSColor.labelColor
                currentAttrs[.font] = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)

                // Draw a subtle background for the current line number
                NSColor.selectedContentBackgroundColor.withAlphaComponent(0.15).set()
                NSRect(x: 0, y: y, width: ruleThickness, height: rect.height).fill()
            }

            let label = "\(lineNum)" as NSString
            let size = label.size(withAttributes: currentAttrs)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y + (rect.height - size.height) / 2), withAttributes: currentAttrs)

            idx = lineRange.upperBound
            lineNum += 1
            if idx == nsString.length && nsString.hasSuffix("\n") { break }
        }
    }
}

// MARK: - Highlighter

private enum Highlighter {
    static func apply(to ts: NSTextStorage, font: NSFont, isJSON: Bool, isTOML: Bool) {
        let str = ts.string
        guard !str.isEmpty else { return }
        let full = NSRange(location: 0, length: ts.length)
        ts.setAttributes([.font: font, .foregroundColor: NSColor.labelColor], range: full)

        if isJSON {
            // Numbers
            color(ts, str, #"-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#, .systemPurple)
            // Keywords
            color(ts, str, #"\b(?:true|false|null)\b"#, .systemTeal)
            // Values (Strings) - including escapes
            color(ts, str, #""([^"\\]|\\.)*""#, .systemOrange)
            // Keys
            color(ts, str, #""([^"\\]|\\.)*"(?=\s*:)"#, .systemBlue)
        } else if isTOML {
            // Comments
            color(ts, str, #"#.*$"#, .systemGray)
            // Sections [section] or [[array]]
            color(ts, str, #"^\[{1,2}.*\]{1,2}"#, .systemBlue)
            // Keys
            color(ts, str, #"^[a-zA-Z0-9_-]+(?=\s*=)"#, .systemTeal)
            // Double-quoted strings
            color(ts, str, #""([^"\\]|\\.)*""#, .systemOrange)
            // Single-quoted strings (literal)
            color(ts, str, #"'[^']*'"#, .systemOrange)
            // Numbers (integers, floats, dates)
            color(ts, str, #"-?\b\d+[\d\-:T.Z]*\b"#, .systemPurple)
            // Booleans
            color(ts, str, #"\b(?:true|false)\b"#, .systemTeal)
        }
    }

    private static func color(_ ts: NSTextStorage, _ str: String, _ pattern: String, _ c: NSColor) {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return }
        re.enumerateMatches(in: str, range: NSRange(location: 0, length: str.utf16.count)) { m, _, _ in
            guard let r = m?.range else { return }
            ts.addAttribute(.foregroundColor, value: c, range: r)
        }
    }
}
