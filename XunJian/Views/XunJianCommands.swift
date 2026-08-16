import SwiftUI

struct XunJianCommandAvailability: Equatable, Sendable {
    let canCreateCategory: Bool
    let canAddFolder: Bool
    let canActOnSelection: Bool
    let canSelectAll: Bool
    let canDeselect: Bool
    let canSearch: Bool
    let canChangeBrowseMode: Bool
    let canToggleInspector: Bool
    let canExport: Bool

    static let unavailable = XunJianCommandAvailability(
        canCreateCategory: false,
        canAddFolder: false,
        canActOnSelection: false,
        canSelectAll: false,
        canDeselect: false,
        canSearch: false,
        canChangeBrowseMode: false,
        canToggleInspector: false,
        canExport: false
    )

    static func resolve(
        destination: NavigationDestination,
        databaseAvailable: Bool,
        hasSelectedFile: Bool,
        selectedFileCount: Int,
        hasCommandTargets: Bool,
        canToggleInspector: Bool,
        isExporting: Bool
    ) -> XunJianCommandAvailability {
        let isFilePage: Bool
        switch destination {
        case .allFiles, .category:
            isFilePage = true
        case .home, .categories, .settings:
            isFilePage = false
        }
        return XunJianCommandAvailability(
            canCreateCategory: databaseAvailable,
            canAddFolder: databaseAvailable,
            canActOnSelection: databaseAvailable && isFilePage && hasSelectedFile,
            canSelectAll: databaseAvailable && isFilePage && hasCommandTargets,
            canDeselect: isFilePage && selectedFileCount > 0,
            canSearch: databaseAvailable,
            canChangeBrowseMode: databaseAvailable,
            canToggleInspector: databaseAvailable && canToggleInspector,
            canExport: databaseAvailable && isFilePage && hasCommandTargets && !isExporting
        )
    }
}

struct XunJianCommandContext {
    let availability: XunJianCommandAvailability
    let createCategory: () -> Void
    let addFolder: () -> Void
    let openSelected: () -> Void
    let quickLookSelected: () -> Void
    let showSelectedInFinder: () -> Void
    let renameSelected: () -> Void
    let moveSelected: () -> Void
    let trashSelection: () -> Void
    let copySelectedPath: () -> Void
    let selectAll: () -> Void
    let deselectAll: () -> Void
    let focusSearch: () -> Void
    let setBrowseViewMode: (FileBrowseViewMode) -> Void
    let toggleInspector: () -> Void
    let showCommandPalette: () -> Void
    let previewSelectedText: () -> Void
    let showStorageInsights: () -> Void
    let exportFileList: (FileListExport.Format) -> Void
}

private struct XunJianCommandContextKey: FocusedValueKey {
    typealias Value = XunJianCommandContext
}

extension FocusedValues {
    var xunJianCommandContext: XunJianCommandContext? {
        get { self[XunJianCommandContextKey.self] }
        set { self[XunJianCommandContextKey.self] = newValue }
    }
}

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
    static let xunJianSetBrowseViewMode = Notification.Name(
        "com.xingmingbo.XunJian.setBrowseViewMode"
    )
}

enum XunJianSearchFieldScope: String, Sendable {
    case home
    case allFiles
    case category
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
    @FocusedValue(\.xunJianCommandContext) private var commandContext

    private var availability: XunJianCommandAvailability {
        commandContext?.availability ?? .unavailable
    }

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
                commandContext?.createCategory()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(!availability.canCreateCategory)

            Button(AppLanguage.localized("添加文件夹…", english: "Add Folder…")) {
                commandContext?.addFolder()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(!availability.canAddFolder)
        }

        CommandGroup(after: .newItem) {
            Divider()

            Button(AppLanguage.localized("打开", english: "Open")) {
                commandContext?.openSelected()
            }
            .keyboardShortcut(.downArrow, modifiers: .command)
            .disabled(!availability.canActOnSelection)

            Menu(AppLanguage.localized("打开最近使用的文件", english: "Open Recent")) {
                if appModel.recentFiles.isEmpty {
                    Text(AppLanguage.localized("没有最近文件", english: "No Recent Files"))
                } else {
                    ForEach(Array(appModel.recentFiles.prefix(8))) { file in
                        Button(file.name) {
                            appModel.open(file)
                        }
                    }
                }
            }
            .disabled(appModel.recentFiles.isEmpty)

            Button(AppLanguage.localized("快速查看", english: "Quick Look")) {
                commandContext?.quickLookSelected()
            }
            .keyboardShortcut("y", modifiers: .command)
            .disabled(!availability.canActOnSelection)

            Button(AppLanguage.localized("在 Finder 中显示", english: "Show in Finder")) {
                commandContext?.showSelectedInFinder()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!availability.canActOnSelection)

            Divider()

            Button(AppLanguage.localized("重命名…", english: "Rename…")) {
                commandContext?.renameSelected()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!availability.canActOnSelection)

            Button(AppLanguage.localized("移动到…", english: "Move To…")) {
                commandContext?.moveSelected()
            }
            .disabled(!availability.canActOnSelection)

            Button(AppLanguage.localized("移到废纸篓", english: "Move to Trash")) {
                commandContext?.trashSelection()
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(!availability.canActOnSelection)
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
                commandContext?.copySelectedPath()
            }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(!availability.canActOnSelection)

            Divider()

            Button(AppLanguage.localized("全选文件", english: "Select All Files")) {
                commandContext?.selectAll()
            }
            .keyboardShortcut("a", modifiers: [.command, .option])
            .disabled(!availability.canSelectAll)

            Button(AppLanguage.localized("取消选择", english: "Deselect All")) {
                commandContext?.deselectAll()
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(!availability.canDeselect)
        }

        CommandGroup(after: .textEditing) {
            Button(AppLanguage.localized("查找文件", english: "Find Files")) {
                commandContext?.focusSearch()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(!availability.canSearch)
        }
    }

    // MARK: - View

    @CommandsBuilder
    private var viewCommands: some Commands {
        CommandGroup(after: .toolbar) {
            Button(AppLanguage.localized("以列表显示", english: "As List")) {
                commandContext?.setBrowseViewMode(.list)
            }
            .keyboardShortcut("1", modifiers: .command)
            .disabled(!availability.canChangeBrowseMode)

            Button(AppLanguage.localized("以图标显示", english: "As Icons")) {
                commandContext?.setBrowseViewMode(.grid)
            }
            .keyboardShortcut("2", modifiers: .command)
            .disabled(!availability.canChangeBrowseMode)

            Divider()

            Button(AppLanguage.localized("显示或隐藏文件详情", english: "Show or Hide File Details")) {
                commandContext?.toggleInspector()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(!availability.canToggleInspector)

            Divider()

            Button(AppLanguage.localized("命令面板…", english: "Command Palette…")) {
                commandContext?.showCommandPalette()
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(commandContext == nil)

            Button(AppLanguage.localized("预览正文", english: "Preview Text")) {
                commandContext?.previewSelectedText()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(!availability.canActOnSelection)

            Button(AppLanguage.localized("存储洞察…", english: "Storage Insights…")) {
                commandContext?.showStorageInsights()
            }
            .disabled(commandContext == nil)
        }
    }

    private func exportButton(_ format: FileListExport.Format) -> some View {
        Button("\(format.localizedTitle)…") {
            commandContext?.exportFileList(format)
        }
        .disabled(!availability.canExport)
    }
}
