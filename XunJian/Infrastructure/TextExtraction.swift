import Foundation
import PDFKit

struct TextExtractionService: Sendable {
    private static let supportedTextExtensions: Set<String> = [
        "txt", "md", "markdown", "json", "yaml", "yml", "xml", "csv", "html", "htm",
        "swift", "m", "mm", "c", "h", "cpp", "hpp", "js", "jsx", "ts", "tsx",
        "py", "sh", "zsh", "bash", "rb", "go", "rs", "java", "kt", "sql", "css"
    ]

    private let maxFileSize: Int64
    private let maxCharacterCount: Int

    init(
        maxFileSize: Int64 = 8 * 1_024 * 1_024,
        maxCharacterCount: Int = 200_000
    ) {
        self.maxFileSize = maxFileSize
        self.maxCharacterCount = maxCharacterCount
    }

    func supports(_ url: URL) -> Bool {
        let fileExtension = url.pathExtension.lowercased()
        return fileExtension == "pdf" || Self.supportedTextExtensions.contains(fileExtension)
    }

    func extractText(from url: URL) -> String? {
        let fileExtension = url.pathExtension.lowercased()
        guard supports(url),
              let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize,
              fileSize > 0,
              Int64(fileSize) <= maxFileSize else {
            return nil
        }

        let extracted: String?
        if fileExtension == "pdf" {
            extracted = PDFDocument(url: url)?.string
        } else {
            extracted = Self.readTextFile(at: url)
        }

        guard let extracted else { return nil }
        let trimmed = extracted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxCharacterCount))
    }

    private static func readTextFile(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              !data.isEmpty,
              !data.prefix(4_096).contains(0) else {
            return nil
        }

        for encoding in [
            String.Encoding.utf8,
            .utf16,
            .utf16LittleEndian,
            .utf16BigEndian,
            .isoLatin1
        ] {
            if let text = String(data: data, encoding: encoding) {
                return text
            }
        }
        return nil
    }
}

enum FileSortOrder: String, CaseIterable, Identifiable, Sendable {
    case relevance
    case name
    case modifiedAt
    case createdAt
    case size
    case kind

    var id: String { rawValue }

    var title: String {
        switch self {
        case .relevance: "相关度"
        case .name: "名称"
        case .modifiedAt: "修改时间"
        case .createdAt: "创建时间"
        case .size: "大小"
        case .kind: "类型"
        }
    }

    func sorted(_ files: [IndexedFile], ascending: Bool) -> [IndexedFile] {
        guard self != .relevance else { return files }

        let kindSortRanks: [FileKind: Int]
        if self == .kind {
            kindSortRanks = Dictionary(
                uniqueKeysWithValues: FileKind.allCases
                    .sorted {
                        $0.localizedTitle.localizedStandardCompare($1.localizedTitle)
                            == .orderedAscending
                    }
                    .enumerated()
                    .map { ($0.element, $0.offset) }
            )
        } else {
            kindSortRanks = [:]
        }

        return files.sorted { lhs, rhs in
            let result = comparison(lhs, rhs, kindSortRanks: kindSortRanks)
            if result == .orderedSame {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private func comparison(
        _ lhs: IndexedFile,
        _ rhs: IndexedFile,
        kindSortRanks: [FileKind: Int]
    ) -> ComparisonResult {
        switch self {
        case .relevance:
            return .orderedSame
        case .name:
            return lhs.name.localizedStandardCompare(rhs.name)
        case .modifiedAt:
            return compareOptionalDates(lhs.modifiedAt, rhs.modifiedAt)
        case .createdAt:
            return compareOptionalDates(lhs.createdAt, rhs.createdAt)
        case .size:
            return compare(lhs.size, rhs.size)
        case .kind:
            return compare(
                kindSortRanks[lhs.kind] ?? Int.max,
                kindSortRanks[rhs.kind] ?? Int.max
            )
        }
    }

    private func compareOptionalDates(_ lhs: Date?, _ rhs: Date?) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): compare(lhs, rhs)
        case (nil, nil): .orderedSame
        case (nil, _): .orderedDescending
        case (_, nil): .orderedAscending
        }
    }

    private func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }
}

enum SearchIndexText {
    static func normalized(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)

        for scalar in text.lowercased().unicodeScalars {
            if isCJK(scalar) {
                result.append(" ")
                result.unicodeScalars.append(scalar)
                result.append(" ")
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    static func matchExpression(for query: String) -> String? {
        let tokens = normalized(query)
            .unicodeScalars
            .split { !CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " AND ")
    }

    /// FTS expression matching any of the given keywords (F13): each keyword
    /// expands to its own AND-group and the groups are OR-ed, so AI search
    /// issues one query instead of one per keyword.
    static func matchExpression(forKeywords keywords: [String]) -> String? {
        let groups = keywords.compactMap { matchExpression(for: $0) }
        guard !groups.isEmpty else { return nil }
        return groups.map { "(\($0))" }.joined(separator: " OR ")
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
             0x3040...0x30FF, 0xAC00...0xD7AF:
            true
        default:
            false
        }
    }
}
