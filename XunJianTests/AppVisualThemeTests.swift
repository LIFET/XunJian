import XCTest
import SwiftUI
import AppKit
@testable import XunJian

final class AppVisualThemeTests: XCTestCase {
    @MainActor
    func testWorkspaceSeparatorStaysHorizontalInHorizontalContainers() {
        // The category's old overlay inherited HStack's axis and drew a vertical
        // rule through the directory. The shared rule must own its thickness.
        for width: CGFloat in [280, 840] {
            let view = NSHostingView(rootView: HStack(spacing: 0) {
                WorkspaceRowSeparator()
            }.frame(width: width))
            XCTAssertEqual(view.fittingSize.width, width, accuracy: 1)
            XCTAssertLessThanOrEqual(view.fittingSize.height, 1)
        }
    }

    @MainActor
    func testIconTargetsKeepTheirSizeAcrossThemesAndControlSizes() {
        for theme in AppVisualTheme.allCases {
            for controlSize in [ControlSize.small, .regular] {
                let view = NSHostingView(rootView:
                    Button {} label: { Image(systemName: "sidebar.left") }
                        .buttonStyle(XunJianIconButtonStyle())
                        .controlSize(controlSize)
                        .xunjianVisualTheme(theme)
                )
                XCTAssertGreaterThanOrEqual(view.fittingSize.width, 34)
                XCTAssertGreaterThanOrEqual(view.fittingSize.height, 34)
            }
        }
    }

    @MainActor
    func testIconOnlyMenusHaveRealTargetsEvenWithoutText() {
        let view = NSHostingView(rootView:
            XunJianToolbarLabel(title: "类型", systemImage: "doc", showsTitle: false, showsChevron: true)
        )
        XCTAssertGreaterThanOrEqual(view.fittingSize.width, 34)
        XCTAssertGreaterThanOrEqual(view.fittingSize.height, 34)
    }

    func testThemesSuggestNativeInspectorWidthWithoutWindowGeometryPolling() {
        XCTAssertEqual(WorkspaceSplitProportions.idealInspectorWidth(for: .precision), 1_000)
        XCTAssertEqual(WorkspaceSplitProportions.idealInspectorWidth(for: .reading), 1_000)
    }
    @MainActor
    func testGridNavigationMatchesPaddedAdaptiveGridAtBoundary() {
        XCTAssertEqual(FileGridCard.columnCount(forWidth: 440), 2)
        XCTAssertEqual(FileGridCard.columnCount(forWidth: 455), 2)
        XCTAssertEqual(FileGridCard.columnCount(forWidth: 456), 3)
        XCTAssertEqual(FileGridCard.columnCount(forWidth: 280), 1)
        XCTAssertEqual(FileGridCard.columnCount(forWidth: 610), 3)
        XCTAssertEqual(FileGridCard.columnCount(forWidth: 617), 3)
        XCTAssertEqual(FileGridCard.columnCount(forWidth: 618), 4)
    }
    func testMissingAndUnknownValuesUseReadingWithoutRewritingPreferences() throws {
        XCTAssertEqual(AppVisualTheme.resolve(nil), .reading)
        XCTAssertEqual(AppVisualTheme.resolve(""), .reading)
        XCTAssertEqual(AppVisualTheme.resolve("retired-theme"), .reading)
    }

    func testBothStableIdentifiersRoundTrip() {
        XCTAssertEqual(AppVisualTheme.allCases.map(\.id), ["precision", "reading"])
        for theme in AppVisualTheme.allCases {
            XCTAssertEqual(AppVisualTheme.resolve(theme.rawValue), theme)
        }
    }

    func testThemePreferenceRestoresIndependentlyOfAppearanceAndBrowsing() throws {
        let suite = "AppVisualThemeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let existing: [String: String] = [
            "appAppearance": "dark", "appLanguage": "en",
            "allFiles.sortOrder": "modifiedAt", "allFiles.viewMode": "grid"
        ]
        for (key, value) in existing { defaults.set(value, forKey: key) }
        defaults.set("retired-theme", forKey: AppVisualTheme.storageKey)
        XCTAssertEqual(AppVisualTheme.resolve(defaults.string(forKey: AppVisualTheme.storageKey)), .reading)
        XCTAssertEqual(defaults.string(forKey: AppVisualTheme.storageKey), "retired-theme")
        for theme in AppVisualTheme.allCases {
            defaults.set(theme.rawValue, forKey: AppVisualTheme.storageKey)
            let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
            XCTAssertEqual(AppVisualTheme.resolve(reopened.string(forKey: AppVisualTheme.storageKey)), theme)
            for (key, value) in existing { XCTAssertEqual(reopened.string(forKey: key), value) }
        }
    }

    func testLegacyThemeValuesShareTheNewWorkspaceGeometry() {
        XCTAssertEqual(AppVisualTheme.precision.contentPadding, 16)
        XCTAssertEqual(AppVisualTheme.reading.contentPadding, AppVisualTheme.precision.contentPadding)
        XCTAssertEqual(AppVisualTheme.precision.previewFontSize, 15)
        XCTAssertEqual(AppVisualTheme.reading.previewFontSize, 15)
        XCTAssertEqual(AppVisualTheme.precision.rowVerticalPadding, 8)
        XCTAssertEqual(AppVisualTheme.reading.rowVerticalPadding, 8)
    }

    func testLegacyPalettesConvergeWhileContentAdaptsToAppearance() {
        for scheme in [ColorScheme.light, .dark] {
            let precision = AppVisualTheme.precision.palette(for: scheme)
            let reading = AppVisualTheme.reading.palette(for: scheme)
            XCTAssertEqual(precision.canvas, reading.canvas)
            XCTAssertEqual(precision.accent, reading.accent)
            XCTAssertEqual(precision.selection, reading.selection)
        }
        for theme in AppVisualTheme.allCases {
            let light = theme.palette(for: .light)
            let dark = theme.palette(for: .dark)
            XCTAssertNotEqual(light.canvas, dark.canvas)
            XCTAssertNotEqual(light.surface, dark.surface)
            XCTAssertNotEqual(light.sidebar, dark.sidebar, "按需目录与内容共同适配系统明暗")
            XCTAssertNotEqual(light.accent, dark.accent)
            XCTAssertNotEqual(light.selection, dark.selection)
        }
    }

    func testEnvironmentDefaultsToReading() {
        XCTAssertEqual(EnvironmentValues().appVisualTheme, .reading)
    }

    @MainActor
    func testThemeInvalidatesSnapshotPresentationWithoutChangingDataIdentity() {
        func snapshot(_ theme: AppVisualTheme) -> EquatableSnapshotList<EmptyView> {
            EquatableSnapshotList(
                signature: 42, viewMode: .list, selectionEpoch: 3,
                metadataEpoch: 4, layoutToken: 640, presentationToken: theme.rawValue
            ) { EmptyView() }
        }
        let original = snapshot(.reading)
        XCTAssertEqual(original, snapshot(.reading))
        XCTAssertNotEqual(original, snapshot(.precision))
        XCTAssertEqual(original.signature, snapshot(.precision).signature)
        XCTAssertEqual(original.selectionEpoch, snapshot(.precision).selectionEpoch)
    }

    @MainActor
    func testAppStorageSynchronizesHostedRootsAndRestoresThemeWithoutResettingViewState() async throws {
        let suite = "AppVisualThemeHostingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set("dark", forKey: "appAppearance")
        let firstObservation = ThemeHostingObservation()
        let secondObservation = ThemeHostingObservation()
        var windows: [NSWindow] = []
        defer {
            firstObservation.chooseTheme = nil
            secondObservation.chooseTheme = nil
            for window in windows {
                window.contentView = nil
                window.close()
            }
            defaults.removePersistentDomain(forName: suite)
        }

        func host(_ observation: ThemeHostingObservation, store: UserDefaults) -> NSWindow {
            let view = NSHostingView(rootView: ThemeHostingRoot(observation: observation).defaultAppStorage(store))
            let window = NSWindow(
                contentRect: NSRect(x: -10_000, y: -10_000, width: 240, height: 160),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            windows.append(window)
            return window
        }

        _ = host(firstObservation, store: defaults)
        _ = host(secondObservation, store: defaults)
        try await waitForThemeHosting(windows: windows) {
            firstObservation.snapshot?.theme == .reading && secondObservation.snapshot?.theme == .reading
        }
        let firstInitial = try XCTUnwrap(firstObservation.snapshot)
        let secondInitial = try XCTUnwrap(secondObservation.snapshot)
        let select = try XCTUnwrap(firstObservation.chooseTheme)
        select(.precision)

        try await waitForThemeHosting(windows: windows) {
            firstObservation.snapshot?.theme == .precision && secondObservation.snapshot?.theme == .precision
        }
        XCTAssertEqual(defaults.string(forKey: AppVisualTheme.storageKey), AppVisualTheme.precision.rawValue)
        for (observation, original) in [(firstObservation, firstInitial), (secondObservation, secondInitial)] {
            let current = try XCTUnwrap(observation.snapshot)
            XCTAssertEqual(current.viewIdentity, original.viewIdentity)
            XCTAssertEqual(current.query, original.query)
            XCTAssertEqual(current.selection, original.selection)
            XCTAssertEqual(current.appearance, "dark")
            XCTAssertEqual(current.colorScheme, .dark)
        }

        // 销毁第一棵真实 SwiftUI 根，再用重新打开的隔离偏好创建新根。
        firstObservation.chooseTheme = nil
        windows[0].contentView = nil
        windows[0].close()
        let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
        let restoredObservation = ThemeHostingObservation()
        defer { restoredObservation.chooseTheme = nil }
        _ = host(restoredObservation, store: reopened)
        try await waitForThemeHosting(windows: windows) {
            restoredObservation.snapshot?.theme == .precision
        }
        let restored = try XCTUnwrap(restoredObservation.snapshot)
        XCTAssertNotEqual(restored.viewIdentity, firstInitial.viewIdentity)
        XCTAssertEqual(restored.query, firstInitial.query)
        XCTAssertEqual(restored.selection, firstInitial.selection)
        XCTAssertEqual(restored.appearance, "dark")
        XCTAssertEqual(restored.colorScheme, .dark)
        XCTAssertEqual(reopened.string(forKey: "appAppearance"), "dark")
    }
}

@MainActor
private func waitForThemeHosting(
    windows: [NSWindow],
    file: StaticString = #filePath,
    line: UInt = #line,
    condition: () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
        for window in windows { window.contentView?.layoutSubtreeIfNeeded() }
        if condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("SwiftUI 主题环境未在 3 秒内同步到托管根", file: file, line: line)
}

@MainActor
private final class ThemeHostingObservation {
    struct Snapshot {
        let theme: AppVisualTheme
        let colorScheme: ColorScheme
        let appearance: String
        let query: String
        let selection: String
        let viewIdentity: UUID
    }
    var snapshot: Snapshot?
    var chooseTheme: ((AppVisualTheme) -> Void)?
}

private struct ThemeHostingRoot: View {
    @AppStorage(AppVisualTheme.storageKey) private var rawTheme = AppVisualTheme.reading.rawValue
    @AppStorage("appAppearance") private var appearance = "system"
    @State private var query = "保留当前检索"
    @State private var selection = "selected-fixture-file"
    @State private var viewIdentity = UUID()
    let observation: ThemeHostingObservation

    var body: some View {
        ThemeHostingProbe(
            observation: observation, appearance: appearance,
            query: query, selection: selection, viewIdentity: viewIdentity,
            chooseTheme: { rawTheme = $0.rawValue }
        )
        .xunjianVisualTheme(AppVisualTheme.resolve(rawTheme))
        .environment(\.colorScheme, appearance == "dark" ? .dark : .light)
    }
}

private struct ThemeHostingProbe: NSViewRepresentable {
    @Environment(\.appVisualTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    let observation: ThemeHostingObservation
    let appearance: String
    let query: String
    let selection: String
    let viewIdentity: UUID
    let chooseTheme: (AppVisualTheme) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        observation.snapshot = .init(
            theme: theme, colorScheme: colorScheme, appearance: appearance,
            query: query, selection: selection, viewIdentity: viewIdentity
        )
        observation.chooseTheme = chooseTheme
    }
}
