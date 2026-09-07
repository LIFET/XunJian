import SwiftUI

struct AISearchSheet: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var isWorking = false
    @State private var failure: String?
    @State private var operationTask: Task<Void, Never>?
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        AISheetScaffold(
            title: AppLanguage.localized("AI 搜文件", english: "AI File Search"),
            subtitle: AppLanguage.localized(
                "你的描述会发给 AI，用来生成搜索条件。文件匹配在这台 Mac 上完成。",
                english: "Your description is sent to AI to create search filters. Files are matched on this Mac."
            ),
            idealWidth: 520,
            maxWidth: 560
        ) {
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
                ErrorMessageRow(message: failure)
            }
        } actions: {
            HStack {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                    Text(AppLanguage.localized("正在生成搜索条件…", english: "Creating search filters…"))
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
