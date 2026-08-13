import SwiftUI

extension Notification.Name {
    static let xunJianShowTextPreview = Notification.Name(
        "com.xingmingbo.XunJian.showTextPreview"
    )
}

/// In-app preview of a file's extracted text with match highlighting (N10).
///
/// The text is already in the index, so confirming "is this the document I
/// meant?" should not require opening another application. Content is read
/// on demand by file ID and never held after the sheet closes.
struct TextPreviewView: View {
    let file: IndexedFile
    /// Seeded from the active search so the term the user searched for is
    /// already highlighted when the preview opens.
    let initialQuery: String

    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var chunks: [TextChunk] = []
    @State private var loadState = LoadState.loading
    @State private var query = ""
    @State private var matches: [Match] = []
    @State private var currentMatch = 0

    private enum LoadState: Equatable {
        case loading
        case ready
        case empty
        case failed(String)
    }

    struct TextChunk: Identifiable, Equatable {
        let id: Int
        let text: String
    }

    struct Match: Equatable {
        let chunkID: Int
        let range: Range<String.Index>
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 520, idealWidth: 720, minHeight: 420, idealHeight: 680)
        .task { await load() }
        .onChange(of: query) { _, newValue in
            recomputeMatches(for: newValue)
        }
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: file.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    Text(verbatim: file.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Button(AppLanguage.localized("打开文件", english: "Open File")) {
                    appModel.open(file)
                }
                Button(AppLanguage.localized("完成", english: "Done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            if loadState == .ready {
                findBar
            }
        }
        .padding(XunJianUI.Spacing.page)
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField(
                "",
                text: $query,
                prompt: Text(verbatim: AppLanguage.localized(
                    "在正文中查找…",
                    english: "Find in text…"
                ))
            )
            .textFieldStyle(.plain)
            .onSubmit { moveMatch(by: 1) }
            .accessibilityLabel(Text(verbatim: AppLanguage.localized(
                "在正文中查找",
                english: "Find in Text"
            )))

            if !query.isEmpty {
                Text(verbatim: matchSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Button {
                    moveMatch(by: -1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(matches.isEmpty)
                .accessibilityLabel(Text(verbatim: AppLanguage.localized(
                    "上一处",
                    english: "Previous Match"
                )))

                Button {
                    moveMatch(by: 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(matches.isEmpty)
                .accessibilityLabel(Text(verbatim: AppLanguage.localized(
                    "下一处",
                    english: "Next Match"
                )))
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            XunJianUI.Fill.quiet,
            in: RoundedRectangle(cornerRadius: XunJianUI.Radius.control, style: .continuous)
        )
    }

    private var matchSummary: String {
        guard !matches.isEmpty else {
            return AppLanguage.localized("无结果", english: "No results")
        }
        return "\(currentMatch + 1)/\(matches.count)"
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(Text(verbatim: AppLanguage.localized(
                    "正在载入正文",
                    english: "Loading text"
                )))

        case .empty:
            ContentUnavailableView(
                AppLanguage.localized("没有可预览的正文", english: "No Text to Preview"),
                systemImage: "doc.text.magnifyingglass",
                description: Text(verbatim: AppLanguage.localized(
                    "这个文件没有可提取的文本内容，可以直接打开或用快速查看。",
                    english: "No extractable text for this file. Open it or use Quick Look instead."
                ))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case let .failed(message):
            ContentUnavailableView {
                Label(
                    AppLanguage.localized("无法载入正文", english: "Could Not Load Text"),
                    systemImage: "exclamationmark.triangle"
                )
            } description: {
                Text(AppLanguage.localizedRuntimeMessage(message))
            } actions: {
                Button(AppLanguage.localized("重试", english: "Retry")) {
                    Task { await load() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .ready:
            textBody
        }
    }

    /// Rendered as lazily-loaded chunks rather than one `Text`: the index
    /// stores up to 200k characters, which is far too much for a single
    /// attributed string to lay out smoothly.
    private var textBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(chunks) { chunk in
                        Text(attributed(chunk))
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(chunk.id)
                    }
                }
                .padding(XunJianUI.Spacing.page)
            }
            .onChange(of: currentMatch) { _, index in
                guard matches.indices.contains(index) else { return }
                proxy.scrollTo(matches[index].chunkID, anchor: .center)
            }
        }
    }

    private func attributed(_ chunk: TextChunk) -> AttributedString {
        var result = AttributedString(chunk.text)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return result }

        let activeChunkID = matches.indices.contains(currentMatch)
            ? matches[currentMatch].chunkID
            : nil

        for range in Self.ranges(of: trimmed, in: chunk.text) {
            guard let attributedRange = Range(range, in: result) else { continue }
            // The chunk holding the current match gets a stronger tint so the
            // user can tell where "next match" landed.
            result[attributedRange].backgroundColor = chunk.id == activeChunkID
                ? Color.accentColor.opacity(0.45)
                : Color.accentColor.opacity(0.18)
        }
        return result
    }

    // MARK: - Loading and matching

    private func load() async {
        loadState = .loading
        do {
            let text = try await appModel.fetchTextContent(forFileID: file.id)
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                chunks = []
                loadState = .empty
                return
            }
            chunks = Self.chunk(text)
            loadState = .ready
            query = initialQuery
            recomputeMatches(for: initialQuery)
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    private func recomputeMatches(for rawQuery: String) {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            matches = []
            currentMatch = 0
            return
        }
        matches = chunks.flatMap { chunk in
            Self.ranges(of: trimmed, in: chunk.text).map {
                Match(chunkID: chunk.id, range: $0)
            }
        }
        currentMatch = 0
    }

    private func moveMatch(by offset: Int) {
        guard !matches.isEmpty else { return }
        currentMatch = (currentMatch + offset + matches.count) % matches.count
    }

    static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let found = text.range(
                  of: query,
                  options: [.caseInsensitive, .diacriticInsensitive],
                  range: searchStart..<text.endIndex
              ) {
            result.append(found)
            searchStart = found.upperBound
        }
        return result
    }

    /// Splits on newlines, then hard-wraps very long lines so a file with no
    /// line breaks still produces multiple chunks instead of one huge view.
    static func chunk(_ text: String, maximumChunkLength: Int = 2_000) -> [TextChunk] {
        var result: [TextChunk] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var remainder = Substring(line)
            repeat {
                let slice = remainder.prefix(maximumChunkLength)
                result.append(TextChunk(id: result.count, text: String(slice)))
                remainder = remainder.dropFirst(slice.count)
            } while !remainder.isEmpty
        }
        return result
    }
}
