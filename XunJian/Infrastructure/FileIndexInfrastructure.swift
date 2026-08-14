import Darwin
import Foundation
import SQLite3
import UniformTypeIdentifiers

enum FilePathCanonicalizer {
    static func path(_ url: URL) -> String {
        // `resolvingSymlinksInPath()` cannot reliably resolve `/var` to
        // `/private/var` after the final item has already moved away. Resolve
        // the nearest existing ancestor, then append the missing suffix so
        // live FSEvents and later reconciliation use the same identity.
        var existingAncestor = url.standardizedFileURL
        var missingComponents: [String] = []
        while existingAncestor.path != "/",
              !FileManager.default.fileExists(atPath: existingAncestor.path) {
            missingComponents.insert(existingAncestor.lastPathComponent, at: 0)
            existingAncestor.deleteLastPathComponent()
        }
        let resolvedAncestorPath = existingAncestor.path.withCString { pathPointer in
            guard let resolvedPointer = Darwin.realpath(pathPointer, nil) else {
                return existingAncestor.path
            }
            defer { free(resolvedPointer) }
            return String(cString: resolvedPointer)
        }
        var resolved = URL(fileURLWithPath: resolvedAncestorPath, isDirectory: true)
        for component in missingComponents {
            resolved.appendPathComponent(component)
        }
        var resolvedPath = resolved.path
        // Keep the stable, user-facing macOS aliases used by
        // FileManager. FSEvents reports their `/private` targets directly,
        // so normalize both forms to one value regardless of existence.
        if resolvedPath == "/private/var" {
            resolvedPath = "/var"
        } else if resolvedPath.hasPrefix("/private/var/") {
            resolvedPath = "/var/" + String(resolvedPath.dropFirst("/private/var/".count))
        } else if resolvedPath == "/private/tmp" {
            resolvedPath = "/tmp"
        } else if resolvedPath.hasPrefix("/private/tmp/") {
            resolvedPath = "/tmp/" + String(resolvedPath.dropFirst("/private/tmp/".count))
        }
        return resolvedPath.precomposedStringWithCanonicalMapping
    }

    static func path(_ path: String) -> String {
        self.path(URL(fileURLWithPath: path))
    }
}

enum IndexedFileIdentity {
    static let resourceKeys: Set<URLResourceKey> = [
        .fileResourceIdentifierKey,
        .volumeIdentifierKey
    ]

    static func id(
        sourceID: UUID,
        url: URL,
        values: URLResourceValues,
        fileManager: FileManager = .default
    ) -> String {
        let resourceIdentifier: String
        if let identifier = values.fileResourceIdentifier {
            resourceIdentifier = String(describing: identifier)
        } else if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let device = attributes[.systemNumber] as? NSNumber,
                  let inode = attributes[.systemFileNumber] as? NSNumber {
            resourceIdentifier = "inode:\(device):\(inode)"
        } else {
            resourceIdentifier = "path:\(FilePathCanonicalizer.path(url))"
        }
        let volumeIdentifier = values.volumeIdentifier
            .map { String(describing: $0) } ?? "volume"
        return "\(sourceID.uuidString):\(volumeIdentifier):\(resourceIdentifier)"
    }
}

struct IndexedFile: Identifiable, Hashable, Sendable {
    let id: String
    let sourceID: UUID
    let name: String
    let path: String
    let fileExtension: String
    let kind: FileKind
    let size: Int64
    let createdAt: Date?
    let modifiedAt: Date?
    let indexedAt: Date
    let textContent: String?
    /// Read-only Finder tags captured at scan time (N11).
    let tagNames: [String]

    init(
        id: String,
        sourceID: UUID,
        name: String,
        path: String,
        fileExtension: String,
        kind: FileKind,
        size: Int64,
        createdAt: Date?,
        modifiedAt: Date?,
        indexedAt: Date,
        textContent: String? = nil,
        tagNames: [String] = []
    ) {
        self.id = id
        self.sourceID = sourceID
        self.name = name
        self.path = path
        self.fileExtension = fileExtension
        self.kind = kind
        self.size = size
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.indexedAt = indexedAt
        self.textContent = textContent
        self.tagNames = tagNames
    }

    var url: URL { URL(fileURLWithPath: path) }

    var parentPath: String {
        url.deletingLastPathComponent().path
    }
}

struct FileSearchPage: Equatable, Sendable {
    let files: [IndexedFile]
    let totalCount: Int

    var hasMore: Bool { files.count < totalCount }
}

struct FileTextContentUpdate: Sendable {
    let fileID: String
    let textContent: String?
}

enum FileIndexPreferences {
    static let includesHiddenFilesKey = "fileIndex.includesDotPrefixedFiles"
    static let indexesFileContentsKey = "fileIndex.indexesFileContents"
    static let disabledContentPurgeCompletedKey = "fileIndex.disabledContentPurgeCompleted"

    static var indexesFileContents: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: indexesFileContentsKey) != nil else { return true }
        return defaults.bool(forKey: indexesFileContentsKey)
    }
}

enum SourceAccessState: String, Sendable {
    case available
    case needsAuthorization
    case unavailable
}

struct FileSource: Identifiable, Hashable, Sendable {
    let id: UUID
    let displayName: String
    let path: String
    let bookmark: Data
    let enabled: Bool
    let createdAt: Date
    var accessState: SourceAccessState = .available

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

struct ScanProgress: Equatable, Sendable {
    let discoveredCount: Int
    let currentPath: String
    var sourceIndex: Int = 1
    var sourceCount: Int = 1
}

/// A persisted search (N07): query text plus the manual filter values, so a
/// frequently used narrowing becomes a one-click sidebar entry.
struct SavedSearch: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var query: String
    var minSizeBytes: Int64
    var minDate: Date?
    let createdAt: Date
    var fileKind: FileKind? = nil

    /// One-line description of the stored query and filters, shown under the
    /// name in the sidebar so a saved search is recognisable without opening it.
    func conditionSummary(usesEnglish: Bool) -> String {
        var parts: [String] = []
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty {
            parts.append(usesEnglish ? "Any name" : "不限名称")
        } else {
            parts.append(trimmedQuery)
        }
        if let fileKind {
            parts.append(fileKind.title(usesEnglish: usesEnglish))
        }
        if minSizeBytes > 0 {
            let size = ByteCountFormatter.string(fromByteCount: minSizeBytes, countStyle: .file)
            parts.append("≥ \(size)")
        }
        if let minDate {
            let formatted = Self.summaryDateFormatter.string(from: minDate)
            parts.append(usesEnglish ? "Since \(formatted)" : "不早于 \(formatted)")
        }
        return parts.joined(separator: " · ")
    }

    /// True when this saved search is the same query and filters the user is
    /// looking at now, so the sidebar can mark it as current.
    func matches(
        query: String,
        minSizeBytes: Int64,
        minDate: Date?,
        fileKind: FileKind? = nil
    ) -> Bool {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let ownQuery = self.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedQuery == ownQuery,
              minSizeBytes == self.minSizeBytes,
              self.fileKind == fileKind else {
            return false
        }
        switch (minDate, self.minDate) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return abs(lhs.timeIntervalSince1970 - rhs.timeIntervalSince1970) < 1
        default:
            return false
        }
    }

    private static let summaryDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}

struct ResolvedBookmark: Sendable {
    let url: URL
    let isStale: Bool
}

enum FileIndexError: LocalizedError, Sendable {
    case database(String)
    case bookmarkCreation
    case bookmarkResolution
    case unreadableFolder(String)
    case overlappingSource(String)
    case invalidCategoryName
    case categoryExists

    static var databaseUnavailable: FileIndexError {
        .database(AppLanguage.localized(
            "当前不可用，请在设置中重试。",
            english: "It is currently unavailable. Retry from Settings."
        ))
    }

    var errorDescription: String? {
        switch self {
        case let .database(message):
            AppLanguage.localized("无法访问本地文件索引：\(message)", english: "The local file index could not be accessed: \(message)")
        case .bookmarkCreation:
            AppLanguage.localized("无法保存这个文件夹的访问权限，请重新选择。", english: "Access to this folder could not be saved. Select it again.")
        case .bookmarkResolution:
            AppLanguage.localized("macOS 已取消这个文件夹的访问权限，请重新授权。", english: "macOS revoked access to this folder. Authorize it again.")
        case let .unreadableFolder(name):
            AppLanguage.localized("无法读取文件夹“\(name)”，请检查它是否存在以及当前权限。", english: "The folder “\(name)” could not be read. Check that it exists and that access is allowed.")
        case let .overlappingSource(existingName):
            AppLanguage.localized(
                "无法添加这个文件夹，因为它与已授权文件夹“\(existingName)”重叠。请选择现有索引范围之外的文件夹。",
                english: "Cannot add this folder because it overlaps the authorized folder \(existingName). Choose a folder outside the existing indexed folders."
            )
        case .invalidCategoryName:
            AppLanguage.localized("分类名称不能为空，且最多使用 80 个字符。", english: "A category name is required and cannot exceed 80 characters.")
        case .categoryExists:
            AppLanguage.localized("已经存在同名分类，请换一个名称。", english: "A category with this name already exists.")
        }
    }
}

struct BookmarkManager: Sendable {
    func createBookmark(for url: URL) throws -> Data {
        do {
            return try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw FileIndexError.bookmarkCreation
        }
    }

    func resolveBookmark(_ data: Data) throws -> ResolvedBookmark {
        var isStale = false

        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return ResolvedBookmark(url: url, isStale: isStale)
        } catch {
            throw FileIndexError.bookmarkResolution
        }
    }
}

actor FileScanner {
    typealias ProgressHandler = @Sendable (ScanProgress) -> Void
    typealias ResourceValuesLoader = @Sendable (
        URL,
        Set<URLResourceKey>
    ) throws -> URLResourceValues

    private let fileManager: FileManager
    private let excludedDirectoryNames: Set<String>
    /// User-added folder names, refreshed before each scan.
    private var additionalExcludedNames: Set<String> = []
    private let textExtractor: TextExtractionService
    private let resourceValuesLoader: ResourceValuesLoader

    /// Paths that could not be read during the most recent scan. A single
    /// permission-denied subfolder must not fail the whole scan, but the user
    /// still needs to know the index is incomplete.
    private(set) var lastScanSkippedPaths: [String] = []
    private static let resourceKeys: [URLResourceKey] = [
        .nameKey,
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .creationDateKey,
        .contentModificationDateKey,
        .contentTypeKey,
        .fileResourceIdentifierKey,
        .volumeIdentifierKey
    ]

    static func isComplete(skippedPaths: [String]) -> Bool {
        skippedPaths.isEmpty
    }

    init(
        fileManager: FileManager = .default,
        textExtractor: TextExtractionService = TextExtractionService(),
        resourceValuesLoader: @escaping ResourceValuesLoader = { url, keys in
            try url.resourceValues(forKeys: keys)
        }
    ) {
        self.fileManager = fileManager
        self.textExtractor = textExtractor
        self.resourceValuesLoader = resourceValuesLoader
        self.excludedDirectoryNames = ScanExclusions.builtIn
    }

    func setAdditionalExcludedNames(_ names: Set<String>) {
        additionalExcludedNames = names
    }

    func scan(
        sourceID: UUID,
        rootURL: URL,
        includesHiddenFiles: Bool = false,
        extractsText: Bool = true,
        progress: ProgressHandler? = nil
    ) async throws -> [IndexedFile] {
        lastScanSkippedPaths = []
        return try enumerate(
            sourceID: sourceID,
            rootURL: rootURL,
            includesHiddenFiles: includesHiddenFiles,
            extractsText: extractsText,
            progress: progress
        )
    }

    /// Content extraction is deliberately separate from metadata discovery.
    /// The coordinator can publish the usable file list first, then enrich
    /// FTS in one bounded, cancellable pass.
    func extractTextContents(
        in files: [IndexedFile],
        batchSize: Int = 64,
        consume: @Sendable ([FileTextContentUpdate]) async throws -> Void,
        progress: ProgressHandler? = nil
    ) async throws {
        precondition(batchSize > 0)
        let candidates = files.filter { textExtractor.supports($0.url) }
        var updates: [FileTextContentUpdate] = []
        updates.reserveCapacity(min(batchSize, candidates.count))
        for (offset, file) in candidates.enumerated() {
            try Task.checkCancellation()
            updates.append(
                FileTextContentUpdate(
                    fileID: file.id,
                    textContent: textExtractor.extractText(from: file.url)
                )
            )
            if updates.count == batchSize {
                try await consume(updates)
                updates.removeAll(keepingCapacity: true)
            }
            if offset.isMultiple(of: 25) {
                progress?(
                    ScanProgress(
                        discoveredCount: files.count,
                        currentPath: file.path
                    )
                )
            }
        }
        if !updates.isEmpty {
            try await consume(updates)
        }
    }

    func scanChanges(
        sourceID: UUID,
        rootURL: URL,
        events: [FileSystemChangeEvent],
        includesHiddenFiles: Bool = false,
        extractsText: Bool = true
    ) async throws -> IncrementalScanSnapshot {
        lastScanSkippedPaths = []
        let canonicalRootPath = canonicalPath(rootURL.path)
        var scopes: Set<FileIndexScope> = []

        for event in events where !event.requiresFullRescan {
            let eventPath = canonicalPath(event.path)
            guard isPath(eventPath, inside: canonicalRootPath),
                  (includesHiddenFiles || !isDotPrefixedPath(eventPath)),
                  !isExcludedPath(eventPath, relativeTo: canonicalRootPath) else {
                continue
            }

            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: eventPath, isDirectory: &isDirectory)
            scopes.insert(
                FileIndexScope(
                    path: eventPath,
                    includesDescendants: event.isDirectory || (exists && isDirectory.boolValue)
                )
            )
        }

        let indexedAt = Date()
        var filesByID: [String: IndexedFile] = [:]
        var successfulScopes: Set<FileIndexScope> = []
        var failedScopes: Set<FileIndexScope> = []
        for scope in scopes {
            try Task.checkCancellation()
            let url = URL(fileURLWithPath: scope.path, isDirectory: scope.includesDescendants)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: scope.path, isDirectory: &isDirectory) else {
                successfulScopes.insert(scope)
                continue
            }

            let directoryValues: URLResourceValues?
            if isDirectory.boolValue {
                do {
                    directoryValues = try resourceValuesLoader(url, Set(Self.resourceKeys))
                } catch {
                    failedScopes.insert(scope)
                    continue
                }
            } else {
                directoryValues = nil
            }

            if let directoryValues,
               Self.isDocumentPackage(url, values: directoryValues) {
                successfulScopes.insert(scope)
                if let file = indexedFile(
                    at: url,
                    values: directoryValues,
                    sourceID: sourceID,
                    indexedAt: indexedAt,
                    extractsText: extractsText
                ) {
                    filesByID[file.id] = file
                }
            } else if scope.includesDescendants || isDirectory.boolValue {
                let scannedFiles: [IndexedFile]
                do {
                    scannedFiles = try enumerate(
                        sourceID: sourceID,
                        rootURL: url,
                        includesHiddenFiles: includesHiddenFiles,
                        extractsText: extractsText,
                        progress: nil
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failedScopes.insert(scope)
                    continue
                }
                successfulScopes.insert(scope)
                for file in scannedFiles {
                    filesByID[file.id] = file
                }
            } else {
                let values: URLResourceValues
                do {
                    values = try resourceValuesLoader(url, Set(Self.resourceKeys))
                } catch {
                    failedScopes.insert(scope)
                    continue
                }
                successfulScopes.insert(scope)
                if let file = indexedFile(
                        at: url,
                        values: values,
                        sourceID: sourceID,
                        indexedAt: indexedAt,
                        extractsText: extractsText
                      ) {
                    filesByID[file.id] = file
                }
            }
        }

        return IncrementalScanSnapshot(
            scopes: successfulScopes.sorted {
                $0.path.localizedStandardCompare($1.path) == .orderedAscending
            },
            failedScopes: failedScopes.sorted {
                $0.path.localizedStandardCompare($1.path) == .orderedAscending
            },
            files: filesByID.values.sorted {
                $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
        )
    }

    private func enumerate(
        sourceID: UUID,
        rootURL: URL,
        includesHiddenFiles: Bool,
        extractsText: Bool,
        progress: ProgressHandler?
    ) throws -> [IndexedFile] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              fileManager.isReadableFile(atPath: rootURL.path) else {
            throw FileIndexError.unreadableFolder(rootURL.lastPathComponent)
        }

        // Collected synchronously by the enumerator's error handler, which runs
        // inline on this thread for each unreadable item.
        var skippedPaths: [String] = []
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Self.resourceKeys,
            options: [.skipsPackageDescendants],
            errorHandler: { url, _ in
                skippedPaths.append(url.path)
                return true
            }
        ) else {
            throw FileIndexError.unreadableFolder(rootURL.lastPathComponent)
        }

        var files: [IndexedFile] = []
        let indexedAt = Date()

        for case let fileURL as URL in enumerator {
            try Task.checkCancellation()

            let values: URLResourceValues
            do {
                values = try resourceValuesLoader(fileURL, Set(Self.resourceKeys))
            } catch {
                // Fail closed by design (see FileScannerTests): metadata
                // failure aborts the scan so the previous index is preserved.
                throw FileIndexError.unreadableFolder(rootURL.lastPathComponent)
            }

            if values.isDirectory == true, !Self.isDocumentPackage(fileURL, values: values) {
                if (!includesHiddenFiles && fileURL.lastPathComponent.hasPrefix("."))
                    || shouldExcludeDirectory(fileURL.lastPathComponent)
                    || values.isSymbolicLink == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            if !includesHiddenFiles, fileURL.lastPathComponent.hasPrefix(".") {
                continue
            }

            guard let file = indexedFile(
                at: fileURL,
                values: values,
                sourceID: sourceID,
                indexedAt: indexedAt,
                extractsText: extractsText
            ) else { continue }
            files.append(file)

            if files.count.isMultiple(of: 100) {
                progress?(
                    ScanProgress(discoveredCount: files.count, currentPath: fileURL.path)
                )
            }
        }

        lastScanSkippedPaths.append(contentsOf: skippedPaths)
        guard Self.isComplete(skippedPaths: skippedPaths) else {
            // Never return a partial directory snapshot. A full scan keeps its
            // previous index, while an incremental scan marks this scope as
            // failed and therefore excludes it from reconciliation.
            throw FileIndexError.unreadableFolder(rootURL.lastPathComponent)
        }

        progress?(
            ScanProgress(discoveredCount: files.count, currentPath: rootURL.path)
        )

        return files.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    private func shouldExcludeDirectory(_ name: String) -> Bool {
        let lowercased = name.lowercased()
        return excludedDirectoryNames.contains(lowercased)
            || additionalExcludedNames.contains(lowercased)
    }

    private func isDotPrefixedPath(_ path: String) -> Bool {
        URL(fileURLWithPath: path).pathComponents.contains {
            $0.count > 1 && $0.hasPrefix(".")
        }
    }

    private func indexedFile(
        at fileURL: URL,
        values: URLResourceValues,
        sourceID: UUID,
        indexedAt: Date,
        extractsText: Bool
    ) -> IndexedFile? {
        guard (values.isRegularFile == true || Self.isDocumentPackage(fileURL, values: values)),
              values.isSymbolicLink != true else {
            return nil
        }

        let name = (values.name ?? fileURL.lastPathComponent)
            .precomposedStringWithCanonicalMapping
        let storedPath = canonicalPath(fileURL.path)
        let fileExtension = fileURL.pathExtension.lowercased()
        return IndexedFile(
            id: IndexedFileIdentity.id(
                sourceID: sourceID,
                url: fileURL,
                values: values,
                fileManager: fileManager
            ),
            sourceID: sourceID,
            name: name,
            path: storedPath,
            fileExtension: fileExtension,
            kind: Self.fileKind(contentType: values.contentType, fileExtension: fileExtension),
            size: Int64(values.fileSize ?? 0),
            createdAt: values.creationDate,
            modifiedAt: values.contentModificationDate,
            indexedAt: indexedAt,
            textContent: extractsText ? textExtractor.extractText(from: fileURL) : nil
        )
    }

    private func canonicalPath(_ path: String) -> String {
        FilePathCanonicalizer.path(path)
    }

    private static func isDocumentPackage(_ url: URL, values: URLResourceValues) -> Bool {
        guard values.isDirectory == true else { return false }
        switch url.pathExtension.lowercased() {
        case "pages", "numbers", "key":
            return true
        default:
            return false
        }
    }

    private func isPath(_ path: String, inside rootPath: String) -> Bool {
        path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    private func isExcludedPath(_ path: String, relativeTo rootPath: String) -> Bool {
        guard path != rootPath else { return false }
        let relativePath = String(path.dropFirst(rootPath.count))
        return relativePath.split(separator: "/").contains {
            shouldExcludeDirectory(String($0))
        }
    }

    private static func fileKind(contentType: UTType?, fileExtension: String) -> FileKind {
        if let contentType {
            if contentType.conforms(to: .image) { return .image }
            if contentType.conforms(to: .movie) || contentType.conforms(to: .video) { return .video }
            if contentType.conforms(to: .audio) { return .audio }
            if contentType.conforms(to: .archive) { return .archive }
            if contentType.conforms(to: .sourceCode) { return .code }
            if contentType.conforms(to: .text) || contentType.conforms(to: .pdf) { return .document }
        }

        switch fileExtension {
        case "doc", "docx", "pages", "xls", "xlsx", "numbers", "ppt", "pptx", "key":
            return .document
        case "zip", "rar", "7z", "tar", "gz", "bz2", "xz":
            return .archive
        case "swift", "m", "mm", "c", "h", "cpp", "js", "ts", "py", "sh", "rb", "go", "rs":
            return .code
        default:
            return .other
        }
    }
}

actor FileIndexDatabase {
    private let connection: SQLiteConnection

    init(databaseURL: URL) throws {
        let databaseDirectory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: databaseDirectory.path
        )

        var openedDatabase: OpaquePointer?
        let openCode = sqlite3_open_v2(
            databaseURL.path,
            &openedDatabase,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )

        guard openCode == SQLITE_OK, let openedDatabase else {
            let message = openedDatabase.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
            if let openedDatabase { sqlite3_close(openedDatabase) }
            throw FileIndexError.database(message)
        }

        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: databaseURL.path
            )
            try Self.execute("PRAGMA foreign_keys = ON;", on: openedDatabase)
            try Self.execute("PRAGMA journal_mode = WAL;", on: openedDatabase)
            try Self.execute("PRAGMA synchronous = NORMAL;", on: openedDatabase)
            try Self.migrate(openedDatabase)
            try Self.restrictDatabaseFiles(at: databaseURL)
        } catch {
            sqlite3_close(openedDatabase)
            throw error
        }

        connection = SQLiteConnection(pointer: openedDatabase)
    }

    static func defaultDatabaseURL() throws -> URL {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw FileIndexError.database("无法定位 Application Support 目录")
        }

        return applicationSupport
            .appendingPathComponent("XunJian", isDirectory: true)
            .appendingPathComponent("index.sqlite3")
    }

    /// Pauses or resumes indexing for one source (N06). Disabled sources are
    /// skipped by scanning and monitoring but keep their index rows.
    func setSourceEnabled(id: UUID, enabled: Bool) throws {
        let statement = try prepare(
            "UPDATE sources SET enabled = ? WHERE id = ?;"
        )
        defer { sqlite3_finalize(statement) }
        try bind(enabled ? 1 : 0, at: 1, to: statement)
        try bind(id.uuidString, at: 2, to: statement)
        try stepDone(statement)
    }

    func upsertSource(
        displayName: String,
        path: String,
        bookmark: Data
    ) throws -> FileSource {
        let existing = try source(withPath: path)
        let source = FileSource(
            id: existing?.id ?? UUID(),
            displayName: displayName,
            path: path,
            bookmark: bookmark,
            enabled: true,
            createdAt: existing?.createdAt ?? Date()
        )

        let statement = try prepare(
            """
            INSERT INTO sources (id, display_name, path, bookmark, enabled, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET
                display_name = excluded.display_name,
                bookmark = excluded.bookmark,
                enabled = excluded.enabled;
            """
        )
        defer { sqlite3_finalize(statement) }

        try bind(source.id.uuidString, at: 1, to: statement)
        try bind(source.displayName, at: 2, to: statement)
        try bind(source.path, at: 3, to: statement)
        try bind(source.bookmark, at: 4, to: statement)
        try bind(source.enabled ? 1 : 0, at: 5, to: statement)
        try bind(source.createdAt.timeIntervalSince1970, at: 6, to: statement)
        try stepDone(statement)

        return source
    }

    func updateBookmark(for sourceID: UUID, bookmark: Data, path: String) throws {
        let statement = try prepare(
            "UPDATE sources SET bookmark = ?, path = ? WHERE id = ?;"
        )
        defer { sqlite3_finalize(statement) }

        try bind(bookmark, at: 1, to: statement)
        try bind(path, at: 2, to: statement)
        try bind(sourceID.uuidString, at: 3, to: statement)
        try stepDone(statement)
    }

    func fetchSources() throws -> [FileSource] {
        let statement = try prepare(
            """
            SELECT id, display_name, path, bookmark, enabled, created_at
            FROM sources
            ORDER BY created_at ASC;
            """
        )
        defer { sqlite3_finalize(statement) }

        var sources: [FileSource] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = UUID(uuidString: text(statement, column: 0)) else { continue }
            sources.append(
                FileSource(
                    id: id,
                    displayName: text(statement, column: 1),
                    path: text(statement, column: 2),
                    bookmark: blob(statement, column: 3),
                    enabled: sqlite3_column_int(statement, 4) == 1,
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
                )
            )
        }
        return sources
    }

    func deleteSource(_ sourceID: UUID) throws {
        try transaction {
            let deleteSearchStatement = try prepare(
                """
                DELETE FROM file_search
                WHERE file_id IN (SELECT id FROM files WHERE source_id = ?);
                """
            )
            do {
                defer { sqlite3_finalize(deleteSearchStatement) }
                try bind(sourceID.uuidString, at: 1, to: deleteSearchStatement)
                try stepDone(deleteSearchStatement)
            }

            let deleteSourceStatement = try prepare("DELETE FROM sources WHERE id = ?;")
            defer { sqlite3_finalize(deleteSourceStatement) }
            try bind(sourceID.uuidString, at: 1, to: deleteSourceStatement)
            try stepDone(deleteSourceStatement)
        }
    }

    /// Replaces a source's file rows with a fresh full-scan result.
    ///
    /// When `deletesUnscanned` is false (a scan that skipped unreadable
    /// folders), rows that were not seen this time are kept instead of being
    /// deleted — otherwise files in skipped folders would silently vanish
    /// from the index along with their text and category links. The index may
    /// then hold stale entries until a clean scan runs, which is safer than
    /// losing data.
    func replaceFiles(
        for sourceID: UUID,
        with files: [IndexedFile],
        deletesUnscanned: Bool = true,
        preservesExistingText: Bool = false
    ) throws {
        let database = connection.pointer
        try Self.execute("BEGIN IMMEDIATE TRANSACTION;", on: database)

        do {
            try Self.execute(
                """
                CREATE TEMP TABLE IF NOT EXISTS scanned_file_ids (
                    id TEXT PRIMARY KEY
                );
                DELETE FROM scanned_file_ids;
                """,
                on: database
            )

            let insertStatement = try prepare(
                """
                INSERT INTO files (
                    id, source_id, name, path, extension, file_type, size,
                    created_at, modified_at, indexed_at, text_content
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    source_id = excluded.source_id,
                    name = excluded.name,
                    path = excluded.path,
                    extension = excluded.extension,
                    file_type = excluded.file_type,
                    size = excluded.size,
                    created_at = excluded.created_at,
                    modified_at = excluded.modified_at,
                    indexed_at = excluded.indexed_at,
                    text_content = CASE
                        WHEN ? = 1 THEN files.text_content
                        ELSE excluded.text_content
                    END;
                """
            )
            defer { sqlite3_finalize(insertStatement) }
            let scannedIDStatement = try prepare(
                "INSERT OR IGNORE INTO scanned_file_ids (id) VALUES (?);"
            )
            defer { sqlite3_finalize(scannedIDStatement) }

            for file in files {
                sqlite3_reset(insertStatement)
                sqlite3_clear_bindings(insertStatement)
                try bind(file.id, at: 1, to: insertStatement)
                try bind(file.sourceID.uuidString, at: 2, to: insertStatement)
                try bind(file.name, at: 3, to: insertStatement)
                try bind(file.path, at: 4, to: insertStatement)
                try bind(file.fileExtension, at: 5, to: insertStatement)
                try bind(file.kind.rawValue, at: 6, to: insertStatement)
                try bind(file.size, at: 7, to: insertStatement)
                try bind(file.createdAt?.timeIntervalSince1970, at: 8, to: insertStatement)
                try bind(file.modifiedAt?.timeIntervalSince1970, at: 9, to: insertStatement)
                try bind(file.indexedAt.timeIntervalSince1970, at: 10, to: insertStatement)
                try bind(file.textContent, at: 11, to: insertStatement)
                try bind(preservesExistingText ? 1 : 0, at: 12, to: insertStatement)
                try stepDone(insertStatement)

                sqlite3_reset(scannedIDStatement)
                sqlite3_clear_bindings(scannedIDStatement)
                try bind(file.id, at: 1, to: scannedIDStatement)
                try stepDone(scannedIDStatement)
            }

            // Rebuild FTS rows for exactly the files we just wrote, whether
            // or not unscanned rows survive below.
            let deleteSearchStatement = try prepare(
                """
                DELETE FROM file_search
                WHERE file_id IN (SELECT id FROM scanned_file_ids);
                """
            )
            do {
                defer { sqlite3_finalize(deleteSearchStatement) }
                try stepDone(deleteSearchStatement)
            }

            if deletesUnscanned {
                let deleteStatement = try prepare(
                    """
                    DELETE FROM files
                    WHERE source_id = ?
                      AND id NOT IN (SELECT id FROM scanned_file_ids);
                    """
                )
                do {
                    defer { sqlite3_finalize(deleteStatement) }
                    try bind(sourceID.uuidString, at: 1, to: deleteStatement)
                    try stepDone(deleteStatement)
                }
            }

            let categoryTextByFileID = try categorySearchText(for: sourceID)
            let searchStatement = try prepare(
                """
                INSERT INTO file_search (file_id, name, path, categories, text_content)
                VALUES (?, ?, ?, ?, ?);
                """
            )
            defer { sqlite3_finalize(searchStatement) }

            for file in files {
                sqlite3_reset(searchStatement)
                sqlite3_clear_bindings(searchStatement)
                try bind(file.id, at: 1, to: searchStatement)
                try bind(SearchIndexText.normalized(file.name), at: 2, to: searchStatement)
                try bind(SearchIndexText.normalized(file.path), at: 3, to: searchStatement)
                try bind(
                    SearchIndexText.normalized(categoryTextByFileID[file.id] ?? ""),
                    at: 4,
                    to: searchStatement
                )
                try bind(
                    SearchIndexText.normalized(file.textContent ?? ""),
                    at: 5,
                    to: searchStatement
                )
                try stepDone(searchStatement)
            }

            try Self.execute("COMMIT;", on: database)
        } catch {
            try? Self.execute("ROLLBACK;", on: database)
            throw error
        }
    }

    func reconcileFiles(
        for sourceID: UUID,
        scopes: [FileIndexScope],
        with files: [IndexedFile]
    ) throws {
        guard !scopes.isEmpty else { return }
        guard files.allSatisfy({ $0.sourceID == sourceID }) else {
            throw FileIndexError.database("增量索引包含不匹配的扫描来源")
        }

        try transaction {
            var existingFileIDs: Set<String> = []
            for scope in Set(scopes) {
                let statement: OpaquePointer
                if scope.includesDescendants {
                    statement = try prepare(
                        """
                        SELECT id FROM files
                        WHERE source_id = ?
                          AND (path = ? OR path LIKE ? ESCAPE '\\');
                        """
                    )
                    try bind(sourceID.uuidString, at: 1, to: statement)
                    try bind(scope.path, at: 2, to: statement)
                    let prefix = scope.path.hasSuffix("/") ? scope.path : scope.path + "/"
                    try bind(Self.escapedLikePattern(prefix) + "%", at: 3, to: statement)
                } else {
                    statement = try prepare(
                        "SELECT id FROM files WHERE source_id = ? AND path = ?;"
                    )
                    try bind(sourceID.uuidString, at: 1, to: statement)
                    try bind(scope.path, at: 2, to: statement)
                }
                defer { sqlite3_finalize(statement) }
                while sqlite3_step(statement) == SQLITE_ROW {
                    existingFileIDs.insert(text(statement, column: 0))
                }
            }

            let filesByID = Dictionary(files.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            let incomingFileIDs = Set(filesByID.keys)
            let staleFileIDs = existingFileIDs.subtracting(incomingFileIDs)

            let deleteSearchStatement = try prepare(
                "DELETE FROM file_search WHERE file_id = ?;"
            )
            defer { sqlite3_finalize(deleteSearchStatement) }
            let deleteFileStatement = try prepare(
                "DELETE FROM files WHERE id = ? AND source_id = ?;"
            )
            defer { sqlite3_finalize(deleteFileStatement) }

            for fileID in staleFileIDs {
                sqlite3_reset(deleteSearchStatement)
                sqlite3_clear_bindings(deleteSearchStatement)
                try bind(fileID, at: 1, to: deleteSearchStatement)
                try stepDone(deleteSearchStatement)

                sqlite3_reset(deleteFileStatement)
                sqlite3_clear_bindings(deleteFileStatement)
                try bind(fileID, at: 1, to: deleteFileStatement)
                try bind(sourceID.uuidString, at: 2, to: deleteFileStatement)
                try stepDone(deleteFileStatement)
            }

            let upsertStatement = try prepare(
                """
                INSERT INTO files (
                    id, source_id, name, path, extension, file_type, size,
                    created_at, modified_at, indexed_at, text_content
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    source_id = excluded.source_id,
                    name = excluded.name,
                    path = excluded.path,
                    extension = excluded.extension,
                    file_type = excluded.file_type,
                    size = excluded.size,
                    created_at = excluded.created_at,
                    modified_at = excluded.modified_at,
                    indexed_at = excluded.indexed_at,
                    text_content = CASE
                        WHEN excluded.text_content IS NULL THEN files.text_content
                        ELSE excluded.text_content
                    END;
                """
            )
            defer { sqlite3_finalize(upsertStatement) }

            for file in filesByID.values {
                sqlite3_reset(upsertStatement)
                sqlite3_clear_bindings(upsertStatement)
                try bind(file.id, at: 1, to: upsertStatement)
                try bind(file.sourceID.uuidString, at: 2, to: upsertStatement)
                try bind(file.name, at: 3, to: upsertStatement)
                try bind(file.path, at: 4, to: upsertStatement)
                try bind(file.fileExtension, at: 5, to: upsertStatement)
                try bind(file.kind.rawValue, at: 6, to: upsertStatement)
                try bind(file.size, at: 7, to: upsertStatement)
                try bind(file.createdAt?.timeIntervalSince1970, at: 8, to: upsertStatement)
                try bind(file.modifiedAt?.timeIntervalSince1970, at: 9, to: upsertStatement)
                try bind(file.indexedAt.timeIntervalSince1970, at: 10, to: upsertStatement)
                try bind(file.textContent, at: 11, to: upsertStatement)
                try stepDone(upsertStatement)
                try rebuildSearchEntry(file.id)
            }
        }
    }

    @discardableResult
    func removeMissingFiles(for sourceID: UUID) throws -> Int {
        let selectStatement = try prepare(
            "SELECT id, path FROM files WHERE source_id = ?;"
        )
        defer { sqlite3_finalize(selectStatement) }
        try bind(sourceID.uuidString, at: 1, to: selectStatement)

        var missingFileIDs: [String] = []
        while sqlite3_step(selectStatement) == SQLITE_ROW {
            let fileID = text(selectStatement, column: 0)
            let path = text(selectStatement, column: 1)
            if !FileManager.default.fileExists(atPath: path) {
                missingFileIDs.append(fileID)
            }
        }
        guard !missingFileIDs.isEmpty else { return 0 }

        try transaction {
            let deleteSearchStatement = try prepare(
                "DELETE FROM file_search WHERE file_id = ?;"
            )
            defer { sqlite3_finalize(deleteSearchStatement) }
            let deleteFileStatement = try prepare(
                "DELETE FROM files WHERE id = ? AND source_id = ?;"
            )
            defer { sqlite3_finalize(deleteFileStatement) }

            for fileID in missingFileIDs {
                sqlite3_reset(deleteSearchStatement)
                sqlite3_clear_bindings(deleteSearchStatement)
                try bind(fileID, at: 1, to: deleteSearchStatement)
                try stepDone(deleteSearchStatement)

                sqlite3_reset(deleteFileStatement)
                sqlite3_clear_bindings(deleteFileStatement)
                try bind(fileID, at: 1, to: deleteFileStatement)
                try bind(sourceID.uuidString, at: 2, to: deleteFileStatement)
                try stepDone(deleteFileStatement)
            }
        }
        return missingFileIDs.count
    }

    func fetchFiles() throws -> [IndexedFile] {
        let statement = try prepare(
            """
            SELECT id, source_id, name, path, extension, file_type, size,
                   created_at, modified_at, indexed_at
            FROM files
            ORDER BY modified_at DESC, name COLLATE NOCASE ASC;
            """
        )
        defer { sqlite3_finalize(statement) }

        var files: [IndexedFile] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let sourceID = UUID(uuidString: text(statement, column: 1)),
                  let kind = FileKind(rawValue: text(statement, column: 5)) else {
                continue
            }

            files.append(
                IndexedFile(
                    id: text(statement, column: 0),
                    sourceID: sourceID,
                    name: text(statement, column: 2),
                    path: text(statement, column: 3),
                    fileExtension: text(statement, column: 4),
                    kind: kind,
                    size: sqlite3_column_int64(statement, 6),
                    createdAt: optionalDate(statement, column: 7),
                    modifiedAt: optionalDate(statement, column: 8),
                    indexedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9))
                )
            )
        }
        return files
    }

    func fetchTextContent(forFileID fileID: String) throws -> String? {
        let statement = try prepare(
            "SELECT text_content FROM files WHERE id = ? LIMIT 1;"
        )
        defer { sqlite3_finalize(statement) }
        try bind(fileID, at: 1, to: statement)

        let result = sqlite3_step(statement)
        if result == SQLITE_DONE {
            return nil
        }
        guard result == SQLITE_ROW else {
            throw FileIndexError.database(String(cString: sqlite3_errmsg(connection.pointer)))
        }
        guard sqlite3_column_type(statement, 0) != SQLITE_NULL else {
            return nil
        }
        return text(statement, column: 0)
    }

    func updateTextContents(_ updates: [FileTextContentUpdate]) throws {
        guard !updates.isEmpty else { return }
        try transaction {
            let statement = try prepare(
                "UPDATE files SET text_content = ? WHERE id = ?;"
            )
            defer { sqlite3_finalize(statement) }
            for update in updates {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try bind(update.textContent, at: 1, to: statement)
                try bind(update.fileID, at: 2, to: statement)
                try stepDone(statement)
                try rebuildSearchEntry(update.fileID)
            }
        }
    }

    func clearTextContents() throws {
        try transaction {
            try Self.execute("UPDATE files SET text_content = NULL;", on: connection.pointer)
            // FTS5 applies UPDATE as a bulk delete/insert internally. Updating
            // the derived column in one statement avoids preparing three SQL
            // statements per file, which made opting out of content indexing
            // increasingly slow on large libraries.
            try Self.execute("UPDATE file_search SET text_content = '';", on: connection.pointer)
        }
    }

    func searchFiles(matching query: String, limit: Int = 500) throws -> [IndexedFile] {
        try searchFilesPage(matching: query, limit: limit).files
    }

    /// Single-query FTS lookup for multiple keywords (F13): AI search used to
    /// run one query per keyword (up to 12 round-trips); now they OR together
    /// into one MATCH expression.
    func searchFiles(matchingAnyOf keywords: [String], limit: Int = 500) throws -> [IndexedFile] {
        guard let matchExpression = SearchIndexText.matchExpression(forKeywords: keywords) else {
            return []
        }
        return try searchFilesPage(
            matchExpression: matchExpression,
            limit: limit
        ).files
    }

    func searchFilesPage(
        matching query: String,
        limit: Int = 500,
        offset: Int = 0,
        includesHiddenFiles: Bool = true,
        fetchesTotalCount: Bool = true
    ) throws -> FileSearchPage {
        guard let matchExpression = SearchIndexText.matchExpression(for: query) else {
            return FileSearchPage(files: [], totalCount: 0)
        }
        return try searchFilesPage(
            matchExpression: matchExpression,
            limit: limit,
            offset: offset,
            includesHiddenFiles: includesHiddenFiles,
            fetchesTotalCount: fetchesTotalCount
        )
    }

    func searchFileIDs(
        matching query: String,
        inCategory categoryID: UUID,
        limit: Int
    ) throws -> Set<String> {
        guard let matchExpression = SearchIndexText.matchExpression(for: query) else {
            return []
        }
        let statement = try prepare(
            """
            SELECT file_search.file_id
            FROM file_search
            JOIN file_categories AS fc ON fc.file_id = file_search.file_id
            WHERE file_search MATCH ? AND fc.category_id = ?
            ORDER BY bm25(file_search, 0.0, 8.0, 3.0, 5.0, 1.0) ASC
            LIMIT ?;
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(matchExpression, at: 1, to: statement)
        try bind(categoryID.uuidString, at: 2, to: statement)
        try bind(Int64(max(1, limit)), at: 3, to: statement)

        var result = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            result.insert(text(statement, column: 0))
        }
        return result
    }

    private func searchFilesPage(
        matchExpression: String,
        limit: Int,
        offset: Int = 0,
        includesHiddenFiles: Bool = true,
        fetchesTotalCount: Bool = true
    ) throws -> FileSearchPage {

        let requestedLimit = Int64(max(1, limit))
        let requestedOffset = Int64(max(0, offset))

        let statement = try prepare(
            """
            SELECT f.id, f.source_id, f.name, f.path, f.extension, f.file_type, f.size,
                   f.created_at, f.modified_at, f.indexed_at
            FROM file_search
            JOIN files AS f ON f.id = file_search.file_id
            WHERE file_search MATCH ?
              AND (? = 1 OR f.path NOT GLOB '*/.*')
            ORDER BY bm25(file_search, 0.0, 8.0, 3.0, 5.0, 1.0) ASC,
                     f.modified_at DESC,
                     f.name COLLATE NOCASE ASC
            LIMIT ? OFFSET ?;
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(matchExpression, at: 1, to: statement)
        try bind(includesHiddenFiles ? 1 : 0, at: 2, to: statement)
        try bind(requestedLimit, at: 3, to: statement)
        try bind(requestedOffset, at: 4, to: statement)

        var files: [IndexedFile] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let sourceID = UUID(uuidString: text(statement, column: 1)),
                  let kind = FileKind(rawValue: text(statement, column: 5)) else {
                continue
            }
            files.append(
                IndexedFile(
                    id: text(statement, column: 0),
                    sourceID: sourceID,
                    name: text(statement, column: 2),
                    path: text(statement, column: 3),
                    fileExtension: text(statement, column: 4),
                    kind: kind,
                    size: sqlite3_column_int64(statement, 6),
                    createdAt: optionalDate(statement, column: 7),
                    modifiedAt: optionalDate(statement, column: 8),
                    indexedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9))
                )
            )
        }
        guard fetchesTotalCount else {
            return FileSearchPage(files: files, totalCount: max(0, offset) + files.count)
        }
        let countStatement = try prepare(
            """
            SELECT COUNT(*)
            FROM file_search
            JOIN files AS f ON f.id = file_search.file_id
            WHERE file_search MATCH ?
              AND (? = 1 OR f.path NOT GLOB '*/.*');
            """
        )
        defer { sqlite3_finalize(countStatement) }
        try bind(matchExpression, at: 1, to: countStatement)
        try bind(includesHiddenFiles ? 1 : 0, at: 2, to: countStatement)
        guard sqlite3_step(countStatement) == SQLITE_ROW else {
            throw FileIndexError.database(String(cString: sqlite3_errmsg(connection.pointer)))
        }
        return FileSearchPage(
            files: files,
            totalCount: Int(sqlite3_column_int64(countStatement, 0))
        )
    }

    // MARK: - Saved searches (N07)

    func fetchSavedSearches() throws -> [SavedSearch] {
        let statement = try prepare(
            """
            SELECT id, name, query, min_size, min_date, created_at, file_kind
            FROM saved_searches
            ORDER BY created_at ASC;
            """
        )
        defer { sqlite3_finalize(statement) }

        var searches: [SavedSearch] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = UUID(uuidString: text(statement, column: 0)) else { continue }
            searches.append(
                SavedSearch(
                    id: id,
                    name: text(statement, column: 1),
                    query: text(statement, column: 2),
                    minSizeBytes: sqlite3_column_int64(statement, 3),
                    minDate: optionalDate(statement, column: 4),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                    fileKind: FileKind(rawValue: text(statement, column: 6))
                )
            )
        }
        return searches
    }

    func upsertSavedSearch(_ search: SavedSearch) throws {
        let statement = try prepare(
            """
            INSERT INTO saved_searches (id, name, query, min_size, min_date, created_at, file_kind)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                query = excluded.query,
                min_size = excluded.min_size,
                min_date = excluded.min_date,
                file_kind = excluded.file_kind;
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(search.id.uuidString, at: 1, to: statement)
        try bind(search.name, at: 2, to: statement)
        try bind(search.query, at: 3, to: statement)
        try bind(search.minSizeBytes, at: 4, to: statement)
        try bind(search.minDate?.timeIntervalSince1970, at: 5, to: statement)
        try bind(search.createdAt.timeIntervalSince1970, at: 6, to: statement)
        try bind(search.fileKind?.rawValue, at: 7, to: statement)
        try stepDone(statement)
    }

    func deleteSavedSearch(id: UUID) throws {
        let statement = try prepare("DELETE FROM saved_searches WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, at: 1, to: statement)
        try stepDone(statement)
    }

    func fetchCategories() throws -> [FileCategory] {
        let statement = try prepare(
            """
            SELECT id, name, icon, created_at
            FROM categories
            ORDER BY created_at ASC, name COLLATE NOCASE ASC;
            """
        )
        defer { sqlite3_finalize(statement) }

        var categories: [FileCategory] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = UUID(uuidString: text(statement, column: 0)) else { continue }
            categories.append(
                FileCategory(
                    id: id,
                    name: text(statement, column: 1),
                    symbolName: text(statement, column: 2),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
                )
            )
        }
        return categories
    }

    func createCategory(name: String, symbolName: String) throws -> FileCategory {
        let normalizedName = try validatedCategoryName(name)
        guard try categoryID(named: normalizedName, excluding: nil) == nil else {
            throw FileIndexError.categoryExists
        }

        let category = FileCategory(
            id: UUID(),
            name: normalizedName,
            symbolName: symbolName.isEmpty ? "folder" : symbolName
        )
        let statement = try prepare(
            "INSERT INTO categories (id, name, icon, created_at) VALUES (?, ?, ?, ?);"
        )
        defer { sqlite3_finalize(statement) }

        try bind(category.id.uuidString, at: 1, to: statement)
        try bind(category.name, at: 2, to: statement)
        try bind(category.symbolName, at: 3, to: statement)
        try bind(category.createdAt.timeIntervalSince1970, at: 4, to: statement)
        try stepDone(statement)
        return category
    }

    func renameCategory(_ categoryID: UUID, to name: String) throws {
        let normalizedName = try validatedCategoryName(name)
        guard try self.categoryID(named: normalizedName, excluding: categoryID) == nil else {
            throw FileIndexError.categoryExists
        }

        try transaction {
            let fileIDs = try fileIDs(in: categoryID)
            let statement = try prepare("UPDATE categories SET name = ? WHERE id = ?;")
            defer { sqlite3_finalize(statement) }
            try bind(normalizedName, at: 1, to: statement)
            try bind(categoryID.uuidString, at: 2, to: statement)
            try stepDone(statement)
            try fileIDs.forEach(rebuildSearchEntry)
        }
    }

    func deleteCategory(_ categoryID: UUID) throws {
        try transaction {
            let fileIDs = try fileIDs(in: categoryID)
            let statement = try prepare("DELETE FROM categories WHERE id = ?;")
            defer { sqlite3_finalize(statement) }
            try bind(categoryID.uuidString, at: 1, to: statement)
            try stepDone(statement)
            try fileIDs.forEach(rebuildSearchEntry)
        }
    }

    /// Recreates a category and its file links after an undo. Does not touch
    /// files on disk.
    func restoreCategory(_ category: FileCategory, fileIDs: [String]) throws {
        var normalizedName = try validatedCategoryName(category.name)
        if try categoryID(named: normalizedName, excluding: nil) != nil {
            normalizedName = try uniqueRestoredCategoryName(normalizedName)
        }

        try transaction {
            let statement = try prepare(
                "INSERT INTO categories (id, name, icon, created_at) VALUES (?, ?, ?, ?);"
            )
            defer { sqlite3_finalize(statement) }
            try bind(category.id.uuidString, at: 1, to: statement)
            try bind(normalizedName, at: 2, to: statement)
            try bind(category.symbolName, at: 3, to: statement)
            try bind(category.createdAt.timeIntervalSince1970, at: 4, to: statement)
            try stepDone(statement)

            for fileID in fileIDs {
                let link = try prepare(
                    """
                    INSERT OR IGNORE INTO file_categories (file_id, category_id)
                    VALUES (?, ?);
                    """
                )
                defer { sqlite3_finalize(link) }
                try bind(fileID, at: 1, to: link)
                try bind(category.id.uuidString, at: 2, to: link)
                try stepDone(link)
                try rebuildSearchEntry(fileID)
            }
        }
    }

    func setCategory(_ categoryID: UUID, assigned: Bool, toFile fileID: String) throws {
        try transaction {
            let statement: OpaquePointer
            if assigned {
                statement = try prepare(
                    """
                    INSERT OR IGNORE INTO file_categories (file_id, category_id)
                    VALUES (?, ?);
                    """
                )
            } else {
                statement = try prepare(
                    "DELETE FROM file_categories WHERE file_id = ? AND category_id = ?;"
                )
            }
            defer { sqlite3_finalize(statement) }
            try bind(fileID, at: 1, to: statement)
            try bind(categoryID.uuidString, at: 2, to: statement)
            try stepDone(statement)
            try rebuildSearchEntry(fileID)
        }
    }

    func setCategories(_ changes: [AIClassificationChange], assigned: Bool) throws {
        guard !changes.isEmpty else { return }

        try transaction {
            let statement: OpaquePointer
            if assigned {
                statement = try prepare(
                    """
                    INSERT OR IGNORE INTO file_categories (file_id, category_id)
                    VALUES (?, ?);
                    """
                )
            } else {
                statement = try prepare(
                    "DELETE FROM file_categories WHERE file_id = ? AND category_id = ?;"
                )
            }
            defer { sqlite3_finalize(statement) }

            for change in changes {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try bind(change.fileID, at: 1, to: statement)
                try bind(change.categoryID.uuidString, at: 2, to: statement)
                try stepDone(statement)
            }

            for fileID in Set(changes.map(\.fileID)) {
                try rebuildSearchEntry(fileID)
            }
        }
    }

    func fetchCategoryIDs(forFile fileID: String) throws -> Set<UUID> {
        let statement = try prepare(
            "SELECT category_id FROM file_categories WHERE file_id = ?;"
        )
        defer { sqlite3_finalize(statement) }
        try bind(fileID, at: 1, to: statement)

        var categoryIDs = Set<UUID>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let categoryID = UUID(uuidString: text(statement, column: 0)) {
                categoryIDs.insert(categoryID)
            }
        }
        return categoryIDs
    }

    /// Atomically replaces an indexed source file with its moved destination while preserving
    /// the category snapshot captured before the physical move. A failed upsert or category
    /// assignment rolls the whole index mutation back, leaving the old relationship recoverable.
    func reconcileMovedFile(
        fromFile sourceFileID: String,
        to destinationFile: IndexedFile,
        preserving categoryIDs: Set<UUID>
    ) throws {
        try transaction {
            let upsertStatement = try prepare(
                """
                INSERT INTO files (
                    id, source_id, name, path, extension, file_type, size,
                    created_at, modified_at, indexed_at, text_content
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    source_id = excluded.source_id,
                    name = excluded.name,
                    path = excluded.path,
                    extension = excluded.extension,
                    file_type = excluded.file_type,
                    size = excluded.size,
                    created_at = excluded.created_at,
                    modified_at = excluded.modified_at,
                    indexed_at = excluded.indexed_at,
                    text_content = CASE
                        WHEN excluded.text_content IS NULL THEN files.text_content
                        ELSE excluded.text_content
                    END;
                """
            )
            defer { sqlite3_finalize(upsertStatement) }
            try bind(destinationFile.id, at: 1, to: upsertStatement)
            try bind(destinationFile.sourceID.uuidString, at: 2, to: upsertStatement)
            try bind(destinationFile.name, at: 3, to: upsertStatement)
            try bind(destinationFile.path, at: 4, to: upsertStatement)
            try bind(destinationFile.fileExtension, at: 5, to: upsertStatement)
            try bind(destinationFile.kind.rawValue, at: 6, to: upsertStatement)
            try bind(destinationFile.size, at: 7, to: upsertStatement)
            try bind(destinationFile.createdAt?.timeIntervalSince1970, at: 8, to: upsertStatement)
            try bind(destinationFile.modifiedAt?.timeIntervalSince1970, at: 9, to: upsertStatement)
            try bind(destinationFile.indexedAt.timeIntervalSince1970, at: 10, to: upsertStatement)
            try bind(destinationFile.textContent, at: 11, to: upsertStatement)
            try stepDone(upsertStatement)

            let insertStatement = try prepare(
                """
                INSERT OR IGNORE INTO file_categories (file_id, category_id)
                VALUES (?, ?);
                """
            )
            defer { sqlite3_finalize(insertStatement) }
            for categoryID in categoryIDs {
                sqlite3_reset(insertStatement)
                sqlite3_clear_bindings(insertStatement)
                try bind(destinationFile.id, at: 1, to: insertStatement)
                try bind(categoryID.uuidString, at: 2, to: insertStatement)
                try stepDone(insertStatement)
            }

            if sourceFileID != destinationFile.id {
                let deleteSearchStatement = try prepare(
                    "DELETE FROM file_search WHERE file_id = ?;"
                )
                do {
                    defer { sqlite3_finalize(deleteSearchStatement) }
                    try bind(sourceFileID, at: 1, to: deleteSearchStatement)
                    try stepDone(deleteSearchStatement)
                }

                let deleteFileStatement = try prepare("DELETE FROM files WHERE id = ?;")
                defer { sqlite3_finalize(deleteFileStatement) }
                try bind(sourceFileID, at: 1, to: deleteFileStatement)
                try stepDone(deleteFileStatement)
            }

            try rebuildSearchEntry(destinationFile.id)
        }
    }

    func fetchFileCategoryLinks() throws -> [String: Set<UUID>] {
        let statement = try prepare(
            "SELECT file_id, category_id FROM file_categories;"
        )
        defer { sqlite3_finalize(statement) }

        var links: [String: Set<UUID>] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let fileID = text(statement, column: 0)
            guard let categoryID = UUID(uuidString: text(statement, column: 1)) else { continue }
            links[fileID, default: []].insert(categoryID)
        }
        return links
    }

    /// Rebuilds the full-text table from the `files` rows and compacts the
    /// database.
    ///
    /// Non-destructive on purpose: `file_categories` cascades on `files`, so
    /// clearing `files` would silently discard the user's manual
    /// categorisation. Only the derived search rows are regenerated, which is
    /// what actually goes wrong when search returns stale or missing hits.
    ///
    /// Returns the number of rows reindexed.
    @discardableResult
    func rebuildSearchIndex() throws -> Int {
        var reindexed = 0
        try transaction {
            try Self.execute("DELETE FROM file_search;", on: connection.pointer)

            let categoryText = try allCategorySearchText()
            let selectStatement = try prepare(
                "SELECT id, name, path, text_content FROM files;"
            )
            defer { sqlite3_finalize(selectStatement) }

            let insertStatement = try prepare(
                """
                INSERT INTO file_search (file_id, name, path, categories, text_content)
                VALUES (?, ?, ?, ?, ?);
                """
            )
            defer { sqlite3_finalize(insertStatement) }

            while sqlite3_step(selectStatement) == SQLITE_ROW {
                let fileID = text(selectStatement, column: 0)
                sqlite3_reset(insertStatement)
                sqlite3_clear_bindings(insertStatement)
                try bind(fileID, at: 1, to: insertStatement)
                try bind(
                    SearchIndexText.normalized(text(selectStatement, column: 1)),
                    at: 2,
                    to: insertStatement
                )
                try bind(
                    SearchIndexText.normalized(text(selectStatement, column: 2)),
                    at: 3,
                    to: insertStatement
                )
                try bind(
                    SearchIndexText.normalized(categoryText[fileID] ?? ""),
                    at: 4,
                    to: insertStatement
                )
                try bind(
                    SearchIndexText.normalized(text(selectStatement, column: 3)),
                    at: 5,
                    to: insertStatement
                )
                try stepDone(insertStatement)
                reindexed += 1
            }
        }

        // Outside the transaction: SQLite refuses to VACUUM inside one.
        try Self.execute("VACUUM;", on: connection.pointer)
        return reindexed
    }

    private func allCategorySearchText() throws -> [String: String] {
        let statement = try prepare(
            """
            SELECT fc.file_id, GROUP_CONCAT(c.name, ' ')
            FROM file_categories AS fc
            JOIN categories AS c ON c.id = fc.category_id
            GROUP BY fc.file_id;
            """
        )
        defer { sqlite3_finalize(statement) }

        var result: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            result[text(statement, column: 0)] = text(statement, column: 1)
        }
        return result
    }

    private func categorySearchText(for sourceID: UUID) throws -> [String: String] {
        let statement = try prepare(
            """
            SELECT fc.file_id, GROUP_CONCAT(c.name, ' ')
            FROM file_categories AS fc
            JOIN categories AS c ON c.id = fc.category_id
            JOIN files AS f ON f.id = fc.file_id
            WHERE f.source_id = ?
            GROUP BY fc.file_id;
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(sourceID.uuidString, at: 1, to: statement)

        var result: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            result[text(statement, column: 0)] = text(statement, column: 1)
        }
        return result
    }

    private func fileIDs(in categoryID: UUID) throws -> [String] {
        let statement = try prepare(
            "SELECT file_id FROM file_categories WHERE category_id = ?;"
        )
        defer { sqlite3_finalize(statement) }
        try bind(categoryID.uuidString, at: 1, to: statement)

        var fileIDs: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            fileIDs.append(text(statement, column: 0))
        }
        return fileIDs
    }

    private func rebuildSearchEntry(_ fileID: String) throws {
        let deleteStatement = try prepare("DELETE FROM file_search WHERE file_id = ?;")
        do {
            defer { sqlite3_finalize(deleteStatement) }
            try bind(fileID, at: 1, to: deleteStatement)
            try stepDone(deleteStatement)
        }

        let selectStatement = try prepare(
            """
            SELECT f.name, f.path, COALESCE(f.text_content, ''),
                   COALESCE(GROUP_CONCAT(c.name, ' '), '')
            FROM files AS f
            LEFT JOIN file_categories AS fc ON fc.file_id = f.id
            LEFT JOIN categories AS c ON c.id = fc.category_id
            WHERE f.id = ?
            GROUP BY f.id;
            """
        )
        defer { sqlite3_finalize(selectStatement) }
        try bind(fileID, at: 1, to: selectStatement)
        guard sqlite3_step(selectStatement) == SQLITE_ROW else { return }

        let insertStatement = try prepare(
            """
            INSERT INTO file_search (file_id, name, path, categories, text_content)
            VALUES (?, ?, ?, ?, ?);
            """
        )
        defer { sqlite3_finalize(insertStatement) }
        try bind(fileID, at: 1, to: insertStatement)
        try bind(SearchIndexText.normalized(text(selectStatement, column: 0)), at: 2, to: insertStatement)
        try bind(SearchIndexText.normalized(text(selectStatement, column: 1)), at: 3, to: insertStatement)
        try bind(SearchIndexText.normalized(text(selectStatement, column: 3)), at: 4, to: insertStatement)
        try bind(SearchIndexText.normalized(text(selectStatement, column: 2)), at: 5, to: insertStatement)
        try stepDone(insertStatement)
    }

    private func transaction(_ work: () throws -> Void) throws {
        let database = connection.pointer
        try Self.execute("BEGIN IMMEDIATE TRANSACTION;", on: database)
        do {
            try work()
            try Self.execute("COMMIT;", on: database)
        } catch {
            try? Self.execute("ROLLBACK;", on: database)
            throw error
        }
    }

    private func uniqueRestoredCategoryName(_ name: String) throws -> String {
        func candidate(suffix: String) throws -> String {
            if name.count + suffix.count <= 80 {
                return try validatedCategoryName(name + suffix)
            }
            let trimmed = String(name.prefix(max(1, 80 - suffix.count)))
            return try validatedCategoryName(trimmed + suffix)
        }

        var restored = try candidate(
            suffix: AppLanguage.localized(" (已恢复)", english: " (Restored)")
        )
        var index = 2
        while try categoryID(named: restored, excluding: nil) != nil {
            restored = try candidate(
                suffix: AppLanguage.localized(" (已恢复 \(index))", english: " (Restored \(index))")
            )
            index += 1
        }
        return restored
    }

    private func validatedCategoryName(_ name: String) throws -> String {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty, normalizedName.count <= 80 else {
            throw FileIndexError.invalidCategoryName
        }
        return normalizedName
    }

    private func categoryID(named name: String, excluding excludedID: UUID?) throws -> UUID? {
        let statement = try prepare(
            "SELECT id FROM categories WHERE name = ? COLLATE NOCASE LIMIT 1;"
        )
        defer { sqlite3_finalize(statement) }
        try bind(name, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let categoryID = UUID(uuidString: text(statement, column: 0)),
              categoryID != excludedID else {
            return nil
        }
        return categoryID
    }

    private func source(withPath path: String) throws -> FileSource? {
        let statement = try prepare(
            """
            SELECT id, display_name, path, bookmark, enabled, created_at
            FROM sources WHERE path = ? LIMIT 1;
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(path, at: 1, to: statement)

        guard sqlite3_step(statement) == SQLITE_ROW,
              let id = UUID(uuidString: text(statement, column: 0)) else {
            return nil
        }

        return FileSource(
            id: id,
            displayName: text(statement, column: 1),
            path: text(statement, column: 2),
            bookmark: blob(statement, column: 3),
            enabled: sqlite3_column_int(statement, 4) == 1,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
        )
    }

    private static func migrate(_ database: OpaquePointer) throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS sources (
                id TEXT PRIMARY KEY,
                display_name TEXT NOT NULL,
                path TEXT NOT NULL UNIQUE,
                bookmark BLOB NOT NULL,
                enabled INTEGER NOT NULL DEFAULT 1,
                created_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS files (
                id TEXT PRIMARY KEY,
                source_id TEXT NOT NULL,
                name TEXT NOT NULL,
                path TEXT NOT NULL,
                extension TEXT NOT NULL,
                file_type TEXT NOT NULL,
                size INTEGER NOT NULL,
                created_at REAL,
                modified_at REAL,
                indexed_at REAL NOT NULL,
                FOREIGN KEY (source_id) REFERENCES sources(id) ON DELETE CASCADE
            );

            CREATE INDEX IF NOT EXISTS files_source_id_idx ON files(source_id);
            CREATE INDEX IF NOT EXISTS files_modified_at_idx ON files(modified_at DESC);
            CREATE INDEX IF NOT EXISTS files_path_idx ON files(path);

            CREATE TABLE IF NOT EXISTS categories (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL COLLATE NOCASE UNIQUE,
                icon TEXT NOT NULL,
                created_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS file_categories (
                file_id TEXT NOT NULL,
                category_id TEXT NOT NULL,
                PRIMARY KEY (file_id, category_id),
                FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE,
                FOREIGN KEY (category_id) REFERENCES categories(id) ON DELETE CASCADE
            );

            CREATE INDEX IF NOT EXISTS file_categories_category_idx
            ON file_categories(category_id);
            """,
            on: database
        )

        if try userVersion(database) < 2 {
            // F24: FileCategory.defaults is the single source of truth; the
            // migration no longer hard-codes its own copy of the list.
            let valueRows = FileCategory.defaults.enumerated().map { index, category in
                "('\(category.id.uuidString)', '\(category.name)', '\(category.symbolName)', \(index + 1))"
            }.joined(separator: ",\n    ")
            try execute(
                """
                INSERT OR IGNORE INTO categories (id, name, icon, created_at) VALUES
                \(valueRows);
                PRAGMA user_version = 2;
                """,
                on: database
            )
        }

        if try userVersion(database) < 3 {
            try execute(
                """
                BEGIN IMMEDIATE TRANSACTION;
                ALTER TABLE files ADD COLUMN text_content TEXT;

                CREATE VIRTUAL TABLE file_search USING fts5(
                    file_id UNINDEXED,
                    name,
                    path,
                    categories,
                    text_content,
                    tokenize = 'unicode61 remove_diacritics 2'
                );

                INSERT INTO file_search (file_id, name, path, categories, text_content)
                SELECT f.id, f.name, f.path,
                       COALESCE(GROUP_CONCAT(c.name, ' '), ''),
                       COALESCE(f.text_content, '')
                FROM files AS f
                LEFT JOIN file_categories AS fc ON fc.file_id = f.id
                LEFT JOIN categories AS c ON c.id = fc.category_id
                GROUP BY f.id;

                PRAGMA user_version = 3;
                COMMIT;
                """,
                on: database
            )
        }

        if try userVersion(database) < 4 {
            try execute(
                """
                CREATE TABLE IF NOT EXISTS saved_searches (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    query TEXT NOT NULL,
                    min_size INTEGER NOT NULL DEFAULT 0,
                    min_date REAL,
                    created_at REAL NOT NULL
                );
                PRAGMA user_version = 4;
                """,
                on: database
            )
        }

        if try userVersion(database) < 5 {
            try execute(
                """
                ALTER TABLE saved_searches ADD COLUMN file_kind TEXT;
                PRAGMA user_version = 5;
                """,
                on: database
            )
        }
    }

    private static func userVersion(_ database: OpaquePointer) throws -> Int32 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw FileIndexError.database(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw FileIndexError.database(String(cString: sqlite3_errmsg(database)))
        }
        return sqlite3_column_int(statement, 0)
    }

    private static func execute(_ sql: String, on database: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw FileIndexError.database(message)
        }
    }

    private static func escapedLikePattern(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func restrictDatabaseFiles(at databaseURL: URL) throws {
        for url in [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm")
        ] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        let database = connection.pointer
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw FileIndexError.database(String(cString: sqlite3_errmsg(database)))
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            let message = String(cString: sqlite3_errmsg(connection.pointer))
            throw FileIndexError.database(message)
        }
    }

    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer) throws {
        guard sqlite3_bind_text(statement, index, value, -1, Self.transientDestructor) == SQLITE_OK else {
            throw FileIndexError.database("无法绑定文本参数")
        }
    }

    private func bind(_ value: String?, at index: Int32, to statement: OpaquePointer) throws {
        if let value {
            try bind(value, at: index, to: statement)
        } else if sqlite3_bind_null(statement, index) != SQLITE_OK {
            throw FileIndexError.database("无法绑定文本参数")
        }
    }

    private func bind(_ value: Data, at index: Int32, to statement: OpaquePointer) throws {
        let result = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(
                statement,
                index,
                bytes.baseAddress,
                Int32(value.count),
                Self.transientDestructor
            )
        }
        guard result == SQLITE_OK else {
            throw FileIndexError.database("无法绑定权限数据")
        }
    }

    private func bind(_ value: Int, at index: Int32, to statement: OpaquePointer) throws {
        guard sqlite3_bind_int(statement, index, Int32(value)) == SQLITE_OK else {
            throw FileIndexError.database("无法绑定整数参数")
        }
    }

    private func bind(_ value: Int64, at index: Int32, to statement: OpaquePointer) throws {
        guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else {
            throw FileIndexError.database("无法绑定整数参数")
        }
    }

    private func bind(_ value: Double?, at index: Int32, to statement: OpaquePointer) throws {
        let result: Int32
        if let value {
            result = sqlite3_bind_double(statement, index, value)
        } else {
            result = sqlite3_bind_null(statement, index)
        }
        guard result == SQLITE_OK else {
            throw FileIndexError.database("无法绑定时间参数")
        }
    }

    private func text(_ statement: OpaquePointer, column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    private func blob(_ statement: OpaquePointer, column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    private func optionalDate(_ statement: OpaquePointer, column: Int32) -> Date? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
    }

    private static var transientDestructor: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }
}

private final class SQLiteConnection: @unchecked Sendable {
    let pointer: OpaquePointer

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        sqlite3_close(pointer)
    }
}
