import Foundation

/// Ordered multi-selection for a visible file list.
///
/// Finder-style rules:
/// - click replaces the selection and moves both the lead and the anchor
/// - ⌘-click toggles one file and moves the lead/anchor to it
/// - ⇧-click (and ⇧-arrow) fills the range from the sticky anchor to the lead
struct FileSelection: Equatable, Sendable {
    var ids: Set<String> = []
    var leadID: String?
    var anchorID: String?

    var primaryID: String? {
        if let leadID, ids.contains(leadID) {
            return leadID
        }
        return ids.first
    }

    mutating func clear() {
        ids = []
        leadID = nil
        anchorID = nil
    }

    mutating func replace(with fileID: String) {
        ids = [fileID]
        leadID = fileID
        anchorID = fileID
    }

    /// Keeps a multi-selection intact when one file is renamed or moved.
    mutating func resolveIdentity(from oldID: String?, to newID: String) {
        if ids.contains(newID) {
            leadID = newID
            return
        }
        if ids.count > 1, let oldID, ids.contains(oldID) {
            ids.remove(oldID)
            ids.insert(newID)
            if leadID == oldID { leadID = newID }
            if anchorID == oldID { anchorID = newID }
            return
        }
        replace(with: newID)
    }

    mutating func selectAll(orderedIDs: [String]) {
        ids = Set(orderedIDs)
        leadID = orderedIDs.first
        anchorID = orderedIDs.first
    }

    mutating func select(
        _ fileID: String,
        in orderedIDs: [String],
        command: Bool,
        shift: Bool
    ) {
        if shift {
            let anchor = anchorID ?? leadID ?? fileID
            guard let from = orderedIDs.firstIndex(of: anchor),
                  let to = orderedIDs.firstIndex(of: fileID) else {
                replace(with: fileID)
                return
            }
            let range = Set(orderedIDs[min(from, to)...max(from, to)])
            ids = command ? ids.union(range) : range
            leadID = fileID
            if anchorID == nil {
                anchorID = anchor
            }
            return
        }

        if command {
            if ids.contains(fileID) {
                ids.remove(fileID)
                if leadID == fileID {
                    leadID = ids.first
                }
                if anchorID == fileID {
                    anchorID = leadID
                }
            } else {
                ids.insert(fileID)
                leadID = fileID
                anchorID = fileID
            }
            return
        }

        replace(with: fileID)
    }

    /// Arrow-key movement. Shift keeps the original anchor and grows the range.
    mutating func moveLead(by offset: Int, in orderedIDs: [String], extending: Bool) {
        guard !orderedIDs.isEmpty else { return }

        let nextIndex: Int
        if let leadID, let current = orderedIDs.firstIndex(of: leadID) {
            nextIndex = min(max(current + offset, 0), orderedIDs.count - 1)
            if nextIndex == current && !extending {
                return
            }
        } else {
            nextIndex = offset >= 0 ? 0 : orderedIDs.count - 1
        }

        select(
            orderedIDs[nextIndex],
            in: orderedIDs,
            command: false,
            shift: extending
        )
    }

    /// Keeps lead/anchor inside `ids` after an external assignment (the table).
    mutating func reconcileMetadata() {
        if ids.isEmpty {
            leadID = nil
            anchorID = nil
            return
        }
        if let leadID, ids.contains(leadID) {
            if anchorID == nil || ids.contains(anchorID!) == false {
                anchorID = leadID
            }
            return
        }
        leadID = ids.first
        anchorID = leadID
    }
}
