import AppKit

/// Handles the macOS Services entry (N14): other apps can send file paths
/// to XunJian via the Services menu. Received paths are forwarded to the
/// app model, which selects the file if it is indexed or reveals it in
/// Finder otherwise.
final class XunJianAppDelegate: NSObject, NSApplicationDelegate {
    @objc func openPathsService(
        _ pboard: NSPasteboard,
        userData: String,
        error: NSErrorPointer
    ) {
        guard let paths = pboard.propertyList(forType: .fileURL) as? [String] else {
            error?.pointee = NSError(
                domain: "XunJian",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No file paths provided."]
            )
            return
        }
        for path in paths {
            NotificationCenter.default.post(
                name: .xunJianOpenExternalPath,
                object: path
            )
        }
    }
}

extension Notification.Name {
    /// A path received from another app via the Services menu (N14).
    static let xunJianOpenExternalPath = Notification.Name(
        "xunJianOpenExternalPath"
    )
}
