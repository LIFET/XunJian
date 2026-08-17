import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.locale) private var locale
    let openAllFiles: (FileKind?) -> Void
    let searchAllFiles: (String) -> Void

    @State private var hoveredFileKind: FileKind?
    @State private var hoveredRecentFileID: String?
    @State private var homeQuery = ""
    @State private var sourcePendingRemoval: FileSource?

    // Fixed sizes that still need to grow with the user's text size setting.
    @ScaledMetric(relativeTo: .body) private var kindIconSize: CGFloat = 15
    @ScaledMetric(relativeTo: .body) private var kindIconContainer: CGFloat = 28
    @ScaledMetric(relativeTo: .body) private var sourceIconSize: CGFloat = 14

    private var finderDateFormatter: DateFormatter {
        FinderDateFormatting.formatter(for: locale)
    }

    private let columns = [
        GridItem(.adaptive(minimum: XunJianUI.Breakpoint.homeCardMin), spacing: 12)
    ]

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: XunJianUI.Spacing.section) {
                    searchHero
                    recentFiles
                    fileKinds
                    scanLocations
                }
                .padding(XunJianUI.pagePadding(for: geometry.size.width))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
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

    private var searchHero: some View {
        InsetSurface(usesAccentWash: true) {
            VStack(alignment: .leading, spacing: XunJianUI.Spacing.sectionInner) {
                PageHeader(
                    title: AppLanguage.localized(
                        "在这台 Mac 上，快速找到文件",
                        english: "Find files on this Mac, fast"
                    ),
                    subtitle: AppLanguage.localized(
                        "搜索已授权位置中的文件名与本地索引内容。",
                        english: "Search filenames and locally indexed content in authorized locations."
                    )
                )
                SearchField(
                    text: $homeQuery,
                    focusScope: .home,
                    onHistorySelect: { query in
                        searchAllFiles(query)
                    }
                )
            }
        }
    }

    private var recentFiles: some View {
        section(title: AppLanguage.localized("最近文件", english: "Recent Files")) {
            if appModel.recentFiles.isEmpty {
                InsetSurface {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: XunJianUI.Spacing.sectionInner) {
                            homeEmptyStateIdentity
                            Spacer(minLength: XunJianUI.Spacing.sectionInner)
                            Button(AppLanguage.localized("添加文件夹", english: "Add Folder")) {
                                appModel.chooseFolder()
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        VStack(alignment: .leading, spacing: XunJianUI.Spacing.sectionInner) {
                            homeEmptyStateIdentity
                            Button(AppLanguage.localized("添加文件夹", english: "Add Folder")) {
                                appModel.chooseFolder()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
            } else {
                GroupedSurface(padding: 4) {
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

    private var fileKinds: some View {
        section(
            title: AppLanguage.localized("按类型浏览", english: "Browse by Type"),
            subtitle: AppLanguage.localized(
                "直接进入常用文件类型，不改变文件在磁盘上的位置。",
                english: "Jump to common file types without moving anything on disk."
            )
        ) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(FileKind.allCases) { kind in
                    Button {
                        openAllFiles(kind)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: kind.symbolName)
                                .font(.system(size: kindIconSize, weight: .medium))
                                .frame(width: kindIconContainer, height: kindIconContainer)
                                .foregroundStyle(.tint)
                                .background(
                                    Color.accentColor.opacity(0.10),
                                    in: RoundedRectangle(
                                        cornerRadius: XunJianUI.Radius.chip,
                                        style: .continuous
                                    )
                                )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(kind.localizedTitle)
                                    .font(XunJianUI.Typography.itemTitle)
                                Text(AppLanguage.fileCount(appModel.fileCount(for: kind)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, XunJianUI.Spacing.sectionInner)
                        .padding(.vertical, XunJianUI.Spacing.row)
                        .background {
                            InteractiveCardBackground(
                                isSelected: appModel.selectedKind == kind,
                                isHovered: hoveredFileKind == kind
                            )
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SoftCardButtonStyle())
                    .onHover { isHovering in
                        hoveredFileKind = isHovering ? kind : nil
                    }
                    .accessibilityLabel(
                        AppLanguage.joinedForAccessibility([
                            kind.localizedTitle,
                            AppLanguage.fileCount(appModel.fileCount(for: kind))
                        ])
                    )
                    .accessibilityValue(
                        Text(verbatim: appModel.selectedKind == kind
                             ? AppLanguage.localized("已选择", english: "Selected")
                             : AppLanguage.localized("未选择", english: "Not Selected"))
                    )
                }
            }
        }
    }

    private var scanLocations: some View {
        section(
            title: AppLanguage.localized("扫描位置", english: "Scan Locations"),
            subtitle: AppLanguage.localized(
                "寻简只会索引你明确授权的位置。",
                english: "XunJian indexes only the locations you explicitly authorize."
            )
        ) {
            if appModel.sources.isEmpty {
                InsetSurface(padding: 14) {
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
                                "尚未添加扫描位置",
                                english: "No scan locations yet"
                            ))
                            .font(XunJianUI.Typography.itemTitle)
                            Text(verbatim: AppLanguage.localized(
                                "可前往设置添加文件夹。",
                                english: "Add folders from Settings."
                            ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                GroupBox {
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
                            .padding(.vertical, 8)

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
                SectionHeader(title: title)
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
                Text(verbatim: AppLanguage.localized("还没有文件", english: "No Files Yet"))
                    .font(XunJianUI.Typography.itemTitle)
                Text(verbatim: AppLanguage.localized(
                    "选择一个文件夹，开始建立本地文件索引。",
                    english: "Choose a folder to start building a local file index."
                ))
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
            .controlSize(.small)
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
            .controlSize(.small)
        }
    }

    private func recentFileBackground(for file: IndexedFile) -> Color {
        if appModel.selectedFileID == file.id {
            return XunJianUI.Fill.selectedSoft
        }
        return hoveredRecentFileID == file.id ? XunJianUI.Fill.hover : .clear
    }
}

private struct RecentFileRow: View {
    let file: IndexedFile
    let formattedDate: String?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                FileThumbnail(file: file, size: 32)
                fileIdentity
                Spacer(minLength: 8)
                modifiedDate
            }

            HStack(alignment: .top, spacing: 12) {
                FileThumbnail(file: file, size: 32)
                VStack(alignment: .leading, spacing: 4) {
                    fileIdentity
                    modifiedDate
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    private var fileIdentity: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(file.name)
                .lineLimit(1)
            Text(file.parentPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var modifiedDate: some View {
        if let formattedDate {
            Text(verbatim: formattedDate)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}
