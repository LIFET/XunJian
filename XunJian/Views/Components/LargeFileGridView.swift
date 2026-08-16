import AppKit
import QuickLookThumbnailing
import SwiftUI

/// AppKit-backed icon browser for very large file snapshots.
///
/// The custom layout computes attributes only for the visible rows and
/// `NSCollectionView` asks its data source only for materialized items. This
/// keeps a six-figure library out of SwiftUI's per-card view graph while
/// preserving native macOS selection, keyboard and drag behavior.
@MainActor
struct LargeFileGridView: NSViewRepresentable {
    typealias NSViewType = NSScrollView

    let files: [IndexedFile]
    let idIndex: [String: Int]
    let contentVersion: Int
    @Binding var selection: Set<String>

    let onSelectionLeadChange: (IndexedFile?) -> Void
    let onDoubleClick: (IndexedFile) -> Void
    let onQuickLook: (IndexedFile) -> Void
    let onDelete: () -> Void
    /// Return an AppKit menu for the clicked file/current selection, or `nil`
    /// to use no contextual menu.
    let contextMenuProvider: ((IndexedFile, Set<String>) -> NSMenu?)?

    init(
        files: [IndexedFile],
        idIndex: [String: Int],
        contentVersion: Int,
        selection: Binding<Set<String>>,
        onSelectionLeadChange: @escaping (IndexedFile?) -> Void,
        onDoubleClick: @escaping (IndexedFile) -> Void,
        onQuickLook: @escaping (IndexedFile) -> Void,
        onDelete: @escaping () -> Void,
        contextMenuProvider: ((IndexedFile, Set<String>) -> NSMenu?)? = nil
    ) {
        self.files = files
        self.idIndex = idIndex
        self.contentVersion = contentVersion
        _selection = selection
        self.onSelectionLeadChange = onSelectionLeadChange
        self.onDoubleClick = onDoubleClick
        self.onQuickLook = onQuickLook
        self.onDelete = onDelete
        self.contextMenuProvider = contextMenuProvider
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let collectionView = LargeFileNSCollectionView()
        collectionView.collectionViewLayout = LargeFileGridLayout()
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.autoresizingMask = [.width]
        collectionView.register(
            LargeFileGridItem.self,
            forItemWithIdentifier: LargeFileGridItem.reuseIdentifier
        )
        collectionView.setAccessibilityLabel(
            AppLanguage.localized("文件图标", english: "File Icons")
        )
        collectionView.setDraggingSourceOperationMask([.copy, .move], forLocal: false)

        collectionView.activationHandler = { [weak coordinator = context.coordinator] item in
            coordinator?.activate(item: item)
        }
        collectionView.quickLookHandler = { [weak coordinator = context.coordinator] item in
            coordinator?.quickLook(item: item)
        }
        collectionView.deleteHandler = { [weak coordinator = context.coordinator] in
            coordinator?.deleteSelection()
        }
        collectionView.selectionLeadHandler = { [weak coordinator = context.coordinator] item in
            coordinator?.cancelPendingSelectionPublication()
            coordinator?.publishSelectionAndLead(item: item)
        }
        collectionView.contextMenuHandler = { [weak coordinator = context.coordinator] item in
            coordinator?.contextMenu(for: item)
        }

        context.coordinator.collectionView = collectionView
        scrollView.documentView = collectionView
        context.coordinator.replaceSnapshot(with: self, in: collectionView, force: true)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let collectionView = scrollView.documentView as? LargeFileNSCollectionView else {
            return
        }
        context.coordinator.replaceSnapshot(with: self, in: collectionView, force: false)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        guard let collectionView = scrollView.documentView as? LargeFileNSCollectionView else {
            return
        }
        coordinator.cancelVisibleThumbnailRequests(in: collectionView)
        coordinator.cancelPendingSelectionPublication()
        collectionView.delegate = nil
        collectionView.dataSource = nil
    }
}

// MARK: - Coordinator

extension LargeFileGridView {
    @MainActor
    final class Coordinator: NSObject,
        NSCollectionViewDataSource,
        NSCollectionViewDelegate,
        NSCollectionViewDelegateFlowLayout
    {
        fileprivate weak var collectionView: LargeFileNSCollectionView?

        private var parent: LargeFileGridView
        private var files: [IndexedFile] = []
        private var idIndex: [String: Int] = [:]
        private var appliedContentVersion: Int?
        private var isApplyingSelection = false
        private var selectionEchoGuard = NativeSelectionEchoGuard()
        private var selectionPublicationTask: Task<Void, Never>?
        private var hasPublishedLead = false
        private var lastPublishedLeadID: String?

        init(parent: LargeFileGridView) {
            self.parent = parent
        }

        fileprivate func replaceSnapshot(
            with newParent: LargeFileGridView,
            in collectionView: LargeFileNSCollectionView,
            force: Bool
        ) {
            parent = newParent
            let contentChanged = force || appliedContentVersion != newParent.contentVersion
            if contentChanged {
                selectionPublicationTask?.cancel()
                selectionPublicationTask = nil
                selectionEchoGuard.cancelPendingNativeSelection()
                cancelVisibleThumbnailRequests(in: collectionView)
                files = newParent.files
                idIndex = newParent.idIndex
                appliedContentVersion = newParent.contentVersion
                collectionView.leadItem = nil
                collectionView.selectionAnchorItem = nil
                isApplyingSelection = true
                collectionView.reloadData()
                collectionView.collectionViewLayout?.invalidateLayout()
                isApplyingSelection = false
            }
            synchronizeSelection(in: collectionView)
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            numberOfItemsInSection section: Int
        ) -> Int {
            section == 0 ? files.count : 0
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            itemForRepresentedObjectAt indexPath: IndexPath
        ) -> NSCollectionViewItem {
            let item = collectionView.makeItem(
                withIdentifier: LargeFileGridItem.reuseIdentifier,
                for: indexPath
            )
            guard let gridItem = item as? LargeFileGridItem,
                  indexPath.item >= 0,
                  indexPath.item < files.count else {
                return item
            }
            let file = files[indexPath.item]
            gridItem.configure(
                file: file,
                isSelected: NativeGridSelectionAppearance.isSelected(
                    item: indexPath.item,
                    selection: collectionView.selectionIndexPaths
                )
            ) { [weak self] in
                self?.activate(item: indexPath.item)
            }
            return gridItem
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            willDisplay item: NSCollectionViewItem,
            forRepresentedObjectAt indexPath: IndexPath
        ) {
            guard let gridItem = item as? LargeFileGridItem else { return }
            gridItem.applySelectionAppearance(
                NativeGridSelectionAppearance.isSelected(
                    item: indexPath.item,
                    selection: collectionView.selectionIndexPaths
                )
            )
            gridItem.startThumbnailRequest()
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            didEndDisplaying item: NSCollectionViewItem,
            forRepresentedObjectAt indexPath: IndexPath
        ) {
            (item as? LargeFileGridItem)?.cancelThumbnailRequest()
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            didSelectItemsAt indexPaths: Set<IndexPath>
        ) {
            guard !isApplyingSelection else { return }
            refreshSelectionAppearance(
                for: indexPaths,
                in: collectionView
            )
            let nativeLead = (collectionView as? LargeFileNSCollectionView)?.leadItem
            let preferredLead = nativeLead.flatMap { item in
                collectionView.selectionIndexPaths.contains(IndexPath(item: item, section: 0))
                    ? item
                    : nil
            } ?? indexPaths.sorted(by: indexPathOrder).last?.item
            scheduleSelectionPublication(preferredLead: preferredLead)
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            didDeselectItemsAt indexPaths: Set<IndexPath>
        ) {
            guard !isApplyingSelection else { return }
            refreshSelectionAppearance(
                for: indexPaths,
                in: collectionView
            )
            scheduleSelectionPublication(
                preferredLead: (collectionView as? LargeFileNSCollectionView)?.leadItem
            )
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            pasteboardWriterForItemAt indexPath: IndexPath
        ) -> (any NSPasteboardWriting)? {
            guard indexPath.item >= 0, indexPath.item < files.count else { return nil }
            return files[indexPath.item].url as NSURL
        }

        fileprivate func activate(item: Int) {
            guard item >= 0, item < files.count else { return }
            parent.onDoubleClick(files[item])
        }

        fileprivate func quickLook(item: Int) {
            guard item >= 0, item < files.count else { return }
            parent.onQuickLook(files[item])
        }

        fileprivate func deleteSelection() {
            guard collectionView?.selectionIndexPaths.isEmpty == false else { return }
            parent.onDelete()
        }

        fileprivate func publishSelectionAndLead(item: Int?) {
            guard let collectionView, !isApplyingSelection else { return }
            let selectedIDs = selectedFileIDs(in: collectionView)
            selectionEchoGuard.nativeSelectionDidChange(to: selectedIDs)
            if parent.selection != selectedIDs {
                parent.selection = selectedIDs
            }
            selectionEchoGuard.nativeSelectionPublicationDidComplete()
            refreshVisibleSelectionAppearance(in: collectionView)
            let lead = item.flatMap { index in
                index >= 0 && index < files.count ? files[index] : nil
            }
            if !hasPublishedLead || lead?.id != lastPublishedLeadID {
                hasPublishedLead = true
                lastPublishedLeadID = lead?.id
                parent.onSelectionLeadChange(lead)
            }
        }

        fileprivate func cancelPendingSelectionPublication() {
            selectionPublicationTask?.cancel()
            selectionPublicationTask = nil
        }

        fileprivate func contextMenu(for item: Int) -> NSMenu? {
            guard item >= 0,
                  item < files.count,
                  let contextMenuProvider = parent.contextMenuProvider else { return nil }
            let selectedIDs = collectionView.map(selectedFileIDs(in:)) ?? []
            return contextMenuProvider(files[item], selectedIDs)
        }

        fileprivate func cancelVisibleThumbnailRequests(in collectionView: NSCollectionView) {
            for item in collectionView.visibleItems() {
                (item as? LargeFileGridItem)?.cancelThumbnailRequest()
            }
        }

        private func synchronizeSelection(in collectionView: NSCollectionView) {
            var indexPaths = Set<IndexPath>()
            indexPaths.reserveCapacity(parent.selection.count)
            for fileID in parent.selection {
                if let item = idIndex[fileID], item >= 0, item < files.count {
                    indexPaths.insert(IndexPath(item: item, section: 0))
                }
            }
            if selectionEchoGuard.shouldApplyExternalSelection(parent.selection),
               collectionView.selectionIndexPaths != indexPaths {
                isApplyingSelection = true
                collectionView.selectionIndexPaths = indexPaths
                isApplyingSelection = false
            }
            // NSCollectionView's selection set can already be correct while a
            // recycled visible item's `isSelected` property remains stale.
            // Reconcile the materialized views even when this update is only
            // the SwiftUI echo of the native click.
            refreshVisibleSelectionAppearance(in: collectionView)
        }

        private func refreshSelectionAppearance(
            for indexPaths: Set<IndexPath>,
            in collectionView: NSCollectionView
        ) {
            for indexPath in indexPaths {
                guard let item = collectionView.item(at: indexPath) as? LargeFileGridItem else {
                    continue
                }
                item.applySelectionAppearance(
                    NativeGridSelectionAppearance.isSelected(
                        item: indexPath.item,
                        selection: collectionView.selectionIndexPaths
                    )
                )
            }
        }

        private func refreshVisibleSelectionAppearance(in collectionView: NSCollectionView) {
            for case let item as LargeFileGridItem in collectionView.visibleItems() {
                guard let indexPath = collectionView.indexPath(for: item) else { continue }
                item.applySelectionAppearance(
                    NativeGridSelectionAppearance.isSelected(
                        item: indexPath.item,
                        selection: collectionView.selectionIndexPaths
                    )
                )
            }
        }

        private func selectedFileIDs(in collectionView: NSCollectionView) -> Set<String> {
            var result = Set<String>()
            result.reserveCapacity(collectionView.selectionIndexPaths.count)
            for indexPath in collectionView.selectionIndexPaths
            where indexPath.item >= 0 && indexPath.item < files.count {
                result.insert(files[indexPath.item].id)
            }
            return result
        }

        private func scheduleSelectionPublication(preferredLead: Int?) {
            if let collectionView {
                selectionEchoGuard.nativeSelectionDidChange(
                    to: selectedFileIDs(in: collectionView)
                )
            }
            selectionPublicationTask?.cancel()
            selectionPublicationTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self, let collectionView = self.collectionView else {
                    return
                }
                let lead = preferredLead.flatMap { item in
                    collectionView.selectionIndexPaths.contains(
                        IndexPath(item: item, section: 0)
                    ) ? item : nil
                } ?? collectionView.selectionIndexPaths.min(by: {
                    $0.item < $1.item
                })?.item
                self.publishSelectionAndLead(item: lead)
                self.selectionPublicationTask = nil
            }
        }

        private func indexPathOrder(_ lhs: IndexPath, _ rhs: IndexPath) -> Bool {
            lhs.item < rhs.item
        }
    }
}

// MARK: - Virtualized layout

/// Immutable geometry for one prepared collection-view width.
///
/// AppKit can ask for the content size, visible attributes and individual item
/// attributes at different moments during a resize. Keeping all three answers
/// on one geometry snapshot prevents old/new column counts from being mixed in
/// the same layout pass.
struct NativeGridLayoutPolicy: Equatable {
    static let minimumItemWidth: CGFloat = 132
    static let itemHeight: CGFloat = 148
    static let interitemSpacing: CGFloat = 14
    static let lineSpacing: CGFloat = 14
    static let sectionInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

    let itemCount: Int
    let containerWidth: CGFloat
    let columns: Int
    let itemWidth: CGFloat
    let rowStride: CGFloat

    init(itemCount: Int, containerWidth: CGFloat) {
        self.itemCount = max(itemCount, 0)
        self.containerWidth = max(containerWidth, 0)
        let available = max(
            self.containerWidth - Self.sectionInsets.left - Self.sectionInsets.right,
            1
        )
        let proposedColumns = Int(
            floor(
                (available + Self.interitemSpacing)
                    / (Self.minimumItemWidth + Self.interitemSpacing)
            )
        )
        columns = max(proposedColumns, 1)
        itemWidth = max(
            floor(
                (available - CGFloat(columns - 1) * Self.interitemSpacing)
                    / CGFloat(columns)
            ),
            1
        )
        rowStride = Self.itemHeight + Self.lineSpacing
    }

    var contentSize: NSSize {
        let rows = itemCount == 0
            ? 0
            : Int(ceil(Double(itemCount) / Double(columns)))
        let rowsHeight = rows == 0
            ? 0
            : CGFloat(rows) * Self.itemHeight + CGFloat(rows - 1) * Self.lineSpacing
        let minimumContentWidth = Self.sectionInsets.left + itemWidth + Self.sectionInsets.right
        return NSSize(
            width: max(containerWidth, minimumContentWidth),
            height: Self.sectionInsets.top + rowsHeight + Self.sectionInsets.bottom
        )
    }

    func frame(forItem item: Int) -> NSRect? {
        guard item >= 0, item < itemCount else { return nil }
        let row = item / columns
        let column = item % columns
        return NSRect(
            x: Self.sectionInsets.left
                + CGFloat(column) * (itemWidth + Self.interitemSpacing),
            y: Self.sectionInsets.top + CGFloat(row) * rowStride,
            width: itemWidth,
            height: Self.itemHeight
        )
    }

    /// Generates only the rows intersecting `rect`; this remains O(visible
    /// rows) even for a six-figure snapshot.
    func itemFrames(intersecting rect: NSRect) -> [(item: Int, frame: NSRect)] {
        guard itemCount > 0, !rect.isEmpty else { return [] }
        let firstRow = max(
            Int(floor((rect.minY - Self.sectionInsets.top) / rowStride)),
            0
        )
        let maximumRow = max(
            Int(floor((rect.maxY - Self.sectionInsets.top) / rowStride)),
            firstRow
        )
        let firstItem = firstRow * columns
        guard firstItem < itemCount else { return [] }
        let endItem = min((maximumRow + 1) * columns, itemCount)

        var frames: [(item: Int, frame: NSRect)] = []
        frames.reserveCapacity(max(endItem - firstItem, 0))
        for item in firstItem..<endItem {
            guard let frame = frame(forItem: item), frame.intersects(rect) else { continue }
            frames.append((item, frame))
        }
        return frames
    }
}

/// Fixed-height adaptive grid whose work is proportional to visible rows, not
/// the number of indexed files. `NSCollectionViewFlowLayout` may ask for
/// attributes throughout a very large content range; this layout never builds
/// or retains a 100k-item attributes array.
@MainActor
private final class LargeFileGridLayout: NSCollectionViewLayout {
    private var preparedPolicy = NativeGridLayoutPolicy(itemCount: 0, containerWidth: 0)

    override func prepare() {
        super.prepare()
        guard let collectionView else {
            preparedPolicy = NativeGridLayoutPolicy(itemCount: 0, containerWidth: 0)
            return
        }
        preparedPolicy = NativeGridLayoutPolicy(
            itemCount: collectionView.numberOfItems(inSection: 0),
            containerWidth: collectionView.bounds.width
        )
    }

    override var collectionViewContentSize: NSSize {
        preparedPolicy.contentSize
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        preparedPolicy.itemFrames(intersecting: rect).map { item, frame in
            let indexPath = IndexPath(item: item, section: 0)
            let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
            attributes.frame = frame
            return attributes
        }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard indexPath.section == 0,
              let frame = preparedPolicy.frame(forItem: indexPath.item) else {
            return nil
        }
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
        attributes.frame = frame
        return attributes
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        abs(preparedPolicy.containerWidth - newBounds.width) > 0.5
    }
}

// MARK: - Collection view and item

@MainActor
final class LargeFileNSCollectionView: NSCollectionView {
    var activationHandler: ((Int) -> Void)?
    var quickLookHandler: ((Int) -> Void)?
    var deleteHandler: (() -> Void)?
    var selectionLeadHandler: ((Int?) -> Void)?
    var contextMenuHandler: ((Int) -> NSMenu?)?
    var leadItem: Int?
    var selectionAnchorItem: Int?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let clicked = indexPathForItem(at: point)?.item else {
            super.mouseDown(with: event)
            return
        }
        handleItemMouseDown(item: clicked, event: event)
    }

    /// Applies the item gesture from an `NSCollectionViewItem` whose visual
    /// subviews received the mouse event. Relying on `super.mouseDown` alone
    /// is insufficient here: AppKit sees the nested view as the hit target and
    /// may leave the collection selection unchanged.
    func handleItemMouseDown(item: Int, event: NSEvent) {
        let intendedSelection = applyItemSelectionGesture(
            item: item,
            modifiers: event.modifierFlags
        )
        selectionLeadHandler?(leadItem)

        // Keep AppKit's native tracking alive for drag initiation. Some
        // macOS versions ignore selection when the original hit view is a
        // nested image/label, so restore the explicit result afterwards.
        super.mouseDown(with: event)
        if selectionIndexPaths != intendedSelection {
            selectionIndexPaths = intendedSelection
            selectionLeadHandler?(leadItem)
        }
        if event.clickCount == 2, selectionIndexPaths.contains(
            IndexPath(item: item, section: 0)
        ) {
            activationHandler?(item)
        }
    }

    @discardableResult
    func applyItemSelectionGesture(
        item: Int,
        modifiers: NSEvent.ModifierFlags
    ) -> Set<IndexPath> {
        let clickedPath = IndexPath(item: item, section: 0)
        let previousSelection = selectionIndexPaths
        let command = modifiers.contains(.command)
        let shift = modifiers.contains(.shift)
        var updatedSelection: Set<IndexPath>

        if shift {
            let anchor = selectionAnchorItem ?? leadItem ?? item
            let lowerBound = min(anchor, item)
            let upperBound = max(anchor, item)
            let range = Set(
                (lowerBound...upperBound).map {
                    IndexPath(item: $0, section: 0)
                }
            )
            updatedSelection = command ? previousSelection.union(range) : range
            selectionAnchorItem = anchor
            leadItem = item
        } else if command {
            updatedSelection = previousSelection
            if updatedSelection.contains(clickedPath) {
                updatedSelection.remove(clickedPath)
                leadItem = NativeGridSelectionLead.updatedLead(
                    previousLead: item,
                    previousSelection: Set(previousSelection.map(\.item)),
                    newSelection: Set(updatedSelection.map(\.item))
                )
                selectionAnchorItem = leadItem
            } else {
                updatedSelection.insert(clickedPath)
                leadItem = item
                selectionAnchorItem = item
            }
        } else {
            updatedSelection = [clickedPath]
            leadItem = item
            selectionAnchorItem = item
        }

        selectionIndexPaths = updatedSelection
        return updatedSelection
    }

    override func keyDown(with event: NSEvent) {
        let previousSelection = Set(selectionIndexPaths.map(\.item))
        let previousLead = leadItem
        let selectedItem = leadItem.flatMap { item in
            selectionIndexPaths.contains(IndexPath(item: item, section: 0)) ? item : nil
        } ?? selectionIndexPaths.min(by: { $0.item < $1.item })?.item

        if event.keyCode == 36 || event.keyCode == 76 {
            if let selectedItem { activationHandler?(selectedItem) }
            return
        }
        if event.keyCode == 49 {
            if let selectedItem { quickLookHandler?(selectedItem) }
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            deleteHandler?()
            return
        }
        super.keyDown(with: event)
        guard Self.arrowKeyCodes.contains(event.keyCode) else { return }
        let updatedLead = NativeGridSelectionLead.updatedLead(
            previousLead: previousLead,
            previousSelection: previousSelection,
            newSelection: Set(selectionIndexPaths.map(\.item))
        )
        leadItem = updatedLead
        if !event.modifierFlags.contains(.shift) {
            selectionAnchorItem = updatedLead
        }
        selectionLeadHandler?(updatedLead)
    }

    private static let arrowKeyCodes: Set<UInt16> = [123, 124, 125, 126]

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let clicked = indexPathForItem(at: point)?.item else {
            return super.menu(for: event)
        }
        let clickedPath = IndexPath(item: clicked, section: 0)
        if !selectionIndexPaths.contains(clickedPath) {
            selectionIndexPaths = [clickedPath]
        }
        leadItem = clicked
        selectionAnchorItem = clicked
        selectionLeadHandler?(clicked)
        return contextMenuHandler?(clicked) ?? super.menu(for: event)
    }

    func menu(forItem item: Int, event: NSEvent) -> NSMenu? {
        let clickedPath = IndexPath(item: item, section: 0)
        if !selectionIndexPaths.contains(clickedPath) {
            selectionIndexPaths = [clickedPath]
        }
        leadItem = item
        selectionAnchorItem = item
        selectionLeadHandler?(item)
        return contextMenuHandler?(item) ?? super.menu(for: event)
    }
}

/// Infers the endpoint AppKit moved to without walking the full file snapshot.
/// `NSCollectionView` exposes only a set selection, while Finder-style Return,
/// Space and Inspector actions need the latest lead after Shift-arrow changes.
enum NativeGridSelectionLead {
    static func updatedLead(
        previousLead: Int?,
        previousSelection: Set<Int>,
        newSelection: Set<Int>
    ) -> Int? {
        guard !newSelection.isEmpty else { return nil }
        let added = newSelection.subtracting(previousSelection)
        if let previousLead, !added.isEmpty {
            return added.max {
                abs($0 - previousLead) < abs($1 - previousLead)
            }
        }
        if let only = newSelection.count == 1 ? newSelection.first : nil {
            return only
        }
        if let previousLead, previousSelection.subtracting(newSelection).isEmpty == false {
            return newSelection.min {
                abs($0 - previousLead) < abs($1 - previousLead)
            }
        }
        if let previousLead, newSelection.contains(previousLead) {
            return previousLead
        }
        return newSelection.min()
    }
}

/// Single source of truth for the visible card highlight. AppKit owns the
/// selected index paths; recycled item state is only a rendering cache.
enum NativeGridSelectionAppearance {
    static func isSelected(item: Int, selection: Set<IndexPath>) -> Bool {
        selection.contains(IndexPath(item: item, section: 0))
    }
}

@MainActor
private final class LargeFileGridItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("LargeFileGrid.Item")

    private var representedFile: IndexedFile?
    private var thumbnailTask: Task<Void, Never>?

    override func loadView() {
        view = LargeFileGridItemView(frame: .zero)
    }

    override var isSelected: Bool {
        didSet {
            (view as? LargeFileGridItemView)?.setSelected(isSelected)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelThumbnailRequest()
        representedFile = nil
        (view as? LargeFileGridItemView)?.reset()
    }

    func configure(
        file: IndexedFile,
        isSelected: Bool,
        onAccessibilityActivate: @escaping () -> Void
    ) {
        cancelThumbnailRequest()
        representedFile = file
        guard let itemView = view as? LargeFileGridItemView else { return }
        itemView.accessibilityActivation = onAccessibilityActivate
        itemView.mouseDownHandler = { [weak self] event in
            self?.handleMouseDown(event)
        }
        itemView.contextMenuHandler = { [weak self] event in
            self?.contextMenu(for: event)
        }
        itemView.configure(
            name: file.name,
            sizeText: ByteFormatting.string(forByteCount: file.size),
            placeholder: NSImage(
                systemSymbolName: file.kind.symbolName,
                accessibilityDescription: nil
            )
        )
        itemView.setSelected(isSelected)
    }

    func applySelectionAppearance(_ isSelected: Bool) {
        (view as? LargeFileGridItemView)?.setSelected(isSelected)
    }

    func startThumbnailRequest() {
        guard thumbnailTask == nil, let file = representedFile else { return }
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        thumbnailTask = Task { [weak self] in
            let image = await ThumbnailService.shared.thumbnail(
                for: file,
                size: CGSize(width: 88, height: 88),
                scale: scale,
                representationTypes: .thumbnail
            )
            guard !Task.isCancelled,
                  let self,
                  self.representedFile?.id == file.id,
                  let image else { return }
            (self.view as? LargeFileGridItemView)?.setThumbnail(image)
            self.thumbnailTask = nil
        }
    }

    func cancelThumbnailRequest() {
        thumbnailTask?.cancel()
        thumbnailTask = nil
    }

    private func handleMouseDown(_ event: NSEvent) {
        guard let collectionView = enclosingCollectionView,
              let indexPath = collectionView.indexPath(for: self) else {
            view.nextResponder?.mouseDown(with: event)
            return
        }
        collectionView.handleItemMouseDown(item: indexPath.item, event: event)
    }

    private func contextMenu(for event: NSEvent) -> NSMenu? {
        guard let collectionView = enclosingCollectionView,
              let indexPath = collectionView.indexPath(for: self) else {
            return nil
        }
        return collectionView.menu(forItem: indexPath.item, event: event)
    }

    private var enclosingCollectionView: LargeFileNSCollectionView? {
        var candidate = view.superview
        while let view = candidate {
            if let collectionView = view as? LargeFileNSCollectionView {
                return collectionView
            }
            candidate = view.superview
        }
        return nil
    }

}

@MainActor
final class LargeFileGridItemView: NSView {
    private let imageView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private var selected = false
    var accessibilityActivation: (() -> Void)?
    var mouseDownHandler: ((NSEvent) -> Void)?
    var contextMenuHandler: ((NSEvent) -> NSMenu?)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.setAccessibilityElement(false)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.maximumNumberOfLines = 1
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        sizeLabel.translatesAutoresizingMaskIntoConstraints = false
        sizeLabel.alignment = .center
        sizeLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.lineBreakMode = .byTruncatingTail
        sizeLabel.maximumNumberOfLines = 1
        sizeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(imageView)
        addSubview(nameLabel)
        addSubview(sizeLabel)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 88),
            imageView.heightAnchor.constraint(equalToConstant: 88),
            nameLabel.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 7),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            sizeLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            sizeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            sizeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            sizeLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -7)
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    /// Treat the visual contents as one native collection-view item. AppKit
    /// controls such as `NSImageView` and `NSTextField` otherwise become the
    /// mouse hit target and can consume the initial click before
    /// `NSCollectionView` applies its selection gesture.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard let mouseDownHandler else {
            super.mouseDown(with: event)
            return
        }
        mouseDownHandler(event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuHandler?(event) ?? super.menu(for: event)
    }

    func configure(name: String, sizeText: String, placeholder: NSImage?) {
        nameLabel.stringValue = name
        nameLabel.toolTip = name
        toolTip = name
        sizeLabel.stringValue = sizeText
        imageView.image = placeholder
        setAccessibilityLabel(AppLanguage.joinedForAccessibility([name, sizeText]))
        setAccessibilityHelp(
            AppLanguage.localized("按下以打开文件", english: "Press to open the file")
        )
    }

    func setThumbnail(_ image: NSImage) {
        imageView.image = image
    }

    func setSelected(_ isSelected: Bool) {
        selected = isSelected
        setAccessibilitySelected(isSelected)
        updateAppearance()
    }

    func reset() {
        accessibilityActivation = nil
        mouseDownHandler = nil
        contextMenuHandler = nil
        toolTip = nil
        imageView.image = nil
        nameLabel.stringValue = ""
        sizeLabel.stringValue = ""
        setAccessibilityLabel(nil)
        setSelected(false)
    }

    override func accessibilityPerformPress() -> Bool {
        guard let accessibilityActivation else { return false }
        accessibilityActivation()
        return true
    }

    private func updateAppearance() {
        layer?.backgroundColor = (
            selected
                ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.18)
                : NSColor.controlBackgroundColor.withAlphaComponent(0.32)
        ).cgColor
        layer?.borderColor = (
            selected
                ? NSColor.controlAccentColor.withAlphaComponent(0.75)
                : NSColor.separatorColor.withAlphaComponent(0.24)
        ).cgColor
    }
}
