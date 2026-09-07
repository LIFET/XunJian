import AppKit
import SwiftUI

struct AllFilesView: View {
    /// Shared with the category page so both honour the same stored default.
    typealias ViewMode = FileBrowseViewMode

    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var searchProgressStore: SearchProgressStore
    @EnvironmentObject private var categoryIndex: CategoryIndexStore
    @Environment(\.locale) private var locale
    @Environment(\.appVisualTheme) private var visualTheme
    @Environment(\.colorScheme) private var colorScheme

    let windowWidth: CGFloat
    private let initialContentWidth: CGFloat
    @State private var measuredResultsWidth: CGFloat?
    private var contentWidth: CGFloat { measuredResultsWidth ?? initialContentWidth }
    var isVisible = true
    var statusContent: AnyView? = nil
    var workspaceInspector: WorkspaceInspectorModifier? = nil

    @AppStorage("allFiles.viewMode") private var viewMode = ViewMode.list
    @AppStorage("allFiles.listPresentation") private var listPresentation = FileListPresentation.defaultValue
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
    /// A native table click is already visible. Feeding that same row back
    /// through `scrollPosition` makes a six-figure table locate and scroll to
    /// its current row again, adding avoidable work to every selection.
    @State private var nativeSelectionLeadID: String?
    /// Only external/programmatic selection changes need to pierce the
    /// equatable table shell. Native row clicks already update Table itself.
    @State private var tableSelectionEpoch: UInt64 = 0
    @State private var scrollPositionPersistenceTask: Task<Void, Never>?
    /// Page-local, atomically published browse state. Keeping this off the
    /// broad AppModel prevents one 100k-row refresh from invalidating the
    /// sidebar, inspector, settings and app commands at the same time.
    @State private var browseSnapshot = DisplayedFilesSnapshot.empty
    /// Search pages are observed directly instead of being forwarded through
    /// AppModel. Only a new result revision wakes this retained page; typing
    /// and the searching flag stay inside their narrow stores.
    @State private var searchResultState = BrowseSearchStore.ResultState.empty

    // Manual filters (N02): a size floor and a modified-since date, applied
    // on top of whatever search/AI narrowing is active. Values live on
    // AppModel so saved searches can restore them.
    @State private var showsFilterPopover = false
    @State private var showsSaveSearch = false
    @State private var savedSearchName = ""

    private var finderDateFormatter: DateFormatter {
        FinderDateFormatting.formatter(for: locale)
    }

    init(windowWidth: CGFloat, contentWidth: CGFloat, isVisible: Bool = true, statusContent: AnyView? = nil,
         workspaceInspector: WorkspaceInspectorModifier? = nil) {
        self.windowWidth = windowWidth
        self.initialContentWidth = contentWidth
        self.isVisible = isVisible
        self.statusContent = statusContent
        self.workspaceInspector = workspaceInspector
    }

    var body: some View {
        Group {
            if isVisible {
                content(filesSnapshot: browseSnapshot.files)
            } else {
                Color.clear
                    .accessibilityHidden(true)
            }
        }
        .task(id: displayedFilesRefreshKey) {
            guard isVisible else { return }
            await refreshDisplayedFilesSnapshot()
        }
        .onReceive(
            appModel.browseSearchStore.$resultState.removeDuplicates {
                $0.revision == $1.revision
            }
        ) { state in
            searchResultState = state
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
            synchronizeSelectionFromModel(appModel.selectedFileIDs)
        }
        .onChange(of: isVisible) { _, visible in
            guard visible else { return }
            appModel.highlightQuery = appModel.searchText
            synchronizeSelectionFromModel(appModel.selectedFileIDs)
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
            if (listPresentation == .results && viewMode == .list
                || FileBrowsePerformancePolicy.usesNativeBrowser(fileCount: appModel.files.count)),
               nativeSelectionLeadID == id {
                nativeSelectionLeadID = nil
                return
            }
            nativeSelectionLeadID = nil
            if viewMode == .list {
                liveListScrollPosition = id
            } else {
                liveGridScrollPosition = id
            }
            scheduleScrollPositionPersistence(id, mode: viewMode)
        }
        .onChange(of: appModel.selectedFileIDs) { _, ids in
            synchronizeSelectionFromModel(ids)
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
            librarySearchHeader
            WorkspaceRowSeparator()
            if let workspaceInspector {
                resultsWorkspace(filesSnapshot: filesSnapshot).modifier(workspaceInspector)
            } else {
                resultsWorkspace(filesSnapshot: filesSnapshot)
            }
        }
        .background(visualTheme.palette(for: colorScheme).canvas)
    }

    private func resultsWorkspace(filesSnapshot: [IndexedFile]) -> some View {
        VStack(spacing: 0) {
            fileHeader(filesSnapshot: filesSnapshot)
            emptyState(files: filesSnapshot)
            fileLocationFooter(resultCount: filesSnapshot.count)
        }
        .background(visualTheme.palette(for: colorScheme).surface)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            measuredResultsWidth = width
        }
    }

    @ViewBuilder
    private func fileHeader(filesSnapshot: [IndexedFile]) -> some View {
        if activeFilterCount > 0 { activeFilterSummary }
        if let statusContent { statusContent }
        if appModel.selectedFileIDs.count > 1 {
            FileBatchActionBar(contentWidth: contentWidth)
        }
        if let plan = appModel.aiSearchPlan {
            HStack(spacing: 8) {
                Label(aiSearchModeDescription(for: plan), systemImage: "sparkles")
                    .symbolRenderingMode(.hierarchical)
                    .lineLimit(1)
                    .help(aiSearchModeDescription(for: plan))
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

    private var librarySearchHeader: some View {
        HStack(spacing: 12) {
            workspaceSearch
            if initialContentWidth >= 800 {
                Menu {
                    Picker(AppLanguage.localized("文件类型", english: "File Type"), selection: $appModel.selectedKind) {
                        Text(AppLanguage.localized("所有类型", english: "All Types")).tag(Optional<FileKind>.none)
                    ForEach(FileKind.allCases) { kind in
                        Text(kind.localizedTitle).tag(Optional(kind))
                    }
                    }.pickerStyle(.inline)
                } label: {
                    Text(appModel.selectedKind?.localizedTitle ?? AppLanguage.localized("所有类型", english: "All Types"))
                }
                .fixedSize()
                .help(AppLanguage.localized("文件类型", english: "File Type"))
                Menu { resultSortChoices
                } label: {
                    Text(activeSortOrder.localizedTitle)
                }
                .fixedSize()
                .help(sortDescription)
                Menu { resultDisplayChoices } label: {
                    Image(systemName: viewMode.symbolName).frame(width: 28, height: 32)
                }
                .fixedSize()
                .help(AppLanguage.localized("显示方式", english: "View Mode"))
                .accessibilityLabel(AppLanguage.localized("显示方式", english: "View Mode"))
            } else {
                Menu {
                    Section(AppLanguage.localized("文件类型", english: "File Type")) {
                        Picker(AppLanguage.localized("类型", english: "Kind"), selection: $appModel.selectedKind) {
                            Text(AppLanguage.localized("所有类型", english: "All Types")).tag(Optional<FileKind>.none)
                            ForEach(FileKind.allCases) { Text($0.localizedTitle).tag(Optional($0)) }
                        }.pickerStyle(.inline)
                    }
                    Section(AppLanguage.localized("排序", english: "Sort")) { resultSortChoices }
                    Section(AppLanguage.localized("显示方式", english: "View Mode")) { resultDisplayChoices }
                } label: { Image(systemName: viewMode.symbolName).frame(width: 28, height: 32) }
                .fixedSize().accessibilityLabel(AppLanguage.localized("类型、排序与显示", english: "Type, Sort and View"))
                .help(AppLanguage.localized("类型、排序与显示", english: "Type, Sort and View"))
            }
            filterButton
            Button {
                savedSearchName = ""
                showsSaveSearch = true
            } label: {
                Label(AppLanguage.localized("保存搜索", english: "Save Search"), systemImage: "bookmark")
                    .labelStyle(.iconOnly)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .help(AppLanguage.localized("保存当前搜索与筛选", english: "Save this search and filters"))
            .disabled(!Self.canSaveSearch(name: "Search", query: appModel.searchText,
                hasManualFilter: hasActiveManualFilter, kind: appModel.selectedKind) || appModel.hasInvalidSizeFilterInput)
            .sheet(isPresented: $showsSaveSearch) { saveSearchForm }
            Menu { aiChoices } label: { Image(systemName: "sparkles").frame(width: 28, height: 32) }
                .fixedSize()
                .help(AppLanguage.localized("AI 功能", english: "AI Actions"))
                .accessibilityLabel(AppLanguage.localized("AI 功能", english: "AI Actions"))
        }
        .controlSize(.large)
        .buttonStyle(.borderless)
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(visualTheme.palette(for: colorScheme).canvas)
    }

    private var workspaceSearch: some View {
                BrowseSearchField(
                    store: appModel.browseSearchStore,
                    appModel: appModel,
                    isCompact: false,
                    onMoveSelection: { offset in
                        guard isVisible, FileResultNavigationPolicy.canNavigate(
                            hasResults: !browseSnapshot.orderedIDs.isEmpty,
                            isSearching: appModel.browseSearchStore.isSearching,
                            snapshotSignature: browseSnapshot.signature,
                            expectedSignature: displayedFilesRefreshKey.signature,
                            snapshotUserSignature: browseSnapshot.userSignature,
                            expectedUserSignature: displayedFilesUserKey.signature
                        ) else { return false }
                        appModel.moveDisplayedSelection(by: offset, inIDs: browseSnapshot.orderedIDs,
                                                        extending: false, idIndex: browseSnapshot.idIndex)
                        return true
                    }
                )
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("library.search")
    }

    private var sortDescription: String {
        activeSortOrder.localizedTitle + " · " + (activeSortOrder == .relevance
            ? AppLanguage.localized("最相关优先", english: "Most Relevant First")
            : (activeSortAscending ? AppLanguage.localized("升序", english: "Ascending")
               : AppLanguage.localized("降序", english: "Descending")))
    }

    private var activeFilterCount: Int {
        (appModel.selectedKind == nil ? 0 : 1)
            + (minimumSizeBytes > 0 || appModel.hasInvalidSizeFilterInput ? 1 : 0)
            + (minimumFilterDate == nil ? 0 : 1)
    }

    private var activeFilterSummary: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text(AppLanguage.localized("筛选 \(activeFilterCount)", english: "Filters \(activeFilterCount)"))
                    .foregroundStyle(.secondary)
                if let kind = appModel.selectedKind {
                    filterChip(kind.localizedTitle) { appModel.selectedKind = nil }
                }
                if minimumSizeBytes > 0 || appModel.hasInvalidSizeFilterInput {
                    filterChip(appModel.hasInvalidSizeFilterInput
                        ? AppLanguage.localized("大小条件无效", english: "Invalid Size")
                        : AppLanguage.localized("大小 ≥ \(appModel.filterMinSizeMB.formatted()) MB",
                                                english: "Size ≥ \(appModel.filterMinSizeMB.formatted()) MB")) {
                        appModel.filterMinSizeMB = 0
                    }
                }
                if let date = minimumFilterDate {
                    filterChip(AppLanguage.localized("修改于 \(date.formatted(date: .numeric, time: .omitted)) 之后",
                                                     english: "Modified Since \(date.formatted(date: .numeric, time: .omitted))")) {
                        appModel.filterMinDate = 0
                    }
                }
                Button {
                    appModel.selectedKind = nil
                    appModel.filterMinSizeMB = 0
                    appModel.filterMinDate = 0
                } label: {
                    Text(AppLanguage.localized("全部清除", english: "Clear All"))
                        .padding(.horizontal, 8)
                        .frame(minHeight: XunJianUI.controlHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(AppLanguage.localized("清除类型、大小与日期条件，保留搜索词", english: "Clear type, size and date conditions; keep the search query"))
            }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
        .background(visualTheme.palette(for: colorScheme).canvas)
        .overlay(alignment: .bottom) { WorkspaceRowSeparator() }
    }

    private func filterChip(_ title: String, clear: @escaping () -> Void) -> some View {
        Button(action: clear) {
            HStack(spacing: 6) {
                Text(title)
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
            }
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(minHeight: XunJianUI.controlHeight)
            .background(visualTheme.palette(for: colorScheme).selection, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AppLanguage.localized("移除筛选：\(title)", english: "Remove Filter: \(title)"))
        .help(AppLanguage.localized("移除筛选：\(title)", english: "Remove Filter: \(title)"))
    }

    private var resultSortChoices: some View {
        Group {
            ForEach(availableSortOrders) { order in
                Toggle(order.localizedTitle, isOn: Binding(
                    get: { activeSortOrder == order }, set: { if $0 { activeSortOrderBinding.wrappedValue = order } }))
            }
            Divider()
            Toggle(AppLanguage.localized("升序", english: "Ascending"), isOn: Binding(
                get: { activeSortAscending }, set: { activeSortAscending = $0 }))
                .disabled(activeSortOrder == .relevance)
        }
    }

    private var resultDisplayChoices: some View {
        Group {
            Toggle(AppLanguage.localized("结果列表", english: "Results List"), isOn: Binding(
                get: { viewMode == .list && listPresentation == .results },
                set: { if $0 { listPresentation = .results; viewMode = .list } }))
            Toggle(AppLanguage.localized("属性表格", english: "Column Table"), isOn: Binding(
                get: { viewMode == .list && listPresentation == .table },
                set: { if $0 { listPresentation = .table; viewMode = .list } }))
            Toggle(AppLanguage.localized("图标网格", english: "Icon Grid"), isOn: Binding(
                get: { viewMode == .grid }, set: { if $0 { viewMode = .grid } }))
        }
    }

    /// Manual size/date filter entry point (N02). Highlighted while active so
    /// the narrowing is visible at a glance.
    private var filterButton: some View {
        Button {
            showsFilterPopover.toggle()
        } label: {
            Label(AppLanguage.localized("筛选", english: "Filter"),
                  systemImage: hasActiveManualFilter || appModel.hasInvalidSizeFilterInput ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                .labelStyle(.iconOnly)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .help(AppLanguage.localized("按大小或修改日期筛选", english: "Filter by size or modified date"))
        .accessibilityLabel(AppLanguage.localized("筛选文件", english: "Filter Files"))
        .popover(isPresented: $showsFilterPopover, arrowEdge: .bottom) { filterPopover }
    }

    private var filterPopover: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text(AppLanguage.localized("过滤条件", english: "Filters"))
                    .font(XunJianUI.Typography.sectionTitle)

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

                    if appModel.hasInvalidSizeFilterInput {
                        Text(AppLanguage.localized(
                            "请输入有效的非负大小，数值不能超过支持范围。",
                            english: "Enter a non-negative size within the supported range."
                        ))
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    }
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
                    .disabled(!hasActiveManualFilter && !appModel.hasInvalidSizeFilterInput)
                }
            }
            .padding(16)
            .frame(width: 280)
    }

    private var saveSearchForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(AppLanguage.localized("保存搜索", english: "Save Search"))
                .font(.headline)
            Text(AppLanguage.localized("将当前关键词、类型和筛选条件保存到目录，方便再次查找。", english: "Keep this query, type and filters in the directory for next time."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(
                AppLanguage.localized("搜索名称", english: "Search name"),
                text: $savedSearchName
            )
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("savedSearch.name")
            HStack {
                Spacer()
                Button(AppLanguage.localized("取消", english: "Cancel")) { showsSaveSearch = false }
                    .keyboardShortcut(.cancelAction)
                Button(AppLanguage.localized("保存搜索", english: "Save Search")) {
                    appModel.saveSearch(
                        name: savedSearchName,
                        query: appModel.searchText,
                        minSizeBytes: minimumSizeBytes,
                        minDate: minimumFilterDate
                    )
                    savedSearchName = ""
                    showsSaveSearch = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    !Self.canSaveSearch(
                        name: savedSearchName,
                        query: appModel.searchText,
                        hasManualFilter: hasActiveManualFilter,
                        kind: appModel.selectedKind
                    ) || appModel.hasInvalidSizeFilterInput
                )
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private func headerSummary(resultCount: Int) -> some View {
        Text(verbatim: resultDescription(resultCount: resultCount))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help(resultDescription(resultCount: resultCount))
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
                    contentWidth < 700 ? AppLanguage.localized("加载更多", english: "Load More") :
                    AppLanguage.localized(
                        "加载更多（\(searchResultState.results?.count ?? 0)/\(searchResultState.totalCount ?? 0)）",
                        english: "Load More (\(searchResultState.results?.count ?? 0)/\(searchResultState.totalCount ?? 0))"
                    )
                )
            }
            .buttonStyle(.link)
            .accessibilityHint(
                AppLanguage.localized(
                    "当前仅显示前 \(searchResultState.results?.count ?? 0) 项搜索结果",
                    english: "Currently showing the first \(searchResultState.results?.count ?? 0) search results"
                )
            )
        }
    }

    private func fileLocationFooter(resultCount: Int) -> some View {
        VStack(spacing: 0) {
            Divider()
            Group {
                if contentWidth >= 440 {
                    HStack(spacing: 12) {
                        footerLocation.frame(minWidth: 0, maxWidth: .infinity)
                        footerStatus(resultCount: resultCount).fixedSize(horizontal: true, vertical: false)
                    }
                    .frame(minHeight: 40)
                } else {
                    VStack(spacing: 0) {
                        footerLocation.frame(height: XunJianUI.controlHeight)
                        footerStatus(resultCount: resultCount)
                            .padding(.vertical, 6)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .background(visualTheme.palette(for: colorScheme).canvas)
    }

    @ViewBuilder
    private var footerLocation: some View {
        if appModel.selectedFileIDs.count == 1, let file = appModel.selectedFile {
            FileLocationPathView(url: file.url)
                .frame(height: XunJianUI.controlHeight)
        } else {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                Text(appModel.selectedKind?.localizedTitle ?? AppLanguage.localized("资料库", english: "Library"))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func footerStatus(resultCount: Int) -> some View {
        HStack(spacing: 8) {
            headerSummary(resultCount: resultCount)
            Spacer(minLength: 4)
            searchProgress
            if !appModel.selectedFileIDs.isEmpty {
                Text(verbatim: AppLanguage.localized(
                    "已选 \(appModel.selectedFileIDs.count) 项",
                    english: "\(appModel.selectedFileIDs.count) selected"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
    }

    private var aiChoices: some View {
        let hasAIProvider = appModel.activeAIProviderKind != nil
        return Group {
            if !hasAIProvider {
                Text(
                    AppLanguage.localized(
                        "请先在设置中配置当前 AI",
                        english: "Configure the current AI in Settings first"
                    )
                )
                Button {
                    NotificationCenter.default.post(name: .xunJianOpenSettings, object: SettingsPage.ai)
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
        }
    }


    private func emptyState(files: [IndexedFile]) -> some View {
        Group {
            if FileListLoadingPresentation.showsPreparing(
                displayedIsEmpty: files.isEmpty, indexIsOpening: appModel.databaseState == .opening,
                snapshotIsCurrent: browseSnapshot.signature == displayedFilesRefreshKey.signature,
                hasSourceFiles: hasPotentialSourceFilesForDisplay
            ) {
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
                    signature: browseSnapshot.signature,
                    viewMode: viewMode,
                    selectionEpoch: tableSelectionEpoch,
                    metadataEpoch: FileBrowsePerformancePolicy.usesNativeTable(
                        fileCount: appModel.files.count
                    ) ? categoryIndex.revision : 0,
                    layoutToken: FileTableLayout.snapshotLayoutToken(
                        contentWidth: contentWidth,
                        viewMode: viewMode
                    ),
                    presentationToken: "\(visualTheme.rawValue)|\(listPresentation.rawValue)|\(appModel.searchText)"
                ) {
                    fileTable(files: files)
                }
                .equatable()
            } else if viewMode == .grid, !files.isEmpty {
                EquatableSnapshotList(
                    signature: browseSnapshot.signature,
                    viewMode: viewMode,
                    selectionEpoch: tableSelectionEpoch,
                    metadataEpoch: 0,
                    layoutToken: FileTableLayout.snapshotLayoutToken(
                        contentWidth: contentWidth,
                        viewMode: viewMode
                    ),
                    presentationToken: visualTheme.rawValue
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
                    if appModel.databaseState == .opening {
                        EmptyView()
                    } else if appModel.databaseState.showsFailure {
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
                    } else if searchEmptyReason.offersFilterReset {
                        Button(
                            AppLanguage.localized("清除筛选条件", english: "Clear Filters")
                        ) {
                            appModel.filterMinSizeMB = 0
                            appModel.filterMinDate = 0
                            appModel.selectedKind = nil
                        }
                        .buttonStyle(.borderedProminent)
                        if !appModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button(AppLanguage.localized("清除关键词", english: "Clear Keyword")) {
                                appModel.searchText = ""
                            }
                        }
                    } else if searchEmptyReason == .keyword {
                        Button(AppLanguage.localized("清除关键词", english: "Clear Keyword")) {
                            appModel.searchText = ""
                        }
                        .buttonStyle(.borderedProminent)
                    } else if appModel.files.isEmpty {
                        if indexAvailability.emptyState != .scanning {
                        Button(indexAvailability.emptyStateActionTitle) {
                            indexAvailability.performEmptyStateAction()
                        }
                        .buttonStyle(.borderedProminent)
                        }
                        Button(AppLanguage.localized("管理搜索位置", english: "Manage Search Locations")) {
                            NotificationCenter.default.post(name: .xunJianOpenSettings, object: SettingsPage.files)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 560, minHeight: 280)
                .padding(XunJianUI.pagePadding(for: contentWidth))
            }
        }
        .xunjianAnimation(
            FileBrowsePerformancePolicy.animatesModeChange(fileCount: files.count)
                ? XunJianUI.standardAnimation
                : nil,
            value: viewMode
        )
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
        if appModel.databaseState == .opening {
            return AppLanguage.localized("正在打开本地索引…", english: "Opening local index…")
        }
        if appModel.databaseState.showsFailure {
            return AppLanguage.localized("本地索引不可用", english: "Local index unavailable")
        }
        if appModel.aiSearchResults != nil {
            return AppLanguage.localized(
                "AI 没有找到相关文件",
                english: "AI found no matching files"
            )
        }
        if searchEmptyReason == .invalidFilters {
            return AppLanguage.localized("大小条件无效", english: "Invalid size filter")
        }
        if searchEmptyReason == .filters {
            return AppLanguage.localized("没有符合条件的文件", english: "No files match these filters")
        }
        return appModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (appModel.files.isEmpty ? indexAvailability.emptyStateTitle : AppLanguage.localized("还没有文件", english: "No files yet"))
            : AppLanguage.localized("没有找到相关文件", english: "No matching files")
    }

    private var indexAvailability: IndexAvailabilityPresentation {
        IndexAvailabilityPresentation(appModel: appModel)
    }

    private var searchEmptyReason: FileSearchEmptyReason {
        .resolve(query: appModel.searchText,
                 hasFilters: hasActiveManualFilter || appModel.selectedKind != nil,
                 invalidSize: appModel.hasInvalidSizeFilterInput)
    }

    private var emptyDescription: String {
        if appModel.databaseState == .opening {
            return AppLanguage.localized(
                "索引准备完成后，文件会自动显示。",
                english: "Files appear automatically when the index is ready."
            )
        }
        if appModel.databaseState.showsFailure {
            return AppLanguage.localized(
                "无法读取文件索引，请重试。",
                english: "The file index could not be read. Please try again."
            )
        }
        if appModel.aiSearchResults == nil, searchEmptyReason == .invalidFilters {
            return AppLanguage.localized("请在筛选中输入有效大小，或清除筛选条件。", english: "Enter a valid size in Filters, or clear the filters.")
        }
        if appModel.aiSearchResults == nil, searchEmptyReason == .filters {
            return AppLanguage.localized("试着放宽类型、大小或日期条件。清除筛选会保留当前关键词。", english: "Try broader type, size or date filters. Clearing filters keeps your keyword.")
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
                    "清除类型筛选后可查看所有文件。",
                    english: "Clear the type filter to return to all files."
                )
            }
            if appModel.files.isEmpty { return indexAvailability.emptyStateDescription }
            return AppLanguage.localized(
                "添加文件夹并完成扫描后可查看文件。",
                english: "Add a folder and scan it to see its files."
            )
        }
        return AppLanguage.localized(
            "试试更短的关键词，或检查是否有错别字。",
            english: "Try a shorter keyword or check the spelling."
        )
    }

    private var hasPotentialSourceFilesForDisplay: Bool {
        let query = appModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let aiSearchResults = appModel.aiSearchResults {
            return query.isEmpty
                ? !aiSearchResults.isEmpty
                : !aiSearchResults.isEmpty && !(searchResultState.results ?? []).isEmpty
        }
        if !query.isEmpty {
            return !(searchResultState.results ?? []).isEmpty
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
                guard FileBrowsePerformancePolicy.tracksLiveListScrollPosition(
                    fileCount: browseSnapshot.files.count
                ) else { return }
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
            searchResultsRevision: searchResultState.revision,
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
            searchResultsRevision: searchResultState.revision,
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
        appModel.minimumFilterSizeBytes
    }

    private var minimumFilterDate: Date? {
        appModel.filterMinDate > 0 ? Date(timeIntervalSince1970: appModel.filterMinDate) : nil
    }

    private var hasActiveManualFilter: Bool {
        minimumSizeBytes > 0 || minimumFilterDate != nil
    }

    nonisolated static func canSaveSearch(
        name: String,
        query: String,
        hasManualFilter: Bool,
        kind: FileKind?
    ) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || hasManualFilter || kind != nil)
    }

    private func refreshDisplayedFilesSnapshot() async {
        let signature = displayedFilesRefreshKey.signature
        // Returning to this page with unchanged inputs reuses the cached list
        // instead of re-sorting and flashing a placeholder.
        guard browseSnapshot.signature != signature else {
            if isVisible {
                appModel.updateCommandTargetFiles(
                    browseSnapshot.files,
                    usesGlobalSearchPagination: true,
                    signature: signature
                )
                appModel.clearSelectionIfHidden(
                    using: browseSnapshot.idIndex
                )
            }
            return
        }

        // Burst settle: when only the file index moved (not query, search
        // results, sort, or filters), wait out FSEvents / iCloud metadata
        // bursts instead of re-sorting and rebuilding the table on every
        // batch. The previous 5_000-file gate left the real 2.8k library
        // doing that work on every iCloud xattr tick.
        let userSignature = displayedFilesUserKey.signature
        if DisplayedFilesRefreshPolicy.shouldSettleRevisionDrivenRefresh(
            previousUserSignature: browseSnapshot.userSignature,
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
        let searchResults = searchResultState.results
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
                        idIndex: [String: Int]()
                    )
                }
                guard let sorted = requestedSortOrder.sortedCancellable(
                    filteredFiles,
                    ascending: requestedAscending,
                    isCancelled: { cancellationFlag.isCancelled }
                ) else {
                    return (
                        files: [IndexedFile](),
                        orderedIDs: [String](),
                        idIndex: [String: Int]()
                    )
                }
                // Build both ID representations off the main actor. They are
                // reused by selection, keyboard navigation and cache hits.
                var orderedIDs: [String] = []
                orderedIDs.reserveCapacity(sorted.count)
                var idIndex: [String: Int] = [:]
                idIndex.reserveCapacity(sorted.count)
                for (offset, file) in sorted.enumerated() {
                    if offset.isMultiple(of: 2_048), cancellationFlag.isCancelled {
                        return (
                            files: [IndexedFile](),
                            orderedIDs: [String](),
                            idIndex: [String: Int]()
                        )
                    }
                    orderedIDs.append(file.id)
                    idIndex[file.id] = offset
                }
                return (
                    files: sorted,
                    orderedIDs: orderedIDs,
                    idIndex: idIndex
                )
            }.value
        } onCancel: {
            cancellationFlag.cancel()
        }
        guard !Task.isCancelled,
              isVisible,
              displayedFilesRefreshKey.signature == signature else { return }
        let result = computed.files
        browseSnapshot = DisplayedFilesSnapshot(
            files: result,
            orderedIDs: computed.orderedIDs,
            idIndex: computed.idIndex,
            signature: signature,
            userSignature: userSignature
        )
        appModel.updateCommandTargetFiles(
            result,
            usesGlobalSearchPagination: true,
            signature: signature
        )
        appModel.clearSelectionIfHidden(using: computed.idIndex)
    }

    @ViewBuilder
    private func fileTable(files: [IndexedFile]) -> some View {
        // Base the renderer on the library size, not the current filter.
        // Otherwise changing file type can tear down AppKit and rebuild a
        // SwiftUI Table exactly while the user is clicking the toolbar.
        if listPresentation == .results || FileBrowsePerformancePolicy.usesNativeTable(fileCount: appModel.files.count) {
            nativeFileTable(files: files)
        } else {
            swiftUIFileTable(files: files)
        }
    }

    private func nativeFileTable(files: [IndexedFile]) -> some View {
        LargeFileTableView(
            files: files,
            idIndex: browseSnapshot.idIndex,
            contentVersion: browseSnapshot.signature ?? 0,
            categoryVersion: categoryIndex.revision,
            autosaveName: listPresentation == .results ? "XunJian.AllFiles.Results" : "XunJian.AllFiles.LargeTable",
            locale: locale,
            presentation: listPresentation,
            resultQuery: appModel.searchText,
            resultTextProvider: { file in
                try? await appModel.fetchInspectorPreviewText(forFileID: file.id, maximumCharacters: 8_192)
            },
            selection: nativeSelectionBinding(for: .list),
            categoryText: { file in
                categoryIndex.categories(for: file.id)
                    .map(\.localizedDisplayName)
                    .joined(separator: AppLanguage.listSeparator)
            },
            onSelectionLeadChange: { file in
                nativeSelectionLeadID = file?.id
            },
            onDoubleClick: { file in
                doubleClickBehavior.perform(on: file, using: appModel)
            },
            onQuickLook: { file in
                appModel.quickLook(file)
            },
            onDelete: {
                if appModel.selectedFileIDs.count > 1 {
                    appModel.requestBatchTrash()
                } else if let file = appModel.selectedFile {
                    appModel.requestTrash(file)
                }
            },
            contextMenuProvider: { file, selectedIDs in
                nativeContextMenu(for: file, selectedIDs: selectedIDs)
            }
        )
        .id(listPresentation)
        .frame(maxHeight: .infinity, alignment: .leading)
    }

    private func swiftUIFileTable(files: [IndexedFile]) -> some View {
        listTableScrollTracking(
            Table(
                of: IndexedFile.self,
                selection: nativeSelectionBinding(for: .list),
                columnCustomization: $tableColumnCustomization
            ) {
                TableColumn(AppLanguage.localized("名称", english: "Name")) { file in
                    plainTableCell {
                        HStack(spacing: 8) {
                            FileThumbnail(file: file, size: 24)
                                .accessibilityHidden(true)
                            Text(file.name)
                                .lineLimit(1)
                                .help(file.name)
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
                        .help(file.parentPath)
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
            .scrollContentBackground(.hidden)
            .background(visualTheme.palette(for: colorScheme).canvas)
            .contextMenu(forSelectionType: String.self) { selection in
                if let file = tableFile(for: selection) {
                    FileContextMenu(file: file)
                }
            } primaryAction: { selection in
                guard let file = tableFile(for: selection) else { return }
                doubleClickBehavior.perform(on: file, using: appModel)
            },
            fileCount: files.count
        )
        .frame(maxHeight: .infinity, alignment: .leading)
        // Arrow keys are left to the table's own row navigation; this only
        // adds the file actions on top.
        .fileListKeyboardNavigation(
            files: files,
            orderedIDs: browseSnapshot.orderedIDs,
            idIndex: browseSnapshot.idIndex,
            handlesArrowKeys: false
        )
    }

    /// Omitting the modifier matters: a setter that discards updates still
    /// makes SwiftUI resolve and observe row identities while scrolling. On a
    /// six-figure table that work delays native selection and inspector
    /// changes even though no position is ultimately persisted.
    @ViewBuilder
    private func listTableScrollTracking<Content: View>(
        _ content: Content,
        fileCount: Int
    ) -> some View {
        if FileBrowsePerformancePolicy.tracksLiveListScrollPosition(fileCount: fileCount) {
            content.scrollPosition(id: listScrollPositionBinding)
        } else {
            content
        }
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
            .padding(.vertical, visualTheme.rowVerticalPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityHidden(accessibilityHidden)
    }

    private func nativeContextMenu(
        for file: IndexedFile,
        selectedIDs: Set<String>
    ) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NativeFileActionMenuItem(
            title: AppLanguage.localized("打开", english: "Open")
        ) { appModel.open(file) })
        menu.addItem(NativeFileActionMenuItem(
            title: AppLanguage.localized("快速查看", english: "Quick Look")
        ) { appModel.quickLook(file) })
        menu.addItem(NativeFileActionMenuItem(
            title: AppLanguage.localized("在 Finder 中显示", english: "Show in Finder")
        ) { appModel.showInFinder(file) })
        menu.addItem(NativeFileActionMenuItem(
            title: AppLanguage.localized("复制路径", english: "Copy Path")
        ) { appModel.copyPath(file) })
        menu.addItem(.separator())

        let actsOnSelection = selectedIDs.count > 1 && selectedIDs.contains(file.id)
        let categoryRoot = NSMenuItem(
            title: AppLanguage.localized(
                actsOnSelection ? "将所选文件添加到资料集" : "添加到资料集",
                english: actsOnSelection ? "Add Selection to Collection" : "Add to Collection"
            ),
            action: nil,
            keyEquivalent: ""
        )
        let categoryMenu = NSMenu()
        if appModel.categories.isEmpty {
            let empty = NSMenuItem(
                title: AppLanguage.localized("还没有资料集", english: "No collections yet"),
                action: nil,
                keyEquivalent: ""
            )
            empty.isEnabled = false
            categoryMenu.addItem(empty)
            categoryMenu.addItem(NativeFileActionMenuItem(
                title: AppLanguage.localized("新建资料集…", english: "New Collection…")
            ) {
                NotificationCenter.default.post(
                    name: .xunJianRequestNewCategory,
                    object: nil
                )
            })
        } else {
            for category in appModel.categories {
                let item = NativeFileActionMenuItem(
                    title: category.localizedDisplayName
                ) {
                    if actsOnSelection {
                        appModel.assignSelectedFiles(to: category)
                    } else {
                        appModel.toggleCategory(category, for: file)
                    }
                }
                if !actsOnSelection, appModel.isCategory(category, assignedTo: file) {
                    item.state = .on
                }
                categoryMenu.addItem(item)
            }
        }
        categoryRoot.submenu = categoryMenu
        menu.addItem(categoryRoot)

        if actsOnSelection {
            menu.addItem(NativeFileActionMenuItem(
                title: AppLanguage.localized(
                    "移到废纸篓（\(selectedIDs.count) 项）",
                    english: "Move \(selectedIDs.count) Items to Trash"
                )
            ) { appModel.requestBatchTrash() })
        } else {
            menu.addItem(.separator())
            menu.addItem(NativeFileActionMenuItem(
                title: AppLanguage.localized("重命名…", english: "Rename…")
            ) { appModel.requestRename(file) })
            menu.addItem(NativeFileActionMenuItem(
                title: AppLanguage.localized("移动到…", english: "Move To…")
            ) { appModel.chooseMoveDestination(for: file) })
            menu.addItem(NativeFileActionMenuItem(
                title: AppLanguage.localized("移到废纸篓", english: "Move to Trash")
            ) { appModel.requestTrash(file) })
        }
        return menu
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

    private func synchronizeSelectionFromModel(_ ids: Set<String>) {
        guard tableSelectedIDs != ids else { return }
        tableSelectedIDs = ids
        // A retained equatable list does not observe this local mirror.
        // Initial appearance and page restoration need the same epoch as
        // subsequent model changes, or its native selection remains empty.
        tableSelectionEpoch &+= 1
    }

    /// Table's native selection is the only click path. Same-set writes are
    /// dropped so `@Published` does not fire twice for one click.
    private func nativeSelectionBinding(
        for sourceMode: FileBrowseViewMode
    ) -> Binding<Set<String>> {
        Binding(
            get: { tableSelectedIDs },
            set: { newValue in
                let accepts = FileBrowseSelection.shouldAcceptNativeSelectionPublication(
                    from: sourceMode,
                    currentMode: viewMode
                )
                guard accepts else { return }
                guard newValue != tableSelectedIDs else { return }
                tableSelectedIDs = newValue
                tableSelectionEpoch &+= 1
                let modifiers = NSApp.currentEvent?.modifierFlags ?? []
                appModel.applyNativeTableSelection(
                    newValue,
                    orderedIDs: browseSnapshot.orderedIDs,
                    idIndex: browseSnapshot.idIndex,
                    command: modifiers.contains(.command),
                    shift: modifiers.contains(.shift)
                )
                nativeSelectionLeadID = appModel.selectedFileID
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

    @ViewBuilder
    private func fileGrid(files: [IndexedFile]) -> some View {
        // SwiftUI still eagerly resolves a large ForEach's identities even
        // when LazyVGrid materializes only visible cards. Keep the large-data
        // path fully native, matching the table renderer.
        if FileBrowsePerformancePolicy.usesNativeGrid(fileCount: appModel.files.count) {
            nativeFileGrid(files: files)
        } else if FileBrowsePerformancePolicy.tracksLiveGridScrollPosition(fileCount: files.count) {
            fileGridScrollView(files: files, tracksScrollPosition: true)
                .scrollPosition(id: gridScrollPositionBinding)
                .fileListKeyboardNavigation(
                    files: files,
                    orderedIDs: browseSnapshot.orderedIDs,
                    idIndex: browseSnapshot.idIndex,
                    columnCount: FileGridCard.columnCount(forWidth: contentWidth)
                )
        } else {
            fileGridScrollView(files: files, tracksScrollPosition: false)
                .fileListKeyboardNavigation(
                    files: files,
                    orderedIDs: browseSnapshot.orderedIDs,
                    idIndex: browseSnapshot.idIndex,
                    columnCount: FileGridCard.columnCount(forWidth: contentWidth)
                )
        }
    }

    private func nativeFileGrid(files: [IndexedFile]) -> some View {
        LargeFileGridView(
            files: files,
            idIndex: browseSnapshot.idIndex,
            contentVersion: browseSnapshot.signature ?? 0,
            selection: nativeSelectionBinding(for: .grid),
            onSelectionLeadChange: { file in
                nativeSelectionLeadID = file?.id
            },
            onDoubleClick: { file in
                doubleClickBehavior.perform(on: file, using: appModel)
            },
            onQuickLook: { file in
                appModel.quickLook(file)
            },
            onDelete: {
                if appModel.selectedFileIDs.count > 1 {
                    appModel.requestBatchTrash()
                } else if let file = appModel.selectedFile {
                    appModel.requestTrash(file)
                }
            },
            contextMenuProvider: { file, selectedIDs in
                nativeContextMenu(for: file, selectedIDs: selectedIDs)
            }
        )
        .frame(maxHeight: .infinity, alignment: .leading)
    }

    private func fileGridScrollView(
        files: [IndexedFile],
        tracksScrollPosition: Bool
    ) -> some View {
        ScrollView {
            fileGridRows(files: files, tracksScrollPosition: tracksScrollPosition)
        }
    }

    @ViewBuilder
    private func fileGridRows(
        files: [IndexedFile],
        tracksScrollPosition: Bool
    ) -> some View {
        if tracksScrollPosition {
            fileGridCards(files: files)
                .scrollTargetLayout()
        } else {
            fileGridCards(files: files)
        }
    }

    private func fileGridCards(files: [IndexedFile]) -> some View {
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
        .padding(XunJianUI.pagePadding(for: contentWidth))
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
            inIDs: browseSnapshot.orderedIDs,
            command: command,
            shift: shift,
            idIndex: browseSnapshot.idIndex
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
