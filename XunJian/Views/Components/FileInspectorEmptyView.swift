import SwiftUI

struct InspectorSelectionActionState {
    let selectedCount: Int
    let resolvedCount: Int

    var canApplyBatchActions: Bool {
        selectedCount > 1 && resolvedCount == selectedCount
    }
}

struct FileInspectorView: View {
    nonisolated static let maximumInlinePreviewCharacters = 20_000
    nonisolated static let inlinePreviewFetchCharacterLimit = maximumInlinePreviewCharacters + 1
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var categoryIndex: CategoryIndexStore
    @Environment(\.locale) private var locale
    @Environment(\.appVisualTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isFileInformationExpanded = false
    let file: IndexedFile?
    var onClose: (() -> Void)? = nil

    // Inline text preview (N08).
    @State private var previewText: String?
    @State private var previewLoadState = InspectorPreviewLoadState()
    private var isLoadingPreview: Bool { previewLoadState.isLoading }
    @State private var previewFailed = false
    @State private var previewRetry = 0
    /// Observe only the presentation query. Search lifecycle changes no
    /// longer travel through AppModel and redraw the entire inspector shell.
    @State private var highlightQuery = ""
    // Read-only Finder tags, fetched live rather than indexed (N11).
    @State private var finderTags: [String] = []
    @State private var loadedFinderTagFileID: String?
    @State private var finderTagRefreshRevision: UInt64 = 0

    private var finderDateFormatter: DateFormatter {
        FinderDateFormatting.formatter(for: locale)
    }

    var body: some View {
        VStack(spacing: 0) {
            inspectorHeader
            Divider()
            if appModel.selectedFileIDs.count > 1 {
                multiSelectInspector
            } else if let file {
                VStack(spacing: 0) {
                    ZStack {
                        // Keep native PDF/text reading position alive while viewing metadata.
                        contentPreview(for: file)
                            .opacity(isFileInformationExpanded ? 0 : 1)
                            .allowsHitTesting(!isFileInformationExpanded)
                            .accessibilityHidden(isFileInformationExpanded)
                        if isFileInformationExpanded {
                            inspectorFooter(for: file)
                                .transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
                }
            } else {
                ContentUnavailableView(
                    AppLanguage.localized("未选择文件", english: "No File Selected"),
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(
                        AppLanguage.localized(
                            "选择一个文件查看内容和信息。",
                            english: "Select a file to see its details here."
                        )
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.palette(for: colorScheme).canvas)
        .tint(theme.palette(for: colorScheme).accent)
        .onReceive(
            appModel.browseSearchStore.$highlightQuery.removeDuplicates()
        ) { query in
            highlightQuery = query
        }
        .onAppear { restoreCachedInspectorContent() }
        .onChange(of: file?.id) { _, _ in
            restoreCachedInspectorContent()
        }
        .task(id: "\(previewCacheKey)-\(previewRetry)") {
            let generation = previewLoadState.begin()
            defer { previewLoadState.finish(generation) }
            guard appModel.selectedFileIDs.count <= 1, let file else { return }
            guard DocumentPreviewPolicy.route(kind: file.kind, fileExtension: file.fileExtension) == .text else {
                previewText = nil
                previewFailed = false
                return
            }

            if previewRetry == 0,
               let cached = InspectorPreviewCache.text(for: previewCacheKey) {
                previewText = cached.text
                previewFailed = cached.failed
                return
            }

            previewFailed = false
            do {
                let text = try await appModel.fetchInspectorPreviewText(
                    forFileID: file.id,
                    maximumCharacters: Self.inlinePreviewFetchCharacterLimit
                )
                guard !Task.isCancelled, previewLoadState.isCurrent(generation), self.file?.id == file.id else { return }
                let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let resolved = trimmed.isEmpty ? nil : text
                previewText = resolved
                previewFailed = false
                InspectorPreviewCache.storeText(
                    InspectorPreviewCache.CachedText(text: resolved, failed: false),
                    for: previewCacheKey
                )
            } catch {
                guard !Task.isCancelled, previewLoadState.isCurrent(generation), self.file?.id == file.id else { return }
                guard !InspectorPreviewCache.isCancellation(error) else { return }
                previewFailed = true
            }
        }
        .task(id: "\(file?.id ?? "")-\(finderTagRefreshRevision)") {
            guard appModel.selectedFileIDs.count <= 1, let file else {
                finderTags = []
                loadedFinderTagFileID = nil
                return
            }
            if let cached = InspectorPreviewCache.tags(for: file.id) {
                finderTags = cached
                loadedFinderTagFileID = file.id
                return
            }
            if FinderTagRefreshPolicy.shouldClearExistingTags(
                loadedFileID: loadedFinderTagFileID,
                currentFileID: file.id
            ) {
                finderTags = []
            }
            // N11: live Finder tags. The metadata read is a synchronous
            // filesystem call, so it runs off the main actor: network volumes
            // or not-yet-downloaded iCloud items must not stall the UI.
            let fileURL = file.url
            let tagNames = await Task.detached(priority: .utility) {
                (try? fileURL.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
            }.value
            guard !Task.isCancelled, self.file?.id == file.id else { return }
            finderTags = tagNames
            loadedFinderTagFileID = file.id
            InspectorPreviewCache.storeTags(tagNames, for: file.id)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .xunJianFinderTagsDidChange)
        ) { notification in
            guard let file,
                  let fileIDs = notification.object as? Set<String>,
                  fileIDs.contains(file.id) else { return }
            InspectorPreviewCache.invalidateTags(for: file.id)
            finderTagRefreshRevision &+= 1
        }
    }

    private var inspectorHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                inspectorHeading.frame(minWidth: 120)
                inspectorHeaderActions.fixedSize(horizontal: true, vertical: false)
            }
            .frame(height: 48)
            VStack(alignment: .leading, spacing: 0) {
                inspectorHeading.frame(height: 32)
                inspectorHeaderActions.frame(height: 40)
            }
            .padding(.vertical, 4)
        }
        .padding(.horizontal, theme.contentPadding)
        .accessibilityElement(children: .contain)
    }

    private var inspectorHeading: some View {
        Text(verbatim: appModel.selectedFileIDs.count > 1
             ? AppLanguage.localized("已选 \(appModel.selectedFileIDs.count) 项", english: "\(appModel.selectedFileIDs.count) selected")
             : file?.name ?? AppLanguage.localized("文件预览", english: "File Preview"))
            .font(.system(size: 13, weight: .medium)).lineLimit(1)
            .truncationMode(.middle).help(file?.name ?? "")
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("inspector.filename")
    }

    private var inspectorHeaderActions: some View {
        HStack(spacing: 12) {
        if let file, appModel.selectedFileIDs.count <= 1 {
        HStack(spacing: 4) {
            inspectorTab(AppLanguage.localized("阅读", english: "Read"), information: false)
            inspectorTab(AppLanguage.localized("信息", english: "Info"), information: true)
        }
        .accessibilityIdentifier("inspector.mode")
        .xunjianAnimation(value: isFileInformationExpanded)
        .controlSize(.large)
        .fixedSize()
        Spacer(minLength: 0)
            Menu {
                Button(AppLanguage.localized("快速查看", english: "Quick Look")) { appModel.quickLook(file) }
                Button(AppLanguage.localized("在 Finder 中显示", english: "Show in Finder")) { appModel.showInFinder(file) }
                Button(AppLanguage.localized("复制路径", english: "Copy Path")) { appModel.copyPath(file) }
                categoryMenu(for: file)
                if appModel.activeAIProviderKind != nil {
                    Divider()
                    Button(AppLanguage.localized("用 AI 解释", english: "Explain with AI")) { appModel.aiSheetRequest = .explain(file) }
                        .disabled(!appModel.supportsTextContent(file))
                    Button(AppLanguage.localized("向 AI 提问", english: "Ask AI About File")) { appModel.aiSheetRequest = .ask(file) }
                        .disabled(!appModel.supportsTextContent(file))
                }
                Divider()
                Button(AppLanguage.localized("重命名…", english: "Rename…")) { appModel.requestRename(file) }
                Button(AppLanguage.localized("移动到…", english: "Move To…")) { appModel.chooseMoveDestination(for: file) }
                Button(AppLanguage.localized("移到废纸篓", english: "Move to Trash"), role: .destructive) { appModel.requestTrash(file) }
            } label: {
                Text(AppLanguage.localized("打开", english: "Open"))
            } primaryAction: { appModel.open(file) }
            .controlSize(.large).fixedSize()
            .accessibilityIdentifier("inspector.open")
        } else { Spacer(minLength: 0) }
        if let onClose {
            Button(action: onClose) {
                Image(systemName: "xmark").frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .controlSize(.large)
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
            .help(AppLanguage.localized("关闭阅读区", english: "Close Reading Pane"))
            .accessibilityLabel(AppLanguage.localized("关闭阅读区", english: "Close Reading Pane"))
            .accessibilityIdentifier("inspector.close")
        }
        }
    }

    private func inspectorTab(_ title: String, information: Bool) -> some View {
        Button { isFileInformationExpanded = information } label: {
            Text(verbatim: title).font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 8).frame(height: 38)
                .contentShape(Rectangle())
                .foregroundStyle(isFileInformationExpanded == information ? theme.palette(for: colorScheme).accent : .secondary)
                .overlay(alignment: .bottom) {
                    if isFileInformationExpanded == information { Rectangle().fill(theme.palette(for: colorScheme).accent).frame(height: 2) }
                }
        }.buttonStyle(.plain)
            .accessibilityAddTraits(isFileInformationExpanded == information ? .isSelected : [])
    }

    private func inspectorFooter(for file: IndexedFile) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                fileIdentity(for: file)
                Text(AppLanguage.localized("文件信息", english: "File Information"))
                    .font(.headline)
                fileInformation(for: file)
            }
            .padding(theme.contentPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.palette(for: colorScheme).surface)
    }

    private func fileIdentity(for file: IndexedFile) -> some View {
        HStack(alignment: .top, spacing: 12) {
            FileThumbnail(file: file, size: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: file.name)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                    .textSelection(.enabled)
                Text(verbatim: file.kind.localizedTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }


    private func categoryMenu(for file: IndexedFile) -> some View {
        Menu(AppLanguage.localized("资料集", english: "Collections")) {
            if appModel.categories.isEmpty {
                Text(AppLanguage.localized("还没有资料集", english: "No collections yet"))
                Button(AppLanguage.localized("新建资料集…", english: "New Collection…")) {
                    NotificationCenter.default.post(name: .xunJianRequestNewCategory, object: nil)
                }
            } else {
                ForEach(appModel.categories) { category in
                    Button { appModel.toggleCategory(category, for: file) } label: {
                        Label(category.localizedDisplayName,
                              systemImage: categoryIndex.isAssigned(category.id, to: file.id) ? "checkmark" : category.symbolName)
                    }
                }
            }
        }
    }

    private func fileInformation(for file: IndexedFile) -> some View {
            VStack(alignment: .leading, spacing: 14) {
                detail(
                    AppLanguage.localized("类型", english: "Kind"),
                    value: file.kind.localizedTitle
                )
                detail(
                    AppLanguage.localized("大小", english: "Size"),
                    value: ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)
                )
                detail(
                    AppLanguage.localized("位置", english: "Where"),
                    value: file.parentPath,
                    lineLimit: 3,
                    help: file.parentPath
                )
                detail(
                    AppLanguage.localized("创建时间", english: "Created"),
                    value: formatted(file.createdAt)
                )
                detail(
                    AppLanguage.localized("修改时间", english: "Modified"),
                    value: formatted(file.modifiedAt)
                )
                let categories = categoryIndex.categories(for: file.id).map(\.localizedDisplayName)
                if !categories.isEmpty {
                    detail(AppLanguage.localized("分类", english: "Categories"),
                           value: categories.joined(separator: AppLanguage.listSeparator))
                }

                // N11: read-only Finder tags, fetched live.
                if !finderTags.isEmpty {
                    detail(
                        AppLanguage.localized("Finder 标签", english: "Finder Tags"),
                        value: finderTags.joined(separator: AppLanguage.listSeparator)
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func contentPreview(for file: IndexedFile) -> some View {
        Group {
            let route = DocumentPreviewPolicy.route(kind: file.kind, fileExtension: file.fileExtension)
            if route == .pdf || route == .image {
                DocumentPreviewView(file: file, source: appModel.sources.first { $0.id == file.sourceID }) {
                    appModel.quickLook(file)
                }
            } else if route == .text {
                if isLoadingPreview {
                    ProgressView(AppLanguage.localized("正在载入正文", english: "Loading text"))
                        .controlSize(.small)
                } else if previewFailed {
                    VStack(spacing: 12) {
                        Text(AppLanguage.localized("无法读取正文。", english: "Couldn’t load the text."))
                            .foregroundStyle(.secondary)
                        Button(AppLanguage.localized("重试", english: "Retry")) { previewRetry += 1 }
                    }
                } else if let previewText, !previewText.isEmpty {
                    InspectorTextDocumentPreview(
                        text: String(previewText.prefix(Self.maximumInlinePreviewCharacters)),
                        kind: file.kind,
                        query: highlightQuery,
                        hasMore: Self.shouldOfferFullTextPreview(fetchedCharacterCount: previewText.count),
                        openFullPreview: {
                            NotificationCenter.default.post(name: .xunJianShowTextPreview, object: nil)
                        },
                        readingPositionKey: "\(readingPositionKey)|\(highlightQuery)"
                    )
                    .id(file.id)
                } else {
                    Text(verbatim: AppLanguage.localized("没有可提取的文本。", english: "No extractable text."))
                        .foregroundStyle(.secondary)
                }
            } else {
                ContentUnavailableView {
                    Label(file.kind.localizedTitle, systemImage: file.kind.symbolName)
                } description: {
                    Text(AppLanguage.localized("使用系统预览查看原文件。", english: "Use system Preview to view the original file."))
                } actions: {
                    Button(AppLanguage.localized("系统预览", english: "System Preview")) { appModel.quickLook(file) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    nonisolated static func previewFontDesign(for kind: FileKind) -> Font.Design {
        kind == .code ? .monospaced : .default
    }

    nonisolated static func isExtractedPDFPreview(fileExtension: String) -> Bool {
        fileExtension.caseInsensitiveCompare("pdf") == .orderedSame
    }

    nonisolated static func shouldOfferFullTextPreview(
        fetchedCharacterCount: Int
    ) -> Bool {
        fetchedCharacterCount > maximumInlinePreviewCharacters
    }

    private var multiSelectInspector: some View {
        let fileCount = appModel.selectedFileIDs.count
        let totalSize = appModel.selectedFileTotalSize
        let actionState = InspectorSelectionActionState(selectedCount: fileCount, resolvedCount: appModel.selectedFiles.count)
        return VStack(alignment: .leading, spacing: 12) {
            Text(AppLanguage.localized("已选择 \(fileCount) 项", english: "\(fileCount) Selected"))
                .font(.headline)
            Text(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))
                .foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                batchActionRow(fileCount: fileCount, showsTitles: true)
                batchActionRow(fileCount: fileCount, showsTitles: false)
            }
            .disabled(!actionState.canApplyBatchActions)
            Text(actionState.canApplyBatchActions
                ? AppLanguage.localized("可为所选文件添加分类，或在更多操作中移到废纸篓。选择一项可阅读正文。", english: "Add the selected files to a category, or move them to Trash from More Actions. Select one file to read its contents.")
                : AppLanguage.localized("部分所选文件已不可用，请重新选择后操作。", english: "Some selected files are unavailable. Select the files again before continuing."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(theme.contentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func batchActionRow(fileCount: Int, showsTitles: Bool) -> some View {
        HStack(spacing: 8) {
            Menu {
                if appModel.categories.isEmpty {
                    Text(AppLanguage.localized("还没有分类", english: "No categories yet"))
                    Button(AppLanguage.localized("新建资料集…", english: "New Collection…")) {
                        NotificationCenter.default.post(name: .xunJianRequestNewCategory, object: nil)
                    }
                } else {
                    ForEach(appModel.categories) { category in
                        Button(category.localizedDisplayName) { appModel.assignSelectedFiles(to: category) }
                    }
                }
            } label: {
                XunJianToolbarLabel(title: AppLanguage.localized("添加到分类", english: "Add to Category"),
                                    systemImage: "folder.badge.plus", showsTitle: showsTitles, showsChevron: true)
            }
            .accessibilityIdentifier("inspector.batchCategory")
            Menu {
                Button(AppLanguage.localized("移到废纸篓（\(fileCount) 项）", english: "Move \(fileCount) Items to Trash"), role: .destructive) {
                    appModel.requestBatchTrash(appModel.selectedFiles)
                }
            } label: {
                XunJianToolbarLabel(title: AppLanguage.localized("更多操作", english: "More Actions"),
                                    systemImage: "ellipsis", showsTitle: showsTitles, showsChevron: true)
            }
            .accessibilityIdentifier("inspector.batchMore")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(XunJianToolbarButtonStyle())
        .foregroundStyle(.primary)
        .tint(.primary)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func detail(
        _ title: String,
        value: String,
        lineLimit: Int? = nil,
        help: String? = nil
    ) -> some View {
        LabeledContent {
            Group {
                if let help {
                    Text(verbatim: value)
                        .help(help)
                } else {
                    Text(verbatim: value)
                }
            }
                .font(.callout)
                .lineLimit(lineLimit)
                .truncationMode(.middle)
                .textSelection(.enabled)
        } label: {
            Text(verbatim: title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func formatted(_ date: Date?) -> String {
        guard let date else { return "—" }
        return FinderDateFormatting.formatter(for: locale).string(from: date)
    }

    private func restoreCachedInspectorContent() {
        previewLoadState.invalidate()
        guard let file else {
            previewText = nil
            previewFailed = false
            finderTags = []
            loadedFinderTagFileID = nil
            return
        }
        if let cached = InspectorPreviewCache.text(for: previewCacheKey) {
            previewText = cached.text
            previewFailed = cached.failed
        } else {
            previewText = nil
            previewFailed = false
        }
        if let cachedTags = InspectorPreviewCache.tags(for: file.id) {
            finderTags = cachedTags
            loadedFinderTagFileID = file.id
        } else {
            finderTags = []
            loadedFinderTagFileID = nil
        }
    }

    private var previewCacheKey: String {
        guard let file else { return "" }
        let identity = DocumentPreviewPolicy.fileIdentity(id: file.id, path: file.path, kind: file.kind, fileExtension: file.fileExtension)
        return "\(identity)|\(file.size)|\(file.modifiedAt?.timeIntervalSince1970 ?? 0)"
    }

    private var readingPositionKey: String {
        guard let file else { return "" }
        let source = appModel.sources.first { $0.id == file.sourceID }
        let sourceIdentity = source.map { DocumentPreviewPolicy.sourceIdentity(enabled: $0.enabled, bookmark: $0.bookmark) } ?? 0
        return DocumentPreviewPolicy.readingIdentity(
            fileIdentity: DocumentPreviewPolicy.fileIdentity(id: file.id, path: file.path, kind: file.kind, fileExtension: file.fileExtension),
            size: file.size, modifiedAt: file.modifiedAt?.timeIntervalSince1970,
            accessState: source?.accessState.rawValue ?? "missing", sourceIdentity: sourceIdentity)
    }

}

/// Bounded inspector preview cache. Survives the inspector being dismissed
/// so the same file can reopen without another disk / index read.
@MainActor
private enum InspectorPreviewCache {
    struct CachedText {
        var text: String?
        var failed: Bool
    }

    private static let limit = 16
    private static var order: [String] = []
    private static var texts: [String: CachedText] = [:]
    private static var tags: [String: [String]] = [:]

    static func text(for fileID: String) -> CachedText? {
        texts[fileID]
    }

    static func tags(for fileID: String) -> [String]? {
        tags[fileID]
    }

    static func storeText(_ value: CachedText, for fileID: String) {
        texts[fileID] = value
        touch(fileID)
    }

    static func storeTags(_ value: [String], for fileID: String) {
        tags[fileID] = value
        touch(fileID)
    }

    static func invalidateTags(for fileID: String) {
        tags.removeValue(forKey: fileID)
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return true
        }
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSUserCancelledError {
            return true
        }
        return false
    }

    private static func touch(_ fileID: String) {
        order.removeAll { $0 == fileID }
        order.append(fileID)
        while order.count > limit {
            let evicted = order.removeFirst()
            texts.removeValue(forKey: evicted)
            tags.removeValue(forKey: evicted)
        }
    }
}
