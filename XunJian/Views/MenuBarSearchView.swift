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
    @AppStorage(AppVisualTheme.storageKey) private var visualTheme = AppVisualTheme.reading.rawValue
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system.rawValue
    @Environment(\.colorScheme) private var colorScheme

    @State private var query = ""
    @State private var highlightedIndex = 0
    @State private var displayedResults: [IndexedFile] = []
    @State private var remainingCount = 0
    @State private var filterTask: Task<Void, Never>?
    @State private var isFieldFocused = false
    @ScaledMetric(relativeTo: .body) private var searchControlHeight: CGFloat = 34

    private static let maximumResults = 50

    private var effectiveColorScheme: ColorScheme {
        AppAppearance(rawValue: appearance)?.colorScheme ?? colorScheme
    }

    private var theme: AppVisualTheme { AppVisualTheme.resolve(visualTheme) }
    private var palette: ThemePalette { theme.palette(for: effectiveColorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.2x2.fill").foregroundStyle(palette.accent)
                Text(AppLanguage.localized("寻简 · 快速查找", english: "XunJian · Quick Find"))
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 16)
            searchRow
            Divider()

            if displayedResults.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.title3)
                        .foregroundStyle(palette.accent)
                        .accessibilityHidden(true)
                    Text(verbatim: emptyMessage)
                        .font(.body)
                    Text(AppLanguage.localized(
                        "输入文件名或路径；更多检索选项在主窗口。",
                        english: "Search by name or path. Find more search options in the main window."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(16)
            } else {
                    Text(verbatim: query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         ? AppLanguage.localized("最近文件", english: "Recent Files")
                         : AppLanguage.localized("\(displayedResults.count) 项结果", english: "\(displayedResults.count) results"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                resultList
                    .frame(maxHeight: .infinity)
                if remainingCount > 0 {
                    Button {
                        revealRemainingInAllFiles()
                    } label: {
                        Text(verbatim: AppLanguage.localized(
                            "在查找中查看其余 \(remainingCount) 条",
                            english: "See remaining \(remainingCount) in All Files"
                        ))
                        .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
            }

            Divider()
            footer
        }
        .frame(
            minWidth: 320,
            idealWidth: 340,
            maxWidth: 420,
            minHeight: 380,
            idealHeight: 480,
            maxHeight: 620
        )
        .xunjianThinScrollers()
        .background(palette.canvas)
        .xunjianVisualTheme(theme)
        .environment(\.colorScheme, effectiveColorScheme)
        .preferredColorScheme(AppAppearance(rawValue: appearance)?.colorScheme)
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
        .onChange(of: appModel.filesRevision) { _, _ in
            highlightedIndex = 0
            scheduleFilter(immediate: true)
        }
        .onChange(of: displayedResults.count) { _, count in
            if highlightedIndex >= count {
                highlightedIndex = max(count - 1, 0)
            }
        }
    }

    private var searchRow: some View {
        NativeSearchField(
            text: $query,
            isFocused: $isFieldFocused,
            prompt: AppLanguage.localized("快速查找文件…", english: "Find files…"),
            accessibilityLabel: AppLanguage.localized("快速查找文件", english: "Find Files"),
            accessibilityHelp: AppLanguage.localized(
                "搜索已索引的本地文件",
                english: "Searches indexed local files"
            ),
            onSubmit: { _ in revealHighlighted() },
            onMoveSelection: { offset in
                guard !displayedResults.isEmpty else { return false }
                moveHighlight(by: offset)
                return true
            },
            onCancel: {
                if query.isEmpty {
                    NotificationCenter.default.post(name: .xunJianDismissMenuBarSearch, object: nil)
                } else {
                    query = ""
                }
            }
        )
        .frame(height: searchControlHeight)
        .padding(.horizontal, 16)
        .padding(.vertical, theme == .precision ? 12 : 16)
    }

    private var emptyMessage: String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return appModel.files.isEmpty
                ? AppLanguage.localized(
                    "还没有索引任何文件。",
                    english: "No files have been indexed yet."
                )
                : AppLanguage.localized(
                    "输入关键词搜索文件",
                    english: "Type a keyword to search files"
                )
        }
        return AppLanguage.localized("没有匹配的文件", english: "No matching files")
    }

    private var resultList: some View {
        List(selection: resultSelection) {
            ForEach(displayedResults) { file in
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
                .padding(.vertical, theme.rowVerticalPadding)
                .contentShape(Rectangle())
                .help(AppLanguage.joinedForAccessibility([file.name, resultSubtitle(for: file)]))
                .tag(file.id)
                .accessibilityLabel(Text(verbatim: AppLanguage.joinedForAccessibility([
                    file.name,
                    resultSubtitle(for: file)
                ])))
                .accessibilityHint(Text(verbatim: AppLanguage.localized(
                    "激活以在寻简中显示",
                    english: "Activate to show in XunJian"
                )))
                .accessibilityAction {
                    reveal(file)
                }
                .accessibilityAction(named: Text(verbatim: AppLanguage.localized(
                    "打开文件",
                    english: "Open File"
                ))) {
                    open(file)
                }
                // A double-click recognizer delays the first click while it
                // waits for a possible second click. Keep selection immediate;
                // Return and the footer buttons perform the actions.
                .onTapGesture {
                    if let index = displayedResults.firstIndex(where: { $0.id == file.id }) {
                        highlightedIndex = index
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(palette.canvas)
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: XunJianUI.Spacing.row) {
                revealButton
                openFileButton
                Spacer(minLength: 0)
                openAppButton
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: XunJianUI.Spacing.row) {
                    revealButton
                    openFileButton
                }
                openAppButton
            }
        }
        .controlSize(.regular)
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, theme == .precision ? 8 : 12)
    }

    private var revealButton: some View {
        Button(AppLanguage.localized("在寻简中显示", english: "Show in XunJian")) {
            revealHighlighted()
        }
        .buttonStyle(.borderedProminent)
        .disabled(!displayedResults.indices.contains(highlightedIndex))
    }

    private var openFileButton: some View {
        Button(AppLanguage.localized("打开文件", english: "Open File")) {
            openHighlightedFile()
        }
        .disabled(!displayedResults.indices.contains(highlightedIndex))
    }

    private var openAppButton: some View {
        Button {
            activateMainWindow()
        } label: {
            Label(AppLanguage.localized("打开寻简", english: "Open XunJian"), systemImage: "macwindow")
                .labelStyle(.iconOnly)
        }
        .help(AppLanguage.localized("打开寻简主窗口", english: "Open XunJian Main Window"))
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

    private var resultSelection: Binding<String?> {
        Binding(
            get: {
                guard displayedResults.indices.contains(highlightedIndex) else { return nil }
                return displayedResults[highlightedIndex].id
            },
            set: { selectedID in
                guard let selectedID,
                      let index = displayedResults.firstIndex(where: { $0.id == selectedID }) else { return }
                highlightedIndex = index
            }
        )
    }

    private func revealHighlighted() {
        guard displayedResults.indices.contains(highlightedIndex) else { return }
        reveal(displayedResults[highlightedIndex])
    }

    private func openHighlightedFile() {
        guard displayedResults.indices.contains(highlightedIndex) else { return }
        open(displayedResults[highlightedIndex])
    }

    private func open(_ file: IndexedFile) {
        appModel.open(file)
        NotificationCenter.default.post(name: .xunJianDismissMenuBarSearch, object: nil)
        query = ""
        highlightedIndex = 0
    }

    private func reveal(_ file: IndexedFile) {
        appModel.revealInAllFiles(file)
        activateMainWindow()
        query = ""
        highlightedIndex = 0
    }

    private func revealRemainingInAllFiles() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        appModel.searchAllFiles(query: trimmed)
        activateMainWindow()
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
        let sourceRevision = appModel.filesRevision
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            guard appModel.filesRevision == sourceRevision else { return }
            displayedResults = Array(appModel.recentFiles.prefix(Self.maximumResults))
            remainingCount = 0
            return
        }
        let files = appModel.files
        let limit = Self.maximumResults
        // The detached scan cannot observe the outer task's cancellation, so
        // a flag flipped by the cancellation handler lets stale full-index
        // walks stop the moment newer input arrives.
        let cancellationFlag = QuickSearchCancellationFlag()
        let result = await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                QuickSearchMatching.prefixMatches(
                    in: files,
                    query: trimmed,
                    limit: limit,
                    isCancelled: { cancellationFlag.isCancelled }
                )
            }.value
        } onCancel: {
            cancellationFlag.cancel()
        }
        guard !Task.isCancelled,
              appModel.filesRevision == sourceRevision else { return }
        displayedResults = result.files
        remainingCount = result.remainingCount
    }

    /// Brings the existing main window forward rather than creating another
    /// one; the app is single-window by design.
    private func activateMainWindow() {
        // Close the status-item popover first. Activating while its transient
        // window is still key made the loop below select the popover itself;
        // closing it then left no main window in front.
        NotificationCenter.default.post(name: .xunJianDismissMenuBarSearch, object: nil)
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
            let candidates = NSApplication.shared.windows.filter {
                $0.canBecomeMain && $0.level == .normal && !($0 is NSPanel)
            }
            let mainWindow = candidates.first(where: {
                $0.identifier?.rawValue == "main"
            }) ?? candidates.first(where: {
                $0.title == AppLanguage.localized("寻简", english: "XunJian")
            }) ?? candidates.first
            mainWindow?.makeKeyAndOrderFront(nil)
        }
    }
}
