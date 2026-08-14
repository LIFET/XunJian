import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var appModel: AppModel
    @Binding var selection: NavigationDestination?
    let categories: [FileCategory]

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
                                Text(verbatim: search.name)
                            } icon: {
                                Image(systemName: "clock.arrow.circlepath")
                                    .symbolRenderingMode(.hierarchical)
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
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
                    }
                }
            }

            Section {
                navigationRow(
                    Text(AppLanguage.localized("设置", english: "Settings")),
                    symbol: "gearshape",
                    destination: .settings
                )
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(AppLanguage.localized("寻简", english: "XunJian"))
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
}
