import AppKit
import SwiftUI

extension Notification.Name {
    static let xunJianExportFileList = Notification.Name(
        "com.xingmingbo.XunJian.exportFileList"
    )
}

/// Exports the current result list as a plain-text artifact (N11).
///
/// Read-only: this writes a new file the user picks and never touches the
/// indexed files themselves.
enum FileListExport {
    enum Format: String, CaseIterable, Identifiable {
        case csv
        case markdown

        var id: String { rawValue }

        var fileExtension: String { self == .csv ? "csv" : "md" }

        var localizedTitle: String {
            switch self {
            case .csv: AppLanguage.localized("CSV 表格", english: "CSV Spreadsheet")
            case .markdown: AppLanguage.localized("Markdown 清单", english: "Markdown List")
            }
        }
    }

    /// The list the user is currently looking at.
    ///
    /// An explicit multi-selection wins; otherwise this uses the files the
    /// active page last published as visible. Falls back to the raw index
    /// only before any page has published a target list. An empty published
    /// list (Settings, category overview) exports nothing rather than the
    /// whole index.
    @MainActor
    static func currentFiles(from appModel: AppModel) -> [IndexedFile] {
        if appModel.selectedFileIDs.count > 1 {
            return appModel.selectedFiles
        }
        if appModel.hasPublishedCommandTarget {
            return appModel.commandTargetFiles
        }
        return appModel.files
    }

    @MainActor
    static func run(appModel: AppModel, format: Format) {
        let files = currentFiles(from: appModel)
        guard !files.isEmpty else {
            appModel.errorMessage = AppLanguage.localized(
                "当前没有可导出的文件。",
                english: "There are no files to export right now."
            )
            return
        }

        let panel = NSSavePanel()
        panel.title = AppLanguage.localized("导出文件清单", english: "Export File List")
        panel.nameFieldStringValue = defaultFileName(format: format)
        panel.allowedContentTypes = []
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let categoryNames = files.reduce(into: [String: [String]]()) { result, file in
            result[file.id] = appModel.categories(for: file).map(\.localizedDisplayName)
        }
        let text = contents(
            for: files,
            format: format,
            categoryNames: categoryNames
        )

        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            appModel.errorMessage = error.localizedDescription
        }
    }

    static func defaultFileName(format: Format) -> String {
        // Built per call rather than cached in a static: this runs once per
        // export, and a shared formatter would not be concurrency-safe.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withDashSeparatorInDate]
        let base = AppLanguage.localized("寻简文件清单", english: "XunJian File List")
        return "\(base) \(formatter.string(from: Date())).\(format.fileExtension)"
    }

    static func contents(
        for files: [IndexedFile],
        format: Format,
        categoryNames: [String: [String]]
    ) -> String {
        switch format {
        case .csv:
            csv(for: files, categoryNames: categoryNames)
        case .markdown:
            markdown(for: files, categoryNames: categoryNames)
        }
    }

    private static var headers: [String] {
        [
            AppLanguage.localized("名称", english: "Name"),
            AppLanguage.localized("类型", english: "Type"),
            AppLanguage.localized("大小", english: "Size"),
            AppLanguage.localized("字节", english: "Bytes"),
            AppLanguage.localized("修改时间", english: "Date Modified"),
            AppLanguage.localized("创建时间", english: "Date Created"),
            AppLanguage.localized("分类", english: "Categories"),
            AppLanguage.localized("路径", english: "Path")
        ]
    }

    private static func row(
        for file: IndexedFile,
        categoryNames: [String: [String]],
        dateFormatter: (Date) -> String
    ) -> [String] {
        [
            file.name,
            file.kind.localizedTitle,
            ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file),
            String(file.size),
            file.modifiedAt.map(dateFormatter) ?? "",
            file.createdAt.map(dateFormatter) ?? "",
            (categoryNames[file.id] ?? []).joined(separator: "; "),
            file.path
        ]
    }

    private static func csv(
        for files: [IndexedFile],
        categoryNames: [String: [String]]
    ) -> String {
        let formatter = ISO8601DateFormatter()
        var lines = [headers.map(csvField).joined(separator: ",")]
        for file in files {
            let cells = row(
                for: file,
                categoryNames: categoryNames,
                dateFormatter: { formatter.string(from: $0) }
            )
            lines.append(cells.map(csvField).joined(separator: ","))
        }
        // Trailing newline keeps the file POSIX-clean for downstream tools.
        return lines.joined(separator: "\n") + "\n"
    }

    /// Quotes any field containing a delimiter, quote, or newline, doubling
    /// embedded quotes per RFC 4180. A leading spreadsheet formula marker is
    /// prefixed with an apostrophe so opening an exported list cannot execute
    /// a formula supplied by a file name, category, or path.
    static func csvField(_ value: String) -> String {
        let safeValue: String
        let firstMeaningful = value.drop(while: { $0 == " " || $0 == "\t" }).first
        if let firstMeaningful, "=+-@\r".contains(firstMeaningful) {
            safeValue = "'" + value
        } else {
            safeValue = value
        }
        guard safeValue.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
        else {
            return safeValue
        }
        return "\"\(safeValue.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func markdown(
        for files: [IndexedFile],
        categoryNames: [String: [String]]
    ) -> String {
        var lines = [
            "# " + AppLanguage.localized("寻简文件清单", english: "XunJian File List"),
            "",
            AppLanguage.localized(
                "共 \(files.count) 个文件 · 导出于 \(FinderDateFormatting.string(for: Date()))",
                english: "\(files.count) files · exported \(FinderDateFormatting.string(for: Date()))"
            ),
            "",
            "| " + headers.map(markdownCell).joined(separator: " | ") + " |",
            "| " + headers.map { _ in "---" }.joined(separator: " | ") + " |"
        ]
        for file in files {
            let cells = row(
                for: file,
                categoryNames: categoryNames,
                dateFormatter: FinderDateFormatting.string(for:)
            )
            lines.append("| " + cells.map(markdownCell).joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Escapes pipes and flattens newlines so a single file never breaks the
    /// table structure.
    static func markdownCell(_ value: String) -> String {
        value
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}
