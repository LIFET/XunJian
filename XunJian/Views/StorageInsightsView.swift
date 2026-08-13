import SwiftUI

extension Notification.Name {
    static let xunJianShowStorageInsights = Notification.Name(
        "com.xingmingbo.XunJian.showStorageInsights"
    )
}

/// Aggregated view of what is actually in the index (N15).
///
/// Everything is derived from the already-loaded `files` array in one pass and
/// cached, so opening the panel issues no database queries and does not walk
/// the list once per section.
struct StorageInsightsSnapshot: Equatable {
    struct KindBreakdown: Identifiable, Equatable {
        let kind: FileKind
        let count: Int
        let totalSize: Int64

        var id: FileKind { kind }
    }

    struct SourceBreakdown: Identifiable, Equatable {
        let id: UUID
        let displayName: String
        let count: Int
        let totalSize: Int64
    }

    let fileCount: Int
    let totalSize: Int64
    let kinds: [KindBreakdown]
    let sources: [SourceBreakdown]
    let largestFiles: [IndexedFile]
    let oldestFiles: [IndexedFile]

    static let empty = StorageInsightsSnapshot(
        fileCount: 0,
        totalSize: 0,
        kinds: [],
        sources: [],
        largestFiles: [],
        oldestFiles: []
    )

    static let listLimit = 10

    static func make(files: [IndexedFile], sources: [FileSource]) -> StorageInsightsSnapshot {
        guard !files.isEmpty else { return .empty }

        var totalSize: Int64 = 0
        var countByKind: [FileKind: Int] = [:]
        var sizeByKind: [FileKind: Int64] = [:]
        var countBySource: [UUID: Int] = [:]
        var sizeBySource: [UUID: Int64] = [:]

        for file in files {
            totalSize += file.size
            countByKind[file.kind, default: 0] += 1
            sizeByKind[file.kind, default: 0] += file.size
            countBySource[file.sourceID, default: 0] += 1
            sizeBySource[file.sourceID, default: 0] += file.size
        }

        let kinds = FileKind.allCases
            .compactMap { kind -> KindBreakdown? in
                guard let count = countByKind[kind], count > 0 else { return nil }
                return KindBreakdown(
                    kind: kind,
                    count: count,
                    totalSize: sizeByKind[kind] ?? 0
                )
            }
            .sorted { $0.totalSize > $1.totalSize }

        let sourceBreakdowns = sources
            .compactMap { source -> SourceBreakdown? in
                guard let count = countBySource[source.id], count > 0 else { return nil }
                return SourceBreakdown(
                    id: source.id,
                    displayName: source.displayName,
                    count: count,
                    totalSize: sizeBySource[source.id] ?? 0
                )
            }
            .sorted { $0.totalSize > $1.totalSize }

        let largest = files
            .sorted { $0.size > $1.size }
            .prefix(listLimit)

        // Files with no modification date are skipped rather than sorted to
        // one end, where they would crowd out real results.
        let oldest = files
            .compactMap { file -> (IndexedFile, Date)? in
                file.modifiedAt.map { (file, $0) }
            }
            .sorted { $0.1 < $1.1 }
            .prefix(listLimit)
            .map(\.0)

        return StorageInsightsSnapshot(
            fileCount: files.count,
            totalSize: totalSize,
            kinds: kinds,
            sources: sourceBreakdowns,
            largestFiles: Array(largest),
            oldestFiles: oldest
        )
    }
}

struct StorageInsightsView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var snapshot = StorageInsightsSnapshot.empty
    @State private var hasComputed = false
    // Duplicate detection (N13), on demand because it reads file contents.
    @State private var duplicateGroups: [DuplicateGroup] = []
    @State private var isFindingDuplicates = false
    @State private var duplicateProgress = (hashed: 0, total: 0)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if snapshot.fileCount == 0 {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: XunJianUI.Spacing.section) {
                        summary
                        kindSection
                        if !snapshot.sources.isEmpty {
                            sourceSection
                        }
                        largestSection
                        if !snapshot.oldestFiles.isEmpty {
                            oldestSection
                        }
                        duplicateSection
                    }
                    .padding(XunJianUI.Spacing.page)
                }
            }
        }
        .frame(minWidth: 460, idealWidth: 620, minHeight: 420, idealHeight: 640)
        .task {
            guard !hasComputed else { return }
            hasComputed = true
            snapshot = StorageInsightsSnapshot.make(
                files: appModel.files,
                sources: appModel.sources
            )
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            PageHeader(
                title: AppLanguage.localized("存储洞察", english: "Storage Insights"),
                subtitle: AppLanguage.localized(
                    "统计只来自已索引的文件，不会扫描磁盘。",
                    english: "Based on indexed files only. Nothing is scanned from disk."
                )
            )
            Button(AppLanguage.localized("完成", english: "Done")) { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(XunJianUI.Spacing.page)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            AppLanguage.localized("还没有索引任何文件", english: "No Indexed Files"),
            systemImage: "chart.pie",
            description: Text(verbatim: AppLanguage.localized(
                "添加并扫描一个文件夹后，这里会显示类型和体积分布。",
                english: "Add and scan a folder to see type and size breakdowns here."
            ))
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var summary: some View {
        HStack(spacing: 12) {
            summaryTile(
                value: AppLanguage.fileCount(snapshot.fileCount),
                label: AppLanguage.localized("已索引文件", english: "Indexed Files")
            )
            summaryTile(
                value: Self.sizeText(snapshot.totalSize),
                label: AppLanguage.localized("总体积", english: "Total Size")
            )
            summaryTile(
                value: "\(snapshot.sources.count)",
                label: AppLanguage.localized("授权位置", english: "Locations")
            )
        }
    }

    private func summaryTile(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: value)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(verbatim: label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            XunJianUI.Fill.quiet,
            in: RoundedRectangle(cornerRadius: XunJianUI.Radius.card, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }

    private var kindSection: some View {
        VStack(alignment: .leading, spacing: XunJianUI.Spacing.sectionInner) {
            SectionHeader(title: "按类型分布")
            GroupedSurface(padding: 10) {
                VStack(spacing: 10) {
                    ForEach(snapshot.kinds) { breakdown in
                        proportionRow(
                            title: breakdown.kind.localizedTitle,
                            symbolName: breakdown.kind.symbolName,
                            count: breakdown.count,
                            size: breakdown.totalSize
                        )
                    }
                }
            }
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: XunJianUI.Spacing.sectionInner) {
            SectionHeader(title: "按位置分布")
            GroupedSurface(padding: 10) {
                VStack(spacing: 10) {
                    ForEach(snapshot.sources) { breakdown in
                        proportionRow(
                            title: breakdown.displayName,
                            symbolName: "folder",
                            count: breakdown.count,
                            size: breakdown.totalSize
                        )
                    }
                }
            }
        }
    }

    /// A labelled row with a proportional bar. The bar is relative to the
    /// total indexed size, so bars are comparable across sections.
    private func proportionRow(
        title: String,
        symbolName: String,
        count: Int,
        size: Int64
    ) -> some View {
        let fraction = snapshot.totalSize > 0
            ? Double(size) / Double(snapshot.totalSize)
            : 0

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: symbolName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(verbatim: title)
                    .font(.callout)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(verbatim: AppLanguage.fileCount(count))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text(verbatim: Self.sizeText(size))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(XunJianUI.Fill.control)
                    Capsule()
                        .fill(Color.accentColor.opacity(0.55))
                        .frame(width: max(geometry.size.width * fraction, 2))
                }
            }
            .frame(height: 5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: AppLanguage.localized(
            "\(title)，\(AppLanguage.fileCount(count))，\(Self.sizeText(size))",
            english: "\(title), \(AppLanguage.fileCount(count)), \(Self.sizeText(size))"
        )))
    }

    private var largestSection: some View {
        VStack(alignment: .leading, spacing: XunJianUI.Spacing.sectionInner) {
            SectionHeader(title: "最大的文件")
            fileList(snapshot.largestFiles) { file in
                Self.sizeText(file.size)
            }
        }
    }

    private var oldestSection: some View {
        VStack(alignment: .leading, spacing: XunJianUI.Spacing.sectionInner) {
            SectionHeader(title: "最久未修改")
            fileList(snapshot.oldestFiles) { file in
                file.modifiedAt.map(FinderDateFormatting.string(for:)) ?? "—"
            }
        }
    }

    /// Content-hash duplicate detection (N13). Runs on demand because it
    /// reads file contents; files above 128MB are skipped.
    private var duplicateSection: some View {
        VStack(alignment: .leading, spacing: XunJianUI.Spacing.sectionInner) {
            HStack {
                SectionHeader(title: "重复文件")
                Spacer()
                Button(
                    AppLanguage.localized("查找重复文件", english: "Find Duplicates")
                ) {
                    findDuplicates()
                }
                .disabled(isFindingDuplicates)
            }

            if isFindingDuplicates {
                ProgressView(
                    AppLanguage.localized(
                        duplicateProgress.total > 0
                            ? "正在计算内容指纹 \(duplicateProgress.hashed)/\(duplicateProgress.total)…"
                            : "正在分组文件…",
                        english: duplicateProgress.total > 0
                            ? "Hashing \(duplicateProgress.hashed)/\(duplicateProgress.total)…"
                            : "Grouping files…"
                    )
                )
                .controlSize(.small)
            } else if hasComputed && !duplicateGroups.isEmpty {
                ForEach(duplicateGroups) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(
                            AppLanguage.localized(
                                "\(group.files.count) 个文件 · \(Self.sizeText(group.size))",
                                english: "\(group.files.count) files · \(Self.sizeText(group.size))"
                            )
                        )
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        ForEach(group.files) { file in
                            HStack(spacing: 8) {
                                FileThumbnail(file: file, size: 16)
                                Text(verbatim: file.name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button {
                                    appModel.quickLook(file)
                                } label: {
                                    Image(systemName: "eye")
                                }
                                .buttonStyle(.plain)
                                .help(AppLanguage.localized("快速查看", english: "Quick Look"))
                            }
                            .font(.caption)
                        }
                    }
                    .padding(10)
                    .background(
                        XunJianUI.Fill.quiet,
                        in: RoundedRectangle(
                            cornerRadius: XunJianUI.Radius.row,
                            style: .continuous
                        )
                    )
                }
            }
        }
    }

    private func findDuplicates() {
        guard !isFindingDuplicates else { return }
        isFindingDuplicates = true
        duplicateProgress = (0, 0)
        let files = appModel.files
        Task {
            let groups = await DuplicateFileFinder.find(in: files) { hashed, total in
                Task { @MainActor in
                    duplicateProgress = (hashed, total)
                }
            }
            duplicateGroups = groups
            isFindingDuplicates = false
        }
    }

    private func fileList(
        _ files: [IndexedFile],
        trailing: @escaping (IndexedFile) -> String
    ) -> some View {
        GroupedSurface(padding: 4) {
            VStack(spacing: 0) {
                ForEach(files) { file in
                    Button {
                        appModel.selectedFileID = file.id
                        appModel.showInFinder(file)
                    } label: {
                        HStack(spacing: 10) {
                            FileThumbnail(file: file, size: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: file.name)
                                    .lineLimit(1)
                                Text(verbatim: file.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 8)
                            Text(verbatim: trailing(file))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(AppLanguage.localized("在访达中显示", english: "Show in Finder"))
                    .contextMenu {
                        FileContextMenu(file: file)
                    }

                    if file.id != files.last?.id {
                        Divider().padding(.leading, 44)
                    }
                }
            }
        }
    }

    static func sizeText(_ size: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}
