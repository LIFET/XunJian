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

    static func pagePadding(for width: CGFloat) -> CGFloat {
        width < 520 ? Spacing.pageCompact : Spacing.page
    }
}

// MARK: - Search field

struct SearchField: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isFocused ? Color.accentColor : Color.secondary)
                .frame(width: 16)

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
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                        .frame(width: 28, height: 28)
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
        .frame(height: 36)
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
