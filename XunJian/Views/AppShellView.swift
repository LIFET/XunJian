import SwiftUI

struct AppShellResponsiveLayoutState: Equatable {
    private(set) var prefersSidebarVisible = true
    private(set) var prefersInspectorVisible = false
    private(set) var isSidebarForcedCollapsed = false
    private(set) var isInspectorForcedCollapsed = false
    /// A deliberate open at a compact width stays authoritative. Without
    /// this, the next layout measurement immediately re-applies the automatic
    /// collapse and makes the Inspector button appear broken.
    private(set) var isInspectorManuallyPresentedAtCompactWidth = false

    var showsSidebar: Bool {
        prefersSidebarVisible && !isSidebarForcedCollapsed
    }

    var showsInspector: Bool {
        prefersInspectorVisible && !isInspectorForcedCollapsed
    }

    mutating func update(windowWidth: CGFloat) {
        guard windowWidth > 0 else { return }

        if isSidebarForcedCollapsed {
            if windowWidth > XunJianUI.Breakpoint.sidebarRestore {
                isSidebarForcedCollapsed = false
            }
        } else if windowWidth < XunJianUI.Breakpoint.sidebarAutoCollapse {
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
        guard !isSidebarForcedCollapsed else { return }
        prefersSidebarVisible = isVisible
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
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var selection: NavigationDestination? = .home
    @State private var responsiveLayout = AppShellResponsiveLayoutState()
    @State private var windowWidth: CGFloat = 1_200
    @State private var showsGlobalNewCategory = false

    var body: some View {
        let _ = (locale.identifier, appModel.localeRevision)
        GeometryReader { geometry in
            appContent
                .onAppear {
                    updateResponsiveLayout(for: geometry.size.width)
                }
                .onChange(of: geometry.size.width) { _, newWidth in
                    updateResponsiveLayout(for: newWidth)
                }
        }
    }

    private var appContent: some View {
        let navigation = NavigationSplitView(columnVisibility: columnVisibility) {
            SidebarView(
                selection: $selection,
                categories: appModel.categories.map(\.localizedForDisplay)
            )
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 260)
        } detail: {
            GeometryReader { detailGeometry in
                VStack(spacing: 0) {
                    if selection == .allFiles {
                        BrowseSearchField(
                            store: appModel.browseSearchStore,
                            appModel: appModel
                        )
                            .padding(.horizontal, XunJianUI.Spacing.page)
                            .padding(.top, 12)
                            .padding(.bottom, 10)
                    }

                    ScanStatusBanner(
                        store: appModel.scanProgressStore,
                        pausesInsteadOfCancels: appModel.scanScopeMode == .wholeMac
                    ) {
                        if appModel.scanScopeMode == .wholeMac {
                            appModel.pauseWholeMacScan()
                        } else {
                            appModel.cancelScan()
                        }
                    }

                    FileExportProgressBanner(
                        store: appModel.fileExportProgressStore,
                        onCancel: appModel.cancelFileListExport
                    )

                    TrashUndoBanner(
                        store: appModel.index.trashUndoStore,
                        onUndo: { appModel.undoLastTrash() },
                        onDismiss: { appModel.dismissTrashUndoBanner() }
                    )

                    DatabaseUnavailableBanner(
                        isAvailable: appModel.isDatabaseAvailable,
                        onRetry: { Task { await appModel.retryDatabase() } }
                    )

                    Divider()
                        .opacity(0.7)

                    selectedContent(contentWidth: detailGeometry.size.width)
                }
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .inspector(isPresented: inspectorPresentation) {
            FileInspectorView(file: appModel.selectedFile)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 360)
                .environment(\.locale, locale)
                .disabled(!appModel.isDatabaseAvailable || !supportsInspector)
                .background(Color(nsColor: .controlBackgroundColor))
        }
        .toolbar {
            if supportsInspector {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        setInspectorVisible(!showsInspector)
                    } label: {
                        Label(
                            AppLanguage.localized("文件详情", english: "File Details"),
                            systemImage: "sidebar.right"
                        )
                        .symbolVariant(showsInspector ? .fill : .none)
                    }
                    .accessibilityValue(
                        AppLanguage.localized(
                            showsInspector ? "已显示" : "已隐藏",
                            english: showsInspector ? "Shown" : "Hidden"
                        )
                    )
                    .accessibilityAddTraits(showsInspector ? .isSelected : [])
                    .help(
                        AppLanguage.localized(
                            showsInspector ? "隐藏文件详情" : "显示文件详情",
                            english: showsInspector ? "Hide File Details" : "Show File Details"
                        )
                    )
                }
            }
        }
        .focusedSceneValue(\.xunJianCommandContext, commandContext)
        return navigation
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
            .modifier(GlobalPresentations(selection: $selection))
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

    private var commandContext: XunJianCommandContext {
        let destination = selection ?? .home
        let isFilePage = Self.supportsFileCommands(for: destination)
        let selectedFile = isFilePage ? appModel.selectedFile : nil
        let availability = XunJianCommandAvailability.resolve(
            destination: destination,
            databaseAvailable: appModel.isDatabaseAvailable,
            hasSelectedFile: selectedFile != nil,
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
        case .home, .allFiles, .category:
            return .focusVisibleField
        case .categories, .settings:
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
        case .categories, .settings:
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

    private var showsInspector: Bool {
        supportsInspector && responsiveLayout.showsInspector
    }

    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { responsiveLayout.showsSidebar ? .all : .detailOnly },
            set: { visibility in
                responsiveLayout.setSidebarVisible(visibility != .detailOnly)
            }
        )
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

    private var inspectorPresentation: Binding<Bool> {
        Binding(
            get: { showsInspector },
            set: { isPresented in
                guard supportsInspector else { return }
                setInspectorVisible(isPresented)
            }
        )
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
                isVisible: showsAllFiles
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
        .navigationTitle(current.title(categories: appModel.categories))
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
            CategoriesView(selectedCategory: nil) { category in
                selection = .category(category.id)
            }
            .disabled(!appModel.isDatabaseAvailable)
        case let .category(categoryID):
            CategoriesView(
                selectedCategory: appModel.categories.first(where: { $0.id == categoryID }),
                openCategory: { category in selection = .category(category.id) },
                showAllCategories: { selection = .categories }
            )
            .disabled(!appModel.isDatabaseAvailable)
        case .settings:
            SettingsView(presentsErrors: true)
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
                Divider()
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
                    Divider()
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
    let isAvailable: Bool
    let onRetry: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if !isAvailable {
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
                    Divider()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(XunJianUI.motion(reduceMotion: reduceMotion), value: isAvailable)
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
            Divider()
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
                            ? "正在建立文件索引（\(progress.sourceIndex)/\(progress.sourceCount)）… 已发现 \(AppLanguage.fileCount(progress.discoveredCount))"
                            : "正在建立文件索引… 已发现 \(AppLanguage.fileCount(progress.discoveredCount))",
                        english: progress.sourceCount > 1
                            ? "Building file index (\(progress.sourceIndex)/\(progress.sourceCount))… Found \(AppLanguage.fileCount(progress.discoveredCount))"
                            : "Building file index… Found \(AppLanguage.fileCount(progress.discoveredCount))"
                    )
                )
                .font(.caption.weight(.medium))
                Text(verbatim: progress.currentPath)
                    .font(.caption2)
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
