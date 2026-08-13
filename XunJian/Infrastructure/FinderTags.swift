import Foundation
import SwiftUI

/// Read-only access to Finder tags (N17).
///
/// Tags are system metadata owned by Finder. Xunjian only displays them and
/// never writes them back, so a user's existing tagging scheme cannot be
/// changed from here.
actor FinderTagService {
    static let shared = FinderTagService()

    /// Tags are not part of the index, so each lookup is a disk read. Results
    /// are cached for the session because the file table asks for the same
    /// rows repeatedly while scrolling.
    ///
    /// A tag edited in Finder while Xunjian is running keeps the cached value
    /// until `invalidate` is called; tag changes do not update the file's
    /// modification date, so there is nothing cheaper to key off.
    private var cache: [String: [String]] = [:]

    func tags(forFileID fileID: String, path: String) -> [String] {
        if let cached = cache[fileID] { return cached }

        let url = URL(fileURLWithPath: path)
        let names = (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
        cache[fileID] = names
        return names
    }

    func invalidate(fileID: String) {
        cache.removeValue(forKey: fileID)
    }

    func invalidateAll() {
        cache.removeAll()
    }
}

/// Displays a file's Finder tags, loading them off the main actor.
struct FinderTagsLabel: View {
    let file: IndexedFile
    var placeholder = "—"

    @State private var tags: [String] = []
    @State private var hasLoaded = false

    var body: some View {
        Text(verbatim: hasLoaded && !tags.isEmpty ? joined : placeholder)
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(tags.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            .task(id: file.id) {
                hasLoaded = false
                tags = await FinderTagService.shared.tags(
                    forFileID: file.id,
                    path: file.path
                )
                hasLoaded = true
            }
            .accessibilityLabel(Text(verbatim: accessibilityText))
    }

    private var joined: String {
        tags.joined(separator: AppLanguage.selected.usesEnglish ? ", " : "、")
    }

    private var accessibilityText: String {
        guard hasLoaded, !tags.isEmpty else {
            return AppLanguage.localized("没有标签", english: "No tags")
        }
        return AppLanguage.localized("标签：\(joined)", english: "Tags: \(joined)")
    }
}
