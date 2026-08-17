#if DEBUG
import SwiftUI

private struct DesignSystemStatePreview: View {
    let selected: Bool
    var forceOpaqueSurface = false

    var body: some View {
        VStack(alignment: .leading, spacing: XunJianUI.Spacing.section) {
            PageHeader(
                title: AppLanguage.localized("设计系统", english: "Design System"),
                subtitle: AppLanguage.localized(
                    "语义表面、排版与交互状态",
                    english: "Semantic surfaces, typography, and interaction states"
                )
            )

            SectionHeader(title: AppLanguage.localized("卡片状态", english: "Card States"))
            HStack(spacing: XunJianUI.Spacing.sectionInner) {
                previewCard(title: AppLanguage.localized("默认", english: "Default"))
                previewCard(
                    title: AppLanguage.localized("已选择", english: "Selected"),
                    selected: selected
                )
            }

            VStack(alignment: .leading, spacing: XunJianUI.Spacing.row) {
                Label("Verified", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(XunJianUI.Semantic.success)
                Label("Needs attention", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(XunJianUI.Semantic.warning)
                Label("Unavailable", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(XunJianUI.Semantic.danger)
            }
            .font(XunJianUI.Typography.status)

            Text("Floating Surface")
                .padding(XunJianUI.Spacing.pageCompact)
                .xunjianFloatingSurface(forceOpaque: forceOpaqueSurface)
        }
        .padding(XunJianUI.Spacing.page)
        .frame(width: 620)
        .background(XunJianUI.Surface.canvas)
    }

    private func previewCard(title: String, selected: Bool = false) -> some View {
        Text(verbatim: title)
            .font(XunJianUI.Typography.itemTitle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(XunJianUI.Spacing.sectionInner)
            .background {
                InteractiveCardBackground(isSelected: selected)
            }
    }
}

#Preview("Design System - Light") {
    DesignSystemStatePreview(selected: true)
}

#Preview("Design System - Dark and Opaque") {
    DesignSystemStatePreview(selected: true, forceOpaqueSurface: true)
        .preferredColorScheme(.dark)
}
#endif
