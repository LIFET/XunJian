import SwiftUI

struct CategoriesView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.locale) private var locale
    let selectedCategory: FileCategory?
    let openCategory: (FileCategory) -> Void
    let showAllCategories: () -> Void

    @State private var showsNewCategory = false
    @State private var categoryToRename: FileCategory?
    @State private var categoryToDelete: FileCategory?
    @State private var hoveredCategoryID: UUID?
    @State private var hoveredFileID: String?

    private let columns = [
        GridItem(.adaptive(minimum: 176), spacing: 12)
    ]

    init(
        selectedCategory: FileCategory?,
        openCategory: @escaping (FileCategory) -> Void = { _ in },
        showAllCategories: @escaping () -> Void = {}
    ) {
        self.selectedCategory = selectedCategory
        self.openCategory = openCategory
        self.showAllCategories = showAllCategories
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: XunJianUI.Spacing.section) {
                    header

                    if let selectedCategory {
                        categoryFiles(selectedCategory)
                    } else {
                        categoryOverview
                    }
                }
                .padding(XunJianUI.pagePadding(for: geometry.size.width))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle(
            selectedCategory?.localizedDisplayName
                ?? AppLanguage.localized("分类", english: "Categories")
        )
        .onAppear {
            appModel.clearSelectionIfHidden(from: Set(selectedCategoryFileIDs))
        }
        .onChange(of: selectedCategoryFileIDs) { _, fileIDs in
            appModel.clearSelectionIfHidden(from: Set(fileIDs))
        }
        .sheet(isPresented: $showsNewCategory) {
            CategoryEditorSheet(title: "新建分类") { name, symbolName in
                try await appModel.createCategory(name: name, symbolName: symbolName)
            }
            .environment(\.locale, locale)
        }
        .sheet(item: $categoryToRename) { category in
            CategoryEditorSheet(
                title: "修改分类名称",
                initialName: category.name,
                initialSymbol: category.symbolName,
                allowsSymbolEditing: false
            ) { name, _ in
                try await appModel.renameCategory(category, to: name)
            }
            .environment(\.locale, locale)
        }
        .alert(
            "删除分类？",
            isPresented: Binding(
                get: { categoryToDelete != nil },
                set: { if !$0 { categoryToDelete = nil } }
            )
        ) {
            Button("取消", role: .cancel) { categoryToDelete = nil }
            Button("删除分类", role: .destructive) {
                if let categoryToDelete {
                    appModel.deleteCategory(categoryToDelete)
                }
                categoryToDelete = nil
            }
        } message: {
            Text(verbatim: deleteMessage)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            if selectedCategory != nil {
                Button(action: showAllCategories) {
                    Label("全部分类", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    headerIdentity
                    Spacer(minLength: 0)
                    headerAction
                }

                VStack(alignment: .leading, spacing: 10) {
                    headerIdentity
                    headerAction
                }
            }
        }
    }

    private var headerIdentity: some View {
        PageHeader(
            title: selectedCategory?.localizedDisplayName
                ?? AppLanguage.localized("分类", english: "Categories"),
            subtitle: AppLanguage.localized(
                "用简单分类组织文件，一个文件可以属于多个分类。",
                english: "Organize files with simple categories. A file can belong to more than one."
            )
        )
    }

    @ViewBuilder
    private var headerAction: some View {
        if let selectedCategory {
            Menu {
                Button("修改名称…") {
                    categoryToRename = selectedCategory
                }
                Divider()
                Button("删除分类", role: .destructive) {
                    categoryToDelete = selectedCategory
                }
            } label: {
                Label {
                    Text(verbatim: AppLanguage.localized(
                        "管理分类",
                        english: "Manage Category"
                    ))
                } icon: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        } else {
            Button {
                showsNewCategory = true
            } label: {
                Label("新建分类", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
    }

    @ViewBuilder
    private var categoryOverview: some View {
        if appModel.categories.isEmpty {
            ContentUnavailableView(
                "还没有分类",
                systemImage: "folder.badge.plus",
                description: Text("创建分类后，可以从文件右键菜单或详情栏添加。")
            )
            .frame(maxWidth: .infinity, minHeight: 280)
            .background(
                XunJianUI.Fill.quiet,
                in: RoundedRectangle(cornerRadius: XunJianUI.Radius.card, style: .continuous)
            )
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(appModel.categories) { category in
                    Button {
                        openCategory(category)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: category.symbolName)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(.tint)
                                .frame(width: 32, height: 32)
                                .background(
                                    Color.accentColor.opacity(0.10),
                                    in: RoundedRectangle(
                                        cornerRadius: XunJianUI.Radius.chip,
                                        style: .continuous
                                    )
                                )
                            VStack(alignment: .leading, spacing: 3) {
                                Text(verbatim: category.localizedDisplayName)
                                    .font(.body.weight(.semibold))
                                    .lineLimit(1)
                                Text(verbatim: AppLanguage.fileCount(appModel.fileCount(in: category)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .background {
                            InteractiveCardBackground(
                                isHovered: hoveredCategoryID == category.id
                            )
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SoftCardButtonStyle())
                    .onHover { isHovering in
                        hoveredCategoryID = isHovering ? category.id : nil
                    }
                    .accessibilityLabel(
                        "\(category.localizedDisplayName)，\(AppLanguage.fileCount(appModel.fileCount(in: category)))"
                    )
                    .contextMenu {
                        Button("修改名称…") { categoryToRename = category }
                        Divider()
                        Button("删除分类", role: .destructive) { categoryToDelete = category }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func categoryFiles(_ category: FileCategory) -> some View {
        let files = appModel.files(in: category)
        if files.isEmpty {
            ContentUnavailableView(
                "这个分类里还没有文件",
                systemImage: category.symbolName,
                description: Text("从文件右键菜单或详情栏为文件添加分类。")
            )
            .frame(maxWidth: .infinity, minHeight: 280)
            .background(
                XunJianUI.Fill.quiet,
                in: RoundedRectangle(cornerRadius: XunJianUI.Radius.card, style: .continuous)
            )
        } else {
            GroupedSurface(padding: 4) {
                LazyVStack(spacing: 0) {
                    ForEach(files) { file in
                        Button {
                            appModel.selectedFileID = file.id
                        } label: {
                            HStack(spacing: 12) {
                                FileThumbnail(file: file, size: 34)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(verbatim: file.name)
                                        .lineLimit(1)
                                    Text(verbatim: file.parentPath)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 0)
                                Text(
                                    verbatim: ByteCountFormatter.string(
                                        fromByteCount: file.size,
                                        countStyle: .file
                                    )
                                )
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            .background(
                                categoryFileBackground(for: file),
                                in: RoundedRectangle(
                                    cornerRadius: XunJianUI.Radius.row,
                                    style: .continuous
                                )
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .simultaneousGesture(
                            TapGesture(count: 2).onEnded {
                                appModel.selectedFileID = file.id
                                appModel.open(file)
                            }
                        )
                        .onHover { isHovering in
                            hoveredFileID = isHovering ? file.id : nil
                        }
                        .contextMenu {
                            FileContextMenu(file: file)
                        }

                        if file.id != files.last?.id {
                            Divider()
                                .padding(.leading, 56)
                        }
                    }
                }
            }
        }
    }

    private var selectedCategoryFileIDs: [String] {
        guard let selectedCategory else { return appModel.files.map(\.id) }
        return appModel.files(in: selectedCategory).map(\.id)
    }

    private var deleteMessage: String {
        let name = categoryToDelete?.localizedDisplayName
            ?? AppLanguage.localized("这个分类", english: "this category")
        return AppLanguage.localized(
            "只会删除“\(name)”及其分类关系，不会删除任何真实文件。",
            english: "Only “\(name)” and its category relationships will be deleted. No files will be deleted."
        )
    }

    private func categoryFileBackground(for file: IndexedFile) -> Color {
        if appModel.selectedFileID == file.id {
            return XunJianUI.Fill.selectedSoft
        }
        return hoveredFileID == file.id ? XunJianUI.Fill.hover : .clear
    }
}

struct CategoryEditorSheet: View {
    let title: LocalizedStringKey
    let allowsSymbolEditing: Bool
    let submit: (String, String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var symbolName: String
    @State private var isSaving = false
    @State private var failure: String?
    @FocusState private var isNameFocused: Bool

    private let symbols = [
        "folder", "briefcase", "doc.text", "paintbrush", "books.vertical",
        "banknote", "person", "archivebox", "building.2", "star"
    ]

    init(
        title: LocalizedStringKey,
        initialName: String = "",
        initialSymbol: String = "folder",
        allowsSymbolEditing: Bool = true,
        submit: @escaping (String, String) async throws -> Void
    ) {
        self.title = title
        self.allowsSymbolEditing = allowsSymbolEditing
        self.submit = submit
        _name = State(initialValue: initialName)
        _symbolName = State(initialValue: initialSymbol)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.title2.weight(.semibold))
            TextField("分类名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isNameFocused)
                .onSubmit(save)
            if let failure {
                Text(AppLanguage.localizedRuntimeMessage(failure))
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if allowsSymbolEditing {
                Text("图标")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 40))], spacing: 8) {
                    ForEach(symbols, id: \.self) { symbol in
                        Button {
                            symbolName = symbol
                        } label: {
                            Image(systemName: symbol)
                                .font(.system(size: 14, weight: .medium))
                                .frame(width: 36, height: 36)
                                .foregroundStyle(symbolName == symbol ? Color.accentColor : .primary)
                                .background {
                                    RoundedRectangle(
                                        cornerRadius: XunJianUI.Radius.chip,
                                        style: .continuous
                                    )
                                    .fill(
                                        symbolName == symbol
                                            ? XunJianUI.Fill.selected
                                            : XunJianUI.Fill.quiet
                                    )
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            symbolAccessibilityLabel(symbol)
                        )
                        .accessibilityValue(
                            symbolName == symbol
                                ? AppLanguage.localized("已选择", english: "Selected")
                                : ""
                        )
                    }
                }
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .disabled(isSaving)
            }
        }
        .padding(24)
        .frame(minWidth: 280, idealWidth: 440, maxWidth: 520, alignment: .leading)
        .onAppear { isNameFocused = true }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        failure = nil
        Task {
            do {
                try await submit(name, symbolName)
                dismiss()
            } catch {
                failure = error.localizedDescription
                isSaving = false
            }
        }
    }

    private func symbolAccessibilityLabel(_ symbol: String) -> String {
        switch symbol {
        case "folder":
            AppLanguage.localized("文件夹图标", english: "Folder icon")
        case "briefcase":
            AppLanguage.localized("公文包图标", english: "Briefcase icon")
        case "doc.text":
            AppLanguage.localized("文档图标", english: "Document icon")
        case "paintbrush":
            AppLanguage.localized("画笔图标", english: "Paintbrush icon")
        case "books.vertical":
            AppLanguage.localized("书籍图标", english: "Books icon")
        case "banknote":
            AppLanguage.localized("钞票图标", english: "Banknote icon")
        case "person":
            AppLanguage.localized("人物图标", english: "Person icon")
        case "archivebox":
            AppLanguage.localized("归档箱图标", english: "Archive box icon")
        case "building.2":
            AppLanguage.localized("建筑图标", english: "Buildings icon")
        case "star":
            AppLanguage.localized("星标图标", english: "Star icon")
        default:
            AppLanguage.localized("分类图标", english: "Category icon")
        }
    }
}
