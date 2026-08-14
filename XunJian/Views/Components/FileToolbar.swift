import SwiftUI

/// Layout constants for the file toolbar (F10). Text-sensitive sizes live on
/// the components themselves as `@ScaledMetric` so they grow with the user's
/// text size setting (F03); pure layout values stay here.
enum FileToolbarMetrics {
    static let controlHeight: CGFloat = 32
    static let iconButtonSide: CGFloat = 32
    static let symbolSize: CGFloat = 14
    static let regularSpacing: CGFloat = 8
    static let compactSpacing: CGFloat = 6
    static let fileTypeWidth: CGFloat = 112
    static func sortWidth(for order: FileSortOrder) -> CGFloat {
        if AppLanguage.selected.usesEnglish,
           order == .modifiedAt || order == .createdAt {
            return 128
        }
        return 104
    }
    static let viewModeWidth: CGFloat = 72
    static let viewModeItemWidth: CGFloat = 35
    static let cornerRadius: CGFloat = 6
    static let innerCornerRadius: CGFloat = 5
    static let controlFill = XunJianUI.Fill.control
}

private struct FileToolbarSurface: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(
                isHovered ? XunJianUI.Fill.hover : FileToolbarMetrics.controlFill,
                in: RoundedRectangle(
                    cornerRadius: FileToolbarMetrics.cornerRadius,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: FileToolbarMetrics.cornerRadius,
                    style: .continuous
                )
                .strokeBorder(isHovered ? XunJianUI.Fill.stroke : .clear)
            }
            .onHover { isHovered = $0 }
    }
}

extension View {
    func fileToolbarSurface() -> some View {
        modifier(FileToolbarSurface())
    }
}

struct FileToolbarIconLabel: View {
    let systemName: String

    @ScaledMetric(relativeTo: .body) private var symbolSize = FileToolbarMetrics.symbolSize
    @ScaledMetric(relativeTo: .body) private var side = FileToolbarMetrics.iconButtonSide

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: symbolSize, weight: .medium))
            .frame(width: side, height: side)
            .fileToolbarSurface()
            .contentShape(Rectangle())
    }
}

struct FileToolbarMenuLabel: View {
    let title: String
    let systemName: String

    @ScaledMetric(relativeTo: .body) private var symbolSize = FileToolbarMetrics.symbolSize
    @ScaledMetric(relativeTo: .body) private var controlHeight = FileToolbarMetrics.controlHeight

    var body: some View {
        Label {
            Text(verbatim: title)
                .lineLimit(1)
        } icon: {
            Image(systemName: systemName)
                .font(.system(size: symbolSize, weight: .medium))
        }
        .padding(.horizontal, 10)
        .frame(height: controlHeight)
        .fileToolbarSurface()
        .contentShape(Rectangle())
    }
}

struct FileToolbarPopupLabel: View {
    let title: String
    let width: CGFloat

    @ScaledMetric(relativeTo: .body) private var symbolSize = FileToolbarMetrics.symbolSize
    @ScaledMetric(relativeTo: .body) private var controlHeight = FileToolbarMetrics.controlHeight

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: title)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: symbolSize, weight: .semibold))
        }
        .padding(.horizontal, 10)
        .frame(width: width, height: controlHeight)
        .fileToolbarSurface()
        .contentShape(Rectangle())
    }
}
