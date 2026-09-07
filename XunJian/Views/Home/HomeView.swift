import SwiftUI
import UniformTypeIdentifiers

enum HomeEmptyStateKind: Equatable {
    case unauthorized, scanning, paused, accessUnavailable, readyEmpty

    static func scopedSources<Source>(wholeMac: Bool, wholeMacSource: Source?, selectedFolderSources: [Source]) -> [Source] {
        wholeMac ? (wholeMacSource.map { [$0] } ?? []) : selectedFolderSources
    }

    static func resolve(hasSources: Bool, isScanning: Bool, isPaused: Bool,
                        hasEnabledSource: Bool, hasAvailableSource: Bool) -> Self {
        guard hasSources else { return .unauthorized }
        if isScanning { return .scanning }
        if !hasAvailableSource { return .accessUnavailable }
        if isPaused || !hasEnabledSource { return .paused }
        return .readyEmpty
    }
}

@MainActor
struct IndexAvailabilityPresentation {
    let appModel: AppModel
    var openAllFiles: (FileKind?) -> Void = { _ in }

    var scopedSources: [FileSource] {
        HomeEmptyStateKind.scopedSources(
            wholeMac: appModel.scanScopeMode == .wholeMac,
            wholeMacSource: appModel.wholeMacSource,
            selectedFolderSources: appModel.selectedFolderSources
        )
    }

    var emptyState: HomeEmptyStateKind {
        HomeEmptyStateKind.resolve(
            hasSources: !scopedSources.isEmpty,
            isScanning: appModel.isScanning,
            isPaused: appModel.scanScopeMode == .wholeMac && appModel.isWholeMacScanPaused,
            hasEnabledSource: scopedSources.contains { $0.enabled && $0.accessState == .available },
            hasAvailableSource: scopedSources.contains { $0.accessState == .available }
        )
    }

    var emptyStateTitle: String {
        switch emptyState {
        case .unauthorized: appModel.scanScopeMode == .wholeMac
            ? AppLanguage.localized("授权全盘扫描", english: "Authorize whole Mac scanning")
            : AppLanguage.localized("添加第一个扫描位置", english: "Add your first scan location")
        case .scanning: AppLanguage.localized("正在建立文件索引", english: "Building your file index")
        case .paused: AppLanguage.localized("扫描已暂停", english: "Scanning is paused")
        case .accessUnavailable: AppLanguage.localized("扫描位置暂不可访问", english: "Scan location unavailable")
        case .readyEmpty: AppLanguage.localized("暂未发现文件", english: "No files found yet")
        }
    }

    var emptyStateDescription: String {
        switch emptyState {
        case .unauthorized: appModel.scanScopeMode == .wholeMac
            ? AppLanguage.localized("请先允许寻简访问启动磁盘。", english: "Allow XunJian to access your startup disk first.")
            : AppLanguage.localized("添加要搜索的文件夹。文件仍保留在原位置。", english: "Add a folder to search. Your files stay where they are.")
        case .scanning: AppLanguage.localized("文件会随扫描进度陆续显示，不用重复添加文件夹。", english: "Files appear as scanning progresses. You don't need to add the folders again.")
        case .paused: AppLanguage.localized("恢复扫描后会继续查找文件。", english: "Resume scanning to continue finding files.")
        case .accessUnavailable: AppLanguage.localized("请检查磁盘是否连接，或重新授权文件夹。", english: "Check that the drive is connected, or grant folder access again.")
        case .readyEmpty: AppLanguage.localized("可以重新扫描，或到设置中检查是否排除了这些文件。", english: "Scan again, or check whether these files are excluded in Settings.")
        }
    }

    var emptyStateActionTitle: String {
        switch emptyState {
        case .unauthorized: appModel.scanScopeMode == .wholeMac
            ? AppLanguage.localized("授权全盘扫描", english: "Authorize Whole Mac")
            : AppLanguage.localized("添加文件夹", english: "Add Folder")
        case .scanning: AppLanguage.localized("查看文件列表", english: "View Files")
        case .paused: AppLanguage.localized("恢复扫描", english: "Resume Scan")
        case .accessUnavailable: AppLanguage.localized("重新授权", english: "Reauthorize")
        case .readyEmpty: AppLanguage.localized("重新扫描", english: "Scan Again")
        }
    }

    func performEmptyStateAction() {
        switch emptyState {
        case .unauthorized:
            if appModel.scanScopeMode == .wholeMac { appModel.chooseWholeMacScope() }
            else { appModel.chooseFolder() }
        case .scanning: openAllFiles(nil)
        case .paused:
            if appModel.scanScopeMode == .wholeMac, appModel.isWholeMacScanPaused { appModel.resumeWholeMacScan() }
            else if let source = scopedSources.first(where: { !$0.enabled && $0.accessState == .available }) {
                appModel.setSourceEnabled(source, enabled: true)
            }
        case .accessUnavailable:
            if let source = scopedSources.first(where: { $0.accessState != .available }) { appModel.reauthorizeSource(source) }
        case .readyEmpty: appModel.refreshAllSources()
        }
    }

}

struct HomeView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.locale) private var locale
    @Environment(\.appVisualTheme) private var visualTheme
    @Environment(\.colorScheme) private var colorScheme
    let openAllFiles: (FileKind?) -> Void
    let searchAllFiles: (String) -> Void

    @State private var hoveredRecentFileID: String?
    @State private var homeQuery = ""
    @State private var sourcePendingRemoval: FileSource?

    // Fixed sizes that still need to grow with the user's text size setting.
    @ScaledMetric(relativeTo: .body) private var sourceIconSize: CGFloat = 14

    private var finderDateFormatter: DateFormatter {
        FinderDateFormatting.formatter(for: locale)
    }

    private var palette: ThemePalette { visualTheme.palette(for: colorScheme) }

    private var availability: IndexAvailabilityPresentation {
        IndexAvailabilityPresentation(appModel: appModel, openAllFiles: openAllFiles)
    }

    private var emptyStateTitle: String { availability.emptyStateTitle }
    private var emptyStateDescription: String { availability.emptyStateDescription }
    private var emptyStateActionTitle: String { availability.emptyStateActionTitle }
    private func performEmptyStateAction() { availability.performEmptyStateAction() }

    private var emptyStateAction: some View {
        Button(emptyStateActionTitle, action: performEmptyStateAction)
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .frame(minHeight: XunJianUI.controlHeight)
            .disabled(!appModel.isDatabaseAvailable)
    }

    var body: some View {
        GeometryReader { geometry in
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                recentSearchBar
                recentFiles
                Divider()
                DisclosureGroup(AppLanguage.localized("搜索位置与授权", english: "Search Locations & Access")) {
                    scanLocations.padding(.top, 16)
                }
                .font(.callout)
            }
            .frame(maxWidth: 1040, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)

        }
        }
        .background(palette.canvas)
        .onAppear {
            appModel.highlightQuery = ""
            appModel.updateCommandTargetFiles(appModel.recentFiles)
        }
        .onChange(of: appModel.filesRevision) { _, _ in
            appModel.updateCommandTargetFiles(appModel.recentFiles)
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

    private var recentSearchBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            StudioPageHeading(
                title: AppLanguage.localized("最近", english: "Recent"),
                subtitle: AppLanguage.localized("按修改时间查看最近的文件。", english: "Browse recent files by modification date.")
            ).padding(.bottom, 16)
            HStack {
                SearchField(
                    text: $homeQuery,
                    focusScope: .home,
                    onHistorySelect: { query in searchAllFiles(query) }
                )
                Menu {
                    Button(AppLanguage.localized("全部文件", english: "All Files")) { openAllFiles(nil) }
                    Divider()
                    ForEach(FileKind.allCases) { kind in
                        Button { openAllFiles(kind) } label: {
                            Label(kind.localizedTitle, systemImage: kind.symbolName)
                        }
                    }
                } label: {
                    Label(AppLanguage.localized("按类型查找", english: "Find by Type"), systemImage: "line.3.horizontal.decrease")
                }
                .controlSize(.large)
            }
        }
    }

    private var recentFiles: some View {
        section(title: AppLanguage.localized("最近文件", english: "Recent Files")) {
            if appModel.recentFiles.isEmpty {
                Group {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: XunJianUI.Spacing.sectionInner) {
                            homeEmptyStateIdentity
                            Spacer(minLength: XunJianUI.Spacing.sectionInner)
                            emptyStateAction
                        }

                        VStack(alignment: .leading, spacing: XunJianUI.Spacing.sectionInner) {
                            homeEmptyStateIdentity
                            emptyStateAction
                        }
                    }
                }
            } else {
                Group {
                    VStack(spacing: 0) {
                        ForEach(appModel.recentFiles) { file in
                            Button {
                                appModel.selectedFileID = file.id
                                openAllFiles(nil)
                            } label: {
                                RecentFileRow(
                                    file: file,
                                    formattedDate: file.modifiedAt.map {
                                        finderDateFormatter.string(from: $0)
                                    }
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    recentFileBackground(for: file),
                                    in: RoundedRectangle(
                                        cornerRadius: XunJianUI.Radius.row,
                                        style: .continuous
                                    )
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .combine)
                            .accessibilityHint(AppLanguage.localized(
                                "在所有文件中显示这个文件",
                                english: "Reveal this file in All Files"
                            ))
                            .onHover { isHovering in
                                hoveredRecentFileID = isHovering ? file.id : nil
                            }
                            .contextMenu {
                                FileContextMenu(file: file)
                            }
                            .draggable(file.url)

                            if file.id != appModel.recentFiles.last?.id {
                                Divider()
                                    .padding(.leading, 50)
                            }
                        }
                    }
                }
            }
        }
    }

    private var scanLocations: some View {
        section(
            title: AppLanguage.localized("搜索来源", english: "Search Sources"),
            subtitle: AppLanguage.localized(
                "寻简只会索引你明确授权的位置。",
                english: "XunJian indexes only the locations you explicitly authorize."
            )
        ) {
            if appModel.sources.isEmpty {
                Group {
                    HStack(spacing: XunJianUI.Spacing.sectionInner) {
                        Image(systemName: "folder.badge.questionmark")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.tint)
                            .frame(width: 36, height: 36)
                            .background(
                                XunJianUI.Fill.accentWash,
                                in: RoundedRectangle(
                                    cornerRadius: XunJianUI.Radius.chip,
                                    style: .continuous
                                )
                            )
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: AppLanguage.localized(
                                "还没有添加文件夹",
                                english: "No scan locations yet"
                            ))
                            .font(XunJianUI.Typography.itemTitle)
                            Button(AppLanguage.localized("管理搜索位置…", english: "Manage Search Locations…")) {
                                NotificationCenter.default.post(name: .xunJianOpenSettings, object: SettingsPage.files)
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
            } else {
                Group {
                    VStack(spacing: 0) {
                        ForEach(Array(appModel.sources.enumerated()), id: \.element.id) { index, source in
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 12) {
                                    sourceIdentity(source)
                                        .layoutPriority(1)
                                    Spacer(minLength: 12)
                                    sourceActions(source)
                                        .fixedSize(horizontal: true, vertical: false)
                                }

                                VStack(alignment: .leading, spacing: 8) {
                                    sourceIdentity(source)
                                    sourceActions(source)
                                }
                            }
                            .padding(.vertical, visualTheme.rowVerticalPadding + 2)

                            if index < appModel.sources.count - 1 {
                                Divider()
                                    .padding(.leading, 34)
                            }
                        }
                    }
                }
            }
        }
    }

    private func section<Content: View>(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: XunJianUI.Spacing.sectionInner) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.headline)
                if let subtitle, !subtitle.isEmpty {
                    Text(verbatim: subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content()
        }
    }

    private var homeEmptyStateIdentity: some View {
        HStack(spacing: XunJianUI.Spacing.sectionInner) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 42, height: 42)
                .background(
                    XunJianUI.Fill.accentWash,
                    in: RoundedRectangle(
                        cornerRadius: XunJianUI.Radius.control,
                        style: .continuous
                    )
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: emptyStateTitle)
                    .font(XunJianUI.Typography.itemTitle)
                Text(verbatim: emptyStateDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func sourceIdentity(_ source: FileSource) -> some View {
        HStack(spacing: 12) {
            Image(systemName: source.accessState == .available
                  ? "folder.fill"
                  : "folder.badge.exclamationmark")
                .font(.system(size: sourceIconSize, weight: .medium))
                .foregroundStyle(
                    source.accessState == .available
                        ? Color(nsColor: .secondaryLabelColor)
                        : XunJianUI.Semantic.warning
                )
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.displayName)
                    .font(XunJianUI.Typography.itemTitle)
                    .lineLimit(1)
                    .help(source.displayName)
                Text(source.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(source.path)
            }
        }
    }

    @ViewBuilder
    private func sourceActions(_ source: FileSource) -> some View {
        HStack(spacing: 8) {
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
            .controlSize(.regular)
            .labelsHidden()
            .help(
                AppLanguage.localized(
                    source.enabled ? "暂停索引" : "恢复索引",
                    english: source.enabled ? "Pause indexing" : "Resume indexing"
                )
            )
            .accessibilityLabel(
                AppLanguage.localized(
                    source.enabled ? "暂停索引“\(source.displayName)”" : "恢复索引“\(source.displayName)”",
                    english: source.enabled
                        ? "Pause indexing for “\(source.displayName)”"
                        : "Resume indexing for “\(source.displayName)”"
                )
            )
            .disabled(!appModel.isDatabaseAvailable)
            ControlGroup {
                if source.accessState != .available {
                    Button(AppLanguage.localized("重新授权", english: "Reauthorize")) {
                        appModel.reauthorizeSource(source)
                    }
                }
                Button(
                    AppLanguage.localized("移除…", english: "Remove…"),
                    role: .destructive
                ) {
                    sourcePendingRemoval = source
                }
                .disabled(!appModel.isDatabaseAvailable)
            }
            .controlSize(.regular)
        }
    }

    private func recentFileBackground(for file: IndexedFile) -> Color {
        if appModel.selectedFileID == file.id {
            return palette.selection
        }
        return hoveredRecentFileID == file.id ? palette.surface : .clear
    }
}

private struct RecentFileRow: View {
    @Environment(\.appVisualTheme) private var visualTheme
    let file: IndexedFile
    let formattedDate: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: file.fileExtension) ?? .data))
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 32)
                .accessibilityHidden(true)
            fileIdentity
            Spacer(minLength: 8)
            modifiedDate
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private var fileIdentity: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(file.name)
                .font(.body.weight(.medium))
                .lineLimit(1)
            Text(verbatim: file.url.deletingLastPathComponent().lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(file.parentPath)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var modifiedDate: some View {
        if let formattedDate {
            Text(verbatim: formattedDate)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}
