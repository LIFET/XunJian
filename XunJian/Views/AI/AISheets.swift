import SwiftUI
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AI 搜文件")
                .font(.title2.weight(.semibold))
            Text("AI 只理解你的描述并生成检索条件；文件候选筛选和结果匹配均在本地完成。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("例如：找我去年保存的合同", text: $query)
                .textFieldStyle(.roundedBorder)
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
                    Text("正在理解查找条件…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(
                    AppLanguage.localized(
                        isWorking ? "停止" : "取消",
                        english: isWorking ? "Stop" : "Cancel"
                    )
                ) { cancelAndDismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("查找", action: search)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        isWorking
                            || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
            }
        }
        .padding(24)
        .frame(minWidth: 320, idealWidth: 520, maxWidth: 560, alignment: .leading)
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

    private func cancelAndDismiss() {
        operationTask?.cancel()
        dismiss()
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

    var body: some View {
        AITextResultSheet(
            title: "AI 看文件",
            subtitle: file.name,
            output: output,
            failure: failure,
            isWorking: hasStarted && output.isEmpty && failure == nil,
            showsStart: !hasStarted,
            start: startAnalysis,
            dismiss: {
                operationTask?.cancel()
                dismiss()
            }
        )
        .onDisappear { operationTask?.cancel() }
    }

    private func startAnalysis() {
        guard !hasStarted else { return }
        hasStarted = true
        operationTask = Task {
            do {
                let result = try await appModel.explainWithAI(file)
                try Task.checkCancellation()
                output = result
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                failure = error.localizedDescription
            }
        }
    }
}

struct AIQuestionSheet: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    let file: IndexedFile

    @State private var question = ""
    @State private var output = ""
    @State private var failure: String?
    @State private var isWorking = false
    @State private var operationTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AI 问文件")
                .font(.title2.weight(.semibold))
            Text(file.name)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            TextField("例如：这个合同什么时候到期？", text: $question)
                .textFieldStyle(.roundedBorder)
                .onSubmit(ask)

            Group {
                if isWorking {
                    ProgressView("正在阅读当前文件…")
                } else if let failure {
                    Text(AppLanguage.localizedRuntimeMessage(failure))
                        .foregroundStyle(XunJianUI.Semantic.danger)
                } else if !output.isEmpty {
                    ScrollView {
                        Text(output)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Text("仅会发送当前文件中回答问题所需的文本，不发送路径或其他文件。")
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
                    operationTask?.cancel()
                    dismiss()
                }
                    .keyboardShortcut(.cancelAction)
                Button("提问", action: ask)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        isWorking
                            || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
            }
        }
        .padding(24)
        .frame(minWidth: 320, idealWidth: 560, maxWidth: 620, minHeight: 340, idealHeight: 380)
        .onDisappear { operationTask?.cancel() }
    }

    private func ask() {
        isWorking = true
        failure = nil
        output = ""
        operationTask?.cancel()
        operationTask = Task {
            do {
                let result = try await appModel.askAI(question, about: file)
                try Task.checkCancellation()
                output = result
            } catch is CancellationError {
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
    let title: LocalizedStringKey
    let subtitle: String
    let output: String
    let failure: String?
    let isWorking: Bool
    let showsStart: Bool
    let start: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Group {
                if isWorking {
                    ProgressView("正在读取必要文本…")
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
                    ScrollView {
                        Text(output)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
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
                Button("关闭", action: dismiss)
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
    @State private var operationTask: Task<Void, Never>?
    @State private var appliedChanges: [AIClassificationChange] = []
    @State private var showsAppliedConfirmation = false
    @State private var isCommittingChanges = false

    init(initialFileID: String?) {
        _selectedFileIDs = State(
            initialValue: initialFileID.map { [$0] } ?? []
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AI 分类")
                .font(.title2.weight(.semibold))
            Text("最多选择 8 个文件。AI 只会建议已有分类，确认后才写入本地索引。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if appModel.categories.isEmpty {
                ContentUnavailableView {
                    Label("还没有分类", systemImage: "square.grid.2x2")
                } description: {
                    Text(
                        verbatim: AppLanguage.localized(
                            "请先创建分类，再使用 AI 分类。",
                            english: "Create a category before using AI classification."
                        )
                    )
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
        .alert(
            AppLanguage.localized("分类已应用", english: "Classification Applied"),
            isPresented: $showsAppliedConfirmation
        ) {
            Button(
                AppLanguage.localized("撤销本次分类", english: "Undo Classification"),
                role: .destructive
            ) { undoAppliedChanges() }
            Button("完成") { dismiss() }
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
            TextField(
                AppLanguage.localized("搜索本地文件…", english: "Search local files…"),
                text: $fileSearchText
            )
                .textFieldStyle(.roundedBorder)
            List(filteredClassificationFiles) { file in
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
                .disabled(!selectedFileIDs.contains(file.id) && selectedFileIDs.count >= 8)
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
        }
    }

    private var filteredClassificationFiles: [IndexedFile] {
        let query = fileSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return appModel.files.sorted { lhs, rhs in
            let lhsSelected = selectedFileIDs.contains(lhs.id)
            let rhsSelected = selectedFileIDs.contains(rhs.id)
            if lhsSelected != rhsSelected { return lhsSelected }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }.filter { file in
            query.isEmpty || file.name.localizedCaseInsensitiveContains(query)
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
                    "已选择 \(selectedFileIDs.count) / 8",
                    english: "Selected \(selectedFileIDs.count) / 8"
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
                operationTask?.cancel()
                dismiss()
            }
                .keyboardShortcut(.cancelAction)
                .disabled(isCommittingChanges)
            if let suggestions {
                Button("确认应用") {
                    apply(suggestions)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking || suggestions.allSatisfy(\.categoryIDs.isEmpty))
            } else {
                Button("生成建议", action: classify)
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
                HStack {
                    Text(verbatim: suggestion.fileName)
                        .lineLimit(1)
                    Spacer()
                    if suggestion.categoryIDs.isEmpty {
                        Text("不建议分类")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(verbatim: displayNames.joined(separator: " / "))
                            .foregroundStyle(.secondary)
                    }
                    Button(
                        AppLanguage.localized("移除此建议", english: "Remove Suggestion")
                    ) {
                        self.suggestions?.removeAll { $0.id == suggestion.id }
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .listStyle(.bordered(alternatesRowBackgrounds: true))
    }

    private func toggle(_ fileID: String) {
        if selectedFileIDs.contains(fileID) {
            selectedFileIDs.remove(fileID)
        } else if selectedFileIDs.count < 8 {
            selectedFileIDs.insert(fileID)
        }
    }

    private func classify() {
        let selectedFiles = appModel.files.filter { selectedFileIDs.contains($0.id) }
        isWorking = true
        failure = nil
        operationTask?.cancel()
        operationTask = Task {
            do {
                let result = try await appModel.classifyWithAI(selectedFiles)
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
