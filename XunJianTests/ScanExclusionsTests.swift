import XCTest
@testable import XunJian

final class ScanExclusionsTests: XCTestCase {
    func testSystemHomePrefersAccountDirectoryOverSandboxContainer() {
        let accountHome = "/Users/owner"
        let sandboxHome = URL(
            fileURLWithPath: "/Users/owner/Library/Containers/app/Data",
            isDirectory: true
        )

        XCTAssertEqual(
            SystemUserHomeDirectory.resolved(
                accountHomePath: accountHome,
                fallback: sandboxHome
            ).path,
            accountHome
        )
    }

    func testSystemHomeFallsBackWhenAccountDirectoryIsInvalid() {
        let sandboxHome = URL(
            fileURLWithPath: "/Users/owner/Library/Containers/app/Data",
            isDirectory: true
        )

        XCTAssertEqual(
            SystemUserHomeDirectory.resolved(
                accountHomePath: nil,
                fallback: sandboxHome
            ).path,
            sandboxHome.path
        )
    }

    func testNormalizationLowercasesTrimsAndDeduplicates() {
        let result = ScanExclusions.normalized([
            "  Vendor  ", "vendor", "PODS", "", "   "
        ])
        XCTAssertEqual(result, ["pods", "vendor"])
    }

    /// Built-in names are always excluded anyway; storing them again would
    /// show a redundant row the user could "remove" with no effect.
    func testBuiltInNamesAreNotStoredAsCustomEntries() {
        let result = ScanExclusions.normalized(["node_modules", ".GIT", "vendor"])
        XCTAssertEqual(result, ["vendor"])
    }

    func testSaveAndLoadRoundTripsThroughDefaults() {
        let suiteName = "ScanExclusionsTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create a test defaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        ScanExclusions.save(["Vendor", "pods"], defaults: defaults)

        XCTAssertEqual(ScanExclusions.current(defaults: defaults), ["pods", "vendor"])
    }

    func testMissingDefaultsYieldsNoCustomExclusions() {
        let suiteName = "ScanExclusionsTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create a test defaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(ScanExclusions.current(defaults: defaults).isEmpty)
    }

    func testSensitiveCredentialStoresRemainExcludedWhenHiddenFilesAreVisible() {
        let sensitivePaths = [
            "/Users/owner/.docker/config.json",
            "/Users/owner/.config/gcloud/application_default_credentials.json",
            "/Users/owner/.config/gh/hosts.yml",
            "/Users/owner/.config/glab-cli/config.yml",
            "/Users/owner/.config/op/config",
            "/Users/owner/.config/1Password/settings.json",
            "/Users/owner/.config/rclone/rclone.conf",
            "/Users/owner/.password-store/example.gpg",
            "/Users/owner/.local/share/keyrings/login.keyring"
        ]

        for path in sensitivePaths {
            XCTAssertTrue(
                ScanExclusions.isSensitivePath(URL(fileURLWithPath: path)),
                "Expected credential path to be excluded: \(path)"
            )
        }
    }

    func testOrdinaryHiddenConfigurationRemainsEligible() {
        XCTAssertFalse(
            ScanExclusions.isSensitivePath(
                URL(fileURLWithPath: "/Users/owner/.config/nvim/init.lua")
            )
        )
    }
}

final class SearchIndexRebuildTests: XCTestCase {
    /// The rebuild must regenerate search rows without touching files or the
    /// user's manual category assignments — `file_categories` cascades on
    /// `files`, so a naive "clear and rescan" would silently discard them.
    func testRebuildPreservesFilesAndCategoryAssignments() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("XunJianTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = try FileIndexDatabase(
            databaseURL: directory.appendingPathComponent("index.sqlite3")
        )
        let source = try await database.upsertSource(
            displayName: "Docs",
            path: directory.appendingPathComponent("Docs").path,
            bookmark: Data("bookmark".utf8)
        )

        let file = IndexedFile(
            id: "file-1",
            sourceID: source.id,
            name: "季度报告.md",
            path: directory.appendingPathComponent("Docs/季度报告.md").path,
            fileExtension: "md",
            kind: .document,
            size: 1_024,
            createdAt: Date(),
            modifiedAt: Date(),
            indexedAt: Date(),
            textContent: "本季度营收增长显著"
        )
        try await database.replaceFiles(for: source.id, with: [file])

        // "财务" ships as a seeded default, so reuse it rather than creating a
        // duplicate (which the database rejects).
        let categories = try await database.fetchCategories()
        let category = try XCTUnwrap(categories.first { $0.name == "财务" })
        try await database.setCategory(category.id, assigned: true, toFile: file.id)

        let reindexed = try await database.rebuildSearchIndex()

        let remainingFiles = try await database.fetchFiles()
        let remainingCategories = try await database.fetchCategories()
        let assignedCategoryIDs = try await database.fetchCategoryIDs(forFile: file.id)
        let nameHits = try await database.searchFiles(matching: "季度报告").map(\.id)
        let bodyHits = try await database.searchFiles(matching: "营收").map(\.id)
        let categoryHits = try await database.searchFiles(matching: "财务").map(\.id)

        XCTAssertEqual(reindexed, 1)
        XCTAssertEqual(remainingFiles.count, 1)
        XCTAssertFalse(remainingCategories.isEmpty)
        XCTAssertEqual(assignedCategoryIDs, [category.id])
        XCTAssertEqual(nameHits, [file.id])
        // Body text and category name stay searchable after the rebuild.
        XCTAssertEqual(bodyHits, [file.id])
        XCTAssertEqual(categoryHits, [file.id])
    }

    func testRebuildRepairsAStaleSearchTable() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("XunJianTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = try FileIndexDatabase(
            databaseURL: directory.appendingPathComponent("index.sqlite3")
        )
        let source = try await database.upsertSource(
            displayName: "Docs",
            path: directory.appendingPathComponent("Docs").path,
            bookmark: Data("bookmark".utf8)
        )
        let files = (0..<3).map { index in
            IndexedFile(
                id: "file-\(index)",
                sourceID: source.id,
                name: "note-\(index).txt",
                path: directory.appendingPathComponent("Docs/note-\(index).txt").path,
                fileExtension: "txt",
                kind: .document,
                size: 10,
                createdAt: Date(),
                modifiedAt: Date(),
                indexedAt: Date(),
                textContent: "searchable body \(index)"
            )
        }
        try await database.replaceFiles(for: source.id, with: files)

        let reindexed = try await database.rebuildSearchIndex()
        let hits = try await database.searchFiles(matching: "note")

        XCTAssertEqual(reindexed, files.count)
        XCTAssertEqual(hits.count, files.count)
    }
}
