import AppKit
import SwiftUI

// MARK: - Search field

/// Observes the global query without making AppShellView observe it. Each key
/// therefore invalidates only this small native-control bridge.
struct BrowseSearchField: View {
    @ObservedObject var store: BrowseSearchStore
    let appModel: AppModel

    var body: some View {
        SearchField(
            text: Binding(
                get: { store.query },
                set: { appModel.searchText = $0 }
            ),
            focusScope: .allFiles
        )
    }
}

struct SearchField: View {
    @Binding var text: String
    /// Overrides the default "search local files" prompt when the field is
    /// scoped (category page) rather than global.
    var prompt: String? = nil
    var accessibilityHint: String? = nil
    var focusScope: XunJianSearchFieldScope
    /// Called when a recent-search chip is chosen. Home uses this to jump to
    /// All Files; other pages just fill the field via `text`.
    var onHistorySelect: ((String) -> Void)? = nil
    @State private var isFocused = false

    /// Shared so the field can offer recent searches without every call site
    /// having to thread a store through (N03).
    @ObservedObject private var history = SearchHistoryStore.shared
    @ScaledMetric(relativeTo: .body) private var fieldHeight: CGFloat = 40

    var body: some View {
        searchRow
            .onExitCommand {
                handleExitCommand()
            }
            .onReceive(NotificationCenter.default.publisher(for: .xunJianFocusSearchField)) { note in
                guard note.object as? String == focusScope.rawValue else { return }
                isFocused = true
            }
    }

    private var searchRow: some View {
        NativeSearchField(
            text: $text,
            isFocused: $isFocused,
            prompt: prompt ?? AppLanguage.localized(
                "搜索本地文件…",
                english: "Search local files…"
            ),
            accessibilityLabel: AppLanguage.localized(
                "搜索文件",
                english: "Search Files"
            ),
            accessibilityHelp: accessibilityHint ?? AppLanguage.localized(
                "搜索已索引的本地文件",
                english: "Searches indexed local files"
            ),
            controlSize: .large,
            recentSearches: history.entries,
            recentSearchesTitle: AppLanguage.localized("最近搜索", english: "Recent Searches"),
            noRecentSearchesTitle: AppLanguage.localized("没有最近搜索", english: "No Recent Searches"),
            clearRecentSearchesTitle: AppLanguage.localized("清除搜索历史", english: "Clear Search History"),
            onSubmit: { committedText in
                history.record(committedText)
                onHistorySelect?(committedText)
            },
            onClearRecentSearches: history.clear,
            onCancel: handleExitCommand
        )
        .frame(height: fieldHeight)
    }

    private func handleExitCommand() {
        if !text.isEmpty {
            text = ""
        } else {
            isFocused = false
        }
    }
}

/// AppKit's native search control provides the standard magnifying glass,
/// focus ring, clear button, keyboard behaviour, and macOS accessibility
/// semantics without recreating that chrome in SwiftUI.
struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let prompt: String
    let accessibilityLabel: String
    let accessibilityHelp: String
    var controlSize: NSControl.ControlSize = .regular
    var recentSearches: [String] = []
    var recentSearchesTitle = ""
    var noRecentSearchesTitle = ""
    var clearRecentSearchesTitle = ""
    let onSubmit: (String) -> Void
    var onClearRecentSearches: () -> Void = {}
    var onMoveSelection: (Int) -> Void = { _ in }
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = NSSearchField()
        searchField.delegate = context.coordinator
        searchField.target = context.coordinator
        searchField.action = #selector(Coordinator.submit(_:))
        searchField.controlSize = controlSize
        searchField.bezelStyle = .roundedBezel
        searchField.focusRingType = .default
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = true
        if !recentSearchesTitle.isEmpty {
            context.coordinator.installSearchMenuIfNeeded(on: searchField)
            searchField.maximumRecents = SearchHistoryStore.maximumEntryCount
        }
        return searchField
    }

    func updateNSView(_ searchField: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if searchField.stringValue != text {
            searchField.stringValue = text
        }
        searchField.placeholderString = prompt
        searchField.controlSize = controlSize
        searchField.setAccessibilityLabel(accessibilityLabel)
        searchField.setAccessibilityHelp(accessibilityHelp)
        searchField.recentSearches = recentSearches
        if !recentSearchesTitle.isEmpty {
            context.coordinator.installSearchMenuIfNeeded(on: searchField)
        }

        guard isFocused else { return }
        DispatchQueue.main.async { [weak searchField, weak coordinator = context.coordinator] in
            guard let searchField,
                  let coordinator,
                  coordinator.parent.isFocused,
                  searchField.window?.firstResponder !== searchField.currentEditor() else { return }
            searchField.window?.makeFirstResponder(searchField)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: NativeSearchField
        private var searchMenuSignature: String?

        init(parent: NativeSearchField) {
            self.parent = parent
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.isFocused = true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.isFocused = false
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let searchField = notification.object as? NSSearchField else { return }
            parent.text = searchField.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                if !parent.isFocused {
                    control.window?.makeFirstResponder(nil)
                }
                return true
            case #selector(NSResponder.moveUp(_:)):
                parent.onMoveSelection(-1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onMoveSelection(1)
                return true
            default:
                return false
            }
        }

        @objc func submit(_ sender: NSSearchField) {
            parent.text = sender.stringValue
            parent.onSubmit(sender.stringValue)
        }

        func makeSearchMenu() -> NSMenu {
            let menu = NSMenu()

            let title = NSMenuItem(title: parent.recentSearchesTitle, action: nil, keyEquivalent: "")
            title.tag = NSSearchField.recentsTitleMenuItemTag
            menu.addItem(title)

            let recents = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            recents.tag = NSSearchField.recentsMenuItemTag
            menu.addItem(recents)

            let noRecents = NSMenuItem(title: parent.noRecentSearchesTitle, action: nil, keyEquivalent: "")
            noRecents.tag = NSSearchField.noRecentsMenuItemTag
            menu.addItem(noRecents)

            menu.addItem(.separator())
            let clear = NSMenuItem(
                title: parent.clearRecentSearchesTitle,
                action: #selector(clearRecentSearches(_:)),
                keyEquivalent: ""
            )
            clear.target = self
            menu.addItem(clear)
            return menu
        }

        func installSearchMenuIfNeeded(on searchField: NSSearchField) {
            let signature = [
                parent.recentSearchesTitle,
                parent.noRecentSearchesTitle,
                parent.clearRecentSearchesTitle
            ].joined(separator: "\u{1F}")
            guard searchMenuSignature != signature else { return }
            searchMenuSignature = signature
            searchField.searchMenuTemplate = makeSearchMenu()
        }

        @objc private func clearRecentSearches(_ sender: Any?) {
            parent.onClearRecentSearches()
        }
    }
}
