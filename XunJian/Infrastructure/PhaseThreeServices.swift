import AppKit
import Foundation
import Quartz
import QuickLookThumbnailing
import SwiftUI

enum FileOperationError: LocalizedError, Equatable, Sendable {
    case fileNotFound
    case invalidName
    case notWritable
    case destinationExists(String)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound:
            "文件已经不存在，索引将在重新扫描后更新。"
        case .invalidName:
            "文件名不能为空，也不能包含“/”或“:”。"
        case .notWritable:
            "当前位置不可写，无法完成这个文件操作。"
        case let .destinationExists(name):
            "目标位置已经存在“\(name)”，请换一个名称或位置。"
        case let .operationFailed(message):
            "文件操作失败：\(message)"
        }
    }
}

actor FileOperationService {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func rename(fileAt sourceURL: URL, to proposedName: String) throws -> URL {
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw FileOperationError.fileNotFound
        }

        let newName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty,
              newName != ".",
              newName != "..",
              !newName.contains("/"),
              !newName.contains(":") else {
            throw FileOperationError.invalidName
        }

        guard fileManager.isWritableFile(atPath: sourceURL.deletingLastPathComponent().path) else {
            throw FileOperationError.notWritable
        }

        let destinationURL = sourceURL.deletingLastPathComponent().appendingPathComponent(newName)
        if destinationURL.standardizedFileURL == sourceURL.standardizedFileURL {
            return sourceURL
        }
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw FileOperationError.destinationExists(newName)
        }

        do {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
            return destinationURL
        } catch {
            throw FileOperationError.operationFailed(error.localizedDescription)
        }
    }

    func move(fileAt sourceURL: URL, to destinationDirectory: URL) throws -> URL {
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw FileOperationError.fileNotFound
        }
        guard fileManager.isWritableFile(atPath: destinationDirectory.path) else {
            throw FileOperationError.notWritable
        }

        let destinationURL = destinationDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        if destinationURL.standardizedFileURL == sourceURL.standardizedFileURL {
            return sourceURL
        }
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw FileOperationError.destinationExists(sourceURL.lastPathComponent)
        }

        do {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
            return destinationURL
        } catch {
            throw FileOperationError.operationFailed(error.localizedDescription)
        }
    }

    func moveToTrash(fileAt sourceURL: URL) throws -> URL? {
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw FileOperationError.fileNotFound
        }
        guard fileManager.isWritableFile(atPath: sourceURL.deletingLastPathComponent().path) else {
            throw FileOperationError.notWritable
        }

        var resultingURL: NSURL?
        do {
            try fileManager.trashItem(at: sourceURL, resultingItemURL: &resultingURL)
            return resultingURL as URL?
        } catch {
            throw FileOperationError.operationFailed(error.localizedDescription)
        }
    }
}

@MainActor
final class QuickLookPresenter: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = QuickLookPresenter()

    private var previewURL: URL?

    func present(_ url: URL) {
        previewURL = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> any QLPreviewItem {
        (previewURL ?? URL(fileURLWithPath: "/")) as NSURL
    }
}

@MainActor
final class ThumbnailService {
    static let shared = ThumbnailService()

    private let cache = NSCache<NSString, NSImage>()

    func thumbnail(for file: IndexedFile, size: CGSize, scale: CGFloat) async -> NSImage? {
        let cacheKey = "\(file.id)-\(Int(size.width))-\(Int(size.height))" as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: file.url,
            size: size,
            scale: scale,
            representationTypes: .all
        )

        do {
            let representation = try await QLThumbnailGenerator.shared
                .generateBestRepresentation(for: request)
            let image = NSImage(cgImage: representation.cgImage, size: size)
            cache.setObject(image, forKey: cacheKey)
            return image
        } catch {
            return nil
        }
    }
}

struct FileThumbnail: View {
    let file: IndexedFile
    let size: CGFloat

    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: file.kind.symbolName)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.tint)
                    .padding(size * 0.16)
            }
        }
        .frame(width: size, height: size)
        .task(id: file.id) {
            thumbnail = await ThumbnailService.shared.thumbnail(
                for: file,
                size: CGSize(width: size, height: size),
                scale: displayScale
            )
        }
    }
}
