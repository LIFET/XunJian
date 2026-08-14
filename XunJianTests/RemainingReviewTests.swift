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

    private func makeFile(
        name: String,
        path: String,
        modifiedAt: Date? = Date()
    ) -> IndexedFile {
        IndexedFile(
            id: path,
            sourceID: UUID(),
            name: name,
            path: path,
            fileExtension: "pdf",
            kind: .document,
            size: 1,
            createdAt: nil,
            modifiedAt: modifiedAt,
            indexedAt: Date()
        )
    }
}
