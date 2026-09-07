import SwiftUI

enum AppVisualTheme: String, CaseIterable, Identifiable, Sendable {
    case precision
    case reading

    static let storageKey = "appVisualTheme"
    var id: String { rawValue }
    static func resolve(_ rawValue: String?) -> Self {
        rawValue.flatMap(Self.init(rawValue:)) ?? .reading
    }

    var title: String {
        switch self {
        case .precision:
            AppLanguage.localized("清晰", english: "Clarity")
        case .reading:
            AppLanguage.localized("柔和", english: "Soft")
        }
    }

    var summary: String {
        switch self {
        case .precision:
            AppLanguage.localized("中性底色与深青强调，清晰利落。", english: "Neutral surfaces with a crisp teal accent.")
        case .reading:
            AppLanguage.localized("柔和暖灰与低饱和强调，阅读更舒适。", english: "Soft warm grays with a subdued accent for comfortable reading.")
        }
    }

    var contentPadding: CGFloat { 16 }
    var previewFontSize: CGFloat { 15 }
    var rowVerticalPadding: CGFloat { 8 }

    func palette(for scheme: ColorScheme) -> ThemePalette {
        // Legacy persisted A/B values resolve to the same workspace design.
        // No preference migration or data reset is required.
        switch scheme {
        case .dark:
            ThemePalette(canvas: color(0x202123), surface: color(0x27282B), sidebar: color(0x232427), accent: color(0xECEDEF), selection: color(0x3B3D40))
        default:
            ThemePalette(canvas: color(0xFFFFFF), surface: color(0xF7F8FA), sidebar: color(0xF7F8FA), accent: color(0x202124), selection: color(0xECEDEE))
        }
    }

    private func color(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255,
              green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

struct ThemePalette {
    let canvas: Color
    let surface: Color
    let sidebar: Color
    let accent: Color
    let selection: Color
}

/// Text destinations in the native window toolbar; resources are auxiliary.
struct EditorialNavigationTabs: View {
    @Binding var selection: NavigationDestination?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var activeDestination

    var body: some View {
        HStack(spacing: 18) {
            destination(.allFiles, title: AppLanguage.localized("搜索", english: "Search"))
            destination(.categories, title: AppLanguage.localized("资料集", english: "Collections"))
            destination(.home, title: AppLanguage.localized("最近", english: "Recent"))
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: selection)
        .accessibilityElement(children: .contain)
    }

    private func destination(_ value: NavigationDestination, title: String) -> some View {
        let selected = AppShellView.workspaceMode(for: selection ?? .allFiles) == value
        return Button {
            selection = value
        } label: {
            Text(verbatim: title)
                .font(.system(size: 14, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 6).frame(height: 38)
                .overlay(alignment: .bottom) {
                    if selected {
                        Rectangle().fill(.primary).frame(height: 2)
                            .matchedGeometryEffect(id: "active", in: activeDestination)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier("workspace.destination.\(String(describing: value))")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct StudioPageHeading: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: title).font(.system(size: 24, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension EnvironmentValues {
    @Entry var appVisualTheme: AppVisualTheme = .reading
}

private struct AppVisualThemeModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let theme: AppVisualTheme

    func body(content: Content) -> some View {
        let palette = theme.palette(for: colorScheme)
        content
            .environment(\.appVisualTheme, theme)
            .tint(palette.accent)
            // 兼容现有 Color.accentColor 消费者，不修改 macOS 系统强调色。
            .accentColor(palette.accent)
    }
}

extension View {
    func xunjianVisualTheme(_ theme: AppVisualTheme) -> some View {
        modifier(AppVisualThemeModifier(theme: theme))
    }
}
