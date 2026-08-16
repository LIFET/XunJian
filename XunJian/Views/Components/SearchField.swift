import AppKit
import SwiftUI

// MARK: - Shared visual tokens (Views only)

/// Lightweight presentation tokens for consistent macOS chrome across Views.
/// No business logic — spacing, radii, and surface fills only.
enum XunJianUI {
    enum Spacing {
        static let page: CGFloat = 24
        static let pageCompact: CGFloat = 16
        static let section: CGFloat = 24
        static let sectionInner: CGFloat = 12
        static let row: CGFloat = 10
        static let tight: CGFloat = 4
    }

    enum Radius {
        static let card: CGFloat = 10
        static let row: CGFloat = 8
        static let control: CGFloat = 8
        static let search: CGFloat = 10
        static let chip: CGFloat = 6
    }

    enum Fill {
        static let quiet = Color.primary.opacity(0.04)
        static let hover = Color.primary.opacity(0.06)
        static let pressed = Color.primary.opacity(0.08)
        static let selected = Color.accentColor.opacity(0.12)
        static let selectedSoft = Color.accentColor.opacity(0.08)
        static let control = Color.primary.opacity(0.065)
        static let accentWash = Color.accentColor.opacity(0.055)
        static let stroke = Color.primary.opacity(0.08)
        static let strokeSelected = Color.accentColor.opacity(0.45)
    }

    /// Status colours. Previously these were written inline in three different
    /// files, so changing "what green means" meant editing all of them.
    enum Semantic {
        static let success = Color.green
        static let warning = Color.orange
        static let danger = Color.red
        static let neutral = Color.secondary

        static let successWash = Color.green.opacity(0.12)
        static let warningWash = Color.orange.opacity(0.12)
        static let dangerWash = Color.red.opacity(0.12)
    }

    /// Responsive layout thresholds, previously scattered as magic numbers
    /// across AppShellView, AllFilesView, HomeView, and CategoriesView.
    enum Breakpoint {
        /// Below this the page switches to compact padding.
        static let compactPage: CGFloat = 520
        /// Below this the file toolbar collapses into an overflow menu.
        static let compactToolbar: CGFloat = 640
        /// Window widths at which the inspector auto-collapses / restores.
        static let inspectorAutoCollapse: CGFloat = 1_080
        static let inspectorRestore: CGFloat = 1_140
        /// Window widths at which the sidebar auto-collapses / restores.
        static let sidebarAutoCollapse: CGFloat = 960
        static let sidebarRestore: CGFloat = 1_020

        /// Minimum width of an adaptive grid item.
        static let homeCardMin: CGFloat = 148
        static let categoryCardMin: CGFloat = 176

        /// Minimum height reserved for empty-state panels, so the layout
        /// doesn't collapse when there is nothing to show.
        static let homeEmptyStateHeight: CGFloat = 168
        static let categoryEmptyStateHeight: CGFloat = 280
    }

    /// Animation durations. Debounce intervals live on `AppModel` instead,
    /// since they govern behaviour rather than presentation.
    enum Timing {
        /// Standard UI state transition. Short enough to feel instant.
        static let transition: TimeInterval = 0.18
        /// Faster variant for press/hover feedback.
        static let feedback: TimeInterval = 0.12
        /// Overlay panels (command palette) use a slightly longer spring.
        static let overlay: TimeInterval = 0.28
    }

    static func pagePadding(for width: CGFloat) -> CGFloat {
        width < Breakpoint.compactPage ? Spacing.pageCompact : Spacing.page
    }

    // MARK: - Motion

    static let standardAnimation = Animation.easeOut(duration: Timing.transition)
    static let feedbackAnimation = Animation.easeOut(duration: Timing.feedback)
    static let overlayAnimation = Animation.spring(response: 0.28, dampingFraction: 0.88)

    /// Returns `nil` when the system "Reduce Motion" setting is on, so callers
    /// can pass the result straight to `withAnimation` and get an instant,
    /// non-animated state change instead.
    static func motion(
        _ animation: Animation? = standardAnimation,
        reduceMotion: Bool
    ) -> Animation? {
        reduceMotion ? nil : animation
    }
}

// MARK: - Reduce Motion aware animation

private struct XunJianAnimationModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let animation: Animation?
    let value: Value

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    /// Implicit animation that honours the system "Reduce Motion" setting.
    /// Use this instead of `.animation(_:value:)` everywhere in the app.
    func xunjianAnimation<Value: Equatable>(
        _ animation: Animation? = XunJianUI.standardAnimation,
        value: Value
    ) -> some View {
        modifier(XunJianAnimationModifier(animation: animation, value: value))
    }
}

// MARK: - Search field

struct SearchField: View {
    @Binding var text: String
    /// Overrides the default "search local files" prompt when the field is
    /// scoped (category page) rather than global.
    var prompt: String? = nil
    var accessibilityHint: String? = nil
    /// Called when a recent-search chip is chosen. Home uses this to jump to
    /// All Files; other pages just fill the field via `text`.
    var onHistorySelect: ((String) -> Void)? = nil
    @State private var isFocused = false

    /// Shared so the field can offer recent searches without every call site
    /// having to thread a store through (N03).
    @ObservedObject private var history = SearchHistoryStore.shared
    @ScaledMetric(relativeTo: .body) private var fieldHeight: CGFloat = 36

    var body: some View {
        searchRow
            .onExitCommand {
                handleExitCommand()
            }
            .onReceive(NotificationCenter.default.publisher(for: .xunJianFocusSearchField)) { _ in
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

// MARK: - Reusable chrome

struct PageHeader: View {
    let title: String
    var subtitle: String?
    var compactSubtitle = false

    var body: some View {
        VStack(alignment: .leading, spacing: XunJianUI.Spacing.tight) {
            Text(verbatim: title)
                .font(.title2.weight(.semibold))
            if let subtitle, !subtitle.isEmpty {
                Text(verbatim: subtitle)
                    .font(compactSubtitle ? .caption : .subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(verbatim: title)
            .font(.headline)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Soft grouped surface for list-like content blocks.
struct GroupedSurface<Content: View>: View {
    var padding: CGFloat = 4
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                XunJianUI.Fill.quiet,
                in: RoundedRectangle(cornerRadius: XunJianUI.Radius.card, style: .continuous)
            )
    }
}

struct InteractiveCardBackground: View {
    var isSelected = false
    var isHovered = false
    var cornerRadius: CGFloat = XunJianUI.Radius.card

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(fillColor)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(strokeColor, lineWidth: 1)
            }
            .xunjianAnimation(XunJianUI.feedbackAnimation, value: isSelected)
            .xunjianAnimation(XunJianUI.feedbackAnimation, value: isHovered)
    }

    private var fillColor: Color {
        if isSelected { return XunJianUI.Fill.selectedSoft }
        if isHovered { return XunJianUI.Fill.hover }
        return XunJianUI.Fill.quiet
    }

    private var strokeColor: Color {
        if isSelected { return XunJianUI.Fill.strokeSelected.opacity(0.55) }
        return Color.clear
    }
}

struct SoftCardButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = XunJianUI.Radius.card

    func makeBody(configuration: Configuration) -> some View {
        PressFeedback(isPressed: configuration.isPressed) {
            configuration.label
        }
    }

    /// A `ButtonStyle` cannot read `@Environment` directly, so the press
    /// feedback lives in a real view in order to honour Reduce Motion.
    private struct PressFeedback<Label: View>: View {
        let isPressed: Bool
        @ViewBuilder var label: () -> Label

        var body: some View {
            label()
                .opacity(isPressed ? 0.78 : 1)
                .scaleEffect(isPressed ? 0.985 : 1)
                .xunjianAnimation(XunJianUI.feedbackAnimation, value: isPressed)
        }
    }
}
