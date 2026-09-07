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
    /// Precomputed per-chunk ranges for the current query so `attributed` can
    /// highlight without re-scanning the text on every render.
    @State private var chunkMatchRanges: [Int: [Range<String.Index>]] = [:]
    @State private var currentMatch = 0
    @State private var matchTask: Task<Void, Never>?
    @State private var isSearchFocused = false

    private enum LoadState: Equatable {
        case loading
        case ready
        case empty
        case failed(String)
    }

    struct TextChunk: Identifiable, Equatable, Sendable {
        let id: Int
        let text: String
        let startOffset: Int
    }

    struct MatchSegment: Equatable, Sendable {
        let chunkID: Int
        let range: Range<String.Index>
    }

    struct Match: Equatable, Sendable {
        let segments: [MatchSegment]

        var chunkID: Int { segments.first?.chunkID ?? 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 340, idealWidth: 720, minHeight: 420, idealHeight: 680)
        .task { await load() }
        .onChange(of: query) { _, newValue in
            scheduleMatchComputation(for: newValue)
        }
        .onDisappear { matchTask?.cancel() }
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    previewIdentity
                    Spacer(minLength: 0)
                    previewActions
                }

                VStack(alignment: .leading, spacing: 8) {
                    previewIdentity
                    HStack(spacing: 8) { previewActions }
                }
            }

            if loadState == .ready {
                findBar
            }
        }
        .padding(XunJianUI.Spacing.page)
        .controlSize(.large)
    }

    private var previewIdentity: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: file.name)
                .font(.system(size: 22, weight: .semibold))
                .lineLimit(2)
            Text(verbatim: file.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private var previewActions: some View {
        Button(AppLanguage.localized("打开文件", english: "Open File")) {
            appModel.open(file)
        }
        Button(AppLanguage.localized("完成", english: "Done")) { dismiss() }
            .keyboardShortcut(.defaultAction)
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            NativeSearchField(
                text: $query,
                isFocused: $isSearchFocused,
                prompt: AppLanguage.localized(
                    "在正文中查找…",
                    english: "Find in text…"
                ),
                accessibilityLabel: AppLanguage.localized(
                    "在正文中查找",
                    english: "Find in Text"
                ),
                accessibilityHelp: AppLanguage.localized(
                    "在提取的正文中查找匹配内容",
                    english: "Finds matching text in the extracted content"
                ),
                onSubmit: { _ in moveMatch(by: 1) },
                onCancel: {
                    if query.isEmpty {
                        isSearchFocused = false
                    } else {
                        query = ""
                    }
                }
            )
            .frame(height: 36)

            if !query.isEmpty {
                Text(verbatim: matchSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                ControlGroup {
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
        }
        .controlSize(.small)
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
        // Ranges are precomputed once per query (see scheduleMatchComputation);
        // re-scanning every visible chunk here on every render made match
        // navigation re-run the case-insensitive search over the whole text.
        guard let ranges = chunkMatchRanges[chunk.id], !ranges.isEmpty else {
            return result
        }

        let activeMatch = matches.indices.contains(currentMatch)
            ? matches[currentMatch]
            : nil

        for range in ranges {
            guard let attributedRange = Range(range, in: result) else { continue }
            result[attributedRange].backgroundColor = activeMatch.map {
                Self.isActive(chunkID: chunk.id, range: range, currentMatch: $0)
            } == true
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
            try Task.checkCancellation()
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                chunks = []
                loadState = .empty
                return
            }
            chunks = Self.chunk(text)
            loadState = .ready
            query = initialQuery
        } catch is CancellationError {
            return
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    private func scheduleMatchComputation(for rawQuery: String) {
        matchTask?.cancel()
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            matches = []
            chunkMatchRanges = [:]
            currentMatch = 0
            return
        }
        let chunkSnapshot = chunks
        matchTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(80))
                let worker = Task.detached(priority: .userInitiated) {
                    Self.matchesWithRanges(for: trimmed, in: chunkSnapshot)
                }
                let computed = await withTaskCancellationHandler {
                    await worker.value
                } onCancel: {
                    worker.cancel()
                }
                try Task.checkCancellation()
                guard query.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else {
                    return
                }
                matches = computed.matches
                chunkMatchRanges = computed.rangesByChunk
                currentMatch = 0
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    nonisolated static func matchesWithRanges(
        for query: String,
        in chunks: [TextChunk]
    ) -> (matches: [Match], rangesByChunk: [Int: [Range<String.Index>]]) {
        guard !query.isEmpty, !Task.isCancelled else { return ([], [:]) }
        var matches: [Match] = []
        var rangesByChunk: [Int: [Range<String.Index>]] = [:]
        let fullText = chunks.map(\.text).joined()
        let chunkLengths = chunks.map { $0.text.count }
        var localCursors = chunks.map { $0.text.startIndex }
        var localOffsets = Array(repeating: 0, count: chunks.count)
        var firstChunk = 0
        var searchStart = fullText.startIndex
        var searchOffset = 0
        // Both the source cursor and per-chunk cursors only move forward.
        // Walking from the beginning for every hit made dense Unicode text quadratic.
        while searchStart < fullText.endIndex {
            guard !Task.isCancelled else { return ([], [:]) }
            guard let globalRange = fullText.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchStart..<fullText.endIndex
            ), globalRange.upperBound > searchStart else { break }
            let lowerOffset = searchOffset + fullText.distance(from: searchStart, to: globalRange.lowerBound)
            let upperOffset = lowerOffset + fullText.distance(from: globalRange.lowerBound, to: globalRange.upperBound)
            searchStart = globalRange.upperBound
            searchOffset = upperOffset
            while firstChunk < chunks.count,
                  chunks[firstChunk].startOffset + chunkLengths[firstChunk] <= lowerOffset {
                firstChunk += 1
            }
            var segments: [MatchSegment] = []
            var chunkIndex = firstChunk
            while chunkIndex < chunks.count, chunks[chunkIndex].startOffset < upperOffset {
                guard !Task.isCancelled else { return ([], [:]) }
                let chunk = chunks[chunkIndex]
                let chunkLower = chunk.startOffset
                let chunkUpper = chunkLower + chunkLengths[chunkIndex]
                let intersectionLower = max(lowerOffset, chunkLower)
                let intersectionUpper = min(upperOffset, chunkUpper)
                defer { chunkIndex += 1 }
                guard intersectionLower < intersectionUpper else { continue }
                let localLower = chunk.text.index(
                    localCursors[chunkIndex],
                    offsetBy: intersectionLower - chunkLower - localOffsets[chunkIndex]
                )
                let localUpper = chunk.text.index(
                    localLower,
                    offsetBy: intersectionUpper - intersectionLower
                )
                localCursors[chunkIndex] = localUpper
                localOffsets[chunkIndex] = intersectionUpper - chunkLower
                let localRange = localLower..<localUpper
                let segment = MatchSegment(chunkID: chunk.id, range: localRange)
                segments.append(segment)
                rangesByChunk[chunk.id, default: []].append(localRange)
            }
            if !segments.isEmpty {
                matches.append(Match(segments: segments))
            }
        }
        return (matches, rangesByChunk)
    }

    nonisolated static func matches(for query: String, in chunks: [TextChunk]) -> [Match] {
        matchesWithRanges(for: query, in: chunks).matches
    }

    nonisolated static func isActive(
        chunkID: Int,
        range: Range<String.Index>,
        currentMatch: Match
    ) -> Bool {
        currentMatch.segments.contains {
            $0.chunkID == chunkID && $0.range == range
        }
    }

    private func moveMatch(by offset: Int) {
        guard !matches.isEmpty else { return }
        currentMatch = (currentMatch + offset + matches.count) % matches.count
    }

    nonisolated static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        guard !query.isEmpty, !Task.isCancelled else { return [] }
        var result: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while !Task.isCancelled, searchStart < text.endIndex,
              let found = text.range(
                  of: query,
                  options: [.caseInsensitive, .diacriticInsensitive],
                  range: searchStart..<text.endIndex
              ) {
            guard found.upperBound > searchStart else { break }
            result.append(found)
            searchStart = found.upperBound
        }
        return Task.isCancelled ? [] : result
    }

    /// Exact contiguous slices keep the source reconstructable for matching.
    /// A query crossing either a newline or a hard chunk boundary remains one
    /// logical match while each visible slice receives its own highlight.
    nonisolated static func chunk(_ text: String, maximumChunkLength: Int = 2_000) -> [TextChunk] {
        precondition(maximumChunkLength > 0)
        var result: [TextChunk] = []
        var remainder = text[...]
        var startOffset = 0
        while !remainder.isEmpty {
            let slice = remainder.prefix(maximumChunkLength)
            result.append(TextChunk(
                id: result.count,
                text: String(slice),
                startOffset: startOffset
            ))
            startOffset += slice.count
            remainder = remainder.dropFirst(slice.count)
        }
        return result
    }
}
