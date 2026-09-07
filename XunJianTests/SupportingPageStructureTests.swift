import Foundation
import XCTest
#if !SUPPORTING_PAGES_STANDALONE
@testable import XunJian
#endif

/// 固定本轮视觉层级约束；截图与原生交互验收仍由独立夹具负责。
final class SupportingPageStructureTests: XCTestCase {
    func testEmptyListWaitsForIndexAndDisplaySnapshot() {
        XCTAssertTrue(FileListLoadingPresentation.showsPreparing(displayedIsEmpty: true, indexIsOpening: true, snapshotIsCurrent: true, hasSourceFiles: false))
        XCTAssertTrue(FileListLoadingPresentation.showsPreparing(displayedIsEmpty: true, indexIsOpening: false, snapshotIsCurrent: false, hasSourceFiles: true))
        XCTAssertFalse(FileListLoadingPresentation.showsPreparing(displayedIsEmpty: true, indexIsOpening: false, snapshotIsCurrent: true, hasSourceFiles: true), "完成筛选后的零结果不是加载状态")
        XCTAssertFalse(FileListLoadingPresentation.showsPreparing(displayedIsEmpty: true, indexIsOpening: false, snapshotIsCurrent: true, hasSourceFiles: false), "真实空库应显示空态")
        XCTAssertFalse(FileListLoadingPresentation.showsPreparing(displayedIsEmpty: false, indexIsOpening: false, snapshotIsCurrent: false, hasSourceFiles: true), "刷新时保留已有文件")
    }
    func testStatisticsRefreshDoesNotResetIndependentFileOperations() throws {
        let source = try viewSource("StorageInsightsView.swift")
        let refresh = try XCTUnwrap(source.components(separatedBy: ".task(id: appModel.filesRevision) {").last?.components(separatedBy: ".onDisappear").first)
        XCTAssertFalse(refresh.contains("cleaningDuplicateGroupID = nil"))
        XCTAssertFalse(refresh.contains("duplicateGroups = []"))
        XCTAssertFalse(refresh.contains("duplicateSearchTask?.cancel()"))
        XCTAssertFalse(refresh.contains("hasComputed = false"))
        XCTAssertTrue(source.contains("DisclosureGroup"))
        XCTAssertTrue(source.contains("LazyVStack"))
    }

    func testFilteredEmptyStateDoesNotSuggestAnEmptyLibrary() {
        for query in ["", "   ", "品牌方案"] {
            let reason = FileSearchEmptyReason.resolve(query: query, hasFilters: true, invalidSize: false)
            XCTAssertEqual(reason, .filters)
            XCTAssertTrue(reason.offersFilterReset, "筛选与关键词同时存在时，仍必须能单独清除筛选")
        }
        XCTAssertEqual(FileSearchEmptyReason.resolve(query: "方案", hasFilters: false, invalidSize: false), .keyword)
        XCTAssertEqual(FileSearchEmptyReason.resolve(query: " \n ", hasFilters: false, invalidSize: false), .library)
        let invalid = FileSearchEmptyReason.resolve(query: "方案", hasFilters: false, invalidSize: true)
        XCTAssertEqual(invalid, .invalidFilters)
        XCTAssertTrue(invalid.offersFilterReset)
    }
    func testDirectoryDoesNotDuplicateSettingsOrInterceptNativeListNavigation() throws {
        let sidebar = try viewSource("SidebarView.swift")
        XCTAssertFalse(sidebar.contains("selection = .settings"), "设置在窗口工具栏已有固定入口")
        XCTAssertFalse(sidebar.contains(".onMoveCommand"), "目录方向键不能路由到不在列表内的全局页面")
        XCTAssertTrue(sidebar.contains("List(selection: $selection)"), "由原生列表管理可见资料集的键盘选择")
    }

    func testWorkspaceNavigationDoesNotOverrideChildAccessibilityIdentifiers() throws {
        let theme = try viewSource("Components/AppVisualTheme.swift")
        XCTAssertFalse(theme.contains(".accessibilityIdentifier(\"workspace.destinations\")"), "父标识不能覆盖三个导航按钮")
        XCTAssertTrue(theme.contains(".accessibilityElement(children: .contain)"))
    }
    func testWorkspaceDestinationsDescribeTasksInsteadOfOldPages() {
        XCTAssertEqual(NavigationDestination.home.title(categories: []), AppLanguage.localized("最近", english: "Recent"))
        XCTAssertEqual(NavigationDestination.allFiles.title(categories: []), AppLanguage.localized("查找", english: "Search"))
        XCTAssertEqual(NavigationDestination.categories.title(categories: []), AppLanguage.localized("资料集", english: "Collections"))
    }
    func testHomeEmptyStateIgnoresSourcesOutsideCurrentScope() {
        struct Source: Equatable { let available: Bool; let enabled: Bool }
        let unavailableRoot = Source(available: false, enabled: true)
        let availableFolder = Source(available: true, enabled: true)
        let pausedFolder = Source(available: true, enabled: false)
        let wholeMac = HomeEmptyStateKind.scopedSources(wholeMac: true, wholeMacSource: unavailableRoot, selectedFolderSources: [availableFolder])
        XCTAssertEqual(wholeMac, [unavailableRoot])
        XCTAssertEqual(HomeEmptyStateKind.resolve(hasSources: !wholeMac.isEmpty, isScanning: false, isPaused: false, hasEnabledSource: wholeMac.contains { $0.enabled && $0.available }, hasAvailableSource: wholeMac.contains { $0.available }), .accessUnavailable)
        let missingRoot = HomeEmptyStateKind.scopedSources(wholeMac: true, wholeMacSource: Optional<Source>.none, selectedFolderSources: [availableFolder])
        XCTAssertTrue(missingRoot.isEmpty)
        let folders = HomeEmptyStateKind.scopedSources(wholeMac: false, wholeMacSource: availableFolder, selectedFolderSources: [pausedFolder])
        XCTAssertEqual(folders, [pausedFolder])
        XCTAssertEqual(HomeEmptyStateKind.resolve(hasSources: !folders.isEmpty, isScanning: false, isPaused: false, hasEnabledSource: folders.contains { $0.enabled && $0.available }, hasAvailableSource: folders.contains { $0.available }), .paused)
    }

    func testHomeEmptyStateUsesCurrentSourceAndScanState() {
        XCTAssertEqual(HomeEmptyStateKind.resolve(hasSources: false, isScanning: false, isPaused: false, hasEnabledSource: false, hasAvailableSource: false), .unauthorized)
        XCTAssertEqual(HomeEmptyStateKind.resolve(hasSources: true, isScanning: true, isPaused: false, hasEnabledSource: true, hasAvailableSource: true), .scanning)
        XCTAssertEqual(HomeEmptyStateKind.resolve(hasSources: true, isScanning: false, isPaused: true, hasEnabledSource: true, hasAvailableSource: true), .paused)
        XCTAssertEqual(HomeEmptyStateKind.resolve(hasSources: true, isScanning: false, isPaused: false, hasEnabledSource: false, hasAvailableSource: true), .paused)
        XCTAssertEqual(HomeEmptyStateKind.resolve(hasSources: true, isScanning: false, isPaused: false, hasEnabledSource: true, hasAvailableSource: false), .accessUnavailable)
        XCTAssertEqual(HomeEmptyStateKind.resolve(hasSources: true, isScanning: false, isPaused: false, hasEnabledSource: true, hasAvailableSource: true), .readyEmpty)
    }

    func testSettingsUsesDirectPagesAndPreservesExternalProviderDrafts() throws {
        let source = try viewSource("Settings/SettingsView.swift")
        XCTAssertTrue(source.contains("SettingsPage.allCases"), "设置需要直接可见的分区入口，而非长表单跳转菜单")
        XCTAssertTrue(source.contains("switch selectedPage"))
        XCTAssertFalse(source.contains("scroll.scrollTo(section, anchor: .top)"))
        XCTAssertFalse(source.contains(".id(selectedSection)"))
        XCTAssertFalse(source.contains(".controlSize(AppVisualTheme.resolve(visualTheme) == .precision ? .small"))
        let provider = try viewSource("Settings/AIProviderSettingsRow.swift")
        XCTAssertTrue(provider.contains("restoreDraftOrSynchronizeFields"))
        XCTAssertTrue(provider.contains("draftStore.save("))
    }

    func testCategorySearchRemainsOutsideEmptyAndLoadingBranches() throws {
        let source = try viewSource("Categories/CategoriesView.swift")
        XCTAssertTrue(source.contains(".toolbar { categoryFileToolbar(contentWidth: geometry.size.width) }"))
        XCTAssertTrue(source.contains("onMoveSelection: { offset in"))
        XCTAssertTrue(source.contains("categoryWorkspaceHeader(contentWidth: geometry.size.width)"))
        XCTAssertTrue(source.contains(".accessibilityIdentifier(\"collection.search\")"))
        XCTAssertTrue(source.contains("if let statusContent { statusContent }"))
        XCTAssertFalse(source.contains("FileBrowseToolbar("), "分类与所有文件使用相同层级的34pt菜单，不额外堆叠旧工具条")
    }
    func testSupportingPagesDoNotDuplicateShellTitleWithMarketingHeader() throws {
        for path in ["Home/HomeView.swift", "Categories/CategoriesView.swift", "Settings/SettingsView.swift"] {
            let source = try viewSource(path)
            XCTAssertFalse(source.contains("PageHeader("), "\(path) 不应重复 Shell 顶部页名")
        }
    }

    func testWorkspaceUsesDirectModeNavigationAndCompactDirectory() throws {
        let shell = try viewSource("AppShellView.swift")
        XCTAssertTrue(shell.contains("EditorialNavigationTabs"), "主任务放在原生顶部工具栏")
        XCTAssertFalse(shell.contains("StudioNavigationRail"), "9F 不保留彩色任务轨")
        XCTAssertFalse(shell.contains("workspaceModeBar"), "不再用顶部四段选择器承载整个产品导航")
        XCTAssertTrue(shell.contains("prefersSidebarVisible: false"), "资源目录按需展开，不能启动时常驻")
        let home = try viewSource("Home/HomeView.swift")
        XCTAssertFalse(home.contains("searchHero"))
        XCTAssertFalse(home.contains("InsetSurface("))
        XCTAssertFalse(home.contains("GroupedSurface("))
        XCTAssertFalse(home.contains("InteractiveCardBackground("))
        let categories = try viewSource("Categories/CategoriesView.swift")
        XCTAssertFalse(categories.contains("InteractiveCardBackground("))
        let overview = try XCTUnwrap(categories.components(separatedBy: "private var categoryOverview: some View").last)
            .components(separatedBy: "private func categoryFiles").first ?? ""
        XCTAssertTrue(overview.contains("LazyVStack"), "资料集使用紧凑平面条目，不堆叠卡片")
        XCTAssertTrue(categories.contains("collections.search"))
        XCTAssertFalse(categories.contains("design: .serif"))
        XCTAssertTrue(categories.contains("WorkspaceRowSeparator()"))
    }

    func testLibrarySearchLivesInContentAndLegacyThemeSelectorIsRemoved() throws {
        let files = try viewSource("Files/AllFilesView.swift")
        XCTAssertTrue(files.contains("librarySearchHeader"))
        XCTAssertFalse(files.contains("ToolbarItem(id: \"files.search\""))
        let settings = try viewSource("Settings/SettingsView.swift")
        XCTAssertFalse(settings.contains("settings.visualTheme"))
        XCTAssertTrue(settings.contains("AIProviderSettingsRow(kind: selectedProvider, isDetail: true)"))
        let inspector = try viewSource("Components/FileInspectorEmptyView.swift")
        XCTAssertTrue(inspector.contains("inspector.mode"))
        XCTAssertTrue(inspector.contains(".accessibilityHidden(isFileInformationExpanded)"))
    }

    func testQuickSearchKeepsThemeCanvasVisibleAndDoesNotRecreateOnThemeSwitch() throws {
        let source = try viewSource("MenuBarSearchView.swift")
        XCTAssertTrue(source.contains(".scrollContentBackground(.hidden)"))
        XCTAssertTrue(source.contains(".padding(.vertical, theme.rowVerticalPadding)"))
        XCTAssertFalse(source.contains(".id(visualTheme)"))
        XCTAssertFalse(source.contains(".onChange(of: visualTheme)"))
        XCTAssertFalse(source.contains(".task(id: visualTheme)"))
    }

    private func viewSource(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("XunJian/Views/\(path)"), encoding: .utf8)
    }
}
