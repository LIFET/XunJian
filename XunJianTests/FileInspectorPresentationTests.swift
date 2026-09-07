import SwiftUI
import XCTest
import Darwin
import PDFKit
@testable import XunJian

final class FileInspectorPresentationTests: XCTestCase {
    @MainActor
    func testNativeTextPreviewSwitchesLongAndShortDocumentsWithoutStaleHighlightRanges() async throws {
        func preview(_ text: String, query: String) -> some View {
            InspectorTextDocumentPreview(text: text, kind: .document, query: query, hasMore: false, openFullPreview: {})
                .frame(width: 400, height: 300)
        }
        let host = NSHostingView(rootView: preview(String(repeating: "hello ", count: 300), query: "hello"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        func textView(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.lazy.compactMap { textView(in: $0) }.first
        }
        for (text, query) in [("short", "hello"), ("hello again", "hello"), ("", "hello"), ("hello again", "")] {
            host.rootView = preview(text, query: query)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
            let rendered = try XCTUnwrap(textView(in: host)?.textStorage)
            XCTAssertEqual(rendered.string, text)
            if !text.isEmpty {
                let highlighted = rendered.attribute(.backgroundColor, at: 0, effectiveRange: nil) != nil
                XCTAssertEqual(highlighted, text.hasPrefix("hello") && !query.isEmpty)
            }
        }
    }
    @MainActor
    func testTextRenderReusesContentAcrossNavigationButInvalidatesTextAndStyle() throws {
        var cache = InspectorTextRenderCache()
        func input(_ text: String = "hello hello", fontSize: CGFloat = 15, color: NSColor = .yellow) -> InspectorTextContent {
            InspectorTextContent(text: text, matches: DocumentPreviewPolicy.matchRanges(in: text, query: "hello"),
                                 font: .systemFont(ofSize: fontSize), lineSpacing: 7,
                                 selectionColor: color, accentColor: .labelColor)
        }
        let first = cache.attributedText(for: input())
        for _ in 0..<100 {
            XCTAssertTrue(first === cache.attributedText(for: input()), "匹配位置/父视图刷新不能重建同一富文本")
        }
        let changed = cache.attributedText(for: input("hello world"))
        XCTAssertFalse(first === changed)
        XCTAssertEqual(changed.string, "hello world")
        let styled = cache.attributedText(for: input("hello world", fontSize: 18, color: .green))
        XCTAssertFalse(changed === styled)
        XCTAssertEqual((styled.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 18)
        XCTAssertEqual(styled.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor, .green)
        XCTAssertNil(styled.attribute(.backgroundColor, at: 7, effectiveRange: nil))
        XCTAssertEqual(cache.attributedText(for: input("")).length, 0)
    }
    @MainActor
    func testPDFPageStatusTracksNavigationAndIgnoresPreviousDocumentView() async throws {
        let document = PDFDocument()
        for index in 0..<3 {
            let page = try XCTUnwrap(PDFPage(image: NSImage(size: NSSize(width: 80, height: 100), flipped: false) { _ in
                NSColor.white.setFill()
                NSRect(x: 0, y: 0, width: 80, height: 100).fill()
                return true
            }))
            document.insert(page, at: index)
        }
        let firstView = PDFView()
        firstView.document = document
        let progress = PDFReadingProgress()
        progress.observe(firstView)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(progress.totalPages, 3)
        XCTAssertEqual(progress.currentPage, 1)
        firstView.go(to: try XCTUnwrap(document.page(at: 2)))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(progress.currentPage, 3)

        let replacementView = PDFView()
        replacementView.document = document
        progress.observe(replacementView)
        firstView.go(to: try XCTUnwrap(document.page(at: 1)))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(progress.currentPage, 1, "旧阅读区通知不得覆盖新阅读区页码")
        replacementView.document = nil
        progress.observe(replacementView)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(progress.currentPage, 0)
        XCTAssertEqual(progress.totalPages, 0)
    }

    func testReadingPositionIdentityChangesWithSourcePermission() {
        func identity(enabled: Bool = true, bookmark: Data = Data([1]), access: String = "authorized") -> String {
            DocumentPreviewPolicy.readingIdentity(fileIdentity: 42, size: 100, modifiedAt: 123,
                accessState: access, sourceIdentity: DocumentPreviewPolicy.sourceIdentity(enabled: enabled, bookmark: bookmark))
        }
        XCTAssertEqual(identity(), identity())
        XCTAssertNotEqual(identity(), identity(enabled: false))
        XCTAssertNotEqual(identity(), identity(bookmark: Data([2])))
        XCTAssertNotEqual(identity(), identity(access: "missing"))
    }

    @MainActor
    func testPDFReadingPositionSurvivesNativeViewRecreationAndIsolatesFiles() async throws {
        let key = "pdf-reading-\(UUID().uuidString)"
        let document = PDFDocument()
        let page = try XCTUnwrap(PDFPage(image: NSImage(size: NSSize(width: 680, height: 900), flipped: false) { _ in
            NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 680, height: 900).fill(); return true
        }))
        document.insert(page, at: 0)
        func makeView(key: String) -> (NSWindow, InspectorPDFView) {
            let view = InspectorPDFView()
            view.displayMode = .singlePageContinuous
            view.autoScales = true
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 707, height: 500), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            view.installPreviewDocument(document, readingPositionKey: key)
            return (window, view)
        }
        var first: (NSWindow, InspectorPDFView)? = makeView(key: key)
        try await Task.sleep(for: .milliseconds(100))
        first!.1.noteUserInteraction()
        first!.1.go(to: PDFDestination(page: page, at: NSPoint(x: 0, y: 640)))
        let expected = try XCTUnwrap(first!.1.currentDestination?.point.y)
        first!.1.saveReadingPosition()
        first!.0.close()
        first = nil
        // Reopening and closing synchronously, before the queued restoration,
        // must not replace the saved position with PDFKit's temporary default.
        var interrupted: (NSWindow, InspectorPDFView)? = makeView(key: key)
        interrupted!.1.go(to: PDFDestination(page: page, at: NSPoint(x: 0, y: 900)))
        interrupted!.1.saveReadingPosition()
        interrupted!.0.close()
        interrupted = nil
        let (window, restored) = makeView(key: key)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(try XCTUnwrap(restored.currentDestination?.point.y), expected, accuracy: 2)
        let (otherWindow, other) = makeView(key: key + "-different-file-version")
        defer { otherWindow.close() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThan(try XCTUnwrap(other.currentDestination?.point.y), 880)
    }

    @MainActor
    func testTextReadingPositionSurvivesNativeViewRecreation() async throws {
        let key = "text-reading-\(UUID().uuidString)"
        func makeView() -> (NSWindow, InspectorTextScrollView) {
            let scroll = InspectorTextScrollView()
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 280, height: 2_000))
            text.string = String(repeating: "Preview text line\n", count: 120)
            scroll.documentView = text
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            scroll.prepareReadingPosition(for: key)
            scroll.restoreReadingPositionIfNeeded()
            return (window, scroll)
        }
        var first: (NSWindow, InspectorTextScrollView)? = makeView()
        first!.1.contentView.scroll(to: NSPoint(x: 0, y: 500))
        first!.1.saveReadingPosition()
        first!.0.close()
        first = nil
        let (window, restored) = makeView()
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(restored.contentView.bounds.origin.y, 500, accuracy: 1)
    }

    func testInspectorBatchActionsRequireAllSelectedFilesToBeResolved() {
        XCTAssertTrue(InspectorSelectionActionState(selectedCount: 2, resolvedCount: 2).canApplyBatchActions)
        XCTAssertFalse(InspectorSelectionActionState(selectedCount: 2, resolvedCount: 1).canApplyBatchActions)
        XCTAssertFalse(InspectorSelectionActionState(selectedCount: 0, resolvedCount: 0).canApplyBatchActions)
        XCTAssertFalse(InspectorSelectionActionState(selectedCount: 1, resolvedCount: 1).canApplyBatchActions)
        XCTAssertFalse(InspectorSelectionActionState(selectedCount: 2, resolvedCount: 3).canApplyBatchActions)
    }

    @MainActor
    func testNarrowNativePathKeepsFilenameAndAllAncestorTargets() throws {
        let control = FileLocationPathControl()
        let url = URL(fileURLWithPath: "/tmp/project-materials/brand-guidelines/review-final/Long final document name.pdf")
        control.url = url
        control.isEditable = false
        let originalURLs = control.pathItems.compactMap(\.url)
        control.setFrameSize(NSSize(width: 160, height: 34))
        control.updatePathPresentation()
        XCTAssertEqual(control.pathStyle, .popUp)
        XCTAssertEqual(control.pathItems.last?.url, url)
        XCTAssertEqual(control.pathItems.last?.title, url.lastPathComponent)
        XCTAssertEqual(control.pathItems.compactMap(\.url), originalURLs)
        XCTAssertFalse(control.isEditable)
        let rightClick = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown,
            location: NSPoint(x: 80, y: 17), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(control.menu(for: rightClick))
        XCTAssertEqual(menu.items.count, 3)
        XCTAssertTrue(menu.items.allSatisfy { ($0.representedObject as? URL) == url })

        let parent = try XCTUnwrap(originalURLs.dropLast().last)
        XCTAssertTrue(control.contextMenu(for: parent).items.allSatisfy { ($0.representedObject as? URL) == parent })
        control.setFrameSize(NSSize(width: 2_000, height: 34))
        control.updatePathPresentation()
        XCTAssertEqual(control.pathStyle, .standard)
        XCTAssertEqual(control.pathItems.compactMap(\.url), originalURLs)
    }

    @MainActor
    func testInitialPDFLayoutRecoversFirstPageTopWithoutResettingUserNavigation() async throws {
        let document = PDFDocument()
        let page = try XCTUnwrap(PDFPage(image: NSImage(size: NSSize(width: 680, height: 900), flipped: false) { _ in
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 680, height: 900).fill()
            return true
        }))
        document.insert(page, at: 0)
        let view = InspectorPDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 707, height: 757), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        view.installPreviewDocument(document)
        // Reproduce the destination observed in the real expanding inspector:
        // PDFKit has retained y~732 before the final width settles.
        view.setFrameSize(NSSize(width: 708, height: 757))
        view.setFrameSize(NSSize(width: 707, height: 757))
        view.go(to: PDFDestination(page: page, at: NSPoint(x: 0, y: 732)))
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThan(try XCTUnwrap(view.currentDestination?.point.y), 880)

        // PDFKit may deliver its internal clip-view layout after the outer
        // inspector size has settled. The same-size late update must also start
        // at the top until the user has actually interacted with the document.
        view.go(to: PDFDestination(page: page, at: NSPoint(x: 0, y: 732)))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThan(try XCTUnwrap(view.currentDestination?.point.y), 880)

        view.noteUserInteraction()
        view.go(to: PDFDestination(page: page, at: NSPoint(x: 0, y: 732)))
        let userPosition = try XCTUnwrap(view.currentDestination?.point.y)
        view.installPreviewDocument(document)
        view.backgroundColor = .darkGray
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(try XCTUnwrap(view.currentDestination?.point.y), userPosition, accuracy: 1)
    }

    func testPreviewRequestIdentityIncludesMovedPathAndChangedFormat() {
        let original = DocumentPreviewPolicy.fileIdentity(id: "same", path: "/a/report.pdf", kind: .document, fileExtension: "pdf")
        XCTAssertNotEqual(original, DocumentPreviewPolicy.fileIdentity(id: "same", path: "/b/report.pdf", kind: .document, fileExtension: "pdf"))
        XCTAssertNotEqual(original, DocumentPreviewPolicy.fileIdentity(id: "same", path: "/a/report.pdf", kind: .image, fileExtension: "png"))
    }

    func testStalePreviewCompletionCannotClearNewLoadingState() {
        var state = InspectorPreviewLoadState()
        let old = state.begin()
        let latest = state.begin()
        XCTAssertFalse(state.finish(old))
        XCTAssertTrue(state.isLoading)
        XCTAssertFalse(state.isCurrent(old))
        XCTAssertTrue(state.finish(latest))
        XCTAssertFalse(state.isLoading)
    }

    func testOriginalReadRejectsLeafSymlinkSwappedAfterValidation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("InspectorRead-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("report.pdf")
        let replacement = root.appendingPathComponent("replacement.pdf")
        try Data("first".utf8).write(to: target)
        try Data("replacement".utf8).write(to: replacement)
        XCTAssertThrowsError(try OriginalDocumentDataLoader.readValidatedFile(at: target, authorizedRoot: root, beforeOpen: {
            try FileManager.default.removeItem(at: target)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: replacement)
        }))
    }

    func testOriginalReadAllowsRegularFileAndRejectsSwappedFIFOWithoutBlocking() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("InspectorFIFORead-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("report.pdf")
        let content = Data("first".utf8)
        try content.write(to: target)
        XCTAssertEqual(try OriginalDocumentDataLoader.readValidatedFile(at: target, authorizedRoot: root), content)
        XCTAssertThrowsError(try OriginalDocumentDataLoader.readValidatedFile(at: target, authorizedRoot: root, beforeOpen: {
            try FileManager.default.removeItem(at: target)
            guard mkfifo(target.path, 0o600) == 0 else { throw CocoaError(.fileWriteUnknown) }
        }))
    }

    func testOriginalReadRejectsParentSymlinkSwappedOutsideAuthorizedRoot() throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("InspectorParentRead-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("authorized", isDirectory: true)
        let parent = root.appendingPathComponent("nested", isDirectory: true)
        let outside = fixture.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let target = parent.appendingPathComponent("report.pdf")
        try Data("first".utf8).write(to: target)
        try Data("outside".utf8).write(to: outside.appendingPathComponent("report.pdf"))
        XCTAssertThrowsError(try OriginalDocumentDataLoader.readValidatedFile(at: target, authorizedRoot: root, beforeOpen: {
            try FileManager.default.moveItem(at: parent, to: root.appendingPathComponent("saved"))
            try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)
        }))
    }

    func testOriginalDocumentPreviewRoutingDoesNotPretendOfficeTextIsOriginal() {
        XCTAssertEqual(DocumentPreviewPolicy.route(kind: .document, fileExtension: "PDF"), .pdf)
        XCTAssertEqual(DocumentPreviewPolicy.route(kind: .image, fileExtension: "png"), .image)
        XCTAssertEqual(DocumentPreviewPolicy.route(kind: .document, fileExtension: "docx"), .text)
        XCTAssertEqual(DocumentPreviewPolicy.route(kind: .code, fileExtension: "swift"), .text)
        XCTAssertEqual(DocumentPreviewPolicy.route(kind: .video, fileExtension: "mov"), .external)
    }

    func testPreviewMatchesUseOriginalUTF16OffsetsAndIgnoreEmptyQuery() {
        let text = "👩🏽‍💻İstanbul 品牌方案 BRAND brand"
        let ranges = DocumentPreviewPolicy.matchRanges(in: text, query: "brand")
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges.map { (text as NSString).substring(with: $0) }, ["BRAND", "brand"])
        XCTAssertTrue(DocumentPreviewPolicy.matchRanges(in: text, query: "  ").isEmpty)
    }

    func testMatchNavigationWrapsAndEmptyResultsHaveNoSelection() {
        XCTAssertEqual(DocumentPreviewPolicy.nextMatch(current: 0, delta: -1, count: 3), 2)
        XCTAssertEqual(DocumentPreviewPolicy.nextMatch(current: 2, delta: 1, count: 3), 0)
        XCTAssertEqual(DocumentPreviewPolicy.nextMatch(current: 0, delta: 1, count: 0), 0)
    }

    func testOriginalPreviewRejectsSiblingWithSamePathPrefix() {
        XCTAssertTrue(DocumentPreviewPolicy.isWithinAuthorizedRoot(filePath: "/Users/test/Documents/report.pdf", rootPath: "/Users/test/Documents"))
        XCTAssertFalse(DocumentPreviewPolicy.isWithinAuthorizedRoot(filePath: "/Users/test/Documents-private/report.pdf", rootPath: "/Users/test/Documents"))
        XCTAssertFalse(DocumentPreviewPolicy.isWithinAuthorizedRoot(filePath: "/Users/test/Documents/../private/report.pdf", rootPath: "/Users/test/Documents"))
    }

    func testOriginalPreviewRequestChangesWhenSourceIsDisabledOrReauthorized() {
        let original = DocumentPreviewPolicy.sourceIdentity(enabled: true, bookmark: Data([1, 2]))
        XCTAssertEqual(original, DocumentPreviewPolicy.sourceIdentity(enabled: true, bookmark: Data([1, 2])))
        XCTAssertNotEqual(original, DocumentPreviewPolicy.sourceIdentity(enabled: false, bookmark: Data([1, 2])))
        XCTAssertNotEqual(original, DocumentPreviewPolicy.sourceIdentity(enabled: true, bookmark: Data([3, 4])))
    }

    func testCodePreviewPreservesMonospacedTypography() {
        XCTAssertEqual(FileInspectorView.previewFontDesign(for: .code), .monospaced)
        XCTAssertEqual(FileInspectorView.previewFontDesign(for: .document), .default)
    }

    func testPDFExtractedTextIsExplicitlyDistinguishedFromOriginalLayout() {
        XCTAssertTrue(FileInspectorView.isExtractedPDFPreview(fileExtension: "pdf"))
        XCTAssertTrue(FileInspectorView.isExtractedPDFPreview(fileExtension: "PDF"))
        XCTAssertFalse(FileInspectorView.isExtractedPDFPreview(fileExtension: "md"))
        XCTAssertFalse(FileInspectorView.isExtractedPDFPreview(fileExtension: "txt"))
    }
}
