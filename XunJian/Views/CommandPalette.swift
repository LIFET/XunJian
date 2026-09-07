import SwiftUI

extension Notification.Name {
    static let xunJianShowCommandPalette = Notification.Name(
        "com.xingmingbo.XunJian.showCommandPalette"
    )
}

/// A single actionable row in the palette.
struct PaletteCommand: Identifiable {
    enum Group {
        case navigation
        case action
        case file

        var localizedTitle: String {
            switch self {
            case .navigation: AppLanguage.localized("前往", english: "Go To")
            case .action: AppLanguage.localized("操作", english: "Actions")
            case .file: AppLanguage.localized("文件", english: "Files")
            }
        }
    }

    let id: String
    let title: String
    var subtitle: String?
    let symbolName: String
    let group: Group
    let run: () -> Void
}

/// ⌘K command palette (N09).
///
/// One keyboard-driven entry point for navigation, common actions, and files.
/// It reads the already-loaded index rather than issuing its own queries, so
/// opening the palette never touches the database.
struct CommandPaletteView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.appVisualTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Binding var isPresented: Bool
    @Binding var selection: NavigationDestination?

    @State private var query = ""
    @State private var highlightedIndex = 0
    @State private var displayedCommands: [PaletteCommand] = []
    @State private var displayedQuery = ""
    @State private var pendingSubmissionQuery: String?
    @State private var filterTask: Task<Void, Never>?
    @State private var isFieldFocused = false

    @ScaledMetric(relativeTo: .body) private var rowIconSize: CGFloat = 13

    private static let maximumFileResults = 8

    var body: some View {
        GeometryReader { geometry in
            let compactHeight = geometry.size.height < XunJianUI.Breakpoint.compactOverlayHeight
            let topPadding: CGFloat = compactHeight ? XunJianUI.Spacing.page : 96
            let resultHeight = max(
                160,
                min(340, geometry.size.height - topPadding - 150)
            )

            ZStack(alignment: .top) {
                Color.black.opacity(0.08)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss() }
                    .accessibilityHidden(true)

                panel(maximumResultHeight: resultHeight)
                    .frame(maxWidth: 560)
                    .padding(.top, topPadding)
                    .padding(.horizontal, XunJianUI.Spacing.page)
            }
        }
        .onExitCommand(perform: dismiss)
        .onAppear {
            isFieldFocused = true
            scheduleCommandFilter(immediate: true)
        }
        .onDisappear { filterTask?.cancel() }
        .onChange(of: appModel.filesRevision) { _, _ in
            highlightedIndex = 0
            scheduleCommandFilter(immediate: true)
        }
        .onChange(of: appModel.categoryRevision) { _, _ in
            highlightedIndex = 0
            scheduleCommandFilter(immediate: true)
        }
    }

    private func panel(maximumResultHeight: CGFloat) -> some View {
        let visibleCommands = displayedCommands
        return VStack(spacing: 0) {
            HStack {
                Label(AppLanguage.localized("快速前往", english: "Quick Switcher"), systemImage: "command")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("⌘K").font(.system(.caption, design: .monospaced))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.top, 16)
            queryField

            if visibleCommands.isEmpty {
                Text(verbatim: AppLanguage.localized(
                    "没有匹配的命令或文件",
                    english: "No matching commands or files"
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            } else {
                Divider()
                resultList(visibleCommands, maximumHeight: maximumResultHeight)
            }
            Divider()
            HStack(spacing: 16) {
                Text(AppLanguage.localized("↑ ↓ 选择", english: "↑ ↓ Select"))
                Text(AppLanguage.localized("↩ 执行", english: "↩ Run"))
                Spacer(minLength: 8)
                Button(AppLanguage.localized("关闭 esc", english: "Close esc"), action: dismiss)
                    .buttonStyle(.borderless)
                    .help(AppLanguage.localized("关闭命令面板", english: "Close Command Palette"))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .xunjianFloatingSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: AppLanguage.localized(
            "命令面板",
            english: "Command Palette"
        )))
        .accessibilityAddTraits(.isModal)
    }

    private var queryField: some View {
        NativeSearchField(
            text: $query,
            isFocused: $isFieldFocused,
            prompt: AppLanguage.localized("搜索命令、页面或文件…", english: "Search commands, pages, or files…"),
            accessibilityLabel: AppLanguage.localized("命令面板搜索", english: "Command Palette Search"),
            accessibilityHelp: AppLanguage.localized("输入后按回车执行，按 Escape 关闭", english: "Type and press Return to run, or Escape to close"),
            onSubmit: { _ in runHighlighted() },
            onMoveSelection: { offset in
                guard displayedQuery == query.trimmingCharacters(in: .whitespacesAndNewlines),
                      !displayedCommands.isEmpty else { return false }
                moveHighlight(by: offset)
                return true
            },
            onCancel: dismiss
        )
        .frame(height: XunJianUI.controlHeight)
        .padding(12)
        .onChange(of: query) { _, _ in
            if pendingSubmissionQuery != query.trimmingCharacters(in: .whitespacesAndNewlines) {
                pendingSubmissionQuery = nil
            }
            highlightedIndex = 0
            scheduleCommandFilter(immediate: false)
        }
    }

    private func resultList(
        _ visibleCommands: [PaletteCommand],
        maximumHeight: CGFloat
    ) -> some View {
        List(selection: commandSelection) {
            ForEach(Array(commandGroups.enumerated()), id: \.offset) { _, group in
                let commands = visibleCommands.filter { $0.group == group }
                if !commands.isEmpty {
                    Section {
                        ForEach(commands) { command in
                            Button {
                                run(command)
                            } label: {
                                commandRow(command)
                            }
                            .buttonStyle(.plain)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Text(verbatim: command.subtitle.map {
                                AppLanguage.joinedForAccessibility([command.title, $0])
                            } ?? command.title))
                            .tag(command.id)
                        }
                    } header: {
                        Text(verbatim: group.localizedTitle)
                    }
                }
            }
        }
        .listStyle(.inset)
        .disabled(displayedQuery != query.trimmingCharacters(in: .whitespacesAndNewlines))
        .frame(maxHeight: maximumHeight)
    }

    private var commandGroups: [PaletteCommand.Group] {
        [.navigation, .action, .file]
    }

    private var commandSelection: Binding<String?> {
        Binding(
            get: {
                guard displayedCommands.indices.contains(highlightedIndex) else { return nil }
                return displayedCommands[highlightedIndex].id
            },
            set: { commandID in
                guard let commandID,
                      let index = displayedCommands.firstIndex(where: { $0.id == commandID }) else {
                    return
                }
                highlightedIndex = index
            }
        )
    }

    private func commandRow(_ command: PaletteCommand) -> some View {
        HStack(spacing: 10) {
            Image(systemName: command.symbolName)
                .font(.system(size: rowIconSize, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: command.title)
                    .lineLimit(1)
                if let subtitle = command.subtitle, !subtitle.isEmpty {
                    Text(verbatim: subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .help(command.subtitle ?? command.title)
    }

    // MARK: - Commands

    private func scheduleCommandFilter(immediate: Bool) {
        filterTask?.cancel()
        filterTask = Task {
            if !immediate {
                try? await Task.sleep(for: .milliseconds(120))
            }
            guard !Task.isCancelled else { return }
            let published = await rebuildCommands()
            if published, !Task.isCancelled,
               pendingSubmissionQuery == displayedQuery,
               displayedQuery == query.trimmingCharacters(in: .whitespacesAndNewlines) {
                pendingSubmissionQuery = nil
                if displayedCommands.indices.contains(highlightedIndex) {
                    run(displayedCommands[highlightedIndex])
                }
            }
        }
    }

    @MainActor
    private func rebuildCommands() async -> Bool {
        let sourceFilesRevision = appModel.filesRevision
        let sourceCategoryRevision = appModel.categoryRevision
        let all = navigationCommands + actionCommands
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            guard appModel.filesRevision == sourceFilesRevision,
                  appModel.categoryRevision == sourceCategoryRevision else { return false }
            displayedCommands = all + fileCommands(from: appModel.recentFiles)
            displayedQuery = trimmed
            return true
        }

        let matched = all.filter { QuickSearchMatching.matches($0.title, query: trimmed) }
        let files = appModel.files
        let limit = Self.maximumFileResults
        // The detached scan cannot observe the outer task's cancellation, so
        // a flag flipped by the cancellation handler lets stale full-index
        // walks stop the moment newer input arrives.
        let cancellationFlag = QuickSearchCancellationFlag()
        let result = await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                QuickSearchMatching.prefixMatches(
                    in: files,
                    query: trimmed,
                    limit: limit,
                    isCancelled: { cancellationFlag.isCancelled }
                )
            }.value
        } onCancel: {
            cancellationFlag.cancel()
        }
        guard !Task.isCancelled,
              appModel.filesRevision == sourceFilesRevision,
              appModel.categoryRevision == sourceCategoryRevision else { return false }
        var commands = matched + fileCommands(from: result.files)
        if result.remainingCount > 0 {
            commands.append(moreFilesCommand(remaining: result.remainingCount, query: trimmed))
        }
        displayedCommands = commands
        displayedQuery = trimmed
        return true
    }

    private func moreFilesCommand(remaining: Int, query: String) -> PaletteCommand {
        PaletteCommand(
            id: "files-more",
            title: AppLanguage.localized(
                "在查找中查看其余 \(remaining) 条",
                english: "See remaining \(remaining) in All Files"
            ),
            symbolName: "ellipsis.circle",
            group: .file
        ) {
            appModel.searchAllFiles(query: query)
            selection = .allFiles
        }
    }

    private var navigationCommands: [PaletteCommand] {
        var items: [PaletteCommand] = [
            navigationCommand(
                .home,
                id: "nav-home",
                title: NavigationDestination.home.title(categories: []),
                symbol: "rectangle.3.group"
            ),
            navigationCommand(
                .allFiles,
                id: "nav-all-files",
                title: NavigationDestination.allFiles.title(categories: []),
                symbol: "tray.full"
            ),
            navigationCommand(
                .categories,
                id: "nav-categories",
                title: NavigationDestination.categories.title(categories: []),
                symbol: "square.stack"
            ),
            navigationCommand(
                .settings,
                id: "nav-settings",
                title: AppLanguage.localized("设置", english: "Settings"),
                symbol: "gearshape"
            )
        ]
        items += appModel.categories.map { category in
            navigationCommand(
                .category(category.id),
                id: "nav-category-\(category.id.uuidString)",
                title: category.localizedDisplayName,
                symbol: category.symbolName,
                subtitle: AppLanguage.fileCount(appModel.fileCount(in: category))
            )
        }
        return items
    }

    private func navigationCommand(
        _ destination: NavigationDestination,
        id: String,
        title: String,
        symbol: String,
        subtitle: String? = nil
    ) -> PaletteCommand {
        PaletteCommand(
            id: id,
            title: title,
            subtitle: subtitle,
            symbolName: symbol,
            group: .navigation
        ) {
            selection = destination
        }
    }

    private var actionCommands: [PaletteCommand] {
        var items: [PaletteCommand] = []
        // Only offered when it has a target, so the palette never lists an
        // action that would silently do nothing.
        if let selected = appModel.selectedFile,
           appModel.supportsTextContent(selected) {
            items.append(
                PaletteCommand(
                    id: "action-preview-text",
                    title: AppLanguage.localized("预览正文", english: "Preview Text"),
                    subtitle: selected.name,
                    symbolName: "doc.text.magnifyingglass",
                    group: .action
                ) {
                    NotificationCenter.default.post(name: .xunJianShowTextPreview, object: nil)
                }
            )
        }
        return items + [
            PaletteCommand(
                id: "action-add-folder",
                title: AppLanguage.localized("添加文件夹…", english: "Add Folder…"),
                symbolName: "folder.badge.plus",
                group: .action
            ) {
                appModel.chooseFolder()
            },
            PaletteCommand(
                id: "action-new-category",
                title: AppLanguage.localized("新建资料集…", english: "New Collection…"),
                symbolName: "plus.rectangle.on.folder",
                group: .action
            ) {
                NotificationCenter.default.post(name: .xunJianRequestNewCategory, object: nil)
            },
            PaletteCommand(
                id: "action-rescan",
                title: AppLanguage.localized("重新扫描全部位置", english: "Rescan All Locations"),
                symbolName: "arrow.clockwise",
                group: .action
            ) {
                appModel.refreshAllSources()
            },
            PaletteCommand(
                id: "action-storage-insights",
                title: AppLanguage.localized("存储概览", english: "Storage Overview"),
                symbolName: "chart.pie",
                group: .action
            ) {
                NotificationCenter.default.post(name: .xunJianShowStorageInsights, object: nil)
            }
        ] + FileListExport.Format.allCases.map { format in
            PaletteCommand(
                id: "action-export-\(format.rawValue)",
                title: AppLanguage.localized(
                    "导出文件清单为 \(format.localizedTitle)…",
                    english: "Export File List as \(format.localizedTitle)…"
                ),
                symbolName: "square.and.arrow.up",
                group: .action
            ) {
                FileListExport.run(appModel: appModel, format: format)
            }
        }
    }

    private func fileCommands(from files: [IndexedFile]) -> [PaletteCommand] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return files.map { file in
            let pathOnly = !trimmed.isEmpty
                && QuickSearchMatching.matchedPathOnly(file: file, query: trimmed)
            return PaletteCommand(
                id: "file-\(file.id)",
                title: file.name,
                subtitle: pathOnly
                    ? AppLanguage.localized(
                        "路径 · \(file.parentPath)",
                        english: "Path · \(file.parentPath)"
                    )
                    : file.parentPath,
                symbolName: file.kind.symbolName,
                group: .file
            ) {
                appModel.revealInAllFiles(file)
                selection = .allFiles
            }
        }
    }

    // MARK: - Behaviour

    private func moveHighlight(by offset: Int) {
        guard !displayedCommands.isEmpty else { return }
        let next = highlightedIndex + offset
        highlightedIndex = min(max(next, 0), displayedCommands.count - 1)
    }

    private func runHighlighted() {
        guard displayedQuery == query.trimmingCharacters(in: .whitespacesAndNewlines),
              displayedCommands.indices.contains(highlightedIndex) else {
            pendingSubmissionQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            scheduleCommandFilter(immediate: true)
            return
        }
        run(displayedCommands[highlightedIndex])
    }

    private func run(_ command: PaletteCommand) {
        // Dismiss first so actions that present their own panels (folder
        // picker, category sheet) are not competing with the overlay.
        dismiss()
        command.run()
    }

    private func dismiss() {
        filterTask?.cancel()
        pendingSubmissionQuery = nil
        isFieldFocused = false
        isPresented = false
        query = ""
        highlightedIndex = 0
    }
}
