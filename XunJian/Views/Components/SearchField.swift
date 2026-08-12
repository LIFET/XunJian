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
        /// Table columns interpolate between their minimum and ideal widths
        /// across this range.
        static let tableCompressionStart: CGFloat = 640
        static let tableCompressionEnd: CGFloat = 1_020

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
    }

    static func pagePadding(for width: CGFloat) -> CGFloat {
        width < Breakpoint.compactPage ? Spacing.pageCompact : Spacing.page
    }

    // MARK: - Motion

    static let standardAnimation = Animation.easeOut(duration: Timing.transition)
    static let feedbackAnimation = Animation.easeOut(duration: Timing.feedback)

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
    @FocusState private var isFocused: Bool

    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 14
    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 16
    @ScaledMetric(relativeTo: .body) private var clearButtonSide: CGFloat = 28
    @ScaledMetric(relativeTo: .body) private var fieldHeight: CGFloat = 36

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(isFocused ? Color.accentColor : Color.secondary)
                .frame(width: iconWidth)

            TextField(
                "",
                text: $text,
                prompt: Text(verbatim: AppLanguage.localized(
                    "搜索本地文件…",
                    english: "Search local files…"
                ))
            )
            .textFieldStyle(.plain)
            .font(.body)
            .focused($isFocused)
            .keyboardShortcut("f", modifiers: .command)
            .accessibilityLabel(Text(verbatim: AppLanguage.localized(
                "搜索文件",
                english: "Search Files"
            )))

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: iconSize))
                        .foregroundStyle(.tertiary)
                        .frame(width: clearButtonSide, height: clearButtonSide)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: AppLanguage.localized(
                    "清除搜索",
                    english: "Clear Search"
                )))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: fieldHeight)
        .background {
            RoundedRectangle(cornerRadius: XunJianUI.Radius.search, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
            RoundedRectangle(cornerRadius: XunJianUI.Radius.search, style: .continuous)
                .strokeBorder(
                    isFocused
                        ? Color.accentColor.opacity(0.45)
                        : XunJianUI.Fill.stroke,
                    lineWidth: 1
                )
        }
        .accessibilityElement(children: .contain)
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
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
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
        configuration.label
            .opacity(configuration.isPressed ? 0.78 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
