import SwiftUI

struct AISheetScaffold<Content: View, Actions: View>: View {
    @Environment(\.appVisualTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    var subtitle: String?
    var minWidth: CGFloat = 320
    var idealWidth: CGFloat = 560
    var maxWidth: CGFloat = 620
    var minHeight: CGFloat?
    var idealHeight: CGFloat?
    var maxHeight: CGFloat?
    @ViewBuilder var content: () -> Content
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: XunJianUI.Spacing.tight) {
                Text(verbatim: title)
                    .font(XunJianUI.Typography.sheetTitle)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle, !subtitle.isEmpty {
                    Text(verbatim: subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.palette(for: colorScheme).canvas)
            WorkspaceRowSeparator()
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            WorkspaceRowSeparator()
            actions()
                .controlSize(.large)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(theme.palette(for: colorScheme).surface)
        }
        .background(theme.palette(for: colorScheme).canvas)
        .frame(
            minWidth: minWidth,
            idealWidth: idealWidth,
            maxWidth: maxWidth,
            minHeight: minHeight,
            idealHeight: idealHeight,
            maxHeight: maxHeight,
            alignment: .leading
        )
    }
}
