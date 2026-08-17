import SwiftUI

struct CategoriesView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var categoryIndex: CategoryIndexStore
    @Environment(\.locale) private var locale
    let selectedCategory: FileCategory?
    let openCategory: (FileCategory) -> Void
    let showAllCategories: () -> Void

    @State private var showsNewCategory = false
    @State private var categoryToRename: FileCategory?
    @State private var categoryToDelete: FileCategory?
    @State private var hoveredCategoryID: UUID?
    @State private var categoryQuery = ""
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
    @State private var selectedKind: FileKind?
    @AppStorage(FileActivationBehavior.storageKey)
    private var doubleClickBehavior = FileActivationBehavior.open

    @ScaledMetric(relativeTo: .body) private var categoryIconSize: CGFloat = 16
    @ScaledMetric(relativeTo: .body) private var categoryIconContainer: CGFloat = 32

    private let columns = [
        GridItem(.adaptive(minimum: XunJianUI.Breakpoint.categoryCardMin), spacing: 12)
    ]

    init(
        selectedCategory: FileCategory?,
        openCategory: @escaping (FileCategory) -> Void = { _ in },
        showAllCategories: @escaping () -> Void = {}
    ) {
        self.selectedCategory = selectedCategory
        self.openCategory = openCategory
        self.showAllCategories = showAllCategories
    }

    var body: some View {
        GeometryReader { geometry in
            if let selectedCategory {
                VStack(alignment: .leading, spacing: XunJianUI.Spacing.section) {
                    header
                    categoryFiles(selectedCategory, contentWidth: geometry.size.width)
                }
                .padding(XunJianUI.pagePadding(for: geometry.size.width))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: XunJianUI.Spacing.section) {
                        header
                        categoryOverview
                    }
                    .padding(XunJianUI.pagePadding(for: geometry.size.width))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
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
            categoryQuery = ""
            selectedKind = nil
            displayedFiles = []
            displayedFileIDs = []
            displayedFileOrderedIDs = []
            displayedFileIDIndex = [:]
            categoryFileCount = 0
            displayedSignature = nil
            appModel.updateCommandTargetFiles([])
            appModel.highlightQuery = ""
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
                title: AppLanguage.localized("新建分类", english: "New Category")
            ) { name, symbolName in
                try await appModel.createCategory(name: name, symbolName: symbolName)
            }
            .environment(\.locale, locale)
        }
        .sheet(item: $categoryToRename) { category in
            CategoryEditorSheet(
                title: AppLanguage.localized("修改分类名称", english: "Rename Category"),
                initialName: category.name,
                initialSymbol: category.symbolName,
                allowsSymbolEditing: false
            ) { name, _ in
                try await appModel.renameCategory(category, to: name)
            }
            .environment(\.locale, locale)
        }
        .alert(
            AppLanguage.localized("删除分类？", english: "Delete Category?"),
            isPresented: Binding(
                get: { categoryToDelete != nil },
                set: { if !$0 { categoryToDelete = nil } }
            )
        ) {
            Button(AppLanguage.localized("取消", english: "Cancel"), role: .cancel) {
                categoryToDelete = nil
            }
            Button(
                AppLanguage.localized("删除分类", english: "Delete Category"),
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
        Group {
            if let selectedCategory {
                HStack(spacing: 10) {
                    Button(action: showAllCategories) {
                        Label(
                            AppLanguage.localized("全部分类", english: "All Categories"),
                            systemImage: "chevron.left"
                        )
                    }
                    .buttonStyle(.bordered)

                    Spacer(minLength: 0)

                    Menu {
                        Button {
                            categoryToRename = selectedCategory
                        } label: {
                            Label(
                                AppLanguage.localized("修改名称…", english: "Rename…"),
                                systemImage: "pencil"
                            )
                        }
                        Divider()
                        Button(role: .destructive) {
                            categoryToDelete = selectedCategory
                        } label: {
                            Label(
                                AppLanguage.localized("删除分类…", english: "Delete Category…"),
                                systemImage: "trash"
                            )
                        }
                    } label: {
                        Label(
                            AppLanguage.localized("编辑分类", english: "Edit Category"),
                            systemImage: "pencil"
                        )
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.regular)
            } else {
                HStack {
                    Spacer(minLength: 0)
                    headerAction
                }
            }
        }
    }

    @ViewBuilder
    private var headerAction: some View {
        if selectedCategory == nil {
            Button {
                showsNewCategory = true
            } label: {
                Label(
                    AppLanguage.localized("新建分类", english: "New Category"),
                    systemImage: "plus"
                )
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
    }

    @ViewBuilder
    private var categoryOverview: some View {
        if appModel.categories.isEmpty {
            ContentUnavailableView(
                AppLanguage.localized("还没有分类", english: "No Categories Yet"),
                systemImage: "folder.badge.plus",
                description: Text(
                    AppLanguage.localized(
                        "创建分类后，可以从文件右键菜单或详情栏添加。",
                        english: "After you create a category, add files from the context menu or inspector."
                    )
                )
            )
            .frame(
                maxWidth: .infinity,
                minHeight: XunJianUI.Breakpoint.categoryEmptyStateHeight
            )
            .background(
                XunJianUI.Fill.quiet,
                in: RoundedRectangle(cornerRadius: XunJianUI.Radius.card, style: .continuous)
            )
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(appModel.categories) { category in
                    Button {
                        openCategory(category)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: category.symbolName)
                                .font(.system(size: categoryIconSize, weight: .medium))
                                .foregroundStyle(.tint)
                                .frame(width: categoryIconContainer, height: categoryIconContainer)
                                .background(
                                    Color.accentColor.opacity(0.10),
                                    in: RoundedRectangle(
                                        cornerRadius: XunJianUI.Radius.chip,
                                        style: .continuous
                                    )
                                )
                            VStack(alignment: .leading, spacing: 3) {
                                Text(verbatim: category.localizedDisplayName)
                                    .font(XunJianUI.Typography.itemTitle)
                                    .lineLimit(1)
                                    .help(category.localizedDisplayName)
                                Text(verbatim: AppLanguage.fileCount(appModel.fileCount(in: category)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .background {
                            InteractiveCardBackground(
                                isHovered: hoveredCategoryID == category.id
                            )
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SoftCardButtonStyle())
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
                            AppLanguage.localized("删除分类", english: "Delete Category"),
                            role: .destructive
                        ) { categoryToDelete = category }
                    }
                }
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
                    "这个分类里还没有文件",
                    english: "No Files in This Category"
                ),
                systemImage: category.symbolName,
                description: Text(
                    AppLanguage.localized(
                        "从文件右键菜单或详情栏为文件添加分类。",
                        english: "Add files to this category from the context menu or inspector."
                    )
                )
            )
            .frame(
                maxWidth: .infinity,
                minHeight: XunJianUI.Breakpoint.categoryEmptyStateHeight
            )
            .background(
                XunJianUI.Fill.quiet,
                in: RoundedRectangle(cornerRadius: XunJianUI.Radius.card, style: .continuous)
            )
        } else {
            VStack(alignment: .leading, spacing: XunJianUI.Spacing.sectionInner) {
                HStack(spacing: 8) {
                    SearchField(
                        text: $categoryQuery,
                        prompt: AppLanguage.localized(
                            "在此分类中搜索…",
                            english: "Search in this category…"
                        ),
                        accessibilityHint: AppLanguage.localized(
                            "只搜索当前分类中的文件",
                            english: "Searches only files in this category"
                        ),
                        focusScope: .category
                    )
                    if isCategorySearching {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(Text(verbatim: AppLanguage.localized(
                                "正在搜索",
                                english: "Searching"
                            )))
                    }
                }
                FileBrowseToolbar(
                    selectedKind: $selectedKind,
                    sortOrder: $sortOrder,
                    sortAscending: $sortAscending,
                    viewMode: $viewMode
                )
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
        .background(
            XunJianUI.Fill.quiet,
            in: RoundedRectangle(cornerRadius: XunJianUI.Radius.card, style: .continuous)
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
            ?? AppLanguage.localized("这个分类", english: "this category")
        return AppLanguage.localized(
            "只会删除“\(name)”及其分类关系，不会删除任何真实文件。",
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
                AppLanguage.localized("分类名称", english: "Category Name"),
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
            AppLanguage.localized("分类图标", english: "Category icon")
        }
    }
}
