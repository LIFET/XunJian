import Foundation

enum NavigationDestination: Hashable, Sendable {
    case home
    case allFiles
    case categories
    case category(UUID)
    case settings

    func title(categories: [FileCategory]) -> String {
        switch self {
        case .home:
            AppLanguage.localized("最近", english: "Recent")
        case .allFiles:
            AppLanguage.localized("查找", english: "Search")
        case .categories:
            AppLanguage.localized("资料集", english: "Collections")
        case let .category(categoryID):
            categories.first(where: { $0.id == categoryID })?.localizedDisplayName
                ?? AppLanguage.localized("分类", english: "Categories")
        case .settings:
            AppLanguage.localized("设置", english: "Settings")
        }
    }
}
