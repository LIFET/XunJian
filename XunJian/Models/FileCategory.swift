import Foundation

struct FileCategory: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var symbolName: String
    let createdAt: Date

    init(
        id: UUID,
        name: String,
        symbolName: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.createdAt = createdAt
    }

    static let defaults: [FileCategory] = [
        FileCategory(id: UUID(uuidString: "B2D19E64-0184-4B30-9364-0C05DD2A2A01")!, name: "工作", symbolName: "briefcase"),
        FileCategory(id: UUID(uuidString: "B2D19E64-0184-4B30-9364-0C05DD2A2A02")!, name: "项目", symbolName: "folder"),
        FileCategory(id: UUID(uuidString: "B2D19E64-0184-4B30-9364-0C05DD2A2A03")!, name: "设计", symbolName: "paintbrush"),
        FileCategory(id: UUID(uuidString: "B2D19E64-0184-4B30-9364-0C05DD2A2A04")!, name: "资料", symbolName: "books.vertical"),
        FileCategory(id: UUID(uuidString: "B2D19E64-0184-4B30-9364-0C05DD2A2A05")!, name: "合同", symbolName: "doc.text"),
        FileCategory(id: UUID(uuidString: "B2D19E64-0184-4B30-9364-0C05DD2A2A06")!, name: "财务", symbolName: "banknote"),
        FileCategory(id: UUID(uuidString: "B2D19E64-0184-4B30-9364-0C05DD2A2A07")!, name: "个人", symbolName: "person"),
        FileCategory(id: UUID(uuidString: "B2D19E64-0184-4B30-9364-0C05DD2A2A08")!, name: "归档", symbolName: "archivebox")
    ]
}
