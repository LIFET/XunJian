import Foundation

/// A bounded stack of reversible user actions (N16).
///
/// Foundation's `UndoManager` is built around the responder chain and
/// synchronous targets; index mutations here are async and go through actors,
/// so an explicit stack of async revert closures is both simpler and testable.
///
/// Only actions with a well-defined inverse are recorded: rename, move,
/// category changes, and move-to-Trash. Reverting is best-effort — if the file
/// changed on disk in the meantime the revert throws and the entry is dropped
/// rather than silently doing the wrong thing.
@MainActor
final class UndoCoordinator: ObservableObject {
    struct Entry: Identifiable {
        let id = UUID()
        /// Shown on the Undo menu item, e.g. "撤销重命名".
        let title: String
        /// Sources whose indexed objects are captured by this undo closure.
        /// Removing one source invalidates only its dependent entries.
        let affectedSourceIDs: Set<UUID>
        let revert: () async throws -> Void
    }

    /// Deep enough for a realistic tidying session, bounded so revert closures
    /// (which capture file metadata) cannot accumulate without limit.
    static let maximumDepth = 20

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var isUndoing = false

    var canUndo: Bool { !isUndoing && !entries.isEmpty }

    /// Title of the action that would be undone next.
    var nextTitle: String? { entries.last?.title }

    /// Returns the new entry's identifier so callers that expose their own
    /// one-off undo affordance can drop it from the stack once used.
    @discardableResult
    func record(
        title: String,
        affectedSourceIDs: Set<UUID> = [],
        revert: @escaping () async throws -> Void
    ) -> UUID {
        let entry = Entry(
            title: title,
            affectedSourceIDs: affectedSourceIDs,
            revert: revert
        )
        entries.append(entry)
        if entries.count > Self.maximumDepth {
            entries.removeFirst(entries.count - Self.maximumDepth)
        }
        return entry.id
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
    }

    func removeEntries(affecting sourceID: UUID) {
        entries.removeAll { $0.affectedSourceIDs.contains(sourceID) }
    }

    /// Pops and runs the most recent action. The entry is removed even when
    /// the revert throws: a failed undo usually means the world changed
    /// underneath it (file moved or deleted elsewhere), and retrying the same
    /// stale closure would keep failing.
    func undoLast() async throws {
        guard !isUndoing, let entry = entries.popLast() else { return }
        isUndoing = true
        defer { isUndoing = false }
        try await entry.revert()
    }

    /// Drops all entries only when the entire index identity is reset.
    func clear() {
        entries.removeAll()
    }

    // MARK: - Titles

    static var renameTitle: String {
        AppLanguage.localized("撤销重命名", english: "Undo Rename")
    }

    static var moveTitle: String {
        AppLanguage.localized("撤销移动", english: "Undo Move")
    }

    static var trashTitle: String {
        AppLanguage.localized("撤销移到废纸篓", english: "Undo Move to Trash")
    }

    static func categoryTitle(assigned: Bool) -> String {
        assigned
            ? AppLanguage.localized("撤销添加分类", english: "Undo Add to Category")
            : AppLanguage.localized("撤销移除分类", english: "Undo Remove from Category")
    }

    static var batchCategoryTitle: String {
        AppLanguage.localized("撤销批量分类", english: "Undo Category Change")
    }

    static var deleteCategoryTitle: String {
        AppLanguage.localized("撤销删除分类", english: "Undo Delete Category")
    }
}
