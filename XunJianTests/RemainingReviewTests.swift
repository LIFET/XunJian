import XCTest
@testable import XunJian

final class RemainingReviewTests: XCTestCase {
    func testCSVFieldsNeutralizeSpreadsheetFormulas() {
        XCTAssertEqual(FileListExport.csvField("=1+1"), "'=1+1")
        XCTAssertEqual(FileListExport.csvField("+SUM(A1:A2)"), "'+SUM(A1:A2)")
        XCTAssertEqual(FileListExport.csvField("@command"), "'@command")
        XCTAssertEqual(FileListExport.csvField("  =1+1"), "'  =1+1")
        XCTAssertEqual(FileListExport.csvField("normal.txt"), "normal.txt")
    }

    func testStreamingCSVExportMatchesInMemoryContractAndReplacesDestination() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xunjian-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("files.csv")
        try Data("stale".utf8).write(to: destination)
        let files = [
            makeFile(name: "=formula.pdf", path: "/docs/=formula.pdf", size: 42),
            makeFile(name: "report.pdf", path: "/docs/report.pdf", size: 84)
        ]
        let categoryNames = [files[0].id: ["Finance"], files[1].id: ["Work"]]

        try FileListExport.write(
            files: files,
            format: .csv,
            categoryNames: categoryNames,
            to: destination
        )

        let exported = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertEqual(
            exported,
            FileListExport.contents(
                for: files,
                format: .csv,
                categoryNames: categoryNames
            )
        )
        XCTAssertTrue(exported.contains("'=formula.pdf"))
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .allSatisfy { !$0.hasPrefix(".xunjian-export-") }
        )
    }

    func testStorageInsightsKeepsOnlyCorrectTopTenFiles() {
        let sourceID = UUID()
        let files = (0..<25).map { index in
            IndexedFile(
                id: "file-\(index)",
                sourceID: sourceID,
                name: "file-\(index).pdf",
                path: "/docs/file-\(index).pdf",
                fileExtension: "pdf",
                kind: .document,
                size: Int64(index),
                createdAt: nil,
                modifiedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                indexedAt: Date()
            )
        }

        let snapshot = StorageInsightsSnapshot.make(files: files, sources: [])

        XCTAssertEqual(snapshot.largestFiles.map(\.size), Array((15..<25).reversed()).map(Int64.init))
        XCTAssertEqual(snapshot.oldestFiles.map(\.id), (0..<10).map { "file-\($0)" })
    }

    func testDuplicateHashReadsTheCompleteFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xunjian-duplicate-hash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sample.txt")
        try Data("abc".utf8).write(to: file)

        let digest = try await DuplicateFileFinder.hash(fileAt: file)
        XCTAssertEqual(
            digest,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testQuickSearchMatchesNameAndPath() {
        let file = makeFile(
            name: "invoice.pdf",
            path: "/Users/me/Documents/Finance/invoice.pdf"
        )

        XCTAssertTrue(QuickSearchMatching.matches(file: file, query: "invoice"))
        XCTAssertTrue(QuickSearchMatching.matches(file: file, query: "Finance"))
        XCTAssertTrue(QuickSearchMatching.matches(file: file, query: "DOCUMENTS"))
        XCTAssertFalse(QuickSearchMatching.matches(file: file, query: "taxes"))
    }

    func testQuickSearchReportsPathOnlyHits() {
        let file = makeFile(
            name: "invoice.pdf",
            path: "/Users/me/Documents/Finance/invoice.pdf"
        )

        XCTAssertTrue(QuickSearchMatching.matchedPathOnly(file: file, query: "Finance"))
        XCTAssertFalse(QuickSearchMatching.matchedPathOnly(file: file, query: "invoice"))
        XCTAssertFalse(QuickSearchMatching.matchedPathOnly(file: file, query: "taxes"))
    }

    func testSavedSearchSummaryIncludesQuerySizeAndDate() {
        let search = SavedSearch(
            id: UUID(),
            name: "Contracts",
            query: "合同",
            minSizeBytes: 10 * 1_024 * 1_024,
            minDate: Date(timeIntervalSince1970: 1_700_000_000),
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let english = search.conditionSummary(usesEnglish: true)
        XCTAssertTrue(english.contains("合同"))
        XCTAssertTrue(english.contains("10"))
        XCTAssertFalse(english.isEmpty)

        let chinese = search.conditionSummary(usesEnglish: false)
        XCTAssertTrue(chinese.contains("合同"))
        XCTAssertTrue(chinese.contains("10"))
    }

    func testSavedSearchSummaryForUnconstrainedSearch() {
        let search = SavedSearch(
            id: UUID(),
            name: "Everything",
            query: "  ",
            minSizeBytes: 0,
            minDate: nil,
            createdAt: Date()
        )

        XCTAssertEqual(search.conditionSummary(usesEnglish: true), "Any name")
        XCTAssertEqual(search.conditionSummary(usesEnglish: false), "不限名称")
    }

    func testDuplicateCleanupKeepsTheNewestFile() {
        let older = makeFile(name: "a.pdf", path: "/a.pdf", modifiedAt: Date(timeIntervalSince1970: 1))
        let newest = makeFile(name: "b.pdf", path: "/b.pdf", modifiedAt: Date(timeIntervalSince1970: 9))
        let middle = makeFile(name: "c.pdf", path: "/c.pdf", modifiedAt: Date(timeIntervalSince1970: 5))

        XCTAssertEqual(DuplicateCleanup.fileToKeep(in: [older, newest, middle])?.id, newest.id)
        XCTAssertEqual(
            DuplicateCleanup.filesToTrash(keepingNewestIn: [older, newest, middle]).map(\.id),
            [older.id, middle.id]
        )
    }

    func testDuplicateCleanupFallsBackToPathWhenDatesMatch() {
        let date = Date(timeIntervalSince1970: 42)
        let left = makeFile(name: "copy.pdf", path: "/z/copy.pdf", modifiedAt: date)
        let right = makeFile(name: "copy.pdf", path: "/a/copy.pdf", modifiedAt: date)

        XCTAssertEqual(DuplicateCleanup.fileToKeep(in: [left, right])?.path, "/a/copy.pdf")
        XCTAssertEqual(DuplicateCleanup.filesToTrash(keepingNewestIn: [left, right]).map(\.path), ["/z/copy.pdf"])
    }

    func testFileTableKeepsReadableCanvasAtNarrowWidths() {
        XCTAssertEqual(FileTableLayout.minimumWidth(contentWidth: 360), 640)
        XCTAssertEqual(FileTableLayout.minimumWidth(contentWidth: 640), 640)
        XCTAssertEqual(FileTableLayout.minimumWidth(contentWidth: 1_000), 1_000)
        XCTAssertTrue(FileTableLayout.needsHorizontalScroll(contentWidth: 360))
        XCTAssertFalse(FileTableLayout.needsHorizontalScroll(contentWidth: 640))
        XCTAssertFalse(FileTableLayout.needsHorizontalScroll(contentWidth: 1_000))
    }

    func testSavedSearchMatchesCurrentFilters() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let search = SavedSearch(
            id: UUID(),
            name: "Contracts",
            query: "合同",
            minSizeBytes: 10 * 1_024 * 1_024,
            minDate: date,
            createdAt: Date()
        )

        XCTAssertTrue(search.matches(
            query: " 合同 ",
            minSizeBytes: 10 * 1_024 * 1_024,
            minDate: date
        ))
        XCTAssertFalse(search.matches(
            query: "合同",
            minSizeBytes: 0,
            minDate: date
        ))
        XCTAssertFalse(search.matches(
            query: "发票",
            minSizeBytes: 10 * 1_024 * 1_024,
            minDate: date
        ))
        XCTAssertFalse(search.matches(
            query: "合同",
            minSizeBytes: 10 * 1_024 * 1_024,
            minDate: nil
        ))
        XCTAssertTrue(search.matches(
            query: "合同",
            minSizeBytes: 10 * 1_024 * 1_024,
            minDate: date,
            fileKind: nil
        ))
        XCTAssertFalse(search.matches(
            query: "合同",
            minSizeBytes: 10 * 1_024 * 1_024,
            minDate: date,
            fileKind: .document
        ))
    }

    func testSavedSearchIncludesKindInCurrentMatch() {
        let search = SavedSearch(
            id: UUID(),
            name: "PDFs",
            query: "合同",
            minSizeBytes: 0,
            minDate: nil,
            createdAt: Date(),
            fileKind: .document
        )
        XCTAssertTrue(search.matches(query: "合同", minSizeBytes: 0, minDate: nil, fileKind: .document))
        XCTAssertFalse(search.matches(query: "合同", minSizeBytes: 0, minDate: nil, fileKind: nil))
        XCTAssertTrue(search.conditionSummary(usesEnglish: false).contains("文档"))
        XCTAssertTrue(search.conditionSummary(usesEnglish: true).contains("Document"))
    }

    func testQuickSearchPrefixCountsRemainingMatches() {
        let files = [
            makeFile(name: "a.pdf", path: "/docs/a.pdf"),
            makeFile(name: "b.pdf", path: "/docs/b.pdf"),
            makeFile(name: "notes.txt", path: "/docs/notes.txt"),
            makeFile(name: "c.pdf", path: "/other/c.pdf")
        ]
        let result = QuickSearchMatching.prefixMatches(
            in: files,
            query: "pdf",
            limit: 2
        )
        XCTAssertEqual(result.files.map(\.name), ["a.pdf", "b.pdf"])
        XCTAssertEqual(result.remainingCount, 1)
    }

    func testDuplicateFindSkipsUnreadablePackagesWithoutFailing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xunjian-dup-skip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let left = root.appendingPathComponent("a.txt")
        let right = root.appendingPathComponent("b.txt")
        let package = root.appendingPathComponent("pack.pages", isDirectory: true)
        try Data("abc".utf8).write(to: left)
        try Data("abc".utf8).write(to: right)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        try Data("internal".utf8).write(to: package.appendingPathComponent("index.xml"))

        let files = [
            makeFile(name: "a.txt", path: left.path, size: 3),
            makeFile(name: "b.txt", path: right.path, size: 3),
            makeFile(name: "pack.pages", path: package.path, size: 3)
        ]
        let result = try await DuplicateFileFinder.find(in: files)
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(Set(result.groups[0].files.map(\.name)), ["a.txt", "b.txt"])
        XCTAssertEqual(result.unreadCount, 1)
    }

    func testDocumentPackageIsIndexedAsOneFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xunjian-package-\(UUID().uuidString)", isDirectory: true)
        let package = root.appendingPathComponent("Report.pages", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("internal".utf8).write(to: package.appendingPathComponent("index.xml"))
        defer { try? FileManager.default.removeItem(at: root) }

        let files = try await FileScanner().scan(sourceID: UUID(), rootURL: root)

        XCTAssertEqual(files.map(\.name), ["Report.pages"])
        XCTAssertEqual(files.first?.kind, .document)
    }

    func testDestructiveOperationRejectsFileReplacedAtIndexedPath() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xunjian-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("report.txt")
        try Data("first".utf8).write(to: url)
        let scanner = FileScanner()
        let scanned = try await scanner.scan(sourceID: UUID(), rootURL: root)
        let indexed = try XCTUnwrap(scanned.first)
        let service = FileOperationService()
        try await service.requireIndexedIdentity(indexed)

        try FileManager.default.removeItem(at: url)
        try Data("replacement".utf8).write(to: url)

        do {
            _ = try await service.rename(indexedFile: indexed, to: "renamed.txt")
            XCTFail("Expected replacement to be rejected")
        } catch let error as FileOperationError {
            XCTAssertEqual(error, .fileIdentityChanged)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("renamed.txt").path
            )
        )
    }

    func testTextExtractionStreamsBoundedBatches() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xunjian-text-batches-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<5 {
            try Data("text \(index)".utf8).write(
                to: root.appendingPathComponent("file-\(index).txt")
            )
        }
        let scanner = FileScanner()
        let files = try await scanner.scan(
            sourceID: UUID(),
            rootURL: root,
            extractsText: false
        )
        let recorder = TextExtractionBatchRecorder()

        try await scanner.extractTextContents(
            in: files,
            batchSize: 2,
            consume: { updates in await recorder.record(updates) }
        )

        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.sizes, [2, 2, 1])
        XCTAssertEqual(snapshot.fileIDs.count, 5)
        XCTAssertEqual(Set(snapshot.fileIDs), Set(files.map(\.id)))
    }

    func testContentIndexCanBeEnrichedAndClearedWithoutRemovingFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xunjian-content-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try FileIndexDatabase(
            databaseURL: root.appendingPathComponent("index.sqlite3")
        )
        let source = try await database.upsertSource(
            displayName: "Documents",
            path: root.path,
            bookmark: Data([1])
        )
        let file = IndexedFile(
            id: "content-file",
            sourceID: source.id,
            name: "notes.md",
            path: root.appendingPathComponent("notes.md").path,
            fileExtension: "md",
            kind: .document,
            size: 12,
            createdAt: nil,
            modifiedAt: nil,
            indexedAt: Date()
        )
        try await database.replaceFiles(for: source.id, with: [file])
        try await database.updateTextContents([
            FileTextContentUpdate(fileID: file.id, textContent: "private searchable phrase")
        ])
        let storedText = try await database.fetchTextContent(forFileID: file.id)
        let matchingBeforeClear = try await database.searchFiles(matching: "searchable")
        XCTAssertEqual(storedText, "private searchable phrase")
        XCTAssertEqual(matchingBeforeClear.map(\.id), [file.id])

        try await database.clearTextContents()

        let clearedText = try await database.fetchTextContent(forFileID: file.id)
        let matchingAfterClear = try await database.searchFiles(matching: "searchable")
        let remainingFiles = try await database.fetchFiles()
        XCTAssertNil(clearedText)
        XCTAssertTrue(matchingAfterClear.isEmpty)
        XCTAssertEqual(remainingFiles.map(\.id), [file.id])
    }

    private func makeFile(
        name: String,
        path: String,
        modifiedAt: Date? = Date(),
        size: Int64 = 1
    ) -> IndexedFile {
        IndexedFile(
            id: path,
            sourceID: UUID(),
            name: name,
            path: path,
            fileExtension: "pdf",
            kind: .document,
            size: size,
            createdAt: nil,
            modifiedAt: modifiedAt,
            indexedAt: Date()
        )
    }
}

private actor TextExtractionBatchRecorder {
    private var sizes: [Int] = []
    private var fileIDs: [String] = []

    func record(_ updates: [FileTextContentUpdate]) {
        sizes.append(updates.count)
        fileIDs.append(contentsOf: updates.map(\.fileID))
    }

    func snapshot() -> (sizes: [Int], fileIDs: [String]) {
        (sizes, fileIDs)
    }
}
