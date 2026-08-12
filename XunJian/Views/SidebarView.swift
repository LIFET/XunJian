import SwiftUI

struct SidebarView: View {
    @Binding var selection: NavigationDestination?
    let categories: [FileCategory]

    var body: some View {
        List(selection: $selection) {
            Section {
                navigationRow(Text("首页"), symbol: "house", destination: .home)
                navigationRow(Text("所有文件"), symbol: "tray.full", destination: .allFiles)
            }

            Section("分类") {
                navigationRow(Text("全部分类"), symbol: "square.grid.2x2", destination: .categories)

                ForEach(categories) { category in
                    navigationRow(
                        Text(verbatim: category.name),
                        symbol: category.symbolName,
                        destination: .category(category.id)
                    )
                }
            }

            Section {
                navigationRow(Text("设置"), symbol: "gearshape", destination: .settings)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("寻简")
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
