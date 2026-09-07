import AppKit
import SwiftUI

// MARK: - Shared visual system

/// Presentation-only roles shared by SwiftUI views. Business timing and model
/// constants stay with their owning feature.
enum XunJianUI {
    static let controlHeight: CGFloat = 34
    static let iconSize: CGFloat = 16
    enum Spacing {
        static let page: CGFloat = 24
        static let pageCompact: CGFloat = 16
        static let section: CGFloat = 24
        static let sectionInner: CGFloat = 12
        static let panel: CGFloat = 18
        static let row: CGFloat = 10
        static let tight: CGFloat = 4
        static let sheet: CGFloat = 24
    }

    enum Radius {
        static let card: CGFloat = 10
        static let row: CGFloat = 8
        static let control: CGFloat = 8
        static let search: CGFloat = 10
        static let chip: CGFloat = 6
        static let floating: CGFloat = 12
    }

    enum Typography {
        static let pageTitle = Font.system(size: 24, weight: .semibold)
        static let sheetTitle = Font.system(size: 21, weight: .semibold)
        static let sectionTitle = Font.headline
        static let itemTitle = Font.body.weight(.medium)
        static let supporting = Font.caption
        static let status = Font.caption
    }

    enum Size {
        static let compactControlHeight: CGFloat = 34
        static let regularControlHeight: CGFloat = 40
        static let rowIcon: CGFloat = 20
        static let compactIcon: CGFloat = 16
        static let minimumHitTarget: CGFloat = 34
        static let readableContentWidth: CGFloat = 760
        static let overviewContentWidth: CGFloat = 1120
    }

    /// Platform semantic surfaces remain legible in light, dark, inactive and
    /// increased-contrast appearances.
    enum Surface {
        static let canvas = Color(nsColor: .windowBackgroundColor)
        static let raised = Color(nsColor: .controlBackgroundColor)
        static let muted = Color(nsColor: .underPageBackgroundColor)
        static let separator = Color(nsColor: .separatorColor)
        static let inactiveSelection = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
    }

    enum Fill {
        static let quiet = Surface.raised.opacity(0.62)
        static let hover = Color.primary.opacity(0.06)
        static let pressed = Color.primary.opacity(0.08)
        static let selected = Color.accentColor.opacity(0.12)
        static let selectedSoft = Color.accentColor.opacity(0.08)
        static let control = Surface.raised
        static let accentWash = Color.accentColor.opacity(0.055)
        static let stroke = Surface.separator.opacity(0.78)
        static let strokeSelected = Color.accentColor.opacity(0.45)
    }

    enum Semantic {
        static let success = Color(nsColor: .systemGreen)
        static let warning = Color(nsColor: .systemOrange)
        static let danger = Color(nsColor: .systemRed)
        static let neutral = Color.secondary

        static let successWash = Color(nsColor: .systemGreen).opacity(0.12)
        static let warningWash = Color(nsColor: .systemOrange).opacity(0.12)
        static let dangerWash = Color(nsColor: .systemRed).opacity(0.12)
    }

    enum Breakpoint {
        static let compactPage: CGFloat = 520
        static let compactToolbar: CGFloat = 640
        static let inspectorAutoCollapse: CGFloat = 1_080
        static let inspectorRestore: CGFloat = 1_140
        static let sidebarAutoCollapse: CGFloat = 960
        static let sidebarRestore: CGFloat = 1_020
        static let homeCardMin: CGFloat = 148
        static let categoryCardMin: CGFloat = 176
        static let homeEmptyStateHeight: CGFloat = 168
        static let categoryEmptyStateHeight: CGFloat = 280
        static let compactOverlayHeight: CGFloat = 540
    }

    enum Timing {
        static let transition: TimeInterval = 0.18
        static let feedback: TimeInterval = 0.12
        static let overlay: TimeInterval = 0.28
    }

    enum Shadow {
        static let floatingColor = Color.black.opacity(0.14)
        static let floatingRadius: CGFloat = 16
        static let floatingY: CGFloat = 7
    }

    static func pagePadding(for width: CGFloat) -> CGFloat {
        width < Breakpoint.compactPage ? Spacing.pageCompact : Spacing.page
    }

    static let standardAnimation = Animation.easeOut(duration: Timing.transition)
    static let feedbackAnimation = Animation.easeOut(duration: Timing.feedback)
    static let overlayAnimation = Animation.spring(response: 0.28, dampingFraction: 0.88)

    static func motion(
        _ animation: Animation? = standardAnimation,
        reduceMotion: Bool
    ) -> Animation? {
        reduceMotion ? nil : animation
    }
}

/// A horizontal rule must own its axis. Divider inside an overlay can inherit
/// a horizontal layout proposal and become a full-height vertical line.
struct WorkspaceRowSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.45))
            .frame(height: 0.5)
            .accessibilityHidden(true)
    }
}

/// A shared target, not just a larger glyph. Keyboard activation remains owned
/// by Button; hover and pressed feedback never change the layout.
struct XunJianIconButtonStyle: ButtonStyle {
    var isSelected = false
    var expandsForLabel = false

    func makeBody(configuration: Configuration) -> some View {
        Target(label: configuration.label, isPressed: configuration.isPressed,
               isSelected: isSelected, expandsForLabel: expandsForLabel)
    }

    private struct Target<Label: View>: View {
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.colorSchemeContrast) private var contrast
        @State private var isHovered = false
        let label: Label
        let isPressed: Bool
        let isSelected: Bool
        let expandsForLabel: Bool

        var body: some View {
            label
                .font(.system(size: XunJianUI.iconSize, weight: .medium))
                .frame(minWidth: XunJianUI.controlHeight)
                .frame(width: expandsForLabel ? nil : XunJianUI.controlHeight, height: XunJianUI.controlHeight)
                .foregroundStyle(isEnabled ? (isSelected ? Color.accentColor : Color.primary) : Color.secondary)
                .background {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(isSelected ? XunJianUI.Fill.selected :
                                (isEnabled && (isHovered || isPressed) ? XunJianUI.Fill.hover : Color.clear))
                }
                .overlay {
                    if isSelected && contrast == .increased {
                        RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary, lineWidth: 1)
                    }
                }
                .opacity(isEnabled ? (isPressed ? 0.7 : 1) : 0.45)
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
                .xunjianAnimation(XunJianUI.feedbackAnimation, value: isHovered)
                .xunjianAnimation(XunJianUI.feedbackAnimation, value: isPressed)
        }
    }
}

/// Pair with MenuStyle.button. BorderlessButtonMenuStyle ignores the label's
/// target frame and exposes a glyph-sized native hit area on macOS.
struct XunJianToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        XunJianIconButtonStyle(expandsForLabel: true).makeBody(configuration: configuration)
    }
}

struct XunJianToolbarLabel: View {
    let title: String
    let systemImage: String
    var showsTitle = true
    var showsChevron = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage).font(.system(size: XunJianUI.iconSize))
            if showsTitle { Text(verbatim: title).font(.system(size: 13, weight: .medium)).lineLimit(1) }
            if showsChevron { Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)) }
        }
        .padding(.horizontal, 7)
        .frame(minWidth: XunJianUI.controlHeight, minHeight: XunJianUI.controlHeight)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

// MARK: - Environment-aware modifiers

private struct XunJianAnimationModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let animation: Animation?
    let value: Value

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

private struct FloatingSurfaceModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    let cornerRadius: CGFloat
    let forceOpaque: Bool?

    func body(content: Content) -> some View {
        let usesOpaqueSurface = forceOpaque ?? reduceTransparency
        content
            .background {
                if usesOpaqueSurface {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(XunJianUI.Surface.raised)
                } else {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.regularMaterial)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        XunJianUI.Fill.stroke,
                        lineWidth: contrast == .increased ? 1.5 : 1
                    )
            }
            .shadow(
                color: usesOpaqueSurface ? .clear : XunJianUI.Shadow.floatingColor,
                radius: XunJianUI.Shadow.floatingRadius,
                y: XunJianUI.Shadow.floatingY
            )
    }
}

extension View {
    func xunjianAnimation<Value: Equatable>(
        _ animation: Animation? = XunJianUI.standardAnimation,
        value: Value
    ) -> some View {
        modifier(XunJianAnimationModifier(animation: animation, value: value))
    }

    func xunjianFloatingSurface(
        cornerRadius: CGFloat = XunJianUI.Radius.floating,
        forceOpaque: Bool? = nil
    ) -> some View {
        modifier(FloatingSurfaceModifier(cornerRadius: cornerRadius, forceOpaque: forceOpaque))
    }

    /// Keeps every AppKit-backed SwiftUI scroll container on the compact,
    /// overlay-style scroller used throughout XunJian. This is app-local and
    /// never changes the user's macOS scrollbar preference.
    func xunjianThinScrollers() -> some View {
        background(XunJianThinScrollerBridge())
    }
}

// MARK: - App-local scrollbar appearance

/// Leading, ungrouped title for file workspaces. The title never acquires
/// the shared glass background used by adjacent native toolbar buttons.
struct FileWorkspaceToolbarHeading: ToolbarContent {
    let title: String
    let id: String

    var body: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarItem(id: id + ".title", placement: .navigation) {
                Text(title).font(.headline).lineLimit(1)
            }
            .sharedBackgroundVisibility(.hidden)
        } else if #available(macOS 15, *) {
            ToolbarItem(id: id + ".title", placement: .navigation) {
                Text(title).font(.headline).lineLimit(1)
            }
        }
    }
}

@MainActor
enum XunJianScrollAppearance {
    static func apply(to scrollView: NSScrollView) {
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true

        for scroller in [scrollView.verticalScroller, scrollView.horizontalScroller].compactMap({ $0 }) {
            scroller.controlSize = .small
        }
    }

    static func applyRecursively(in rootView: NSView) {
        var pendingViews = [rootView]
        while let view = pendingViews.popLast() {
            if let scrollView = view as? NSScrollView {
                apply(to: scrollView)
                // A scroll view's document tree can contain thousands of
                // visible file cells but cannot contain another page scroller.
                continue
            }
            pendingViews.append(contentsOf: view.subviews)
        }
    }
}

private struct XunJianThinScrollerBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> XunJianThinScrollerHostView {
        XunJianThinScrollerHostView()
    }

    func updateNSView(_ nsView: XunJianThinScrollerHostView, context: Context) {
        nsView.scheduleApply()
    }
}

@MainActor
final class XunJianThinScrollerHostView: NSView {
    private var applyTask: Task<Void, Never>?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        if window != nil {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidBecomeKey(_:)),
                name: NSWindow.didBecomeKeyNotification,
                object: nil
            )
        }
        scheduleApply()
    }

    func scheduleApply() {
        scheduleApply(in: window)
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let targetWindow = notification.object as? NSWindow else { return }
        scheduleApply(in: targetWindow)
    }

    private func scheduleApply(in targetWindow: NSWindow?) {
        applyTask?.cancel()
        applyTask = Task { @MainActor [weak self, weak targetWindow] in
            await Task.yield()
            guard !Task.isCancelled,
                  self != nil,
                  let contentView = targetWindow?.contentView else { return }
            XunJianScrollAppearance.applyRecursively(in: contentView)
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
                .font(XunJianUI.Typography.pageTitle)
            if let subtitle, !subtitle.isEmpty {
                Text(verbatim: subtitle)
                    .font(compactSubtitle ? .caption : .subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(verbatim: title)
            .font(XunJianUI.Typography.sectionTitle)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

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

/// A restrained, opaque grouping surface for page-level introductions and
/// empty states. Unlike floating chrome it never uses blur or shadow.
struct InsetSurface<Content: View>: View {
    var padding: CGFloat = XunJianUI.Spacing.panel
    var usesAccentWash = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: XunJianUI.Radius.card, style: .continuous)
                    .fill(XunJianUI.Fill.quiet)
                    .overlay {
                        if usesAccentWash {
                            RoundedRectangle(
                                cornerRadius: XunJianUI.Radius.card,
                                style: .continuous
                            )
                            .fill(XunJianUI.Fill.accentWash)
                        }
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: XunJianUI.Radius.card, style: .continuous)
                    .strokeBorder(XunJianUI.Fill.stroke, lineWidth: 1)
            }
    }
}

struct InteractiveCardBackground: View {
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.controlActiveState) private var controlActiveState

    var isSelected = false
    var isHovered = false
    var cornerRadius: CGFloat = XunJianUI.Radius.card

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(fillColor)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        strokeColor,
                        style: StrokeStyle(
                            lineWidth: strokeWidth,
                            dash: isSelected && differentiateWithoutColor ? [4, 3] : []
                        )
                    )
            }
            .xunjianAnimation(XunJianUI.feedbackAnimation, value: isSelected)
            .xunjianAnimation(XunJianUI.feedbackAnimation, value: isHovered)
    }

    private var fillColor: Color {
        if isSelected {
            return controlActiveState == .key
                ? XunJianUI.Fill.selectedSoft
                : XunJianUI.Surface.inactiveSelection.opacity(0.42)
        }
        if isHovered { return XunJianUI.Fill.hover }
        return XunJianUI.Fill.quiet
    }

    private var strokeColor: Color {
        guard isSelected else { return .clear }
        return controlActiveState == .key
            ? XunJianUI.Fill.strokeSelected
            : Color.secondary.opacity(0.5)
    }

    private var strokeWidth: CGFloat {
        guard isSelected else { return 1 }
        return contrast == .increased || differentiateWithoutColor ? 2 : 1
    }
}

struct SoftCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressFeedback(isPressed: configuration.isPressed) {
            configuration.label
        }
    }

    private struct PressFeedback<Label: View>: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        let isPressed: Bool
        @ViewBuilder var label: () -> Label

        var body: some View {
            label()
                .opacity(isPressed ? 0.9 : 1)
                .scaleEffect(isPressed && !reduceMotion ? 0.985 : 1)
                .xunjianAnimation(XunJianUI.feedbackAnimation, value: isPressed)
        }
    }
}

struct ErrorMessageRow: View {
    let message: String

    var body: some View {
        Label {
            Text(verbatim: AppLanguage.localizedRuntimeMessage(message))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .accessibilityHidden(true)
        }
        .font(XunJianUI.Typography.status)
        .foregroundStyle(XunJianUI.Semantic.danger)
        .accessibilityElement(children: .combine)
    }
}
