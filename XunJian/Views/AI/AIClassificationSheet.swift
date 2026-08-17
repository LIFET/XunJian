import SwiftUI

struct AIClassificationSheet: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedFileIDs: Set<String>
    @State private var suggestions: [AIClassificationSuggestion]?
    @State private var isWorking = false
    @State private var failure: String?
    @State private var fileSearchText = ""
    @State private var includesFileContent = false
    @State private var operationTask: Task<Void, Never>?
    @State private var appliedChanges: [AIClassificationChange] = []
    @State private var showsAppliedConfirmation = false
    @State private var isCommittingChanges = false
    @State private var showsCategoryEditor = false
    @State private var isFileSearchFocused = false
    /// Name-sorted copy of the index, rebuilt off the main actor only when
    /// the file set changes.
    @State private var nameSortedFilesCache: [IndexedFile] = []
    @State private var nameSortedFilesRevision: UInt64 = 0
    /// The list the picker renders, computed asynchronously so body
    /// evaluation stays O(1) even at six-figure index sizes.
    @State private var displayedClassificationFiles: [IndexedFile] = []

    init(initialFileID: String?) {
        _selectedFileIDs = State(
            initialValue: initialFileID.map { [$0] } ?? []
        )
    }

    /// Everything the displayed list depends on, hashed so `.task(id:)`
    /// restarts the computation (and cancels the previous one) only when
    /// one of them actually changes.
    private var classificationListKey: Int {
        var hasher = Hasher()
        hasher.combine(appModel.filesRevision)
        hasher.combine(fileSearchText.trimmingCharacters(in: .whitespacesAndNewlines))
        hasher.combine(selectedFileIDs)
        return hasher.finalize()
    }

    private func refreshDisplayedClassificationFiles() async {
        // The task restarts per keystroke, so this sleep is the debounce.
        try? await Task.sleep(for: .milliseconds(60))
        guard !Task.isCancelled else { return }
        let query = fileSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = selectedFileIDs
        let revision = appModel.filesRevision
        let cachedRevision = nameSortedFilesRevision
        let cachedFiles = nameSortedFilesCache
        let sourceFiles = appModel.files
        let cancellationFlag = QuickSearchCancellationFlag()
        let computed = await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                let base = cachedRevision == revision
                    ? cachedFiles
                    : sourceFiles.sorted {
                            $0.name.localizedStandardCompare($1.name) == .orderedAscending
                        }
                let filtered = query.isEmpty
                    ? base
                    : base.filter { $0.name.localizedCaseInsensitiveContains(query) }
                guard !cancellationFlag.isCancelled else {
                    return (base: base, displayed: [IndexedFile]())
                }
                let selectedFiles = filtered.filter { selected.contains($0.id) }
                let unselected = filtered.filter { !selected.contains($0.id) }
                return (base: base, displayed: selectedFiles + unselected)
            }.value
        } onCancel: {
            cancellationFlag.cancel()
        }
        guard !Task.isCancelled, appModel.filesRevision == revision else { return }
        nameSortedFilesRevision = revision
        nameSortedFilesCache = computed.base
        displayedClassificationFiles = computed.displayed
    }

    var body: some View {
        AISheetScaffold(
            title: AppLanguage.localized("AI 分类", english: "AI Classify"),
            subtitle: AppLanguage.localized(
                "最多选择 50 个文件。AI 会分批给出带依据的建议；你可以逐项编辑，确认后才写入本地索引。",
                english: "Choose up to 50 files. AI suggests in bounded batches with reasons; edit each result before applying it."
            ),
            minWidth: 340,
            idealWidth: 620,
            maxWidth: 680,
            minHeight: 420,
            idealHeight: 500
        ) {
            if appModel.categories.isEmpty {
                ContentUnavailableView {
                    Label(
                        AppLanguage.localized("还没有分类", english: "No Categories Yet"),
                        systemImage: "square.grid.2x2"
                    )
                } description: {
                    Text(
                        verbatim: AppLanguage.localized(
                            "请先创建分类，再使用 AI 分类。",
                            english: "Create a category before using AI classification."
                        )
                    )
                } actions: {
                    Button(
                        AppLanguage.localized(
                            "新建分类…",
                            english: "New Category…"
                        )
                    ) {
                        showsCategoryEditor = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if let suggestions {
                suggestionList(suggestions)
            } else {
                selectionList
            }

            if let failure {
                ErrorMessageRow(message: failure)
            }
        } actions: {
            classificationFooter
        }
        .interactiveDismissDisabled(isCommittingChanges)
        .onDisappear {
            if !isCommittingChanges { operationTask?.cancel() }
        }
        .onAppear {
            let indexedIDs = Set(appModel.files(ids: selectedFileIDs).map(\.id))
            selectedFileIDs.formIntersection(indexedIDs)
        }
        .task(id: classificationListKey) {
            await refreshDisplayedClassificationFiles()
        }
        .sheet(isPresented: $showsCategoryEditor) {
            CategoryEditorSheet(
                title: AppLanguage.localized("新建分类", english: "New Category")
            ) { name, symbolName in
                try await appModel.createCategory(name: name, symbolName: symbolName)
            }
        }
        .alert(
            AppLanguage.localized("分类已应用", english: "Classification Applied"),
            isPresented: $showsAppliedConfirmation
        ) {
            Button(
                AppLanguage.localized("撤销本次分类", english: "Undo Classification"),
                role: .destructive
            ) { undoAppliedChanges() }
            Button(AppLanguage.localized("完成", english: "Done")) { dismiss() }
        } message: {
            Text(
                verbatim: AppLanguage.localized(
                    "已新增 \(appliedChanges.count) 个分类关联。",
                    english: "Added \(appliedChanges.count) category associations."
                )
            )
        }
    }

    private var selectionList: some View {
        VStack(spacing: 10) {
            Toggle(
                AppLanguage.localized(
                    "允许发送可提取正文（默认仅文件名和类型）",
                    english: "Include extractable content (name and type only by default)"
                ),
                isOn: $includesFileContent
            )
            .toggleStyle(.switch)
            .frame(maxWidth: .infinity, alignment: .leading)
            NativeSearchField(
                text: $fileSearchText,
                isFocused: $isFileSearchFocused,
                prompt: AppLanguage.localized("搜索本地文件…", english: "Search local files…"),
                accessibilityLabel: AppLanguage.localized("搜索本地文件", english: "Search Local Files"),
                accessibilityHelp: AppLanguage.localized(
                    "筛选可供 AI 分类的本地文件",
                    english: "Filters local files available for AI classification"
                ),
                onSubmit: { _ in },
                onCancel: {
                    if fileSearchText.isEmpty {
                        isFileSearchFocused = false
                    } else {
                        fileSearchText = ""
                    }
                }
            )
            .frame(height: XunJianUI.Size.compactControlHeight)
            HStack {
                Spacer(minLength: 0)
                Button(
                    allDisplayedFilesSelected
                        ? AppLanguage.localized("取消全选", english: "Deselect All")
                        : AppLanguage.localized("全选（最多 50 个）", english: "Select All (Up to 50)")
                ) {
                    toggleAllDisplayedFiles()
                }
                .buttonStyle(.link)
                .disabled(displayedClassificationFiles.isEmpty)
            }
            List(selection: classificationSelection) {
                ForEach(displayedClassificationFiles) { file in
                    HStack {
                        Text(file.name)
                            .lineLimit(1)
                            .help(file.name)
                        Spacer()
                        Text(file.kind.localizedTitle)
                            .foregroundStyle(.secondary)
                    }
                    .tag(file.id)
                    .disabled(!selectedFileIDs.contains(file.id) && selectedFileIDs.count >= 50)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
        }
    }

    private var classificationFooter: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                classificationStatus
                Spacer(minLength: 8)
                classificationActions
            }

            VStack(alignment: .leading, spacing: 10) {
                classificationStatus
                HStack {
                    Spacer(minLength: 0)
                    classificationActions
                }
            }
        }
    }

    private var classificationStatus: some View {
        HStack(spacing: 8) {
            if isWorking {
                ProgressView()
                    .controlSize(.small)
            }
            Text(
                AppLanguage.localized(
                    "已选择 \(selectedFileIDs.count) / 50",
                    english: "Selected \(selectedFileIDs.count) / 50"
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var classificationActions: some View {
        HStack(spacing: 8) {
            Button(
                AppLanguage.localized(
                    isWorking && !isCommittingChanges ? "停止" : "取消",
                    english: isWorking && !isCommittingChanges ? "Stop" : "Cancel"
                )
            ) {
                if isWorking && !isCommittingChanges {
                    operationTask?.cancel()
                    operationTask = nil
                    isWorking = false
                } else {
                    dismiss()
                }
            }
                .keyboardShortcut(.cancelAction)
                .disabled(isCommittingChanges)
            if let suggestions {
                Button(AppLanguage.localized("确认应用", english: "Apply")) {
                    apply(suggestions)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking || suggestions.allSatisfy(\.categoryIDs.isEmpty))
            } else {
                Button(AppLanguage.localized("生成建议", english: "Suggest"), action: classify)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || selectedFileIDs.isEmpty)
            }
        }
    }

    private func suggestionList(_ suggestions: [AIClassificationSuggestion]) -> some View {
        List {
            ForEach(suggestions) { suggestion in
            let localizedNames = suggestion.categoryIDs.compactMap { categoryID in
                appModel.categories.first(where: { $0.id == categoryID })?.localizedDisplayName
            }
            let displayNames = localizedNames.isEmpty
                ? suggestion.categoryNames
                : localizedNames
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(verbatim: suggestion.fileName)
                            .lineLimit(1)
                        Spacer()
                        Text(verbatim: "\(Int((suggestion.confidence * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(
                        suggestion.categoryIDs.isEmpty
                            ? AppLanguage.localized("不建议分类", english: "No category suggested")
                            : displayNames.joined(separator: " / ")
                    )
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    if !suggestion.reason.isEmpty {
                        Text(verbatim: suggestion.reason)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                    HStack(spacing: 12) {
                        Menu(AppLanguage.localized("编辑分类…", english: "Edit Categories…")) {
                            ForEach(appModel.categories) { category in
                                Button {
                                    toggleCategory(category, for: suggestion.id)
                                } label: {
                                    Label(
                                        category.localizedDisplayName,
                                        systemImage: suggestion.categoryIDs.contains(category.id)
                                            ? "checkmark" : category.symbolName
                                    )
                                }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        Button(
                            AppLanguage.localized("跳过", english: "Skip")
                        ) {
                            self.suggestions?.removeAll { $0.id == suggestion.id }
                        }
                        .buttonStyle(.link)
                    }
                }
            }
        }
        .listStyle(.bordered(alternatesRowBackgrounds: true))
    }

    private var classificationSelection: Binding<Set<String>> {
        Binding(
            get: { selectedFileIDs },
            set: { proposed in
                guard proposed.count > 50 else {
                    selectedFileIDs = proposed
                    return
                }
                let additions = proposed.subtracting(selectedFileIDs)
                let capacity = max(50 - selectedFileIDs.count, 0)
                selectedFileIDs.formUnion(additions.prefix(capacity))
            }
        )
    }

    private var allDisplayedFilesSelected: Bool {
        let visibleIDs = displayedClassificationFiles.prefix(50).map(\.id)
        return !visibleIDs.isEmpty && visibleIDs.allSatisfy(selectedFileIDs.contains)
    }

    private func toggleAllDisplayedFiles() {
        if allDisplayedFilesSelected {
            selectedFileIDs.removeAll()
        } else {
            selectedFileIDs = Set(displayedClassificationFiles.prefix(50).map(\.id))
        }
    }

    private func toggleCategory(_ category: FileCategory, for suggestionID: String) {
        guard let index = suggestions?.firstIndex(where: { $0.id == suggestionID }) else { return }
        if suggestions![index].categoryIDs.contains(category.id) {
            suggestions![index].categoryIDs.removeAll { $0 == category.id }
            suggestions![index].categoryNames.removeAll { $0 == category.name }
        } else if suggestions![index].categoryIDs.count < 3 {
            suggestions![index].categoryIDs.append(category.id)
            suggestions![index].categoryNames.append(category.name)
        }
    }

    private func classify() {
        let selectedFiles = appModel.files(ids: selectedFileIDs)
        isWorking = true
        failure = nil
        operationTask?.cancel()
        operationTask = Task {
            do {
                let result = try await appModel.classifyWithAI(
                    selectedFiles,
                    includesFileContent: includesFileContent
                )
                try Task.checkCancellation()
                suggestions = result
            } catch is CancellationError {
                isWorking = false
                return
            } catch {
                guard !Task.isCancelled else { return }
                failure = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func apply(_ suggestions: [AIClassificationSuggestion]) {
        isWorking = true
        isCommittingChanges = true
        failure = nil
        operationTask?.cancel()
        operationTask = Task {
            do {
                let changes = try await appModel.applyAIClassification(suggestions)
                appliedChanges = changes
                isWorking = false
                isCommittingChanges = false
                showsAppliedConfirmation = true
            } catch is CancellationError {
                isWorking = false
                isCommittingChanges = false
                return
            } catch {
                guard !Task.isCancelled else { return }
                failure = error.localizedDescription
                isWorking = false
                isCommittingChanges = false
            }
        }
    }

    private func undoAppliedChanges() {
        isCommittingChanges = true
        operationTask?.cancel()
        operationTask = Task {
            do {
                try await appModel.undoAIClassification(appliedChanges)
                isCommittingChanges = false
                dismiss()
            } catch is CancellationError {
                isCommittingChanges = false
                return
            } catch {
                guard !Task.isCancelled else { return }
                failure = error.localizedDescription
                showsAppliedConfirmation = false
                isCommittingChanges = false
            }
        }
    }
}
