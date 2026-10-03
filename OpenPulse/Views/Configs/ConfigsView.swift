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

    enum ConfigFileKind {
        case config, prompt

        var localizedTitle: LocalizedStringResource {
            switch self {
            case .config: "工具配置"
            case .prompt: "全局规则"
            }
        }
    }

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

@MainActor
@Observable
final class ConfigsViewModel {
    var selectedFile: ConfigFile? {
        didSet {
            guard selectedFile?.id != oldValue?.id else { return }
            showDiff = false
            loadFile(selectedFile)
        }
    }
    var editorContent: String = "" {
        didSet { isDirty = editorContent != savedContent }
    }
    var savedContent: String = "" {
        didSet { isDirty = editorContent != savedContent }
    }
    var isDirty: Bool = false
    var showDiff: Bool = false
    var loadError: String?
    var fileIsMissing = false
    var saveError: String?
    var lastSavedTime: Date?
    var cursorPosition = CursorPosition()
    var searchText: String = ""
    var markdownModeRaw: String = MarkdownMode.split.rawValue

    func loadFile(_ file: ConfigFile?) {
        saveError = nil; lastSavedTime = nil; loadError = nil; fileIsMissing = false
        editorContent = ""; savedContent = ""
        cursorPosition = CursorPosition()
        guard let file else { return }
        do {
            let text = try String(contentsOf: file.url, encoding: .utf8)
            editorContent = text; savedContent = text
        } catch {
            let code = (error as NSError).code
            fileIsMissing = (error as NSError).domain == NSCocoaErrorDomain
                && (code == NSFileReadNoSuchFileError || code == NSFileNoSuchFileError)
            loadError = error.localizedDescription
        }
    }

    @discardableResult
    func saveFile(_ file: ConfigFile) -> Bool {
        guard loadError == nil, selectedFile?.id == file.id else { return false }
        saveError = nil
        let fileManager = FileManager.default
        let backupURL = file.url.appendingPathExtension("bak")
        let temporaryBackupURL = file.url.appendingPathExtension("bak.\(UUID().uuidString).tmp")
        do {
            guard try String(contentsOf: file.url, encoding: .utf8) == savedContent else {
                saveError = String(localized: "文件已在其他位置修改。重新载入后再保存。")
                return false
            }
            // Refresh the backup on every save. Copying preserves the original
            // file's permissions, including restrictive credential-file modes.
            try fileManager.copyItem(at: file.url, to: temporaryBackupURL)
            defer { try? fileManager.removeItem(at: temporaryBackupURL) }
            if fileManager.fileExists(atPath: backupURL.path) {
                _ = try fileManager.replaceItemAt(backupURL, withItemAt: temporaryBackupURL, options: .usingNewMetadataOnly)
            } else {
                try fileManager.moveItem(at: temporaryBackupURL, to: backupURL)
            }
            try editorContent.write(to: file.url, atomically: true, encoding: .utf8)
            savedContent = editorContent; showDiff = false; lastSavedTime = Date()
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            return true
        } catch {
            saveError = String(localized: "保存失败：\(error.localizedDescription)")
            return false
        }
    }

    func createFile(_ file: ConfigFile) {
        do {
            try FileManager.default.createDirectory(
                at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // A file may have appeared since the failed read. Never replace it.
            try Data().write(to: file.url, options: .withoutOverwriting)
            loadFile(file)
        } catch {
            loadError = String(localized: "创建失败：\(error.localizedDescription)")
            fileIsMissing = !FileManager.default.fileExists(atPath: file.url.path)
        }
    }

    func revert() {
        editorContent = savedContent; showDiff = false; saveError = nil
    }

    func formatJSON() {
        guard let formatted = prettyPrintJSON(editorContent) else { return }
        editorContent = formatted
        saveError = nil
    }

    var filteredGroupedFiles: [(tool: String, files: [ConfigFile])] {
        var seen: [String] = []
        var map: [String: [ConfigFile]] = [:]
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        for file in allConfigFiles where query.isEmpty
            || file.displayName.localizedCaseInsensitiveContains(query)
            || file.toolName.localizedCaseInsensitiveContains(query) {
            if map[file.toolName] == nil { seen.append(file.toolName) }
            map[file.toolName, default: []].append(file)
        }
        return seen.map { (tool: $0, files: map[$0]!) }
    }
}

// MARK: - Main view

struct ConfigsView: View {
    @Environment(AppStore.self) private var appStore
    @AppStorage("configs.wordWrap") private var wordWrap = true
    @AppStorage("configs.fontSize") private var fontSize = 13.0
    @State private var pendingFile: ConfigFile?
    @State private var showSwitchConfirmation = false

    private var viewModel: ConfigsViewModel { appStore.configsViewModel }

    var body: some View {
        GeometryReader { viewport in
            VStack(spacing: 0) {
                ConfigsPageHeader(viewModel: viewModel, onSelect: selectFile)
                Divider()
                ConfigsEditorWorkspace(viewModel: viewModel, wordWrap: $wordWrap, fontSize: $fontSize)
            }
            .frame(width: viewport.size.width, height: viewport.size.height)
            .clipped()
        }
        .navigationTitle("配置文件")
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if viewModel.selectedFile == nil { viewModel.selectedFile = allConfigFiles.first }
        }
        .alert("保存修改？", isPresented: $showSwitchConfirmation) {
            Button("保存并切换") {
                if let current = viewModel.selectedFile, viewModel.saveFile(current) {
                    viewModel.selectedFile = pendingFile
                }
                pendingFile = nil
            }
            Button("放弃修改", role: .destructive) {
                viewModel.selectedFile = pendingFile
                pendingFile = nil
            }
            Button("取消", role: .cancel) { pendingFile = nil }
        } message: {
            if let file = viewModel.selectedFile {
                Text("切换文件前，保存对 \(file.displayName) 的修改。")
            }
        }
    }

    private func selectFile(_ file: ConfigFile) {
        guard file.id != viewModel.selectedFile?.id else { return }
        if viewModel.isDirty {
            pendingFile = file
            showSwitchConfirmation = true
        } else {
            viewModel.selectedFile = file
        }
    }
}

private struct ConfigsPageHeader: View {
    @Bindable var viewModel: ConfigsViewModel
    var onSelect: (ConfigFile) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text("配置文件")
                    .font(.system(size: 28, weight: .semibold))
                Spacer(minLength: 0)
                ConfigsSearchField(text: $viewModel.searchText)
                    .frame(minWidth: 150, maxWidth: 240)
            }
            Text("编辑工具配置与全局规则。修改会保留在这里，保存后写入原文件。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ConfigsFileSelection(
                groups: viewModel.filteredGroupedFiles,
                selectedFile: viewModel.selectedFile,
                isSearching: !viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                isDirty: viewModel.isDirty,
                onSelect: onSelect
            )
        }
        .padding(20)
    }
}

private struct ConfigsSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索工具或文件", text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("清除搜索")
                    .accessibilityLabel("清除搜索")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.07)) }
    }
}

private struct ConfigsFileSelection: View {
    let groups: [(tool: String, files: [ConfigFile])]
    let selectedFile: ConfigFile?
    let isSearching: Bool
    let isDirty: Bool
    var onSelect: (ConfigFile) -> Void

    private var visibleFiles: [ConfigFile] {
        if isSearching { return groups.flatMap(\.files) }
        return groups.first(where: { $0.tool == selectedFile?.toolName })?.files ?? groups.first?.files ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if groups.isEmpty {
                Label("没有匹配的配置文件", systemImage: "doc.text.magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(groups, id: \.tool) { group in
                            if let first = group.files.first {
                                Button {
                                    if selectedFile?.toolName != group.tool { onSelect(first) }
                                } label: {
                                    HStack(spacing: 7) {
                                        if let tool = first.tool { ToolLogoImage(tool: tool, size: 15) }
                                        Text(group.tool)
                                            .font(.system(size: 12, weight: selectedFile?.toolName == group.tool ? .medium : .regular))
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(selectedFile?.toolName == group.tool ? Color.primary.opacity(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(selectedFile?.toolName == group.tool ? .isSelected : [])
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(visibleFiles) { file in
                            ConfigFileTab(file: file, isSelected: selectedFile?.id == file.id, isDirty: isDirty && selectedFile?.id == file.id, showTool: isSearching) { onSelect(file) }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }
}

private struct ConfigFileTab: View {
    let file: ConfigFile
    let isSelected: Bool
    let isDirty: Bool
    let showTool: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: file.kindIcon).foregroundStyle(.secondary)
                Text(file.displayName)
                if showTool {
                    Text(file.toolName).foregroundStyle(.secondary)
                }
                if isDirty {
                    Circle().fill(.orange).frame(width: 5, height: 5)
                        .accessibilityLabel("已修改")
                }
            }
            .font(.system(size: 12, weight: isSelected ? .medium : .regular))
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(isSelected ? Color(nsColor: .controlBackgroundColor) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(isSelected ? 0.12 : 0.06)) }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(Text(file.kind.localizedTitle))
    }
}

private struct ConfigsEditorWorkspace: View {
    @Bindable var viewModel: ConfigsViewModel
    @Binding var wordWrap: Bool
    @Binding var fontSize: Double

    var body: some View {
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
            fileIsMissing: viewModel.fileIsMissing,
            onSave: { viewModel.saveFile($0) },
            onRevert: { viewModel.revert() },
            onFormat: { viewModel.formatJSON() },
            onCreate: { viewModel.createFile($0) },
            onReload: { viewModel.loadFile($0) }
        )
        .background {
            ConfigsFontShortcuts(fontSize: $fontSize)
        }
    }
}

private struct ConfigsFontShortcuts: View {
    @Binding var fontSize: Double

    var body: some View {
        Group {
            Button("") { fontSize = min(fontSize + 1, 28) }.keyboardShortcut("+", modifiers: .command)
            Button("") { fontSize = min(fontSize + 1, 28) }.keyboardShortcut("=", modifiers: .command)
            Button("") { fontSize = max(fontSize - 1, 9) }.keyboardShortcut("-", modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Editor workspace

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
    var fileIsMissing = false

    var onSave: (ConfigFile) -> Void
    var onRevert: () -> Void
    var onFormat: () -> Void
    var onCreate: (ConfigFile) -> Void
    var onReload: (ConfigFile) -> Void = { _ in }

    @State private var triggerFind = false
    @State private var showReloadConfirmation = false

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
                        fontSize: $fontSize,
                        loadError: loadError,
                        onSave: { onSave(file) },
                        onRevert: onRevert,
                        onFormat: onFormat,
                        onFind: { triggerFind = true },
                        onReload: {
                            if isDirty { showReloadConfirmation = true } else { onReload(file) }
                        }
                    )

                    Divider()

                    // Native document views scroll inside this viewport. Their
                    // fitting sizes must not move the toolbar or status bar.
                    GeometryReader { viewport in
                        ZStack {
                            Color(nsColor: .textBackgroundColor)

                            Group {
                                if let err = loadError {
                                    FileNotFoundPanel(file: file, error: err, isMissing: fileIsMissing, onCreate: { onCreate(file) }, onReload: { onReload(file) })
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
                        .frame(width: viewport.size.width, height: viewport.size.height)
                        .clipped()
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
        .alert("重新载入文件？", isPresented: $showReloadConfirmation) {
            Button("放弃修改并重新载入", role: .destructive) {
                if let file { onReload(file) }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("未保存的修改将被替换为文件中的内容。")
        }
    }
}

struct EditorToolbar: View {
    let file: ConfigFile
    let isDirty: Bool
    @Binding var showDiff: Bool
    @Binding var markdownModeRaw: String
    @Binding var wordWrap: Bool
    @Binding var fontSize: Double
    let loadError: String?
    var onSave: () -> Void
    var onRevert: () -> Void
    var onFormat: () -> Void
    var onFind: () -> Void
    var onReload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(file.displayName).font(.system(size: 14, weight: .semibold))
                        if isDirty {
                            Text("已修改")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                        }
                    }
                    Text(file.url.path.replacingOccurrences(of: home.path, with: "~"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("保存", action: onSave)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!isDirty || loadError != nil)
                    .keyboardShortcut("s", modifiers: .command)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    if file.isMarkdown { ConfigsMarkdownModePicker(mode: $markdownModeRaw, isEnabled: loadError == nil) }
                    ConfigsEditorActions(file: file, isDirty: isDirty, showDiff: $showDiff, wordWrap: $wordWrap, fontSize: $fontSize, loadError: loadError, canFind: loadError == nil && !showDiff && (!file.isMarkdown || markdownModeRaw != MarkdownMode.preview.rawValue), onRevert: onRevert, onFormat: onFormat, onFind: onFind, onReload: onReload)
                }
                VStack(alignment: .leading, spacing: 10) {
                    if file.isMarkdown { ConfigsMarkdownModePicker(mode: $markdownModeRaw, isEnabled: loadError == nil) }
                    ConfigsEditorActions(file: file, isDirty: isDirty, showDiff: $showDiff, wordWrap: $wordWrap, fontSize: $fontSize, loadError: loadError, canFind: loadError == nil && !showDiff && (!file.isMarkdown || markdownModeRaw != MarkdownMode.preview.rawValue), onRevert: onRevert, onFormat: onFormat, onFind: onFind, onReload: onReload)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }
}

private struct ConfigsMarkdownModePicker: View {
    @Binding var mode: String
    let isEnabled: Bool

    var body: some View {
        Picker("Markdown 显示方式", selection: $mode) {
            Label("编辑", systemImage: "pencil").tag(MarkdownMode.edit.rawValue)
            Label("分栏", systemImage: "rectangle.split.2x1").tag(MarkdownMode.split.rawValue)
            Label("预览", systemImage: "eye").tag(MarkdownMode.preview.rawValue)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 156)
        .controlSize(.small)
        .disabled(!isEnabled)
    }
}

private struct ConfigsEditorActions: View {
    let file: ConfigFile
    let isDirty: Bool
    @Binding var showDiff: Bool
    @Binding var wordWrap: Bool
    @Binding var fontSize: Double
    let loadError: String?
    let canFind: Bool
    var onRevert: () -> Void
    var onFormat: () -> Void
    var onFind: () -> Void
    var onReload: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onFind) { Image(systemName: "magnifyingglass") }
                .help("搜索 (⌘F)")
                .accessibilityLabel("搜索文件内容")
                .disabled(!canFind)
            if file.isJSON {
                Button(action: onFormat) { Image(systemName: "text.alignleft") }
                    .help("格式化 JSON (⌥⌘F)")
                    .accessibilityLabel("格式化 JSON")
                    .keyboardShortcut("f", modifiers: [.option, .command])
                    .disabled(loadError != nil)
            }
            Toggle(isOn: $wordWrap) { Image(systemName: "text.word.spacing") }
                .toggleStyle(.button)
                .help("自动换行")
                .accessibilityLabel("自动换行")
                .disabled(loadError != nil)
            Divider().frame(height: 16)
            ConfigsFontControls(fontSize: $fontSize)
            Spacer(minLength: 8)
            Menu {
                Toggle("查看差异", isOn: $showDiff)
                    .disabled(!isDirty || loadError != nil)
                    .keyboardShortcut("d", modifiers: [.shift, .command])
                Button("还原修改", systemImage: "arrow.uturn.backward", action: onRevert)
                    .disabled(!isDirty || loadError != nil)
                Button("重新载入", systemImage: "arrow.clockwise", action: onReload)
                Divider()
                Button("在 Finder 中显示", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([file.url])
                }
                Button("复制路径", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(file.url.path, forType: .string)
                }
            } label: { Image(systemName: "ellipsis") }
            .menuIndicator(.hidden)
            .help("更多操作")
            .accessibilityLabel("更多操作")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }
}

private struct ConfigsFontControls: View {
    @Binding var fontSize: Double

    var body: some View {
        HStack(spacing: 8) {
            Button { fontSize = max(fontSize - 1, 9) } label: { Image(systemName: "textformat.size.smaller") }
                .help("减小字号")
                .accessibilityLabel("减小字号")
                .disabled(fontSize <= 9)
            Text("\(Int(fontSize))")
                .font(.system(size: 11).monospacedDigit())
                .frame(minWidth: 18)
                .accessibilityLabel("编辑器字号 \(Int(fontSize))")
            Button { fontSize = min(fontSize + 1, 28) } label: { Image(systemName: "textformat.size.larger") }
                .help("增大字号")
                .accessibilityLabel("增大字号")
                .disabled(fontSize >= 28)
        }
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
                ConfigsSplitView(leading: editor, trailing: MarkdownPreviewView(source: content))
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
        .id(file.id)
    }
}

// A nested HSplitView inherits NavigationSplitView's navigation-pane safe area
// and can lay out across the sidebar. Keep this local divider in the viewport.
private struct ConfigsSplitView<Leading: View, Trailing: View>: View {
    let leading: Leading
    let trailing: Trailing
    @State private var leadingFraction: CGFloat = 0.5
    @State private var dragStartWidth: CGFloat?
    private let dividerWidth: CGFloat = 7

    var body: some View {
        GeometryReader { viewport in
            let availableWidth = max(0, viewport.size.width - dividerWidth)
            let minimumWidth = min(200, availableWidth / 2)
            let leadingWidth = min(max(availableWidth * leadingFraction, minimumWidth), availableWidth - minimumWidth)

            HStack(spacing: 0) {
                leading
                    .frame(width: leadingWidth, height: viewport.size.height)
                    .clipped()
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1)
                    .frame(width: dividerWidth, height: viewport.size.height)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if dragStartWidth == nil { dragStartWidth = leadingWidth }
                                let width = min(max((dragStartWidth ?? leadingWidth) + value.translation.width, minimumWidth), availableWidth - minimumWidth)
                                leadingFraction = width / max(1, availableWidth)
                            }
                            .onEnded { _ in dragStartWidth = nil }
                    )
                    .accessibilityLabel("分栏")
                    .accessibilityValue(Text(Double(leadingWidth / max(1, availableWidth)), format: .percent.precision(.fractionLength(0))))
                    .accessibilityAdjustableAction { direction in
                        let delta: CGFloat
                        switch direction {
                        case .increment: delta = 24
                        case .decrement: delta = -24
                        @unknown default: return
                        }
                        let width = min(max(leadingWidth + delta, minimumWidth), availableWidth - minimumWidth)
                        leadingFraction = width / max(1, availableWidth)
                    }
                trailing
                    .frame(width: max(0, availableWidth - leadingWidth), height: viewport.size.height)
                    .clipped()
            }
            .frame(width: viewport.size.width, height: viewport.size.height)
        }
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
        VStack(alignment: .leading, spacing: 8) {
            if let error = saveError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    ConfigsDocumentStatus(content: content, isJSON: file.isJSON && loadError == nil)
                    Spacer(minLength: 12)
                    ConfigsCursorStatus(position: cursorPosition)
                    if let lastSavedTime, !isDirty {
                        Text("已保存 \(lastSavedTime, format: .dateTime.hour().minute().second())")
                            .foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    ConfigsDocumentStatus(content: content, isJSON: file.isJSON && loadError == nil)
                    ConfigsCursorStatus(position: cursorPosition)
                }
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private struct ConfigsDocumentStatus: View {
    let content: String
    let isJSON: Bool

    var body: some View {
        HStack(spacing: 12) {
            if isJSON {
                if let error = jsonError(content) {
                    Label("JSON 无效", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                        .help(error)
                        .accessibilityValue(error)
                } else if !content.isEmpty {
                    Label("JSON 有效", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
            }
            Text("\(content.components(separatedBy: .newlines).count) 行")
                .foregroundStyle(.secondary)
        }
    }
}

private struct ConfigsCursorStatus: View {
    let position: CursorPosition

    var body: some View {
        Text("行 \(position.line) · 列 \(position.column)")
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }
}

struct DiffPanel: View {
    let savedContent: String
    let editorContent: String

    var body: some View {
        let (leftDiffs, rightDiffs) = lineDiff(original: savedContent, modified: editorContent)
        ConfigsSplitView(
            leading: DiffColumn(title: "原始版本", diffs: leftDiffs),
            trailing: DiffColumn(title: "当前修改", diffs: rightDiffs)
        )
    }
}

struct DiffColumn: View {
    let title: LocalizedStringResource
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
    let isMissing: Bool
    var onCreate: () -> Void
    var onReload: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: isMissing ? "doc.badge.plus" : "doc.text.magnifyingglass")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                if isMissing {
                    Text("配置文件缺失").font(.system(size: 16, weight: .semibold))
                } else {
                    Text("无法读取配置文件").font(.system(size: 16, weight: .semibold))
                }
                Text(file.url.path.replacingOccurrences(of: home.path, with: "~"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
            if isMissing {
                Button("立即创建", systemImage: "plus", action: onCreate)
                    .buttonStyle(.borderedProminent)
            } else {
                Button("重新载入", systemImage: "arrow.clockwise", action: onReload)
                    .buttonStyle(.bordered)
            }
        }
        .padding(28)
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

// MARK: - Markdown preview (WKWebView)

struct MarkdownPreviewView: NSViewRepresentable {
    let source: String

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WKWebView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }

    func makeNSView(context: Context) -> WKWebView {
        let wv = WKWebView()
        wv.navigationDelegate = context.coordinator
        wv.setValue(false, forKey: "drawsBackground")
        return wv
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard source != context.coordinator.lastSource else { return }
        context.coordinator.lastSource = source
        let html = configMarkdownHTML(source: source)
        let coordinator = context.coordinator
        coordinator.pendingRender?.cancel()
        let work = DispatchWorkItem { [weak webView, weak coordinator] in
            guard coordinator?.lastSource == source else { return }
            webView?.loadHTMLString(html, baseURL: nil)
        }
        coordinator.pendingRender = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.pendingRender?.cancel()
        coordinator.lastSource = nil
        webView.stopLoading()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastSource: String?
        var pendingRender: DispatchWorkItem?

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard navigationAction.navigationType == .linkActivated else { return .allow }
            guard let url = navigationAction.request.url,
                  ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return .cancel }
            NSWorkspace.shared.open(url)
            return .cancel
        }
    }
}

func configMarkdownHTML(source: String) -> String {
    let encoded = ((try? JSONEncoder().encode(source)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\"")
        .replacingOccurrences(of: "<", with: "\\u003C")
        .replacingOccurrences(of: ">", with: "\\u003E")
    return markdownHTML(encoded)
}

private func markdownHTML(_ encodedJSON: String) -> String {
    #"""
    <!DOCTYPE html><html><head><meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'">
    <style>
    :root{color-scheme:light dark}
    body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;font-size:14px;line-height:1.6;
         padding:24px;max-width:800px;margin:0 auto;
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
    function esc(s){return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#39;');}
    function inline(s){
      s=esc(s);
      s=s.replace(/`([^`\n]+)`/g,'<code>$1</code>');
      s=s.replace(/\*\*\*(.+?)\*\*\*/g,'<strong><em>$1</em></strong>');
      s=s.replace(/\*\*(.+?)\*\*/g,'<strong>$1</strong>');
      s=s.replace(/\*(.+?)\*/g,'<em>$1</em>');
      s=s.replace(/~~(.+?)~~/g,'<del>$1</del>');
      s=s.replace(/\[([^\]]+)\]\(([^)]+)\)/g,function(_,label,url){
        if(!/^(https?:\/\/|mailto:|#)/i.test(url))return label;
        return '<a href="'+url+'" rel="noopener noreferrer">'+label+'</a>';
      });
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

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }

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
        let syntaxChanged = context.coordinator.parent.isJSON != isJSON || context.coordinator.parent.isTOML != isTOML
        context.coordinator.parent = self

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
            let selection = textView.selectedRange()
            textView.string = text
            context.coordinator.updateLineStarts(for: text)
            let utf16Length = (textView.string as NSString).length
            textView.setSelectedRange(NSRange(location: min(selection.location, utf16Length), length: 0))
        } else if syntaxChanged, let storage = textView.textStorage {
            Highlighter.apply(to: storage, font: newFont, isJSON: isJSON, isTOML: isTOML)
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

    // This storage belongs exclusively to the main-actor NSTextView. Its
    // synchronous editing callbacks never originate from background mutations.
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
        var parent: ConfigEditor
        var currentFont: NSFont
        private var lineStarts: [Int] = [0]

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
            guard let textView = notification.object as? NSTextView else { return }
            updateLineStarts(for: textView.string)
            parent.text = textView.string
            parent.onContentChange()
        }

        func updateLineStarts(for text: String) {
            lineStarts = [0]
            for (offset, unit) in text.utf16.enumerated() where unit == 10 {
                lineStarts.append(offset + 1)
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let text = tv.string as NSString
            let location = min(tv.selectedRange().location, text.length)
            var lower = 0
            var upper = lineStarts.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if lineStarts[middle] <= location { lower = middle + 1 } else { upper = middle }
            }
            let lineIndex = max(0, lower - 1)
            let lineStart = min(lineStarts[lineIndex], location)
            let column = text.substring(with: NSRange(location: lineStart, length: location - lineStart)).count + 1
            parent.cursorPosition = CursorPosition(line: lineIndex + 1, column: column)

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
        guard range.length > 0, range.location < layoutManager.numberOfGlyphs else { return }
        let firstIndex = layoutManager.characterIndexForGlyph(at: range.location)

        var lineNum = 1
        var idx = 0
        while idx < firstIndex {
            let next = nsString.lineRange(for: NSRange(location: idx, length: 0)).upperBound
            guard next <= firstIndex else { break }
            idx = next
            lineNum += 1
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        let selectedRange = textView.selectedRange()

        idx = firstIndex
        while idx < NSMaxRange(range) {
            let lineRange = nsString.lineRange(for: NSRange(location: idx, length: 0))
            let rect = layoutManager.lineFragmentUsedRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: idx), effectiveRange: nil)
            let y = rect.origin.y - visibleRect.origin.y + textView.textContainerInset.height

            // Highlight current line number
            var currentAttrs = attributes
            if lineRange.contains(selectedRange.location) || (lineRange.upperBound == nsString.length && selectedRange.location == nsString.length && !nsString.hasSuffix("\n")) {
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

@MainActor
private enum Highlighter {
    private static let expressions: [String: NSRegularExpression] = {
        let patterns = [
            #"-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#,
            #"\b(?:true|false|null)\b"#,
            #""([^"\\]|\\.)*""#,
            #""([^"\\]|\\.)*"(?=\s*:)"#,
            #"#.*$"#,
            #"^\[{1,2}.*\]{1,2}"#,
            #"^[a-zA-Z0-9_-]+(?=\s*=)"#,
            #"'[^']*'"#,
            #"-?\b\d+[\d\-:T.Z]*\b"#,
            #"\b(?:true|false)\b"#
        ]
        return Dictionary(uniqueKeysWithValues: patterns.compactMap { pattern in
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return nil }
            return (pattern, expression)
        })
    }()

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
        guard let re = expressions[pattern] else { return }
        re.enumerateMatches(in: str, range: NSRange(location: 0, length: str.utf16.count)) { m, _, _ in
            guard let r = m?.range else { return }
            ts.addAttribute(.foregroundColor, value: c, range: r)
        }
    }
}
