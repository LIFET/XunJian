import SwiftUI
import AppKit

// 9F THESIS: One flat search and reading desk, no persistent rail or page cards.
// OWN-WORLD: White, ice gray and graphite; system typography and native controls.
// STORY: Search, select a result, read it without losing position.
// FIRST VIEWPORT: Native text navigation, full-width search, narrow index / wide reader.
// FORM: User-approved Editorial Desk comp; replaces rejected 9E.
// FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

extension Notification.Name {
    static let xunJianToggleSidebar = Notification.Name("xunJianToggleSidebar")
}

enum WorkspaceSplitProportions {
    static func idealInspectorWidth(for theme: AppVisualTheme) -> CGFloat {
        1_000
    }
}

/// Attached below the search strip so native split resizing cannot cover it.
struct WorkspaceInspectorModifier: ViewModifier {
    @EnvironmentObject private var appModel: AppModel
    @Binding var isPresented: Bool
    var maximumWidth: CGFloat

    func body(content: Content) -> some View {
        content.inspector(isPresented: $isPresented) {
            FileInspectorView(file: appModel.selectedFile, onClose: { isPresented = false })
                .inspectorColumnWidth(min: 280, ideal: min(1_000, maximumWidth), max: maximumWidth)
                .disabled(!appModel.isDatabaseAvailable)
        }
    }
}

/// Read the actual window viewport, not a split view's larger ideal size.
/// This is event-driven and never searches or repositions native dividers.
private struct WorkspaceWindowSizeObserver: NSViewRepresentable {
    var onResize: (CGFloat) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onResize = onResize
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onResize = onResize
    }

    final class ObserverView: NSView {
        var onResize: ((CGFloat) -> Void)?
        private var lastWidth: CGFloat?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            lastWidth = nil
            guard let window else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(windowResized),
                                                  name: NSWindow.didResizeNotification, object: window)
            windowResized()
        }

        @objc private func windowResized() {
            guard let width = window?.contentLayoutRect.width, width > 0, width != lastWidth else { return }
            lastWidth = width
            DispatchQueue.main.async { [weak self] in self?.onResize?(width) }
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

struct AppShellResponsiveLayoutState: Equatable {
    private(set) var prefersSidebarVisible = true
    private(set) var prefersInspectorVisible = false
    private(set) var isSidebarForcedCollapsed = false
    private(set) var isSidebarManuallyPresentedAtCompactWidth = false
    private(set) var isInspectorForcedCollapsed = false
    /// A deliberate open at a compact width stays authoritative. Without
    /// this, the next layout measurement immediately re-applies the automatic
    /// collapse and makes the Inspector button appear broken.
    private(set) var isInspectorManuallyPresentedAtCompactWidth = false

    var showsSidebar: Bool {
        prefersSidebarVisible && !isSidebarForcedCollapsed
    }

    func showsSidebar(for destination: NavigationDestination?) -> Bool {
        destination != .settings && showsSidebar
    }

    mutating func setSidebarVisible(_ visible: Bool, for destination: NavigationDestination?) {
        guard destination != .settings else { return }
        setSidebarVisible(visible)
    }

    var showsInspector: Bool {
        prefersInspectorVisible && !isInspectorForcedCollapsed
    }

    mutating func update(windowWidth: CGFloat) {
        guard windowWidth > 0 else { return }

        if isSidebarForcedCollapsed {
            if windowWidth > XunJianUI.Breakpoint.sidebarRestore {
                isSidebarForcedCollapsed = false
                isSidebarManuallyPresentedAtCompactWidth = false
            }
        } else if windowWidth > XunJianUI.Breakpoint.sidebarRestore {
            isSidebarManuallyPresentedAtCompactWidth = false
        } else if !isSidebarManuallyPresentedAtCompactWidth,
                  windowWidth < XunJianUI.Breakpoint.sidebarAutoCollapse {
            isSidebarForcedCollapsed = true
        }

        if windowWidth < AppShellView.minimumInspectorWindowWidth {
            isInspectorForcedCollapsed = true
            isInspectorManuallyPresentedAtCompactWidth = false
        } else if isInspectorForcedCollapsed {
            if windowWidth > XunJianUI.Breakpoint.inspectorRestore {
                isInspectorForcedCollapsed = false
                isInspectorManuallyPresentedAtCompactWidth = false
            }
        } else if windowWidth > XunJianUI.Breakpoint.inspectorRestore {
            isInspectorManuallyPresentedAtCompactWidth = false
        } else if prefersInspectorVisible,
                  !isInspectorManuallyPresentedAtCompactWidth,
                  windowWidth < XunJianUI.Breakpoint.inspectorAutoCollapse {
            isInspectorForcedCollapsed = true
        }
    }

    mutating func setSidebarVisible(_ isVisible: Bool) {
        if isVisible {
            prefersSidebarVisible = true
            isSidebarForcedCollapsed = false
            isSidebarManuallyPresentedAtCompactWidth = true
            return
        }
        guard !isSidebarForcedCollapsed else { return }
        prefersSidebarVisible = isVisible
        isSidebarManuallyPresentedAtCompactWidth = false
    }

    mutating func setInspectorVisible(_ isVisible: Bool) {
        if isVisible {
            prefersInspectorVisible = true
            isInspectorForcedCollapsed = false
            isInspectorManuallyPresentedAtCompactWidth = true
            return
        }
        // SwiftUI writes `false` when the responsive policy removes the
        // Inspector. Preserve the user's preference so widening can restore
        // it; a real manual close only arrives while the Inspector is shown.
        guard !isInspectorForcedCollapsed else { return }
        prefersInspectorVisible = isVisible
        isInspectorManuallyPresentedAtCompactWidth = false
    }
}

enum AppShellSearchCommandRoute: Equatable {
    case focusVisibleField
    case revealAllFilesThenFocus
}

enum AppShellBrowseModeCommandRoute: Equatable {
    case visibleFilePage
    case revealAllFiles
}

struct AppShellView: View {
    nonisolated static let minimumInspectorWindowWidth: CGFloat = 720

    @EnvironmentObject private var appModel: AppModel
    @Environment(\.locale) private var locale
    @Environment(\.appVisualTheme) private var visualTheme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var selection: NavigationDestination? = .allFiles
    @State private var settingsPage: SettingsPage = .general
    @State private var responsiveLayout = AppShellResponsiveLayoutState(prefersSidebarVisible: false)
    @State private var windowWidth: CGFloat = 1_200
    @State private var showsGlobalNewCategory = false
    @StateObject private var aiProviderSettingsDraftStore = AIProviderSettingsDraftStore()
    @StateObject private var collectionBrowseContext = CollectionBrowseContext()

    var body: some View {
        let _ = (locale.identifier, appModel.localeRevision)
        appContent
            .modifier(FileWorkspaceDefaultToolbarItems(isFileWorkspace: false))
            .background {
                WorkspaceWindowSizeObserver(onResize: updateResponsiveLayout)
                    .frame(width: 0, height: 0)
            }
    }

    private var sidebarVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { showsNavigationSidebar ? .all : .detailOnly },
            set: { visibility in
                guard selection != .settings else { return }
                let visible = visibility != .detailOnly
                if !visible && showsInspector && windowWidth < 1_100 { return }
                if visible && windowWidth < 1_100 { setInspectorVisible(false) }
                responsiveLayout.setSidebarVisible(visible, for: selection)
            }
        )
    }

    private var showsNavigationSidebar: Bool {
        responsiveLayout.showsSidebar(for: selection) && !(showsInspector && windowWidth < 1_100)
    }

    private var appContent: some View {
        let workspace = NavigationSplitView(columnVisibility: sidebarVisibility) {
            SidebarView(selection: $selection, categories: appModel.categories.map(\.localizedForDisplay))
                .navigationSplitViewColumnWidth(min: 180, ideal: 212, max: 260)
                .modifier(FileWorkspaceDefaultToolbarItems(isFileWorkspace: false, isSettings: selection == .settings))
        } detail: {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    if !isInspectorDestination { statusBanners }
                    selectedContent(contentWidth: geometry.size.width)
                }
                .background(visualTheme.palette(for: colorScheme).canvas)
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 320)
            .navigationTitle(AppLanguage.localized("寻简", english: "XunJian"))
        }
        .navigationSplitViewStyle(.balanced)
        .focusedSceneValue(\.xunJianCommandContext, commandContext)
        return workspace
            .toolbar {
                navigationToolbar
                ToolbarItem(id: "workspace.settings", placement: .primaryAction) {
                    Button { selection = .settings } label: {
                        Label(AppLanguage.localized("设置", english: "Settings"), systemImage: "gearshape")
                    }
                    .help(AppLanguage.localized("设置", english: "Settings"))
                    .accessibilityIdentifier("workspace.settings")
                    .accessibilityAddTraits(selection == .settings ? .isSelected : [])
                }
                inspectorToolbar
            }
            .xunjianThinScrollers()
            .onReceive(NotificationCenter.default.publisher(for: .xunJianToggleSidebar)) { _ in
                sidebarVisibility.wrappedValue = showsNavigationSidebar ? .detailOnly : .all
            }
            .onReceive(NotificationCenter.default.publisher(for: .xunJianRevealInAllFiles)) { _ in
                selection = .allFiles
            }
            .onReceive(NotificationCenter.default.publisher(for: .xunJianFocusSearch)) { _ in
                focusSearch()
            }
            .onReceive(NotificationCenter.default.publisher(for: .xunJianSetBrowseViewMode)) { note in
                guard let raw = note.object as? String,
                      let mode = FileBrowseViewMode(rawValue: raw) else { return }
                handleBrowseViewModeNotification(mode)
            }
            .onReceive(NotificationCenter.default.publisher(for: .xunJianToggleInspector)) { _ in
                guard canToggleInspector else { return }
                setInspectorVisible(!showsInspector)
            }
            .onChange(of: selection) { _, newSelection in
                prepareCommandTargets(for: newSelection)
            }
            .onChange(of: appModel.categoryRevision) { _, _ in
                selection = Self.selectionAfterCategoryReload(
                    selection,
                    availableCategoryIDs: Set(appModel.categories.map(\.id))
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .xunJianRequestNewCategory)) { _ in
                showsGlobalNewCategory = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .xunJianOpenExternalPath)) { notification in
                let paths: [String]
                if let batch = notification.object as? [String] {
                    paths = batch
                } else if let path = notification.object as? String {
                    paths = [path]
                } else {
                    return
                }
                selection = .allFiles
                appModel.handleExternalPaths(paths)
            }
            .modifier(GlobalPresentations(selection: $selection, settingsPage: $settingsPage))
            .alert(
                AppLanguage.localized("操作未完成", english: "Action Couldn’t Finish"),
                isPresented: presentsErrorAlert
            ) {
                Button(AppLanguage.localized("好", english: "OK")) { appModel.clearError() }
            } message: {
                Text(AppLanguage.localizedRuntimeMessage(appModel.errorMessage ?? ""))
            }
            .sheet(item: $appModel.renameRequest) { file in
                RenameFileSheet(file: file) { newName in
                    try await appModel.rename(file, to: newName)
                }
                .environment(\.locale, locale)
            }
            // AI sheets live at the shell level so the inspector (and any
            // other page) can open them, not just the All Files toolbar (N04).
            .sheet(item: $appModel.aiSheetRequest) { task in
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
                .xunjianThinScrollers()
            }
            .sheet(isPresented: $showsGlobalNewCategory) {
                CategoryEditorSheet(
                    title: AppLanguage.localized("新建分类", english: "New Category")
                ) { name, symbolName in
                    try await appModel.createCategory(name: name, symbolName: symbolName)
                }
                .environment(\.locale, locale)
            }
            .alert(
                AppLanguage.localized("移到废纸篓？", english: "Move to Trash?"),
                isPresented: Binding(
                    get: { appModel.trashRequest != nil },
                    set: { if !$0 { appModel.trashRequest = nil } }
                )
            ) {
                Button(AppLanguage.localized("取消", english: "Cancel"), role: .cancel) {
                    appModel.trashRequest = nil
                }
                Button(
                    AppLanguage.localized("移到废纸篓", english: "Move to Trash"),
                    role: .destructive
                ) {
                    appModel.confirmTrash()
                }
            } message: {
                let fileName = appModel.trashRequest?.name
                    ?? AppLanguage.localized("这个文件", english: "this file")
                Text(
                    AppLanguage.localized(
                        "“\(fileName)”将被移到系统废纸篓，可以从废纸篓恢复。",
                        english: "“\(fileName)” will be moved to the system Trash and can be restored from there."
                    )
                )
            }
            .alert(
                AppLanguage.localized("批量移到废纸篓？", english: "Move to Trash?"),
                isPresented: Binding(
                    get: { appModel.batchTrashRequest != nil },
                    set: { if !$0 { appModel.cancelBatchTrash() } }
                )
            ) {
                Button(AppLanguage.localized("取消", english: "Cancel"), role: .cancel) {
                    appModel.cancelBatchTrash()
                }
                Button(
                    AppLanguage.localized("移到废纸篓", english: "Move to Trash"),
                    role: .destructive
                ) {
                    appModel.confirmBatchTrash()
                }
            } message: {
                Text(
                    AppLanguage.localized(
                        "\(appModel.batchTrashRequest?.count ?? 0) 个文件将被移到系统废纸篓，可以从废纸篓恢复。",
                        english: "\(appModel.batchTrashRequest?.count ?? 0) files will be moved to the system Trash and can be restored from there."
                    )
                )
            }
    }

    private func prepareCommandTargets(for destination: NavigationDestination?) {
        switch destination ?? .home {
        case .home:
            appModel.updateCommandTargetFiles(appModel.recentFiles)
        case .allFiles, .categories, .category, .settings:
            // Each destination publishes its own exact visible rows once its
            // async filtering is complete. Clear the previous page now.
            appModel.updateCommandTargetFiles([])
        }
    }


    static func workspaceMode(for destination: NavigationDestination) -> NavigationDestination {
        switch destination {
        case .category: .categories
        case .settings: .settings
        default: destination
        }
    }


    private var statusBanners: some View {
        VStack(spacing: 0) {
            ScanStatusBanner(store: appModel.scanProgressStore,
                             pausesInsteadOfCancels: appModel.scanScopeMode == .wholeMac) {
                if appModel.scanScopeMode == .wholeMac { appModel.pauseWholeMacScan() }
                else { appModel.cancelScan() }
            }
            FileExportProgressBanner(store: appModel.fileExportProgressStore,
                                     onCancel: appModel.cancelFileListExport)
            TrashUndoBanner(store: appModel.index.trashUndoStore,
                            onUndo: { appModel.undoLastTrash() },
                            onDismiss: { appModel.dismissTrashUndoBanner() })
            DatabaseUnavailableBanner(state: appModel.databaseState,
                                      onRetry: { Task { await appModel.retryDatabase() } })
        }
    }

    private var commandContext: XunJianCommandContext {
        let destination = selection ?? .home
        let isFilePage = Self.supportsFileCommands(for: destination)
        let selectedFile = isFilePage ? appModel.selectedFile : nil
        let availability = XunJianCommandAvailability.resolve(
            destination: destination,
            databaseAvailable: appModel.isDatabaseAvailable,
            hasSelectedFile: selectedFile != nil,
            selectedFileSupportsText: selectedFile.map { appModel.supportsTextContent($0) } ?? false,
            selectedFileCount: isFilePage ? appModel.selectedFileIDs.count : 0,
            hasCommandTargets: isFilePage && !appModel.commandTargetFiles.isEmpty,
            canToggleInspector: canToggleInspector,
            isExporting: appModel.isExportingFileList
        )
        return XunJianCommandContext(
            availability: availability,
            createCategory: { showsGlobalNewCategory = true },
            addFolder: { appModel.chooseFolder() },
            openSelected: { selectedFile.map(appModel.open) },
            quickLookSelected: { selectedFile.map(appModel.quickLook) },
            showSelectedInFinder: { selectedFile.map(appModel.showInFinder) },
            renameSelected: { selectedFile.map(appModel.requestRename) },
            moveSelected: { selectedFile.map(appModel.chooseMoveDestination) },
            trashSelection: {
                guard let selectedFile else { return }
                if appModel.selectedFileIDs.count > 1 {
                    appModel.requestBatchTrash()
                } else {
                    appModel.requestTrash(selectedFile)
                }
            },
            copySelectedPath: { selectedFile.map(appModel.copyPath) },
            selectAll: appModel.selectAllDisplayedFiles,
            deselectAll: { appModel.selectedFileIDs = [] },
            focusSearch: focusSearch,
            setBrowseViewMode: setBrowseViewMode,
            toggleInspector: { setInspectorVisible(!showsInspector) },
            showCommandPalette: {
                NotificationCenter.default.post(name: .xunJianShowCommandPalette, object: nil)
            },
            previewSelectedText: {
                NotificationCenter.default.post(name: .xunJianShowTextPreview, object: nil)
            },
            showStorageInsights: {
                NotificationCenter.default.post(name: .xunJianShowStorageInsights, object: nil)
            },
            exportFileList: { format in
                NotificationCenter.default.post(
                    name: .xunJianExportFileList,
                    object: format.rawValue
                )
            }
        )
    }

    static func supportsFileCommands(for destination: NavigationDestination) -> Bool {
        switch destination {
        case .allFiles, .category:
            return true
        case .home, .categories, .settings:
            return false
        }
    }

    static func searchCommandRoute(
        for destination: NavigationDestination
    ) -> AppShellSearchCommandRoute {
        switch destination {
        case .home, .allFiles, .category, .categories:
            return .focusVisibleField
        case .settings:
            return .revealAllFilesThenFocus
        }
    }

    static func searchFieldScope(
        for destination: NavigationDestination
    ) -> XunJianSearchFieldScope? {
        switch destination {
        case .home:
            return .home
        case .allFiles:
            return .allFiles
        case .category:
            return .category
        case .categories:
            return .collections
        case .settings:
            return nil
        }
    }

    static func browseModeCommandRoute(
        for destination: NavigationDestination
    ) -> AppShellBrowseModeCommandRoute {
        supportsFileCommands(for: destination) ? .visibleFilePage : .revealAllFiles
    }

    private func focusSearch() {
        let destination = selection ?? .home
        switch Self.searchCommandRoute(for: destination) {
        case .focusVisibleField:
            guard let scope = Self.searchFieldScope(for: destination) else { return }
            NotificationCenter.default.post(
                name: .xunJianFocusSearchField,
                object: scope.rawValue
            )
        case .revealAllFilesThenFocus:
            selection = .allFiles
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                guard selection == .allFiles else { return }
                NotificationCenter.default.post(
                    name: .xunJianFocusSearchField,
                    object: XunJianSearchFieldScope.allFiles.rawValue
                )
            }
        }
    }

    private func setBrowseViewMode(_ mode: FileBrowseViewMode) {
        switch Self.browseModeCommandRoute(for: selection ?? .home) {
        case .visibleFilePage:
            NotificationCenter.default.post(
                name: .xunJianSetBrowseViewMode,
                object: mode.rawValue
            )
        case .revealAllFiles:
            selection = .allFiles
            Task { @MainActor in
                NotificationCenter.default.post(
                    name: .xunJianSetBrowseViewMode,
                    object: mode.rawValue
                )
            }
        }
    }

    private func handleBrowseViewModeNotification(_ mode: FileBrowseViewMode) {
        guard Self.browseModeCommandRoute(for: selection ?? .home) == .revealAllFiles else {
            // The visible file page already received this notification.
            return
        }
        selection = .allFiles
        Task { @MainActor in
            NotificationCenter.default.post(
                name: .xunJianSetBrowseViewMode,
                object: mode.rawValue
            )
        }
    }

    private func setInspectorVisible(_ isVisible: Bool) {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            responsiveLayout.setInspectorVisible(isVisible)
        }
    }

    private var presentsErrorAlert: Binding<Bool> {
        Binding(
            get: { controlActiveState == .key && appModel.errorMessage != nil },
            set: { if !$0 { appModel.clearError() } }
        )
    }

    private var supportsInspector: Bool {
        Self.supportsInspector(
            for: selection ?? .home,
            windowWidth: windowWidth
        )
    }

    private var canToggleInspector: Bool {
        supportsInspector
    }

    private var inspectorWidthLimit: CGFloat {
        max(280, min(1_040, windowWidth - (showsNavigationSidebar ? 260 : 0) - 440))
    }

    private var workspaceInspector: WorkspaceInspectorModifier {
        WorkspaceInspectorModifier(isPresented: Binding(
            get: { showsInspector }, set: { setInspectorVisible($0) }
        ), maximumWidth: inspectorWidthLimit)
    }

    private var isInspectorDestination: Bool {
        switch selection ?? .home {
        case .allFiles, .category: true
        case .home, .categories, .settings: false
        }
    }

    @ToolbarContentBuilder
    private var navigationToolbar: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(id: "workspace.destinations", placement: .principal) {
                EditorialNavigationTabs(selection: $selection)
            }.sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(id: "workspace.destinations", placement: .principal) {
                EditorialNavigationTabs(selection: $selection)
            }
        }
    }

    @ToolbarContentBuilder
    private var inspectorToolbar: some ToolbarContent {
        ToolbarItem(id: "workspace.inspector", placement: .primaryAction) {
            if isInspectorDestination {
                Button { setInspectorVisible(!showsInspector) } label: {
                    Label(inspectorToggleTitle, systemImage: "sidebar.right")
                }
                .disabled(!canToggleInspector)
                .help(inspectorToggleTitle + (canToggleInspector ? " (⌥⌘I)" : ""))
                .accessibilityIdentifier("workspace.inspector.toggle")
                .accessibilityValue(showsInspector
                    ? AppLanguage.localized("已展开", english: "Expanded")
                    : AppLanguage.localized("已收起", english: "Collapsed"))
            }
        }
    }

    private var inspectorToggleTitle: String {
        if !canToggleInspector {
            return AppLanguage.localized("窗口加宽至720点后可显示预览", english: "Widen the window to 720 points to show preview")
        }
        return showsInspector
            ? AppLanguage.localized("隐藏文件预览", english: "Hide File Preview")
            : AppLanguage.localized("显示文件预览", english: "Show File Preview")
    }

    private var showsInspector: Bool {
        supportsInspector && responsiveLayout.showsInspector
    }

    static func supportsInspector(
        for destination: NavigationDestination,
        windowWidth: CGFloat
    ) -> Bool {
        guard windowWidth >= minimumInspectorWindowWidth else { return false }
        switch destination {
        case .allFiles, .category:
            return true
        case .home, .categories, .settings:
            return false
        }
    }

    static func selectionAfterCategoryReload(
        _ selection: NavigationDestination?,
        availableCategoryIDs: Set<UUID>
    ) -> NavigationDestination? {
        guard case let .category(categoryID) = selection,
              !availableCategoryIDs.contains(categoryID) else {
            return selection
        }
        return .categories
    }

    private func updateResponsiveLayout(for newWidth: CGFloat) {
        guard newWidth > 0 else { return }
        windowWidth = newWidth
        responsiveLayout.update(windowWidth: newWidth)
    }

    @ViewBuilder
    private func selectedContent(contentWidth: CGFloat) -> some View {
        let current = selection ?? .home
        let showsAllFiles = current == .allFiles
        ZStack {
            // Keep the file list mounted. Recreating the table on every
            // sidebar click was the remaining page-switch hitch after the
            // global selection animation was removed.
            AllFilesView(
                windowWidth: windowWidth,
                contentWidth: contentWidth,
                isVisible: showsAllFiles,
                statusContent: AnyView(statusBanners),
                workspaceInspector: workspaceInspector
            )
                .environmentObject(appModel.searchProgressStore)
                .disabled(!showsAllFiles || !appModel.isDatabaseAvailable)
                .opacity(showsAllFiles ? 1 : 0)
                .allowsHitTesting(showsAllFiles)
                .accessibilityHidden(!showsAllFiles)
                .zIndex(showsAllFiles ? 1 : 0)
                // Inspector open/close animates the detail width. The file
                // list must keep its Table/Grid identity instead of
                // interpolating a different container tree.
                .transaction(value: showsInspector) { transaction in
                    transaction.animation = nil
                }

            if !showsAllFiles {
                overlayContent(current, contentWidth: contentWidth)
                    .zIndex(2)
            }
        }
        .navigationTitle(AppLanguage.localized("寻简", english: "XunJian"))
    }

    @ViewBuilder
    private func overlayContent(
        _ current: NavigationDestination,
        contentWidth: CGFloat
    ) -> some View {
        switch current {
        case .home:
            HomeView(
                openAllFiles: { kind in
                    appModel.clearAISearch()
                    appModel.searchText = ""
                    appModel.filterMinSizeMB = 0
                    appModel.filterMinDate = 0
                    appModel.selectedKind = kind
                    selection = .allFiles
                },
                searchAllFiles: { query in
                    appModel.searchAllFiles(query: query)
                }
            )
            .disabled(!appModel.isDatabaseAvailable)
        case .allFiles:
            EmptyView()
        case .categories:
            CategoriesView(selectedCategory: nil, browseContext: collectionBrowseContext) { category in
                selection = .category(category.id)
            }
            .disabled(!appModel.isDatabaseAvailable)
        case let .category(categoryID):
            CategoriesView(
                selectedCategory: appModel.categories.first(where: { $0.id == categoryID }),
                browseContext: collectionBrowseContext,
                openCategory: { category in selection = .category(category.id) },
                showAllCategories: { selection = .categories },
                statusContent: AnyView(statusBanners)
            )
            .modifier(workspaceInspector)
            .disabled(!appModel.isDatabaseAvailable)
        case .settings:
            SettingsView(presentsErrors: true, selectedPage: $settingsPage)
                .environmentObject(aiProviderSettingsDraftStore)
        }
    }
}

private struct FileWorkspaceDefaultToolbarItems: ViewModifier {
    let isFileWorkspace: Bool
    var isSettings = false

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content
                .toolbar(removing: isFileWorkspace ? .title : nil)
                .toolbar(removing: isSettings ? .sidebarToggle : nil)
        } else {
            content
        }
    }
}

private struct FileExportProgressBanner: View {
    @ObservedObject var store: FileExportProgressStore
    let onCancel: () -> Void

    var body: some View {
        if let progress = store.progress {
            HStack(spacing: 10) {
                ProgressView(
                    value: Double(progress.completed),
                    total: Double(max(progress.total, 1))
                )
                    .frame(maxWidth: 180)
                Text(verbatim: AppLanguage.localized(
                    "正在导出 \(progress.completed)/\(progress.total)",
                    english: "Exporting \(progress.completed)/\(progress.total)"
                ))
                    .font(.caption)
                    .monospacedDigit()
                Spacer(minLength: 8)
                Button(AppLanguage.localized("取消", english: "Cancel"), action: onCancel)
                    .controlSize(.small)
            }
            .padding(.horizontal, XunJianUI.Spacing.page)
            .padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .bottom) {
                WorkspaceRowSeparator()
            }
        }
    }
}

extension Notification.Name {
    static let xunJianRequestNewCategory = Notification.Name(
        "com.xunjian.request-new-category"
    )
    static let xunJianOpenSettings = Notification.Name(
        "com.xunjian.open-settings"
    )
}

private struct RenameFileSheet: View {
    let file: IndexedFile
    let submit: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var isSaving = false
    @State private var failure: String?
    @FocusState private var isNameFocused: Bool

    init(file: IndexedFile, submit: @escaping (String) async throws -> Void) {
        self.file = file
        self.submit = submit
        _name = State(initialValue: file.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(AppLanguage.localized("重命名文件", english: "Rename File"))
                .font(XunJianUI.Typography.sheetTitle)
            Text(verbatim: file.parentPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            TextField(
                AppLanguage.localized("文件名", english: "File Name"),
                text: $name
            )
                .textFieldStyle(.roundedBorder)
                .focused($isNameFocused)
                .onSubmit(rename)
            if let failure {
                ErrorMessageRow(message: failure)
            }
            HStack {
                Spacer()
                Button(AppLanguage.localized("取消", english: "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button(AppLanguage.localized("重命名", english: "Rename"), action: rename)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .disabled(isSaving)
            }
        }
        .padding(24)
        .frame(minWidth: 280, idealWidth: 420, maxWidth: 520, alignment: .leading)
        .onAppear { isNameFocused = true }
        .interactiveDismissDisabled(isSaving)
    }

    private func rename() {
        guard !isSaving else { return }
        isSaving = true
        failure = nil
        Task {
            do {
                try await submit(name)
                dismiss()
            } catch {
                failure = error.localizedDescription
                isSaving = false
            }
        }
    }
}

private struct ScanStatusBanner: View {
    @ObservedObject var store: ScanProgressStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let cancel: () -> Void
    let pausesInsteadOfCancels: Bool

    init(
        store: ScanProgressStore,
        pausesInsteadOfCancels: Bool,
        cancel: @escaping () -> Void
    ) {
        self.store = store
        self.pausesInsteadOfCancels = pausesInsteadOfCancels
        self.cancel = cancel
    }

    var body: some View {
        Group {
            if let progress = store.progress {
                ScanStatusView(
                    progress: progress,
                    pausesInsteadOfCancels: pausesInsteadOfCancels,
                    cancel: cancel
                )
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(XunJianUI.motion(reduceMotion: reduceMotion), value: store.isActive)
    }
}

private struct TrashUndoBanner: View {
    @ObservedObject var store: TrashUndoStore
    let onUndo: () -> Void
    let onDismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let undo = store.undo
        Group {
            if let undo {
                HStack(spacing: 8) {
                    Label(
                        undo.fileCount == 1
                            ? AppLanguage.localized(
                                "“\(undo.items[0].originalURL.lastPathComponent)”已移到废纸篓。",
                                english: "“\(undo.items[0].originalURL.lastPathComponent)” was moved to the Trash."
                            )
                            : AppLanguage.localized(
                                "\(undo.fileCount) 个文件已移到废纸篓。",
                                english: "\(undo.fileCount) files were moved to the Trash."
                            ),
                        systemImage: "arrow.uturn.backward.circle"
                    )
                    Spacer(minLength: 8)
                    Button(AppLanguage.localized("撤销", english: "Undo"), action: onUndo)
                        .controlSize(.small)
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(AppLanguage.localized("关闭", english: "Dismiss"))
                }
                .font(.caption)
                .padding(.horizontal, XunJianUI.Spacing.page)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
                .overlay(alignment: .bottom) {
                    WorkspaceRowSeparator()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(XunJianUI.motion(reduceMotion: reduceMotion), value: undo != nil)
        .task(id: undo) {
            guard undo != nil else { return }
            // Long enough to read a multi-file summary; a new undo replaces
            // the old one and restarts this window via `id`.
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }
            onDismiss()
        }
    }
}

private struct DatabaseUnavailableBanner: View {
    let state: FileIndexDatabaseState
    let onRetry: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if state == .opening {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(verbatim: AppLanguage.localized(
                        "正在打开本地索引…",
                        english: "Opening the local index…"
                    ))
                    Spacer(minLength: 8)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, XunJianUI.Spacing.page)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
                .overlay(alignment: .bottom) { WorkspaceRowSeparator() }
                .transition(.move(edge: .top).combined(with: .opacity))
            } else if state.showsFailure {
                HStack(spacing: 8) {
                    Label(
                        AppLanguage.localized(
                            "本地索引不可用，文件操作已暂停。",
                            english: "The local index is unavailable. File actions are paused."
                        ),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    Spacer(minLength: 8)
                    Button(AppLanguage.localized("重试", english: "Retry"), action: onRetry)
                        .controlSize(.small)
                }
                .font(.caption)
                .foregroundStyle(XunJianUI.Semantic.warning)
                .padding(.horizontal, XunJianUI.Spacing.page)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
                .overlay(alignment: .bottom) {
                    WorkspaceRowSeparator()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(XunJianUI.motion(reduceMotion: reduceMotion), value: state)
    }
}

private struct ScanStatusView: View {
    let progress: ScanProgress
    let pausesInsteadOfCancels: Bool
    let cancel: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                progressIdentity
                Spacer(minLength: 8)
                cancelButton
            }

            VStack(alignment: .leading, spacing: 6) {
                progressIdentity
                cancelButton
            }
        }
        .padding(.horizontal, XunJianUI.Spacing.page)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) {
            WorkspaceRowSeparator()
        }
    }

    private var progressIdentity: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    AppLanguage.localized(
                        progress.sourceCount > 1
                            ? "正在建立文件索引（\(progress.sourceIndex)/\(progress.sourceCount)）… 本轮已扫描 \(AppLanguage.fileCount(progress.discoveredCount))"
                            : "正在建立文件索引… 本轮已扫描 \(AppLanguage.fileCount(progress.discoveredCount))",
                        english: progress.sourceCount > 1
                            ? "Building file index (\(progress.sourceIndex)/\(progress.sourceCount))… Scanned \(AppLanguage.fileCount(progress.discoveredCount)) this pass"
                            : "Building file index… Scanned \(AppLanguage.fileCount(progress.discoveredCount)) this pass"
                    )
                )
                .font(.caption.weight(.medium))
                Text(verbatim: progress.currentPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var cancelButton: some View {
        Button(
            pausesInsteadOfCancels
                ? AppLanguage.localized("暂停", english: "Pause")
                : AppLanguage.localized("取消", english: "Cancel"),
            action: cancel
        )
            .controlSize(.small)
            .buttonStyle(.bordered)
    }
}
