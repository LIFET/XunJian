import SwiftUI

struct CategoriesView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.locale) private var locale
    let selectedCategory: FileCategory?
    let openCategory: (FileCategory) -> Void
    let showAllCategories: () -> Void

    @State private var showsNewCategory = false
    @State private var categoryToRename: FileCategory?
    @State private var categoryToDelete: FileCategory?
    @State private var hoveredCategoryID: UUID?
    @State private var hoveredFileID: String?
    @State private var categoryQuery = ""
    @State private var displayedFiles: [IndexedFile] = []
    @State private var categoryFileCount = 0
    @State private var displayedSignature: Int?

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
            ScrollView {
                VStack(alignment: .leading, spacing: XunJianUI.Spacing.section) {
                    header

                    if let selectedCategory {
                        categoryFiles(selectedCategory, contentWidth: geometry.size.width)
                    } else {
                        categoryOverview
                    }
                }
                .padding(XunJianUI.pagePadding(for: geometry.size.width))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle(
            selectedCategory?.localizedDisplayName
                ?? AppLanguage.localized("分类", english: "Categories")
        )
        .onAppear {
            if selectedCategory != nil {
                appModel.highlightQuery = categoryQuery
            }
            clearSelectionIfHidden()
        }
        .task(id: categoryFilesRefreshKey) {
            await refreshCategoryFilesSnapshot()
        }
        .onChange(of: selectedCategory?.id) { _, _ in
            categoryQuery = ""
            selectedKind = nil
            displayedFiles = []
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
        .onChange(of: selectedKind) { _, _ in clearSelectionIfHidden() }
        .onChange(of: categoryQuery) { _, query in
            if selectedCategory != nil {
                appModel.highlightQuery = query
            }
            clearSelectionIfHidden()
        }
        .onChange(of: appModel.files.count) { _, _ in clearSelectionIfHidden() }
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
        VStack(alignment: .leading, spacing: 10) {
            if selectedCategory != nil {
                Button(action: showAllCategories) {
                    Label(
                        AppLanguage.localized("全部分类", english: "All Categories"),
                        systemImage: "chevron.left"
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    headerIdentity
                    Spacer(minLength: 0)
                    headerAction
                }

                VStack(alignment: .leading, spacing: 10) {
                    headerIdentity
                    headerAction
                }
            }
        }
    }

    private var headerIdentity: some View {
        PageHeader(
            title: selectedCategory?.localizedDisplayName
                ?? AppLanguage.localized("分类", english: "Categories"),
            subtitle: AppLanguage.localized(
                "用简单分类组织文件，一个文件可以属于多个分类。",
                english: "Organize files with simple categories. A file can belong to more than one."
            )
        )
    }

    @ViewBuilder
    private var headerAction: some View {
        if let selectedCategory {
            Menu {
                Button(AppLanguage.localized("修改名称…", english: "Rename…")) {
                    categoryToRename = selectedCategory
                }
                Divider()
                Button(
                    AppLanguage.localized("删除分类", english: "Delete Category"),
                    role: .destructive
                ) {
                    categoryToDelete = selectedCategory
                }
            } label: {
                Label {
                    Text(verbatim: AppLanguage.localized(
                        "管理分类",
                        english: "Manage Category"
                    ))
                } icon: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        } else {
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
                                    .font(.body.weight(.semibold))
                                    .lineLimit(1)
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
                SearchField(
                    text: $categoryQuery,
                    prompt: AppLanguage.localized(
                        "在此分类中搜索…",
                        english: "Search in this category…"
                    ),
                    accessibilityHint: AppLanguage.localized(
                        "只搜索当前分类中的文件",
                        english: "Searches only files in this category"
                    )
                )
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

                if files.isEmpty {
                    kindFilterEmptyState
                } else if viewMode == .grid {
                    categoryFileGrid(files)
                        .fileListKeyboardNavigation(
                            files: files,
                            columnCount: FileGridCard.columnCount(forWidth: contentWidth)
                        )
                } else {
                    categoryFileList(files)
                        .fileListKeyboardNavigation(files: files)
                }
            }
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
                FileGridCard(
                    file: file,
                    isSelected: appModel.selectedFileIDs.contains(file.id),
                    isHovered: hoveredFileID == file.id,
                    onSelect: { appModel.selectDisplayedFile(file, in: files) },
                    onOpen: {
                        appModel.selectedFileID = file.id
                        doubleClickBehavior.perform(on: file, using: appModel)
                    },
                    onHover: { isHovering in
                        hoveredFileID = isHovering ? file.id : nil
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
        GroupedSurface(padding: 4) {
            LazyVStack(spacing: 0) {
                ForEach(files) { file in
                    Button {
                        appModel.selectDisplayedFile(file, in: files)
                    } label: {
                        HStack(spacing: 12) {
                            FileThumbnail(file: file, size: 34)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(verbatim: file.name)
                                    .lineLimit(1)
                                Text(verbatim: file.parentPath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 0)
                            Text(verbatim: FileGridCard.sizeText(file))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .background(
                            categoryFileBackground(for: file),
                            in: RoundedRectangle(
                                cornerRadius: XunJianUI.Radius.row,
                                style: .continuous
                            )
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded {
                            appModel.selectedFileID = file.id
                            doubleClickBehavior.perform(on: file, using: appModel)
                        }
                    )
                    .onHover { isHovering in
                        hoveredFileID = isHovering ? file.id : nil
                    }
                    .contextMenu {
                        FileContextMenu(file: file)
                    }
                    .draggable(file.url)

                    if file.id != files.last?.id {
                        Divider()
                            .padding(.leading, 56)
                    }
                }
            }
        }
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
        guard let selectedCategory else {
            appModel.clearSelectionIfHidden(from: Set(appModel.files.map(\.id)))
            return
        }
        var visible = Set<String>()
        for file in appModel.files(in: selectedCategory)
        where selectedKind == nil || file.kind == selectedKind {
            if categoryQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || QuickSearchMatching.matches(file: file, query: categoryQuery) {
                visible.insert(file.id)
            }
        }
        appModel.clearSelectionIfHidden(from: visible)
    }

    private var categoryFilesRefreshKey: CategoryFilesRefreshKey {
        CategoryFilesRefreshKey(
            filesRevision: appModel.filesRevision,
            categoryRevision: appModel.categoryRevision,
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
            categoryFileCount = 0
            displayedSignature = nil
            return
        }

        let signature = categoryFilesRefreshKey.signature
        if displayedSignature != signature {
            appModel.updateCommandTargetFiles([])
        }
        guard displayedSignature != signature else {
            appModel.updateCommandTargetFiles(displayedFiles)
            return
        }

        let allFiles = appModel.files
        let links = appModel.fileCategoryLinks
        let categoryID = selectedCategory.id
        let kind = selectedKind
        let query = categoryQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let order = sortOrder
        let ascending = sortAscending
        let matchingIDs: Set<String>?
        if query.isEmpty {
            matchingIDs = nil
        } else {
            do {
                let matches = try await appModel.searchFiles(
                    matching: query,
                    limit: max(allFiles.count, 1)
                )
                matchingIDs = Set(matches.map(\.id))
            } catch {
                matchingIDs = nil
            }
        }
        let result = await Task.detached(priority: .userInitiated) {
            let inCategory = allFiles.filter { file in
                links[file.id]?.contains(categoryID) == true
            }
            let displayed = CategoriesView.displayed(
                inCategory,
                kind: kind,
                query: query,
                ftsMatchIDs: matchingIDs,
                sortOrder: order,
                ascending: ascending
            )
            return (inCategory.count, displayed)
        }.value
        guard !Task.isCancelled else { return }
        categoryFileCount = result.0
        displayedFiles = result.1
        displayedSignature = signature
        appModel.updateCommandTargetFiles(result.1)
        clearSelectionIfHidden()
    }

    private var deleteMessage: String {
        let name = categoryToDelete?.localizedDisplayName
            ?? AppLanguage.localized("这个分类", english: "this category")
        return AppLanguage.localized(
            "只会删除“\(name)”及其分类关系，不会删除任何真实文件。",
            english: "Only “\(name)” and its category relationships will be deleted. No files will be deleted."
        )
    }

    private func categoryFileBackground(for file: IndexedFile) -> Color {
        if appModel.selectedFileIDs.contains(file.id) {
            return XunJianUI.Fill.selectedSoft
        }
        return hoveredFileID == file.id ? XunJianUI.Fill.hover : .clear
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

    @ScaledMetric(relativeTo: .body) private var symbolPickerIconSize: CGFloat = 14
    @ScaledMetric(relativeTo: .body) private var symbolPickerItemSide: CGFloat = 36

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
                .font(.title2.weight(.semibold))
            TextField(
                AppLanguage.localized("分类名称", english: "Category Name"),
                text: $name
            )
                .textFieldStyle(.roundedBorder)
                .focused($isNameFocused)
                .onSubmit(save)
            if let failure {
                Text(AppLanguage.localizedRuntimeMessage(failure))
                    .font(.caption)
                    .foregroundStyle(XunJianUI.Semantic.danger)
            }

            if allowsSymbolEditing {
                Text(AppLanguage.localized("图标", english: "Icon"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 40))], spacing: 8) {
                    ForEach(symbols, id: \.self) { symbol in
                        Button {
                            symbolName = symbol
                        } label: {
                            Image(systemName: symbol)
                                .font(.system(size: symbolPickerIconSize, weight: .medium))
                                .frame(width: symbolPickerItemSide, height: symbolPickerItemSide)
                                .foregroundStyle(symbolName == symbol ? Color.accentColor : .primary)
                                .background {
                                    RoundedRectangle(
                                        cornerRadius: XunJianUI.Radius.chip,
                                        style: .continuous
                                    )
                                    .fill(
                                        symbolName == symbol
                                            ? XunJianUI.Fill.selected
                                            : XunJianUI.Fill.quiet
                                    )
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            symbolAccessibilityLabel(symbol)
                        )
                        .accessibilityValue(
                            symbolName == symbol
                                ? AppLanguage.localized("已选择", english: "Selected")
                                : ""
                        )
                    }
                }
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
