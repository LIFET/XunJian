import Foundation

/// Scan UI state that updates many times per scan.
///
/// Kept off `FileIndexCoordinator` / `AppModel` so counting files does not
/// invalidate the whole window. Only the banner observes this object.
@MainActor
final class ScanProgressStore: ObservableObject {
    @Published private(set) var progress: ScanProgress?

    var isActive: Bool { progress != nil }

    func update(_ progress: ScanProgress?) {
        guard self.progress != progress else { return }
        self.progress = progress
    }
}

/// Search-in-progress flag, kept off `FileIndexCoordinator` so typing into
/// search does not redraw the sidebar, inspector, and overlay pages.
@MainActor
final class SearchProgressStore: ObservableObject {
    @Published private(set) var isSearching = false

    func update(_ isSearching: Bool) {
        guard self.isSearching != isSearching else { return }
        self.isSearching = isSearching
    }
}

/// Export progress, kept off `AppModel` so ticking the counter does not
/// rebuild the file table, sidebar, and inspector.
@MainActor
final class FileExportProgressStore: ObservableObject {
    @Published private(set) var progress: FileExportProgress?

    func update(_ progress: FileExportProgress?) {
        guard self.progress != progress else { return }
        self.progress = progress
    }
}

/// One-hop trash undo banner state. Not `@Published` on the index coordinator:
/// showing or dismissing the banner used to redraw the whole window.
@MainActor
final class TrashUndoStore: ObservableObject {
    @Published private(set) var undo: FileIndexCoordinator.TrashUndo?

    func update(_ undo: FileIndexCoordinator.TrashUndo?) {
        guard self.undo != undo else { return }
        self.undo = undo
    }
}
