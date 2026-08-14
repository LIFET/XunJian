import AppKit
import Combine
import SwiftUI

/// Handles the macOS Services entry: other apps can send file paths to
/// XunJian via the Services menu. Received paths are forwarded to the app
/// model, which selects the file if it is indexed or reveals it in Finder
/// otherwise.
///
/// Also owns the menu bar quick-search item. That lives here as an
/// `NSStatusItem` rather than a SwiftUI `MenuBarExtra`: a `MenuBarExtra` in
/// the scene tree hangs the XCTest runner before it can connect, even when
/// `isInserted` is false.
final class XunJianAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var preferenceObservation: AnyCancellable?
    private weak var appModel: AppModel?

    @MainActor
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
        // Bring the app forward: without this the selection changes silently
        // while XunJian is still in the background.
        NSApplication.shared.activate(ignoringOtherApps: true)
        for path in paths {
            NotificationCenter.default.post(
                name: .xunJianOpenExternalPath,
                object: path
            )
        }
    }

    // MARK: - Menu bar quick search

    /// Called once the SwiftUI scene has an app model to share with the
    /// popover's content view.
    @MainActor
    func attachMenuBarSearch(appModel: AppModel) {
        guard !Self.isRunningTests, self.appModel == nil else { return }
        self.appModel = appModel

        preferenceObservation = NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .map { _ in Self.isMenuBarSearchEnabled }
            .removeDuplicates()
            .sink { [weak self] enabled in
                self?.setMenuBarSearchVisible(enabled)
            }
        setMenuBarSearchVisible(Self.isMenuBarSearchEnabled)
    }

    private static var isMenuBarSearchEnabled: Bool {
        UserDefaults.standard.object(forKey: MenuBarSearchPreference.storageKey) as? Bool ?? true
    }

    private static let isRunningTests =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    @MainActor
    private func setMenuBarSearchVisible(_ isVisible: Bool) {
        guard isVisible else {
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
            }
            statusItem = nil
            popover = nil
            return
        }
        guard statusItem == nil, let appModel else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "magnifyingglass",
            accessibilityDescription: AppLanguage.localized(
                "寻简快速搜索",
                english: "XunJian Quick Search"
            )
        )
        item.button?.target = self
        item.button?.action = #selector(toggleQuickSearch)
        statusItem = item

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 340, height: 360)
        popover.contentViewController = NSHostingController(
            rootView: MenuBarSearchView().environmentObject(appModel)
        )
        self.popover = popover
    }

    @MainActor
    @objc private func toggleQuickSearch() {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

extension Notification.Name {
    /// A path received from another app via the Services menu.
    static let xunJianOpenExternalPath = Notification.Name(
        "xunJianOpenExternalPath"
    )
}
