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
struct FileGridCard: View {
    let file: IndexedFile
    let isSelected: Bool
    let isHovered: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onHover: (Bool) -> Void

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
        .onHover(perform: onHover)
        .accessibilityLabel(Text(verbatim: "\(file.name)，\(Self.sizeText(file))"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    static func sizeText(_ file: IndexedFile) -> String {
        ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)
    }

    static let gridColumns = [GridItem(.adaptive(minimum: 132), spacing: 14)]
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
            Text(
                verbatim: selectedKind?.localizedTitle
                    ?? AppLanguage.localized("所有类型", english: "All Types")
            )
        }
        .menuStyle(.borderlessButton)
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
            Text(verbatim: sortOrder.localizedTitle)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(Text(verbatim: AppLanguage.localized("排序", english: "Sort By")))
    }

    private var directionButton: some View {
        Button {
            sortAscending.toggle()
        } label: {
            Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: sortAscending
            ? AppLanguage.localized("升序", english: "Ascending")
            : AppLanguage.localized("降序", english: "Descending")))
    }

    private var viewModePicker: some View {
        HStack(spacing: 2) {
            ForEach(FileBrowseViewMode.allCases) { mode in
                Button {
                    viewMode = mode
                } label: {
                    Image(systemName: mode.symbolName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(viewMode == mode ? Color.accentColor : Color.primary)
                        .frame(width: 30, height: 24)
                        .background {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(
                                    viewMode == mode
                                        ? XunJianUI.Fill.selected
                                        : Color.clear
                                )
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: mode.localizedTitle))
                .accessibilityAddTraits(viewMode == mode ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(
            XunJianUI.Fill.control,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
    }
}
