import AppKit
import SwiftUI
import UserNotifications

struct SettingsView: View {
    var presentsErrors = false

    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var oauth: OAuthCoordinator
    @EnvironmentObject private var ai: AISessionCoordinator
    @EnvironmentObject private var updateCoordinator: AppUpdateCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.controlActiveState) private var controlActiveState
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system.rawValue
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system.rawValue
    @AppStorage(MenuBarSearchPreference.storageKey) private var showsMenuBarSearch = true
    @AppStorage(FileIndexPreferences.indexesFileContentsKey)
    private var indexesFileContents = true
    // Bound to the same keys the file list writes, so changing a default here
    // takes effect immediately rather than only for new windows.
    @AppStorage("allFiles.sortOrder") private var defaultSortOrder = FileSortOrder.modifiedAt
    @AppStorage("allFiles.sortAscending") private var defaultSortAscending = false
    @AppStorage("allFiles.viewMode") private var defaultViewMode = FileBrowseViewMode.list
    @AppStorage(FileActivationBehavior.storageKey)
    private var doubleClickBehavior = FileActivationBehavior.open
    @State private var indexStatistics = IndexStatistics.unknown
    @State private var customExclusions = ScanExclusions.current()
    @State private var newExclusion = ""
    @State private var isRebuildingSearchIndex = false
    @State private var sourcePendingRemoval: FileSource?
    @State private var notificationsEnabled = false
    @State private var notificationPermissionDenied = false
    /// Highlighted while a folder is dragged over the authorisation area (F06).
    @State private var droppedFolderTargeted = false
    @State private var showsAllAuthorizedFolders = false

    private static let collapsedAuthorizedFolderLimit = 4

    private var displayedAuthorizedFolders: ArraySlice<FileSource> {
        let sources = appModel.selectedFolderSources
        return sources.prefix(
            showsAllAuthorizedFolders ? sources.count : Self.collapsedAuthorizedFolderLimit
        )
    }

    var body: some View {
        Form {
            Section(AppLanguage.localized("通用", english: "General")) {
                Picker(AppLanguage.localized("外观", english: "Appearance"), selection: $appearance) {
                    ForEach(AppAppearance.allCases) { option in
                        Text(verbatim: option.title).tag(option.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .id(language)
                Picker(AppLanguage.localized("界面语言", english: "Language"), selection: $language) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(verbatim: option.title).tag(option.rawValue)
                    }
                }
                .pickerStyle(.menu)

                Toggle(
                    AppLanguage.localized(
                        "扫描完成后发送通知",
                        english: "Notify when a scan finishes"
                    ),
                    isOn: Binding(
                        get: { notificationsEnabled },
                        set: { enabled in
                            Task { await setNotificationsEnabled(enabled) }
                        }
                    )
                )
                .toggleStyle(.switch)

                if notificationPermissionDenied {
                    HStack {
                        Text(verbatim: AppLanguage.localized(
                            "系统通知权限已关闭。",
                            english: "Notification permission is turned off."
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button(AppLanguage.localized("打开系统设置", english: "Open System Settings")) {
                            guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
                            NSWorkspace.shared.open(url)
                        }
                    }
                }

                Toggle(
                    AppLanguage.localized(
                        "在菜单栏显示快速搜索",
                        english: "Show quick search in the menu bar"
                    ),
                    isOn: $showsMenuBarSearch
                )
                .toggleStyle(.switch)
            }

            Section(AppLanguage.localized("浏览", english: "Browsing")) {
                Picker(
                    AppLanguage.localized("默认排序", english: "Default Sort"),
                    selection: $defaultSortOrder
                ) {
                    ForEach(FileSortOrder.allCases.filter { $0 != .relevance }) { order in
                        Text(verbatim: order.localizedTitle).tag(order)
                    }
                }
                .pickerStyle(.menu)

                Picker(
                    AppLanguage.localized("默认顺序", english: "Default Order"),
                    selection: $defaultSortAscending
                ) {
                    Text(verbatim: AppLanguage.localized("升序", english: "Ascending")).tag(true)
                    Text(verbatim: AppLanguage.localized("降序", english: "Descending")).tag(false)
                }
                .pickerStyle(.menu)

                Picker(
                    AppLanguage.localized("默认显示方式", english: "Default View"),
                    selection: $defaultViewMode
                ) {
                    ForEach(FileBrowseViewMode.allCases) { mode in
                        Text(verbatim: mode.localizedTitle).tag(mode)
                    }
                }
                .pickerStyle(.menu)

                Picker(
                    AppLanguage.localized("双击文件时", english: "Double-clicking a file"),
                    selection: $doubleClickBehavior
                ) {
                    ForEach(FileActivationBehavior.allCases) { behavior in
                        Text(verbatim: behavior.localizedTitle).tag(behavior)
                    }
                }
                .pickerStyle(.menu)
            }

            Section(AppLanguage.localized("文件位置", english: "Locations")) {
                Toggle(
                    AppLanguage.localized(
                        "显示以点号开头的隐藏文件",
                        english: "Show dot-prefixed hidden files"
                    ),
                    isOn: Binding(
                        get: { appModel.includesHiddenFiles },
                        set: { appModel.setIncludesHiddenFiles($0) }
                    )
                )
                .disabled(
                    appModel.isScanning
                        || appModel.isUpdatingContentIndex
                        || !appModel.isDatabaseAvailable
                )

                Text(
                    verbatim: AppLanguage.localized(
                        "默认不索引 .DS_Store 等以“.”开头的文件和文件夹；修改后会重新扫描。",
                        english: "By default, files and folders beginning with “.”, such as .DS_Store, are not indexed. Changing this setting rescans your folders."
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Toggle(
                    AppLanguage.localized(
                        "索引支持文件的正文内容",
                        english: "Index the contents of supported files"
                    ),
                    isOn: Binding(
                        get: { indexesFileContents },
                        set: { enabled in
                            appModel.setIndexesFileContents(enabled)
                        }
                    )
                )
                .disabled(
                    appModel.isScanning
                        || appModel.isUpdatingContentIndex
                        || !appModel.isDatabaseAvailable
                )

                if appModel.isUpdatingContentIndex {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(verbatim: AppLanguage.localized(
                            "正在安全清除已保存正文…",
                            english: "Securely clearing stored file contents…"
                        ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(verbatim: AppLanguage.localized(
                    "正文只保存在本机索引中，用于全文搜索；关闭会立即清除已保存正文。只有你主动使用 AI 文件操作时，相关正文才会发送给当前 AI。",
                    english: "File contents stay in the local index for full-text search. Turning this off clears stored contents immediately. Content is sent to the current AI only when you explicitly use an AI file action."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)

                Picker(
                    AppLanguage.localized("扫描范围", english: "Scan Scope"),
                    selection: Binding(
                        get: { appModel.scanScopeMode },
                        set: { appModel.setScanScopeMode($0) }
                    )
                ) {
                    ForEach(FileScanScopeMode.allCases) { mode in
                        Text(verbatim: mode.localizedTitle).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(appModel.isScanning || !appModel.isDatabaseAvailable)

                if appModel.scanScopeMode == .wholeMac {
                    VStack(alignment: .leading, spacing: 10) {
                        if let source = appModel.wholeMacSource {
                            sourceIdentity(source)
                            Text(verbatim: AppLanguage.localized(
                                "当前只扫描整台 Mac 范围；你添加的文件夹会保留，切回“指定文件夹”后继续使用。",
                                english: "Only the Entire Mac scope is active. Added folders are retained and resume when you switch back."
                            ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            HStack(spacing: 10) {
                                sourcePrimaryAction(source)
                                if appModel.isScanning {
                                    Button(AppLanguage.localized(
                                        "暂停扫描",
                                        english: "Pause Scan"
                                    )) {
                                        appModel.pauseWholeMacScan()
                                    }
                                } else if appModel.isWholeMacScanPaused {
                                    Button(AppLanguage.localized(
                                        "继续扫描",
                                        english: "Resume Scan"
                                    )) {
                                        appModel.resumeWholeMacScan()
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                                Button(AppLanguage.localized(
                                    "完全磁盘访问设置…",
                                    english: "Full Disk Access Settings…"
                                )) {
                                    appModel.openFullDiskAccessSettings()
                                }
                            }
                        } else {
                            Text(verbatim: AppLanguage.localized(
                                "整台 Mac 扫描需要你先选择启动磁盘，并在系统设置中按需授予完全磁盘访问。未授权前不会开始扫描。",
                                english: "Entire Mac scanning requires selecting the startup disk and granting Full Disk Access when needed. Scanning does not start before authorization."
                            ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            HStack(spacing: 10) {
                                Button(AppLanguage.localized(
                                    "授权整台 Mac…",
                                    english: "Authorize Entire Mac…"
                                )) {
                                    appModel.chooseWholeMacScope()
                                }
                                .buttonStyle(.borderedProminent)
                                Button(AppLanguage.localized(
                                    "打开完全磁盘访问设置…",
                                    english: "Open Full Disk Access Settings…"
                                )) {
                                    appModel.openFullDiskAccessSettings()
                                }
                            }
                        }
                    }
                    .padding(12)
                    .background(
                        XunJianUI.Fill.quiet,
                        in: RoundedRectangle(
                            cornerRadius: XunJianUI.Radius.card,
                            style: .continuous
                        )
                    )
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        LabeledContent(
                            AppLanguage.localized("已授权目录", english: "Authorized Folders"),
                            value: "\(appModel.selectedFolderSources.count)"
                        )
                        Button(AppLanguage.localized("添加文件夹", english: "Add Folder")) {
                            appModel.chooseFolder()
                        }
                        .disabled(!appModel.isDatabaseAvailable)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent(
                            AppLanguage.localized("已授权目录", english: "Authorized Folders"),
                            value: "\(appModel.selectedFolderSources.count)"
                        )
                        Button(AppLanguage.localized("添加文件夹", english: "Add Folder")) {
                            appModel.chooseFolder()
                        }
                        .disabled(!appModel.isDatabaseAvailable)
                    }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    var added = false
                    for url in urls {
                        var isDirectory: ObjCBool = false
                        guard FileManager.default.fileExists(
                            atPath: url.path,
                            isDirectory: &isDirectory
                        ), isDirectory.boolValue else { continue }
                        appModel.addFolderDropped(url: url)
                        added = true
                    }
                    if !added {
                        appModel.settingsErrorMessage = AppLanguage.localized(
                            "请拖入文件夹。",
                            english: "Drop a folder."
                        )
                    }
                    return added
                } isTargeted: { isTargeted in
                    droppedFolderTargeted = isTargeted
                }
                .padding(4)
                .background(
                    droppedFolderTargeted
                        ? XunJianUI.Fill.selectedSoft
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: XunJianUI.Radius.control, style: .continuous)
                )

                ForEach(displayedAuthorizedFolders) { source in
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            sourceIdentity(source)
                                .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
                            sourcePrimaryAction(source)
                            // N06: pause a slow folder without removing its
                            // index; enable again to rescan it.
                            Toggle(
                                AppLanguage.localized(
                                    source.enabled ? "索引中" : "已暂停",
                                    english: source.enabled ? "Indexing" : "Paused"
                                ),
                                isOn: Binding(
                                    get: { source.enabled },
                                    set: { appModel.setSourceEnabled(source, enabled: $0) }
                                )
                            )
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .disabled(!appModel.isDatabaseAvailable)
                            Button(
                                AppLanguage.localized("移除…", english: "Remove…"),
                                role: .destructive
                            ) {
                                sourcePendingRemoval = source
                            }
                            .disabled(!appModel.isDatabaseAvailable)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            sourceIdentity(source)
                            Toggle(
                                AppLanguage.localized(
                                    source.enabled ? "索引中" : "已暂停",
                                    english: source.enabled ? "Indexing" : "Paused"
                                ),
                                isOn: Binding(
                                    get: { source.enabled },
                                    set: { appModel.setSourceEnabled(source, enabled: $0) }
                                )
                            )
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .disabled(!appModel.isDatabaseAvailable)
                            HStack(spacing: 8) {
                                sourcePrimaryAction(source)
                                Button(
                                    AppLanguage.localized("移除…", english: "Remove…"),
                                    role: .destructive
                                ) {
                                    sourcePendingRemoval = source
                                }
                                .disabled(!appModel.isDatabaseAvailable)
                            }
                        }
                    }
                }

                if appModel.selectedFolderSources.count > Self.collapsedAuthorizedFolderLimit {
                    Button {
                        showsAllAuthorizedFolders.toggle()
                    } label: {
                        Label(
                            showsAllAuthorizedFolders
                                ? AppLanguage.localized("收起文件夹", english: "Show Fewer Folders")
                                : AppLanguage.localized(
                                    "显示其余 \(appModel.selectedFolderSources.count - Self.collapsedAuthorizedFolderLimit) 个文件夹",
                                    english: "Show \(appModel.selectedFolderSources.count - Self.collapsedAuthorizedFolderLimit) More Folders"
                                ),
                            systemImage: showsAllAuthorizedFolders ? "chevron.up" : "chevron.down"
                        )
                    }
                    .buttonStyle(.link)
                }

                if !appModel.sources.isEmpty {
                    Button(AppLanguage.localized("重新扫描全部位置", english: "Rescan All Locations")) {
                        appModel.refreshAllSources()
                    }
                    .disabled(
                        appModel.isScanning
                            || !appModel.sources.contains(where: {
                                $0.enabled && $0.accessState == .available
                            })
                    )
                    .disabled(!appModel.isDatabaseAvailable)
                }
            }

            Section {
                LabeledContent(
                    AppLanguage.localized("当前 AI", english: "Current AI"),
                    value: activeProviderSummary
                )

                ForEach(AIProviderKind.allCases) { kind in
                    AIProviderSettingsRow(kind: kind)
                }
            } header: {
                Text(AppLanguage.localized("AI 服务", english: "AI Services"))
            } footer: {
                Text(
                    verbatim: AppLanguage.localized(
                        "凭据只保存在当前用户的寻简本地数据目录，不会写入 App 包或随 App 分享。普通搜索始终在本地完成。",
                        english: "Credentials stay in XunJian's local data folder for the current user and are never included in the app bundle or shared with it. Regular search always stays on your Mac."
                    )
                )
            }

            Section(AppLanguage.localized("扫描排除", english: "Scan Exclusions")) {
                Text(verbatim: AppLanguage.localized(
                    "扫描会始终跳过 .git、node_modules、DerivedData、Caches 等构建与缓存目录。可以在这里补充自己的目录名，改动会立即重新扫描。",
                    english: "Scans always skip build and cache folders such as .git, node_modules, DerivedData, and Caches. Add your own folder names here; changes trigger a rescan."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                ForEach(customExclusions, id: \.self) { name in
                    HStack {
                        Text(verbatim: name)
                        Spacer(minLength: 8)
                        Button {
                            updateExclusions(customExclusions.filter { $0 != name })
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text(verbatim: AppLanguage.localized(
                            "移除排除项“\(name)”",
                            english: "Remove exclusion “\(name)”"
                        )))
                    }
                }

                HStack {
                    TextField(
                        AppLanguage.localized("目录名，例如 vendor", english: "Folder name, e.g. vendor"),
                        text: $newExclusion
                    )
                    .onSubmit(addExclusion)
                    Button(AppLanguage.localized("添加", english: "Add"), action: addExclusion)
                        .disabled(
                            newExclusion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                }
            }

            Section(AppLanguage.localized("索引状态", english: "Index Status")) {
                LabeledContent(
                    AppLanguage.localized("已索引文件", english: "Indexed Files")
                ) {
                    Text(verbatim: AppLanguage.fileCount(appModel.files.count))
                }
                LabeledContent(
                    AppLanguage.localized("数据库体积", english: "Database Size")
                ) {
                    Text(verbatim: indexStatistics.databaseSizeText)
                }
                LabeledContent(
                    AppLanguage.localized("最近索引", english: "Last Indexed")
                ) {
                    Text(verbatim: indexStatistics.lastIndexedText)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        Task {
                            isRebuildingSearchIndex = true
                            await appModel.rebuildSearchIndex()
                            indexStatistics = await IndexStatistics.make(files: appModel.files)
                            isRebuildingSearchIndex = false
                        }
                    } label: {
                        if isRebuildingSearchIndex {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(verbatim: AppLanguage.localized(
                                "重建搜索索引",
                                english: "Rebuild Search Index"
                            ))
                        }
                    }
                    .disabled(isRebuildingSearchIndex || !appModel.isDatabaseAvailable)

                    Text(verbatim: AppLanguage.localized(
                        "搜索结果不准确时使用。只重新生成搜索数据并压缩数据库，不会删除文件、授权目录或你的分类。",
                        english: "Use this when search results look wrong. It only regenerates search data and compacts the database — no files, locations, or categories are removed."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .task(id: appModel.filesRevision) {
                // Skip the repeated database-size reads while a scan bumps
                // filesRevision on every batch commit; the scan-end hook
                // below recomputes once when scanning stops.
                guard !appModel.isScanning else { return }
                indexStatistics = await IndexStatistics.make(files: appModel.files)
            }
            .onChange(of: appModel.isScanning) { _, isScanning in
                guard !isScanning else { return }
                Task {
                    indexStatistics = await IndexStatistics.make(files: appModel.files)
                }
            }

            Section(AppLanguage.localized("关于与更新", english: "About & Updates")) {
                LabeledContent(
                    AppLanguage.localized("应用", english: "App"),
                    value: AppLanguage.localized("寻简", english: "XunJian")
                )
                LabeledContent(
                    AppLanguage.localized("版本", english: "Version"),
                    value: appVersionText
                )

                Toggle(
                    AppLanguage.localized(
                        "自动检查更新",
                        english: "Automatically check for updates"
                    ),
                    isOn: Binding(
                        get: { updateCoordinator.automaticallyChecksForUpdates },
                        set: { updateCoordinator.automaticallyChecksForUpdates = $0 }
                    )
                )
                .toggleStyle(.switch)
                .disabled(!updateCoordinator.isConfigured)

                Button(AppLanguage.localized("检查更新…", english: "Check for Updates…")) {
                    updateCoordinator.checkForUpdates()
                }
                .disabled(
                    !updateCoordinator.isConfigured
                        || !updateCoordinator.canCheckForUpdates
                )

                if !updateCoordinator.isConfigured {
                    Text(verbatim: AppLanguage.localized(
                        "当前构建尚未配置受信任的 HTTPS 更新源和 EdDSA 公钥。发布版本配置后才会启用在线更新。",
                        english: "This build has no trusted HTTPS update feed or EdDSA public key. Online updates activate only after the release build is configured."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .id(language)
        .navigationTitle(AppLanguage.localized("设置", english: "Settings"))
        .onAppear {
            appModel.updateCommandTargetFiles([])
        }
        .task { await refreshNotificationAuthorization() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await refreshNotificationAuthorization() }
        }
        .alert(
            AppLanguage.localized("操作未完成", english: "Action Couldn’t Finish"),
            isPresented: presentsErrorAlert
        ) {
            Button(AppLanguage.localized("好", english: "OK")) {
                appModel.clearSettingsError()
            }
        } message: {
            Text(AppLanguage.localizedRuntimeMessage(appModel.settingsErrorMessage ?? ""))
        }
        .confirmationDialog(
            AppLanguage.localized("移除文件夹授权？", english: "Remove Folder Access?"),
            isPresented: Binding(
                get: { sourcePendingRemoval != nil },
                set: { if !$0 { sourcePendingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: sourcePendingRemoval
        ) { source in
            Button(
                AppLanguage.localized(
                    "移除“\(source.displayName)”",
                    english: "Remove “\(source.displayName)”"
                ),
                role: .destructive
            ) {
                appModel.removeSource(source)
                sourcePendingRemoval = nil
            }
            Button(AppLanguage.localized("取消", english: "Cancel"), role: .cancel) {
                sourcePendingRemoval = nil
            }
        } message: { _ in
            Text(
                AppLanguage.localized(
                    "只会移除寻简保存的授权与本地索引，不会删除原文件夹或其中的文件。",
                    english: "This removes XunJian’s saved access and local index. The original folder and its files stay on disk."
                )
            )
        }
    }

    private func addExclusion() {
        let candidate = newExclusion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return }
        newExclusion = ""
        updateExclusions(customExclusions + [candidate])
    }

    private var presentsErrorAlert: Binding<Bool> {
        Binding(
            get: {
                presentsErrors
                    && controlActiveState == .key
                    && appModel.settingsErrorMessage != nil
            },
            set: { if !$0 { appModel.clearSettingsError() } }
        )
    }

    private var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        guard let build, !build.isEmpty, build != version else { return version }
        return "\(version) (\(build))"
    }

    private func refreshNotificationAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let stored = UserDefaults.standard.bool(forKey: "notifications.scanComplete")
        let authorized = settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
        notificationsEnabled = stored && authorized
        notificationPermissionDenied = settings.authorizationStatus == .denied
        if stored && !authorized {
            UserDefaults.standard.set(false, forKey: "notifications.scanComplete")
        }
    }

    private func setNotificationsEnabled(_ enabled: Bool) async {
        guard enabled else {
            UserDefaults.standard.set(false, forKey: "notifications.scanComplete")
            notificationsEnabled = false
            return
        }
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            UserDefaults.standard.set(granted, forKey: "notifications.scanComplete")
            notificationsEnabled = granted
            await refreshNotificationAuthorization()
        } catch {
            UserDefaults.standard.set(false, forKey: "notifications.scanComplete")
            notificationsEnabled = false
            notificationPermissionDenied = true
        }
    }

    /// Persists and rescans, so the visible file list matches the new rules
    /// immediately rather than only after the next manual scan.
    private func updateExclusions(_ names: [String]) {
        let normalized = ScanExclusions.normalized(names)
        guard normalized != customExclusions else { return }
        customExclusions = normalized
        ScanExclusions.save(normalized)
        appModel.refreshAllSources()
    }

    private func sourceIdentity(_ source: FileSource) -> some View {
        HStack(spacing: 12) {
            Image(systemName: source.accessState == .available ? "folder" : "folder.badge.exclamationmark")
                .foregroundStyle(
                    Color(
                        nsColor: source.accessState == .available
                            ? .secondaryLabelColor
                            : .systemOrange
                    )
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: source.displayName)
                    .lineLimit(1)
                Text(verbatim: source.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func sourcePrimaryAction(_ source: FileSource) -> some View {
        if source.accessState == .available {
            Button(AppLanguage.localized("重新扫描", english: "Rescan")) {
                appModel.scanSource(source)
            }
            .disabled(appModel.isScanning || !source.enabled)
            .disabled(!appModel.isDatabaseAvailable)
        } else {
            Button(AppLanguage.localized("重新授权", english: "Reauthorize")) {
                appModel.reauthorizeSource(source)
            }
            .disabled(!appModel.isDatabaseAvailable)
        }
    }

    private func providerTitle(_ kind: AIProviderKind) -> String {
        guard kind == .qwen else { return kind.title }
        return AppLanguage.localized("Qwen / 千问", english: "Qwen")
    }

    private var activeProviderSummary: String {
        guard let kind = ai.activeProviderKind,
              let mode = ai.activeAuthenticationMode else {
            return AppLanguage.localized("未配置", english: "Not Configured")
        }
        return "\(providerTitle(kind)) · \(mode.localizedTitle)"
    }
}
