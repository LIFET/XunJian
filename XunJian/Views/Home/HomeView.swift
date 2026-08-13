import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.locale) private var locale
    let openAllFiles: (FileKind?) -> Void

    @State private var hoveredFileKind: FileKind?
    @State private var hoveredRecentFileID: String?

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
                    PageHeader(
                        title: AppLanguage.localized("我的文件", english: "My Files"),
                        subtitle: AppLanguage.localized(
                            "统一查看、查找和理解 Mac 上的重要文件。",
                            english: "Browse, find, and understand important files on your Mac."
                        )
                    )
                    recentFiles
                    fileKinds
                    scanLocations
                }
                .padding(XunJianUI.pagePadding(for: geometry.size.width))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle(AppLanguage.localized("首页", english: "Home"))
    }

    private var recentFiles: some View {
        section(title: "最近文件") {
            if appModel.recentFiles.isEmpty {
                ContentUnavailableView {
                    Label("还没有文件", systemImage: "folder.badge.plus")
                } description: {
                    Text("选择一个文件夹开始建立本地文件索引。")
                } actions: {
                    Button("添加文件夹") {
                        appModel.chooseFolder()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: XunJianUI.Breakpoint.homeEmptyStateHeight,
                    alignment: .center
                )
                .background(
                    XunJianUI.Fill.quiet,
                    in: RoundedRectangle(cornerRadius: XunJianUI.Radius.card, style: .continuous)
                )
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
        section(title: "文件分类概览") {
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
                                    .font(.body.weight(.medium))
                                Text(AppLanguage.fileCount(appModel.fileCount(for: kind)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 11)
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
                        "\(kind.localizedTitle)，\(AppLanguage.fileCount(appModel.fileCount(for: kind)))"
                    )
                }
            }
        }
    }

    private var scanLocations: some View {
        section(title: "扫描位置") {
            if appModel.sources.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "folder.badge.questionmark")
                        .foregroundStyle(.secondary)
                    Text("尚未添加扫描位置")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .background(
                    XunJianUI.Fill.quiet,
                    in: RoundedRectangle(cornerRadius: XunJianUI.Radius.card, style: .continuous)
                )
            } else {
                GroupedSurface(padding: 10) {
                    VStack(spacing: 0) {
                        ForEach(Array(appModel.sources.enumerated()), id: \.element.id) { index, source in
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
                                        .font(.body.weight(.medium))
                                        .lineLimit(1)
                                    Text(source.path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 0)
                                if source.accessState != .available {
                                    Button("重新授权") {
                                        appModel.reauthorizeSource(source)
                                    }
                                    .controlSize(.small)
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
        title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: XunJianUI.Spacing.sectionInner) {
            SectionHeader(title: title)
            content()
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
