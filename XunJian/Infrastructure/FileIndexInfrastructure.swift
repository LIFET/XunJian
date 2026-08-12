import Foundation
import SQLite3
import UniformTypeIdentifiers

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
        textContent: String? = nil
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

enum FileIndexPreferences {
    static let includesHiddenFilesKey = "fileIndex.includesDotPrefixedFiles"
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

    var errorDescription: String? {
        switch self {
        case let .database(message):
            "无法访问本地文件索引：\(message)"
        case .bookmarkCreation:
            "无法保存这个文件夹的访问权限，请重新选择。"
        case .bookmarkResolution:
            "macOS 已取消这个文件夹的访问权限，请重新授权。"
        case let .unreadableFolder(name):
            "无法读取文件夹“\(name)”，请检查它是否存在以及当前权限。"
        case let .overlappingSource(existingName):
            AppLanguage.localized(
                "无法添加这个文件夹，因为它与已授权文件夹“\(existingName)”重叠。请选择现有索引范围之外的文件夹。",
                english: "Cannot add this folder because it overlaps the authorized folder \(existingName). Choose a folder outside the existing indexed folders."
            )
        case .invalidCategoryName:
            "分类名称不能为空，且最多使用 80 个字符。"
        case .categoryExists:
            "已经存在同名分类，请换一个名称。"
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
    private let textExtractor: TextExtractionService
    private let resourceValuesLoader: ResourceValuesLoader
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
        self.excludedDirectoryNames = [
            ".git", "node_modules", "deriveddata", "caches", ".cache",
            ".trash", "tmp", "temp"
        ]
    }

    func scan(
        sourceID: UUID,
        rootURL: URL,
        includesHiddenFiles: Bool = false,
        progress: ProgressHandler? = nil
    ) async throws -> [IndexedFile] {
        try enumerate(
            sourceID: sourceID,
            rootURL: rootURL,
            includesHiddenFiles: includesHiddenFiles,
            progress: progress
        )
    }

    func scanChanges(
        sourceID: UUID,
        rootURL: URL,
        events: [FileSystemChangeEvent],
        includesHiddenFiles: Bool = false
    ) async throws -> IncrementalScanSnapshot {
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

            if scope.includesDescendants || isDirectory.boolValue {
                let scannedFiles: [IndexedFile]
                do {
                    scannedFiles = try enumerate(
                        sourceID: sourceID,
                        rootURL: url,
                        includesHiddenFiles: includesHiddenFiles,
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
                        indexedAt: indexedAt
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
        progress: ProgressHandler?
    ) throws -> [IndexedFile] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              fileManager.isReadableFile(atPath: rootURL.path) else {
            throw FileIndexError.unreadableFolder(rootURL.lastPathComponent)
        }

        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Self.resourceKeys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, error in
                enumerationError = error
                return false
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
                throw FileIndexError.unreadableFolder(rootURL.lastPathComponent)
            }

            if values.isDirectory == true {
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
                indexedAt: indexedAt
            ) else { continue }
            files.append(file)

            if files.count.isMultiple(of: 100) {
                progress?(
                    ScanProgress(discoveredCount: files.count, currentPath: fileURL.path)
                )
            }
        }

        if enumerationError != nil {
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
        excludedDirectoryNames.contains(name.lowercased())
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
        indexedAt: Date
    ) -> IndexedFile? {
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            return nil
        }

        let name = values.name ?? fileURL.lastPathComponent
        let fileExtension = fileURL.pathExtension.lowercased()
        let resourceIdentifier: String
        if let identifier = values.fileResourceIdentifier {
            resourceIdentifier = String(describing: identifier)
        } else if let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
                  let device = attributes[.systemNumber] as? NSNumber,
                  let inode = attributes[.systemFileNumber] as? NSNumber {
            resourceIdentifier = "inode:\(device):\(inode)"
        } else {
            resourceIdentifier = "path:\(canonicalPath(fileURL.path))"
        }
        let volumeIdentifier = values.volumeIdentifier
            .map { String(describing: $0) } ?? "volume"

        return IndexedFile(
            id: "\(sourceID.uuidString):\(volumeIdentifier):\(resourceIdentifier)",
            sourceID: sourceID,
            name: name,
            path: fileURL.path,
            fileExtension: fileExtension,
            kind: Self.fileKind(contentType: values.contentType, fileExtension: fileExtension),
            size: Int64(values.fileSize ?? 0),
            createdAt: values.creationDate,
            modifiedAt: values.contentModificationDate,
            indexedAt: indexedAt,
            textContent: textExtractor.extractText(from: fileURL)
        )
    }

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
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

    func replaceFiles(for sourceID: UUID, with files: [IndexedFile]) throws {
        let database = connection.pointer
        try Self.execute("BEGIN IMMEDIATE TRANSACTION;", on: database)

        do {
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
                    text_content = excluded.text_content;
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
                try stepDone(insertStatement)

                sqlite3_reset(scannedIDStatement)
                sqlite3_clear_bindings(scannedIDStatement)
                try bind(file.id, at: 1, to: scannedIDStatement)
                try stepDone(scannedIDStatement)
            }

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
                    text_content = excluded.text_content;
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

    func searchFiles(matching query: String, limit: Int = 500) throws -> [IndexedFile] {
        try searchFilesPage(matching: query, limit: limit).files
    }

    func searchFilesPage(
        matching query: String,
        limit: Int = 500,
        includesHiddenFiles: Bool = true
    ) throws -> FileSearchPage {
        guard let matchExpression = SearchIndexText.matchExpression(for: query) else {
            return FileSearchPage(files: [], totalCount: 0)
        }

        let requestedLimit = Int64(max(1, limit))

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
            LIMIT ?;
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(matchExpression, at: 1, to: statement)
        try bind(includesHiddenFiles ? 1 : 0, at: 2, to: statement)
        try bind(requestedLimit, at: 3, to: statement)

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
                    text_content = excluded.text_content;
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
            try execute(
                """
                INSERT OR IGNORE INTO categories (id, name, icon, created_at) VALUES
                    ('B2D19E64-0184-4B30-9364-0C05DD2A2A01', '工作', 'briefcase', 1),
                    ('B2D19E64-0184-4B30-9364-0C05DD2A2A02', '项目', 'folder', 2),
                    ('B2D19E64-0184-4B30-9364-0C05DD2A2A03', '设计', 'paintbrush', 3),
                    ('B2D19E64-0184-4B30-9364-0C05DD2A2A04', '资料', 'books.vertical', 4),
                    ('B2D19E64-0184-4B30-9364-0C05DD2A2A05', '合同', 'doc.text', 5),
                    ('B2D19E64-0184-4B30-9364-0C05DD2A2A06', '财务', 'banknote', 6),
                    ('B2D19E64-0184-4B30-9364-0C05DD2A2A07', '个人', 'person', 7),
                    ('B2D19E64-0184-4B30-9364-0C05DD2A2A08', '归档', 'archivebox', 8);
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
