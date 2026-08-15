import Foundation

/// Category assignments and the derived per-file / per-category lookups.
///
/// Kept off `FileIndexCoordinator` / `AppModel` so toggling one file's category
/// does not rebuild the sidebar, home page, or the All Files table. Visible
/// category chips observe this object directly.
@MainActor
final class CategoryIndexStore: ObservableObject {
    @Published private(set) var revision: UInt64 = 0

    private var categories: [FileCategory] = []
    private var categoryByID: [UUID: FileCategory] = [:]
    private var fileCategoryLinks: [String: Set<UUID>] = [:]
    private var categoriesByFileID: [String: [FileCategory]] = [:]
    private var fileCountsByCategoryID: [UUID: Int] = [:]
    private var filesByCategoryID: [UUID: [IndexedFile]] = [:]

    func replaceAll(
        categories: [FileCategory],
        links: [String: Set<UUID>],
        categoriesByFileID: [String: [FileCategory]],
        fileCountsByCategoryID: [UUID: Int],
        filesByCategoryID: [UUID: [IndexedFile]]
    ) {
        self.categories = categories
        categoryByID = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        fileCategoryLinks = links
        self.categoriesByFileID = categoriesByFileID
        self.fileCountsByCategoryID = fileCountsByCategoryID
        self.filesByCategoryID = filesByCategoryID
        revision &+= 1
    }

    func applyAssignment(assigned: Bool, file: IndexedFile, category: FileCategory) {
        var assignedIDs = fileCategoryLinks[file.id] ?? []
        if assigned {
            assignedIDs.insert(category.id)
        } else {
            assignedIDs.remove(category.id)
        }
        if assignedIDs.isEmpty {
            fileCategoryLinks.removeValue(forKey: file.id)
            categoriesByFileID.removeValue(forKey: file.id)
        } else {
            fileCategoryLinks[file.id] = assignedIDs
            categoriesByFileID[file.id] = assignedIDs.compactMap { categoryByID[$0] }
        }

        var list = filesByCategoryID[category.id] ?? []
        if assigned {
            if !list.contains(where: { $0.id == file.id }) {
                list.append(file)
            }
        } else {
            list.removeAll { $0.id == file.id }
        }
        filesByCategoryID[category.id] = list
        fileCountsByCategoryID[category.id] = list.count
        revision &+= 1
    }

    func applyAssignments(
        assigned: Bool,
        files: [IndexedFile],
        category: FileCategory
    ) {
        guard !files.isEmpty else { return }
        let changedIDs = Set(files.map(\.id))

        for file in files {
            var assignedIDs = fileCategoryLinks[file.id] ?? []
            if assigned {
                assignedIDs.insert(category.id)
            } else {
                assignedIDs.remove(category.id)
            }
            if assignedIDs.isEmpty {
                fileCategoryLinks.removeValue(forKey: file.id)
                categoriesByFileID.removeValue(forKey: file.id)
            } else {
                fileCategoryLinks[file.id] = assignedIDs
                categoriesByFileID[file.id] = assignedIDs.compactMap { categoryByID[$0] }
            }
        }

        var categoryFiles = filesByCategoryID[category.id] ?? []
        if assigned {
            var existingIDs = Set(categoryFiles.map(\.id))
            for file in files where existingIDs.insert(file.id).inserted {
                categoryFiles.append(file)
            }
        } else {
            categoryFiles.removeAll { changedIDs.contains($0.id) }
        }
        filesByCategoryID[category.id] = categoryFiles
        fileCountsByCategoryID[category.id] = categoryFiles.count
        revision &+= 1
    }

    func categories(for fileID: String) -> [FileCategory] {
        categoriesByFileID[fileID] ?? []
    }

    func files(in categoryID: UUID) -> [IndexedFile] {
        filesByCategoryID[categoryID] ?? []
    }

    func fileCount(in categoryID: UUID) -> Int {
        fileCountsByCategoryID[categoryID] ?? 0
    }

    func isAssigned(_ categoryID: UUID, to fileID: String) -> Bool {
        fileCategoryLinks[fileID]?.contains(categoryID) == true
    }
}
