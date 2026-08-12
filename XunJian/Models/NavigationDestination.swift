import Foundation

enum NavigationDestination: Hashable, Sendable {
    case home
    case allFiles
    case categories
    case category(UUID)
    case settings

    func title(categories: [FileCategory]) -> String {
        switch self {
        case .home: "首页"
        case .allFiles: "所有文件"
        case .categories: "分类"
        case let .category(categoryID):
            categories.first(where: { $0.id == categoryID })?.name ?? "分类"
        case .settings: "设置"
        }
    }
}

