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
        return ids.min()
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
        shift: Bool,
        idIndex: [String: Int]? = nil
    ) {
        func index(of candidate: String) -> Int? {
            if let idIndex, let position = idIndex[candidate] {
                return position
            }
            return orderedIDs.firstIndex(of: candidate)
        }
        if shift {
            let anchor = anchorID ?? leadID ?? fileID
            guard let from = index(of: anchor),
                  let to = index(of: fileID) else {
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
                let removedPosition = index(of: fileID)
                ids.remove(fileID)
                if leadID == fileID {
                    leadID = nearestSelectedID(
                        to: removedPosition,
                        in: orderedIDs
                    )
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

    private func nearestSelectedID(
        to removedPosition: Int?,
        in orderedIDs: [String]
    ) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let removedPosition else { return ids.min() }
        if removedPosition > 0 {
            for position in stride(from: removedPosition - 1, through: 0, by: -1) {
                let candidate = orderedIDs[position]
                if ids.contains(candidate) { return candidate }
            }
        }
        if removedPosition + 1 < orderedIDs.count {
            for position in (removedPosition + 1)..<orderedIDs.count {
                let candidate = orderedIDs[position]
                if ids.contains(candidate) { return candidate }
            }
        }
        return ids.min()
    }

    /// Arrow-key movement. Shift keeps the original anchor and grows the range.
    mutating func moveLead(
        by offset: Int,
        in orderedIDs: [String],
        extending: Bool,
        idIndex: [String: Int]? = nil
    ) {
        guard !orderedIDs.isEmpty else { return }

        let nextIndex: Int
        if let leadID {
            let current: Int
            if let idIndex, let position = idIndex[leadID] {
                current = position
            } else if let position = orderedIDs.firstIndex(of: leadID) {
                current = position
            } else {
                current = -1
            }
            guard current >= 0 else { return }
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
            shift: extending,
            idIndex: idIndex
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
        leadID = ids.min()
        anchorID = leadID
    }

    /// Reconciles the native macOS table's set-only selection with the
    /// Finder-style lead/anchor metadata used by keyboard and menu actions.
    /// The table does not expose the clicked row separately, so the newly
    /// added endpoint is inferred from the selection delta and display order.
    mutating func applyNativeTableSelection(
        _ newIDs: Set<String>,
        orderedIDs: [String],
        idIndex: [String: Int]? = nil,
        command: Bool = false,
        shift: Bool = false
    ) {
        guard newIDs != ids else { return }
        guard !newIDs.isEmpty else {
            clear()
            return
        }
        if newIDs.count == 1, let onlyID = newIDs.first {
            replace(with: onlyID)
            return
        }

        let previousIDs = ids
        let previousAnchor = anchorID ?? leadID
        let addedIDs = newIDs.subtracting(previousIDs)
        let removedIDs = previousIDs.subtracting(newIDs)

        if command,
           let toggledID = addedIDs.count == 1
                ? addedIDs.first
                : (removedIDs.count == 1 ? removedIDs.first : nil) {
            select(
                toggledID,
                in: orderedIDs,
                command: true,
                shift: shift,
                idIndex: idIndex
            )
            if ids == newIDs { return }
        }

        if shift, let anchor = previousAnchor {
            func position(of id: String) -> Int? {
                idIndex?[id] ?? orderedIDs.firstIndex(of: id)
            }
            if let anchorPosition = position(of: anchor),
               let endpoint = newIDs.max(by: { lhs, rhs in
                   abs((position(of: lhs) ?? anchorPosition) - anchorPosition)
                       < abs((position(of: rhs) ?? anchorPosition) - anchorPosition)
               }) {
                select(
                    endpoint,
                    in: orderedIDs,
                    command: command,
                    shift: true,
                    idIndex: idIndex
                )
                if ids == newIDs { return }
            }
        }

        ids = newIDs

        if addedIDs.count == 1, let addedID = addedIDs.first {
            leadID = addedID
            anchorID = addedID
            return
        }

        if addedIDs.count > 1 {
            func position(of id: String) -> Int? {
                idIndex?[id] ?? orderedIDs.firstIndex(of: id)
            }
            if let anchor = previousAnchor, let anchorPosition = position(of: anchor) {
                leadID = addedIDs.max { lhs, rhs in
                    abs((position(of: lhs) ?? anchorPosition) - anchorPosition)
                        < abs((position(of: rhs) ?? anchorPosition) - anchorPosition)
                }
                anchorID = anchor
                return
            }
        }

        reconcileMetadata()
    }
}

/// Keeps an AppKit selection gesture authoritative until its SwiftUI binding
/// has echoed the same value back into `updateNSView`.
///
/// `NSCollectionView` can publish deselect/select callbacks separately and a
/// representable update may run between them (for example when a thumbnail
/// finishes). Applying the still-old binding during that window visibly rolls
/// the native highlight back. Once publication completes, a genuinely
/// different external value remains authoritative.
struct NativeSelectionEchoGuard: Equatable, Sendable {
    private enum Phase: Equatable, Sendable {
        case awaitingPublication
        case awaitingEcho
    }

    private var pendingIDs: Set<String>?
    private var phase: Phase?

    mutating func nativeSelectionDidChange(to ids: Set<String>) {
        pendingIDs = ids
        phase = .awaitingPublication
    }

    mutating func nativeSelectionPublicationDidComplete() {
        guard pendingIDs != nil else { return }
        phase = .awaitingEcho
    }

    /// Returns `true` only when AppKit should apply the external value.
    mutating func shouldApplyExternalSelection(_ ids: Set<String>) -> Bool {
        guard let pendingIDs, phase != nil else { return true }
        if ids == pendingIDs {
            cancelPendingNativeSelection()
            return false
        }
        // Several already-enqueued representable updates can arrive here
        // after publication (for example empty, then A, after a native A→B
        // click). None is authoritative until the binding echoes B itself.
        // Programmatic selection changes are accepted again after that echo.
        return false
    }

    mutating func cancelPendingNativeSelection() {
        pendingIDs = nil
        phase = nil
    }
}
