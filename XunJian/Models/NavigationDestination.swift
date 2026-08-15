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
            AppLanguage.localized("首页", english: "Home")
        case .allFiles:
            AppLanguage.localized("所有文件", english: "All Files")
        case .categories:
            AppLanguage.localized("分类", english: "Categories")
        case let .category(categoryID):
            categories.first(where: { $0.id == categoryID })?.localizedDisplayName
                ?? AppLanguage.localized("分类", english: "Categories")
        case .settings:
            AppLanguage.localized("设置", english: "Settings")
        }
    }
}

