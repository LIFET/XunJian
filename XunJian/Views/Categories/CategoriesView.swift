import SwiftUI

@MainActor
final class CollectionBrowseContext: ObservableObject {
    struct Filters: Equatable {
        var query = ""
        var kind: FileKind?
    }
    @Published var directoryQuery = ""
    @Published var filters: [UUID: Filters] = [:]
}

struct CategoriesView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var categoryIndex: CategoryIndexStore
    @Environment(\.locale) private var locale
    @Environment(\.appVisualTheme) private var visualTheme
    @Environment(\.colorScheme) private var colorScheme
    let selectedCategory: FileCategory?
    let openCategory: (FileCategory) -> Void
    let showAllCategories: () -> Void
    let statusContent: AnyView?

    @State private var showsNewCategory = false
    @State private var categoryToRename: FileCategory?
    @State private var categoryToDelete: FileCategory?
    @State private var hoveredCategoryID: UUID?
    @ObservedObject private var browseContext: CollectionBrowseContext
    private var collectionQuery: String {
        get { browseContext.directoryQuery }
        nonmutating set { browseContext.directoryQuery = newValue }
    }
    @State private var isCollectionSearchFocused = false
    private var categoryQuery: String {
        get { selectedCategory.flatMap { browseContext.filters[$0.id]?.query } ?? "" }
        nonmutating set {
            guard let id = selectedCategory?.id else { return }
            browseContext.filters[id, default: .init()].query = newValue
        }
    }
    @State private var displayedFiles: [IndexedFile] = []
    @State private var displayedFileIDs: Set<String> = []
    /// Ordered positions for `displayedFiles`, so selection and arrow-key
    /// navigation do not pay O(n) index scans per click/keypress.
    @State private var displayedFileOrderedIDs: [String] = []
    @State private var displayedFileIDIndex: [String: Int] = [:]
    @State private var tableSelectedIDs: Set<String> = []
    @State private var categoryFileCount = 0
    @State private var displayedSignature: Int?
    @State private var isCategorySearching = false

    // Browsing preferences for the category detail page (N05). Persisted so
    // they survive page switches and relaunches, matching "All Files".
    @AppStorage("category.viewMode") private var viewMode = FileBrowseViewMode.list
    @AppStorage("category.sortOrder") private var sortOrder = FileSortOrder.modifiedAt
    @AppStorage("category.sortAscending") private var sortAscending = false
    private var selectedKind: FileKind? {
        get { selectedCategory.flatMap { browseContext.filters[$0.id]?.kind } }
        nonmutating set {
            guard let id = selectedCategory?.id else { return }
            browseContext.filters[id, default: .init()].kind = newValue
        }
    }
    @AppStorage(FileActivationBehavior.storageKey)
    private var doubleClickBehavior = FileActivationBehavior.open

    @ScaledMetric(relativeTo: .body) private var categoryIconSize: CGFloat = 16
    @ScaledMetric(relativeTo: .body) private var categoryIconContainer: CGFloat = 32

    private var palette: ThemePalette { visualTheme.palette(for: colorScheme) }

    init(
        selectedCategory: FileCategory?,
        browseContext: CollectionBrowseContext = CollectionBrowseContext(),
        openCategory: @escaping (FileCategory) -> Void = { _ in },
        showAllCategories: @escaping () -> Void = {},
        statusContent: AnyView? = nil
    ) {
        self.selectedCategory = selectedCategory
        self.browseContext = browseContext
        self.openCategory = openCategory
        self.showAllCategories = showAllCategories
        self.statusContent = statusContent
    }

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let selectedCategory {
                    VStack(alignment: .leading, spacing: 0) {
                        categoryWorkspaceHeader(contentWidth: geometry.size.width)
                        if let statusContent { statusContent }
                        HStack {
                            Text(verbatim: AppLanguage.fileCount(categoryFileCount))
                                .monospacedDigit()
                            Spacer(minLength: 0)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .frame(height: 32)
                        WorkspaceRowSeparator()
                        categoryFiles(selectedCategory, contentWidth: geometry.size.width)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            header
                            NativeSearchField(
                                text: Binding(get: { collectionQuery }, set: { collectionQuery = $0 }),
                                isFocused: $isCollectionSearchFocused,
                                prompt: AppLanguage.localized("查找资料集…", english: "Find a collection…"),
                                accessibilityLabel: AppLanguage.localized("查找资料集", english: "Find a Collection"),
                                accessibilityHelp: AppLanguage.localized("按名称查找资料集", english: "Find collections by name"),
                                controlSize: .large,
                                onSubmit: { _ in },
                                onCancel: {
                                    if collectionQuery.isEmpty { isCollectionSearchFocused = false }
                                    else { collectionQuery = "" }
                                }
                            )
                                .frame(maxWidth: 360, minHeight: 40, maxHeight: 40)
                                .accessibilityIdentifier("collections.search")
                                .onReceive(NotificationCenter.default.publisher(for: .xunJianFocusSearchField)) { note in
                                    guard note.object as? String == XunJianSearchFieldScope.collections.rawValue else { return }
                                    isCollectionSearchFocused = true
                                }
                            categoryOverview
                        }
                        .frame(maxWidth: 920, alignment: .leading)
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .toolbar { categoryFileToolbar(contentWidth: geometry.size.width) }
        }
        .background(palette.canvas)
        .onAppear {
            if selectedCategory != nil {
                appModel.highlightQuery = categoryQuery
            }
            tableSelectedIDs = appModel.selectedFileIDs
            clearSelectionIfHidden()
        }
        .task(id: categoryFilesRefreshKey) {
            await refreshCategoryFilesSnapshot()
        }
        .onChange(of: selectedCategory?.id) { _, _ in
            displayedFiles = []
            displayedFileIDs = []
            displayedFileOrderedIDs = []
            displayedFileIDIndex = [:]
            categoryFileCount = 0
            displayedSignature = nil
            appModel.updateCommandTargetFiles([])
            appModel.highlightQuery = categoryQuery
            clearSelectionIfHidden()
        }
        .onReceive(NotificationCenter.default.publisher(for: .xunJianSetBrowseViewMode)) { note in
            guard selectedCategory != nil,
                  let raw = note.object as? String,
                  let mode = FileBrowseViewMode(rawValue: raw) else { return }
            viewMode = mode
        }
        .onChange(of: categoryQuery) { _, query in
            if selectedCategory != nil {
                appModel.highlightQuery = query
            }
            isCategorySearching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        .onChange(of: appModel.files.count) { _, _ in clearSelectionIfHidden() }
        .onChange(of: appModel.selectedFileIDs) { _, selectedIDs in
            guard tableSelectedIDs != selectedIDs else { return }
            tableSelectedIDs = selectedIDs
        }
        .sheet(isPresented: $showsNewCategory) {
            CategoryEditorSheet(
                title: AppLanguage.localized("新建资料集", english: "New Collection")
            ) { name, symbolName in
                try await appModel.createCategory(name: name, symbolName: symbolName)
            }
            .environment(\.locale, locale)
        }
        .sheet(item: $categoryToRename) { category in
            CategoryEditorSheet(
                title: AppLanguage.localized("重命名资料集", english: "Rename Collection"),
                initialName: category.name,
                initialSymbol: category.symbolName,
                allowsSymbolEditing: false
            ) { name, _ in
                try await appModel.renameCategory(category, to: name)
            }
            .environment(\.locale, locale)
        }
        .alert(
            AppLanguage.localized("删除资料集？", english: "Delete Collection?"),
            isPresented: Binding(
                get: { categoryToDelete != nil },
                set: { if !$0 { categoryToDelete = nil } }
            )
        ) {
            Button(AppLanguage.localized("取消", english: "Cancel"), role: .cancel) {
                categoryToDelete = nil
            }
            Button(
                AppLanguage.localized("删除资料集", english: "Delete Collection"),
                role: .destructive
            ) {
                if let categoryToDelete {
                    appModel.deleteCategory(categoryToDelete)
                }
                categoryToDelete = nil
            }
        } message: {
            Text(verbatim: deleteMessage)
        }
    }

    private var header: some View {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: XunJianUI.Spacing.sectionInner) {
                        categoryOverviewHeading
                            .layoutPriority(1)
                        headerAction
                    }

                    VStack(alignment: .leading, spacing: XunJianUI.Spacing.sectionInner) {
                        categoryOverviewHeading
                        headerAction
                    }
                }
    }

    @ToolbarContentBuilder
    private func categoryFileToolbar(contentWidth: CGFloat) -> some ToolbarContent {
        if selectedCategory != nil {
            ToolbarItem(id: "category.back", placement: .navigation) {
                Button(action: showAllCategories) {
                    Label(AppLanguage.localized("资料集", english: "Collections"), systemImage: "chevron.left")
                }
                .help(AppLanguage.localized("返回资料集", english: "Back to Collections"))
            }
        }
    }

    private func categoryWorkspaceHeader(contentWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SearchField(
                text: Binding(get: { categoryQuery }, set: { categoryQuery = $0 }),
                prompt: AppLanguage.localized("在此资料集中搜索…", english: "Search this collection…"),
                accessibilityHint: AppLanguage.localized("只搜索当前资料集中的文件", english: "Searches only files in this collection"),
                focusScope: .category,
                onMoveSelection: { offset in
                    guard !displayedFileOrderedIDs.isEmpty else { return false }
                    appModel.moveDisplayedSelection(by: offset, inIDs: displayedFileOrderedIDs,
                                                    extending: false, idIndex: displayedFileIDIndex)
                    return true
                }
            )
            .accessibilityIdentifier("collection.search")
            HStack(spacing: 12) {
                Menu { categoryTypeChoices } label: {
                    HStack(spacing: 6) {
                        Image(systemName: selectedKind == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                        if contentWidth >= 440 { Text(selectedKind?.localizedTitle ?? AppLanguage.localized("全部类型", english: "All Types")) }
                    }
                    .frame(minWidth: 18, minHeight: 26)
                }
                .help(AppLanguage.localized("按文件类型筛选", english: "Filter by File Type"))
                .accessibilityLabel(AppLanguage.localized("筛选文件", english: "Filter Files"))
                Menu {
                    Section(AppLanguage.localized("显示方式", english: "View")) { categoryDisplayChoices }
                    Section(AppLanguage.localized("排序", english: "Sort")) { categorySortChoices }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: viewMode == .grid ? "square.grid.2x2" : "list.bullet")
                        if contentWidth >= 440 { Text(AppLanguage.localized("视图", english: "View")) }
                    }
                    .frame(minWidth: 18, minHeight: 26)
                }
                .accessibilityLabel(AppLanguage.localized("视图", english: "View"))
                Spacer(minLength: 0)
                Menu { categoryActionChoices } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "ellipsis.circle")
                        if contentWidth >= 440 { Text(AppLanguage.localized("操作", english: "Actions")) }
                    }
                    .frame(minWidth: 18, minHeight: 26)
                }
                .help(AppLanguage.localized("AI 与资料集操作", english: "AI and Collection Actions"))
                .accessibilityLabel(AppLanguage.localized("资料集操作", english: "Collection Actions"))
            }
            .controlSize(.large)
            .menuStyle(.button)
        }
        .padding(contentWidth < 440 ? 12 : 20)
        .background(palette.surface)
    }

    private var categoryAIChoices: some View {
        Group {
            Button(AppLanguage.localized("解释所选文件", english: "Explain Selected File")) {
                if let file = appModel.selectedFile { appModel.aiSheetRequest = .explain(file) }
            }
            Button(AppLanguage.localized("向所选文件提问", english: "Ask About Selected File")) {
                if let file = appModel.selectedFile { appModel.aiSheetRequest = .ask(file) }
            }
        }
        .disabled(appModel.activeAIProviderKind == nil || appModel.selectedFileIDs.count != 1
                  || appModel.selectedFile.map { !appModel.supportsTextContent($0) } != false)
    }

    private var categoryActionChoices: some View {
        Group {
            Section("AI") { categoryAIChoices }
            if let selectedCategory {
                Section(AppLanguage.localized("资料集操作", english: "Collection Actions")) {
                    Button(AppLanguage.localized("重命名资料集…", english: "Rename Collection…")) { categoryToRename = selectedCategory }
                    Button(AppLanguage.localized("删除资料集…", english: "Delete Collection…"), role: .destructive) { categoryToDelete = selectedCategory }
                }
            }
        }
    }

    private var categoryTypeChoices: some View {
        Group {
            Toggle(AppLanguage.localized("所有类型", english: "All Types"), isOn: Binding(
                get: { selectedKind == nil }, set: { if $0 { selectedKind = nil } }))
            ForEach(FileKind.allCases) { kind in
                Toggle(kind.localizedTitle, isOn: Binding(
                    get: { selectedKind == kind }, set: { if $0 { selectedKind = kind } }))
            }
        }
    }

    private var categorySortChoices: some View {
        Group {
            ForEach(FileSortOrder.allCases.filter { $0 != .relevance }) { order in
                Toggle(order.localizedTitle, isOn: Binding(get: { sortOrder == order }, set: { selected in
                    guard selected, sortOrder != order else { return }
                    sortOrder = order
                    sortAscending = order == .name || order == .kind
                }))
            }
            Divider()
            Toggle(AppLanguage.localized("升序", english: "Ascending"), isOn: $sortAscending)
        }
    }

    private var categoryDisplayChoices: some View {
        ForEach(FileBrowseViewMode.allCases) { mode in
            Toggle(mode.localizedTitle, isOn: Binding(get: { viewMode == mode }, set: { if $0 { viewMode = mode } }))
        }
    }

    private var categoryOverviewHeading: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AppLanguage.localized("资料集", english: "Collections"))
                .font(.system(size: 24, weight: .semibold))
            Text(AppLanguage.localized("\(appModel.categories.count) 个资料集 · 只建立关联，原文件仍在原处。", english: "\(appModel.categories.count) collections · Linked here, kept in their original locations."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var headerAction: some View {
        if selectedCategory == nil {
            Button {
                showsNewCategory = true
            } label: {
                Label(
                    AppLanguage.localized("新建资料集", english: "New Collection"),
                    systemImage: "plus"
                )
            }
            .labelStyle(.titleAndIcon)
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .frame(minHeight: XunJianUI.controlHeight)
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    @ViewBuilder
    private var categoryOverview: some View {
        if appModel.categories.isEmpty {
            Group {
                ContentUnavailableView(
                    AppLanguage.localized("还没有资料集", english: "No Collections Yet"),
                    systemImage: "folder.badge.plus",
                    description: Text(
                        AppLanguage.localized(
                            "创建资料集后，可以从文件右键菜单或信息栏添加文件。",
                            english: "Create a collection, then add files from the context menu or information pane."
                        )
                    )
                )
                .frame(
                    maxWidth: .infinity,
                    minHeight: XunJianUI.Breakpoint.categoryEmptyStateHeight
                )
            }
        } else {
            LazyVStack(spacing: 0) {
                ForEach(appModel.categories.filter {
                    collectionQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || $0.localizedDisplayName.localizedStandardContains(collectionQuery.trimmingCharacters(in: .whitespacesAndNewlines))
                }) { category in
                    Button {
                        openCategory(category)
                    } label: {
                        HStack(spacing: 16) {
                                Image(systemName: category.symbolName)
                                    .font(.system(size: 18, weight: .regular))
                                    .frame(width: 32)
                                    .foregroundStyle(.secondary)
                            Text(verbatim: category.localizedDisplayName)
                                .font(.system(size: 15, weight: .medium))
                                .lineLimit(1)
                                .help(category.localizedDisplayName)
                            Spacer(minLength: 16)
                            Text(verbatim: AppLanguage.fileCount(appModel.fileCount(in: category)))
                                .font(.callout).monospacedDigit()
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .padding(.horizontal, 12)
                        .background(hoveredCategoryID == category.id ? palette.selection : palette.canvas)
                        .overlay(alignment: .bottom) { WorkspaceRowSeparator() }
                        .xunjianAnimation(value: hoveredCategoryID == category.id)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { isHovering in
                        hoveredCategoryID = isHovering ? category.id : nil
                    }
                    .accessibilityLabel(
                        AppLanguage.joinedForAccessibility([
                            category.localizedDisplayName,
                            AppLanguage.fileCount(appModel.fileCount(in: category))
                        ])
                    )
                    .contextMenu {
                        Button(AppLanguage.localized("修改名称…", english: "Rename…")) {
                            categoryToRename = category
                        }
                        Divider()
                        Button(
                            AppLanguage.localized("删除资料集", english: "Delete Collection"),
                            role: .destructive
                        ) { categoryToDelete = category }
                    }
                }
            }
            if !collectionQuery.isEmpty && !appModel.categories.contains(where: { $0.localizedDisplayName.localizedStandardContains(collectionQuery.trimmingCharacters(in: .whitespacesAndNewlines)) }) {
                ContentUnavailableView.search(text: collectionQuery)
                Button(AppLanguage.localized("清除搜索", english: "Clear Search")) { collectionQuery = "" }
                    .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private func categoryFiles(
        _ category: FileCategory,
        contentWidth: CGFloat
    ) -> some View {
        let files = displayedFiles

        if displayedSignature == nil {
            ProgressView()
                .controlSize(.small)
                .frame(
                    maxWidth: .infinity,
                    minHeight: XunJianUI.Breakpoint.categoryEmptyStateHeight
                )
                .accessibilityLabel(
                    AppLanguage.localized("正在准备文件列表", english: "Preparing file list")
                )
        } else if categoryFileCount == 0 {
            ContentUnavailableView(
                AppLanguage.localized(
                    "资料集里还没有文件",
                    english: "No Files in This Collection"
                ),
                systemImage: category.symbolName,
                description: Text(
                    AppLanguage.localized(
                        "从文件右键菜单或信息栏，将文件添加到这个资料集。",
                        english: "Add files to this collection from the context menu or information pane."
                    )
                )
            )
            .frame(
                maxWidth: .infinity,
                minHeight: XunJianUI.Breakpoint.categoryEmptyStateHeight
            )
        } else {
            VStack(alignment: .leading, spacing: XunJianUI.Spacing.sectionInner) {
                if isCategorySearching, !files.isEmpty {
                    ProgressView(AppLanguage.localized("正在搜索…", english: "Searching…"))
                        .controlSize(.small)
                }
                if appModel.selectedFileIDs.count > 1 {
                    FileBatchActionBar(
                        contentWidth: contentWidth,
                        removalCategory: selectedCategory
                    )
                }

                if files.isEmpty, isCategorySearching {
                    ProgressView(AppLanguage.localized("正在搜索…", english: "Searching…"))
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else if files.isEmpty {
                    kindFilterEmptyState
                } else if viewMode == .grid {
                    ScrollView {
                        categoryFileGrid(files)
                            .padding(XunJianUI.pagePadding(for: contentWidth))
                            .fileListKeyboardNavigation(
                                files: files,
                                orderedIDs: displayedFileOrderedIDs,
                                idIndex: displayedFileIDIndex,
                                columnCount: FileGridCard.columnCount(forWidth: contentWidth)
                            )
                    }
                } else {
                    categoryFileList(files)
                        .fileListKeyboardNavigation(
                            files: files,
                            orderedIDs: displayedFileOrderedIDs,
                            idIndex: displayedFileIDIndex,
                            handlesArrowKeys: false
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .xunjianAnimation(value: viewMode)
        }
    }

    /// Only reachable when the category has files but the type filter hides
    /// them all, so the recovery action is clearing the filter.
    private var kindFilterEmptyState: some View {
        ContentUnavailableView {
            Label(
                AppLanguage.localized("没有匹配的文件", english: "No Matching Files"),
                systemImage: "line.3.horizontal.decrease.circle"
            )
        } description: {
            Text(verbatim: AppLanguage.localized(
                "没有符合当前搜索或类型筛选的文件。",
                english: "No files match the current search or type filter."
            ))
        } actions: {
            Button(AppLanguage.localized("显示全部", english: "Show All")) {
                selectedKind = nil
                categoryQuery = ""
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: XunJianUI.Breakpoint.categoryEmptyStateHeight
        )
    }

    private func categoryFileGrid(_ files: [IndexedFile]) -> some View {
        LazyVGrid(columns: FileGridCard.gridColumns, spacing: 14) {
            ForEach(files) { file in
                FileGridSelectableCard(
                    file: file,
                    isSelected: appModel.selectedFileIDs.contains(file.id),
                    selectedIDs: appModel.$selectedFileIDs,
                    onSelect: {
                        let modifiers = NSEvent.modifierFlags
                        appModel.selectDisplayedFile(
                            file.id,
                            inIDs: displayedFileOrderedIDs,
                            command: modifiers.contains(.command),
                            shift: modifiers.contains(.shift),
                            idIndex: displayedFileIDIndex
                        )
                    },
                    onOpen: {
                        appModel.selectedFileID = file.id
                        doubleClickBehavior.perform(on: file, using: appModel)
                    }
                )
                .contextMenu {
                    FileContextMenu(file: file)
                }
                .draggable(file.url)
            }
        }
    }

    private func categoryFileList(_ files: [IndexedFile]) -> some View {
        Table(of: IndexedFile.self, selection: categoryTableSelection) {
            TableColumn(AppLanguage.localized("名称", english: "Name")) { file in
                categoryTableCell {
                    HStack(spacing: 8) {
                        FileThumbnail(file: file, size: 24)
                            .accessibilityHidden(true)
                        Text(verbatim: file.name)
                            .lineLimit(1)
                            .help(file.name)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: categoryRowAccessibilityLabel(file)))
                }
            }
            .width(min: 160, ideal: 300, max: 460)

            TableColumn(AppLanguage.localized("类型", english: "Kind")) { file in
                categoryTableCell(accessibilityHidden: true) {
                    Text(verbatim: file.kind.localizedTitle)
                        .lineLimit(1)
                }
            }
            .width(min: 70, ideal: 100, max: 140)

            TableColumn(AppLanguage.localized("大小", english: "Size")) { file in
                categoryTableCell(accessibilityHidden: true) {
                    Text(verbatim: FileGridCard.sizeText(file))
                        .lineLimit(1)
                }
            }
            .width(min: 60, ideal: 90, max: 120)

            TableColumn(AppLanguage.localized("位置", english: "Where")) { file in
                categoryTableCell(accessibilityHidden: true) {
                    Text(verbatim: file.parentPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(file.parentPath)
                }
            }
            .width(min: 100, ideal: 240, max: 420)
        } rows: {
            ForEach(files) { file in
                TableRow(file)
                    .draggable(file.url)
            }
        }
        .contextMenu(forSelectionType: String.self) { selection in
            if let file = categoryTableFile(for: selection) {
                FileContextMenu(file: file)
            }
        } primaryAction: { selection in
            guard let file = categoryTableFile(for: selection) else { return }
            doubleClickBehavior.perform(on: file, using: appModel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func categoryTableCell<Content: View>(
        accessibilityHidden: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityHidden(accessibilityHidden)
    }

    private var categoryTableSelection: Binding<Set<String>> {
        Binding(
            get: { tableSelectedIDs },
            set: { newValue in
                guard newValue != tableSelectedIDs else { return }
                tableSelectedIDs = newValue
                let modifiers = NSApp.currentEvent?.modifierFlags ?? []
                appModel.applyNativeTableSelection(
                    newValue,
                    orderedIDs: displayedFileOrderedIDs,
                    idIndex: displayedFileIDIndex,
                    command: modifiers.contains(.command),
                    shift: modifiers.contains(.shift)
                )
            }
        )
    }

    private func categoryTableFile(for selection: Set<String>) -> IndexedFile? {
        if let selectedID = appModel.selectedFileID,
           selection.contains(selectedID),
           let file = appModel.index.file(id: selectedID) {
            return file
        }
        guard let fileID = selection.first else { return nil }
        return appModel.index.file(id: fileID)
    }

    private func categoryRowAccessibilityLabel(_ file: IndexedFile) -> String {
        AppLanguage.joinedForAccessibility([
            file.name,
            file.kind.localizedTitle,
            FileGridCard.sizeText(file),
            file.parentPath
        ])
    }

    /// Applies the page's type filter and sort order.
    nonisolated static func displayed(
        _ files: [IndexedFile],
        kind: FileKind?,
        query: String = "",
        ftsMatchIDs: Set<String>? = nil,
        sortOrder: FileSortOrder,
        ascending: Bool
    ) -> [IndexedFile] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = files.filter { file in
            if let kind, file.kind != kind { return false }
            if let ftsMatchIDs {
                if ftsMatchIDs.contains(file.id) { return true }
                return !trimmed.isEmpty && QuickSearchMatching.matches(file: file, query: trimmed)
            }
            if !trimmed.isEmpty, !QuickSearchMatching.matches(file: file, query: trimmed) {
                return false
            }
            return true
        }
        return sortOrder.sorted(filtered, ascending: ascending)
    }

    /// Drops a selection the user can no longer see, so the inspector never
    /// describes a file that is filtered out of the current category.
    ///
    /// Only the visible ID set matters here, so this skips the sort the list
    /// itself performs.
    private func clearSelectionIfHidden() {
        guard selectedCategory != nil else {
            // Reuses the coordinator's maintained ID set instead of building
            // a six-figure Set per files-count change on the main actor.
            appModel.clearSelectionIfHidden(from: appModel.allFileIDs)
            return
        }
        // While a debounced FTS request is pending, keep the selection. Once
        // the snapshot is committed, its IDs are the exact visible truth,
        // including files matched only through indexed body text.
        guard displayedSignature != nil else { return }
        appModel.clearSelectionIfHidden(from: displayedFileIDs)
    }

    private var categoryFilesRefreshKey: CategoryFilesRefreshKey {
        CategoryFilesRefreshKey(
            filesRevision: appModel.filesRevision,
            categoryRevision: categoryIndex.revision,
            categoryID: selectedCategory?.id,
            kind: selectedKind,
            query: categoryQuery.trimmingCharacters(in: .whitespacesAndNewlines),
            sortOrder: sortOrder,
            ascending: sortAscending
        )
    }

    private func refreshCategoryFilesSnapshot() async {
        guard let selectedCategory else {
            appModel.updateCommandTargetFiles([])
            displayedFiles = []
            displayedFileIDs = []
            displayedFileOrderedIDs = []
            displayedFileIDIndex = [:]
            categoryFileCount = 0
            displayedSignature = nil
            isCategorySearching = false
            return
        }

        let signature = categoryFilesRefreshKey.signature
        guard displayedSignature != signature else {
            appModel.updateCommandTargetFiles(displayedFiles)
            return
        }

        let categoryID = selectedCategory.id
        let categoryFiles = categoryIndex.files(in: categoryID)
        let kind = selectedKind
        let query = categoryQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let order = sortOrder
        let ascending = sortAscending
        let matchingIDs: Set<String>?
        if query.isEmpty {
            matchingIDs = nil
        } else {
            isCategorySearching = true
            do {
                try await Task.sleep(for: .milliseconds(120))
                let matches = try await appModel.searchFileIDs(
                    matching: query,
                    inCategory: categoryID,
                    limit: max(appModel.fileCount(in: selectedCategory), 1)
                )
                try Task.checkCancellation()
                matchingIDs = matches
            } catch is CancellationError {
                return
            } catch {
                appModel.reportError(error.localizedDescription)
                matchingIDs = []
            }
        }
        // Detached sorts cannot observe cancellation: the flag aborts the
        // expensive category sort when a newer revision already landed, so
        // bursts of file activity keep at most one sort in flight.
        let cancellationFlag = QuickSearchCancellationFlag()
        let computed = await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                guard !cancellationFlag.isCancelled else {
                    return (
                        files: [IndexedFile](),
                        visibleIDs: Set<String>(),
                        orderedIDs: [String](),
                        idIndex: [String: Int]()
                    )
                }
                let files = CategoriesView.displayed(
                    categoryFiles,
                    kind: kind,
                    query: query,
                    ftsMatchIDs: matchingIDs,
                    sortOrder: order,
                    ascending: ascending
                )
                let orderedIDs = files.map(\.id)
                return (
                    files: files,
                    visibleIDs: Set(orderedIDs),
                    orderedIDs: orderedIDs,
                    idIndex: Dictionary(
                        uniqueKeysWithValues: orderedIDs.enumerated().map {
                            ($0.element, $0.offset)
                        }
                    )
                )
            }.value
        } onCancel: {
            cancellationFlag.cancel()
        }
        guard !Task.isCancelled,
              categoryFilesRefreshKey.signature == signature else { return }
        let result = computed.files
        categoryFileCount = categoryFiles.count
        displayedFiles = result
        displayedFileIDs = computed.visibleIDs
        displayedFileOrderedIDs = computed.orderedIDs
        displayedFileIDIndex = computed.idIndex
        displayedSignature = signature
        isCategorySearching = false
        appModel.updateCommandTargetFiles(result)
        appModel.clearSelectionIfHidden(from: computed.visibleIDs)
    }

    private var deleteMessage: String {
        let name = categoryToDelete?.localizedDisplayName
            ?? AppLanguage.localized("这个资料集", english: "this collection")
        return AppLanguage.localized(
            "只会删除“\(name)”及其文件关联，不会删除任何原文件。",
            english: "Only “\(name)” and its category relationships will be deleted. No files will be deleted."
        )
    }
}

private struct CategoryFilesRefreshKey: Equatable {
    let filesRevision: UInt64
    let categoryRevision: UInt64
    let categoryID: UUID?
    let kind: FileKind?
    let query: String
    let sortOrder: FileSortOrder
    let ascending: Bool

    var signature: Int {
        var hasher = Hasher()
        hasher.combine(filesRevision)
        hasher.combine(categoryRevision)
        hasher.combine(categoryID)
        hasher.combine(kind)
        hasher.combine(query)
        hasher.combine(sortOrder)
        hasher.combine(ascending)
        return hasher.finalize()
    }
}

struct CategoryEditorSheet: View {
    @Environment(\.appVisualTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let allowsSymbolEditing: Bool
    let submit: (String, String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var symbolName: String
    @State private var isSaving = false
    @State private var failure: String?
    @FocusState private var isNameFocused: Bool

    private let symbols = [
        "folder", "briefcase", "doc.text", "paintbrush", "books.vertical",
        "banknote", "person", "archivebox", "building.2", "star"
    ]

    init(
        title: String,
        initialName: String = "",
        initialSymbol: String = "folder",
        allowsSymbolEditing: Bool = true,
        submit: @escaping (String, String) async throws -> Void
    ) {
        self.title = title
        self.allowsSymbolEditing = allowsSymbolEditing
        self.submit = submit
        _name = State(initialValue: initialName)
        _symbolName = State(initialValue: initialSymbol)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(verbatim: title)
                .font(XunJianUI.Typography.sheetTitle)
            TextField(
                AppLanguage.localized("资料集名称", english: "Collection Name"),
                text: $name
            )
                .textFieldStyle(.roundedBorder)
                .focused($isNameFocused)
                .onSubmit(save)
            if let failure {
                ErrorMessageRow(message: failure)
            }

            if allowsSymbolEditing {
                Picker(
                    AppLanguage.localized("图标", english: "Icon"),
                    selection: $symbolName
                ) {
                    ForEach(symbols, id: \.self) { symbol in
                        Image(systemName: symbol)
                            .tag(symbol)
                        .accessibilityLabel(
                            symbolAccessibilityLabel(symbol)
                        )
                    }
                }
                .pickerStyle(.palette)
            }
            WorkspaceRowSeparator()
            HStack {
                Spacer()
                Button(AppLanguage.localized("取消", english: "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button(AppLanguage.localized("保存", english: "Save"), action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .disabled(isSaving)
            }
        }
        .padding(24)
        .frame(minWidth: 280, idealWidth: 440, maxWidth: 520, alignment: .leading)
        .controlSize(.large)
        .background(theme.palette(for: colorScheme).canvas)
        .onAppear { isNameFocused = true }
        .interactiveDismissDisabled(isSaving)
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        failure = nil
        Task {
            do {
                try await submit(name, symbolName)
                dismiss()
            } catch {
                failure = error.localizedDescription
                isSaving = false
            }
        }
    }

    private func symbolAccessibilityLabel(_ symbol: String) -> String {
        switch symbol {
        case "folder":
            AppLanguage.localized("文件夹图标", english: "Folder icon")
        case "briefcase":
            AppLanguage.localized("公文包图标", english: "Briefcase icon")
        case "doc.text":
            AppLanguage.localized("文档图标", english: "Document icon")
        case "paintbrush":
            AppLanguage.localized("画笔图标", english: "Paintbrush icon")
        case "books.vertical":
            AppLanguage.localized("书籍图标", english: "Books icon")
        case "banknote":
            AppLanguage.localized("钞票图标", english: "Banknote icon")
        case "person":
            AppLanguage.localized("人物图标", english: "Person icon")
        case "archivebox":
            AppLanguage.localized("归档箱图标", english: "Archive box icon")
        case "building.2":
            AppLanguage.localized("建筑图标", english: "Buildings icon")
        case "star":
            AppLanguage.localized("星标图标", english: "Star icon")
        default:
            AppLanguage.localized("资料集图标", english: "Collection icon")
        }
    }
}
