import AppKit
import SwiftUI

struct AllFilesView: View {
    /// Shared with the category page so both honour the same stored default.
    typealias ViewMode = FileBrowseViewMode

    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var searchProgressStore: SearchProgressStore
    @Environment(\.locale) private var locale

    let windowWidth: CGFloat
    let contentWidth: CGFloat
    var isVisible = true

    @AppStorage("allFiles.viewMode") private var viewMode = ViewMode.list
    @AppStorage(FileActivationBehavior.storageKey)
    private var doubleClickBehavior = FileActivationBehavior.open
    @AppStorage("allFiles.sortOrder") private var browseSortOrder = FileSortOrder.modifiedAt
    @AppStorage("allFiles.sortAscending") private var browseSortAscending = false
    @AppStorage("allFiles.searchSortOrder") private var searchSortOrder = FileSortOrder.relevance
    @AppStorage("allFiles.searchSortAscending") private var searchSortAscending = false
    @AppStorage("allFiles.tableColumnCustomization")
    private var tableColumnCustomization = TableColumnCustomization<IndexedFile>()
    @AppStorage("allFiles.listScrollPosition") private var listScrollPosition = ""
    @AppStorage("allFiles.gridScrollPosition") private var gridScrollPosition = ""
    @State private var scrollPositionPersistenceTask: Task<Void, Never>?

    // Manual filters (N02): a size floor and a modified-since date, applied
    // on top of whatever search/AI narrowing is active. Values live on
    // AppModel so saved searches can restore them.
    @State private var showsFilterPopover = false
    @State private var savedSearchName = ""

    // F03: toolbar rows grow with the text size setting instead of clipping
    // at a fixed 32pt.
    @ScaledMetric(relativeTo: .body) private var toolbarControlHeight = FileToolbarMetrics.controlHeight
    @ScaledMetric(relativeTo: .body) private var overflowButtonSide = FileToolbarMetrics.iconButtonSide

    private var finderDateFormatter: DateFormatter {
        FinderDateFormatting.formatter(for: locale)
    }

    init(windowWidth: CGFloat, contentWidth: CGFloat, isVisible: Bool = true) {
        self.windowWidth = windowWidth
        self.contentWidth = contentWidth
        self.isVisible = isVisible
    }

    var body: some View {
        Group {
            if isVisible {
                content(filesSnapshot: appModel.browseSnapshot)
            } else {
                Color.clear
                    .accessibilityHidden(true)
            }
        }
        .task(id: displayedFilesRefreshKey) {
            guard isVisible else { return }
            await refreshDisplayedFilesSnapshot()
        }
        .onAppear {
            guard isVisible else { return }
            appModel.highlightQuery = appModel.searchText
        }
        .onChange(of: isVisible) { _, visible in
            guard visible else { return }
            appModel.highlightQuery = appModel.searchText
            // The retained All Files view may still hold the previous
            // page's snapshot. Publish only after the current filters
            // have been recomputed so commands cannot target stale rows.
            appModel.updateCommandTargetFiles([])
            Task { await refreshDisplayedFilesSnapshot() }
        }
        .onChange(of: appModel.searchText) { _, text in
            guard isVisible else { return }
            appModel.highlightQuery = text
        }
        .onChange(of: appModel.selectedFileID) { _, id in
            guard let id else { return }
            // Coalesce: arrow-key navigation changes the selection many
            // times per second, and each @AppStorage write wakes the
            // UserDefaults observers. Persist the settled position once.
            scrollPositionPersistenceTask?.cancel()
            let isListView = viewMode == .list
            scrollPositionPersistenceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                if isListView {
                    listScrollPosition = id
                } else {
                    gridScrollPosition = id
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .xunJianSetBrowseViewMode)) { note in
            guard isVisible,
                  let raw = note.object as? String,
                  let mode = FileBrowseViewMode(rawValue: raw) else { return }
            viewMode = mode
        }
    }

    private func content(filesSnapshot: [IndexedFile]) -> some View {
        VStack(spacing: 0) {
            fileHeader(filesSnapshot: filesSnapshot)
            Divider().opacity(0.7)
            emptyState(files: filesSnapshot)
        }
    }

    @ViewBuilder
    private func fileHeader(filesSnapshot: [IndexedFile]) -> some View {
        header(resultCount: filesSnapshot.count)
        if appModel.selectedFileIDs.count > 1 {
            FileBatchActionBar(contentWidth: contentWidth)
        }
        if let plan = appModel.aiSearchPlan {
            HStack(spacing: 8) {
                Label(aiSearchModeDescription(for: plan), systemImage: "sparkles")
                    .symbolRenderingMode(.hierarchical)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button(AppLanguage.localized("清除", english: "Clear")) {
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

    private func header(resultCount: Int) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 12) {
                headerSummary(resultCount: resultCount)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                filterButton
                responsiveFileToolbar
            }
            if searchProgressStore.isSearching || appModel.hasMoreSearchResults {
                searchProgress
            }
        }
        .padding(.horizontal, XunJianUI.pagePadding(for: contentWidth))
        .padding(.vertical, 14)
    }

    /// Manual size/date filter entry point (N02). Highlighted while active so
    /// the narrowing is visible at a glance.
    private var filterButton: some View {
        Button {
            showsFilterPopover.toggle()
        } label: {
            FileToolbarIconLabel(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(hasActiveManualFilter ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
        .help(AppLanguage.localized("按大小或日期过滤", english: "Filter by Size or Date"))
        .accessibilityLabel(AppLanguage.localized("按大小或日期过滤", english: "Filter by Size or Date"))
        .popover(isPresented: $showsFilterPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text(AppLanguage.localized("过滤条件", english: "Filters"))
                    .font(.headline)

                VStack(alignment: .leading, spacing: 6) {
                    Text(AppLanguage.localized("最小大小（MB，0 为不限）", english: "Minimum size (MB, 0 = any)"))
                        .font(.caption)
                    TextField(
                        AppLanguage.localized("例如 100", english: "e.g. 100"),
                        value: $appModel.filterMinSizeMB,
                        format: .number
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Toggle(
                        AppLanguage.localized(
                            "按修改日期过滤",
                            english: "Filter by modified date"
                        ),
                        isOn: Binding(
                            get: { minimumFilterDate != nil },
                            set: { enabled in
                                appModel.filterMinDate = enabled
                                    ? Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
                                    : 0
                            }
                        )
                    )
                    .toggleStyle(.switch)
                    if let date = minimumFilterDate {
                        DatePicker(
                            AppLanguage.localized(
                                "修改时间不早于",
                                english: "Modified no earlier than"
                            ),
                            selection: Binding(
                                get: { date },
                                set: { appModel.filterMinDate = $0.timeIntervalSince1970 }
                            ),
                            displayedComponents: .date
                        )
                        .datePickerStyle(.field)
                        .frame(maxWidth: 280)
                    }
                }

                HStack {
                    Spacer()
                    Button(AppLanguage.localized("清除过滤", english: "Clear Filters")) {
                        appModel.filterMinSizeMB = 0
                        appModel.filterMinDate = 0
                    }
                    .disabled(!hasActiveManualFilter)
                }

                Divider()

                // N07: keep the current query + filters as a one-click
                // sidebar entry.
                HStack(spacing: 8) {
                    TextField(
                        AppLanguage.localized("搜索名称", english: "Search name"),
                        text: $savedSearchName
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)

                    Button(AppLanguage.localized("保存搜索", english: "Save Search")) {
                        appModel.saveSearch(
                            name: savedSearchName,
                            query: appModel.searchText,
                            minSizeBytes: minimumSizeBytes,
                            minDate: minimumFilterDate
                        )
                        savedSearchName = ""
                        showsFilterPopover = false
                    }
                    .disabled(
                        savedSearchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || (appModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                && !hasActiveManualFilter)
                    )
                }
            }
            .padding(16)
            .frame(width: 280)
        }
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
        if searchProgressStore.isSearching {
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
                Text(
                    AppLanguage.localized(
                        "请先在设置中配置当前 AI",
                        english: "Configure the current AI in Settings first"
                    )
                )
                Button {
                    NotificationCenter.default.post(name: .xunJianOpenSettings, object: nil)
                } label: {
                    Label(
                        AppLanguage.localized("打开设置…", english: "Open Settings…"),
                        systemImage: "gearshape"
                    )
                }
            }
            Button(AppLanguage.localized("AI 搜文件…", english: "AI File Search…")) {
                appModel.aiSheetRequest = .search
            }
            .disabled(!hasAIProvider)
            Divider()
            Button(AppLanguage.localized("AI 看文件", english: "AI Explain File")) {
                if let file = appModel.selectedFile {
                    appModel.aiSheetRequest = .explain(file)
                }
            }
            .disabled(
                !hasAIProvider
                    || appModel.selectedFile.map { !appModel.supportsTextContent($0) } != false
            )
            Button(AppLanguage.localized("AI 问文件…", english: "Ask AI About File…")) {
                if let file = appModel.selectedFile {
                    appModel.aiSheetRequest = .ask(file)
                }
            }
            .disabled(
                !hasAIProvider
                    || appModel.selectedFile.map { !appModel.supportsTextContent($0) } != false
            )
            Button(AppLanguage.localized("AI 分类…", english: "AI Classify…")) {
                appModel.aiSheetRequest = .classify
            }
            .disabled(!hasAIProvider || appModel.files.isEmpty || appModel.categories.isEmpty)
        } label: {
            if compact {
                FileToolbarIconLabel(systemName: "sparkles")
            } else {
                FileToolbarMenuLabel(
                    title: appModel.activeAIProviderKind?.title
                        ?? AppLanguage.localized("AI", english: "AI"),
                    systemName: "sparkles"
                )
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(
            width: compact ? FileToolbarMetrics.iconButtonSide : nil,
            height: toolbarControlHeight
        )
        .fixedSize()
        .accessibilityLabel(AppLanguage.localized("AI 功能", english: "AI Actions"))
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
        .frame(height: toolbarControlHeight)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var fileTypeMenu: some View {
        Menu {
            Button {
                appModel.selectedKind = nil
            } label: {
                if appModel.selectedKind == nil {
                    Label(
                        AppLanguage.localized("所有类型", english: "All Types"),
                        systemImage: "checkmark"
                    )
                } else {
                    Text(AppLanguage.localized("所有类型", english: "All Types"))
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
                            height: toolbarControlHeight - 2
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
                .accessibilityLabel(
                    mode == .list
                        ? AppLanguage.localized("列表", english: "List")
                        : AppLanguage.localized("图标", english: "Icons")
                )
                .accessibilityAddTraits(viewMode == mode ? .isSelected : [])
            }
        }
        .padding(1)
        .frame(
            width: FileToolbarMetrics.viewModeWidth,
            height: toolbarControlHeight
        )
        .fileToolbarSurface()
        .fixedSize()
    }

    @ViewBuilder
    private var fileTypeChoices: some View {
        Text(AppLanguage.localized("所有类型", english: "All Types")).tag(FileKind?.none)
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
                Picker(
                    AppLanguage.localized("文件类型", english: "File Type"),
                    selection: $appModel.selectedKind
                ) {
                    fileTypeChoices
                }
            }
            if includesSort {
                Picker(
                    AppLanguage.localized("排序", english: "Sort"),
                    selection: activeSortOrderBinding
                ) {
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
                Picker(
                    AppLanguage.localized("显示方式", english: "View"),
                    selection: $viewMode
                ) {
                    Label(
                        AppLanguage.localized("列表", english: "List"),
                        systemImage: ViewMode.list.symbolName
                    )
                        .tag(ViewMode.list)
                    Label(
                        AppLanguage.localized("图标", english: "Icons"),
                        systemImage: ViewMode.grid.symbolName
                    )
                        .tag(ViewMode.grid)
                }
            }
        } label: {
            FileToolbarIconLabel(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .frame(
            width: overflowButtonSide,
            height: overflowButtonSide
        )
        .help(AppLanguage.localized("更多工具", english: "More Tools"))
        .accessibilityLabel(AppLanguage.localized("更多工具", english: "More Tools"))
        .menuIndicator(.hidden)
    }

    private func emptyState(files: [IndexedFile]) -> some View {
        Group {
            if appModel.browseSnapshotSignature == nil, !sourceFilesForDisplay.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(
                        AppLanguage.localized("正在准备文件列表", english: "Preparing file list")
                    )
            } else if searchProgressStore.isSearching, files.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(
                        AppLanguage.localized("正在搜索", english: "Searching")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewMode == .list, !files.isEmpty {
                EquatableSnapshotList(
                    signature: appModel.browseSnapshotSignature,
                    viewMode: viewMode,
                    contentWidth: contentWidth,
                    selectionToken: appModel.selectedFileIDs.hashValue
                ) {
                    VStack(alignment: .leading, spacing: 6) {
                        if FileTableLayout.needsHorizontalScroll(contentWidth: contentWidth) {
                            Text(verbatim: AppLanguage.localized(
                                "窗口较窄，可左右滑动查看全部列。",
                                english: "Window is narrow — swipe sideways to see every column."
                            ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, XunJianUI.pagePadding(for: contentWidth))
                        }
                        ScrollView(.horizontal) {
                            fileTable(files: files)
                        }
                        .scrollIndicators(.automatic)
                    }
                }
                .equatable()
            } else if viewMode == .grid, !files.isEmpty {
                EquatableSnapshotList(
                    signature: appModel.browseSnapshotSignature,
                    viewMode: viewMode,
                    contentWidth: contentWidth,
                    selectionToken: appModel.selectedFileIDs.hashValue
                ) {
                    fileGrid(files: files)
                }
                .equatable()
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
                    } else if hasActiveManualFilter, !appModel.files.isEmpty {
                        // Size/date filters can hide everything on their own,
                        // and the popover is not obvious once the list is
                        // empty, so offer the reset here too.
                        Button(
                            AppLanguage.localized("清除过滤条件", english: "Clear Filters")
                        ) {
                            appModel.filterMinSizeMB = 0
                            appModel.filterMinDate = 0
                            appModel.selectedKind = nil
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
                        Button(AppLanguage.localized("添加文件夹", english: "Add Folder")) {
                            appModel.chooseFolder()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .xunjianAnimation(value: viewMode)
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
        let separator = AppLanguage.listSeparator
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
            // While the first query is still running there is nothing
            // meaningful to show. Falling back to the whole index made the
            // list flash every file before narrowing to the matches.
            return appModel.searchResults ?? []
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
            filesRevision: appModel.filesRevision,
            searchResultsRevision: appModel.searchResultsRevision,
            aiSearchResultCount: appModel.aiSearchResults?.count,
            aiSearchRevision: appModel.aiSearchRevision,
            selectedKind: appModel.selectedKind,
            sortOrder: activeSortOrder,
            sortAscending: activeSortAscending,
            minSizeBytes: minimumSizeBytes,
            minDate: minimumFilterDate
        )
    }

    /// Manual-filter parameters, resolved from persisted UI values (N02).
    private var minimumSizeBytes: Int64 {
        Int64(appModel.filterMinSizeMB * 1_024 * 1_024)
    }

    private var minimumFilterDate: Date? {
        appModel.filterMinDate > 0 ? Date(timeIntervalSince1970: appModel.filterMinDate) : nil
    }

    private var hasActiveManualFilter: Bool {
        minimumSizeBytes > 0 || minimumFilterDate != nil
    }

    private func refreshDisplayedFilesSnapshot() async {
        let signature = displayedFilesRefreshKey.signature
        // Returning to this page with unchanged inputs reuses the cached list
        // instead of re-sorting and flashing a placeholder.
        guard appModel.browseSnapshotSignature != signature else {
            if isVisible {
                appModel.updateCommandTargetFiles(
                    appModel.browseSnapshot,
                    usesGlobalSearchPagination: true
                )
            }
            return
        }

        let sourceFiles = sourceFilesForDisplay
        let selectedKind = appModel.selectedKind
        let requestedSortOrder = activeSortOrder
        let requestedAscending = activeSortAscending
        let minSize = minimumSizeBytes
        let minDate = minimumFilterDate
        // Detached sorts cannot observe cancellation, so a flag flipped by
        // the cancellation handler aborts the expensive 100k-file sort when a
        // newer revision already landed — at most one sort runs at a time
        // during bursts of file activity.
        let cancellationFlag = QuickSearchCancellationFlag()
        let computed = await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                let filteredFiles = sourceFiles.filter { file in
                    guard selectedKind.map({ file.kind == $0 }) ?? true else { return false }
                    if minSize > 0, file.size < minSize { return false }
                    if let minDate, let modifiedAt = file.modifiedAt, modifiedAt < minDate {
                        return false
                    }
                    return true
                }
                guard !cancellationFlag.isCancelled else {
                    return (files: [IndexedFile](), visibleIDs: Set<String>())
                }
                let sorted = requestedSortOrder.sorted(
                    filteredFiles,
                    ascending: requestedAscending
                )
                // The visible-ID set is built here so the main actor only
                // pays the dictionary construction cost for the selection
                // cleanup below.
                return (files: sorted, visibleIDs: Set(sorted.map(\.id)))
            }.value
        } onCancel: {
            cancellationFlag.cancel()
        }
        guard !Task.isCancelled else { return }
        let result = computed.files
        appModel.browseSnapshot = result
        appModel.browseSnapshotSignature = signature
        if isVisible {
            appModel.updateCommandTargetFiles(
                result,
                usesGlobalSearchPagination: true
            )
        }
        appModel.clearSelectionIfHidden(from: computed.visibleIDs)
    }

    private func fileTable(files: [IndexedFile]) -> some View {
        Table(
            files,
            selection: $appModel.selectedFileIDs,
            columnCustomization: $tableColumnCustomization
        ) {
            TableColumn(AppLanguage.localized("名称", english: "Name")) { file in
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

            TableColumn(AppLanguage.localized("分类", english: "Category")) { file in
                selectableTableCell(file: file) {
                    FileCategoryNamesLabel(fileID: file.id)
                }
            }
            .width(min: 45, ideal: categoryColumnWidth, max: categoryColumnWidth)
            .customizationID("category")

            TableColumn(AppLanguage.localized("类型", english: "Kind")) { file in
                selectableTableCell(file: file) {
                    Text(file.kind.localizedTitle)
                        .lineLimit(1)
                }
            }
            .width(min: 45, ideal: typeColumnWidth, max: typeColumnWidth)
            .customizationID("type")

            TableColumn(AppLanguage.localized("大小", english: "Size")) { file in
                selectableTableCell(file: file) {
                    Text(ByteFormatting.string(forByteCount: file.size))
                        .lineLimit(1)
                }
            }
            .width(min: 50, ideal: sizeColumnWidth, max: sizeColumnWidth)
            .customizationID("size")

            TableColumn(AppLanguage.localized("修改时间", english: "Date Modified")) { file in
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

            // Optional columns (N18). Hidden by default so the six-column
            // layout and its compression thresholds stay unchanged; users opt
            // in from the table header's context menu.
            TableColumn(AppLanguage.localized("创建时间", english: "Date Created")) { file in
                selectableTableCell(file: file) {
                    if let createdAt = file.createdAt {
                        Text(finderDateFormatter.string(from: createdAt))
                    } else {
                        Text("—")
                    }
                }
            }
            .width(min: 90, ideal: modifiedColumnWidth, max: modifiedColumnWidth)
            .customizationID("created")
            .defaultVisibility(.hidden)

            // Read-only Finder metadata (N17): shown here, never written back.
            TableColumn(AppLanguage.localized("标签", english: "Tags")) { file in
                selectableTableCell(file: file) {
                    FinderTagsLabel(file: file)
                }
            }
            .width(min: 60, ideal: categoryColumnWidth, max: categoryColumnWidth)
            .customizationID("finderTags")
            .defaultVisibility(.hidden)

            TableColumn(AppLanguage.localized("位置", english: "Where")) { file in
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
        .frame(
            minWidth: FileTableLayout.minimumWidth(contentWidth: contentWidth),
            alignment: .leading
        )
        // Arrow keys are left to the table's own row navigation; this only
        // adds the file actions on top.
        .fileListKeyboardNavigation(files: files, handlesArrowKeys: false)
    }

    private func selectableTableCell<Content: View>(
        file: IndexedFile,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                // Plain clicks select immediately (no double-click wait), but
                // ⌘/⇧ clicks must fall through to the table's own range and
                // toggle selection — otherwise multi-select is impossible.
                let modifiers = NSEvent.modifierFlags
                guard !modifiers.contains(.command), !modifiers.contains(.shift) else {
                    return
                }
                appModel.selectedFileID = file.id
            }
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    appModel.selectedFileID = file.id
                    doubleClickBehavior.perform(on: file, using: appModel)
                }
            )
            .contextMenu {
                FileContextMenu(file: file)
            }
            // Drag out to Finder or another app (F06): the URL item provider
            // lets macOS move/copy the real file on drop.
            .draggable(file.url)
    }

    /// Spoken summary of a table row: name, kind, size, and modification date.
    private func rowAccessibilityLabel(for file: IndexedFile) -> String {
        var parts = [
            file.name,
            file.kind.localizedTitle,
            ByteFormatting.string(forByteCount: file.size)
        ]
        if let modifiedAt = file.modifiedAt {
            parts.append(finderDateFormatter.string(from: modifiedAt))
        }
        let categoryNames = appModel.categories(for: file).map(\.localizedDisplayName)
        if !categoryNames.isEmpty {
            parts.append(categoryNames.joined(separator: AppLanguage.listSeparator))
        }
        return AppLanguage.joinedForAccessibility(parts)
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
                columns: FileGridCard.gridColumns,
                spacing: FileGridCard.gridSpacing
            ) {
                ForEach(files) { file in
                    FileGridCard(
                        file: file,
                        isSelected: appModel.selectedFileIDs.contains(file.id),
                        onSelect: { appModel.selectDisplayedFile(file, in: files) },
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
            .scrollTargetLayout()
            .padding(XunJianUI.pagePadding(for: contentWidth))
        }
        .scrollPosition(id: gridScrollPositionBinding)
        .fileListKeyboardNavigation(
            files: files,
            columnCount: FileGridCard.columnCount(forWidth: contentWidth)
        )
    }
}

/// Identifies the inputs a displayed-file snapshot was built from.
///
/// Deliberately free of the file array itself: this value is rebuilt on every
/// `body` evaluation and compared by `.task(id:)`, so carrying the whole index
/// made both the comparison and the allocation O(files). `filesRevision` from
/// the coordinator stands in for "the file set changed".
struct DisplayedFilesRefreshKey: Equatable {
    let filesRevision: UInt64
    let searchResultsRevision: UInt64
    let aiSearchResultCount: Int?
    let aiSearchRevision: UInt64
    let selectedKind: FileKind?
    let sortOrder: FileSortOrder
    let sortAscending: Bool
    let minSizeBytes: Int64
    let minDate: Date?

    var signature: Int {
        var hasher = Hasher()
        hasher.combine(filesRevision)
        hasher.combine(searchResultsRevision)
        hasher.combine(aiSearchResultCount)
        hasher.combine(aiSearchRevision)
        hasher.combine(selectedKind)
        hasher.combine(sortOrder)
        hasher.combine(sortAscending)
        hasher.combine(minSizeBytes)
        hasher.combine(minDate)
        return hasher.finalize()
    }
}

/// Skips rebuilding the file table when only unrelated AppModel fields changed.
private struct EquatableSnapshotList<Content: View>: View, Equatable {
    let signature: Int?
    let viewMode: FileBrowseViewMode
    let contentWidth: CGFloat
    let selectionToken: Int
    let content: () -> Content

    init(
        signature: Int?,
        viewMode: FileBrowseViewMode,
        contentWidth: CGFloat,
        selectionToken: Int,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.signature = signature
        self.viewMode = viewMode
        self.contentWidth = contentWidth
        self.selectionToken = selectionToken
        self.content = content
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.signature == rhs.signature
            && lhs.viewMode == rhs.viewMode
            && lhs.contentWidth == rhs.contentWidth
            && lhs.selectionToken == rhs.selectionToken
    }

    var body: some View {
        content()
    }
}

/// Category chips observe `CategoryIndexStore` so toggling one file does not
/// rebuild the enclosing table.
struct FileCategoryNamesLabel: View {
    let fileID: String
    @EnvironmentObject private var categoryIndex: CategoryIndexStore

    var body: some View {
        let names = categoryIndex.categories(for: fileID).map(\.localizedDisplayName)
        Text(
            names.isEmpty
                ? "—"
                : names.joined(separator: AppLanguage.listSeparator)
        )
        .lineLimit(1)
    }
}

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
        Button(AppLanguage.localized("打开", english: "Open")) { appModel.open(file) }
        Button(AppLanguage.localized("快速查看", english: "Quick Look")) { appModel.quickLook(file) }
        Button(AppLanguage.localized("在 Finder 中显示", english: "Show in Finder")) {
            appModel.showInFinder(file)
        }
        Button(AppLanguage.localized("复制路径", english: "Copy Path")) {
            appModel.copyPath(file)
        }

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
            Menu(AppLanguage.localized("添加到分类", english: "Add to Category")) {
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

            Button(AppLanguage.localized("重命名…", english: "Rename…")) {
                appModel.requestRename(file)
            }
            Button(AppLanguage.localized("移动到…", english: "Move To…")) {
                appModel.chooseMoveDestination(for: file)
            }
            Button(
                AppLanguage.localized("移到废纸篓", english: "Move to Trash"),
                role: .destructive
            ) {
                appModel.requestTrash(file)
            }
        }
    }
}
