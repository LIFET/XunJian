import AppKit
import SwiftUI

enum MenuBarSearchPreference {
    static let storageKey = "menuBar.quickSearchEnabled"
}

/// Menu bar quick search (N13).
///
/// Filters the already-loaded index in memory so the popover can be used
/// without activating — or even having opened — the main window. It never
/// touches the database or triggers a scan.
struct MenuBarSearchView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.openWindow) private var openWindow

    @State private var query = ""
    @FocusState private var isFieldFocused: Bool

    private static let maximumResults = 8

    private var results: [IndexedFile] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Array(appModel.recentFiles.prefix(Self.maximumResults))
        }
        return Array(
            appModel.files
                .lazy
                .filter { CommandPaletteView.matches($0.name, query: trimmed) }
                .prefix(Self.maximumResults)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchRow
            Divider()

            if results.isEmpty {
                Text(verbatim: emptyMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 16)
            } else {
                resultList
            }

            Divider()
            footer
        }
        .frame(width: 340)
        .onAppear { isFieldFocused = true }
    }

    private var searchRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            TextField(
                "",
                text: $query,
                prompt: Text(verbatim: AppLanguage.localized(
                    "快速查找文件…",
                    english: "Find files…"
                ))
            )
            .textFieldStyle(.plain)
            .focused($isFieldFocused)
            .onSubmit {
                if let first = results.first { open(first) }
            }
            .accessibilityLabel(Text(verbatim: AppLanguage.localized(
                "快速查找文件",
                english: "Find Files"
            )))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var emptyMessage: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? AppLanguage.localized(
                "还没有索引任何文件。",
                english: "No files have been indexed yet."
            )
            : AppLanguage.localized("没有匹配的文件", english: "No matching files")
    }

    private var resultList: some View {
        VStack(spacing: 0) {
            ForEach(results) { file in
                Button {
                    open(file)
                } label: {
                    HStack(spacing: 9) {
                        FileThumbnail(file: file, size: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: file.name)
                                .lineLimit(1)
                            Text(verbatim: file.parentPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: AppLanguage.localized(
                    "打开“\(file.name)”",
                    english: "Open “\(file.name)”"
                )))
            }
        }
        .padding(.vertical, 4)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(AppLanguage.localized("打开寻简", english: "Open XunJian")) {
                activateMainWindow()
            }
            Spacer(minLength: 0)
            Button(AppLanguage.localized("退出", english: "Quit")) {
                NSApplication.shared.terminate(nil)
            }
        }
        .buttonStyle(.link)
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func open(_ file: IndexedFile) {
        appModel.selectedFileID = file.id
        appModel.open(file)
        query = ""
    }

    /// Brings the existing main window forward rather than creating another
    /// one; the app is single-window by design.
    private func activateMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        for window in NSApplication.shared.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            return
        }
    }
}
