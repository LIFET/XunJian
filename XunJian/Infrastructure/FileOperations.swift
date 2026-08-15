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
    case invalidDestination
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
        case .invalidDestination:
            AppLanguage.localized("目标文件夹无效，或位于要移动的文件夹内部。", english: "The destination folder is invalid or is inside the folder being moved.")
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

/// Metadata version paired with a content digest before destructive cleanup.
/// ctime prevents a caller from hiding a rewrite by restoring only mtime.
struct FileSystemObjectVersion: Equatable, Sendable {
    let identity: FileSystemObjectIdentity
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    init(metadata: stat) {
        identity = FileSystemObjectIdentity(
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            fileType: UInt32(metadata.st_mode) & UInt32(S_IFMT)
        )
        size = Int64(metadata.st_size)
        modifiedSeconds = Int64(metadata.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(metadata.st_mtimespec.tv_nsec)
        changedSeconds = Int64(metadata.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(metadata.st_ctimespec.tv_nsec)
    }
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

    func version(of url: URL) throws -> FileSystemObjectVersion {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw FileOperationError.fileNotFound
        }
        return FileSystemObjectVersion(metadata: metadata)
    }

    func directoryIdentity(of url: URL) throws -> FileSystemObjectIdentity {
        let currentIdentity = try identity(of: url)
        guard currentIdentity.fileType == UInt32(S_IFDIR) else {
            throw FileOperationError.invalidDestination
        }
        return currentIdentity
    }

    private func requireVersion(
        _ expected: FileSystemObjectVersion,
        at url: URL
    ) throws {
        guard try version(of: url) == expected else {
            throw FileOperationError.fileIdentityChanged
        }
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
        try requireIndexedIdentity(file, at: file.url)
    }

    private func requireIndexedIdentity(_ file: IndexedFile, at url: URL) throws {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: IndexedFileIdentity.resourceKeys)
        } catch {
            throw FileOperationError.fileNotFound
        }
        let currentID = IndexedFileIdentity.id(
            sourceID: file.sourceID,
            url: url,
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
        try coordinatedWrite(at: file.url, options: .forMoving) { coordinatedURL in
            _ = try directoryIdentity(of: coordinatedURL.deletingLastPathComponent())
            try requireIndexedIdentity(file, at: coordinatedURL)
            let expectedIdentity = try identity(of: coordinatedURL)
            let result = try rename(fileAt: coordinatedURL, to: proposedName)
            try requireIdentity(expectedIdentity, at: result)
            return result
        }
    }

    func rename(
        fileAt sourceURL: URL,
        expectedIdentity: FileSystemObjectIdentity,
        expectedParentIdentity: FileSystemObjectIdentity,
        to proposedName: String
    ) throws -> URL {
        try coordinatedWrite(at: sourceURL, options: .forMoving) { coordinatedURL in
            try requireDirectoryIdentity(
                expectedParentIdentity,
                at: coordinatedURL.deletingLastPathComponent()
            )
            try requireIdentity(expectedIdentity, at: coordinatedURL)
            let result = try rename(fileAt: coordinatedURL, to: proposedName)
            try requireIdentity(expectedIdentity, at: result)
            return result
        }
    }

    func move(indexedFile file: IndexedFile, to destinationDirectory: URL) throws -> URL {
        let expectedDestinationIdentity = try directoryIdentity(of: destinationDirectory)
        return try coordinatedMove(from: file.url, to: destinationDirectory) { source, destination in
            try requireIndexedIdentity(file, at: source)
            let expectedIdentity = try identity(of: source)
            try requireDirectoryIdentity(expectedDestinationIdentity, at: destination)
            try validateMoveDestination(
                sourceURL: source,
                sourceIdentity: expectedIdentity,
                destinationDirectory: destination
            )
            let result = try move(fileAt: source, to: destination)
            try requireIdentity(expectedIdentity, at: result)
            return result
        }
    }

    func move(
        fileAt sourceURL: URL,
        expectedIdentity: FileSystemObjectIdentity,
        expectedDestinationIdentity: FileSystemObjectIdentity,
        to destinationDirectory: URL
    ) throws -> URL {
        try coordinatedMove(from: sourceURL, to: destinationDirectory) { source, destination in
            try requireIdentity(expectedIdentity, at: source)
            try requireDirectoryIdentity(expectedDestinationIdentity, at: destination)
            try validateMoveDestination(
                sourceURL: source,
                sourceIdentity: expectedIdentity,
                destinationDirectory: destination
            )
            let result = try move(fileAt: source, to: destination)
            try requireIdentity(expectedIdentity, at: result)
            return result
        }
    }

    func moveToTrash(indexedFile file: IndexedFile) throws -> URL? {
        try coordinatedWrite(at: file.url, options: .forDeleting) { coordinatedURL in
            _ = try directoryIdentity(of: coordinatedURL.deletingLastPathComponent())
            try requireIndexedIdentity(file, at: coordinatedURL)
            let expectedIdentity = try identity(of: coordinatedURL)
            let result = try moveToTrash(fileAt: coordinatedURL)
            if let result {
                try requireIdentity(expectedIdentity, at: result)
            }
            return result
        }
    }

    private func requireDirectoryIdentity(
        _ expected: FileSystemObjectIdentity,
        at url: URL
    ) throws {
        guard try directoryIdentity(of: url) == expected else {
            throw FileOperationError.fileIdentityChanged
        }
    }

    private func validateMoveDestination(
        sourceURL: URL,
        sourceIdentity: FileSystemObjectIdentity,
        destinationDirectory: URL
    ) throws {
        guard sourceIdentity.fileType == UInt32(S_IFDIR) else { return }
        let sourceComponents = sourceURL.resolvingSymlinksInPath()
            .standardizedFileURL.pathComponents
        let destinationComponents = destinationDirectory.resolvingSymlinksInPath()
            .standardizedFileURL.pathComponents
        guard destinationComponents.count < sourceComponents.count
                || !destinationComponents.prefix(sourceComponents.count)
                    .elementsEqual(sourceComponents) else {
            throw FileOperationError.invalidDestination
        }
    }

    /// Coordinates the reference read and candidate deletion in one filesystem
    /// transaction. Both versions came from stable content hashes immediately
    /// before this call.
    func moveDuplicateToTrash(
        indexedFile file: IndexedFile,
        expectedVersion: FileSystemObjectVersion,
        matching referenceURL: URL,
        expectedReferenceVersion: FileSystemObjectVersion
    ) throws -> URL? {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<URL?, Error>?
        coordinator.coordinate(
            readingItemAt: referenceURL,
            options: .withoutChanges,
            writingItemAt: file.url,
            options: .forDeleting,
            error: &coordinationError
        ) { coordinatedReference, coordinatedCandidate in
            result = Result {
                try requireVersion(expectedReferenceVersion, at: coordinatedReference)
                try requireVersion(expectedVersion, at: coordinatedCandidate)
                try requireIndexedIdentity(file, at: coordinatedCandidate)
                let trashedURL = try moveToTrash(fileAt: coordinatedCandidate)
                if let trashedURL {
                    try requireIdentity(expectedVersion.identity, at: trashedURL)
                }
                return trashedURL
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else {
            throw FileOperationError.operationFailed("File coordination failed")
        }
        return try result.get()
    }

    private func coordinatedWrite<T>(
        at url: URL,
        options: NSFileCoordinator.WritingOptions,
        operation: (URL) throws -> T
    ) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<T, Error>?
        coordinator.coordinate(writingItemAt: url, options: options, error: &coordinationError) {
            coordinatedURL in
            result = Result { try operation(coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw FileOperationError.operationFailed("File coordination failed") }
        return try result.get()
    }

    private func coordinatedMove<T>(
        from sourceURL: URL,
        to destinationDirectory: URL,
        operation: (URL, URL) throws -> T
    ) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<T, Error>?
        coordinator.coordinate(
            writingItemAt: sourceURL,
            options: .forMoving,
            writingItemAt: destinationDirectory,
            options: .forMerging,
            error: &coordinationError
        ) { coordinatedSource, coordinatedDestination in
            result = Result { try operation(coordinatedSource, coordinatedDestination) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw FileOperationError.operationFailed("File coordination failed") }
        return try result.get()
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

        let parentURL = sourceURL.deletingLastPathComponent()
        _ = try directoryIdentity(of: parentURL)
        guard fileManager.isWritableFile(atPath: parentURL.path) else {
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
        let sourceIdentity = try identity(of: sourceURL)
        _ = try directoryIdentity(of: destinationDirectory)
        try validateMoveDestination(
            sourceURL: sourceURL,
            sourceIdentity: sourceIdentity,
            destinationDirectory: destinationDirectory
        )
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
        let parentURL = sourceURL.deletingLastPathComponent()
        _ = try directoryIdentity(of: parentURL)
        guard fileManager.isWritableFile(atPath: parentURL.path) else {
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

    func thumbnail(
        for file: IndexedFile,
        size: CGSize,
        scale: CGFloat,
        representationTypes: QLThumbnailGenerator.Request.RepresentationTypes = .thumbnail
    ) async -> NSImage? {
        // Scale is part of the key: Retina and non-Retina displays (or a
        // display-scale change) must not share one pixel-density entry.
        let modifiedAt = file.modifiedAt?.timeIntervalSinceReferenceDate ?? 0
        let cacheKey = "\(file.id)-\(file.size)-\(modifiedAt)-\(Int(size.width))-\(Int(size.height))-\(Int(scale * 100))-\(representationTypes.rawValue)" as NSString
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
            representationTypes: representationTypes
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
    private struct RequestID: Hashable {
        let fileID: String
        let fileSize: Int64
        let modifiedAt: Date?
        let side: CGFloat
        let displayScale: CGFloat
    }

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
        .task(id: RequestID(
            fileID: file.id,
            fileSize: file.size,
            modifiedAt: file.modifiedAt,
            side: size,
            displayScale: displayScale
        )) {
            // Keep the last image on screen while a replacement loads.
            // Clearing it first flashed the SF Symbol on every cell reuse
            // and made the 1,100-image library stutter while scrolling.
            let image = await ThumbnailService.shared.thumbnail(
                for: file,
                size: CGSize(width: size, height: size),
                scale: displayScale,
                representationTypes: Self.representationTypes(for: size)
            )
            guard !Task.isCancelled else { return }
            thumbnail = image
        }
    }

    /// Table-sized cells only need the file icon. Asking Quick Look for
    /// `.all` made every visible image/video row wait on a full preview.
    static func representationTypes(
        for size: CGFloat
    ) -> QLThumbnailGenerator.Request.RepresentationTypes {
        size <= 32 ? .icon : .thumbnail
    }
}
