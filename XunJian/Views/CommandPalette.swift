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
    @Binding var isPresented: Bool
    @Binding var selection: NavigationDestination?

    @State private var query = ""
    @State private var highlightedIndex = 0
    @FocusState private var isFieldFocused: Bool

    private static let maximumFileResults = 8

    var body: some View {
        ZStack(alignment: .top) {
            // Click-away scrim. A subtle darkening reads as "focus mode"
            // without the muddy grey that a heavier black overlay produces
            // on top of a material panel. `ContentShape` keeps the whole
            // area hittable even though the fill is nearly transparent.
            Color.black.opacity(0.08)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }

            panel
                .frame(maxWidth: 560)
                .padding(.top, 96)
                .padding(.horizontal, 24)
        }
        .onExitCommand(perform: dismiss)
        .onAppear { isFieldFocused = true }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            queryField

            if commands.isEmpty {
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
                resultList
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(XunJianUI.Fill.stroke, lineWidth: 1)
        }
        // Lifts the panel off the page. Without this the material blends into
        // whatever is behind it and the palette reads as a flat grey box.
        .shadow(radius: 28, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: AppLanguage.localized(
            "命令面板",
            english: "Command Palette"
        )))
    }

    private var queryField: some View {
        HStack(spacing: 10) {
            Image(systemName: "command")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            TextField(
                "",
                text: $query,
                prompt: Text(verbatim: AppLanguage.localized(
                    "搜索命令、页面或文件…",
                    english: "Search commands, pages, or files…"
                ))
            )
            .textFieldStyle(.plain)
            .font(.title3)
            .focused($isFieldFocused)
            .onSubmit(runHighlighted)
            .onChange(of: query) { _, _ in highlightedIndex = 0 }
            .accessibilityLabel(Text(verbatim: AppLanguage.localized(
                "命令面板搜索",
                english: "Command Palette Search"
            )))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .onKeyPress(.upArrow) {
            moveHighlight(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveHighlight(by: 1)
            return .handled
        }
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                        if shouldShowGroupHeader(at: index) {
                            Text(verbatim: command.group.localizedTitle)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 14)
                                .padding(.top, index == 0 ? 8 : 12)
                                .padding(.bottom, 2)
                                .accessibilityAddTraits(.isHeader)
                        }

                        commandRow(command, isHighlighted: index == highlightedIndex)
                            .id(index)
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 340)
            .onChange(of: highlightedIndex) { _, index in
                proxy.scrollTo(index, anchor: .center)
            }
        }
    }

    private func commandRow(_ command: PaletteCommand, isHighlighted: Bool) -> some View {
        Button {
            run(command)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: command.symbolName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isHighlighted ? Color.accentColor : .secondary)
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
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                isHighlighted ? XunJianUI.Fill.selected : .clear,
                in: RoundedRectangle(cornerRadius: XunJianUI.Radius.row, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .accessibilityLabel(Text(verbatim: command.subtitle.map {
            "\(command.title)，\($0)"
        } ?? command.title))
        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Commands

    private var commands: [PaletteCommand] {
        let all = navigationCommands + actionCommands
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return all + fileCommands(from: appModel.recentFiles)
        }

        let matched = all.filter { Self.matches($0.title, query: trimmed) }
        let files = appModel.files
            .filter { Self.matches($0.name, query: trimmed) }
            .prefix(Self.maximumFileResults)
        return matched + fileCommands(from: Array(files))
    }

    private var navigationCommands: [PaletteCommand] {
        var items: [PaletteCommand] = [
            navigationCommand(.home, title: AppLanguage.localized("首页", english: "Home"), symbol: "house"),
            navigationCommand(
                .allFiles,
                title: AppLanguage.localized("所有文件", english: "All Files"),
                symbol: "doc.on.doc"
            ),
            navigationCommand(
                .categories,
                title: AppLanguage.localized("分类", english: "Categories"),
                symbol: "folder"
            ),
            navigationCommand(
                .settings,
                title: AppLanguage.localized("设置", english: "Settings"),
                symbol: "gearshape"
            )
        ]
        items += appModel.categories.map { category in
            navigationCommand(
                .category(category.id),
                title: category.localizedDisplayName,
                symbol: category.symbolName,
                subtitle: AppLanguage.fileCount(appModel.fileCount(in: category))
            )
        }
        return items
    }

    private func navigationCommand(
        _ destination: NavigationDestination,
        title: String,
        symbol: String,
        subtitle: String? = nil
    ) -> PaletteCommand {
        PaletteCommand(
            id: "nav-\(title)",
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
        if let selected = appModel.selectedFile {
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
                title: AppLanguage.localized("新建分类…", english: "New Category…"),
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
                title: AppLanguage.localized("存储洞察", english: "Storage Insights"),
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
        files.map { file in
            PaletteCommand(
                id: "file-\(file.id)",
                title: file.name,
                subtitle: file.parentPath,
                symbolName: file.kind.symbolName,
                group: .file
            ) {
                appModel.selectedFileID = file.id
                appModel.open(file)
            }
        }
    }

    // MARK: - Behaviour

    /// Case- and diacritic-insensitive substring match. Deliberately not a
    /// fuzzy subsequence match: with file names in the list, subsequence
    /// matching produces too many irrelevant hits to scan quickly.
    static func matches(_ candidate: String, query: String) -> Bool {
        candidate.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
    }

    private func shouldShowGroupHeader(at index: Int) -> Bool {
        guard index > 0 else { return true }
        return commands[index].group != commands[index - 1].group
    }

    private func moveHighlight(by offset: Int) {
        guard !commands.isEmpty else { return }
        let next = highlightedIndex + offset
        highlightedIndex = min(max(next, 0), commands.count - 1)
    }

    private func runHighlighted() {
        guard commands.indices.contains(highlightedIndex) else { return }
        run(commands[highlightedIndex])
    }

    private func run(_ command: PaletteCommand) {
        // Dismiss first so actions that present their own panels (folder
        // picker, category sheet) are not competing with the overlay.
        dismiss()
        command.run()
    }

    private func dismiss() {
        isPresented = false
        query = ""
        highlightedIndex = 0
    }
}
