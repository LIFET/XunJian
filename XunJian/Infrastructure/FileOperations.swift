import AppKit
import Darwin
import Foundation
import Quartz
import QuickLookThumbnailing
import SwiftUI

enum FileOperationError: LocalizedError, Equatable, Sendable {
    case fileNotFound
    case invalidName
    case notWritable
    case destinationExists(String)
    case fileIdentityChanged
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound:
            AppLanguage.localized("文件已经不存在，索引将在重新扫描后更新。", english: "The file no longer exists. The index will update after a rescan.")
        case .invalidName:
            AppLanguage.localized("文件名不能为空，也不能包含“/”或“:”。", english: "The file name cannot be empty or contain “/” or “:”.")
        case .notWritable:
            AppLanguage.localized("当前位置不可写，无法完成这个文件操作。", english: "This location is not writable.")
        case let .destinationExists(name):
            AppLanguage.localized("目标位置已经存在“\(name)”，请换一个名称或位置。", english: "“\(name)” already exists at the destination. Choose another name or location.")
        case .fileIdentityChanged:
            AppLanguage.localized("文件已经被其他操作替换，已停止操作以避免修改错误的文件。", english: "The file was replaced by another process. The operation was stopped to avoid modifying the wrong file.")
        case let .operationFailed(message):
            AppLanguage.localized("文件操作失败：\(message)", english: "File operation failed: \(message)")
        }
    }
}

/// Stable identity of one filesystem object. Paths alone are insufficient for
/// undo because another process can replace the item at the same path.
struct FileSystemObjectIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let fileType: UInt32
}

actor FileOperationService {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func identity(of url: URL) throws -> FileSystemObjectIdentity {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw FileOperationError.fileNotFound
        }
        return FileSystemObjectIdentity(
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            fileType: UInt32(metadata.st_mode) & UInt32(S_IFMT)
        )
    }

    func requireIdentity(
        _ expected: FileSystemObjectIdentity,
        at url: URL
    ) throws {
        guard try identity(of: url) == expected else {
            throw FileOperationError.fileIdentityChanged
        }
    }

    /// Revalidates the object that was present when the index row was built.
    /// A path alone is not sufficient because another process can replace its
    /// contents between scanning and a destructive action.
    func requireIndexedIdentity(_ file: IndexedFile) throws {
        let values: URLResourceValues
        do {
            values = try file.url.resourceValues(forKeys: IndexedFileIdentity.resourceKeys)
        } catch {
            throw FileOperationError.fileNotFound
        }
        let currentID = IndexedFileIdentity.id(
            sourceID: file.sourceID,
            url: file.url,
            values: values,
            fileManager: fileManager
        )
        guard currentID == file.id else {
            throw FileOperationError.fileIdentityChanged
        }
    }

    /// Keeps identity validation and the path mutation in one actor turn, so
    /// another app task cannot interleave between the two operations.
    func rename(indexedFile file: IndexedFile, to proposedName: String) throws -> URL {
        try requireIndexedIdentity(file)
        return try rename(fileAt: file.url, to: proposedName)
    }

    func rename(
        fileAt sourceURL: URL,
        expectedIdentity: FileSystemObjectIdentity,
        to proposedName: String
    ) throws -> URL {
        try requireIdentity(expectedIdentity, at: sourceURL)
        return try rename(fileAt: sourceURL, to: proposedName)
    }

    func move(indexedFile file: IndexedFile, to destinationDirectory: URL) throws -> URL {
        try requireIndexedIdentity(file)
        return try move(fileAt: file.url, to: destinationDirectory)
    }

    func move(
        fileAt sourceURL: URL,
        expectedIdentity: FileSystemObjectIdentity,
        to destinationDirectory: URL
    ) throws -> URL {
        try requireIdentity(expectedIdentity, at: sourceURL)
        return try move(fileAt: sourceURL, to: destinationDirectory)
    }

    func moveToTrash(indexedFile file: IndexedFile) throws -> URL? {
        try requireIndexedIdentity(file)
        return try moveToTrash(fileAt: file.url)
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

struct ThumbnailFailure: Sendable {
    let fileID: String
    let error: any Error
}

actor ThumbnailService {
    static let shared = ThumbnailService()
    static let maxConcurrent = 4

    /// Most recent generation failure, for diagnostics. Thumbnails degrade
    /// gracefully to a symbol, so this is deliberately not surfaced as an alert.
    private(set) var lastFailure: ThumbnailFailure?

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 600
        cache.totalCostLimit = 96 * 1_024 * 1_024
        return cache
    }()

    private var running = 0
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var waiters: [Waiter] = []

    /// Approximate backing-store cost in bytes, used to bound the cache by memory
    /// rather than by entry count alone (a 512pt @2x thumbnail costs ~4MB).
    private func cost(of image: NSImage, scale: CGFloat) -> Int {
        let pixelWidth = image.size.width * scale
        let pixelHeight = image.size.height * scale
        return Int(pixelWidth * pixelHeight * 4)
    }

    func thumbnail(for file: IndexedFile, size: CGSize, scale: CGFloat) async -> NSImage? {
        let cacheKey = "\(file.id)-\(Int(size.width))-\(Int(size.height))" as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }

        guard await acquire() else { return nil }
        defer { release() }
        guard !Task.isCancelled else { return nil }

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
            cache.setObject(image, forKey: cacheKey, cost: cost(of: image, scale: scale))
            return image
        } catch {
            lastFailure = ThumbnailFailure(fileID: file.id, error: error)
            return nil
        }
    }

    private func acquire() async -> Bool {
        if running < Self.maxConcurrent {
            running += 1
            return true
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(Waiter(id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    private func release() {
        if waiters.isEmpty {
            running -= 1
            return
        }
        waiters.removeFirst().continuation.resume(returning: true)
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
            let image = await ThumbnailService.shared.thumbnail(
                for: file,
                size: CGSize(width: size, height: size),
                scale: displayScale
            )
            guard !Task.isCancelled else { return }
            thumbnail = image
        }
    }
}
