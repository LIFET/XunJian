import Foundation
import CoreFoundation
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

    static func supports(_ url: URL) -> Bool {
        let fileExtension = url.pathExtension.lowercased()
        return fileExtension == "pdf" || Self.supportedTextExtensions.contains(fileExtension)
    }

    func supports(_ url: URL) -> Bool {
        Self.supports(url)
    }

    func extractText(from url: URL) -> String? {
        extractText(from: url, isCancelled: { false })
    }

    func extractText(
        from url: URL,
        isCancelled: @Sendable () -> Bool
    ) -> String? {
        let fileExtension = url.pathExtension.lowercased()
        guard !isCancelled(),
              supports(url),
              let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize,
              fileSize > 0,
              Int64(fileSize) <= maxFileSize else {
            return nil
        }

        let extracted: String?
        if fileExtension == "pdf" {
            extracted = Self.readPDF(
                at: url,
                maximumCharacterCount: maxCharacterCount,
                isCancelled: isCancelled
            )
        } else {
            extracted = Self.readTextFile(
                at: url,
                fileSize: fileSize,
                maximumCharacterCount: maxCharacterCount,
                isCancelled: isCancelled
            )
        }

        guard !isCancelled(), let extracted else { return nil }
        let trimmed = extracted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxCharacterCount))
    }

    private static func readPDF(
        at url: URL,
        maximumCharacterCount: Int,
        isCancelled: @Sendable () -> Bool
    ) -> String? {
        guard !isCancelled(), let document = PDFDocument(url: url) else { return nil }
        var result = ""
        result.reserveCapacity(min(maximumCharacterCount, 32_768))
        for pageIndex in 0..<document.pageCount {
            guard !isCancelled(), result.count < maximumCharacterCount else { break }
            guard let pageText = document.page(at: pageIndex)?.string, !pageText.isEmpty else {
                continue
            }
            if !result.isEmpty { result.append("\n") }
            let remaining = maximumCharacterCount - result.count
            result.append(contentsOf: pageText.prefix(remaining))
        }
        return result.isEmpty ? nil : result
    }

    private static func readTextFile(
        at url: URL,
        fileSize: Int,
        maximumCharacterCount: Int,
        isCancelled: @Sendable () -> Bool
    ) -> String? {
        // Read only enough bytes to satisfy the character budget. Inspector
        // previews use a much smaller budget than AI/full-text extraction, so
        // rapid row changes no longer map and decode every multi-megabyte file.
        let byteBudget = min(
            fileSize,
            max(64 * 1_024, maximumCharacterCount * 4 + 4)
        )
        guard !isCancelled(),
              let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: byteBudget),
              !isCancelled(),
              !data.isEmpty else {
            return nil
        }

        let prefix = data.prefix(4_096)
        let hasUTF16LittleEndianBOM = data.starts(with: [0xFF, 0xFE])
        let hasUTF16BigEndianBOM = data.starts(with: [0xFE, 0xFF])
        let encodings: [String.Encoding]
        if hasUTF16LittleEndianBOM {
            encodings = [.utf16, .utf16LittleEndian]
        } else if hasUTF16BigEndianBOM {
            encodings = [.utf16, .utf16BigEndian]
        } else if prefix.contains(0), Self.looksLikeUTF16(prefix) {
            // UTF-16 text commonly contains NUL bytes. The former early NUL
            // rejection made the UTF-16 decoding branches unreachable.
            encodings = [.utf16LittleEndian, .utf16BigEndian]
        } else if prefix.contains(0) {
            return nil
        } else {
            let detectedEncoding = NSString.stringEncoding(
                for: data,
                encodingOptions: nil,
                convertedString: nil,
                usedLossyConversion: nil
            )
            if detectedEncoding == Self.gb18030Encoding.rawValue {
                encodings = [Self.gb18030Encoding, .utf8]
            } else if String(data: data, encoding: .utf8) == nil,
                      let utf16 = decodedUTF16WithoutBOM(data) {
                return utf16
            } else {
                encodings = [.utf8, Self.gb18030Encoding]
            }
        }

        for encoding in encodings {
            guard !isCancelled() else { return nil }
            if let text = String(data: data, encoding: encoding),
               isPlausibleText(text) {
                return text
            }
        }
        return nil
    }

    private static let gb18030Encoding = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
    )

    private static func looksLikeUTF16(_ bytes: Data.SubSequence) -> Bool {
        guard bytes.count >= 4 else { return false }
        var evenNULs = 0
        var oddNULs = 0
        for (offset, byte) in bytes.enumerated() where byte == 0 {
            if offset.isMultiple(of: 2) {
                evenNULs += 1
            } else {
                oddNULs += 1
            }
        }
        let codeUnitCount = bytes.count / 2
        let dominantNULs = max(evenNULs, oddNULs)
        let otherNULs = min(evenNULs, oddNULs)
        return dominantNULs >= max(2, codeUnitCount / 5)
            && dominantNULs >= otherNULs * 4
    }

    private static func decodedUTF16WithoutBOM(_ data: Data) -> String? {
        guard data.count.isMultiple(of: 2), data.count >= 4 else { return nil }
        let candidates = [
            String(data: data, encoding: .utf16LittleEndian),
            String(data: data, encoding: .utf16BigEndian)
        ].compactMap { text -> (String, Int)? in
            guard let text, isPlausibleText(text) else { return nil }
            return (text, textLikelihoodScore(text))
        }.sorted { $0.1 > $1.1 }
        guard let best = candidates.first,
              best.1 > 0,
              candidates.count == 1 || best.1 >= candidates[1].1 + 2 else {
            return nil
        }
        return best.0
    }

    private static func textLikelihoodScore(_ text: String) -> Int {
        text.unicodeScalars.prefix(4_096).reduce(into: 0) { score, scalar in
            switch scalar.value {
            case 0x3400...0x9FFF, 0x20000...0x2FA1F:
                score += 4
            default:
                if CharacterSet.letters.contains(scalar)
                    || CharacterSet.decimalDigits.contains(scalar) {
                    score += 2
                } else if CharacterSet.whitespacesAndNewlines.contains(scalar)
                            || CharacterSet.punctuationCharacters.contains(scalar) {
                    score += 1
                } else if CharacterSet.controlCharacters.contains(scalar) {
                    score -= 4
                }
            }
        }
    }

    private static func isPlausibleText(_ text: String) -> Bool {
        var inspected = 0
        var suspiciousControls = 0
        for scalar in text.unicodeScalars.prefix(4_096) {
            inspected += 1
            if CharacterSet.controlCharacters.contains(scalar),
               scalar.value != 0x09,
               scalar.value != 0x0A,
               scalar.value != 0x0D {
                suspiciousControls += 1
            }
        }
        guard inspected > 0 else { return false }
        return suspiciousControls * 20 <= inspected
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
        if self == .kind {
            return sortedByKind(files, ascending: ascending)
        }

        return files.sorted { lhs, rhs in
            let result = comparison(lhs, rhs)
            if result == .orderedSame {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    /// Cancellation-aware stable merge sort for interactive six-figure
    /// browse snapshots. Swift's `Array.sorted` cannot stop once started, so
    /// rapidly changing filters previously left several obsolete O(n log n)
    /// sorts competing for CPU and memory.
    func sortedCancellable(
        _ files: [IndexedFile],
        ascending: Bool,
        isCancelled: () -> Bool
    ) -> [IndexedFile]? {
        guard !isCancelled() else { return nil }
        guard self != .relevance else { return files }
        if self == .kind {
            return sortedByKindCancellable(
                files,
                ascending: ascending,
                isCancelled: isCancelled
            )
        }

        return stableSortedCancellable(
            files,
            isCancelled: isCancelled
        ) { lhs, rhs in
            let result = comparison(lhs, rhs)
            if result == .orderedSame {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private func comparison(
        _ lhs: IndexedFile,
        _ rhs: IndexedFile
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
            return .orderedSame
        }
    }

    /// Sort names once, then partition into seven kind buckets. Comparing a
    /// localized name for every same-kind pair made the 100k-file kind sort
    /// pay that cost throughout a second O(n log n) sort.
    private func sortedByKind(_ files: [IndexedFile], ascending: Bool) -> [IndexedFile] {
        let orderedKinds = FileKind.allCases.sorted {
            $0.localizedTitle.localizedStandardCompare($1.localizedTitle) == .orderedAscending
        }
        let rankByKind = Dictionary(uniqueKeysWithValues: orderedKinds.enumerated().map {
            ($0.element, $0.offset)
        })
        let nameOrdered = files.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        var buckets = Array(repeating: [IndexedFile](), count: orderedKinds.count)
        for file in nameOrdered {
            buckets[rankByKind[file.kind] ?? orderedKinds.count - 1].append(file)
        }
        let ranks = ascending ? Array(buckets.indices) : Array(buckets.indices.reversed())
        var result: [IndexedFile] = []
        result.reserveCapacity(files.count)
        for rank in ranks {
            result.append(contentsOf: buckets[rank])
        }
        return result
    }

    private func sortedByKindCancellable(
        _ files: [IndexedFile],
        ascending: Bool,
        isCancelled: () -> Bool
    ) -> [IndexedFile]? {
        let orderedKinds = FileKind.allCases.sorted {
            $0.localizedTitle.localizedStandardCompare($1.localizedTitle) == .orderedAscending
        }
        let rankByKind = Dictionary(uniqueKeysWithValues: orderedKinds.enumerated().map {
            ($0.element, $0.offset)
        })
        guard let nameOrdered = stableSortedCancellable(
            files,
            isCancelled: isCancelled,
            by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        ) else { return nil }
        var buckets = Array(repeating: [IndexedFile](), count: orderedKinds.count)
        for (offset, file) in nameOrdered.enumerated() {
            if offset.isMultiple(of: 1_024), isCancelled() { return nil }
            buckets[rankByKind[file.kind] ?? orderedKinds.count - 1].append(file)
        }
        let ranks = ascending ? Array(buckets.indices) : Array(buckets.indices.reversed())
        var result: [IndexedFile] = []
        result.reserveCapacity(files.count)
        for rank in ranks {
            guard !isCancelled() else { return nil }
            result.append(contentsOf: buckets[rank])
        }
        return result
    }

    private func stableSortedCancellable(
        _ files: [IndexedFile],
        isCancelled: () -> Bool,
        by areInIncreasingOrder: (IndexedFile, IndexedFile) -> Bool
    ) -> [IndexedFile]? {
        guard files.count > 1 else { return isCancelled() ? nil : files }
        var source = files
        var destination = files
        var runWidth = 1
        var comparisons = 0

        while runWidth < source.count {
            guard !isCancelled() else { return nil }
            var runStart = 0
            while runStart < source.count {
                let middle = min(runStart + runWidth, source.count)
                let runEnd = min(runStart + runWidth * 2, source.count)
                var left = runStart
                var right = middle
                var output = runStart

                while left < middle && right < runEnd {
                    comparisons &+= 1
                    if comparisons.isMultiple(of: 1_024), isCancelled() { return nil }
                    if areInIncreasingOrder(source[right], source[left]) {
                        destination[output] = source[right]
                        right += 1
                    } else {
                        destination[output] = source[left]
                        left += 1
                    }
                    output += 1
                }
                while left < middle {
                    destination[output] = source[left]
                    left += 1
                    output += 1
                }
                while right < runEnd {
                    destination[output] = source[right]
                    right += 1
                    output += 1
                }
                runStart = runEnd
            }
            swap(&source, &destination)
            runWidth *= 2
        }
        return isCancelled() ? nil : source
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
