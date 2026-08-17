import AppKit
import SwiftUI

struct DisplayedFilesSnapshot {
    let files: [IndexedFile]
    let orderedIDs: [String]
    let idIndex: [String: Int]
    let signature: Int?
    let userSignature: Int?

    static let empty = DisplayedFilesSnapshot(
        files: [],
        orderedIDs: [],
        idIndex: [:],
        signature: nil,
        userSignature: nil
    )
}

/// Identifies the inputs a displayed-file snapshot was built from.
///
/// Deliberately free of the file array itself: this value is rebuilt on every
/// `body` evaluation and compared by `.task(id:)`, so carrying the whole index
/// made both the comparison and the allocation O(files). `filesRevision` from
/// the coordinator stands in for "the file set changed".
struct DisplayedFilesRefreshKey: Equatable {
    let filesRevision: UInt64
    let searchResultsRevision: UInt64
    let aiSearchResultCount: Int?
    let aiSearchRevision: UInt64
    let selectedKind: FileKind?
    let sortOrder: FileSortOrder
    let sortAscending: Bool
    let minSizeBytes: Int64
    let minDate: Date?
    let isVisible: Bool

    var signature: Int {
        var hasher = Hasher()
        hasher.combine(filesRevision)
        hasher.combine(searchResultsRevision)
        hasher.combine(aiSearchResultCount)
        hasher.combine(aiSearchRevision)
        hasher.combine(selectedKind)
        hasher.combine(sortOrder)
        hasher.combine(sortAscending)
        hasher.combine(minSizeBytes)
        hasher.combine(minDate)
        return hasher.finalize()
    }
}

/// Interactive snapshot inputs. Two keys with the same signature differ only
/// because `filesRevision` changed, which lets the view settle FSEvents
/// bursts without delaying search or filter results.
struct DisplayedFilesUserKey: Equatable {
    let query: String
    let searchResultsRevision: UInt64
    let aiSearchResultCount: Int?
    let aiSearchRevision: UInt64
    let selectedKind: FileKind?
    let sortOrder: FileSortOrder
    let sortAscending: Bool
    let minSizeBytes: Int64
    let minDate: Date?

    var signature: Int {
        var hasher = Hasher()
        hasher.combine(query)
        hasher.combine(searchResultsRevision)
        hasher.combine(aiSearchResultCount)
        hasher.combine(aiSearchRevision)
        hasher.combine(selectedKind)
        hasher.combine(sortOrder)
        hasher.combine(sortAscending)
        hasher.combine(minSizeBytes)
        hasher.combine(minDate)
        return hasher.finalize()
    }
}

enum DisplayedFilesRefreshPolicy {
    static let revisionDrivenSettleDelay: Duration = .milliseconds(250)

    static func shouldSettleRevisionDrivenRefresh(
        previousUserSignature: Int?,
        currentUserSignature: Int
    ) -> Bool {
        previousUserSignature == currentUserSignature
    }
}

struct FileToolbarLayoutConfiguration: Equatable {
    let compactAI: Bool
    let showsFileType: Bool
    let showsSort: Bool
    let showsSortDirection: Bool
    let showsViewMode: Bool
    let spacing: CGFloat
}

enum FileToolbarLayoutPolicy {
    /// Build exactly one toolbar tree for the current width. ViewThatFits
    /// eagerly measured five complete Picker/Menu variants, adding a visible
    /// layout stall to every control click on a large library.
    static func configuration(for contentWidth: CGFloat) -> FileToolbarLayoutConfiguration {
        switch contentWidth {
        case 1_120...:
            FileToolbarLayoutConfiguration(
                compactAI: false,
                showsFileType: true,
                showsSort: true,
                showsSortDirection: true,
                showsViewMode: true,
                spacing: FileToolbarMetrics.regularSpacing
            )
        case 940..<1_120:
            FileToolbarLayoutConfiguration(
                compactAI: false,
                showsFileType: true,
                showsSort: true,
                showsSortDirection: true,
                showsViewMode: false,
                spacing: FileToolbarMetrics.regularSpacing
            )
        case 760..<940:
            FileToolbarLayoutConfiguration(
                compactAI: true,
                showsFileType: true,
                showsSort: true,
                showsSortDirection: false,
                showsViewMode: false,
                spacing: FileToolbarMetrics.compactSpacing
            )
        case 620..<760:
            FileToolbarLayoutConfiguration(
                compactAI: true,
                showsFileType: true,
                showsSort: false,
                showsSortDirection: false,
                showsViewMode: false,
                spacing: FileToolbarMetrics.compactSpacing
            )
        default:
            FileToolbarLayoutConfiguration(
                compactAI: true,
                showsFileType: false,
                showsSort: false,
                showsSortDirection: false,
                showsViewMode: false,
                spacing: FileToolbarMetrics.compactSpacing
            )
        }
    }
}

enum FileBrowsePerformancePolicy {
    /// Continuous scroll-position observation invalidates the SwiftUI parent
    /// for every crossed row. Native Table already virtualizes large data sets,
    /// so disable only that optional persistence layer for very large libraries.
    static let liveScrollTrackingLimit = 20_000
    static let modeAnimationLimit = 5_000
    static let nativeTableThreshold = 20_000

    static func tracksLiveListScrollPosition(fileCount: Int) -> Bool {
        fileCount <= liveScrollTrackingLimit
    }

    static func tracksLiveGridScrollPosition(fileCount: Int) -> Bool {
        fileCount <= liveScrollTrackingLimit
    }

    static func usesNativeTable(fileCount: Int) -> Bool {
        fileCount > nativeTableThreshold
    }

    static func usesNativeGrid(fileCount: Int) -> Bool {
        fileCount > nativeTableThreshold
    }

    static func usesNativeBrowser(fileCount: Int) -> Bool {
        usesNativeTable(fileCount: fileCount) || usesNativeGrid(fileCount: fileCount)
    }

    static func animatesModeChange(fileCount: Int) -> Bool {
        fileCount <= modeAnimationLimit
    }
}

/// Skips rebuilding the file table when only unrelated AppModel fields changed.
struct EquatableSnapshotList<Content: View>: View, Equatable {
    let signature: Int?
    let viewMode: FileBrowseViewMode
    let selectionEpoch: UInt64
    let metadataEpoch: UInt64
    let layoutToken: Int
    let content: () -> Content

    init(
        signature: Int?,
        viewMode: FileBrowseViewMode,
        selectionEpoch: UInt64,
        metadataEpoch: UInt64,
        layoutToken: Int,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.signature = signature
        self.viewMode = viewMode
        self.selectionEpoch = selectionEpoch
        self.metadataEpoch = metadataEpoch
        self.layoutToken = layoutToken
        self.content = content
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.signature == rhs.signature
            && lhs.viewMode == rhs.viewMode
            && lhs.selectionEpoch == rhs.selectionEpoch
            && lhs.metadataEpoch == rhs.metadataEpoch
            && lhs.layoutToken == rhs.layoutToken
    }

    var body: some View {
        content()
    }
}

/// Category chips observe `CategoryIndexStore` so toggling one file does not
/// rebuild the enclosing table.
struct FileCategoryNamesLabel: View {
    let fileID: String
    @EnvironmentObject private var categoryIndex: CategoryIndexStore

    var body: some View {
        let names = categoryIndex.categories(for: fileID).map(\.localizedDisplayName)
        Text(
            names.isEmpty
                ? "—"
                : names.joined(separator: AppLanguage.listSeparator)
        )
        .lineLimit(1)
    }
}

@MainActor
final class NativeFileActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func invoke() {
        handler()
    }
}

struct FileContextMenu: View {
    @EnvironmentObject private var appModel: AppModel
    let file: IndexedFile

    /// When the clicked row is part of a multi-selection, category and trash
    /// actions apply to the whole selection instead of just this file.
    private var actsOnSelection: Bool {
        appModel.selectedFileIDs.count > 1
            && appModel.selectedFileIDs.contains(file.id)
    }

    var body: some View {
        Button(AppLanguage.localized("打开", english: "Open")) { appModel.open(file) }
        Button(AppLanguage.localized("快速查看", english: "Quick Look")) { appModel.quickLook(file) }
        Button(AppLanguage.localized("在 Finder 中显示", english: "Show in Finder")) {
            appModel.showInFinder(file)
        }
        Button(AppLanguage.localized("复制路径", english: "Copy Path")) {
            appModel.copyPath(file)
        }

        Divider()

        if actsOnSelection {
            Menu(AppLanguage.localized("批量添加到分类", english: "Add Selection to Category")) {
                if appModel.categories.isEmpty {
                    Text(
                        AppLanguage.localized(
                            "还没有分类",
                            english: "No categories yet"
                        )
                    )
                } else {
                    ForEach(appModel.categories) { category in
                        Button {
                            appModel.assignSelectedFiles(to: category)
                        } label: {
                            Label(category.localizedDisplayName, systemImage: category.symbolName)
                        }
                    }
                }
            }
            Button(
                AppLanguage.localized(
                    "移到废纸篓（\(appModel.selectedFileIDs.count) 项）",
                    english: "Move \(appModel.selectedFileIDs.count) Items to Trash"
                ),
                role: .destructive
            ) {
                appModel.requestBatchTrash()
            }
        } else {
            Menu(AppLanguage.localized("添加到分类", english: "Add to Category")) {
                if appModel.categories.isEmpty {
                    Text(
                        AppLanguage.localized(
                            "还没有分类",
                            english: "No categories yet"
                        )
                    )
                    Button {
                        NotificationCenter.default.post(
                            name: .xunJianRequestNewCategory,
                            object: nil
                        )
                    } label: {
                        Label(
                            AppLanguage.localized("新建分类…", english: "New Category…"),
                            systemImage: "plus"
                        )
                    }
                } else {
                    ForEach(appModel.categories) { category in
                        Button {
                            appModel.toggleCategory(category, for: file)
                        } label: {
                            if appModel.isCategory(category, assignedTo: file) {
                                Label(category.localizedDisplayName, systemImage: "checkmark")
                            } else {
                                Label(category.localizedDisplayName, systemImage: category.symbolName)
                            }
                        }
                    }
                }
            }

            Divider()

            Button(AppLanguage.localized("重命名…", english: "Rename…")) {
                appModel.requestRename(file)
            }
            Button(AppLanguage.localized("移动到…", english: "Move To…")) {
                appModel.chooseMoveDestination(for: file)
            }
            Button(
                AppLanguage.localized("移到废纸篓", english: "Move to Trash"),
                role: .destructive
            ) {
                appModel.requestTrash(file)
            }
        }
    }
}
