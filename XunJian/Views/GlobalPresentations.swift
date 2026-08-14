import SwiftUI

/// Hosts the app-wide overlays and sheets that are triggered from the menu bar
/// or the command palette: palette, storage insights, text preview, export.
///
/// These live in one modifier rather than inline in `AppShellView` for two
/// reasons: that view's modifier chain had grown past what the Swift type
/// checker can resolve, and keeping them together makes it obvious where
/// notification-driven presentation is handled.
struct GlobalPresentations: ViewModifier {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.locale) private var locale

    @Binding var selection: NavigationDestination?

    @State private var showsCommandPalette = false
    @State private var showsStorageInsights = false
    @State private var textPreviewFile: IndexedFile?

    func body(content: Content) -> some View {
        content
            .modifier(CommandPalettePresentation(
                selection: $selection,
                isPresented: $showsCommandPalette
            ))
            .modifier(StorageInsightsPresentation(isPresented: $showsStorageInsights))
            .modifier(TextPreviewPresentation(file: $textPreviewFile))
            .onReceive(NotificationCenter.default.publisher(for: .xunJianExportFileList)) { note in
                guard let raw = note.object as? String,
                      let format = FileListExport.Format(rawValue: raw) else { return }
                FileListExport.run(appModel: appModel, format: format)
            }
    }
}

private struct CommandPalettePresentation: ViewModifier {
    @Environment(\.locale) private var locale
    @Binding var selection: NavigationDestination?
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .xunJianShowCommandPalette)) { _ in
                isPresented = true
            }
            .overlay {
                if isPresented {
                    CommandPaletteView(isPresented: $isPresented, selection: $selection)
                        .environment(\.locale, locale)
                        .transition(
                            .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
                        )
                }
            }
            .xunjianAnimation(XunJianUI.overlayAnimation, value: isPresented)
    }
}

private struct StorageInsightsPresentation: ViewModifier {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.locale) private var locale
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .xunJianShowStorageInsights)) { _ in
                isPresented = true
            }
            .sheet(isPresented: $isPresented) {
                StorageInsightsView()
                    .environmentObject(appModel)
                    .environment(\.locale, locale)
            }
    }
}

private struct TextPreviewPresentation: ViewModifier {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.locale) private var locale
    @Binding var file: IndexedFile?

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .xunJianShowTextPreview)) { _ in
                // Silently ignored when nothing is selected; the palette only
                // offers this command when there is a target.
                file = appModel.selectedFile
            }
            .sheet(item: $file) { previewed in
                TextPreviewView(file: previewed, initialQuery: appModel.searchText)
                    .environmentObject(appModel)
                    .environment(\.locale, locale)
            }
    }
}
