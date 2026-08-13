import SwiftUI

/// Menu bar commands for palette, insights, and export.
///
/// Kept out of `XunJianApp.body` because inlining them pushed the scene
/// builder past what the type checker could resolve.
struct XunJianCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button(AppLanguage.localized("命令面板…", english: "Command Palette…")) {
                NotificationCenter.default.post(name: .xunJianShowCommandPalette, object: nil)
            }
            .keyboardShortcut("k", modifiers: .command)

            Button(AppLanguage.localized("预览正文", english: "Preview Text")) {
                NotificationCenter.default.post(name: .xunJianShowTextPreview, object: nil)
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])

            Button(AppLanguage.localized("存储洞察…", english: "Storage Insights…")) {
                NotificationCenter.default.post(name: .xunJianShowStorageInsights, object: nil)
            }
        }

        CommandGroup(after: .saveItem) {
            Menu(AppLanguage.localized("导出文件清单", english: "Export File List")) {
                exportButton(.csv)
                exportButton(.markdown)
            }
        }
    }

    private func exportButton(_ format: FileListExport.Format) -> some View {
        Button("\(format.localizedTitle)…") {
            NotificationCenter.default.post(
                name: .xunJianExportFileList,
                object: format.rawValue
            )
        }
    }
}
