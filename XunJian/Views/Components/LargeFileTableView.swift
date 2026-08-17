import AppKit
import QuickLookThumbnailing
import SwiftUI

/// AppKit-backed file table for very large browse snapshots.
///
/// `NSTableView` asks its delegate only for visible cells, so a 100k-file
/// snapshot does not create a 100k-row SwiftUI view graph. The caller supplies
/// the already-built ID index and a cheap content version; this component does
/// not hash or copy every row during routine SwiftUI updates.
@MainActor
struct LargeFileTableView: NSViewRepresentable {
    typealias NSViewType = NSScrollView

    let files: [IndexedFile]
    let idIndex: [String: Int]
    let contentVersion: Int
    let categoryVersion: UInt64
    let autosaveName: String
    let locale: Locale
    @Binding var selection: Set<String>

    /// Evaluated only for category cells that NSTableView makes visible.
    let categoryText: (IndexedFile) -> String
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
        categoryVersion: UInt64 = 0,
        autosaveName: String = "XunJian.AllFiles.LargeTable",
        locale: Locale = .autoupdatingCurrent,
        selection: Binding<Set<String>>,
        categoryText: @escaping (IndexedFile) -> String,
        onSelectionLeadChange: @escaping (IndexedFile?) -> Void,
        onDoubleClick: @escaping (IndexedFile) -> Void,
        onQuickLook: @escaping (IndexedFile) -> Void,
        onDelete: @escaping () -> Void,
        contextMenuProvider: ((IndexedFile, Set<String>) -> NSMenu?)? = nil
    ) {
        self.files = files
        self.idIndex = idIndex
        self.contentVersion = contentVersion
        self.categoryVersion = categoryVersion
        self.autosaveName = autosaveName
        self.locale = locale
        _selection = selection
        self.categoryText = categoryText
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
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let tableView = LargeFileNSTableView()
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.headerView = NSTableHeaderView()
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.allowsColumnSelection = false
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.selectionHighlightStyle = .regular
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.rowHeight = 34
        tableView.intercellSpacing = NSSize(width: 8, height: 1)
        tableView.style = .fullWidth
        tableView.setAccessibilityLabel(
            AppLanguage.localized("文件列表", english: "File List")
        )

        context.coordinator.installColumns(on: tableView)
        tableView.autosaveName = NSTableView.AutosaveName(autosaveName)
        tableView.autosaveTableColumns = true
        context.coordinator.installHeaderMenu(on: tableView)

        tableView.target = context.coordinator
        tableView.doubleAction = #selector(Coordinator.performDoubleClick(_:))
        tableView.activationHandler = { [weak coordinator = context.coordinator] row in
            coordinator?.activate(row: row)
        }
        tableView.quickLookHandler = { [weak coordinator = context.coordinator] row in
            coordinator?.quickLook(row: row)
        }
        tableView.deleteHandler = { [weak coordinator = context.coordinator] in
            coordinator?.deleteSelection()
        }
        tableView.selectionLeadHandler = { [weak coordinator = context.coordinator] row in
            coordinator?.publishLead(row: row)
        }
        tableView.contextMenuHandler = { [weak coordinator = context.coordinator] row in
            coordinator?.contextMenu(for: row)
        }
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: false)

        context.coordinator.tableView = tableView
        scrollView.documentView = tableView
        // NSTableView restores its autosaved width/order while it is being
        // mounted. Apply the dedicated visibility preference afterwards so
        // autosave cannot win over the explicit v4 policy on first entry.
        context.coordinator.restoreColumnVisibility(on: tableView)
        context.coordinator.replaceSnapshot(with: self, in: tableView, force: true)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tableView = scrollView.documentView as? LargeFileNSTableView else { return }
        context.coordinator.replaceSnapshot(with: self, in: tableView, force: false)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.cancelPendingSelectionPublication()
        if let tableView = scrollView.documentView as? NSTableView {
            coordinator.cancelVisibleCellRequests(in: tableView)
        }
        coordinator.stopObservingFinderTagChanges()
        coordinator.tableView?.delegate = nil
        coordinator.tableView?.dataSource = nil
    }
}

// MARK: - Coordinator

extension LargeFileTableView {
    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        fileprivate weak var tableView: LargeFileNSTableView?

        private var parent: LargeFileTableView
        private var files: [IndexedFile] = []
        private var idIndex: [String: Int] = [:]
        private var appliedContentVersion: Int?
        private var appliedCategoryVersion: UInt64?
        private var appliedLocaleIdentifier = ""
        private var isApplyingSelection = false
        private var selectionEchoGuard = NativeSelectionEchoGuard()
        private var selectionPublicationTask: Task<Void, Never>?
        private var observesFinderTagChanges = false

        init(parent: LargeFileTableView) {
            self.parent = parent
            super.init()
            startObservingFinderTagChanges()
        }

        func replaceSnapshot(
            with newParent: LargeFileTableView,
            in tableView: LargeFileNSTableView,
            force: Bool
        ) {
            parent = newParent
            let contentChanged = force || appliedContentVersion != newParent.contentVersion
            let metadataChanged = force
                || appliedCategoryVersion != newParent.categoryVersion
                || appliedLocaleIdentifier != newParent.locale.identifier

            if contentChanged {
                cancelPendingSelectionPublication()
                cancelVisibleCellRequests(in: tableView)
                files = newParent.files
                idIndex = newParent.idIndex
                appliedContentVersion = newParent.contentVersion
                selectionEchoGuard.cancelPendingNativeSelection()
                isApplyingSelection = true
                tableView.reloadData()
                isApplyingSelection = false
            } else if metadataChanged {
                reloadVisibleMetadata(in: tableView)
            }

            appliedCategoryVersion = newParent.categoryVersion
            appliedLocaleIdentifier = newParent.locale.identifier
            synchronizeSelection(in: tableView)
        }

        fileprivate func installColumns(on tableView: NSTableView) {
            for descriptor in LargeFileTableColumn.allCases {
                let column = NSTableColumn(identifier: descriptor.identifier)
                column.title = descriptor.localizedTitle
                column.minWidth = descriptor.minimumWidth
                column.width = descriptor.idealWidth
                column.maxWidth = descriptor.maximumWidth
                column.resizingMask = [.userResizingMask, .autoresizingMask]
                tableView.addTableColumn(column)
            }
        }

        fileprivate func restoreColumnVisibility(on tableView: NSTableView) {
            let defaults = UserDefaults.standard
            let key = visibilityDefaultsKey
            let storedIDs = defaults.array(forKey: key) as? [String]
            let hiddenIDs = LargeFileTableColumnVisibility.hiddenIDs(stored: storedIDs)
            for column in tableView.tableColumns {
                column.isHidden = LargeFileTableColumnVisibility.isHidden(
                    tableColumnIdentifier: column.identifier.rawValue,
                    hiddenIDs: hiddenIDs
                )
            }
            // Persist the policy result directly. Reading `tableColumns`
            // during the first AppKit mount can still report the restored
            // autosave layout and used to overwrite our defaults with `[]`.
            defaults.set(
                LargeFileTableColumnVisibility.persistedIDsAfterRestoration(
                    stored: storedIDs
                ),
                forKey: key
            )
        }

        fileprivate func installHeaderMenu(on tableView: NSTableView) {
            let menu = NSMenu(
                title: AppLanguage.localized("显示列", english: "Show Columns")
            )
            // The items have explicit targets. Disabling responder-chain auto
            // validation prevents AppKit from silently disabling them when the
            // header is not the current first responder.
            menu.autoenablesItems = false
            menu.delegate = self
            tableView.headerView?.menu = menu
            rebuildHeaderMenu(menu)
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            files.count
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard row >= 0, row < files.count,
                  let tableColumn,
                  let descriptor = LargeFileTableColumn(identifier: tableColumn.identifier) else {
                return nil
            }
            let file = files[row]

            if descriptor == .name {
                let identifier = NSUserInterfaceItemIdentifier("LargeFileTable.NameCell")
                let cell = (tableView.makeView(withIdentifier: identifier, owner: self)
                    as? LargeFileNameCellView) ?? LargeFileNameCellView(identifier: identifier)
                cell.configure(file: file, accessibilityLabel: accessibilityLabel(for: file))
                return cell
            }

            if descriptor == .tags {
                let identifier = NSUserInterfaceItemIdentifier("LargeFileTable.TagsCell")
                let cell = (tableView.makeView(withIdentifier: identifier, owner: self)
                    as? LargeFileFinderTagCellView)
                    ?? LargeFileFinderTagCellView(identifier: identifier)
                cell.configure(
                    file: file,
                    title: descriptor.localizedTitle,
                    separator: AppLanguage.listSeparator
                )
                return cell
            }

            let identifier = NSUserInterfaceItemIdentifier("LargeFileTable.\(descriptor.rawValue).Cell")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: self)
                as? LargeFileTextCellView) ?? LargeFileTextCellView(identifier: identifier)
            let cellText = text(for: descriptor, file: file)
            cell.configure(
                text: cellText,
                truncatesInMiddle: descriptor == .location,
                accessibilityLabel: "\(descriptor.localizedTitle): \(cellText)"
            )
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView = notification.object as? NSTableView,
                  !isApplyingSelection else { return }
            // NSTableView can report one ordinary A → B click as two delegate
            // callbacks: first an empty selection, then B. Mark the native
            // gesture authoritative immediately so an unrelated SwiftUI
            // update cannot restore A between those callbacks, but publish
            // only the final state on the next main-actor turn.
            selectionEchoGuard.nativeSelectionDidChange(
                to: selectedFileIDs(in: tableView)
            )
            selectionPublicationTask?.cancel()
            selectionPublicationTask = Task { @MainActor [weak self, weak tableView] in
                await Task.yield()
                guard !Task.isCancelled, let self, let tableView else { return }
                self.publishSelectionAndLead(in: tableView)
                self.selectionPublicationTask = nil
            }
        }

        func tableView(
            _ tableView: NSTableView,
            didRemove rowView: NSTableRowView,
            forRow row: Int
        ) {
            let nameColumn = LargeFileTableColumn.name.currentIndex(in: tableView)
            if nameColumn >= 0 {
                (rowView.view(atColumn: nameColumn) as? LargeFileNameCellView)?
                    .cancelThumbnailRequest()
            }
            let tagsColumn = LargeFileTableColumn.tags.currentIndex(in: tableView)
            if tagsColumn >= 0 {
                (rowView.view(atColumn: tagsColumn) as? LargeFileFinderTagCellView)?
                    .cancelTagRequest()
            }
        }

        func tableView(
            _ tableView: NSTableView,
            typeSelectStringFor tableColumn: NSTableColumn?,
            row: Int
        ) -> String? {
            guard row >= 0, row < files.count else { return nil }
            return files[row].name
        }

        func tableView(
            _ tableView: NSTableView,
            pasteboardWriterForRow row: Int
        ) -> (any NSPasteboardWriting)? {
            guard row >= 0, row < files.count else { return nil }
            return files[row].url as NSURL
        }

        @objc fileprivate func performDoubleClick(_ sender: NSTableView) {
            let row = sender.clickedRow >= 0 ? sender.clickedRow : sender.selectedRow
            activate(row: row)
        }

        fileprivate func activate(row: Int) {
            guard row >= 0, row < files.count else { return }
            parent.onDoubleClick(files[row])
        }

        fileprivate func quickLook(row: Int) {
            guard row >= 0, row < files.count else { return }
            parent.onQuickLook(files[row])
        }

        fileprivate func deleteSelection() {
            guard tableView?.selectedRowIndexes.isEmpty == false else { return }
            parent.onDelete()
        }

        fileprivate func publishLead(row: Int) {
            guard row >= 0, row < files.count else {
                parent.onSelectionLeadChange(nil)
                return
            }
            parent.onSelectionLeadChange(files[row])
        }

        fileprivate func cancelPendingSelectionPublication() {
            selectionPublicationTask?.cancel()
            selectionPublicationTask = nil
        }

        fileprivate func contextMenu(for row: Int) -> NSMenu? {
            guard row >= 0, row < files.count,
                  let contextMenuProvider = parent.contextMenuProvider else { return nil }
            let selectedIDs = tableView.map(selectedFileIDs(in:)) ?? []
            return contextMenuProvider(files[row], selectedIDs)
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            rebuildHeaderMenu(menu)
        }

        @objc private func toggleColumn(_ sender: NSMenuItem) {
            guard let rawID = sender.representedObject as? String,
                  let tableView,
                  let descriptor = LargeFileTableColumn(rawValue: rawID) else { return }
            let currentHiddenIDs = LargeFileTableColumnVisibility.persistedHiddenIDs(
                columnStates: tableView.tableColumns.map {
                    ($0.identifier.rawValue, $0.isHidden)
                }
            )
            let hiddenIDs = LargeFileTableColumnVisibility.toggledHiddenIDs(
                current: Set(currentHiddenIDs),
                column: descriptor
            )
            for column in tableView.tableColumns {
                column.isHidden = LargeFileTableColumnVisibility.isHidden(
                    tableColumnIdentifier: column.identifier.rawValue,
                    hiddenIDs: hiddenIDs
                )
            }
            persistColumnVisibility(from: tableView)
            tableView.tile()
            sender.state = hiddenIDs.contains(rawID) ? .off : .on
            guard descriptor == .tags else { return }
            if hiddenIDs.contains(rawID) {
                cancelVisibleFinderTagRequests(in: tableView)
            } else {
                reloadVisibleFinderTags(in: tableView)
            }
        }

        fileprivate func cancelVisibleCellRequests(in tableView: NSTableView) {
            cancelVisibleThumbnailRequests(in: tableView)
            cancelVisibleFinderTagRequests(in: tableView)
        }

        fileprivate func stopObservingFinderTagChanges() {
            guard observesFinderTagChanges else { return }
            NotificationCenter.default.removeObserver(
                self,
                name: .xunJianFinderTagsDidChange,
                object: nil
            )
            observesFinderTagChanges = false
        }

        private func synchronizeSelection(in tableView: NSTableView) {
            let shouldApply = selectionEchoGuard.shouldApplyExternalSelection(parent.selection)
            guard shouldApply else {
                return
            }
            var rows = IndexSet()
            for fileID in parent.selection {
                if let row = idIndex[fileID], row >= 0, row < files.count {
                    rows.insert(row)
                }
            }
            guard tableView.selectedRowIndexes != rows else { return }
            isApplyingSelection = true
            tableView.selectRowIndexes(rows, byExtendingSelection: false)
            isApplyingSelection = false
        }

        private func selectedFileIDs(in tableView: NSTableView) -> Set<String> {
            var result = Set<String>()
            result.reserveCapacity(tableView.selectedRowIndexes.count)
            for row in tableView.selectedRowIndexes where row >= 0 && row < files.count {
                result.insert(files[row].id)
            }
            return result
        }

        private func publishSelectionAndLead(in tableView: NSTableView) {
            guard !isApplyingSelection else { return }
            let selectedIDs = selectedFileIDs(in: tableView)
            selectionEchoGuard.nativeSelectionDidChange(
                to: selectedIDs
            )
            if parent.selection != selectedIDs {
                parent.selection = selectedIDs
            }
            selectionEchoGuard.nativeSelectionPublicationDidComplete()
            publishLead(row: tableView.selectedRow)
        }

        private func reloadVisibleMetadata(in tableView: NSTableView) {
            let visibleRows = tableView.rows(in: tableView.visibleRect).integerIndexes
            guard !visibleRows.isEmpty else { return }
            tableView.reloadData(
                forRowIndexes: visibleRows,
                columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns)
            )
        }

        private func text(for column: LargeFileTableColumn, file: IndexedFile) -> String {
            switch column {
            case .name:
                return file.name
            case .category:
                let text = parent.categoryText(file)
                return text.isEmpty ? "—" : text
            case .kind:
                return file.kind.localizedTitle
            case .size:
                return ByteFormatting.string(forByteCount: file.size)
            case .modified:
                return dateText(file.modifiedAt)
            case .created:
                return dateText(file.createdAt)
            case .tags:
                // The native tags cell reads Finder metadata only while its
                // row is visible. Finder tags intentionally never enter the
                // six-figure browse snapshot.
                return "—"
            case .location:
                return file.parentPath
            }
        }

        private func dateText(_ date: Date?) -> String {
            guard let date else { return "—" }
            return FinderDateFormatting.formatter(for: parent.locale).string(from: date)
        }

        private func accessibilityLabel(for file: IndexedFile) -> String {
            [
                file.name,
                file.kind.localizedTitle,
                ByteFormatting.string(forByteCount: file.size),
                dateText(file.modifiedAt),
                file.parentPath
            ].joined(separator: ", ")
        }

        private var visibilityDefaultsKey: String {
            LargeFileTableColumnVisibility.storageKey(
                autosaveName: parent.autosaveName
            )
        }

        private func persistColumnVisibility(from tableView: NSTableView) {
            let hidden = LargeFileTableColumnVisibility.persistedHiddenIDs(
                columnStates: tableView.tableColumns.map {
                    ($0.identifier.rawValue, $0.isHidden)
                }
            )
            UserDefaults.standard.set(hidden, forKey: visibilityDefaultsKey)
        }

        private func rebuildHeaderMenu(_ menu: NSMenu) {
            guard let tableView else { return }
            menu.removeAllItems()
            for column in tableView.tableColumns {
                guard let descriptor = LargeFileTableColumn(identifier: column.identifier) else {
                    continue
                }
                let item = NSMenuItem(
                    title: descriptor.localizedTitle,
                    action: #selector(toggleColumn(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = descriptor.rawValue
                item.state = column.isHidden ? .off : .on
                item.isEnabled = descriptor != .name
                menu.addItem(item)
            }
        }

        private func startObservingFinderTagChanges() {
            guard !observesFinderTagChanges else { return }
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(finderTagsDidChange(_:)),
                name: .xunJianFinderTagsDidChange,
                object: nil
            )
            observesFinderTagChanges = true
        }

        @objc private func finderTagsDidChange(_ notification: Notification) {
            guard let changedFileIDs = notification.object as? Set<String>,
                  let tableView else { return }
            let visibleRows = tableView.rows(in: tableView.visibleRect).integerIndexes
            let affectedRows = NativeFinderTagReloadPolicy.affectedVisibleRows(
                changedFileIDs: changedFileIDs,
                idIndex: idIndex,
                visibleRows: visibleRows
            )
            guard !affectedRows.isEmpty else { return }
            reloadFinderTags(in: tableView, rows: affectedRows)
        }

        private func reloadVisibleFinderTags(in tableView: NSTableView) {
            reloadFinderTags(
                in: tableView,
                rows: tableView.rows(in: tableView.visibleRect).integerIndexes
            )
        }

        private func reloadFinderTags(in tableView: NSTableView, rows: IndexSet) {
            let columnIndex = LargeFileTableColumn.tags.currentIndex(in: tableView)
            guard columnIndex >= 0,
                  !tableView.tableColumns[columnIndex].isHidden,
                  !rows.isEmpty else { return }
            for row in rows {
                (tableView.view(
                    atColumn: columnIndex,
                    row: row,
                    makeIfNecessary: false
                ) as? LargeFileFinderTagCellView)?.cancelTagRequest()
            }
            tableView.reloadData(
                forRowIndexes: rows,
                columnIndexes: IndexSet(integer: columnIndex)
            )
        }

        private func cancelVisibleThumbnailRequests(in tableView: NSTableView) {
            let columnIndex = LargeFileTableColumn.name.currentIndex(in: tableView)
            guard columnIndex >= 0 else { return }
            for row in tableView.rows(in: tableView.visibleRect).integerIndexes {
                (tableView.view(
                    atColumn: columnIndex,
                    row: row,
                    makeIfNecessary: false
                ) as? LargeFileNameCellView)?.cancelThumbnailRequest()
            }
        }

        private func cancelVisibleFinderTagRequests(in tableView: NSTableView) {
            let columnIndex = LargeFileTableColumn.tags.currentIndex(in: tableView)
            guard columnIndex >= 0 else { return }
            for row in tableView.rows(in: tableView.visibleRect).integerIndexes {
                (tableView.view(
                    atColumn: columnIndex,
                    row: row,
                    makeIfNecessary: false
                ) as? LargeFileFinderTagCellView)?.cancelTagRequest()
            }
        }
    }
}

// MARK: - Table and cells

@MainActor
final class LargeFileNSTableView: NSTableView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    var activationHandler: ((Int) -> Void)?
    var quickLookHandler: ((Int) -> Void)?
    var deleteHandler: (() -> Void)?
    var selectionLeadHandler: ((Int) -> Void)?
    var contextMenuHandler: ((Int) -> NSMenu?)?
    private(set) var leadRow: Int?
    private(set) var selectionAnchorRow: Int?
    private var pendingMouseDownEvent: NSEvent?
    private var pendingMouseDownRow: Int?

    /// Route every visible data-row hit to NSTableView itself. Read-only cell
    /// labels and images must not consume the first click merely to establish
    /// focus; Finder-style selection is an atomic row operation.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = superview.map { convert(point, from: $0) } ?? point
        let hitRow = row(at: localPoint)
        if hitRow >= 0 { return self }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let localPoint = event.window == nil
            ? event.locationInWindow
            : convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: localPoint)
        guard clickedRow >= 0 else {
            super.mouseDown(with: event)
            return
        }
        pendingMouseDownEvent = event
        pendingMouseDownRow = clickedRow
        handleNameCellMouseDown(row: clickedRow, event: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mouseDownEvent = pendingMouseDownEvent,
              let row = pendingMouseDownRow else {
            super.mouseDragged(with: event)
            return
        }
        pendingMouseDownEvent = nil
        pendingMouseDownRow = nil
        continueNativeDragTracking(row: row, mouseDownEvent: mouseDownEvent)
    }

    override func mouseUp(with event: NSEvent) {
        pendingMouseDownEvent = nil
        pendingMouseDownRow = nil
    }

    /// Handles a left click whose original AppKit hit target was a visual
    /// child of the name cell. Apply one atomic Finder-style mutation instead
    /// of replaying this event through NSTableView's two-phase deselect/select
    /// tracker. Double-click and drag continuation are handled separately.
    func handleNameCellMouseDown(row: Int, event: NSEvent) {
        guard row >= 0, row < numberOfRows else { return }
        let intendedSelection = applyRowSelectionGesture(
            row: row,
            modifiers: event.modifierFlags
        )
        selectionLeadHandler?(leadRow ?? -1)
        if event.clickCount == 2, intendedSelection.contains(row) {
            activationHandler?(row)
        }
    }

    /// Enter AppKit's blocking drag tracker only after the name cell has
    /// actually received a drag event. The original mouse-down has already
    /// selected exactly once, so any tracking-only mutation is restored.
    func continueNativeDragTracking(row: Int, mouseDownEvent: NSEvent) {
        guard row >= 0, row < numberOfRows else { return }
        let intendedSelection = selectedRowIndexes
        super.mouseDown(with: mouseDownEvent)
        guard selectedRowIndexes != intendedSelection else { return }
        selectRowIndexes(intendedSelection, byExtendingSelection: false)
        if intendedSelection.contains(row) {
            leadRow = row
        }
        selectionLeadHandler?(leadRow ?? -1)
    }

    @discardableResult
    func applyRowSelectionGesture(
        row: Int,
        modifiers: NSEvent.ModifierFlags
    ) -> IndexSet {
        guard row >= 0, row < numberOfRows else { return selectedRowIndexes }
        let result = LargeFileTableSelectionPolicy.result(
            previousSelection: selectedRowIndexes,
            row: row,
            previousLead: leadRow,
            previousAnchor: selectionAnchorRow,
            modifiers: modifiers
        )
        leadRow = result.leadRow
        selectionAnchorRow = result.anchorRow
        if selectedRowIndexes != result.rows {
            selectRowIndexes(result.rows, byExtendingSelection: false)
        }
        return result.rows
    }

    override func keyDown(with event: NSEvent) {
        // Return and Enter use the same primary action as a double-click.
        if event.keyCode == 36 || event.keyCode == 76 {
            activationHandler?(selectedRow)
            return
        }
        if event.keyCode == 49 {
            quickLookHandler?(selectedRow)
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            deleteHandler?()
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let clicked = row(at: convert(event.locationInWindow, from: nil))
        guard clicked >= 0 else { return super.menu(for: event) }
        if !selectedRowIndexes.contains(clicked) {
            selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
        }
        return contextMenuHandler?(clicked) ?? super.menu(for: event)
    }
}

struct LargeFileTableSelectionResult: Equatable {
    let rows: IndexSet
    let leadRow: Int?
    let anchorRow: Int?
}

enum LargeFileTableSelectionPolicy {
    static func result(
        previousSelection: IndexSet,
        row: Int,
        previousLead: Int?,
        previousAnchor: Int?,
        modifiers: NSEvent.ModifierFlags
    ) -> LargeFileTableSelectionResult {
        let command = modifiers.contains(.command)
        let shift = modifiers.contains(.shift)

        if shift {
            let anchor = previousAnchor ?? previousLead ?? previousSelection.first ?? row
            var rows = IndexSet(integersIn: min(anchor, row)..<(max(anchor, row) + 1))
            if command {
                rows.formUnion(previousSelection)
            }
            return LargeFileTableSelectionResult(
                rows: rows,
                leadRow: row,
                anchorRow: anchor
            )
        }

        if command {
            var rows = previousSelection
            if rows.contains(row) {
                rows.remove(row)
                let lead = rows.integerLessThan(row) ?? rows.integerGreaterThan(row)
                return LargeFileTableSelectionResult(
                    rows: rows,
                    leadRow: lead,
                    anchorRow: lead
                )
            }
            rows.insert(row)
            return LargeFileTableSelectionResult(rows: rows, leadRow: row, anchorRow: row)
        }

        return LargeFileTableSelectionResult(
            rows: IndexSet(integer: row),
            leadRow: row,
            anchorRow: row
        )
    }
}

@MainActor
private final class LargeFileTextCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String, truncatesInMiddle: Bool, accessibilityLabel: String) {
        label.stringValue = text
        label.toolTip = text
        label.lineBreakMode = truncatesInMiddle ? .byTruncatingMiddle : .byTruncatingTail
        setAccessibilityLabel(accessibilityLabel)
    }
}

/// Finder tags are not indexed. NSTableView creates this cell only for a
/// visible row, keeping metadata reads proportional to the visible viewport.
/// Reconfiguration, scrolling offscreen, hiding the column, and dismantling
/// the table all cancel the cell-owned task.
@MainActor
private final class LargeFileFinderTagCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private var representedFileID: String?
    private var representedPath: String?
    private var tagTask: Task<Void, Never>?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(file: IndexedFile, title: String, separator: String) {
        let identityChanged = representedFileID != file.id || representedPath != file.path
        tagTask?.cancel()
        representedFileID = file.id
        representedPath = file.path
        if identityChanged {
            apply(tags: [], title: title, separator: separator)
        }

        tagTask = Task { [weak self] in
            let tags = await FinderTagService.shared.tags(
                forFileID: file.id,
                path: file.path
            )
            guard !Task.isCancelled,
                  let self,
                  self.representedFileID == file.id,
                  self.representedPath == file.path else { return }
            self.apply(tags: tags, title: title, separator: separator)
            self.tagTask = nil
        }
    }

    func cancelTagRequest() {
        tagTask?.cancel()
        tagTask = nil
        representedFileID = nil
        representedPath = nil
    }

    private func apply(tags: [String], title: String, separator: String) {
        let text = tags.isEmpty ? "—" : tags.joined(separator: separator)
        label.stringValue = text
        label.toolTip = tags.isEmpty ? nil : text
        label.textColor = tags.isEmpty ? .tertiaryLabelColor : .labelColor
        setAccessibilityLabel("\(title): \(text)")
    }
}

@MainActor
final class LargeFileNameCellView: NSTableCellView {
    private let iconView = LargeFileNameImageView()
    private let label = LargeFileNameTextField(labelWithString: "")
    private var representedFileID: String?
    private var thumbnailTask: Task<Void, Never>?
    private var pendingMouseDownEvent: NSEvent?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setAccessibilityElement(false)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setAccessibilityElement(false)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityElement(false)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(iconView)
        addSubview(label)
        imageView = iconView
        textField = label
        iconView.routedMouseDown = { [weak self] event in
            self?.beginMouseDown(event) ?? false
        }
        label.routedMouseDown = { [weak self] event in
            self?.beginMouseDown(event) ?? false
        }
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Treat the thumbnail, label, and remaining name-column space as one
    /// native table cell. This keeps the first click from being consumed by
    /// NSTextField/NSImageView before the row gesture is applied.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = superview.map { convert(point, from: $0) } ?? point
        guard !isHidden,
              alphaValue > 0,
              bounds.contains(localPoint) else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard beginMouseDown(event) else {
            super.mouseDown(with: event)
            return
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mouseDownEvent = pendingMouseDownEvent,
              routeMouseDragToTable(mouseDownEvent) else {
            super.mouseDragged(with: event)
            return
        }
        pendingMouseDownEvent = nil
    }

    override func mouseUp(with event: NSEvent) {
        pendingMouseDownEvent = nil
        super.mouseUp(with: event)
    }

    /// NSTableCellView otherwise synthesizes its `textField` and `imageView`
    /// back into the AX tree even when both views are individually ignored.
    /// Keep this implementation view out of the AX tree so NSTableView's
    /// native outer cell remains the sole selectable accessibility element.
    override func accessibilityChildren() -> [Any]? {
        []
    }

    func configure(file: IndexedFile, accessibilityLabel: String) {
        thumbnailTask?.cancel()
        representedFileID = file.id
        toolTip = file.name
        label.stringValue = file.name
        label.toolTip = file.name
        iconView.image = NSImage(systemSymbolName: file.kind.symbolName, accessibilityDescription: nil)
        setAccessibilityLabel(accessibilityLabel)

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        thumbnailTask = Task { [weak self] in
            let image = await ThumbnailService.shared.thumbnail(
                for: file,
                size: CGSize(width: 24, height: 24),
                scale: scale,
                representationTypes: .thumbnail
            )
            guard !Task.isCancelled,
                  let self,
                  self.representedFileID == file.id,
                  let image else { return }
            self.iconView.image = image
        }
    }

    func cancelThumbnailRequest() {
        thumbnailTask?.cancel()
        thumbnailTask = nil
        representedFileID = nil
    }

    @discardableResult
    private func beginMouseDown(_ event: NSEvent) -> Bool {
        guard routeMouseDownToTable(event) else { return false }
        pendingMouseDownEvent = event
        return true
    }

    @discardableResult
    private func routeMouseDownToTable(_ event: NSEvent) -> Bool {
        var ancestor = superview
        while let view = ancestor {
            if let tableView = view as? LargeFileNSTableView {
                let row = tableView.row(for: self)
                guard row >= 0 else { return false }
                tableView.handleNameCellMouseDown(row: row, event: event)
                return true
            }
            ancestor = view.superview
        }
        return false
    }

    @discardableResult
    private func routeMouseDragToTable(_ mouseDownEvent: NSEvent) -> Bool {
        var ancestor = superview
        while let view = ancestor {
            if let tableView = view as? LargeFileNSTableView {
                let row = tableView.row(for: self)
                guard row >= 0 else { return false }
                tableView.continueNativeDragTracking(
                    row: row,
                    mouseDownEvent: mouseDownEvent
                )
                return true
            }
            ancestor = view.superview
        }
        return false
    }
}

@MainActor
private final class LargeFileNameImageView: NSImageView {
    var routedMouseDown: ((NSEvent) -> Bool)?

    /// Route thumbnail hits to the enclosing name cell instead of letting the
    /// image view consume the row's first click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard containsHit(point) else { return nil }
        return enclosingNameCell
    }

    override func mouseDown(with event: NSEvent) {
        _ = routedMouseDown?(event)
    }

    override func mouseUp(with event: NSEvent) {
        // Selection and pointer state are owned by LargeFileNameCellView.
    }

    private var enclosingNameCell: LargeFileNameCellView? {
        var ancestor = superview
        while let view = ancestor {
            if let cell = view as? LargeFileNameCellView { return cell }
            ancestor = view.superview
        }
        return nil
    }

    private func containsHit(_ point: NSPoint) -> Bool {
        let localPoint = superview.map { convert(point, from: $0) } ?? point
        return !isHidden && alphaValue > 0 && bounds.contains(localPoint)
    }
}

@MainActor
private final class LargeFileNameTextField: NSTextField {
    var routedMouseDown: ((NSEvent) -> Bool)?

    /// A label is presentation only; route glyph hits to the enclosing name
    /// cell so NSTextField never starts its own mouse tracking/field editor.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard containsHit(point) else { return nil }
        return enclosingNameCell
    }

    override func mouseDown(with event: NSEvent) {
        _ = routedMouseDown?(event)
    }

    override func mouseUp(with event: NSEvent) {
        // Selection and pointer state are owned by LargeFileNameCellView.
    }

    private var enclosingNameCell: LargeFileNameCellView? {
        var ancestor = superview
        while let view = ancestor {
            if let cell = view as? LargeFileNameCellView { return cell }
            ancestor = view.superview
        }
        return nil
    }

    private func containsHit(_ point: NSPoint) -> Bool {
        let localPoint = superview.map { convert(point, from: $0) } ?? point
        return !isHidden && alphaValue > 0 && bounds.contains(localPoint)
    }
}

enum LargeFileTableColumn: String, CaseIterable {
    case name
    case category
    case kind
    case size
    case modified
    case created
    case tags
    case location

    static let defaultHidden: Set<Self> = [.created, .tags, .location]

    var identifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("LargeFileTable.\(rawValue)")
    }

    init?(identifier: NSUserInterfaceItemIdentifier) {
        guard let value = identifier.rawValue.split(separator: ".").last,
              let column = Self(rawValue: String(value)) else { return nil }
        self = column
    }

    var localizedTitle: String {
        switch self {
        case .name: AppLanguage.localized("名称", english: "Name")
        case .category: AppLanguage.localized("分类", english: "Category")
        case .kind: AppLanguage.localized("类型", english: "Kind")
        case .size: AppLanguage.localized("大小", english: "Size")
        case .modified: AppLanguage.localized("修改时间", english: "Date Modified")
        case .created: AppLanguage.localized("创建时间", english: "Date Created")
        case .tags: AppLanguage.localized("标签", english: "Tags")
        case .location: AppLanguage.localized("位置", english: "Where")
        }
    }

    var minimumWidth: CGFloat {
        switch self {
        case .name: 150
        case .category, .kind: 55
        case .size: 60
        case .modified, .created: 100
        case .tags: 70
        case .location: 120
        }
    }

    var idealWidth: CGFloat {
        switch self {
        case .name: 280
        case .category: 100
        case .kind: 85
        case .size: 80
        case .modified, .created: 140
        case .tags: 110
        case .location: 220
        }
    }

    var maximumWidth: CGFloat {
        switch self {
        case .name: 520
        case .category, .kind, .size: 200
        case .modified, .created: 240
        case .tags: 320
        case .location: 720
        }
    }

    @MainActor
    func currentIndex(in tableView: NSTableView) -> Int {
        tableView.column(withIdentifier: identifier)
    }
}

struct LargeFileTableColumnVisibility {
    static func storageKey(autosaveName: String) -> String {
        // The original, v2 and v3 keys could be written as an empty array by
        // the broken first mount. A new namespace is the only unambiguous
        // migration; once v4 exists, an empty array is a valid user choice to
        // show every optional column.
        "LargeFileTableView.\(autosaveName).hiddenColumns.v4"
    }

    static func hiddenIDs(stored: [String]?) -> Set<String> {
        let allowed = Set(LargeFileTableColumn.allCases.map(\.rawValue))
        var hidden = stored.map(Set.init)
            ?? Set(LargeFileTableColumn.defaultHidden.map(\.rawValue))
        hidden.formIntersection(allowed)
        hidden.remove(LargeFileTableColumn.name.rawValue)
        return hidden
    }

    static func toggledHiddenIDs(
        current: Set<String>,
        column: LargeFileTableColumn
    ) -> Set<String> {
        var hidden = hiddenIDs(stored: Array(current))
        guard column != .name else { return hidden }
        if hidden.contains(column.rawValue) {
            hidden.remove(column.rawValue)
        } else {
            hidden.insert(column.rawValue)
        }
        return hidden
    }

    static func isHidden(
        tableColumnIdentifier: String,
        hiddenIDs: Set<String>
    ) -> Bool {
        guard let descriptor = LargeFileTableColumn(
            identifier: NSUserInterfaceItemIdentifier(tableColumnIdentifier)
        ), descriptor != .name else { return false }
        return hiddenIDs.contains(descriptor.rawValue)
    }

    static func persistedHiddenIDs(
        columnStates: [(identifier: String, isHidden: Bool)]
    ) -> [String] {
        let stored = columnStates.compactMap { state -> String? in
            guard state.isHidden,
                  let descriptor = LargeFileTableColumn(
                    identifier: NSUserInterfaceItemIdentifier(state.identifier)
                  ) else { return nil }
            return descriptor.rawValue
        }
        return hiddenIDs(stored: stored).sorted()
    }

    static func persistedIDsAfterRestoration(stored: [String]?) -> [String] {
        hiddenIDs(stored: stored).sorted()
    }
}

/// Pure seam used by the native table's Finder-tag notification path. A
/// metadata-only FSEvent can never trigger work for an offscreen row or a full
/// table reload.
enum NativeFinderTagReloadPolicy {
    static func affectedVisibleRows(
        changedFileIDs: Set<String>,
        idIndex: [String: Int],
        visibleRows: IndexSet
    ) -> IndexSet {
        var affected = IndexSet()
        for fileID in changedFileIDs {
            guard let row = idIndex[fileID], visibleRows.contains(row) else { continue }
            affected.insert(row)
        }
        return affected
    }
}

private extension NSRange {
    var integerIndexes: IndexSet {
        guard location != NSNotFound, length > 0 else { return [] }
        return IndexSet(integersIn: location..<(location + length))
    }
}
