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
    /// Live scroll identities stay in view state. Persisting every crossed row
    /// wakes UserDefaults observers and is measurable on very large libraries,
    /// so both modes write their settled position after a short debounce.
    @State private var liveListScrollPosition: String?
    @State private var liveGridScrollPosition: String?
    @State private var tableSelectedIDs: Set<String> = []
    /// Only external/programmatic selection changes need to pierce the
    /// equatable table shell. Native row clicks already update Table itself.
    @State private var tableSelectionEpoch: UInt64 = 0
    @State private var scrollPositionPersistenceTask: Task<Void, Never>?

    // Manual filters (N02): a size floor and a modified-since date, applied
    // on top of whatever search/AI narrowing is active. Values live on
    // AppModel so saved searches can restore them.
    @State private var showsFilterPopover = false
    @State private var savedSearchName = ""

    // F03: toolbar rows grow with the text size setting instead of clipping
    // at a fixed 32pt.
    @ScaledMetric(relativeTo: .body) private var toolbarControlHeight = FileToolbarMetrics.controlHeight

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
            if liveListScrollPosition == nil, !listScrollPosition.isEmpty {
                liveListScrollPosition = listScrollPosition
            }
            if liveGridScrollPosition == nil, !gridScrollPosition.isEmpty {
                liveGridScrollPosition = gridScrollPosition
            }
            tableSelectedIDs = appModel.selectedFileIDs
        }
        .onChange(of: isVisible) { _, visible in
            guard visible else { return }
            appModel.highlightQuery = appModel.searchText
            // The retained All Files view may still hold the previous
            // page's snapshot. Publish only after the current filters
            // have been recomputed so commands cannot target stale rows.
            appModel.updateCommandTargetFiles([])
        }
        .onChange(of: appModel.searchText) { _, text in
            guard isVisible else { return }
            appModel.highlightQuery = text
        }
        .onChange(of: appModel.selectedFileID) { _, id in
            guard isVisible, let id else { return }
            if viewMode == .list {
                liveListScrollPosition = id
            } else {
                liveGridScrollPosition = id
            }
            scheduleScrollPositionPersistence(id, mode: viewMode)
        }
        .onChange(of: appModel.selectedFileIDs) { _, ids in
            guard tableSelectedIDs != ids else { return }
            tableSelectedIDs = ids
            tableSelectionEpoch &+= 1
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
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(hasActiveManualFilter ? Color.accentColor : .primary)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
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
        Text(verbatim: resultDescription(resultCount: resultCount))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityLabel(Text(verbatim: resultDescription(resultCount: resultCount)))
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
                Image(systemName: "sparkles")
            } else {
                Label(
                    appModel.activeAIProviderKind?.title
                        ?? AppLanguage.localized("AI", english: "AI"),
                    systemImage: "sparkles"
                )
            }
        }
        .menuStyle(.button)
        .controlSize(.regular)
        .fixedSize()
        .accessibilityLabel(AppLanguage.localized("AI 功能", english: "AI Actions"))
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
        Picker(
            AppLanguage.localized("文件类型", english: "File Type"),
            selection: $appModel.selectedKind
        ) {
            fileTypeChoices
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: FileToolbarMetrics.fileTypeWidth)
        .fixedSize()
        .accessibilityLabel(AppLanguage.localized("文件类型", english: "File Type"))
    }

    private var sortMenu: some View {
        Picker(
            AppLanguage.localized("排序", english: "Sort"),
            selection: activeSortOrderBinding
        ) {
            sortChoices
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: FileToolbarMetrics.sortWidth(for: activeSortOrder))
        .fixedSize()
        .accessibilityLabel(AppLanguage.localized("排序", english: "Sort"))
    }

    private var viewModeControl: some View {
        Picker(
            AppLanguage.localized("显示方式", english: "View"),
            selection: $viewMode
        ) {
            ForEach(ViewMode.allCases) { mode in
                Label(
                    mode == .list
                        ? AppLanguage.localized("列表", english: "List")
                        : AppLanguage.localized("图标", english: "Icons"),
                    systemImage: mode.symbolName
                )
                .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: FileToolbarMetrics.viewModeWidth)
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
            Image(systemName: activeSortAscending ? "arrow.up" : "arrow.down")
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
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
            Label(
                AppLanguage.localized("更多工具", english: "More Tools"),
                systemImage: "ellipsis"
            )
        }
        .menuStyle(.button)
        .controlSize(.regular)
        .labelStyle(.iconOnly)
        .help(AppLanguage.localized("更多工具", english: "More Tools"))
        .accessibilityLabel(AppLanguage.localized("更多工具", english: "More Tools"))
    }

    private func emptyState(files: [IndexedFile]) -> some View {
        Group {
            if appModel.browseSnapshotSignature == nil, hasPotentialSourceFilesForDisplay {
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
                    selectionEpoch: tableSelectionEpoch,
                    layoutToken: FileTableLayout.snapshotLayoutToken(
                        contentWidth: contentWidth,
                        viewMode: viewMode
                    )
                ) {
                    fileTable(files: files)
                }
                .equatable()
            } else if viewMode == .grid, !files.isEmpty {
                EquatableSnapshotList(
                    signature: appModel.browseSnapshotSignature,
                    viewMode: viewMode,
                    selectionEpoch: 0,
                    layoutToken: FileTableLayout.snapshotLayoutToken(
                        contentWidth: contentWidth,
                        viewMode: viewMode
                    )
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

    private var hasPotentialSourceFilesForDisplay: Bool {
        let query = appModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let aiSearchResults = appModel.aiSearchResults {
            return query.isEmpty
                ? !aiSearchResults.isEmpty
                : !aiSearchResults.isEmpty && !(appModel.searchResults ?? []).isEmpty
        }
        if !query.isEmpty {
            return !(appModel.searchResults ?? []).isEmpty
        }
        return !appModel.files.isEmpty
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
            set: { selectSortOrder($0) }
        )
    }

    private func selectSortOrder(_ order: FileSortOrder) {
        guard activeSortOrder != order else { return }
        activeSortOrder = order
        activeSortAscending = order == .name || order == .kind
    }

    private var listScrollPositionBinding: Binding<String?> {
        Binding(
            get: { liveListScrollPosition },
            set: { newValue in
                liveListScrollPosition = newValue
                scheduleScrollPositionPersistence(newValue, mode: .list)
            }
        )
    }

    private var gridScrollPositionBinding: Binding<String?> {
        Binding(
            get: { liveGridScrollPosition },
            set: { newValue in
                // Live position lives in @State; the @AppStorage copy is
                // written debounced so scrolling the grid does not hammer
                // UserDefaults (and its observers) per crossed row.
                liveGridScrollPosition = newValue
                scheduleScrollPositionPersistence(newValue, mode: .grid)
            }
        )
    }

    private func scheduleScrollPositionPersistence(
        _ value: String?,
        mode: ViewMode
    ) {
        scrollPositionPersistenceTask?.cancel()
        scrollPositionPersistenceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            if mode == .list {
                listScrollPosition = value ?? ""
            } else {
                gridScrollPosition = value ?? ""
            }
        }
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
            minDate: minimumFilterDate,
            isVisible: isVisible
        )
    }

    private var displayedFilesUserKey: DisplayedFilesUserKey {
        DisplayedFilesUserKey(
            query: appModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines),
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
                    usesGlobalSearchPagination: true,
                    signature: signature
                )
                appModel.clearSelectionIfHidden(
                    from: appModel.browseSnapshotIDSet
                )
            }
            return
        }

        // The visible rows still show the previous snapshot while the new
        // filter/sort result is computed. Clear only the command target so a
        // delayed Select All or destructive action cannot act on those stale
        // rows during that short transition.
        appModel.clearCommandTargetFilesKeepingPagination()

        // Burst settle: when only the file index moved (not query, search
        // results, sort, or filters), wait out FSEvents / iCloud metadata
        // bursts instead of re-sorting and rebuilding the table on every
        // batch. The previous 5_000-file gate left the real 2.8k library
        // doing that work on every iCloud xattr tick.
        let userSignature = displayedFilesUserKey.signature
        if DisplayedFilesRefreshPolicy.shouldSettleRevisionDrivenRefresh(
            previousUserSignature: appModel.browseSnapshotUserSignature,
            currentUserSignature: userSignature
        ) {
            try? await Task.sleep(for: DisplayedFilesRefreshPolicy.revisionDrivenSettleDelay)
            guard !Task.isCancelled,
                  isVisible,
                  displayedFilesRefreshKey.signature == signature else { return }
        }

        let selectedKind = appModel.selectedKind
        let indexedFiles = selectedKind.map(appModel.files(for:)) ?? appModel.files
        let indexedFilesAreKindFiltered = selectedKind != nil
        let aiSearchResults = appModel.aiSearchResults
        let searchResults = appModel.searchResults
        let query = appModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
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
                let sourceFiles: [IndexedFile]
                let sourceIsKindFiltered: Bool
                if let aiSearchResults {
                    sourceIsKindFiltered = false
                    if query.isEmpty {
                        sourceFiles = aiSearchResults
                    } else {
                        let matchingFileIDs = Set((searchResults ?? []).map(\.id))
                        sourceFiles = aiSearchResults.filter {
                            matchingFileIDs.contains($0.id)
                        }
                    }
                } else if query.isEmpty {
                    sourceFiles = indexedFiles
                    sourceIsKindFiltered = indexedFilesAreKindFiltered
                } else {
                    sourceFiles = searchResults ?? []
                    sourceIsKindFiltered = false
                }
                let needsFiltering = (!sourceIsKindFiltered && selectedKind != nil)
                    || minSize > 0
                    || minDate != nil
                let filteredFiles = needsFiltering
                    ? sourceFiles.filter { file in
                        guard sourceIsKindFiltered
                                || selectedKind.map({ file.kind == $0 }) ?? true else {
                            return false
                        }
                        if minSize > 0, file.size < minSize { return false }
                        if let minDate {
                            guard let modifiedAt = file.modifiedAt,
                                  modifiedAt >= minDate else { return false }
                        }
                        return true
                    }
                    : sourceFiles
                guard !cancellationFlag.isCancelled else {
                    return (
                        files: [IndexedFile](),
                        orderedIDs: [String](),
                        idIndex: [String: Int](),
                        visibleIDs: Set<String>()
                    )
                }
                let sorted = requestedSortOrder.sorted(
                    filteredFiles,
                    ascending: requestedAscending
                )
                // Build both ID representations off the main actor. They are
                // reused by selection, keyboard navigation and cache hits.
                let orderedIDs = sorted.map(\.id)
                return (
                    files: sorted,
                    orderedIDs: orderedIDs,
                    idIndex: Dictionary(
                        uniqueKeysWithValues: orderedIDs.enumerated().map {
                            ($0.element, $0.offset)
                        }
                    ),
                    visibleIDs: Set(orderedIDs)
                )
            }.value
        } onCancel: {
            cancellationFlag.cancel()
        }
        guard !Task.isCancelled,
              isVisible,
              displayedFilesRefreshKey.signature == signature else { return }
        let result = computed.files
        appModel.publishBrowseSnapshot(
            result,
            orderedIDs: computed.orderedIDs,
            idIndex: computed.idIndex,
            visibleIDs: computed.visibleIDs,
            signature: signature,
            userSignature: userSignature
        )
        appModel.updateCommandTargetFiles(
            result,
            usesGlobalSearchPagination: true,
            signature: signature
        )
        appModel.clearSelectionIfHidden(from: computed.visibleIDs)
    }

    private func fileTable(files: [IndexedFile]) -> some View {
        Table(
            of: IndexedFile.self,
            selection: tableSelection,
            columnCustomization: $tableColumnCustomization
        ) {
            TableColumn(AppLanguage.localized("名称", english: "Name")) { file in
                plainTableCell {
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
            .width(min: 150, ideal: 280, max: 420)
            .customizationID("name")

            TableColumn(AppLanguage.localized("分类", english: "Category")) { file in
                plainTableCell(accessibilityHidden: true) {
                    FileCategoryNamesLabel(fileID: file.id)
                }
            }
            .width(min: 45, ideal: 90, max: 160)
            .customizationID("category")

            TableColumn(AppLanguage.localized("类型", english: "Kind")) { file in
                plainTableCell(accessibilityHidden: true) {
                    Text(file.kind.localizedTitle)
                        .lineLimit(1)
                }
            }
            .width(min: 45, ideal: 75, max: 120)
            .customizationID("type")

            TableColumn(AppLanguage.localized("大小", english: "Size")) { file in
                plainTableCell(accessibilityHidden: true) {
                    Text(ByteFormatting.string(forByteCount: file.size))
                        .lineLimit(1)
                }
            }
            .width(min: 50, ideal: 75, max: 110)
            .customizationID("size")

            TableColumn(AppLanguage.localized("修改时间", english: "Date Modified")) { file in
                plainTableCell(accessibilityHidden: true) {
                    if let modifiedAt = file.modifiedAt {
                        Text(finderDateFormatter.string(from: modifiedAt))
                    } else {
                        Text("—")
                    }
                }
            }
            .width(min: 90, ideal: 135, max: 180)
            .customizationID("modified")

            // Optional columns (N18). Hidden by default so the six-column
            // layout and its compression thresholds stay unchanged; users opt
            // in from the table header's context menu.
            TableColumn(AppLanguage.localized("创建时间", english: "Date Created")) { file in
                plainTableCell(accessibilityHidden: true) {
                    if let createdAt = file.createdAt {
                        Text(finderDateFormatter.string(from: createdAt))
                    } else {
                        Text("—")
                    }
                }
            }
            .width(min: 90, ideal: 135, max: 180)
            .customizationID("created")
            .defaultVisibility(.hidden)

            // Read-only Finder metadata (N17): shown here, never written back.
            TableColumn(AppLanguage.localized("标签", english: "Tags")) { file in
                plainTableCell(accessibilityHidden: true) {
                    FinderTagsLabel(file: file)
                }
            }
            .width(min: 60, ideal: 90, max: 160)
            .customizationID("finderTags")
            .defaultVisibility(.hidden)

            TableColumn(AppLanguage.localized("位置", english: "Where")) { file in
                plainTableCell(accessibilityHidden: true) {
                    Text(file.parentPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .width(min: 80, ideal: 200, max: 360)
            .customizationID("location")
        } rows: {
            ForEach(files) { file in
                // Keep drag support at the native table-row layer. Putting
                // gestures on the name cell creates a SwiftUI hit-testing
                // surface that prevents NSTableView from receiving clicks.
                TableRow(file)
                    .draggable(file.url)
            }
        }
        .contextMenu(forSelectionType: String.self) { selection in
            if let file = tableFile(for: selection) {
                FileContextMenu(file: file)
            }
        } primaryAction: { selection in
            guard let file = tableFile(for: selection) else { return }
            doubleClickBehavior.perform(on: file, using: appModel)
        }
        .scrollPosition(id: listScrollPositionBinding)
        .frame(maxHeight: .infinity, alignment: .leading)
        // Arrow keys are left to the table's own row navigation; this only
        // adds the file actions on top.
        .fileListKeyboardNavigation(
            files: files,
            orderedIDs: appModel.browseSnapshotIDs,
            idIndex: appModel.browseSnapshotIDIndex,
            handlesArrowKeys: false
        )
    }

    /// Cell wrapper without per-cell interaction modifiers. Selection and
    /// row actions stay at the native Table/TableRow layers so a 100k-row
    /// table does not pay extra gesture modifiers per cell and the full name
    /// column remains clickable.
    private func plainTableCell<Content: View>(
        accessibilityHidden: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityHidden(accessibilityHidden)
    }

    private func tableFile(for selection: Set<String>) -> IndexedFile? {
        if let selectedFileID = appModel.selectedFileID,
           selection.contains(selectedFileID),
           let selectedFile = appModel.index.file(id: selectedFileID) {
            return selectedFile
        }
        guard let fileID = selection.first else { return nil }
        return appModel.index.file(id: fileID)
    }

    /// Table's native selection is the only click path. Same-set writes are
    /// dropped so `@Published` does not fire twice for one click.
    private var tableSelection: Binding<Set<String>> {
        Binding(
            get: { tableSelectedIDs },
            set: { newValue in
                guard newValue != tableSelectedIDs else { return }
                tableSelectedIDs = newValue
                let modifiers = NSApp.currentEvent?.modifierFlags ?? []
                appModel.applyNativeTableSelection(
                    newValue,
                    orderedIDs: appModel.browseSnapshotIDs,
                    idIndex: appModel.browseSnapshotIDIndex,
                    command: modifiers.contains(.command),
                    shift: modifiers.contains(.shift)
                )
            }
        )
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

    private func fileGrid(files: [IndexedFile]) -> some View {
        ScrollView {
            LazyVGrid(
                columns: FileGridCard.gridColumns,
                spacing: FileGridCard.gridSpacing
            ) {
                ForEach(files) { file in
                    FileGridSelectableCard(
                        file: file,
                        isSelected: appModel.selectedFileIDs.contains(file.id),
                        selectedIDs: appModel.$selectedFileIDs,
                        onSelect: { selectGridFile(file) },
                        onOpen: { openGridFile(file) }
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
            orderedIDs: appModel.browseSnapshotIDs,
            idIndex: appModel.browseSnapshotIDIndex,
            columnCount: FileGridCard.columnCount(forWidth: contentWidth)
        )
    }

    private func selectGridFile(_ file: IndexedFile) {
        let modifiers = NSEvent.modifierFlags
        let command = modifiers.contains(.command)
        let shift = modifiers.contains(.shift)
        guard FileBrowseSelection.shouldPublishSelectionChange(
            fileID: file.id,
            selectedIDs: appModel.selectedFileIDs,
            command: command,
            shift: shift
        ) else { return }
        appModel.selectDisplayedFile(
            file.id,
            inIDs: appModel.browseSnapshotIDs,
            command: command,
            shift: shift,
            idIndex: appModel.browseSnapshotIDIndex
        )
    }

    private func openGridFile(_ file: IndexedFile) {
        if FileBrowseSelection.shouldPublishSelectionChange(
            fileID: file.id,
            selectedIDs: appModel.selectedFileIDs,
            command: false,
            shift: false
        ) {
            appModel.selectedFileID = file.id
        }
        doubleClickBehavior.perform(on: file, using: appModel)
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
    let isVisible: Bool

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

/// Interactive snapshot inputs. Two keys with the same signature differ only
/// because `filesRevision` changed, which lets the view settle FSEvents
/// bursts without delaying search or filter results.
struct DisplayedFilesUserKey: Equatable {
    let query: String
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
        hasher.combine(query)
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

enum DisplayedFilesRefreshPolicy {
    static let revisionDrivenSettleDelay: Duration = .milliseconds(250)

    static func shouldSettleRevisionDrivenRefresh(
        previousUserSignature: Int?,
        currentUserSignature: Int
    ) -> Bool {
        previousUserSignature == currentUserSignature
    }
}

/// Skips rebuilding the file table when only unrelated AppModel fields changed.
private struct EquatableSnapshotList<Content: View>: View, Equatable {
    let signature: Int?
    let viewMode: FileBrowseViewMode
    let selectionEpoch: UInt64
    let layoutToken: Int
    let content: () -> Content

    init(
        signature: Int?,
        viewMode: FileBrowseViewMode,
        selectionEpoch: UInt64,
        layoutToken: Int,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.signature = signature
        self.viewMode = viewMode
        self.selectionEpoch = selectionEpoch
        self.layoutToken = layoutToken
        self.content = content
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.signature == rhs.signature
            && lhs.viewMode == rhs.viewMode
            && lhs.selectionEpoch == rhs.selectionEpoch
            && lhs.layoutToken == rhs.layoutToken
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
