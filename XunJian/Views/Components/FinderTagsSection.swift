import AppKit
import SwiftUI

/// Read-only display of the file's Finder tags (N17).
///
/// Deliberately read-only: Finder tags are system metadata the user manages
/// elsewhere, and writing them would mean modifying files the app promises
/// not to change on its own. XunJian's own categories stay separate.
struct FinderTagsSection: View {
    let file: IndexedFile

    @State private var tags: [FinderTag] = []
    @State private var hasLoaded = false

    var body: some View {
        // Nothing is rendered for untagged files so the inspector does not
        // grow an empty section for the common case.
        Group {
            if !tags.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: AppLanguage.localized(
                        "访达标签",
                        english: "Finder Tags"
                    ))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                    FlowingTags(tags: tags)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(verbatim: AppLanguage.localized(
                    "访达标签：\(tags.map(\.name).joined(separator: "、"))",
                    english: "Finder tags: \(tags.map(\.name).joined(separator: ", "))"
                )))
            }
        }
        .task(id: file.id) {
            hasLoaded = false
            tags = await FinderTag.tags(for: file.url)
            hasLoaded = true
        }
    }
}

private struct FlowingTags: View {
    let tags: [FinderTag]

    var body: some View {
        // Tag names can be long and the inspector is narrow, so they wrap
        // rather than truncate to a single row.
        WrappingHStack(items: tags) { tag in
            HStack(spacing: 5) {
                Circle()
                    .fill(tag.color ?? Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)
                Text(verbatim: tag.name)
                    .font(.caption)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                XunJianUI.Fill.quiet,
                in: Capsule()
            )
        }
    }
}

/// Minimal wrapping layout; `Layout` is used instead of nested stacks so the
/// rows reflow correctly when the inspector is resized.
private struct WrappingHStack<Item: Identifiable, Content: View>: View {
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items) { item in
                content(item)
            }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalWidth = max(totalWidth, rowWidth)
                totalHeight += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += rowWidth > 0 ? spacing + size.width : size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalWidth = max(totalWidth, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct FinderTag: Identifiable, Equatable, Sendable {
    let name: String
    let colorIndex: Int?

    var id: String { name }

    /// Finder's fixed label palette. Index 0 means "no colour", which renders
    /// as a neutral dot rather than an invisible one.
    var color: Color? {
        switch colorIndex {
        case 1: .gray
        case 2: .green
        case 3: .purple
        case 4: .blue
        case 5: .yellow
        case 6: .red
        case 7: .orange
        default: nil
        }
    }

    /// Reads tags off the main thread. Missing or unreadable metadata simply
    /// yields no tags — a file without access should not surface an error in
    /// the inspector.
    static func tags(for url: URL) async -> [FinderTag] {
        await Task.detached(priority: .utility) {
            guard let values = try? url.resourceValues(
                forKeys: [.tagNamesKey, .labelNumberKey]
            ), let names = values.tagNames else {
                return []
            }
            let labelNumber = values.labelNumber
            return names.map { name in
                // `labelNumber` describes the file's single colour label, so it
                // only applies when there is exactly one tag to attribute it to.
                FinderTag(
                    name: name,
                    colorIndex: names.count == 1 ? labelNumber : nil
                )
            }
        }.value
    }
}
