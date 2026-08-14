import SwiftUI

struct FileInspectorView: View {
    private static let maximumInlinePreviewCharacters = 20_000
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var categoryIndex: CategoryIndexStore
    @Environment(\.locale) private var locale
    @ScaledMetric(relativeTo: .body) private var actionIconSide: CGFloat = 18
    let file: IndexedFile?

    // Inline text preview (N08).
    @State private var previewText: String?
    @State private var previewLimit = 2_000
    @State private var isLoadingPreview = false
    @State private var previewFailed = false
    @State private var previewRetry = 0
    // Read-only Finder tags, fetched live rather than indexed (N11).
    @State private var finderTags: [String] = []

    private var finderDateFormatter: DateFormatter {
        FinderDateFormatting.formatter(for: locale)
    }

    var body: some View {
        Group {
            if appModel.selectedFileIDs.count > 1 {
                multiSelectInspector
            } else if let file {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(spacing: 12) {
                            FileThumbnail(file: file, size: 150)
                                .padding(10)
                                .background(
                                    XunJianUI.Fill.quiet,
                                    in: RoundedRectangle(
                                        cornerRadius: XunJianUI.Radius.card,
                                        style: .continuous
                                    )
                                )
                            Text(verbatim: file.name)
                                .font(.headline)
                                .multilineTextAlignment(.center)
                                .lineLimit(3)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity)

                        Divider()

                        HStack(spacing: 8) {
                            Button {
                                appModel.open(file)
                            } label: {
                                Label(
                                    AppLanguage.localized("打开", english: "Open"),
                                    systemImage: "arrow.up.forward.app"
                                )
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            Button {
                                appModel.quickLook(file)
                            } label: {
                                Image(systemName: "eye")
                                    .frame(width: actionIconSide, height: actionIconSide)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.bordered)
                            .help(AppLanguage.localized("预览", english: "Preview"))
                            .accessibilityLabel(AppLanguage.localized("预览", english: "Preview"))
                            Button {
                                appModel.showInFinder(file)
                            } label: {
                                Image(systemName: "finder")
                                    .frame(width: actionIconSide, height: actionIconSide)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.bordered)
                            .help(AppLanguage.localized("在 Finder 中显示", english: "Show in Finder"))
                            .accessibilityLabel(AppLanguage.localized("在 Finder 中显示", english: "Show in Finder"))

                            // Keep secondary AI actions in one stable control
                            // so the inspector's 260 pt minimum width never
                            // forces the primary action row to overflow.
                            if appModel.activeAIProviderKind != nil {
                                Menu {
                                    Button {
                                        appModel.aiSheetRequest = .explain(file)
                                    } label: {
                                        Label(
                                            AppLanguage.localized("用 AI 解释", english: "Explain with AI"),
                                            systemImage: "doc.text.magnifyingglass"
                                        )
                                    }
                                    .disabled(!appModel.supportsTextContent(file))
                                    Button {
                                        appModel.aiSheetRequest = .ask(file)
                                    } label: {
                                        Label(
                                            AppLanguage.localized("向 AI 提问", english: "Ask AI About File"),
                                            systemImage: "bubble.left.and.text.bubble.right"
                                        )
                                    }
                                    .disabled(!appModel.supportsTextContent(file))
                                } label: {
                                    Image(systemName: "sparkles")
                                        .frame(width: actionIconSide, height: actionIconSide)
                                        .contentShape(Rectangle())
                                }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .fixedSize()
                                .help(AppLanguage.localized("AI 文件操作", english: "AI File Actions"))
                                .accessibilityLabel(AppLanguage.localized("AI 文件操作", english: "AI File Actions"))
                            }
                        }
                        .frame(maxWidth: .infinity)

                        Menu {
                            if appModel.categories.isEmpty {
                                Text(
                                    AppLanguage.localized(
                                        "还没有分类，请先新建分类",
                                        english: "No categories yet. Create one first."
                                    )
                                )
                                Divider()
                                Button {
                                    NotificationCenter.default.post(
                                        name: .xunJianRequestNewCategory,
                                        object: nil
                                    )
                                } label: {
                                    Label(
                                        AppLanguage.localized("新建分类…", english: "New Category…"),
                                        systemImage: "plus"
                                    )
                                }
                            } else {
                                ForEach(appModel.categories) { category in
                                    Button {
                                        appModel.toggleCategory(category, for: file)
                                    } label: {
                                        if categoryIndex.isAssigned(category.id, to: file.id) {
                                            Label {
                                                Text(verbatim: category.localizedDisplayName)
                                            } icon: {
                                                Image(systemName: "checkmark")
                                            }
                                        } else {
                                            Label {
                                                Text(verbatim: category.localizedDisplayName)
                                            } icon: {
                                                Image(systemName: category.symbolName)
                                            }
                                        }
                                    }
                                }
                            }
                        } label: {
                            Label {
                                Text(verbatim: categorySummary(for: file))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            } icon: {
                                Image(systemName: "folder.badge.plus")
                            }
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                        }

                        ViewThatFits(in: .horizontal) {
                            HStack {
                                Button(AppLanguage.localized("重命名…", english: "Rename…")) {
                                    appModel.requestRename(file)
                                }
                                Button(AppLanguage.localized("移动到…", english: "Move To…")) {
                                    appModel.chooseMoveDestination(for: file)
                                }
                                Button(
                                    AppLanguage.localized("移到废纸篓", english: "Move to Trash"),
                                    role: .destructive
                                ) {
                                    appModel.requestTrash(file)
                                }
                            }
                            Menu(AppLanguage.localized("更多操作", english: "More Actions")) {
                                Button(AppLanguage.localized("重命名…", english: "Rename…")) {
                                    appModel.requestRename(file)
                                }
                                Button(AppLanguage.localized("移动到…", english: "Move To…")) {
                                    appModel.chooseMoveDestination(for: file)
                                }
                                Divider()
                                Button(
                                    AppLanguage.localized("移到废纸篓", english: "Move to Trash"),
                                    role: .destructive
                                ) {
                                    appModel.requestTrash(file)
                                }
                            }
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 14) {
                            Text(AppLanguage.localized("信息", english: "Information"))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
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

                            // N11: read-only Finder tags, fetched live.
                            if !finderTags.isEmpty {
                                detail(
                                    AppLanguage.localized("Finder 标签", english: "Finder Tags"),
                                    value: finderTags.joined(separator: AppLanguage.listSeparator)
                                )
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            XunJianUI.Fill.quiet,
                            in: RoundedRectangle(
                                cornerRadius: XunJianUI.Radius.card,
                                style: .continuous
                            )
                        )

                        // N08: inline text preview with search-term
                        // highlighting, so the user can confirm a match
                        // without leaving the app.
                        if file.kind.supportsTextExtraction {
                            Divider()
                            VStack(alignment: .leading, spacing: 10) {
                                Text(
                                    AppLanguage.localized(
                                        "内容预览",
                                        english: "Content Preview"
                                    )
                                )
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)

                                if isLoadingPreview {
                                    ProgressView()
                                        .controlSize(.small)
                                        .accessibilityLabel(Text(verbatim: AppLanguage.localized(
                                            "正在载入正文",
                                            english: "Loading text"
                                        )))
                                } else if previewFailed {
                                    Text(verbatim: AppLanguage.localized(
                                        "无法读取正文。",
                                        english: "Couldn’t load the text."
                                    ))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    Button(AppLanguage.localized("重试", english: "Retry")) {
                                        previewRetry += 1
                                    }
                                    .buttonStyle(.link)
                                    .controlSize(.small)
                                } else if let previewText, !previewText.isEmpty {
                                    Text(highlightedPreview(String(previewText.prefix(previewLimit))))
                                        .font(.caption)
                                        .lineSpacing(3)
                                        .textSelection(.enabled)
                                        .frame(
                                            maxWidth: .infinity,
                                            alignment: .leading
                                        )

                                    if previewText.count > previewLimit,
                                       previewLimit < Self.maximumInlinePreviewCharacters {
                                        Button(
                                            AppLanguage.localized(
                                                "显示更多",
                                                english: "Show More"
                                            )
                                        ) {
                                            previewLimit = min(
                                                previewLimit + 2_000,
                                                Self.maximumInlinePreviewCharacters
                                            )
                                        }
                                        .buttonStyle(.link)
                                        .controlSize(.small)
                                    } else if previewText.count > Self.maximumInlinePreviewCharacters {
                                        Button(AppLanguage.localized(
                                            "打开完整文本预览",
                                            english: "Open Full Text Preview"
                                        )) {
                                            NotificationCenter.default.post(
                                                name: .xunJianShowTextPreview,
                                                object: nil
                                            )
                                        }
                                        .buttonStyle(.link)
                                        .controlSize(.small)
                                    }
                                } else {
                                    Text(verbatim: AppLanguage.localized(
                                        "没有可提取的文本。",
                                        english: "No extractable text."
                                    ))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                XunJianUI.Fill.quiet,
                                in: RoundedRectangle(
                                    cornerRadius: XunJianUI.Radius.card,
                                    style: .continuous
                                )
                            )
                        }
                    }
                    .padding(20)
                }
            } else {
                ContentUnavailableView(
                    AppLanguage.localized("未选择文件", english: "No File Selected"),
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(
                        AppLanguage.localized(
                            "选择文件后可在这里查看详情。",
                            english: "Select a file to see its details here."
                        )
                    )
                )
            }
        }
        .navigationTitle(AppLanguage.localized("文件详情", english: "File Details"))
        .task(id: "\(file?.id ?? "")-\(previewRetry)") {
            // N08: load text content on demand for the inline preview.
            previewText = nil
            previewLimit = 2_000
            previewFailed = false
            finderTags = []
            guard appModel.selectedFileIDs.count <= 1, let file else { return }

            // N11: live Finder tags. The metadata read is a synchronous
            // filesystem call, so it runs off the main actor: network volumes
            // or not-yet-downloaded iCloud items must not stall the UI.
            let fileURL = file.url
            let tagNames = await Task.detached(priority: .utility) {
                (try? fileURL.resourceValues(forKeys: [.tagNamesKey]))?.tagNames
            }.value
            if let tagNames {
                finderTags = tagNames
            }

            guard file.kind.supportsTextExtraction else { return }
            isLoadingPreview = true
            defer { isLoadingPreview = false }
            do {
                let text = try await appModel.fetchTextContent(forFileID: file.id)
                let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                previewText = trimmed.isEmpty ? nil : text
            } catch {
                previewFailed = true
            }
        }
    }

    private var multiSelectInspector: some View {
        let files = appModel.selectedFiles
        let totalSize = files.reduce(Int64(0)) { $0 + $1.size }
        return ContentUnavailableView {
            Label(
                AppLanguage.localized(
                    "已选择 \(files.count) 项",
                    english: "\(files.count) Selected"
                ),
                systemImage: "checkmark.circle"
            )
        } description: {
            Text(verbatim: AppLanguage.localized(
                "批量操作请用列表上方的工具条。单文件重命名、移动和废纸篓在只选一项时可用。总大小 \(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))。",
                english: "Use the batch bar above the list. Rename, move, and Trash apply to a single file when only one is selected. Total size \(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))."
            ))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Renders the preview with every occurrence of the current search query
    /// highlighted (N08). Case-insensitive; plain text otherwise.
    private func highlightedPreview(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        let query = appModel.highlightQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return attributed }

        let lowercasedText = text.lowercased()
        let lowercasedQuery = query.lowercased()
        var searchStart = lowercasedText.startIndex
        while let range = lowercasedText.range(
            of: lowercasedQuery,
            range: searchStart..<lowercasedText.endIndex
        ) {
            guard let attributedRange = Range(range, in: attributed) else { break }
            attributed[attributedRange].backgroundColor = XunJianUI.Fill.accentWash
            attributed[attributedRange].foregroundColor = .accentColor
            searchStart = range.upperBound
        }
        return attributed
    }

    private func detail(
        _ title: String,
        value: String,
        lineLimit: Int? = nil,
        help: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: title)
                .font(.caption)
                .foregroundStyle(.secondary)
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
        }
    }

    private func formatted(_ date: Date?) -> String {
        guard let date else { return "—" }
        return FinderDateFormatting.formatter(for: locale).string(from: date)
    }

    private func categorySummary(for file: IndexedFile) -> String {
        if appModel.categories.isEmpty {
            return AppLanguage.localized("新建分类…", english: "New Category…")
        }
        let names = categoryIndex.categories(for: file.id).map(\.localizedDisplayName)
        guard !names.isEmpty else {
            return AppLanguage.localized("添加分类", english: "Add Category")
        }
        return names.joined(separator: AppLanguage.listSeparator)
    }
}
