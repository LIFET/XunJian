import SwiftUI

struct AIExplainSheet: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    let file: IndexedFile

    @State private var output = ""
    @State private var failure: String?
    @State private var operationTask: Task<Void, Never>?
    @State private var operationID = UUID()
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
                operationID = UUID()
                operationTask?.cancel()
                operationTask = nil
                isWorking = false
                hasStarted = false
            },
            dismiss: {
                operationID = UUID()
                operationTask?.cancel()
                dismiss()
            }
        )
        .onDisappear {
            operationID = UUID()
            operationTask?.cancel()
        }
    }

    private func startAnalysis() {
        guard !hasStarted else { return }
        output = ""
        failure = nil
        hasStarted = true
        isWorking = true
        let requestID = UUID()
        operationID = requestID
        operationTask = Task {
            do {
                let stream = try await appModel.explainWithAIStream(file)
                try await consumeAIStreamForDisplay(stream) { value in
                    guard operationID == requestID else { return }
                    output = value
                }
            } catch is CancellationError {
                guard operationID == requestID else { return }
                isWorking = false
                return
            } catch {
                guard operationID == requestID, !Task.isCancelled else { return }
                failure = error.localizedDescription
            }
            guard operationID == requestID else { return }
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
    @State private var operationID = UUID()
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        AISheetScaffold(
            title: AppLanguage.localized("AI 问文件", english: "Ask AI About File"),
            subtitle: file.name,
            idealWidth: 560,
            maxWidth: 620,
            minHeight: 420,
            idealHeight: 520,
            maxHeight: 620
        ) {
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

            conversationPanel
        } actions: {
            HStack {
                Spacer()
                Button(
                    AppLanguage.localized(
                        isWorking ? "停止" : "关闭",
                        english: isWorking ? "Stop" : "Close"
                    )
                ) {
                    if isWorking {
                        operationID = UUID()
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
        .onAppear { isFieldFocused = true }
        .onDisappear {
            operationID = UUID()
            operationTask?.cancel()
        }
    }

    private var conversationPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
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
                            if isWorking, !output.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(AppLanguage.localized("AI", english: "AI"))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text(verbatim: output)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if isWorking {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(AppLanguage.localized("正在生成回答…", english: "Generating an answer…"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                } else if isWorking {
                    Spacer(minLength: 0)
                    ProgressView(
                        AppLanguage.localized(
                            "正在读取文件并生成回答…",
                            english: "Reading the file and generating an answer…"
                        )
                    )
                    .frame(maxWidth: .infinity, alignment: .center)
                    Spacer(minLength: 0)
                } else {
                    ContentUnavailableView(
                        AppLanguage.localized("准备向 AI 提问", english: "Ready to Ask AI"),
                        systemImage: "bubble.left.and.text.bubble.right",
                        description: Text(AppLanguage.localized(
                            "仅会发送当前文件中回答问题所需的文本，不发送路径或其他文件。",
                            english: "Only the text needed to answer is sent from this file. Paths and other files are not."
                        ))
                    )
                }

                if let failure {
                    ErrorMessageRow(message: failure)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 220, maxHeight: .infinity, alignment: .topLeading)
    }

    private func ask() {
        guard !isWorking else { return }
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
        let requestID = UUID()
        operationID = requestID
        operationTask = Task {
            do {
                let stream = try await appModel.askAIStream(contextualQuestion, about: file)
                try await consumeAIStreamForDisplay(stream) { value in
                    guard operationID == requestID else { return }
                    output = value
                }
                guard operationID == requestID else { return }
                if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    turns.append(Turn(role: .assistant, text: output))
                }
            } catch is CancellationError {
                guard operationID == requestID else { return }
                isWorking = false
                return
            } catch {
                guard operationID == requestID, !Task.isCancelled else { return }
                failure = error.localizedDescription
            }
            guard operationID == requestID else { return }
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
        AISheetScaffold(
            title: title,
            subtitle: subtitle,
            idealWidth: 560,
            maxWidth: 620,
            minHeight: 420,
            idealHeight: 520,
            maxHeight: 620
        ) {
            resultPanel
        } actions: {
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
    }

    private var resultPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
            if !output.isEmpty {
                ScrollView {
                    Text(output)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if isWorking {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(AppLanguage.localized("正在生成分析…", english: "Generating analysis…"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            } else if isWorking {
                Spacer(minLength: 0)
                ProgressView(
                    AppLanguage.localized(
                        "正在读取并分析当前文件…",
                        english: "Reading and analyzing this file…"
                    )
                )
                .frame(maxWidth: .infinity, alignment: .center)
                Spacer(minLength: 0)
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
                Text(verbatim: AppLanguage.localized(
                    "没有可显示的回复内容。",
                    english: "No response content to show."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

                if let failure {
                    ErrorMessageRow(message: failure)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
