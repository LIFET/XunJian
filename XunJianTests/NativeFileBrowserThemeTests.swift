import AppKit
import SwiftUI
import XCTest
@testable import XunJian

@MainActor
final class NativeFileBrowserThemeTests: XCTestCase {
    func testResultColumnFitsViewportWhenInspectorNarrowsWorkspace() async throws {
        let file = IndexedFile(id: "width-fixture", sourceID: UUID(), name: "品牌方案.md",
            path: "/tmp/width-fixture/品牌方案.md", fileExtension: "md", kind: .document,
            size: 2048, createdAt: nil, modifiedAt: Date(), indexedAt: Date(),
            textContent: String(repeating: "品牌方案需要在窄列保留真实摘要与路径。", count: 40))
        let browser = LargeFileTableView(files: [file], idIndex: [file.id: 0], contentVersion: 1,
            presentation: .results, resultQuery: "品牌", selection: .constant([file.id]), categoryText: { _ in "" },
            onSelectionLeadChange: { _ in }, onDoubleClick: { _ in }, onQuickLook: { _ in }, onDelete: {})
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: browser)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.close() }
        func findTable(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { findTable(in: $0) }.first
        }
        for width in [800.0, 320.0, 600.0] {
            window.setContentSize(NSSize(width: width, height: 500))
            try await Task.sleep(for: .milliseconds(150))
            let table = try XCTUnwrap(findTable(in: window.contentView!))
            let scroll = try XCTUnwrap(table.enclosingScrollView)
            XCTAssertLessThanOrEqual(table.rect(ofColumn: 0).maxX, scroll.contentSize.width + 1,
                                     "单列搜索结果不能在预览展开后保留旧列宽")
            let cell = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
            XCTAssertLessThanOrEqual(cell.frame.maxX, scroll.contentSize.width + 1)
            cell.layoutSubtreeIfNeeded()
            for label in cell.subviews.compactMap({ $0 as? NSTextField }) where !label.isHidden {
                XCTAssertLessThanOrEqual(label.frame.maxX, cell.bounds.maxX + 2,
                                         "标题、摘要、路径和时间均须位于单元格内")
            }
        }
    }

    func testSearchNavigationRejectsRetainedResultsWhileNewQueryStarts() {
        let store = BrowseSearchStore()
        let file = IndexedFile(id: "old-query", sourceID: UUID(), name: "old.md", path: "/tmp/old.md",
                               fileExtension: "md", kind: .document, size: 1,
                               createdAt: nil, modifiedAt: nil, indexedAt: .distantPast)
        store.setQuery("old")
        store.publishResults([file], totalCount: 1)
        let oldRevision = store.revision
        store.beginSearch(query: "new")
        XCTAssertEqual(store.results?.map(\.id), [file.id])
        XCTAssertEqual(store.revision, oldRevision)
        XCTAssertFalse(FileResultNavigationPolicy.canNavigate(
            hasResults: true, isSearching: store.isSearching,
            snapshotSignature: 1, expectedSignature: 1,
            snapshotUserSignature: 10, expectedUserSignature: 20))
    }

    func testSearchNavigationRequiresBothCurrentSnapshotSignatures() {
        func allowed(searching: Bool = false, snapshot: Int? = 1, user: Int? = 10, hasResults: Bool = true) -> Bool {
            FileResultNavigationPolicy.canNavigate(hasResults: hasResults, isSearching: searching,
                snapshotSignature: snapshot, expectedSignature: 1,
                snapshotUserSignature: user, expectedUserSignature: 10)
        }
        XCTAssertTrue(allowed())
        XCTAssertFalse(allowed(searching: true))
        XCTAssertFalse(allowed(snapshot: 0))
        XCTAssertFalse(allowed(snapshot: nil))
        XCTAssertFalse(allowed(user: 9))
        XCTAssertFalse(allowed(user: nil))
        XCTAssertFalse(allowed(hasResults: false))
    }

    func testSearchArrowsWithoutResultNavigationRemainNative() {
        let field = NativeSearchField(
            text: .constant("方案"), isFocused: .constant(true), prompt: "Search",
            accessibilityLabel: "Search", accessibilityHelp: "",
            onSubmit: { _ in }, onCancel: {}
        )
        let coordinator = field.makeCoordinator()
        let editor = NSTextView()
        for selector in [#selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:))] {
            XCTAssertFalse(coordinator.control(NSSearchField(), textView: editor, doCommandBy: selector))
        }
    }

    func testSearchArrowsDoNotInterruptMarkedTextComposition() {
        var navigationCalls = 0
        let field = NativeSearchField(
            text: .constant(""), isFocused: .constant(true), prompt: "Search",
            accessibilityLabel: "Search", accessibilityHelp: "",
            onSubmit: { _ in }, onMoveSelection: { _ in navigationCalls += 1; return true }, onCancel: {}
        )
        let coordinator = field.makeCoordinator()
        let editor = NSTextView()
        editor.setMarkedText("pin", selectedRange: NSRange(location: 3, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        for selector in [#selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:))] {
            XCTAssertFalse(coordinator.control(NSSearchField(), textView: editor, doCommandBy: selector))
        }
        XCTAssertEqual(navigationCalls, 0)
    }

    func testSearchArrowsHonorResultNavigationHandledStatus() {
        var directions: [Int] = []
        var hasResults = false
        let field = NativeSearchField(
            text: .constant("方案"), isFocused: .constant(true), prompt: "Search",
            accessibilityLabel: "Search", accessibilityHelp: "",
            onSubmit: { _ in }, onMoveSelection: { offset in
                guard hasResults else { return false }
                directions.append(offset)
                return true
            }, onCancel: {}
        )
        let coordinator = field.makeCoordinator()
        let editor = NSTextView()
        let control = NSSearchField()
        XCTAssertFalse(coordinator.control(control, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        XCTAssertTrue(directions.isEmpty)
        hasResults = true
        XCTAssertTrue(coordinator.control(control, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        XCTAssertTrue(coordinator.control(control, textView: editor, doCommandBy: #selector(NSResponder.moveUp(_:))))
        XCTAssertEqual(directions, [1, -1])
    }

    func testRichResultsUseOnlyAvailableContentAndBoundTheirExcerpt() {
        let missing = FileResultPresentation.summary(textContent: nil, query: "方案", metadata: "PDF · 4 KB")
        XCTAssertEqual(missing.text, "PDF · 4 KB")
        XCTAssertFalse(missing.isContent)
        XCTAssertFalse(missing.matchesQuery)
        let actual = FileResultPresentation.summary(
            textContent: String(repeating: "文", count: 120) + "品牌方案" + String(repeating: "字", count: 800),
            query: "品牌方案", metadata: "PDF"
        )
        XCTAssertTrue(actual.text.contains("品牌方案"))
        XCTAssertTrue(actual.isContent)
        XCTAssertTrue(actual.matchesQuery)
        XCTAssertLessThanOrEqual(actual.text.count, 182)
    }

    func testBothThemesUseMultilineResultsAndRetainOptionalTableMode() {
        XCTAssertEqual(FileListPresentation.defaultValue, .results)
        XCTAssertEqual(FileListPresentation.allCases, [.results, .table])
        XCTAssertEqual(FileResultPresentation.rowHeight(for: .precision), 112)
        XCTAssertEqual(FileResultPresentation.rowHeight(for: .reading), 112)
    }

    func testMatchBadgeRequiresActualBodyOrFilenameEvidence() {
        let body = FileResultPresentation.summary(textContent: "真实品牌方案正文", query: "品牌方案", metadata: "PDF")
        XCTAssertEqual(FileResultPresentation.matchLabel(summary: body, filename: "笔记.md", query: "品牌方案"),
                       AppLanguage.localized("正文匹配", english: "Content Match"))
        let unrelated = FileResultPresentation.summary(textContent: "没有该关键词", query: "品牌方案", metadata: "PDF")
        XCTAssertEqual(FileResultPresentation.matchLabel(summary: unrelated, filename: "品牌方案.pdf", query: "品牌方案"),
                       AppLanguage.localized("文件名匹配", english: "Name Match"))
        XCTAssertNil(FileResultPresentation.matchLabel(summary: unrelated, filename: "笔记.md", query: "品牌方案"))
        XCTAssertNil(FileResultPresentation.matchLabel(summary: body, filename: "笔记.md", query: "  "))
    }

    func testResultBreadcrumbContainsOnlyRealLastThreeParentComponents() {
        let url = URL(fileURLWithPath: "/Users/example/Documents/品牌项目/方案/brief.pdf")
        XCTAssertEqual(FileResultPresentation.parentBreadcrumb(for: url), "Documents › 品牌项目 › 方案")
        XCTAssertEqual(FileResultPresentation.parentBreadcrumb(for: URL(fileURLWithPath: "/tmp/file.txt")), "tmp")
    }

    func testResultCellReservesPathBelowLongExcerptAndRightAlignsBadge() throws {
        let file = IndexedFile(
            id: "result-layout", sourceID: UUID(), name: "方案.md",
            path: "/tmp/设计/品牌项目/方案.md", fileExtension: "md", kind: .document,
            size: 2048, createdAt: nil, modifiedAt: nil, indexedAt: Date(),
            textContent: String(repeating: "品牌方案需要保留真实摘要和路径。", count: 40)
        )
        for theme in AppVisualTheme.allCases {
            let cell = LargeFileNameCellView(identifier: .init("layout-result"))
            cell.frame = NSRect(x: 0, y: 0, width: 480, height: FileResultPresentation.rowHeight(for: theme))
            let host = NSView(frame: cell.frame)
            host.addSubview(cell)
            cell.configureResult(file: file, query: "品牌方案", theme: theme, scheme: .light, date: "2026/9/5") { nil }
            host.layoutSubtreeIfNeeded()
            cell.layoutSubtreeIfNeeded()
            let fields = cell.subviews.compactMap { $0 as? NSTextField }
            let path = try XCTUnwrap(fields.first { $0.toolTip == file.url.deletingLastPathComponent().path })
            let excerpt = try XCTUnwrap(fields.first { $0.stringValue.hasPrefix("品牌方案需要") })
            let badge = try XCTUnwrap(fields.first { $0.stringValue == AppLanguage.localized("正文匹配", english: "Content Match") })
            XCTAssertEqual(path.frame.height, 14, accuracy: 0.5)
            XCTAssertEqual(excerpt.frame.height, 34, accuracy: 0.5)
            XCTAssertFalse(path.frame.intersects(excerpt.frame))
            // NSTextField alignment rect excludes its 2pt optical inset.
            let alignedBadge = badge.alignmentRect(forFrame: badge.frame)
            XCTAssertEqual(alignedBadge.maxX, cell.bounds.maxX - 16, accuracy: 0.5)
            XCTAssertEqual(badge.alignment, .right)
            cell.cancelThumbnailRequest()
        }
    }

    func testNativeSelectionSurvivesEmptySnapshotThenAsynchronousFileArrival() {
        let file = IndexedFile(
            id: "arrival", sourceID: UUID(), name: "arrival.md", path: "/tmp/arrival.md",
            fileExtension: "md", kind: .document, size: 1,
            createdAt: nil, modifiedAt: nil, indexedAt: .distantPast
        )
        var selectedIDs: Set<String> = [file.id]
        let selection = Binding<Set<String>>(get: { selectedIDs }, set: { selectedIDs = $0 })
        func wrapper(_ files: [IndexedFile], version: Int) -> LargeFileTableView {
            LargeFileTableView(
                files: files, idIndex: files.isEmpty ? [:] : [file.id: 0], contentVersion: version,
                presentation: .results, selection: selection, categoryText: { _ in "" },
                onSelectionLeadChange: { _ in }, onDoubleClick: { _ in }, onQuickLook: { _ in }, onDelete: {}
            )
        }
        let table = LargeFileNSTableView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))
        table.addTableColumn(NSTableColumn(identifier: LargeFileTableColumn.name.identifier))
        table.allowsEmptySelection = true
        let coordinator = wrapper([], version: 0).makeCoordinator()
        table.delegate = coordinator
        table.dataSource = coordinator
        let scroll = NSScrollView(frame: table.frame)
        scroll.documentView = table
        coordinator.replaceSnapshot(with: wrapper([], version: 0), in: table, force: true)
        XCTAssertEqual(table.selectedRowIndexes, [])
        XCTAssertEqual(selectedIDs, [file.id])
        coordinator.replaceSnapshot(with: wrapper([file], version: 1), in: table, force: false)
        XCTAssertEqual(table.selectedRowIndexes, [0])
        XCTAssertEqual(selectedIDs, [file.id])
        // A later same-value SwiftUI render must retain the resolved row.
        coordinator.replaceSnapshot(with: wrapper([file], version: 1), in: table, force: false)
        XCTAssertEqual(table.selectedRowIndexes, [0])
    }

    func testNativeResultRowsUseMultilineHeightWithoutReloading() {
        let table = ThemeTrackingTableView()
        let column = NSTableColumn(identifier: .init("name"))
        table.addTableColumn(column)
        table.selectionHighlightStyle = .regular
        let scroll = NSScrollView()
        scroll.documentView = table
        let reloads = table.reloadCount
        NativeFileBrowserThemeAppearance.apply(.precision, scheme: .light, to: table, in: scroll, presentation: .results)
        XCTAssertEqual(table.rowHeight, 112)
        NativeFileBrowserThemeAppearance.apply(.reading, scheme: .dark, to: table, in: scroll, presentation: .results)
        XCTAssertEqual(table.rowHeight, 112)
        XCTAssertEqual(table.reloadCount, reloads)
        XCTAssertEqual(table.selectionHighlightStyle, .regular)
    }

    func testPathContextMenuTargetsClickedParentInsteadOfTerminalFile() {
        let control = FileLocationPathControl()
        control.url = URL(fileURLWithPath: "/tmp/example-folder/document.md")
        let clickedParent = URL(fileURLWithPath: "/tmp/example-folder", isDirectory: true)
        let menu = control.contextMenu(for: clickedParent)
        XCTAssertEqual(menu.items.count, 3)
        for item in menu.items {
            XCTAssertEqual(item.representedObject as? URL, clickedParent)
            XCTAssertTrue(item.target === control)
            XCTAssertNotNil(item.action)
        }
        XCTAssertNotEqual(clickedParent, control.url)
    }

    func testTableThemeChangesDensityWithoutReloadingOrResettingColumns() {
        let table = ThemeTrackingTableView()
        let column = NSTableColumn(identifier: .init("name"))
        column.width = 287
        table.addTableColumn(column)
        table.selectionHighlightStyle = .regular
        let scroll = NSScrollView()
        scroll.documentView = table
        let originalReloadCount = table.reloadCount

        NativeFileBrowserThemeAppearance.apply(.reading, scheme: .light, to: table, in: scroll)
        XCTAssertEqual(table.rowHeight, 38)
        XCTAssertEqual(table.backgroundColor, NSColor(AppVisualTheme.reading.palette(for: .light).canvas))
        XCTAssertFalse(table.usesAlternatingRowBackgroundColors)
        NativeFileBrowserThemeAppearance.apply(.precision, scheme: .dark, to: table, in: scroll)
        XCTAssertEqual(table.rowHeight, 38)
        XCTAssertEqual(table.backgroundColor, NSColor(AppVisualTheme.precision.palette(for: .dark).canvas))
        XCTAssertEqual(table.reloadCount, originalReloadCount)
        XCTAssertEqual(column.width, 287)
        XCTAssertEqual(table.selectionHighlightStyle, .regular)
    }

    func testUnchangedTableAppearanceDoesNotRequestAnotherDisplay() {
        let table = ThemeTrackingTableView()
        let scroll = NSScrollView()
        scroll.documentView = table
        NativeFileBrowserThemeAppearance.apply(.precision, scheme: .light, to: table, in: scroll)
        let previousRequests = table.displayRequests
        for _ in 0..<100 {
            NativeFileBrowserThemeAppearance.apply(.precision, scheme: .light, to: table, in: scroll)
        }
        XCTAssertEqual(table.displayRequests, previousRequests, "Selection and unrelated view updates must not invalidate the entire table")
        NativeFileBrowserThemeAppearance.apply(.reading, scheme: .dark, to: table, in: scroll)
        XCTAssertGreaterThan(table.displayRequests, previousRequests, "A real appearance change still needs rendering")
    }

    func testCollectionThemeDoesNotReloadOrReplaceLayoutAndSelection() {
        let collection = ThemeTrackingCollectionView()
        let layout = NSCollectionViewFlowLayout()
        collection.collectionViewLayout = layout
        collection.isSelectable = true
        let scroll = NSScrollView()
        scroll.documentView = collection
        let originalReloadCount = collection.reloadCount
        let originalSelection = collection.selectionIndexPaths

        for theme in AppVisualTheme.allCases {
            for scheme in [ColorScheme.light, .dark] {
                NativeFileBrowserThemeAppearance.apply(theme, scheme: scheme, to: collection, in: scroll)
                XCTAssertEqual(collection.backgroundColors, [NSColor(theme.palette(for: scheme).canvas)])
                XCTAssertEqual(scroll.backgroundColor, NSColor(theme.palette(for: scheme).canvas))
            }
        }
        XCTAssertEqual(collection.reloadCount, originalReloadCount)
        XCTAssertTrue(collection.collectionViewLayout === layout)
        XCTAssertEqual(collection.selectionIndexPaths, originalSelection)
    }

    func testChangingDensityRetainsTopFileAndNonemptySelectionInLargeTable() {
        let table = ThemeTrackingTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        table.addTableColumn(NSTableColumn(identifier: .init("name")))
        table.rowHeight = 34
        let rows = ThemeTestLargeTableDataSource()
        table.dataSource = rows
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scroll.documentView = table
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 45_000), byExtendingSelection: false)
        table.scrollRowToVisible(45_000)
        let originalTopRow = table.row(at: scroll.contentView.bounds.origin)
        XCTAssertGreaterThan(originalTopRow, 0)
        let originalReloadCount = table.reloadCount

        NativeFileBrowserThemeAppearance.apply(.reading, scheme: .light, to: table, in: scroll)
        XCTAssertEqual(table.row(at: scroll.contentView.bounds.origin), originalTopRow)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 45_000))
        NativeFileBrowserThemeAppearance.apply(.precision, scheme: .dark, to: table, in: scroll)
        XCTAssertEqual(table.row(at: scroll.contentView.bounds.origin), originalTopRow)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 45_000))
        XCTAssertEqual(table.reloadCount, originalReloadCount)
    }
}

@MainActor
private final class ThemeTestLargeTableDataSource: NSObject, NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { 100_000 }
}

@MainActor
private final class ThemeTrackingTableView: NSTableView {
    var displayRequests = 0
    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            if newValue { displayRequests += 1 }
            super.needsDisplay = newValue
        }
    }
    var reloadCount = 0
    override func reloadData() {
        reloadCount += 1
        super.reloadData()
    }
}

@MainActor
private final class ThemeTrackingCollectionView: NSCollectionView {
    var reloadCount = 0
    override func reloadData() {
        reloadCount += 1
        super.reloadData()
    }
}
