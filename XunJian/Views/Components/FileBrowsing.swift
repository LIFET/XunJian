import Combine
import SwiftUI

/// Shared file-browsing chrome (N05).
///
/// The category detail page previously had no sorting, filtering, or grid
/// view, which made it noticeably weaker than "All Files". These pieces live
/// here rather than inside a page so both can share one implementation.
///
/// `AllFilesView` still carries its own `ViewMode` and grid card; folding it
/// onto these types belongs to the F10 view-splitting work, which owns that
/// file.

/// What a double-click does to a file. Finder opens; some users would rather
/// peek first, so this is a preference instead of a hard-coded behaviour.
enum FileActivationBehavior: String, CaseIterable, Identifiable {
    case open
    case quickLook

    static let storageKey = "files.doubleClickBehavior"

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .open: AppLanguage.localized("用默认应用打开", english: "Open in Default App")
        case .quickLook: AppLanguage.localized("快速查看", english: "Quick Look")
        }
    }

    @MainActor
    func perform(on file: IndexedFile, using appModel: AppModel) {
        switch self {
        case .open: appModel.open(file)
        case .quickLook: appModel.quickLook(file)
        }
    }
}

/// Coarse layout identity for the file browser.
///
/// A macOS `Table` already owns column compression and horizontal scrolling.
/// Keep one stable identity for list mode so showing the Inspector never
/// rebuilds a large table merely because the detail width changed.
enum FileTableLayout {
    @MainActor
    static func snapshotLayoutToken(
        contentWidth: CGFloat,
        viewMode: FileBrowseViewMode
    ) -> Int {
        switch viewMode {
        case .list: return 0
        case .grid:
            return 10 + FileGridCard.columnCount(forWidth: contentWidth)
        }
    }
}

enum FileBrowseViewMode: String, CaseIterable, Identifiable {
    case list
    case grid

    var id: String { rawValue }

    var symbolName: String { self == .list ? "list.bullet" : "square.grid.2x2" }

    var localizedTitle: String {
        switch self {
        case .list: AppLanguage.localized("列表", english: "List")
        case .grid: AppLanguage.localized("图标", english: "Icons")
        }
    }
}

// MARK: - Grid card

/// Presentational grid cell for a file. Selection and activation are supplied
/// by the host page so this stays free of app state.
struct FileGridCard: View, Equatable {
    let file: IndexedFile
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.file == rhs.file && lhs.isSelected == rhs.isSelected
    }

    /// Hover lives on the card instead of the page: a page-level @State made
    /// every mouse move invalidate the whole grid (and on All Files, the
    /// 100k-row table view graph) just to repaint one card.
    @State private var isHovered = false

    @ScaledMetric(relativeTo: .body) private var thumbnailSize: CGFloat = 72
    @ScaledMetric(relativeTo: .body) private var minimumHeight: CGFloat = 122

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 10) {
                FileThumbnail(file: file, size: thumbnailSize)
                Text(verbatim: file.name)
                    .font(.callout)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(verbatim: Self.sizeText(file))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, minHeight: minimumHeight)
            .padding(12)
            .background {
                InteractiveCardBackground(
                    isSelected: isSelected,
                    isHovered: isHovered,
                    cornerRadius: XunJianUI.Radius.card
                )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SoftCardButtonStyle())
        .simultaneousGesture(TapGesture(count: 2).onEnded(onOpen))
        .onHover { isHovered = $0 }
        .accessibilityLabel(Text(verbatim: AppLanguage.joinedForAccessibility([
            file.name,
            Self.sizeText(file)
        ])))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: Text(verbatim: AppLanguage.localized(
            "打开",
            english: "Open"
        ))) {
            onOpen()
        }
    }

    static func sizeText(_ file: IndexedFile) -> String {
        ByteFormatting.string(forByteCount: file.size)
    }

    static let minimumItemWidth: CGFloat = 132
    static let gridSpacing: CGFloat = 14
    static let gridColumns = [GridItem(.adaptive(minimum: minimumItemWidth), spacing: gridSpacing)]

    /// Columns the adaptive grid fits at this width. Used so arrow-key
    /// navigation moves a whole row rather than one item.
    static func columnCount(forWidth width: CGFloat) -> Int {
        max(Int(width / (minimumItemWidth + gridSpacing)), 1)
    }
}

/// Click / binding publication rules shared by the table and grid.
enum FileBrowseSelection {
    static func shouldPublishSelectionChange(
        fileID: String,
        selectedIDs: Set<String>,
        command: Bool,
        shift: Bool
    ) -> Bool {
        if command || shift { return true }
        return selectedIDs != [fileID]
    }

    /// A renderer being removed can emit one final empty AppKit selection.
    /// Only the renderer that is still visible may publish into the shared
    /// model; otherwise list ↔ grid switches visibly clear the selected file.
    static func shouldAcceptNativeSelectionPublication(
        from sourceMode: FileBrowseViewMode,
        currentMode: FileBrowseViewMode
    ) -> Bool {
        sourceMode == currentMode
    }
}

/// Each materialized lazy-grid card observes only whether its own ID is in the
/// selection. This avoids rebuilding the whole grid and avoids retaining one
/// observable object for every indexed file.
struct FileGridSelectableCard: View {
    let file: IndexedFile
    let selectedIDs: Published<Set<String>>.Publisher
    let onSelect: () -> Void
    let onOpen: () -> Void
    @State private var isSelected: Bool

    init(
        file: IndexedFile,
        isSelected: Bool,
        selectedIDs: Published<Set<String>>.Publisher,
        onSelect: @escaping () -> Void,
        onOpen: @escaping () -> Void
    ) {
        self.file = file
        self.selectedIDs = selectedIDs
        self.onSelect = onSelect
        self.onOpen = onOpen
        _isSelected = State(initialValue: isSelected)
    }

    var body: some View {
        FileGridCard(
            file: file,
            isSelected: isSelected,
            onSelect: onSelect,
            onOpen: onOpen
        )
            .onReceive(selectedIDs) { ids in
                let next = ids.contains(file.id)
                guard next != isSelected else { return }
                isSelected = next
            }
    }
}

// MARK: - Keyboard navigation

/// Arrow-key selection plus the standard file shortcuts, shared by every file
/// list so the grid and the category page behave like the main table.
///
/// `columnCount` is 1 for vertical lists; grids pass their real column count so
/// up/down moves a row rather than a single item.
struct FileListKeyboardNavigation: ViewModifier {
    @EnvironmentObject private var appModel: AppModel

    let files: [IndexedFile]
    var orderedIDs: [String]?
    /// Optional id -> position map for the displayed list; skips O(n)
    /// index scans per arrow key / shift-click on large grids.
    var idIndex: [String: Int]? = nil
    var columnCount: Int = 1
    /// The main file table owns arrow-key row movement; keep Return / Space /
    /// Delete / ⌘C even when arrows are left to `Table`.
    var handlesArrowKeys = true

    @AppStorage(FileActivationBehavior.storageKey)
    private var activationBehavior = FileActivationBehavior.open
    @FocusState private var isListFocused: Bool

    func body(content: Content) -> some View {
        content
            .focusable(!files.isEmpty)
            .focusEffectDisabled()
            .focused($isListFocused)
            .onChange(of: appModel.selectedFileID) { _, id in
                guard id != nil, !files.isEmpty else { return }
                isListFocused = true
            }
            .onKeyPress(phases: [.down, .repeat]) { press in
                handleKeyPress(press)
            }
    }

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        let extending = press.modifiers.contains(.shift)
        switch press.key {
        case .upArrow:
            return handlesArrowKeys ? move(by: -columnCount, extending: extending) : .ignored
        case .downArrow:
            return handlesArrowKeys ? move(by: columnCount, extending: extending) : .ignored
        case .leftArrow:
            return handlesArrowKeys ? move(by: -1, extending: extending) : .ignored
        case .rightArrow:
            return handlesArrowKeys ? move(by: 1, extending: extending) : .ignored
        case .return:
            guard let file = currentFile else { return .ignored }
            activationBehavior.perform(on: file, using: appModel)
            return .handled
        case .space:
            guard let file = currentFile else { return .ignored }
            appModel.quickLook(file)
            return .handled
        case .delete, .deleteForward:
            return requestTrash()
        default:
            guard press.modifiers.contains(.command),
                  press.characters.lowercased() == "c",
                  let file = currentFile else { return .ignored }
            appModel.copyPath(file)
            return .handled
        }
    }

    private var currentFile: IndexedFile? {
        appModel.selectedFile
    }

    /// Moves the selection, clamping at both ends rather than wrapping so
    /// holding an arrow key cannot silently jump across the whole list.
    private func move(by offset: Int, extending: Bool) -> KeyPress.Result {
        guard !files.isEmpty else { return .ignored }
        if let orderedIDs {
            appModel.moveDisplayedSelection(
                by: offset,
                inIDs: orderedIDs,
                extending: extending,
                idIndex: idIndex
            )
        } else {
            appModel.moveDisplayedSelection(
                by: offset,
                in: files,
                extending: extending,
                idIndex: idIndex
            )
        }
        return .handled
    }

    private func requestTrash() -> KeyPress.Result {
        if appModel.selectedFileIDs.count > 1 {
            appModel.requestBatchTrash()
            return .handled
        }
        guard let file = currentFile else { return .ignored }
        appModel.requestTrash(file)
        return .handled
    }
}

extension View {
    func fileListKeyboardNavigation(
        files: [IndexedFile],
        orderedIDs: [String]? = nil,
        idIndex: [String: Int]? = nil,
        columnCount: Int = 1,
        handlesArrowKeys: Bool = true
    ) -> some View {
        modifier(FileListKeyboardNavigation(
            files: files,
            orderedIDs: orderedIDs,
            idIndex: idIndex,
            columnCount: columnCount,
            handlesArrowKeys: handlesArrowKeys
        ))
    }

}

// MARK: - Compact browse toolbar

/// Type filter, sort order, sort direction, and view mode in a single row.
///
/// Deliberately simpler than the "All Files" toolbar: the category page has a
/// narrower control set, so it does not need that page's five-stage
/// responsive collapsing.
struct FileBrowseToolbar: View {
    @Binding var selectedKind: FileKind?
    @Binding var sortOrder: FileSortOrder
    @Binding var sortAscending: Bool
    @Binding var viewMode: FileBrowseViewMode

    /// Relevance only makes sense while a search is scoring results.
    private var sortOrders: [FileSortOrder] {
        FileSortOrder.allCases.filter { $0 != .relevance }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                controls
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    kindMenu
                    sortMenu
                }
                HStack(spacing: 8) {
                    directionButton
                    Divider()
                        .frame(height: 18)
                    viewModePicker
                }
            }

            compactBrowseMenu
        }
    }

    private var compactBrowseMenu: some View {
        Menu {
            Picker(
                AppLanguage.localized("文件类型", english: "File Type"),
                selection: $selectedKind
            ) {
                Text(AppLanguage.localized("所有类型", english: "All Types"))
                    .tag(FileKind?.none)
                ForEach(FileKind.allCases) { kind in
                    Text(verbatim: kind.localizedTitle).tag(Optional(kind))
                }
            }

            Picker(
                AppLanguage.localized("排序", english: "Sort By"),
                selection: Binding(
                    get: { sortOrder },
                    set: { order in
                        guard sortOrder != order else { return }
                        sortOrder = order
                        sortAscending = order == .name || order == .kind
                    }
                )
            ) {
                ForEach(sortOrders) { order in
                    Text(verbatim: order.localizedTitle).tag(order)
                }
            }

            Button {
                sortAscending.toggle()
            } label: {
                Label(
                    sortAscending
                        ? AppLanguage.localized("升序", english: "Ascending")
                        : AppLanguage.localized("降序", english: "Descending"),
                    systemImage: sortAscending ? "arrow.up" : "arrow.down"
                )
            }

            Picker(
                AppLanguage.localized("显示方式", english: "View"),
                selection: $viewMode
            ) {
                ForEach(FileBrowseViewMode.allCases) { mode in
                    Label(mode.localizedTitle, systemImage: mode.symbolName).tag(mode)
                }
            }
        } label: {
            Label(
                AppLanguage.localized("浏览选项", english: "Browse Options"),
                systemImage: "ellipsis.circle"
            )
        }
        .menuStyle(.button)
        .fixedSize()
    }

    @ViewBuilder
    private var controls: some View {
        kindMenu
        sortMenu
        directionButton
        Spacer(minLength: 0)
        viewModePicker
    }

    private var kindMenu: some View {
        Picker(
            AppLanguage.localized("文件类型", english: "File Type"),
            selection: $selectedKind
        ) {
            Text(AppLanguage.localized("所有类型", english: "All Types"))
                .tag(FileKind?.none)
            ForEach(FileKind.allCases) { kind in
                Text(verbatim: kind.localizedTitle)
                    .tag(Optional(kind))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: FileToolbarMetrics.fileTypeWidth)
        .fixedSize()
        .accessibilityLabel(Text(verbatim: AppLanguage.localized(
            "文件类型",
            english: "File Type"
        )))
    }

    private var sortMenu: some View {
        Picker(
            AppLanguage.localized("排序", english: "Sort By"),
            selection: Binding(
                get: { sortOrder },
                set: { order in
                    guard sortOrder != order else { return }
                    sortOrder = order
                    sortAscending = order == .name || order == .kind
                }
            )
        ) {
            ForEach(sortOrders) { order in
                Text(verbatim: order.localizedTitle)
                    .tag(order)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: FileToolbarMetrics.sortWidth(for: sortOrder))
        .fixedSize()
        .accessibilityLabel(Text(verbatim: AppLanguage.localized("排序", english: "Sort By")))
    }

    private var directionButton: some View {
        Button {
            sortAscending.toggle()
        } label: {
            Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .accessibilityLabel(Text(verbatim: sortAscending
            ? AppLanguage.localized("升序", english: "Ascending")
            : AppLanguage.localized("降序", english: "Descending")))
    }

    private var viewModePicker: some View {
        Picker(
            AppLanguage.localized("显示方式", english: "View"),
            selection: $viewMode
        ) {
            ForEach(FileBrowseViewMode.allCases) { mode in
                Image(systemName: mode.symbolName)
                    .tag(mode)
                    .accessibilityLabel(Text(verbatim: mode.localizedTitle))
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: FileToolbarMetrics.viewModeWidth)
        .fixedSize()
    }
}

/// Shared multi-select bar for All Files and category pages.
struct FileBatchActionBar: View {
    @EnvironmentObject private var appModel: AppModel
    var contentWidth: CGFloat? = nil
    var removalCategory: FileCategory? = nil

    var body: some View {
        GroupBox {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    selectionLabel
                    Spacer(minLength: 8)
                    ControlGroup {
                        categoryMenu
                        if let removalCategory {
                            removeFromCategoryButton(removalCategory)
                        }
                        trashButton
                        clearSelectionButton
                    }
                }

                HStack(spacing: 8) {
                    selectionLabel
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    overflowMenu
                }
            }
        }
        .font(.caption)
        .controlSize(.small)
        .padding(.horizontal, contentWidth.map { XunJianUI.pagePadding(for: $0) } ?? 0)
        .padding(.bottom, 10)
        .xunjianAnimation(value: appModel.selectedFileIDs.count > 1)
    }

    private var selectionLabel: some View {
        Label(
            AppLanguage.localized(
                "已选择 \(appModel.selectedFileIDs.count) 项",
                english: "\(appModel.selectedFileIDs.count) selected"
            ),
            systemImage: "checkmark.circle.fill"
        )
    }

    private var categoryMenu: some View {
        Menu {
            categoryMenuItems
        } label: {
            Label(
                AppLanguage.localized("批量加分类", english: "Add to Category"),
                systemImage: "folder.badge.plus"
            )
        }
        .fixedSize()
    }

    @ViewBuilder
    private var categoryMenuItems: some View {
        if appModel.categories.isEmpty {
            Text(AppLanguage.localized("还没有分类", english: "No categories yet"))
        } else {
            ForEach(appModel.categories) { category in
                Button {
                    appModel.assignSelectedFiles(to: category)
                } label: {
                    Label(category.localizedDisplayName, systemImage: category.symbolName)
                }
            }
        }
    }

    private func removeFromCategoryButton(_ category: FileCategory) -> some View {
        Button {
            appModel.removeSelectedFiles(from: category)
        } label: {
            Label(
                AppLanguage.localized("从此分类移除", english: "Remove from Category"),
                systemImage: "folder.badge.minus"
            )
        }
        .fixedSize()
    }

    private var trashButton: some View {
        Button(role: .destructive) {
            appModel.requestBatchTrash()
        } label: {
            Label(
                AppLanguage.localized("移到废纸篓", english: "Move to Trash"),
                systemImage: "trash"
            )
        }
    }

    private var clearSelectionButton: some View {
        Button {
            appModel.selectedFileIDs = []
        } label: {
            Label(
                AppLanguage.localized("取消选择", english: "Clear Selection"),
                systemImage: "xmark"
            )
        }
    }

    private var overflowMenu: some View {
        Menu {
            Menu {
                categoryMenuItems
            } label: {
                Label(
                    AppLanguage.localized("批量加分类", english: "Add to Category"),
                    systemImage: "folder.badge.plus"
                )
            }
            if let removalCategory {
                removeFromCategoryButton(removalCategory)
            }
            trashButton
            clearSelectionButton
        } label: {
            Label(
                AppLanguage.localized("更多操作", english: "More Actions"),
                systemImage: "ellipsis.circle"
            )
        }
        .fixedSize()
    }
}
