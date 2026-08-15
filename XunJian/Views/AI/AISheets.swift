import SwiftUI

@MainActor
private func consumeAIStreamForDisplay(
    _ stream: AsyncThrowingStream<String, any Error>,
    update: (String) -> Void
) async throws {
    let clock = ContinuousClock()
    var lastUpdate = clock.now
    var rendered = ""
    var pending = ""

    for try await chunk in stream {
        try Task.checkCancellation()
        pending += chunk
        let now = clock.now
        guard lastUpdate.duration(to: now) >= .milliseconds(50) else { continue }
        rendered += pending
        pending.removeAll(keepingCapacity: true)
        update(rendered)
        lastUpdate = now
    }
    if !pending.isEmpty {
        rendered += pending
        update(rendered)
    }
}
enum AITaskSheet: Identifiable {
    case search
    case explain(IndexedFile)
    case ask(IndexedFile)
    case classify

    var id: String {
        switch self {
        case .search: "search"
        case let .explain(file): "explain-\(file.id)"
        case let .ask(file): "ask-\(file.id)"
        case .classify: "classify"
        }
    }
}

struct AISearchSheet: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var isWorking = false
    @State private var failure: String?
    @State private var operationTask: Task<Void, Never>?
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(AppLanguage.localized("AI 搜文件", english: "AI File Search"))
                .font(.title2.weight(.semibold))
            Text(
                AppLanguage.localized(
                    "AI 只理解你的描述并生成检索条件；文件候选筛选和结果匹配均在本地完成。",
                    english: "AI only understands your description and turns it into search criteria. Matching files stays on this Mac."
                )
            )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField(
                AppLanguage.localized(
                    "例如：找我去年保存的合同",
                    english: "e.g. contracts I saved last year"
                ),
                text: $query
            )
                .textFieldStyle(.roundedBorder)
                .focused($isFieldFocused)
                .onSubmit(search)

            if let failure {
                Text(AppLanguage.localizedRuntimeMessage(failure))
                    .font(.caption)
                    .foregroundStyle(XunJianUI.Semantic.danger)
            }

            HStack {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                    Text(AppLanguage.localized("正在理解查找条件…", english: "Understanding the search…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(
                    AppLanguage.localized(
                        isWorking ? "停止" : "取消",
                        english: isWorking ? "Stop" : "Cancel"
                    )
                ) {
                    if isWorking {
                        operationTask?.cancel()
                        isWorking = false
                    } else {
                        dismiss()
                    }
                }
                    .keyboardShortcut(.cancelAction)
                Button(AppLanguage.localized("查找", english: "Search"), action: search)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        isWorking
                            || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
            }
        }
        .padding(24)
        .frame(minWidth: 320, idealWidth: 520, maxWidth: 560, alignment: .leading)
        .onAppear { isFieldFocused = true }
        .onDisappear { operationTask?.cancel() }
    }

    private func search() {
        isWorking = true
        failure = nil
        operationTask?.cancel()
        operationTask = Task {
            do {
                try await appModel.performAISearch(query)
                try Task.checkCancellation()
                dismiss()
            } catch is CancellationError {
                isWorking = false
                return
            } catch {
                guard !Task.isCancelled else { return }
                failure = error.localizedDescription
                isWorking = false
            }
        }
    }

}

struct AIExplainSheet: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    let file: IndexedFile

    @State private var output = ""
    @State private var failure: String?
    @State private var operationTask: Task<Void, Never>?
    @State private var hasStarted = false
    @State private var isWorking = false

    var body: some View {
        AITextResultSheet(
            title: AppLanguage.localized("AI 看文件", english: "AI Explain File"),
            subtitle: file.name,
            output: output,
            failure: failure,
            isWorking: isWorking,
            showsStart: !hasStarted,
            start: startAnalysis,
            stop: {
                operationTask?.cancel()
                operationTask = nil
                isWorking = false
                hasStarted = false
            },
            dismiss: {
                operationTask?.cancel()
                dismiss()
            }
        )
        .onDisappear { operationTask?.cancel() }
    }

    private func startAnalysis() {
        guard !hasStarted else { return }
        output = ""
        failure = nil
        hasStarted = true
        isWorking = true
        operationTask = Task {
            do {
                let stream = try await appModel.explainWithAIStream(file)
                try await consumeAIStreamForDisplay(stream) { output = $0 }
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
}

struct AIQuestionSheet: View {
    private struct Turn: Identifiable {
        enum Role { case user, assistant }
        let id = UUID()
        let role: Role
        let text: String
    }

    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    let file: IndexedFile

    @State private var question = ""
    @State private var output = ""
    @State private var turns: [Turn] = []
    @State private var failure: String?
    @State private var isWorking = false
    @State private var operationTask: Task<Void, Never>?
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(AppLanguage.localized("AI 问文件", english: "Ask AI About File"))
                .font(.title2.weight(.semibold))
            Text(file.name)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            TextField(
                AppLanguage.localized(
                    "例如：这个合同什么时候到期？",
                    english: "e.g. When does this contract expire?"
                ),
                text: $question
            )
                .textFieldStyle(.roundedBorder)
                .focused($isFieldFocused)
                .onSubmit(ask)

            Group {
                if !turns.isEmpty || !output.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(turns) { turn in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(turn.role == .user
                                         ? AppLanguage.localized("你", english: "You")
                                         : AppLanguage.localized("AI", english: "AI"))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text(verbatim: turn.text)
                                        .textSelection(.enabled)
                                }
                            }
                            if isWorking {
                                Text(verbatim: output)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if isWorking {
                        ProgressView()
                            .controlSize(.small)
                    }
                    if let failure {
                        Text(AppLanguage.localizedRuntimeMessage(failure))
                            .foregroundStyle(XunJianUI.Semantic.danger)
                    }
                } else if isWorking {
                    ProgressView(
                        AppLanguage.localized(
                            "正在阅读当前文件…",
                            english: "Reading this file…"
                        )
                    )
                } else if let failure {
                    Text(AppLanguage.localizedRuntimeMessage(failure))
                        .foregroundStyle(XunJianUI.Semantic.danger)
                } else {
                    Text(
                        AppLanguage.localized(
                            "仅会发送当前文件中回答问题所需的文本，不发送路径或其他文件。",
                            english: "Only the text needed to answer is sent from this file. Paths and other files are not."
                        )
                    )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
            .background(
                XunJianUI.Fill.quiet,
                in: RoundedRectangle(cornerRadius: XunJianUI.Radius.card, style: .continuous)
            )

            HStack {
                Spacer()
                Button(
                    AppLanguage.localized(
                        isWorking ? "停止" : "关闭",
                        english: isWorking ? "Stop" : "Close"
                    )
                ) {
                    if isWorking {
                        operationTask?.cancel()
                        operationTask = nil
                        isWorking = false
                    } else {
                        dismiss()
                    }
                }
                    .keyboardShortcut(.cancelAction)
                Button(AppLanguage.localized("提问", english: "Ask"), action: ask)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        isWorking
                            || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
            }
        }
        .padding(24)
        .frame(minWidth: 320, idealWidth: 560, maxWidth: 620, minHeight: 340, idealHeight: 380)
        .onAppear { isFieldFocused = true }
        .onDisappear { operationTask?.cancel() }
    }

    private func ask() {
        let submittedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submittedQuestion.isEmpty else { return }
        let history = turns.suffix(6).map { turn in
            let role = turn.role == .user ? "User" : "Assistant"
            return "\(role): \(turn.text)"
        }.joined(separator: "\n")
        let contextualQuestion = history.isEmpty
            ? submittedQuestion
            : "Previous conversation:\n\(history)\n\nCurrent question: \(submittedQuestion)"
        turns.append(Turn(role: .user, text: submittedQuestion))
        question = ""
        isWorking = true
        failure = nil
        output = ""
        operationTask?.cancel()
        operationTask = Task {
            do {
                let stream = try await appModel.askAIStream(contextualQuestion, about: file)
                try await consumeAIStreamForDisplay(stream) { output = $0 }
                if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    turns.append(Turn(role: .assistant, text: output))
                }
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
}

struct AITextResultSheet: View {
    let title: String
    let subtitle: String
    let output: String
    let failure: String?
    let isWorking: Bool
    let showsStart: Bool
    let start: () -> Void
    let stop: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: title)
                .font(.title2.weight(.semibold))
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Group {
                if !output.isEmpty {
                    ScrollView {
                        Text(output)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if isWorking {
                        ProgressView()
                            .controlSize(.small)
                    }
                    if let failure {
                        Text(AppLanguage.localizedRuntimeMessage(failure))
                            .foregroundStyle(XunJianUI.Semantic.danger)
                    }
                } else if isWorking {
                    ProgressView(
                        AppLanguage.localized(
                            "正在读取必要文本…",
                            english: "Reading the necessary text…"
                        )
                    )
                } else if let failure {
                    Text(AppLanguage.localizedRuntimeMessage(failure))
                        .foregroundStyle(XunJianUI.Semantic.danger)
                } else if showsStart {
                    ContentUnavailableView(
                        AppLanguage.localized("准备分析当前文件", english: "Ready to Analyze This File"),
                        systemImage: "sparkles",
                        description: Text(
                            AppLanguage.localized(
                                "确认后才会读取必要文本并发起 AI 请求。",
                                english: "Necessary text is read and sent to AI only after you confirm."
                            )
                        )
                    )
                } else {
                    // Stream finished without producing content: show an
                    // explicit state instead of an empty scroll box.
                    Text(verbatim: AppLanguage.localized(
                        "没有可显示的回复内容。",
                        english: "No response content to show."
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .topLeading
                        )
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                XunJianUI.Fill.quiet,
                in: RoundedRectangle(cornerRadius: XunJianUI.Radius.card, style: .continuous)
            )

            HStack {
                Spacer()
                Button(
                    AppLanguage.localized(
                        isWorking ? "停止" : "关闭",
                        english: isWorking ? "Stop" : "Close"
                    ),
                    action: isWorking ? stop : dismiss
                )
                    .keyboardShortcut(.cancelAction)
                if showsStart {
                    Button(
                        AppLanguage.localized("开始分析", english: "Start Analysis"),
                        action: start
                    )
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 320, idealWidth: 560, maxWidth: 620, minHeight: 340, idealHeight: 380)
    }
}

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
        return VStack(alignment: .leading, spacing: 16) {
            Text(AppLanguage.localized("AI 分类", english: "AI Classify"))
                .font(.title2.weight(.semibold))
            Text(
                AppLanguage.localized(
                    "最多选择 50 个文件。AI 会分批给出带依据的建议；你可以逐项编辑，确认后才写入本地索引。",
                    english: "Choose up to 50 files. AI suggests in bounded batches with reasons; edit each result before applying it."
                )
            )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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
                Text(AppLanguage.localizedRuntimeMessage(failure))
                    .font(.caption)
                    .foregroundStyle(XunJianUI.Semantic.danger)
            }

            classificationFooter
        }
        .padding(24)
        .frame(minWidth: 340, idealWidth: 620, maxWidth: 680, minHeight: 420, idealHeight: 500)
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
            TextField(
                AppLanguage.localized("搜索本地文件…", english: "Search local files…"),
                text: $fileSearchText
            )
                .textFieldStyle(.roundedBorder)
            List(displayedClassificationFiles) { file in
                Button {
                    toggle(file.id)
                } label: {
                    HStack {
                        Image(
                            systemName: selectedFileIDs.contains(file.id)
                                ? "checkmark.circle.fill" : "circle"
                        )
                        .foregroundStyle(
                            selectedFileIDs.contains(file.id) ? Color.accentColor : .secondary
                        )
                        Text(file.name)
                            .lineLimit(1)
                        Spacer()
                        Text(file.kind.localizedTitle)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .disabled(!selectedFileIDs.contains(file.id) && selectedFileIDs.count >= 50)
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

    private func toggle(_ fileID: String) {
        if selectedFileIDs.contains(fileID) {
            selectedFileIDs.remove(fileID)
        } else if selectedFileIDs.count < 50 {
            selectedFileIDs.insert(fileID)
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

/// Shared file context menu used by All Files, Categories, and Home.
