import SwiftUI

struct AllFilesView: View {
    enum ViewMode: String, CaseIterable, Identifiable {
        case list
        case grid

        var id: String { rawValue }
        var symbolName: String { self == .list ? "list.bullet" : "square.grid.2x2" }
    }

    @EnvironmentObject private var appModel: AppModel
    @Environment(\.locale) private var locale

    let windowWidth: CGFloat
    let contentWidth: CGFloat

    @AppStorage("allFiles.viewMode") private var viewMode = ViewMode.list
    @AppStorage("allFiles.sortOrder") private var browseSortOrder = FileSortOrder.modifiedAt
    @AppStorage("allFiles.sortAscending") private var browseSortAscending = false
    @AppStorage("allFiles.searchSortOrder") private var searchSortOrder = FileSortOrder.relevance
    @AppStorage("allFiles.searchSortAscending") private var searchSortAscending = false
    @AppStorage("allFiles.tableColumnCustomization")
    private var tableColumnCustomization = TableColumnCustomization<IndexedFile>()
    @State private var aiTaskSheet: AITaskSheet?
    @State private var displayedFilesSnapshot: [IndexedFile] = []
    @State private var hasPreparedDisplayedFilesSnapshot = false
    @State private var hoveredGridFileID: String?
    @AppStorage("allFiles.listScrollPosition") private var listScrollPosition = ""
    @AppStorage("allFiles.gridScrollPosition") private var gridScrollPosition = ""

    @MainActor private static var finderDateFormatters: [String: DateFormatter] = [:]

    @MainActor private static func cachedFinderDateFormatter(for locale: Locale) -> DateFormatter {
        if let formatter = finderDateFormatters[locale.identifier] {
            return formatter
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = .autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        finderDateFormatters[locale.identifier] = formatter
        return formatter
    }

    private var finderDateFormatter: DateFormatter {
        Self.cachedFinderDateFormatter(for: locale)
    }

    init(windowWidth: CGFloat, contentWidth: CGFloat) {
        self.windowWidth = windowWidth
        self.contentWidth = contentWidth
    }

    var body: some View {
        let filesSnapshot = displayedFilesSnapshot
        return content(filesSnapshot: filesSnapshot)
    }

    private func content(filesSnapshot: [IndexedFile]) -> some View {
        let content = VStack(spacing: 0) {
            fileHeader(filesSnapshot: filesSnapshot)
            Divider().opacity(0.7)
            emptyState(files: filesSnapshot)
        }
        return content
            .navigationTitle(AppLanguage.localized("所有文件", english: "All Files"))
            .task(id: displayedFilesRefreshKey) {
                await refreshDisplayedFilesSnapshot()
            }
            .sheet(item: $aiTaskSheet, content: aiSheet)
    }

    @ViewBuilder
    private func aiSheet(_ task: AITaskSheet) -> some View {
        Group {
            switch task {
            case .search:
                AISearchSheet()
            case let .explain(file):
                AIExplainSheet(file: file)
            case let .ask(file):
                AIQuestionSheet(file: file)
            case .classify:
                AIClassificationSheet(initialFileID: appModel.selectedFileID)
            }
        }
        .environment(\.locale, locale)
        // Gives the AI sheets a sense of layering above the content behind
        // them. If this reads as too translucent on macOS, drop this line.
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func fileHeader(filesSnapshot: [IndexedFile]) -> some View {
        header(resultCount: filesSnapshot.count)
        if appModel.selectedFileIDs.count > 1 {
            batchActionBar
        }
        if let plan = appModel.aiSearchPlan {
            HStack(spacing: 8) {
                Label(aiSearchModeDescription(for: plan), systemImage: "sparkles")
                    .symbolRenderingMode(.hierarchical)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("清除") {
                    appModel.clearAISearch()
                }
                .buttonStyle(.link)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                XunJianUI.Fill.accentWash,
                in: RoundedRectangle(cornerRadius: XunJianUI.Radius.chip, style: .continuous)
            )
            .padding(.horizontal, XunJianUI.pagePadding(for: contentWidth))
            .padding(.bottom, 10)
        }
    }

    /// Batch operations bar, shown while multiple files are selected (F05).
    private var batchActionBar: some View {
        HStack(spacing: 8) {
            Label(
                AppLanguage.localized(
                    "已选择 \(appModel.selectedFileIDs.count) 项",
                    english: "\(appModel.selectedFileIDs.count) selected"
                ),
                systemImage: "checkmark.circle.fill"
            )
            Spacer(minLength: 8)
            Menu {
                if appModel.categories.isEmpty {
                    Text(AppLanguage.localized("还没有分类", english: "No categories yet"))
                } else {
                    ForEach(appModel.categories) { category in
                        Button {
                            appModel.assignSelectedFiles(to: category)
                        } label: {
                            Label(category.localizedDisplayName, systemImage: category.symbolName)
                        }
                    }
                }
            } label: {
                Label(
                    AppLanguage.localized("批量加分类", english: "Add to Category"),
                    systemImage: "folder.badge.plus"
                )
            }
            .fixedSize()
            Button(role: .destructive) {
                appModel.requestBatchTrash()
            } label: {
                Label(
                    AppLanguage.localized("移到废纸篓", english: "Move to Trash"),
                    systemImage: "trash"
                )
            }
            Button {
                appModel.selectedFileIDs = []
            } label: {
                Label(
                    AppLanguage.localized("取消选择", english: "Clear Selection"),
                    systemImage: "xmark"
                )
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            XunJianUI.Fill.selectedSoft,
            in: RoundedRectangle(cornerRadius: XunJianUI.Radius.chip, style: .continuous)
        )
        .padding(.horizontal, XunJianUI.pagePadding(for: contentWidth))
        .padding(.bottom, 10)
        .xunjianAnimation(value: appModel.selectedFileIDs.count > 1)
    }

    private func header(resultCount: Int) -> some View {
        HStack(spacing: 12) {
            headerSummary(resultCount: resultCount)
                .layoutPriority(1)
            Spacer(minLength: 8)
            searchProgress
            responsiveFileToolbar
        }
        .padding(.horizontal, XunJianUI.pagePadding(for: contentWidth))
        .padding(.vertical, 14)
    }

    private func headerSummary(resultCount: Int) -> some View {
        PageHeader(
            title: AppLanguage.localized("所有文件", english: "All Files"),
            subtitle: usesCompactHeader
                ? AppLanguage.fileCount(resultCount)
                : resultDescription(resultCount: resultCount),
            compactSubtitle: true
        )
    }

    @ViewBuilder
    private var searchProgress: some View {
        if appModel.isSearching {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(AppLanguage.localized("正在搜索", english: "Searching"))
        } else if appModel.hasMoreSearchResults {
            Button {
                appModel.loadMoreSearchResults()
            } label: {
                Text(
                    AppLanguage.localized(
                        "加载更多（\(appModel.searchResults?.count ?? 0)/\(appModel.searchResultTotalCount ?? 0)）",
                        english: "Load More (\(appModel.searchResults?.count ?? 0)/\(appModel.searchResultTotalCount ?? 0))"
                    )
                )
            }
            .buttonStyle(.link)
            .accessibilityHint(
                AppLanguage.localized(
                    "当前仅显示前 \(appModel.searchResults?.count ?? 0) 项搜索结果",
                    english: "Currently showing the first \(appModel.searchResults?.count ?? 0) search results"
                )
            )
        }
    }

    private func aiMenu(compact: Bool) -> some View {
        let hasAIProvider = appModel.activeAIProviderKind != nil
        return Menu {
            if !hasAIProvider {
                Text("请先在设置中配置当前 AI")
                SettingsLink {
                    Label("打开设置…", systemImage: "gearshape")
                }
            }
            Button("AI 搜文件…") {
                aiTaskSheet = .search
            }
            .disabled(!hasAIProvider)
            Divider()
            Button("AI 看文件") {
                if let file = appModel.selectedFile {
                    aiTaskSheet = .explain(file)
                }
            }
            .disabled(!hasAIProvider || appModel.selectedFile == nil)
            Button("AI 问文件…") {
                if let file = appModel.selectedFile {
                    aiTaskSheet = .ask(file)
                }
            }
            .disabled(!hasAIProvider || appModel.selectedFile == nil)
            Button("AI 分类…") {
                aiTaskSheet = .classify
            }
            .disabled(!hasAIProvider || appModel.files.isEmpty || appModel.categories.isEmpty)
        } label: {
            if compact {
                FileToolbarIconLabel(systemName: "sparkles")
            } else {
                FileToolbarMenuLabel(
                    title: appModel.activeAIProviderKind?.title ?? "AI",
                    systemName: "sparkles"
                )
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(
            width: compact ? FileToolbarMetrics.iconButtonSide : nil,
            height: FileToolbarMetrics.controlHeight
        )
        .fixedSize()
        .accessibilityLabel("AI")
    }

    private var usesCompactHeader: Bool {
        contentWidth < XunJianUI.Breakpoint.compactPage
    }

    private var responsiveFileToolbar: some View {
        ViewThatFits(in: .horizontal) {
            fileToolbarRow(
                compactAI: false,
                showsFileType: true,
                showsSort: true,
                showsSortDirection: true,
                showsViewMode: true,
                spacing: FileToolbarMetrics.regularSpacing
            )
            fileToolbarRow(
                compactAI: false,
                showsFileType: true,
                showsSort: true,
                showsSortDirection: true,
                showsViewMode: false,
                spacing: FileToolbarMetrics.regularSpacing
            )
            fileToolbarRow(
                compactAI: true,
                showsFileType: true,
                showsSort: true,
                showsSortDirection: false,
                showsViewMode: false,
                spacing: FileToolbarMetrics.compactSpacing
            )
            fileToolbarRow(
                compactAI: true,
                showsFileType: true,
                showsSort: false,
                showsSortDirection: false,
                showsViewMode: false,
                spacing: FileToolbarMetrics.compactSpacing
            )
            fileToolbarRow(
                compactAI: true,
                showsFileType: false,
                showsSort: false,
                showsSortDirection: false,
                showsViewMode: false,
                spacing: FileToolbarMetrics.compactSpacing
            )
        }
    }

    private func fileToolbarRow(
        compactAI: Bool,
        showsFileType: Bool,
        showsSort: Bool,
        showsSortDirection: Bool,
        showsViewMode: Bool,
        spacing: CGFloat
    ) -> some View {
        HStack(spacing: spacing) {
            aiMenu(compact: compactAI)

            if showsFileType {
                fileTypeMenu
            }

            if showsSort {
                sortMenu
            }

            if showsSortDirection {
                sortDirectionButton
            }

            if showsViewMode {
                viewModeControl
            }

            if !showsFileType || !showsSort || !showsSortDirection || !showsViewMode {
                overflowMenu(
                    includesFileType: !showsFileType,
                    includesSort: !showsSort,
                    includesSortDirection: !showsSortDirection,
                    includesViewMode: !showsViewMode
                )
            }
        }
        .frame(height: FileToolbarMetrics.controlHeight)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var fileTypeMenu: some View {
        Menu {
            Button {
                appModel.selectedKind = nil
            } label: {
                if appModel.selectedKind == nil {
                    Label("所有类型", systemImage: "checkmark")
                } else {
                    Text("所有类型")
                }
            }

            ForEach(FileKind.allCases) { kind in
                Button {
                    appModel.selectedKind = kind
                } label: {
                    if appModel.selectedKind == kind {
                        Label(kind.localizedTitle, systemImage: "checkmark")
                    } else {
                        Text(kind.localizedTitle)
                    }
                }
            }
        } label: {
            FileToolbarPopupLabel(
                title: appModel.selectedKind?.localizedTitle
                    ?? AppLanguage.localized("所有类型", english: "All Types"),
                width: FileToolbarMetrics.fileTypeWidth
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(AppLanguage.localized("文件类型", english: "File Type"))
    }

    private var sortMenu: some View {
        Menu {
            ForEach(availableSortOrders) { order in
                Button {
                    activeSortOrder = order
                    activeSortAscending = order == .name || order == .kind
                } label: {
                    if activeSortOrder == order {
                        Label(order.localizedTitle, systemImage: "checkmark")
                    } else {
                        Text(order.localizedTitle)
                    }
                }
            }
        } label: {
            FileToolbarPopupLabel(
                title: activeSortOrder.localizedTitle,
                width: FileToolbarMetrics.sortWidth(for: activeSortOrder)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(AppLanguage.localized("排序", english: "Sort"))
    }

    private var viewModeControl: some View {
        HStack(spacing: 0) {
            ForEach(ViewMode.allCases) { mode in
                Button {
                    viewMode = mode
                } label: {
                    Image(systemName: mode.symbolName)
                        .font(.system(size: FileToolbarMetrics.symbolSize, weight: .medium))
                        .frame(
                            width: FileToolbarMetrics.viewModeItemWidth,
                            height: FileToolbarMetrics.controlHeight - 2
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(viewMode == mode ? Color.white : Color.primary)
                .background {
                    RoundedRectangle(
                        cornerRadius: FileToolbarMetrics.innerCornerRadius,
                        style: .continuous
                    )
                        .fill(
                            viewMode == mode
                                ? Color.accentColor
                                : Color.clear
                        )
                }
                .accessibilityLabel(mode == .list ? "列表" : "图标")
                .accessibilityAddTraits(viewMode == mode ? .isSelected : [])
            }
        }
        .padding(1)
        .frame(
            width: FileToolbarMetrics.viewModeWidth,
            height: FileToolbarMetrics.controlHeight
        )
        .background(
            FileToolbarMetrics.controlFill,
            in: RoundedRectangle(
                cornerRadius: FileToolbarMetrics.cornerRadius,
                style: .continuous
            )
        )
        .fixedSize()
    }

    @ViewBuilder
    private var fileTypeChoices: some View {
        Text("所有类型").tag(FileKind?.none)
        ForEach(FileKind.allCases) { kind in
            Text(kind.localizedTitle).tag(Optional(kind))
        }
    }

    @ViewBuilder
    private var sortChoices: some View {
        ForEach(availableSortOrders) { order in
            Text(order.localizedTitle).tag(order)
        }
    }

    private var sortDirectionButton: some View {
        Button {
            activeSortAscending.toggle()
        } label: {
            FileToolbarIconLabel(
                systemName: activeSortAscending ? "arrow.up" : "arrow.down"
            )
        }
        .buttonStyle(.plain)
        .frame(
            width: FileToolbarMetrics.iconButtonSide,
            height: FileToolbarMetrics.iconButtonSide
        )
        .help(
            AppLanguage.localized(
                activeSortAscending ? "升序" : "降序",
                english: activeSortAscending ? "Ascending" : "Descending"
            )
        )
        .accessibilityLabel(
            AppLanguage.localized(
                activeSortAscending ? "升序" : "降序",
                english: activeSortAscending ? "Ascending" : "Descending"
            )
        )
        .disabled(activeSortOrder == .relevance)
    }

    private func overflowMenu(
        includesFileType: Bool,
        includesSort: Bool,
        includesSortDirection: Bool,
        includesViewMode: Bool
    ) -> some View {
        Menu {
            if includesFileType {
                Picker("文件类型", selection: $appModel.selectedKind) {
                    fileTypeChoices
                }
            }
            if includesSort {
                Picker("排序", selection: activeSortOrderBinding) {
                    sortChoices
                }
            }
            if includesSortDirection {
                Button(
                    AppLanguage.localized(
                        activeSortAscending ? "切换为降序" : "切换为升序",
                        english: activeSortAscending ? "Switch to Descending" : "Switch to Ascending"
                    )
                ) {
                    activeSortAscending.toggle()
                }
                .disabled(activeSortOrder == .relevance)
            }
            if includesViewMode {
                Picker("显示方式", selection: $viewMode) {
                    Label("列表", systemImage: ViewMode.list.symbolName)
                        .tag(ViewMode.list)
                    Label("图标", systemImage: ViewMode.grid.symbolName)
                        .tag(ViewMode.grid)
                }
            }
        } label: {
            FileToolbarIconLabel(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .frame(
            width: FileToolbarMetrics.iconButtonSide,
            height: FileToolbarMetrics.iconButtonSide
        )
        .help(AppLanguage.localized("更多工具", english: "More Tools"))
        .accessibilityLabel(AppLanguage.localized("更多工具", english: "More Tools"))
        .menuIndicator(.hidden)
    }

    private func emptyState(files: [IndexedFile]) -> some View {
        Group {
            if !hasPreparedDisplayedFilesSnapshot, !sourceFilesForDisplay.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(
                        AppLanguage.localized("正在准备文件列表", english: "Preparing file list")
                    )
            } else if viewMode == .list, !files.isEmpty {
                fileTable(files: files)
            } else if viewMode == .grid, !files.isEmpty {
                fileGrid(files: files)
            } else {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: "tray")
                } description: {
                    Text(emptyDescription)
                } actions: {
                    if !appModel.isDatabaseAvailable {
                        Button(AppLanguage.localized("重试", english: "Retry")) {
                            Task { await appModel.retryDatabase() }
                        }
                    } else if appModel.aiSearchResults != nil {
                        Button(AppLanguage.localized("清除 AI 搜索", english: "Clear AI Search")) {
                            appModel.clearAISearch()
                        }
                        .buttonStyle(.borderedProminent)
                        if !appModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button(AppLanguage.localized("清除关键词", english: "Clear Keyword")) {
                                appModel.searchText = ""
                            }
                        }
                    } else if !appModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button(AppLanguage.localized("清除搜索", english: "Clear Search")) {
                            appModel.searchText = ""
                        }
                        .buttonStyle(.borderedProminent)
                    } else if appModel.selectedKind != nil,
                              appModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              appModel.aiSearchResults == nil,
                              !appModel.files.isEmpty {
                        Button(
                            AppLanguage.localized("清除类型筛选", english: "Clear Type Filter")
                        ) {
                            appModel.selectedKind = nil
                        }
                    } else if appModel.sources.isEmpty {
                        Button("添加文件夹") {
                            appModel.chooseFolder()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .xunjianAnimation(value: viewMode)
        .xunjianAnimation(value: hasPreparedDisplayedFilesSnapshot)
        .xunjianAnimation(value: appModel.isSearching)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resultDescription(resultCount: Int) -> String {
        let query = appModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix: String
        if appModel.aiSearchResults != nil {
            let aiQuery = appModel.aiSearchQuery ?? ""
            prefix = aiQuery.isEmpty
                ? AppLanguage.localized("AI 搜索 · ", english: "AI Search · ")
                : AppLanguage.localized("AI “\(aiQuery)” · ", english: "AI “\(aiQuery)” · ")
        } else if !query.isEmpty {
            prefix = "“\(query)” · "
        } else {
            prefix = ""
        }
        let count = AppLanguage.fileCount(resultCount)
        if let selectedKind = appModel.selectedKind {
            return "\(prefix)\(selectedKind.localizedTitle) · \(count)"
        }
        return "\(prefix)\(count)"
    }

    private func aiSearchDescription(for plan: AISearchPlan) -> String {
        let separator = AppLanguage.selected.usesEnglish ? ", " : "、"
        let keywords = plan.keywords.isEmpty
            ? AppLanguage.localized("无关键词限制", english: "No keyword limit")
            : plan.keywords.joined(separator: separator)
        let kinds = plan.fileKinds.isEmpty
            ? AppLanguage.localized("所有类型", english: "All types")
            : plan.fileKinds.map(\.localizedTitle).sorted().joined(separator: separator)
        return AppLanguage.localized(
            "AI 本地检索：\(keywords) · \(kinds)",
            english: "Local AI search: \(keywords) · \(kinds)"
        )
    }

    private func aiSearchModeDescription(for plan: AISearchPlan) -> String {
        let query = appModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = aiSearchDescription(for: plan)
        guard !query.isEmpty else { return description }
        return AppLanguage.localized(
            "\(description) · 本地关键词：\(query)",
            english: "\(description) · Local keyword: \(query)"
        )
    }

    private var emptyTitle: String {
        if !appModel.isDatabaseAvailable {
            return AppLanguage.localized("本地索引不可用", english: "Local index unavailable")
        }
        if appModel.aiSearchResults != nil {
            return AppLanguage.localized(
                "AI 没有找到相关文件",
                english: "AI found no matching files"
            )
        }
        if appModel.selectedKind != nil,
           appModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !appModel.files.isEmpty {
            return AppLanguage.localized(
                "没有这种类型的文件",
                english: "No files of this type"
            )
        }
        return appModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? AppLanguage.localized("还没有文件", english: "No files yet")
            : AppLanguage.localized("没有找到相关文件", english: "No matching files")
    }

    private var emptyDescription: String {
        if !appModel.isDatabaseAvailable {
            return AppLanguage.localized(
                "文件索引无法读取，依赖索引的操作已暂停。",
                english: "The file index could not be read, so index-dependent actions are paused."
            )
        }
        if appModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if appModel.aiSearchResults != nil {
                return AppLanguage.localized(
                    "可以清除 AI 搜索，或者换一种描述重试。",
                    english: "Clear the AI search or try a different description."
                )
            }
            if appModel.selectedKind != nil, !appModel.files.isEmpty {
                return AppLanguage.localized(
                    "清除类型筛选即可返回所有文件。",
                    english: "Clear the type filter to return to all files."
                )
            }
            return AppLanguage.localized(
                "添加扫描位置并建立索引后，文件会显示在这里。",
                english: "Files appear here after you add a location and build its index."
            )
        }
        return AppLanguage.localized(
            "尝试换一个关键词，或者描述你记得的内容。",
            english: "Try another keyword or describe what you remember."
        )
    }

    private var sourceFilesForDisplay: [IndexedFile] {
        let query = appModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let aiSearchResults = appModel.aiSearchResults {
            guard !query.isEmpty else { return aiSearchResults }
            let matchingFileIDs = Set((appModel.searchResults ?? []).map(\.id))
            return aiSearchResults.filter { matchingFileIDs.contains($0.id) }
        }
        if !query.isEmpty {
            return appModel.searchResults ?? (appModel.isSearching ? appModel.files : [])
        }
        return appModel.files
    }

    private var availableSortOrders: [FileSortOrder] {
        Self.availableSortOrders(hasActiveSearch: hasActiveSearch)
    }

    private var activeSortOrder: FileSortOrder {
        get {
            Self.selectedSortOrder(
                hasActiveSearch: hasActiveSearch,
                browse: browseSortOrder,
                search: searchSortOrder
            )
        }
        nonmutating set {
            if hasActiveSearch {
                searchSortOrder = newValue
            } else {
                browseSortOrder = Self.normalizedSortOrder(
                    newValue,
                    hasActiveSearch: false
                )
            }
        }
    }

    private var activeSortAscending: Bool {
        get { hasActiveSearch ? searchSortAscending : browseSortAscending }
        nonmutating set {
            if hasActiveSearch {
                searchSortAscending = newValue
            } else {
                browseSortAscending = newValue
            }
        }
    }

    private var activeSortOrderBinding: Binding<FileSortOrder> {
        Binding(
            get: { activeSortOrder },
            set: {
                activeSortOrder = $0
                activeSortAscending = $0 == .name || $0 == .kind
            }
        )
    }

    private var listScrollPositionBinding: Binding<String?> {
        persistedScrollPositionBinding(for: $listScrollPosition)
    }

    private var gridScrollPositionBinding: Binding<String?> {
        persistedScrollPositionBinding(for: $gridScrollPosition)
    }

    private func persistedScrollPositionBinding(
        for storedValue: Binding<String>
    ) -> Binding<String?> {
        Binding(
            get: { storedValue.wrappedValue.isEmpty ? nil : storedValue.wrappedValue },
            set: { storedValue.wrappedValue = $0 ?? "" }
        )
    }

    private var hasActiveSearch: Bool {
        appModel.aiSearchResults != nil
            || !appModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func availableSortOrders(hasActiveSearch: Bool) -> [FileSortOrder] {
        hasActiveSearch
            ? FileSortOrder.allCases
            : FileSortOrder.allCases.filter { $0 != .relevance }
    }

    static func normalizedSortOrder(
        _ sortOrder: FileSortOrder,
        hasActiveSearch: Bool
    ) -> FileSortOrder {
        !hasActiveSearch && sortOrder == .relevance ? .modifiedAt : sortOrder
    }

    static func selectedSortOrder(
        hasActiveSearch: Bool,
        browse: FileSortOrder,
        search: FileSortOrder
    ) -> FileSortOrder {
        hasActiveSearch
            ? search
            : normalizedSortOrder(browse, hasActiveSearch: false)
    }

    private var displayedFilesRefreshKey: DisplayedFilesRefreshKey {
        DisplayedFilesRefreshKey(
            sourceFiles: sourceFilesForDisplay,
            selectedKind: appModel.selectedKind,
            sortOrder: activeSortOrder,
            sortAscending: activeSortAscending
        )
    }

    private func refreshDisplayedFilesSnapshot() async {
        let sourceFiles = sourceFilesForDisplay
        let selectedKind = appModel.selectedKind
        let requestedSortOrder = activeSortOrder
        let requestedAscending = activeSortAscending
        let result = await Task.detached(priority: .userInitiated) {
            let filteredFiles = sourceFiles.filter { file in
                selectedKind.map { file.kind == $0 } ?? true
            }
            return requestedSortOrder.sorted(filteredFiles, ascending: requestedAscending)
        }.value
        guard !Task.isCancelled else { return }
        displayedFilesSnapshot = result
        hasPreparedDisplayedFilesSnapshot = true
        appModel.clearSelectionIfHidden(from: Set(result.map(\.id)))
    }

    private func fileTable(files: [IndexedFile]) -> some View {
        Table(
            files,
            selection: $appModel.selectedFileIDs,
            columnCustomization: $tableColumnCustomization
        ) {
            TableColumn("名称") { file in
                selectableTableCell(file: file) {
                    HStack(spacing: 8) {
                        FileThumbnail(file: file, size: 24)
                            .accessibilityHidden(true)
                        Text(file.name)
                            .lineLimit(1)
                    }
                    // The name cell carries a summary of the whole row, so
                    // VoiceOver users hear what the file is without having to
                    // step through all six columns.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: rowAccessibilityLabel(for: file)))
                }
            }
            .width(min: 150, ideal: nameColumnWidth, max: nameColumnWidth)
            .customizationID("name")

            TableColumn("分类") { file in
                let categoryNames = appModel.categories(for: file).map(\.localizedDisplayName)
                selectableTableCell(file: file) {
                    Text(
                        categoryNames.isEmpty
                            ? "—"
                            : categoryNames.joined(
                                separator: AppLanguage.selected.usesEnglish ? ", " : "、"
                            )
                    )
                        .lineLimit(1)
                }
            }
            .width(min: 45, ideal: categoryColumnWidth, max: categoryColumnWidth)
            .customizationID("category")

            TableColumn("类型") { file in
                selectableTableCell(file: file) {
                    Text(file.kind.localizedTitle)
                        .lineLimit(1)
                }
            }
            .width(min: 45, ideal: typeColumnWidth, max: typeColumnWidth)
            .customizationID("type")

            TableColumn("大小") { file in
                selectableTableCell(file: file) {
                    Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                        .lineLimit(1)
                }
            }
            .width(min: 50, ideal: sizeColumnWidth, max: sizeColumnWidth)
            .customizationID("size")

            TableColumn("修改时间") { file in
                selectableTableCell(file: file) {
                    if let modifiedAt = file.modifiedAt {
                        Text(finderDateFormatter.string(from: modifiedAt))
                    } else {
                        Text("—")
                    }
                }
            }
            .width(min: 90, ideal: modifiedColumnWidth, max: modifiedColumnWidth)
            .customizationID("modified")

            TableColumn("位置") { file in
                selectableTableCell(file: file) {
                    Text(file.parentPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .width(min: 80, ideal: locationColumnWidth, max: locationColumnWidth)
            .customizationID("location")
        }
        .scrollPosition(id: listScrollPositionBinding)
        .frame(minWidth: Self.tableMinimumWidth, alignment: .leading)
        .onKeyPress(.return) {
            guard let file = appModel.selectedFile else { return .ignored }
            appModel.open(file)
            return .handled
        }
        .onKeyPress(.space) {
            guard let file = appModel.selectedFile else { return .ignored }
            appModel.quickLook(file)
            return .handled
        }
        .onKeyPress(.deleteForward) {
            guard let file = appModel.selectedFile else { return .ignored }
            appModel.requestTrash(file)
            return .handled
        }
        .onKeyPress(.delete) {
            guard let file = appModel.selectedFile else { return .ignored }
            appModel.requestTrash(file)
            return .handled
        }
    }

    private func selectableTableCell<Content: View>(
        file: IndexedFile,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                appModel.selectedFileID = file.id
            }
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    appModel.selectedFileID = file.id
                    appModel.open(file)
                }
            )
            .contextMenu {
                FileContextMenu(file: file)
            }
    }

    /// Sum of every column's minimum width. The table must never be squeezed
    /// below this, otherwise trailing columns get clipped instead of scrolled.
    static let tableMinimumWidth: CGFloat = 565

    /// Spoken summary of a table row: name, kind, size, and modification date.
    private func rowAccessibilityLabel(for file: IndexedFile) -> String {
        var parts = [
            file.name,
            file.kind.localizedTitle,
            ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)
        ]
        if let modifiedAt = file.modifiedAt {
            parts.append(finderDateFormatter.string(from: modifiedAt))
        }
        let categoryNames = appModel.categories(for: file).map(\.localizedDisplayName)
        if !categoryNames.isEmpty {
            parts.append(categoryNames.joined(separator: AppLanguage.selected.usesEnglish ? ", " : "、"))
        }
        return parts.joined(separator: AppLanguage.selected.usesEnglish ? ", " : "，")
    }

    private var tableColumnCompression: CGFloat {
        let start = XunJianUI.Breakpoint.tableCompressionStart
        let end = XunJianUI.Breakpoint.tableCompressionEnd
        return min(max((contentWidth - start) / (end - start), 0), 1)
    }

    private func compressedColumnWidth(minimum: CGFloat, ideal: CGFloat) -> CGFloat {
        minimum + ((ideal - minimum) * tableColumnCompression)
    }

    private var nameColumnWidth: CGFloat {
        compressedColumnWidth(minimum: 180, ideal: 280)
    }

    private var categoryColumnWidth: CGFloat {
        compressedColumnWidth(minimum: 55, ideal: 90)
    }

    private var typeColumnWidth: CGFloat {
        compressedColumnWidth(minimum: 55, ideal: 75)
    }

    private var sizeColumnWidth: CGFloat {
        compressedColumnWidth(minimum: 60, ideal: 75)
    }

    private var modifiedColumnWidth: CGFloat {
        compressedColumnWidth(minimum: 105, ideal: 135)
    }

    private var locationColumnWidth: CGFloat {
        compressedColumnWidth(minimum: 110, ideal: 200)
    }

    private func fileGrid(files: [IndexedFile]) -> some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 132), spacing: 14)],
                spacing: 14
            ) {
                ForEach(files) { file in
                    Button {
                        appModel.selectedFileID = file.id
                    } label: {
                        VStack(spacing: 10) {
                            FileThumbnail(file: file, size: 72)
                            Text(file.name)
                                .font(.callout)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                            Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 122)
                        .padding(12)
                        .background {
                            InteractiveCardBackground(
                                isSelected: appModel.selectedFileID == file.id,
                                isHovered: hoveredGridFileID == file.id,
                                cornerRadius: XunJianUI.Radius.card
                            )
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SoftCardButtonStyle())
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded {
                            appModel.selectedFileID = file.id
                            appModel.open(file)
                        }
                    )
                    .onHover { isHovering in
                        hoveredGridFileID = isHovering ? file.id : nil
                    }
                    .accessibilityLabel(
                        "\(file.name)，\(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))"
                    )
                    .contextMenu {
                        FileContextMenu(file: file)
                    }
                }
            }
            .scrollTargetLayout()
            .padding(XunJianUI.pagePadding(for: contentWidth))
        }
        .scrollPosition(id: gridScrollPositionBinding)
        .onKeyPress(.return) {
            guard let file = appModel.selectedFile else { return .ignored }
            appModel.open(file)
            return .handled
        }
        .onKeyPress(.space) {
            guard let file = appModel.selectedFile else { return .ignored }
            appModel.quickLook(file)
            return .handled
        }
        .onKeyPress(.deleteForward) {
            guard let file = appModel.selectedFile else { return .ignored }
            appModel.requestTrash(file)
            return .handled
        }
        .onKeyPress(.delete) {
            guard let file = appModel.selectedFile else { return .ignored }
            appModel.requestTrash(file)
            return .handled
        }
    }
}

private struct DisplayedFilesRefreshKey: Equatable {
    let sourceFiles: [IndexedFile]
    let selectedKind: FileKind?
    let sortOrder: FileSortOrder
    let sortAscending: Bool
}

private enum FileToolbarMetrics {
    static let controlHeight: CGFloat = 32
    static let iconButtonSide: CGFloat = 32
    static let symbolSize: CGFloat = 14
    static let regularSpacing: CGFloat = 8
    static let compactSpacing: CGFloat = 6
    static let fileTypeWidth: CGFloat = 112
    static func sortWidth(for order: FileSortOrder) -> CGFloat {
        if AppLanguage.selected.usesEnglish,
           order == .modifiedAt || order == .createdAt {
            return 128
        }
        return 104
    }
    static let viewModeWidth: CGFloat = 72
    static let viewModeItemWidth: CGFloat = 35
    static let cornerRadius: CGFloat = 6
    static let innerCornerRadius: CGFloat = 5
    static let controlFill = Color.primary.opacity(0.065)
}

private struct FileToolbarIconLabel: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: FileToolbarMetrics.symbolSize, weight: .medium))
            .frame(
                width: FileToolbarMetrics.iconButtonSide,
                height: FileToolbarMetrics.iconButtonSide
            )
            .background(
                FileToolbarMetrics.controlFill,
                in: RoundedRectangle(
                    cornerRadius: FileToolbarMetrics.cornerRadius,
                    style: .continuous
                )
            )
            .contentShape(Rectangle())
    }
}

private struct FileToolbarMenuLabel: View {
    let title: String
    let systemName: String

    var body: some View {
        Label {
            Text(verbatim: title)
                .lineLimit(1)
        } icon: {
            Image(systemName: systemName)
                .font(.system(size: FileToolbarMetrics.symbolSize, weight: .medium))
        }
        .padding(.horizontal, 10)
        .frame(height: FileToolbarMetrics.controlHeight)
        .background(
            FileToolbarMetrics.controlFill,
            in: RoundedRectangle(
                cornerRadius: FileToolbarMetrics.cornerRadius,
                style: .continuous
            )
        )
        .contentShape(Rectangle())
    }
}

private struct FileToolbarPopupLabel: View {
    let title: String
    let width: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: title)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: FileToolbarMetrics.symbolSize, weight: .semibold))
        }
        .padding(.horizontal, 10)
        .frame(width: width, height: FileToolbarMetrics.controlHeight)
        .background(
            FileToolbarMetrics.controlFill,
            in: RoundedRectangle(
                cornerRadius: FileToolbarMetrics.cornerRadius,
                style: .continuous
            )
        )
        .contentShape(Rectangle())
    }
}

private enum AITaskSheet: Identifiable {
    case search
    case explain(IndexedFile)
    case ask(IndexedFile)
    case classify

    var id: String {
        switch self {
        case .search: "search"
        case let .explain(file): "explain-\(file.id)"
        case let .ask(file): "ask-\(file.id)"
        case .classify: "classify"
        }
    }
}

private struct AISearchSheet: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var isWorking = false
    @State private var failure: String?
    @State private var operationTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AI 搜文件")
                .font(.title2.weight(.semibold))
            Text("AI 只理解你的描述并生成检索条件；文件候选筛选和结果匹配均在本地完成。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("例如：找我去年保存的合同", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit(search)

            if let failure {
                Text(AppLanguage.localizedRuntimeMessage(failure))
                    .font(.caption)
                    .foregroundStyle(XunJianUI.Semantic.danger)
            }

            HStack {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在理解查找条件…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(
                    AppLanguage.localized(
                        isWorking ? "停止" : "取消",
                        english: isWorking ? "Stop" : "Cancel"
                    )
                ) { cancelAndDismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("查找", action: search)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        isWorking
                            || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
            }
        }
        .padding(24)
        .frame(minWidth: 320, idealWidth: 520, maxWidth: 560, alignment: .leading)
        .onDisappear { operationTask?.cancel() }
    }

    private func search() {
        isWorking = true
        failure = nil
        operationTask?.cancel()
        operationTask = Task {
            do {
                try await appModel.performAISearch(query)
                try Task.checkCancellation()
                dismiss()
            } catch is CancellationError {
                isWorking = false
                return
            } catch {
                guard !Task.isCancelled else { return }
                failure = error.localizedDescription
                isWorking = false
            }
        }
    }

    private func cancelAndDismiss() {
        operationTask?.cancel()
        dismiss()
    }
}

private struct AIExplainSheet: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    let file: IndexedFile

    @State private var output = ""
    @State private var failure: String?
    @State private var operationTask: Task<Void, Never>?
    @State private var hasStarted = false

    var body: some View {
        AITextResultSheet(
            title: "AI 看文件",
            subtitle: file.name,
            output: output,
            failure: failure,
            isWorking: hasStarted && output.isEmpty && failure == nil,
            showsStart: !hasStarted,
            start: startAnalysis,
            dismiss: {
                operationTask?.cancel()
                dismiss()
            }
        )
        .onDisappear { operationTask?.cancel() }
    }

    private func startAnalysis() {
        guard !hasStarted else { return }
        hasStarted = true
        operationTask = Task {
            do {
                let result = try await appModel.explainWithAI(file)
                try Task.checkCancellation()
                output = result
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                failure = error.localizedDescription
            }
        }
    }
}

private struct AIQuestionSheet: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    let file: IndexedFile

    @State private var question = ""
    @State private var output = ""
    @State private var failure: String?
    @State private var isWorking = false
    @State private var operationTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AI 问文件")
                .font(.title2.weight(.semibold))
            Text(file.name)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            TextField("例如：这个合同什么时候到期？", text: $question)
                .textFieldStyle(.roundedBorder)
                .onSubmit(ask)

            Group {
                if isWorking {
                    ProgressView("正在阅读当前文件…")
                } else if let failure {
                    Text(AppLanguage.localizedRuntimeMessage(failure))
                        .foregroundStyle(XunJianUI.Semantic.danger)
                } else if !output.isEmpty {
                    ScrollView {
                        Text(output)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Text("仅会发送当前文件中回答问题所需的文本，不发送路径或其他文件。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
            .background(
                XunJianUI.Fill.quiet,
                in: RoundedRectangle(cornerRadius: XunJianUI.Radius.card, style: .continuous)
            )

            HStack {
                Spacer()
                Button(
                    AppLanguage.localized(
                        isWorking ? "停止" : "关闭",
                        english: isWorking ? "Stop" : "Close"
                    )
                ) {
                    operationTask?.cancel()
                    dismiss()
                }
                    .keyboardShortcut(.cancelAction)
                Button("提问", action: ask)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        isWorking
                            || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
            }
        }
        .padding(24)
        .frame(minWidth: 320, idealWidth: 560, maxWidth: 620, minHeight: 340, idealHeight: 380)
        .onDisappear { operationTask?.cancel() }
    }

    private func ask() {
        isWorking = true
        failure = nil
        output = ""
        operationTask?.cancel()
        operationTask = Task {
            do {
                let result = try await appModel.askAI(question, about: file)
                try Task.checkCancellation()
                output = result
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                failure = error.localizedDescription
            }
            isWorking = false
        }
    }
}

private struct AITextResultSheet: View {
    let title: LocalizedStringKey
    let subtitle: String
    let output: String
    let failure: String?
    let isWorking: Bool
    let showsStart: Bool
    let start: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Group {
                if isWorking {
                    ProgressView("正在读取必要文本…")
                } else if let failure {
                    Text(AppLanguage.localizedRuntimeMessage(failure))
                        .foregroundStyle(XunJianUI.Semantic.danger)
                } else if showsStart {
                    ContentUnavailableView(
                        AppLanguage.localized("准备分析当前文件", english: "Ready to Analyze This File"),
                        systemImage: "sparkles",
                        description: Text(
                            AppLanguage.localized(
                                "确认后才会读取必要文本并发起 AI 请求。",
                                english: "Necessary text is read and sent to AI only after you confirm."
                            )
                        )
                    )
                } else {
                    ScrollView {
                        Text(output)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                XunJianUI.Fill.quiet,
                in: RoundedRectangle(cornerRadius: XunJianUI.Radius.card, style: .continuous)
            )

            HStack {
                Spacer()
                Button("关闭", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                if showsStart {
                    Button(
                        AppLanguage.localized("开始分析", english: "Start Analysis"),
                        action: start
                    )
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 320, idealWidth: 560, maxWidth: 620, minHeight: 340, idealHeight: 380)
    }
}

private struct AIClassificationSheet: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedFileIDs: Set<String>
    @State private var suggestions: [AIClassificationSuggestion]?
    @State private var isWorking = false
    @State private var failure: String?
    @State private var fileSearchText = ""
    @State private var operationTask: Task<Void, Never>?
    @State private var appliedChanges: [AIClassificationChange] = []
    @State private var showsAppliedConfirmation = false
    @State private var isCommittingChanges = false

    init(initialFileID: String?) {
        _selectedFileIDs = State(
            initialValue: initialFileID.map { [$0] } ?? []
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AI 分类")
                .font(.title2.weight(.semibold))
            Text("最多选择 8 个文件。AI 只会建议已有分类，确认后才写入本地索引。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if appModel.categories.isEmpty {
                ContentUnavailableView {
                    Label("还没有分类", systemImage: "square.grid.2x2")
                } description: {
                    Text(
                        verbatim: AppLanguage.localized(
                            "请先创建分类，再使用 AI 分类。",
                            english: "Create a category before using AI classification."
                        )
                    )
                }
            } else if let suggestions {
                suggestionList(suggestions)
            } else {
                selectionList
            }

            if let failure {
                Text(AppLanguage.localizedRuntimeMessage(failure))
                    .font(.caption)
                    .foregroundStyle(XunJianUI.Semantic.danger)
            }

            classificationFooter
        }
        .padding(24)
        .frame(minWidth: 340, idealWidth: 620, maxWidth: 680, minHeight: 420, idealHeight: 500)
        .interactiveDismissDisabled(isCommittingChanges)
        .onDisappear {
            if !isCommittingChanges { operationTask?.cancel() }
        }
        .alert(
            AppLanguage.localized("分类已应用", english: "Classification Applied"),
            isPresented: $showsAppliedConfirmation
        ) {
            Button(
                AppLanguage.localized("撤销本次分类", english: "Undo Classification"),
                role: .destructive
            ) { undoAppliedChanges() }
            Button("完成") { dismiss() }
        } message: {
            Text(
                verbatim: AppLanguage.localized(
                    "已新增 \(appliedChanges.count) 个分类关联。",
                    english: "Added \(appliedChanges.count) category associations."
                )
            )
        }
    }

    private var selectionList: some View {
        VStack(spacing: 10) {
            TextField(
                AppLanguage.localized("搜索本地文件…", english: "Search local files…"),
                text: $fileSearchText
            )
                .textFieldStyle(.roundedBorder)
            List(filteredClassificationFiles) { file in
                Button {
                    toggle(file.id)
                } label: {
                    HStack {
                        Image(
                            systemName: selectedFileIDs.contains(file.id)
                                ? "checkmark.circle.fill" : "circle"
                        )
                        .foregroundStyle(
                            selectedFileIDs.contains(file.id) ? Color.accentColor : .secondary
                        )
                        Text(file.name)
                            .lineLimit(1)
                        Spacer()
                        Text(file.kind.localizedTitle)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .disabled(!selectedFileIDs.contains(file.id) && selectedFileIDs.count >= 8)
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
        }
    }

    private var filteredClassificationFiles: [IndexedFile] {
        let query = fileSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return appModel.files.sorted { lhs, rhs in
            let lhsSelected = selectedFileIDs.contains(lhs.id)
            let rhsSelected = selectedFileIDs.contains(rhs.id)
            if lhsSelected != rhsSelected { return lhsSelected }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }.filter { file in
            query.isEmpty || file.name.localizedCaseInsensitiveContains(query)
        }
    }

    private var classificationFooter: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                classificationStatus
                Spacer(minLength: 8)
                classificationActions
            }

            VStack(alignment: .leading, spacing: 10) {
                classificationStatus
                HStack {
                    Spacer(minLength: 0)
                    classificationActions
                }
            }
        }
    }

    private var classificationStatus: some View {
        HStack(spacing: 8) {
            if isWorking {
                ProgressView()
                    .controlSize(.small)
            }
            Text(
                AppLanguage.localized(
                    "已选择 \(selectedFileIDs.count) / 8",
                    english: "Selected \(selectedFileIDs.count) / 8"
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var classificationActions: some View {
        HStack(spacing: 8) {
            Button(
                AppLanguage.localized(
                    isWorking && !isCommittingChanges ? "停止" : "取消",
                    english: isWorking && !isCommittingChanges ? "Stop" : "Cancel"
                )
            ) {
                operationTask?.cancel()
                dismiss()
            }
                .keyboardShortcut(.cancelAction)
                .disabled(isCommittingChanges)
            if let suggestions {
                Button("确认应用") {
                    apply(suggestions)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking || suggestions.allSatisfy(\.categoryIDs.isEmpty))
            } else {
                Button("生成建议", action: classify)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || selectedFileIDs.isEmpty)
            }
        }
    }

    private func suggestionList(_ suggestions: [AIClassificationSuggestion]) -> some View {
        List {
            ForEach(suggestions) { suggestion in
            let localizedNames = suggestion.categoryIDs.compactMap { categoryID in
                appModel.categories.first(where: { $0.id == categoryID })?.localizedDisplayName
            }
            let displayNames = localizedNames.isEmpty
                ? suggestion.categoryNames
                : localizedNames
                HStack {
                    Text(verbatim: suggestion.fileName)
                        .lineLimit(1)
                    Spacer()
                    if suggestion.categoryIDs.isEmpty {
                        Text("不建议分类")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(verbatim: displayNames.joined(separator: " / "))
                            .foregroundStyle(.secondary)
                    }
                    Button(
                        AppLanguage.localized("移除此建议", english: "Remove Suggestion")
                    ) {
                        self.suggestions?.removeAll { $0.id == suggestion.id }
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .listStyle(.bordered(alternatesRowBackgrounds: true))
    }

    private func toggle(_ fileID: String) {
        if selectedFileIDs.contains(fileID) {
            selectedFileIDs.remove(fileID)
        } else if selectedFileIDs.count < 8 {
            selectedFileIDs.insert(fileID)
        }
    }

    private func classify() {
        let selectedFiles = appModel.files.filter { selectedFileIDs.contains($0.id) }
        isWorking = true
        failure = nil
        operationTask?.cancel()
        operationTask = Task {
            do {
                let result = try await appModel.classifyWithAI(selectedFiles)
                try Task.checkCancellation()
                suggestions = result
            } catch is CancellationError {
                isWorking = false
                return
            } catch {
                guard !Task.isCancelled else { return }
                failure = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func apply(_ suggestions: [AIClassificationSuggestion]) {
        isWorking = true
        isCommittingChanges = true
        failure = nil
        operationTask?.cancel()
        operationTask = Task {
            do {
                let changes = try await appModel.applyAIClassification(suggestions)
                appliedChanges = changes
                isWorking = false
                isCommittingChanges = false
                showsAppliedConfirmation = true
            } catch is CancellationError {
                isWorking = false
                isCommittingChanges = false
                return
            } catch {
                guard !Task.isCancelled else { return }
                failure = error.localizedDescription
                isWorking = false
                isCommittingChanges = false
            }
        }
    }

    private func undoAppliedChanges() {
        isCommittingChanges = true
        operationTask?.cancel()
        operationTask = Task {
            do {
                try await appModel.undoAIClassification(appliedChanges)
                isCommittingChanges = false
                dismiss()
            } catch is CancellationError {
                isCommittingChanges = false
                return
            } catch {
                guard !Task.isCancelled else { return }
                failure = error.localizedDescription
                showsAppliedConfirmation = false
                isCommittingChanges = false
            }
        }
    }
}

/// Shared file context menu used by All Files, Categories, and Home.
struct FileContextMenu: View {
    @EnvironmentObject private var appModel: AppModel
    let file: IndexedFile

    /// When the clicked row is part of a multi-selection, category and trash
    /// actions apply to the whole selection instead of just this file.
    private var actsOnSelection: Bool {
        appModel.selectedFileIDs.count > 1
            && appModel.selectedFileIDs.contains(file.id)
    }

    var body: some View {
        Button("打开") { appModel.open(file) }
        Button("快速查看") { appModel.quickLook(file) }
        Button("在 Finder 中显示") { appModel.showInFinder(file) }

        Divider()

        if actsOnSelection {
            Menu(AppLanguage.localized("批量添加到分类", english: "Add Selection to Category")) {
                if appModel.categories.isEmpty {
                    Text(
                        AppLanguage.localized(
                            "还没有分类",
                            english: "No categories yet"
                        )
                    )
                } else {
                    ForEach(appModel.categories) { category in
                        Button {
                            appModel.assignSelectedFiles(to: category)
                        } label: {
                            Label(category.localizedDisplayName, systemImage: category.symbolName)
                        }
                    }
                }
            }
            Button(
                AppLanguage.localized(
                    "移到废纸篓（\(appModel.selectedFileIDs.count) 项）",
                    english: "Move \(appModel.selectedFileIDs.count) Items to Trash"
                ),
                role: .destructive
            ) {
                appModel.requestBatchTrash()
            }
        } else {
            Menu("添加到分类") {
                if appModel.categories.isEmpty {
                    Text(
                        AppLanguage.localized(
                            "还没有分类",
                            english: "No categories yet"
                        )
                    )
                    Button {
                        NotificationCenter.default.post(
                            name: .xunJianRequestNewCategory,
                            object: nil
                        )
                    } label: {
                        Label(
                            AppLanguage.localized("新建分类…", english: "New Category…"),
                            systemImage: "plus"
                        )
                    }
                } else {
                    ForEach(appModel.categories) { category in
                        Button {
                            appModel.toggleCategory(category, for: file)
                        } label: {
                            if appModel.isCategory(category, assignedTo: file) {
                                Label(category.localizedDisplayName, systemImage: "checkmark")
                            } else {
                                Label(category.localizedDisplayName, systemImage: category.symbolName)
                            }
                        }
                    }
                }
            }

            Divider()

            Button("重命名…") { appModel.requestRename(file) }
            Button("移动到…") { appModel.chooseMoveDestination(for: file) }
            Button("移到废纸篓", role: .destructive) { appModel.requestTrash(file) }
        }
    }
}
