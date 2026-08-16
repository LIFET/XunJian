import SwiftUI

/// Layout constants for the file toolbar (F10). Text-sensitive sizes live on
/// the components themselves as `@ScaledMetric` so they grow with the user's
/// text size setting (F03); pure layout values stay here.
enum FileToolbarMetrics {
    static let controlHeight: CGFloat = 32
    static let regularSpacing: CGFloat = 8
    static let compactSpacing: CGFloat = 6
    static let fileTypeWidth: CGFloat = 112
    static func sortWidth(for order: FileSortOrder) -> CGFloat {
        if AppLanguage.selected.usesEnglish,
           order == .modifiedAt || order == .createdAt {
            return 128
        }
        return 104
    }
    static let viewModeWidth: CGFloat = 72
}
