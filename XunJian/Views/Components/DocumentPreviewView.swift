import SwiftUI
import PDFKit
import ImageIO
import Darwin

enum DocumentPreviewPolicy {
    enum Route: Equatable { case pdf, image, text, external }

    nonisolated static func route(kind: FileKind, fileExtension: String) -> Route {
        if kind == .document, fileExtension.caseInsensitiveCompare("pdf") == .orderedSame { return .pdf }
        if kind == .image { return .image }
        return kind.supportsTextExtraction ? .text : .external
    }

    nonisolated static func matchRanges(in text: String, query: String) -> [NSRange] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var result: [NSRange] = []
        var start = text.startIndex
        while start < text.endIndex,
              let range = text.range(of: query, options: .caseInsensitive, range: start..<text.endIndex) {
            guard range.lowerBound != range.upperBound else { break }
            result.append(NSRange(range, in: text))
            start = range.upperBound
        }
        return result
    }

    nonisolated static func nextMatch(current: Int, delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((current + delta) % count + count) % count
    }

    nonisolated static func isWithinAuthorizedRoot(filePath: String, rootPath: String) -> Bool {
        let file = URL(fileURLWithPath: filePath).standardizedFileURL.path
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        return file == root || file.hasPrefix(root == "/" ? "/" : root + "/")
    }

    nonisolated static func sourceIdentity(enabled: Bool, bookmark: Data) -> Int {
        var hasher = Hasher()
        hasher.combine(enabled)
        hasher.combine(bookmark)
        return hasher.finalize()
    }

    nonisolated static func readingIdentity(fileIdentity: Int, size: Int64, modifiedAt: TimeInterval?, accessState: String, sourceIdentity: Int) -> String {
        "\(fileIdentity)|\(size)|\(modifiedAt ?? 0)|\(accessState)|\(sourceIdentity)"
    }

    nonisolated static func fileIdentity(id: String, path: String, kind: FileKind, fileExtension: String) -> Int {
        var hasher = Hasher()
        hasher.combine(id)
        hasher.combine(path)
        hasher.combine(kind)
        hasher.combine(fileExtension.lowercased())
        return hasher.finalize()
    }
}

struct InspectorPreviewLoadState {
    private(set) var generation = UUID()
    private(set) var isLoading = false
    mutating func begin() -> UUID {
        generation = UUID()
        isLoading = true
        return generation
    }
    func isCurrent(_ request: UUID) -> Bool { request == generation }
    mutating func invalidate() {
        generation = UUID()
        isLoading = false
    }
    @discardableResult mutating func finish(_ request: UUID) -> Bool {
        guard isCurrent(request) else { return false }
        isLoading = false
        return true
    }
}

/// A bounded, read-only native renderer. It never downloads cloud files or
/// resolves a path outside the selected file's existing security-scoped source.
@MainActor @Observable
final class PDFReadingProgress {
    private(set) var currentPage = 0
    private(set) var totalPages = 0
    @ObservationIgnored private weak var observedView: PDFView?
    @ObservationIgnored private var pageObservation: PDFLayoutObservation?

    func observe(_ view: PDFView) {
        if observedView !== view {
            observedView = view
            pageObservation = PDFLayoutObservation(name: .PDFViewPageChanged, object: view) { [weak self, weak view] in
                guard let view else { return }
                self?.scheduleRefresh(view)
            }
        }
        scheduleRefresh(view)
    }

    private func scheduleRefresh(_ view: PDFView) {
        // PDFKit can notify during a SwiftUI representable update. Publish only
        // after that pass, and ignore queued work belonging to the previous view.
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self, let view, self.observedView === view else { return }
            let total = view.document?.pageCount ?? 0
            let index = view.currentPage.flatMap { view.document?.index(for: $0) }
            let current = index.flatMap { $0 >= 0 && $0 < total ? $0 + 1 : nil } ?? 0
            if self.totalPages != total { self.totalPages = total }
            if self.currentPage != current { self.currentPage = current }
        }
    }
}

struct DocumentPreviewView: View {
    let file: IndexedFile
    let source: FileSource?
    let openPreview: () -> Void
    @Environment(\.appVisualTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @State private var pdf: PDFDocument?
    @State private var pdfProgress = PDFReadingProgress()
    @State private var image: NSImage?
    @State private var loading = true
    @State private var retry = 0
    @State private var loadedRequestID: String?
    @State private var loadGeneration = UUID()

    private var requestID: String {
        let sourceIdentity = source.map { DocumentPreviewPolicy.sourceIdentity(enabled: $0.enabled, bookmark: $0.bookmark) } ?? 0
        let fileIdentity = DocumentPreviewPolicy.fileIdentity(id: file.id, path: file.path, kind: file.kind, fileExtension: file.fileExtension)
        return DocumentPreviewPolicy.readingIdentity(fileIdentity: fileIdentity, size: file.size,
            modifiedAt: file.modifiedAt?.timeIntervalSince1970,
            accessState: source?.accessState.rawValue ?? "missing", sourceIdentity: sourceIdentity) + "|\(retry)"
    }

    var body: some View {
        Group {
            if loadedRequestID == requestID, let pdf {
                VStack(spacing: 0) {
                    NativePDFDocumentView(document: pdf, background: NSColor(theme.palette(for: colorScheme).canvas), readingPositionKey: requestID, progress: pdfProgress)
                    Divider()
                    HStack {
                        Spacer(minLength: 0)
                        if pdfProgress.currentPage > 0 {
                            Text(verbatim: AppLanguage.localized(
                                "第 \(pdfProgress.currentPage) 页 / 共 \(pdfProgress.totalPages) 页",
                                english: "Page \(pdfProgress.currentPage) of \(pdfProgress.totalPages)"
                            ))
                            .font(.system(size: 11)).monospacedDigit()
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("inspector.pdf.pageStatus")
                        }
                    }
                    .padding(.horizontal, 16).frame(height: 30)
                    .background(theme.palette(for: colorScheme).canvas)
                }
            } else if loadedRequestID == requestID, let image {
                NativeImageDocumentView(image: image)
                    .padding(theme.contentPadding)
            } else if loading || loadedRequestID != requestID {
                ProgressView(AppLanguage.localized("正在载入原文件", english: "Loading original file"))
                    .controlSize(.small)
            } else {
                ContentUnavailableView {
                    Label(AppLanguage.localized("原文件暂无法内嵌预览", english: "Inline Preview Unavailable"), systemImage: "doc")
                } description: {
                    Text(AppLanguage.localized(
                        "请确认文件已下载且文件夹已授权。大于 32 MB、加密或不支持的文件请使用系统预览。",
                        english: "Ensure the file is downloaded and its folder is authorized. For files over 32 MB, encrypted files, or unsupported formats, use system Preview."
                    ))
                } actions: {
                    Button(AppLanguage.localized("系统预览", english: "System Preview"), action: openPreview)
                    Button(AppLanguage.localized("重试", english: "Retry")) { retry += 1 }
                }
                .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: requestID) {
            let generation = UUID()
            loadGeneration = generation
            pdf = nil
            image = nil
            loading = true
            defer {
                if loadGeneration == generation {
                    loading = false
                    loadedRequestID = requestID
                }
            }
            guard let source, source.enabled, source.accessState == .available else { return }
            let read = Task.detached(priority: .userInitiated) {
                let data = try OriginalDocumentDataLoader.read(file: file, source: source)
                try Task.checkCancellation()
                return PreparedOriginalDocument(data: data, route: DocumentPreviewPolicy.route(kind: file.kind, fileExtension: file.fileExtension))
            }
            let prepared = await withTaskCancellationHandler {
                try? await read.value
            } onCancel: {
                read.cancel()
            }
            guard !Task.isCancelled, loadGeneration == generation, let prepared else { return }
            pdf = prepared.pdf
            if let cgImage = prepared.image { image = NSImage(cgImage: cgImage, size: .zero) }
        }
    }
}

/// Single-owner transfer: parsing happens on one worker; after it returns,
/// only the main-actor PDFView can access the document. Never shared for mutation.
private final class PreparedOriginalDocument: @unchecked Sendable {
    let pdf: PDFDocument?
    let image: CGImage?
    nonisolated init(data: Data, route: DocumentPreviewPolicy.Route) {
        if route == .pdf {
            let document = PDFDocument(data: data)
            pdf = document?.isLocked == false ? document : nil
            image = nil
        } else if route == .image {
            pdf = nil
            if let source = CGImageSourceCreateWithData(data as CFData, nil) {
                image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2400,
                    kCGImageSourceShouldCacheImmediately: true
                ] as CFDictionary)
            } else { image = nil }
        } else {
            pdf = nil
            image = nil
        }
    }
}

enum OriginalDocumentDataLoader {
    nonisolated static let maximumBytes = 32 * 1_024 * 1_024

    nonisolated static func read(file: IndexedFile, source: FileSource) throws -> Data {
        guard file.sourceID == source.id, source.enabled, source.accessState == .available else {
            throw CocoaError(.fileReadNoPermission)
        }
        let restored = try BookmarkManager().resolveBookmark(source.bookmark)
        guard restored.url.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }
        defer { restored.url.stopAccessingSecurityScopedResource() }
        let url = file.url.resolvingSymlinksInPath()
        let root = restored.url.resolvingSymlinksInPath()
        guard !ScanExclusions.isSensitivePath(file.url) else { throw CocoaError(.fileReadNoPermission) }
        return try readValidatedFile(at: url, authorizedRoot: root)
    }

    nonisolated static func readValidatedFile(at url: URL, authorizedRoot root: URL, beforeOpen: (() throws -> Void)? = nil) throws -> Data {
        let url = url.resolvingSymlinksInPath()
        let root = root.resolvingSymlinksInPath()
        guard DocumentPreviewPolicy.isWithinAuthorizedRoot(filePath: url.path, rootPath: root.path),
              !ScanExclusions.isSensitivePath(url) else {
            throw CocoaError(.fileReadNoPermission)
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .fileSizeKey])
        guard values.isRegularFile == true,
              values.isUbiquitousItem != true || values.ubiquitousItemDownloadingStatus == .current,
              let size = values.fileSize, size <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        try Task.checkCancellation()
        try beforeOpen?()
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0, before.st_size <= maximumBytes else { throw CocoaError(.fileReadNoPermission) }
        try validateDescriptorPath(descriptor, authorizedRoot: root)
        let version = FileSystemObjectVersion(metadata: before)
        var data = Data()
        while data.count <= maximumBytes {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: min(256 * 1_024, maximumBytes + 1 - data.count)), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        try Task.checkCancellation()
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              version == FileSystemObjectVersion(metadata: after) else { throw CocoaError(.fileReadUnknown) }
        try validateDescriptorPath(descriptor, authorizedRoot: root)
        return data
    }

    private nonisolated static func validateDescriptorPath(_ descriptor: Int32, authorizedRoot: URL) throws {
        var pathBytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = pathBytes.withUnsafeMutableBufferPointer { buffer in
            fcntl(descriptor, F_GETPATH, buffer.baseAddress!)
        }
        guard result == 0 else { throw CocoaError(.fileReadNoPermission) }
        let actualPath = String(cString: pathBytes)
        guard DocumentPreviewPolicy.isWithinAuthorizedRoot(filePath: actualPath, rootPath: authorizedRoot.path),
              !ScanExclusions.isSensitivePath(URL(fileURLWithPath: actualPath)) else { throw CocoaError(.fileReadNoPermission) }
    }
}

@MainActor
private enum InspectorReadingPositionCache {
    struct PDFPosition { let pageIndex: Int; let point: NSPoint }
    enum Position { case pdf(PDFPosition), text(NSPoint) }
    private static var values: [String: Position] = [:]
    private static var order: [String] = []
    static func position(for key: String) -> Position? { values[key] }
    static func store(_ position: Position, for key: String) {
        values[key] = position
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > 16 { values.removeValue(forKey: order.removeFirst()) }
    }
}

private final class PDFInteractionMonitor {
    let token: Any
    init(_ token: Any) { self.token = token }
    deinit { NSEvent.removeMonitor(token) }
}

private final class PDFLayoutObservation {
    private let token: NSObjectProtocol
    @MainActor init(name: Notification.Name, object: AnyObject, action: @escaping @MainActor () -> Void) {
        token = NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        }
    }
    deinit { NotificationCenter.default.removeObserver(token) }
}

@MainActor
final class InspectorPDFView: PDFView {
    private var tracksInitialLayout = true
    private var anchoredSize: NSSize?
    private var isPositioningInitialPage = false
    private var scheduledSize: NSSize?
    private var anchorRevision: UInt64 = 0
    private var interactionMonitor: PDFInteractionMonitor?
    private var scaleObservation: PDFLayoutObservation?
    private var clipObservation: PDFLayoutObservation?
    private weak var observedClipView: NSClipView?
    private var readingPositionKey: String?
    private var initialReadingPosition: InspectorReadingPositionCache.PDFPosition?
#if DEBUG
    private var debugScaleNotificationCount = 0
    private var debugClipNotificationCount = 0
    private var debugIgnoredClipNotificationCount = 0
    private var debugAnchorCount = 0
    private var debugLastAnchorReturn = "none"
    private var debugLastInteraction = "none"

    var initialLayoutDiagnostics: String {
        func clipDescription(_ clip: NSClipView?) -> String {
            guard let clip else { return "nil" }
            return "id=\(ObjectIdentifier(clip)),bounds=\(clip.bounds),postsBounds=\(clip.postsBoundsChangedNotifications)"
        }
        return "tracks=\(tracksInitialLayout),anchored=\(String(describing: anchoredSize)),scheduled=\(String(describing: scheduledSize)),positioning=\(isPositioningInitialPage),observedClip={\(clipDescription(observedClipView))},actualClip={\(clipDescription(documentView?.enclosingScrollView?.contentView))},scaleNotifications=\(debugScaleNotificationCount),clipNotifications=\(debugClipNotificationCount),ignoredClipNotifications=\(debugIgnoredClipNotificationCount),anchors=\(debugAnchorCount),lastAnchorReturn=\(debugLastAnchorReturn),lastInteraction=\(debugLastInteraction)"
    }
#endif

    func installPreviewDocument(_ document: PDFDocument, readingPositionKey: String? = nil) {
        guard self.document !== document || self.readingPositionKey != readingPositionKey else { return }
        saveReadingPosition()
        self.readingPositionKey = readingPositionKey
        initialReadingPosition = nil
        if let readingPositionKey,
           case let .pdf(position) = InspectorReadingPositionCache.position(for: "pdf|" + readingPositionKey),
           position.pageIndex >= 0, position.pageIndex < document.pageCount {
            initialReadingPosition = position
        }
        tracksInitialLayout = true
        anchoredSize = nil
        scheduledSize = nil
        anchorRevision &+= 1
        self.document = document
        observeInitialLayout()
        scheduleInitialPosition()
    }

    func saveReadingPosition() {
        // A recreated PDFView may be torn down before its queued restoration.
        // Preserve the prior cache until that destination was actually reached.
        guard let readingPositionKey, !tracksInitialLayout || (initialReadingPosition != nil && isAtFirstPageTop),
              let document, let destination = currentDestination,
              let page = destination.page, bounds.width > 0, bounds.height > 0 else { return }
        let pageIndex = document.index(for: page)
        guard pageIndex >= 0, pageIndex < document.pageCount else { return }
        InspectorReadingPositionCache.store(.pdf(.init(pageIndex: pageIndex, point: destination.point)),
                                            for: "pdf|" + readingPositionKey)
    }

    /// Once the user navigates, PDFKit exclusively owns the reading position.
    func noteUserInteraction() {
#if DEBUG
        debugLastInteraction = "explicit noteUserInteraction"
#endif
        tracksInitialLayout = false
        anchorRevision &+= 1
        scheduledSize = nil
        scaleObservation = nil
        clipObservation = nil
        observedClipView = nil
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scheduleInitialPosition()
    }

    override func layout() {
        super.layout()
        observeInitialLayout()
        scheduleInitialPosition()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        interactionMonitor = nil
        scaleObservation = nil
        clipObservation = nil
        observedClipView = nil
        guard window != nil else { return }
        let token = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown, .magnify, .smartMagnify]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let targetsPDF: Bool
            if event.type == .keyDown {
                targetsPDF = (self.window?.firstResponder as? NSView)?.isDescendant(of: self) == true
            } else {
                targetsPDF = self.bounds.contains(self.convert(event.locationInWindow, from: nil))
            }
            if targetsPDF {
                self.noteUserInteraction()
#if DEBUG
                self.debugLastInteraction = "event=\(event.type.rawValue),location=\(event.locationInWindow),keyCode=\(event.type == .keyDown ? String(event.keyCode) : "n/a"),timestamp=\(event.timestamp)"
#endif
            }
            return event
        }
        interactionMonitor = token.map(PDFInteractionMonitor.init)
        observeInitialLayout()
        scheduleInitialPosition()
    }

    private func observeInitialLayout() {
        guard tracksInitialLayout, window != nil else { return }
        if scaleObservation == nil {
            scaleObservation = PDFLayoutObservation(name: .PDFViewScaleChanged, object: self) { [weak self] in
#if DEBUG
                self?.debugScaleNotificationCount += 1
#endif
                self?.scheduleInitialPosition()
            }
        }
        if let clip = documentView?.enclosingScrollView?.contentView, observedClipView !== clip {
            observedClipView = clip
            clip.postsBoundsChangedNotifications = true
            clipObservation = PDFLayoutObservation(name: NSView.boundsDidChangeNotification, object: clip) { [weak self] in
#if DEBUG
                self?.debugClipNotificationCount += 1
                if self?.isPositioningInitialPage == true { self?.debugIgnoredClipNotificationCount += 1 }
#endif
                self?.scheduleInitialPosition()
            }
        }
    }

    private var isAtFirstPageTop: Bool {
        if let position = initialReadingPosition {
            guard let page = document?.page(at: position.pageIndex), currentPage === page,
                  let destination = currentDestination else { return false }
            return abs(destination.point.y - position.point.y) < 8
        }
        guard let firstPage = document?.page(at: 0), currentPage === firstPage,
              let destination = currentDestination else { return false }
        return destination.point.y >= firstPage.bounds(for: displayBox).maxY - 8
    }

    private func scheduleInitialPosition() {
        let size = bounds.size
        guard tracksInitialLayout, !isPositioningInitialPage, window != nil, (document?.pageCount ?? 0) > 0,
              size.width > 0, size.height > 0,
              (anchoredSize != size || !isAtFirstPageTop), scheduledSize != size else { return }
        scheduledSize = size
        anchorRevision &+= 1
        let revision = anchorRevision
        // Let PDFKit finish its autoscale/layout pass first. An expanding native
        // inspector can otherwise retain a mid-page destination from that pass.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.tracksInitialLayout, self.anchorRevision == revision else { return }
            self.scheduledSize = nil
            guard self.window != nil else { return }
            guard self.bounds.size == size else {
                self.scheduleInitialPosition()
                return
            }
            guard let page = self.document?.page(at: self.initialReadingPosition?.pageIndex ?? 0) else { return }
            guard self.anchoredSize != size || !self.isAtFirstPageTop else { return }
            self.anchoredSize = size
            self.layoutSubtreeIfNeeded()
            let pageBounds = page.bounds(for: self.displayBox)
            // Ignore only synchronous notifications caused by this navigation;
            // PDFKit's later layout must still prove it reached the real top.
            self.isPositioningInitialPage = true
            defer { self.isPositioningInitialPage = false }
#if DEBUG
            self.debugAnchorCount += 1
#endif
            let destination = self.initialReadingPosition?.point ?? NSPoint(x: pageBounds.minX, y: pageBounds.maxY)
            self.go(to: PDFDestination(page: page, at: destination))
#if DEBUG
            self.debugLastAnchorReturn = "destination=\(String(describing: self.currentDestination?.point)),scale=\(self.scaleFactor),bounds=\(self.bounds),atFirstPageTop=\(self.isAtFirstPageTop)"
#endif
        }
    }
}

private struct NativePDFDocumentView: NSViewRepresentable {
    let document: PDFDocument
    let background: NSColor
    let readingPositionKey: String
    let progress: PDFReadingProgress
    func makeNSView(context: Context) -> InspectorPDFView {
        let view = InspectorPDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        return view
    }
    func updateNSView(_ view: InspectorPDFView, context: Context) {
        view.installPreviewDocument(document, readingPositionKey: readingPositionKey)
        progress.observe(view)
        view.backgroundColor = background
        XunJianScrollAppearance.applyRecursively(in: view)
    }
    static func dismantleNSView(_ view: InspectorPDFView, coordinator: ()) {
        view.saveReadingPosition()
    }
}

private struct NativeImageDocumentView: NSViewRepresentable {
    let image: NSImage
    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }
    func updateNSView(_ view: NSImageView, context: Context) { view.image = image }
}

struct InspectorTextDocumentPreview: View {
    let text: String
    let kind: FileKind
    let query: String
    let hasMore: Bool
    let openFullPreview: () -> Void
    var readingPositionKey: String? = nil
    @Environment(\.appVisualTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @State private var currentMatch = 0
    @State private var matchSnapshot: MatchSnapshot?

    private struct SearchInput: Equatable {
        let text: String
        let query: String
    }
    private struct MatchSnapshot {
        let input: SearchInput
        let ranges: [NSRange]
    }
    private var matches: [NSRange] {
        // A body may run with the new document before onChange publishes its
        // ranges. Never apply the previous document's offsets to new text.
        guard let matchSnapshot, matchSnapshot.input == SearchInput(text: text, query: query) else { return [] }
        return matchSnapshot.ranges
    }

    var body: some View {
        VStack(spacing: 0) {
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(spacing: 8) {
                    Text(AppLanguage.localized(
                        matches.isEmpty ? "已加载文本中无匹配" : "已加载文本：\(min(currentMatch + 1, matches.count))/\(matches.count)",
                        english: matches.isEmpty ? "No match in loaded text" : "Loaded text: \(min(currentMatch + 1, matches.count))/\(matches.count)"
                    ))
                    .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    ControlGroup {
                        Button { moveMatch(-1) } label: { Image(systemName: "chevron.up") }
                            .help(AppLanguage.localized("上一处", english: "Previous Match"))
                            .accessibilityLabel(AppLanguage.localized("上一处", english: "Previous Match"))
                        Button { moveMatch(1) } label: { Image(systemName: "chevron.down") }
                            .help(AppLanguage.localized("下一处", english: "Next Match"))
                            .accessibilityLabel(AppLanguage.localized("下一处", english: "Next Match"))
                    }
                    .controlSize(.small).disabled(matches.isEmpty)
                }
                .padding(.horizontal, theme.contentPadding).padding(.vertical, 8)
            }
            NativeInspectorTextView(text: text, matches: matches, currentMatch: currentMatch,
                font: kind == .code ? .monospacedSystemFont(ofSize: theme.previewFontSize, weight: .regular) : .systemFont(ofSize: theme.previewFontSize),
                padding: theme.contentPadding, lineSpacing: theme == .reading ? 7 : 4,
                selectionColor: NSColor(theme.palette(for: colorScheme).selection), accentColor: NSColor(theme.palette(for: colorScheme).accent), readingPositionKey: readingPositionKey)
            if hasMore {
                HStack {
                    Text(AppLanguage.localized("已加载前 20,000 字", english: "First 20,000 characters loaded"))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button(AppLanguage.localized("完整文本", english: "Full Text"), action: openFullPreview)
                        .buttonStyle(.link)
                }
                .padding(.horizontal, theme.contentPadding).padding(.vertical, 8)
            }
        }
        .onChange(of: SearchInput(text: text, query: query), initial: true) { _, input in
            matchSnapshot = MatchSnapshot(input: input, ranges: DocumentPreviewPolicy.matchRanges(in: input.text, query: input.query))
            currentMatch = 0
        }
    }

    private func moveMatch(_ delta: Int) {
        currentMatch = DocumentPreviewPolicy.nextMatch(current: currentMatch, delta: delta, count: matches.count)
    }
}

@MainActor
final class InspectorTextScrollView: NSScrollView {
    private var readingPositionKey: String?
    private var pendingOrigin: NSPoint?

    func prepareReadingPosition(for key: String) {
        guard readingPositionKey != key else { return }
        saveReadingPosition()
        readingPositionKey = key
        pendingOrigin = nil
        if case let .text(origin) = InspectorReadingPositionCache.position(for: "text|" + key) {
            pendingOrigin = origin
        }
    }

    func restoreReadingPositionIfNeeded() {
        guard let origin = pendingOrigin, let key = readingPositionKey else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.readingPositionKey == key, self.pendingOrigin != nil else { return }
            self.layoutSubtreeIfNeeded()
            if let textView = self.documentView as? NSTextView, let container = textView.textContainer {
                textView.layoutManager?.ensureLayout(for: container)
            }
            self.contentView.scroll(to: origin)
            self.reflectScrolledClipView(self.contentView)
            self.pendingOrigin = nil
        }
    }

    func saveReadingPosition() {
        guard let readingPositionKey, pendingOrigin == nil, documentView != nil else { return }
        InspectorReadingPositionCache.store(.text(contentView.bounds.origin), for: "text|" + readingPositionKey)
    }
}

struct InspectorTextContent: Equatable {
    let text: String
    let matches: [NSRange]
    let font: NSFont
    let lineSpacing: CGFloat
    let selectionColor: NSColor
    let accentColor: NSColor
}

/// Content generation is independent of selection navigation and scroll layout.
struct InspectorTextRenderCache {
    private var content: InspectorTextContent?
    private var rendered: NSAttributedString?

    mutating func attributedText(for content: InspectorTextContent) -> NSAttributedString {
        if self.content == content, let rendered { return rendered }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = content.lineSpacing
        let value = NSMutableAttributedString(string: content.text, attributes: [
            .font: content.font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
        ])
        for range in content.matches {
            value.addAttributes([.backgroundColor: content.selectionColor, .foregroundColor: content.accentColor], range: range)
        }
        let immutable = NSAttributedString(attributedString: value)
        self.content = content
        rendered = immutable
        return immutable
    }
}

private struct NativeInspectorTextView: NSViewRepresentable {
    let text: String
    let matches: [NSRange]
    let currentMatch: Int
    let font: NSFont
    let padding: CGFloat
    let lineSpacing: CGFloat
    let selectionColor: NSColor
    let accentColor: NSColor
    let readingPositionKey: String?

    final class Coordinator {
        var text = ""
        var matches: [NSRange] = []
        var currentMatch = -1
        var renderCache = InspectorTextRenderCache()
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> InspectorTextScrollView {
        let scroll = InspectorTextScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = view
        XunJianScrollAppearance.apply(to: scroll)
        return scroll
    }
    func updateNSView(_ scroll: InspectorTextScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        if let readingPositionKey { scroll.prepareReadingPosition(for: readingPositionKey) }
        let coordinator = context.coordinator
        let navigate = coordinator.text != text || coordinator.matches != matches || coordinator.currentMatch != currentMatch
        let attributed = coordinator.renderCache.attributedText(for: InspectorTextContent(
            text: text, matches: matches, font: font, lineSpacing: lineSpacing,
            selectionColor: selectionColor, accentColor: accentColor
        ))
        view.textContainerInset = NSSize(width: padding, height: padding)
        if view.textStorage?.isEqual(to: attributed) != true { view.textStorage?.setAttributedString(attributed) }
        coordinator.text = text
        coordinator.matches = matches
        coordinator.currentMatch = currentMatch
        if navigate, matches.indices.contains(currentMatch) {
            view.scrollRangeToVisible(matches[currentMatch])
            view.showFindIndicator(for: matches[currentMatch])
        } else if navigate, matches.isEmpty {
            view.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }
        scroll.restoreReadingPositionIfNeeded()
    }
    static func dismantleNSView(_ view: InspectorTextScrollView, coordinator: Coordinator) {
        view.saveReadingPosition()
    }
}
