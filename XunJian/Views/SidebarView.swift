import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.openSettings) private var openSettings
    @Binding var selection: NavigationDestination?
    let categories: [FileCategory]

    @State private var searchToRename: SavedSearch?
    @State private var renameDraft = ""
    @State private var dropTargetCategoryID: UUID?

    var body: some View {
        List(selection: $selection) {
            Section {
                navigationRow(
                    Text(AppLanguage.localized("首页", english: "Home")),
                    symbol: "house",
                    destination: .home
                )
                navigationRow(
                    Text(AppLanguage.localized("所有文件", english: "All Files")),
                    symbol: "tray.full",
                    destination: .allFiles
                )
            }

            if !appModel.savedSearches.isEmpty {
                Section(AppLanguage.localized("保存的搜索", english: "Saved Searches")) {
                    ForEach(appModel.savedSearches) { search in
                        Button {
                            appModel.applySavedSearch(search)
                            selection = .allFiles
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 6) {
                                        Text(verbatim: search.name)
                                            .lineLimit(1)
                                        if isCurrentSavedSearch(search) {
                                            Image(systemName: "checkmark")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(Color.accentColor)
                                                .accessibilityLabel(AppLanguage.localized(
                                                    "当前条件",
                                                    english: "Current filters"
                                                ))
                                        }
                                    }
                                    Text(verbatim: search.conditionSummary(
                                        usesEnglish: AppLanguage.selected.usesEnglish
                                    ))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                }
                            } icon: {
                                Image(systemName: "clock.arrow.circlepath")
                                    .symbolRenderingMode(.hierarchical)
                            }
                        }
                        .buttonStyle(.plain)
                        .help(search.conditionSummary(usesEnglish: AppLanguage.selected.usesEnglish))
                        .contextMenu {
                            Button(AppLanguage.localized("重命名…", english: "Rename…")) {
                                searchToRename = search
                                renameDraft = search.name
                            }
                            Button(AppLanguage.localized(
                                "用当前条件更新",
                                english: "Update with Current Filters"
                            )) {
                                appModel.updateSavedSearch(search)
                            }
                            Divider()
                            Button(
                                AppLanguage.localized("删除保存的搜索", english: "Delete Saved Search"),
                                role: .destructive
                            ) {
                                appModel.deleteSearch(id: search.id)
                            }
                        }
                    }
                }
            }

            Section(AppLanguage.localized("分类", english: "Categories")) {
                navigationRow(
                    Text(AppLanguage.localized("全部分类", english: "All Categories")),
                    symbol: "square.grid.2x2",
                    destination: .categories
                )

                ForEach(categories) { category in
                    navigationRow(
                        Text(verbatim: category.name),
                        symbol: category.symbolName,
                        destination: .category(category.id)
                    )
                    // Drop a file onto a category to file it there (F06).
                    .dropDestination(for: URL.self) { urls, _ in
                        for url in urls {
                            appModel.assignDroppedFile(url: url, to: category)
                        }
                        return true
                    } isTargeted: { targeted in
                        dropTargetCategoryID = targeted ? category.id : nil
                    }
                    .listRowBackground(
                        dropTargetCategoryID == category.id
                            ? XunJianUI.Fill.selectedSoft
                            : Color.clear
                    )
                }
            }

            Section {
                Button {
                    openSettings()
                } label: {
                    Label(
                        AppLanguage.localized("设置", english: "Settings"),
                        systemImage: "gearshape"
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(AppLanguage.localized("寻简", english: "XunJian"))
        .alert(
            AppLanguage.localized("重命名保存的搜索", english: "Rename Saved Search"),
            isPresented: Binding(
                get: { searchToRename != nil },
                set: { if !$0 { searchToRename = nil } }
            )
        ) {
            TextField(
                AppLanguage.localized("名称", english: "Name"),
                text: $renameDraft
            )
            Button(AppLanguage.localized("保存", english: "Save")) {
                if let searchToRename {
                    appModel.renameSavedSearch(searchToRename, to: renameDraft)
                }
                searchToRename = nil
            }
            .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button(AppLanguage.localized("取消", english: "Cancel"), role: .cancel) {
                searchToRename = nil
            }
        }
    }

    private func navigationRow(
        _ title: Text,
        symbol: String,
        destination: NavigationDestination
    ) -> some View {
        Label {
            title
        } icon: {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
        }
        .tag(destination)
    }

    private func isCurrentSavedSearch(_ search: SavedSearch) -> Bool {
        search.matches(
            query: appModel.searchText,
            minSizeBytes: Int64(appModel.filterMinSizeMB * 1_024 * 1_024),
            minDate: appModel.filterMinDate > 0
                ? Date(timeIntervalSince1970: appModel.filterMinDate)
                : nil
        )
    }
}
