import SwiftUI

struct AISheetScaffold<Content: View, Actions: View>: View {
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
        VStack(alignment: .leading, spacing: XunJianUI.Spacing.pageCompact) {
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

            content()
            actions()
        }
        .padding(XunJianUI.Spacing.sheet)
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
