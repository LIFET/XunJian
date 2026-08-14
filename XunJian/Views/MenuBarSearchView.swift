import AppKit
import SwiftUI

enum MenuBarSearchPreference {
    static let storageKey = "menuBar.quickSearchEnabled"
}

/// Menu bar quick search (N13).
///
/// Filters the already-loaded index in memory so the popover can be used
/// without activating — or even having opened — the main window. It never
/// touches the database or triggers a scan.
struct MenuBarSearchView: View {
    @EnvironmentObject private var appModel: AppModel
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system.rawValue

    @State private var query = ""
    @State private var highlightedIndex = 0
    @State private var displayedResults: [IndexedFile] = []
    @State private var remainingCount = 0
    @State private var filterTask: Task<Void, Never>?
    @FocusState private var isFieldFocused: Bool

    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 13

    private static let maximumResults = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchRow
            Divider()

            if displayedResults.isEmpty {
                Text(verbatim: emptyMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 16)
            } else {
                resultList
                if remainingCount > 0 {
                    Button {
                        revealRemainingInAllFiles()
                    } label: {
                        Text(verbatim: AppLanguage.localized(
                            "在所有文件中查看其余 \(remainingCount) 条",
                            english: "See remaining \(remainingCount) in All Files"
                        ))
                        .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                }
            }

            Divider()
            footer
        }
        .frame(width: 340)
        .environment(
            \.locale,
            AppLanguage(rawValue: language)?.locale ?? .autoupdatingCurrent
        )
        .onAppear {
            isFieldFocused = true
            scheduleFilter(immediate: true)
        }
        .onDisappear { filterTask?.cancel() }
        .onChange(of: query) { _, _ in
            highlightedIndex = 0
            scheduleFilter(immediate: false)
        }
        .onChange(of: displayedResults.count) { _, count in
            if highlightedIndex >= count {
                highlightedIndex = max(count - 1, 0)
            }
        }
    }

    private var searchRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: iconSize))
                .foregroundStyle(.secondary)

            TextField(
                "",
                text: $query,
                prompt: Text(verbatim: AppLanguage.localized(
                    "快速查找文件…",
                    english: "Find files…"
                ))
            )
            .textFieldStyle(.plain)
            .focused($isFieldFocused)
            .onSubmit(revealHighlighted)
            .onKeyPress(.upArrow) {
                moveHighlight(by: -1)
                return .handled
            }
            .onKeyPress(.downArrow) {
                moveHighlight(by: 1)
                return .handled
            }
            .accessibilityLabel(Text(verbatim: AppLanguage.localized(
                "快速查找文件",
                english: "Find Files"
            )))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var emptyMessage: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? AppLanguage.localized(
                "还没有索引任何文件。",
                english: "No files have been indexed yet."
            )
            : AppLanguage.localized("没有匹配的文件", english: "No matching files")
    }

    private var resultList: some View {
        VStack(spacing: 0) {
            ForEach(Array(displayedResults.enumerated()), id: \.element.id) { index, file in
                Button {
                    reveal(file)
                } label: {
                    HStack(spacing: 9) {
                        FileThumbnail(file: file, size: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: file.name)
                                .lineLimit(1)
                            Text(verbatim: resultSubtitle(for: file))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        index == highlightedIndex ? XunJianUI.Fill.selected : .clear,
                        in: RoundedRectangle(
                            cornerRadius: XunJianUI.Radius.row,
                            style: .continuous
                        )
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: AppLanguage.localized(
                    "在寻简中显示“\(file.name)”",
                    english: "Reveal “\(file.name)” in XunJian"
                )))
                .accessibilityAddTraits(index == highlightedIndex ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.vertical, 4)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(AppLanguage.localized("打开寻简", english: "Open XunJian")) {
                activateMainWindow()
            }
            Spacer(minLength: 0)
            Button(AppLanguage.localized("退出", english: "Quit")) {
                NSApplication.shared.terminate(nil)
            }
        }
        .buttonStyle(.link)
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func resultSubtitle(for file: IndexedFile) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, QuickSearchMatching.matchedPathOnly(file: file, query: trimmed) else {
            return file.parentPath
        }
        return AppLanguage.localized(
            "路径 · \(file.parentPath)",
            english: "Path · \(file.parentPath)"
        )
    }

    private func moveHighlight(by offset: Int) {
        guard !displayedResults.isEmpty else { return }
        highlightedIndex = min(max(highlightedIndex + offset, 0), displayedResults.count - 1)
    }

    private func revealHighlighted() {
        guard displayedResults.indices.contains(highlightedIndex) else { return }
        reveal(displayedResults[highlightedIndex])
    }

    private func reveal(_ file: IndexedFile) {
        appModel.revealInAllFiles(file)
        activateMainWindow()
        NotificationCenter.default.post(name: .xunJianDismissMenuBarSearch, object: nil)
        query = ""
        highlightedIndex = 0
    }

    private func revealRemainingInAllFiles() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        appModel.searchText = trimmed
        NotificationCenter.default.post(name: .xunJianRevealInAllFiles, object: nil)
        activateMainWindow()
        NotificationCenter.default.post(name: .xunJianDismissMenuBarSearch, object: nil)
        query = ""
        highlightedIndex = 0
    }

    private func scheduleFilter(immediate: Bool) {
        filterTask?.cancel()
        filterTask = Task {
            if !immediate {
                try? await Task.sleep(for: .milliseconds(120))
            }
            guard !Task.isCancelled else { return }
            await rebuildResults()
        }
    }

    @MainActor
    private func rebuildResults() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            displayedResults = Array(appModel.recentFiles.prefix(Self.maximumResults))
            remainingCount = 0
            return
        }
        let files = appModel.files
        let limit = Self.maximumResults
        let result = await Task.detached(priority: .userInitiated) {
            QuickSearchMatching.prefixMatches(
                in: files,
                query: trimmed,
                limit: limit
            )
        }.value
        guard !Task.isCancelled else { return }
        displayedResults = result.files
        remainingCount = result.remainingCount
    }

    /// Brings the existing main window forward rather than creating another
    /// one; the app is single-window by design.
    private func activateMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        for window in NSApplication.shared.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            return
        }
    }
}
