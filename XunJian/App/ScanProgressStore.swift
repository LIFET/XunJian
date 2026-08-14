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
