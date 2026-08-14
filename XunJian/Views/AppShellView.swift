import SwiftUI

struct AppShellView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection: NavigationDestination? = .home
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var showsInspector = false
    @State private var windowWidth: CGFloat = 1_200
    @State private var hasMeasuredWindow = false
    @State private var sidebarWasAutoCollapsed = false
    @State private var inspectorWasAutoCollapsed = false
    @State private var showsGlobalNewCategory = false

    var body: some View {
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
        let navigation = NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                selection: $selection,
                categories: appModel.categories.map(\.localizedForDisplay)
            )
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 260)
        } detail: {
            GeometryReader { detailGeometry in
                VStack(spacing: 0) {
                    if selection == .allFiles {
                        SearchField(text: $appModel.searchText)
                            .padding(.horizontal, XunJianUI.Spacing.page)
                            .padding(.top, 12)
                            .padding(.bottom, 10)
                    }

                    ScanStatusBanner(store: appModel.scanProgressStore) {
                        appModel.cancelScan()
                    }

                    TrashUndoBanner(
                        undo: appModel.lastTrashUndo,
                        onUndo: { appModel.undoLastTrash() }
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
            if supportsInspector {
                FileInspectorView(file: appModel.selectedFile)
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 360)
                    .environment(\.locale, locale)
                    .disabled(!appModel.isDatabaseAvailable)
                    // Separates the inspector from the content area with depth
                    // rather than relying on a hairline divider alone.
                    .background(.regularMaterial)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(XunJianUI.motion(reduceMotion: reduceMotion)) {
                        showsInspector.toggle()
                    }
                    inspectorWasAutoCollapsed = false
                } label: {
                    Label(
                        AppLanguage.localized("文件详情", english: "File Details"),
                        systemImage: "sidebar.right"
                    )
                }
                .disabled(!supportsInspector)
                .help(
                    AppLanguage.localized(
                        showsInspector ? "隐藏文件详情" : "显示文件详情",
                        english: showsInspector ? "Hide File Details" : "Show File Details"
                    )
                )
            }
        }
        return navigation
            .onReceive(NotificationCenter.default.publisher(for: .xunJianFocusSearch)) { _ in
                selection = .allFiles
                Task { @MainActor in
                    NotificationCenter.default.post(name: .xunJianFocusSearchField, object: nil)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .xunJianToggleInspector)) { _ in
                guard supportsInspector else { return }
                withAnimation(XunJianUI.motion(reduceMotion: reduceMotion)) {
                    showsInspector.toggle()
                }
                inspectorWasAutoCollapsed = false
            }
            .onChange(of: columnVisibility) { oldValue, newValue in
                handleColumnVisibilityChange(oldValue, newValue)
            }
            .onChange(of: showsInspector) { oldValue, newValue in
                handleInspectorVisibilityChange(oldValue, newValue)
            }
            .onChange(of: appModel.categories.map(\.id)) { oldIDs, newIDs in
                handleCategoryIDsChange(oldIDs, newIDs)
            }
            .onReceive(NotificationCenter.default.publisher(for: .xunJianRequestNewCategory)) { _ in
                showsGlobalNewCategory = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .xunJianOpenExternalPath)) { notification in
                guard let path = notification.object as? String else { return }
                selection = .allFiles
                appModel.handleExternalPath(path)
            }
            .modifier(GlobalPresentations(selection: $selection))
            .alert(
                AppLanguage.localized("操作未完成", english: "Action Couldn’t Finish"),
                isPresented: Binding(
                    get: { appModel.errorMessage != nil },
                    set: { if !$0 { appModel.clearError() } }
                )
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
                .background(.ultraThinMaterial)
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

    private func handleColumnVisibilityChange(
        _ oldValue: NavigationSplitViewVisibility,
        _ newValue: NavigationSplitViewVisibility
    ) {
        let isAutomaticCollapse = windowWidth < XunJianUI.Breakpoint.sidebarAutoCollapse
            && newValue == .detailOnly
            && sidebarWasAutoCollapsed
        if !isAutomaticCollapse { sidebarWasAutoCollapsed = false }
    }

    private func handleInspectorVisibilityChange(_ oldValue: Bool, _ isPresented: Bool) {
        let isAutomaticCollapse = windowWidth < XunJianUI.Breakpoint.inspectorAutoCollapse
            && !isPresented
            && inspectorWasAutoCollapsed
        if !isAutomaticCollapse { inspectorWasAutoCollapsed = false }
    }

    private func handleCategoryIDsChange(_ oldIDs: [UUID], _ categoryIDs: [UUID]) {
        selection = Self.selectionAfterCategoryReload(
            selection,
            availableCategoryIDs: Set(categoryIDs)
        )
    }

    private var supportsInspector: Bool {
        switch selection ?? .home {
        case .allFiles, .category:
            true
        case .home, .categories, .settings:
            false
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
            get: { supportsInspector && showsInspector },
            set: { if supportsInspector { showsInspector = $0 } }
        )
    }

    private func updateResponsiveLayout(for newWidth: CGFloat) {
        guard newWidth > 0 else { return }

        guard hasMeasuredWindow else {
            windowWidth = newWidth
            hasMeasuredWindow = true
            return
        }

        let previousWidth = windowWidth
        windowWidth = newWidth

        let animation = XunJianUI.motion(reduceMotion: reduceMotion)

        if previousWidth >= XunJianUI.Breakpoint.inspectorAutoCollapse,
           newWidth < XunJianUI.Breakpoint.inspectorAutoCollapse,
           showsInspector {
            withAnimation(animation) { showsInspector = false }
            inspectorWasAutoCollapsed = true
        } else if previousWidth <= XunJianUI.Breakpoint.inspectorRestore,
                  newWidth > XunJianUI.Breakpoint.inspectorRestore,
                  inspectorWasAutoCollapsed {
            withAnimation(animation) { showsInspector = true }
            inspectorWasAutoCollapsed = false
        }

        if previousWidth >= XunJianUI.Breakpoint.sidebarAutoCollapse,
           newWidth < XunJianUI.Breakpoint.sidebarAutoCollapse,
           columnVisibility != .detailOnly {
            withAnimation(animation) { columnVisibility = .detailOnly }
            sidebarWasAutoCollapsed = true
        } else if previousWidth <= XunJianUI.Breakpoint.sidebarRestore,
                  newWidth > XunJianUI.Breakpoint.sidebarRestore,
                  sidebarWasAutoCollapsed {
            withAnimation(animation) { columnVisibility = .all }
            sidebarWasAutoCollapsed = false
        }
    }

    @ViewBuilder
    private func selectedContent(contentWidth: CGFloat) -> some View {
        let current = selection ?? .home
        let showsAllFiles = current == .allFiles
        ZStack {
            // Keep the file list mounted. Recreating the table on every
            // sidebar click was the remaining page-switch hitch after the
            // global selection animation was removed.
            AllFilesView(windowWidth: windowWidth, contentWidth: contentWidth)
                .disabled(!showsAllFiles || !appModel.isDatabaseAvailable)
                .opacity(showsAllFiles ? 1 : 0)
                .allowsHitTesting(showsAllFiles)
                .accessibilityHidden(!showsAllFiles)
                .zIndex(showsAllFiles ? 1 : 0)

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
            HomeView { kind in
                appModel.selectedKind = kind
                selection = .allFiles
            }
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
            SettingsView()
        }
    }
}

extension Notification.Name {
    static let xunJianRequestNewCategory = Notification.Name(
        "com.xunjian.request-new-category"
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
                .font(.title2.weight(.semibold))
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
                Text(AppLanguage.localizedRuntimeMessage(failure))
                    .font(.caption)
                    .foregroundStyle(XunJianUI.Semantic.danger)
            }
            HStack {
                Spacer()
                Button(AppLanguage.localized("取消", english: "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(AppLanguage.localized("重命名", english: "Rename"), action: rename)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .disabled(isSaving)
            }
        }
        .padding(24)
        .frame(minWidth: 280, idealWidth: 420, maxWidth: 520, alignment: .leading)
        .onAppear { isNameFocused = true }
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

    var body: some View {
        Group {
            if let progress = store.progress {
                ScanStatusView(progress: progress, cancel: cancel)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(XunJianUI.motion(reduceMotion: reduceMotion), value: store.isActive)
    }
}

private struct TrashUndoBanner: View {
    let undo: FileIndexCoordinator.TrashUndo?
    let onUndo: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let undo {
                HStack(spacing: 8) {
                    Label(
                        AppLanguage.localized(
                            "“\(undo.originalURL.lastPathComponent)”已移到废纸篓。",
                            english: "“\(undo.originalURL.lastPathComponent)” was moved to the Trash."
                        ),
                        systemImage: "arrow.uturn.backward.circle"
                    )
                    Spacer(minLength: 8)
                    Button(AppLanguage.localized("撤销", english: "Undo"), action: onUndo)
                        .controlSize(.small)
                }
                .font(.caption)
                .padding(.horizontal, XunJianUI.Spacing.page)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(XunJianUI.Fill.accentWash)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(XunJianUI.motion(reduceMotion: reduceMotion), value: undo != nil)
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
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(XunJianUI.motion(reduceMotion: reduceMotion), value: isAvailable)
    }
}

private struct ScanStatusView: View {
    let progress: ScanProgress
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
        .background(XunJianUI.Fill.accentWash)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.5)
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
                        "正在建立文件索引… 已发现 \(AppLanguage.fileCount(progress.discoveredCount))",
                        english: "Building file index… Found \(AppLanguage.fileCount(progress.discoveredCount))"
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
        Button(AppLanguage.localized("取消", english: "Cancel"), action: cancel)
            .controlSize(.small)
            .buttonStyle(.bordered)
    }
}
