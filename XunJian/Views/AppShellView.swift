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

                    if appModel.isScanning, let progress = appModel.scanProgress {
                        ScanStatusView(progress: progress) {
                            appModel.cancelScan()
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if !appModel.isDatabaseAvailable {
                        HStack(spacing: 8) {
                            Label(
                                AppLanguage.localized(
                                    "本地索引不可用，文件操作已暂停。",
                                    english: "The local index is unavailable. File actions are paused."
                                ),
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            Spacer(minLength: 8)
                            Button(AppLanguage.localized("重试", english: "Retry")) {
                                Task { await appModel.retryDatabase() }
                            }
                            .controlSize(.small)
                        }
                        .font(.caption)
                        .foregroundStyle(XunJianUI.Semantic.warning)
                        .padding(.horizontal, XunJianUI.Spacing.page)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    Divider()
                        .opacity(0.7)

                    selectedContent(contentWidth: detailGeometry.size.width)
                }
                .xunjianAnimation(value: appModel.isScanning)
                .xunjianAnimation(value: appModel.isDatabaseAvailable)
                .xunjianAnimation(value: selection)
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
                    Label("文件详情", systemImage: "sidebar.right")
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
            .alert(
                "操作未完成",
                isPresented: Binding(
                    get: { appModel.errorMessage != nil },
                    set: { if !$0 { appModel.clearError() } }
                )
            ) {
                Button("好") { appModel.clearError() }
            } message: {
                Text(AppLanguage.localizedRuntimeMessage(appModel.errorMessage ?? ""))
            }
            .sheet(item: $appModel.renameRequest) { file in
                RenameFileSheet(file: file) { newName in
                    try await appModel.rename(file, to: newName)
                }
                .environment(\.locale, locale)
            }
            .sheet(isPresented: $showsGlobalNewCategory) {
                CategoryEditorSheet(title: "新建分类") { name, symbolName in
                    try await appModel.createCategory(name: name, symbolName: symbolName)
                }
                .environment(\.locale, locale)
            }
            .alert(
                "移到废纸篓？",
                isPresented: Binding(
                    get: { appModel.trashRequest != nil },
                    set: { if !$0 { appModel.trashRequest = nil } }
                )
            ) {
                Button("取消", role: .cancel) {
                    appModel.trashRequest = nil
                }
                Button("移到废纸篓", role: .destructive) {
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
        switch selection ?? .home {
        case .home:
            HomeView { kind in
                appModel.selectedKind = kind
                selection = .allFiles
            }
            .disabled(!appModel.isDatabaseAvailable)
        case .allFiles:
            AllFilesView(windowWidth: windowWidth, contentWidth: contentWidth)
                .disabled(!appModel.isDatabaseAvailable)
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
            Text("重命名文件")
                .font(.title2.weight(.semibold))
            Text(verbatim: file.parentPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            TextField("文件名", text: $name)
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
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("重命名", action: rename)
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
        Button("取消", action: cancel)
            .controlSize(.small)
            .buttonStyle(.bordered)
    }
}
