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

/// Which file-table columns fit the current content width.
///
/// The table keeps a readable 640pt canvas. A narrower content area scrolls
/// horizontally instead of compressing columns below their readable minima.
enum FileTableLayout {
    static let readableMinimumWidth: CGFloat = 640
    static let categoryVisibleWidth: CGFloat = 640
    static let locationVisibleWidth: CGFloat = 720

    static func showsCategory(contentWidth: CGFloat) -> Bool {
        contentWidth >= categoryVisibleWidth
    }

    static func showsLocation(contentWidth: CGFloat) -> Bool {
        contentWidth >= locationVisibleWidth
    }

    static func minimumWidth(contentWidth: CGFloat) -> CGFloat {
        max(contentWidth, readableMinimumWidth)
    }

    static func needsHorizontalScroll(contentWidth: CGFloat) -> Bool {
        contentWidth < readableMinimumWidth
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

    @ScaledMetric(relativeTo: .body)
    private var controlHeight = FileToolbarMetrics.controlHeight

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
                    viewModePicker
                }
            }
        }
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
        Menu {
            Button {
                selectedKind = nil
            } label: {
                if selectedKind == nil {
                    Label(
                        AppLanguage.localized("所有类型", english: "All Types"),
                        systemImage: "checkmark"
                    )
                } else {
                    Text(verbatim: AppLanguage.localized("所有类型", english: "All Types"))
                }
            }
            Divider()
            ForEach(FileKind.allCases) { kind in
                Button {
                    selectedKind = kind
                } label: {
                    if selectedKind == kind {
                        Label(kind.localizedTitle, systemImage: "checkmark")
                    } else {
                        Text(verbatim: kind.localizedTitle)
                    }
                }
            }
        } label: {
            FileToolbarPopupLabel(
                title: selectedKind?.localizedTitle
                    ?? AppLanguage.localized("所有类型", english: "All Types"),
                width: FileToolbarMetrics.fileTypeWidth
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text(verbatim: AppLanguage.localized(
            "文件类型",
            english: "File Type"
        )))
    }

    private var sortMenu: some View {
        Menu {
            ForEach(sortOrders) { order in
                Button {
                    sortOrder = order
                    // Names and types read naturally A→Z; dates and sizes are
                    // most useful largest/newest first.
                    sortAscending = order == .name || order == .kind
                } label: {
                    if sortOrder == order {
                        Label(order.localizedTitle, systemImage: "checkmark")
                    } else {
                        Text(verbatim: order.localizedTitle)
                    }
                }
            }
        } label: {
            FileToolbarPopupLabel(
                title: sortOrder.localizedTitle,
                width: FileToolbarMetrics.sortWidth(for: sortOrder)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text(verbatim: AppLanguage.localized("排序", english: "Sort By")))
    }

    private var directionButton: some View {
        Button {
            sortAscending.toggle()
        } label: {
            FileToolbarIconLabel(systemName: sortAscending ? "arrow.up" : "arrow.down")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: sortAscending
            ? AppLanguage.localized("升序", english: "Ascending")
            : AppLanguage.localized("降序", english: "Descending")))
    }

    private var viewModePicker: some View {
        HStack(spacing: 0) {
            ForEach(FileBrowseViewMode.allCases) { mode in
                Button {
                    viewMode = mode
                } label: {
                    Image(systemName: mode.symbolName)
                        .font(.system(size: FileToolbarMetrics.symbolSize, weight: .medium))
                        .frame(
                            width: FileToolbarMetrics.viewModeItemWidth,
                            height: controlHeight - 2
                        )
                        .background {
                            RoundedRectangle(
                                cornerRadius: FileToolbarMetrics.innerCornerRadius,
                                style: .continuous
                            )
                            .fill(viewMode == mode ? Color.accentColor : Color.clear)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(viewMode == mode ? Color.white : Color.primary)
                .accessibilityLabel(Text(verbatim: mode.localizedTitle))
                .accessibilityAddTraits(viewMode == mode ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(1)
        .frame(
            width: FileToolbarMetrics.viewModeWidth,
            height: controlHeight
        )
        .fileToolbarSurface()
        .fixedSize()
    }
}

/// Shared multi-select bar for All Files and category pages.
struct FileBatchActionBar: View {
    @EnvironmentObject private var appModel: AppModel
    var contentWidth: CGFloat? = nil
    var removalCategory: FileCategory? = nil

    var body: some View {
        HStack(spacing: 8) {
            Label(
                AppLanguage.localized(
                    "已选择 \(appModel.selectedFileIDs.count) 项",
                    english: "\(appModel.selectedFileIDs.count) selected"
                ),
                systemImage: "checkmark.circle.fill"
            )
            Spacer(minLength: 8)
            Menu {
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
            } label: {
                Label(
                    AppLanguage.localized("批量加分类", english: "Add to Category"),
                    systemImage: "folder.badge.plus"
                )
            }
            .fixedSize()
            if let removalCategory {
                Button {
                    appModel.removeSelectedFiles(from: removalCategory)
                } label: {
                    Label(
                        AppLanguage.localized(
                            "从此分类移除",
                            english: "Remove from Category"
                        ),
                        systemImage: "folder.badge.minus"
                    )
                }
                .fixedSize()
            }
            Button(role: .destructive) {
                appModel.requestBatchTrash()
            } label: {
                Label(
                    AppLanguage.localized("移到废纸篓", english: "Move to Trash"),
                    systemImage: "trash"
                )
            }
            Button {
                appModel.selectedFileIDs = []
            } label: {
                Label(
                    AppLanguage.localized("取消选择", english: "Clear Selection"),
                    systemImage: "xmark"
                )
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            XunJianUI.Fill.selectedSoft,
            in: RoundedRectangle(cornerRadius: XunJianUI.Radius.chip, style: .continuous)
        )
        .padding(.horizontal, contentWidth.map { XunJianUI.pagePadding(for: $0) } ?? 0)
        .padding(.bottom, 10)
        .xunjianAnimation(value: appModel.selectedFileIDs.count > 1)
    }
}
