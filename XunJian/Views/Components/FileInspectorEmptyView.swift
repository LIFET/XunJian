import SwiftUI

struct FileInspectorView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.locale) private var locale
    let file: IndexedFile?

    private var finderDateFormatter: DateFormatter {
        FinderDateFormatting.formatter(for: locale)
    }

    var body: some View {
        Group {
            if let file {
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
                                Label("打开", systemImage: "arrow.up.forward.app")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            Button {
                                appModel.quickLook(file)
                            } label: {
                                Image(systemName: "eye")
                                    .frame(width: 18, height: 18)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.bordered)
                            .help(AppLanguage.localized("预览", english: "Preview"))
                            .accessibilityLabel(AppLanguage.localized("预览", english: "Preview"))
                            Button {
                                appModel.showInFinder(file)
                            } label: {
                                Image(systemName: "finder")
                                    .frame(width: 18, height: 18)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.bordered)
                            .help(AppLanguage.localized("在 Finder 中显示", english: "Show in Finder"))
                            .accessibilityLabel(AppLanguage.localized("在 Finder 中显示", english: "Show in Finder"))

                            // AI entry points (N04): analyse the file right
                            // from the inspector instead of going back to the
                            // toolbar in All Files.
                            if appModel.activeAIProviderKind != nil {
                                Button {
                                    appModel.aiSheetRequest = .explain(file)
                                } label: {
                                    Image(systemName: "doc.text.magnifyingglass")
                                        .frame(width: 18, height: 18)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.bordered)
                                .help(AppLanguage.localized("用 AI 解释这个文件", english: "Explain with AI"))
                                .accessibilityLabel(AppLanguage.localized("用 AI 解释这个文件", english: "Explain with AI"))

                                Button {
                                    appModel.aiSheetRequest = .ask(file)
                                } label: {
                                    Image(systemName: "bubble.left.and.text.bubble.right")
                                        .frame(width: 18, height: 18)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.bordered)
                                .help(AppLanguage.localized("用 AI 提问这个文件", english: "Ask AI About File"))
                                .accessibilityLabel(AppLanguage.localized("用 AI 提问这个文件", english: "Ask AI About File"))
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
                                    Label("新建分类…", systemImage: "plus")
                                }
                            } else {
                                ForEach(appModel.categories) { category in
                                    Button {
                                        appModel.toggleCategory(category, for: file)
                                    } label: {
                                        if appModel.isCategory(category, assignedTo: file) {
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
                                Button("重命名…") { appModel.requestRename(file) }
                                Button("移动到…") { appModel.chooseMoveDestination(for: file) }
                                Button("移到废纸篓", role: .destructive) { appModel.requestTrash(file) }
                            }
                            Menu("更多操作") {
                                Button("重命名…") { appModel.requestRename(file) }
                                Button("移动到…") { appModel.chooseMoveDestination(for: file) }
                                Divider()
                                Button("移到废纸篓", role: .destructive) { appModel.requestTrash(file) }
                            }
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 14) {
                            Text("信息")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                            detail("类型", value: file.kind.localizedTitle)
                            detail(
                                "大小",
                                value: ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)
                            )
                            detail(
                                "位置",
                                value: file.parentPath,
                                lineLimit: 3,
                                help: file.parentPath
                            )
                            detail("创建时间", value: formatted(file.createdAt))
                            detail("修改时间", value: formatted(file.modifiedAt))
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
                    .padding(20)
                }
            } else {
                ContentUnavailableView(
                    "未选择文件",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("选择文件后可在这里查看详情。")
                )
            }
        }
        .navigationTitle("文件详情")
    }

    private func detail(
        _ title: LocalizedStringKey,
        value: String,
        lineLimit: Int? = nil,
        help: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
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
        let names = appModel.categories(for: file).map(\.localizedDisplayName)
        guard !names.isEmpty else {
            return AppLanguage.localized("添加分类", english: "Add Category")
        }
        return names.joined(separator: AppLanguage.selected.usesEnglish ? ", " : "、")
    }
}
