import SwiftUI

extension Notification.Name {
    static let xunJianFocusSearch = Notification.Name(
        "com.xingmingbo.XunJian.focusSearch"
    )
    /// Posted after the All Files page (and its search field) is on screen.
    static let xunJianFocusSearchField = Notification.Name(
        "com.xingmingbo.XunJian.focusSearchField"
    )
    static let xunJianToggleInspector = Notification.Name(
        "com.xingmingbo.XunJian.toggleInspector"
    )
    static let xunJianRevealInAllFiles = Notification.Name(
        "com.xingmingbo.XunJian.revealInAllFiles"
    )
}

/// The app's menu bar.
///
/// Every keyboard shortcut lives here rather than only on a control, so the
/// menu bar stays the single discoverable list of what the keyboard can do.
/// Items that act on a file are disabled when nothing is selected instead of
/// silently doing nothing.
///
/// Kept out of `XunJianApp.body` because inlining it pushed the scene builder
/// past what the type checker could resolve.
struct XunJianCommands: Commands {
    @ObservedObject var appModel: AppModel
    @ObservedObject var undo: UndoCoordinator

    @AppStorage("allFiles.viewMode") private var viewMode = FileBrowseViewMode.list

    private var selectedFile: IndexedFile? { appModel.selectedFile }
    private var hasSelection: Bool { selectedFile != nil }

    var body: some Commands {
        fileCommands
        editCommands
        viewCommands
    }

    // MARK: - File

    @CommandsBuilder
    private var fileCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(AppLanguage.localized("新建分类…", english: "New Category…")) {
                NotificationCenter.default.post(name: .xunJianRequestNewCategory, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)

            Button(AppLanguage.localized("添加文件夹…", english: "Add Folder…")) {
                appModel.chooseFolder()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        CommandGroup(after: .newItem) {
            Divider()

            Button(AppLanguage.localized("打开", english: "Open")) {
                selectedFile.map(appModel.open)
            }
            .keyboardShortcut(.downArrow, modifiers: .command)
            .disabled(!hasSelection)

            Button(AppLanguage.localized("快速查看", english: "Quick Look")) {
                selectedFile.map(appModel.quickLook)
            }
            .keyboardShortcut("y", modifiers: .command)
            .disabled(!hasSelection)

            Button(AppLanguage.localized("在访达中显示", english: "Show in Finder")) {
                selectedFile.map(appModel.showInFinder)
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!hasSelection)

            Divider()

            Button(AppLanguage.localized("重命名…", english: "Rename…")) {
                selectedFile.map(appModel.requestRename)
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!hasSelection)

            Button(AppLanguage.localized("移动到…", english: "Move To…")) {
                selectedFile.map(appModel.chooseMoveDestination)
            }
            .disabled(!hasSelection)

            Button(AppLanguage.localized("移到废纸篓", english: "Move to Trash")) {
                if appModel.selectedFileIDs.count > 1 {
                    appModel.requestBatchTrash()
                } else {
                    selectedFile.map(appModel.requestTrash)
                }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(!hasSelection)
        }

        CommandGroup(after: .saveItem) {
            Menu(AppLanguage.localized("导出文件清单", english: "Export File List")) {
                exportButton(.csv)
                exportButton(.markdown)
            }
        }
    }

    // MARK: - Edit

    @CommandsBuilder
    private var editCommands: some Commands {
        // Keep the native responder-chain Undo/Redo items intact for text
        // fields. File-operation undo uses a separate shortcut and label.
        CommandGroup(after: .undoRedo) {
            Button(undo.nextTitle ?? AppLanguage.localized("撤销", english: "Undo")) {
                appModel.performUndo()
            }
            .keyboardShortcut("z", modifiers: [.command, .option])
            .disabled(!undo.canUndo)
        }

        CommandGroup(after: .pasteboard) {
            Button(AppLanguage.localized("拷贝路径", english: "Copy Path")) {
                selectedFile.map(appModel.copyPath)
            }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(!hasSelection)

            Divider()

            Button(AppLanguage.localized("全选文件", english: "Select All Files")) {
                appModel.selectAllDisplayedFiles()
            }
            .keyboardShortcut("a", modifiers: [.command, .option])
            .disabled(appModel.commandTargetFiles.isEmpty)

            Button(AppLanguage.localized("取消选择", english: "Deselect All")) {
                appModel.selectedFileIDs = []
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(appModel.selectedFileIDs.isEmpty)
        }

        CommandGroup(after: .textEditing) {
            Button(AppLanguage.localized("查找文件", english: "Find Files")) {
                NotificationCenter.default.post(name: .xunJianFocusSearch, object: nil)
            }
            .keyboardShortcut("f", modifiers: .command)
        }
    }

    // MARK: - View

    @CommandsBuilder
    private var viewCommands: some Commands {
        CommandGroup(after: .toolbar) {
            Button(AppLanguage.localized("以列表显示", english: "As List")) {
                viewMode = .list
            }
            .keyboardShortcut("1", modifiers: .command)

            Button(AppLanguage.localized("以图标显示", english: "As Icons")) {
                viewMode = .grid
            }
            .keyboardShortcut("2", modifiers: .command)

            Divider()

            Button(AppLanguage.localized("显示或隐藏文件详情", english: "Show or Hide File Details")) {
                NotificationCenter.default.post(name: .xunJianToggleInspector, object: nil)
            }
            .keyboardShortcut("i", modifiers: [.command, .option])

            Divider()

            Button(AppLanguage.localized("命令面板…", english: "Command Palette…")) {
                NotificationCenter.default.post(name: .xunJianShowCommandPalette, object: nil)
            }
            .keyboardShortcut("k", modifiers: .command)

            Button(AppLanguage.localized("预览正文", english: "Preview Text")) {
                NotificationCenter.default.post(name: .xunJianShowTextPreview, object: nil)
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(!hasSelection)

            Button(AppLanguage.localized("存储洞察…", english: "Storage Insights…")) {
                NotificationCenter.default.post(name: .xunJianShowStorageInsights, object: nil)
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
