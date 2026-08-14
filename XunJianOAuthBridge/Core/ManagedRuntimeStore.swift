import CryptoKit
import Darwin
import Foundation
import Security
enum ManagedRuntimeArchitecture: String, Codable, Sendable {
    case arm64
    case x86_64

    static var current: ManagedRuntimeArchitecture? {
        #if arch(arm64)
        .arm64
        #elseif arch(x86_64)
        .x86_64
        #else
        nil
        #endif
    }
}
protocol ManagedRuntimeSignatureValidating: Sendable {
    func isValid(
        executableURL: URL,
        signingIdentifier: String,
        teamIdentifier: String
    ) -> Bool
}

struct SystemManagedRuntimeSignatureValidator: ManagedRuntimeSignatureValidating {
    func isValid(
        executableURL: URL,
        signingIdentifier: String,
        teamIdentifier: String
    ) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            executableURL as CFURL,
            [],
            &staticCode
        ) == errSecSuccess,
              let staticCode else {
            return false
        }
        let text = "anchor apple generic and identifier \"\(signingIdentifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            text as CFString,
            [],
            &requirement
        ) == errSecSuccess,
              let requirement else {
            return false
        }
        return SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: kSecCSCheckAllArchitectures),
            requirement
        ) == errSecSuccess
    }
}

enum BundledCodexRuntimeError: Error, Equatable, Sendable {
    case missingResource
    case unsafeResource
}

struct BundledCodexRuntimeResolver: Sendable {
    static let version = "0.147.0"

    private static let officialArm64SHA256 =
        "b1a7e99d3dba6cef9bb3785097321041a6b6594600a520bb320a9d80b35fd65c"
    private static let officialX86_64SHA256 =
        "f0da5ac98055516180a480bafd684f6003df1ad64a07c99006389f1e07e2ef3c"

    private let runtimeRootURL: URL?
    private let signatureValidator: any ManagedRuntimeSignatureValidating
    private let expectedArm64SHA256: String
    private let expectedX86_64SHA256: String

    init(
        bundle: Bundle = .main,
        signatureValidator: any ManagedRuntimeSignatureValidating =
            SystemManagedRuntimeSignatureValidator()
    ) {
        runtimeRootURL = bundle.resourceURL?.appending(
            path: "CodexAppServer",
            directoryHint: .isDirectory
        )
        self.signatureValidator = signatureValidator
        expectedArm64SHA256 = Self.officialArm64SHA256
        expectedX86_64SHA256 = Self.officialX86_64SHA256
    }

    init(
        runtimeRootURL: URL,
        signatureValidator: any ManagedRuntimeSignatureValidating,
        expectedArm64SHA256: String,
        expectedX86_64SHA256: String
    ) {
        self.runtimeRootURL = runtimeRootURL.standardizedFileURL
        self.signatureValidator = signatureValidator
        self.expectedArm64SHA256 = expectedArm64SHA256.lowercased()
        self.expectedX86_64SHA256 = expectedX86_64SHA256.lowercased()
    }

    func executableURL(for architecture: ManagedRuntimeArchitecture) throws -> URL {
        guard let runtimeRootURL else {
            throw BundledCodexRuntimeError.missingResource
        }
        try validateDirectory(runtimeRootURL)
        let architectureURL = runtimeRootURL.appending(
            path: architecture.rawValue,
            directoryHint: .isDirectory
        )
        try validateDirectory(architectureURL)
        let executableURL = architectureURL.appending(path: "codex-app-server")
            .standardizedFileURL
        try validateExecutable(executableURL)
        let expectedDigest = switch architecture {
        case .arm64: expectedArm64SHA256
        case .x86_64: expectedX86_64SHA256
        }
        guard Self.isSHA256(expectedDigest),
              try ManagedRuntimeDigest.sha256Hex(fileURL: executableURL)
                == expectedDigest,
              signatureValidator.isValid(
                  executableURL: executableURL,
                  signingIdentifier: "codex-app-server",
                  teamIdentifier: "2DC432GLL2"
              ) else {
            throw BundledCodexRuntimeError.unsafeResource
        }
        try validateExecutable(executableURL)
        return executableURL
    }

    private func validateDirectory(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw BundledCodexRuntimeError.unsafeResource
        }
        var linkInformation = stat()
        guard Darwin.lstat(path, &linkInformation) == 0 else {
            if errno == ENOENT { throw BundledCodexRuntimeError.missingResource }
            throw BundledCodexRuntimeError.unsafeResource
        }
        let descriptor = Darwin.open(
            path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw BundledCodexRuntimeError.unsafeResource
        }
        defer { Darwin.close(descriptor) }
        var openedInformation = stat()
        guard Darwin.fstat(descriptor, &openedInformation) == 0,
              linkInformation.st_dev == openedInformation.st_dev,
              linkInformation.st_ino == openedInformation.st_ino,
              openedInformation.st_mode & S_IFMT == S_IFDIR,
              openedInformation.st_uid == Darwin.getuid()
                || openedInformation.st_uid == 0,
              openedInformation.st_mode & 0o022 == 0 else {
            throw BundledCodexRuntimeError.unsafeResource
        }
    }

    private func validateExecutable(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        var linkInformation = stat()
        guard Darwin.lstat(path, &linkInformation) == 0 else {
            if errno == ENOENT { throw BundledCodexRuntimeError.missingResource }
            throw BundledCodexRuntimeError.unsafeResource
        }
        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw BundledCodexRuntimeError.unsafeResource
        }
        defer { Darwin.close(descriptor) }
        var openedInformation = stat()
        guard Darwin.fstat(descriptor, &openedInformation) == 0,
              linkInformation.st_dev == openedInformation.st_dev,
              linkInformation.st_ino == openedInformation.st_ino,
              openedInformation.st_mode & S_IFMT == S_IFREG,
              openedInformation.st_uid == Darwin.getuid()
                || openedInformation.st_uid == 0,
              openedInformation.st_nlink == 1,
              openedInformation.st_mode & 0o022 == 0,
              openedInformation.st_mode & 0o111 != 0,
              openedInformation.st_size > 0,
              openedInformation.st_size <= 300_000_000 else {
            throw BundledCodexRuntimeError.unsafeResource
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }
}

enum BundledGrokRuntimeError: Error, Equatable, Sendable {
    case missingResource
    case unsafeResource
}

struct BundledGrokRuntimeResolver: Sendable {
    static let version = "1.0.0"

    private static let officialArm64SHA256 =
        "13c7f4f0b9abb00bf38216302ea4bab31f03e13555e3576620eca1de572a8d21"
    private static let officialX86_64SHA256 =
        "a82210a961deac9f0cb72ec6c334196abf76a587be4593bc59db2deab85ee6dc"

    private let runtimeRootURL: URL?
    private let signatureValidator: any ManagedRuntimeSignatureValidating
    private let expectedArm64SHA256: String
    private let expectedX86_64SHA256: String

    init(
        bundle: Bundle = .main,
        signatureValidator: any ManagedRuntimeSignatureValidating =
            SystemManagedRuntimeSignatureValidator()
    ) {
        runtimeRootURL = bundle.resourceURL?.appending(
            path: "GrokRuntime",
            directoryHint: .isDirectory
        )
        self.signatureValidator = signatureValidator
        expectedArm64SHA256 = Self.officialArm64SHA256
        expectedX86_64SHA256 = Self.officialX86_64SHA256
    }

    init(
        runtimeRootURL: URL,
        signatureValidator: any ManagedRuntimeSignatureValidating,
        expectedArm64SHA256: String,
        expectedX86_64SHA256: String
    ) {
        self.runtimeRootURL = runtimeRootURL.standardizedFileURL
        self.signatureValidator = signatureValidator
        self.expectedArm64SHA256 = expectedArm64SHA256.lowercased()
        self.expectedX86_64SHA256 = expectedX86_64SHA256.lowercased()
    }

    func executableURL(for architecture: ManagedRuntimeArchitecture) throws -> URL {
        guard let runtimeRootURL else {
            throw BundledGrokRuntimeError.missingResource
        }
        try validateDirectory(runtimeRootURL)
        let architectureURL = runtimeRootURL.appending(
            path: architecture.rawValue,
            directoryHint: .isDirectory
        )
        try validateDirectory(architectureURL)
        let executableURL = architectureURL.appending(path: "grok")
            .standardizedFileURL
        try validateExecutable(executableURL)
        let expectedDigest = switch architecture {
        case .arm64: expectedArm64SHA256
        case .x86_64: expectedX86_64SHA256
        }
        guard Self.isSHA256(expectedDigest),
              try ManagedRuntimeDigest.sha256Hex(fileURL: executableURL)
                == expectedDigest,
              signatureValidator.isValid(
                  executableURL: executableURL,
                  signingIdentifier: "xai-grok-pager",
                  teamIdentifier: "5Y6N3AJ54S"
              ) else {
            throw BundledGrokRuntimeError.unsafeResource
        }
        try validateExecutable(executableURL)
        return executableURL
    }

    private func validateDirectory(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw BundledGrokRuntimeError.unsafeResource
        }
        var linkInformation = stat()
        guard Darwin.lstat(path, &linkInformation) == 0 else {
            if errno == ENOENT { throw BundledGrokRuntimeError.missingResource }
            throw BundledGrokRuntimeError.unsafeResource
        }
        let descriptor = Darwin.open(
            path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw BundledGrokRuntimeError.unsafeResource
        }
        defer { Darwin.close(descriptor) }
        var openedInformation = stat()
        guard Darwin.fstat(descriptor, &openedInformation) == 0,
              linkInformation.st_dev == openedInformation.st_dev,
              linkInformation.st_ino == openedInformation.st_ino,
              openedInformation.st_mode & S_IFMT == S_IFDIR,
              openedInformation.st_uid == Darwin.getuid()
                || openedInformation.st_uid == 0,
              openedInformation.st_mode & 0o022 == 0 else {
            throw BundledGrokRuntimeError.unsafeResource
        }
    }

    private func validateExecutable(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        var linkInformation = stat()
        guard Darwin.lstat(path, &linkInformation) == 0 else {
            if errno == ENOENT { throw BundledGrokRuntimeError.missingResource }
            throw BundledGrokRuntimeError.unsafeResource
        }
        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw BundledGrokRuntimeError.unsafeResource
        }
        defer { Darwin.close(descriptor) }
        var openedInformation = stat()
        guard Darwin.fstat(descriptor, &openedInformation) == 0,
              linkInformation.st_dev == openedInformation.st_dev,
              linkInformation.st_ino == openedInformation.st_ino,
              openedInformation.st_mode & S_IFMT == S_IFREG,
              openedInformation.st_uid == Darwin.getuid()
                || openedInformation.st_uid == 0,
              openedInformation.st_nlink == 1,
              openedInformation.st_mode & 0o022 == 0,
              openedInformation.st_mode & 0o111 != 0,
              openedInformation.st_size > 0,
              openedInformation.st_size <= 200_000_000 else {
            throw BundledGrokRuntimeError.unsafeResource
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }
}

private enum ManagedRuntimeDigestError: Error {
    case unreadableFile
}

enum ManagedRuntimeDigest {
    static func sha256Hex(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Identity of an opened file, used to keep the digest cache valid: any
    /// change to the binary invalidates the cached hash.
    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modificationNanoseconds: UInt64
    }

    private static let cacheLock = NSLock()
    /// Keyed by path; only the two bundled runtime executables are ever
    /// hashed, so the cache is bounded by design.
    nonisolated(unsafe) private static var cachedDigests: [
        String: (identity: FileIdentity, digest: String)
    ] = [:]

    static func sha256Hex(fileURL: URL) throws -> String {
        let path = fileURL.standardizedFileURL.path
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw ManagedRuntimeDigestError.unreadableFile
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)

        var openedInformation = stat()
        guard fstat(descriptor, &openedInformation) == 0 else {
            throw ManagedRuntimeDigestError.unreadableFile
        }
        let identity = FileIdentity(
            device: UInt64(openedInformation.st_dev),
            inode: UInt64(openedInformation.st_ino),
            size: openedInformation.st_size,
            modificationNanoseconds:
                UInt64(openedInformation.st_mtimespec.tv_sec) * 1_000_000_000
                + UInt64(openedInformation.st_mtimespec.tv_nsec)
        )

        cacheLock.lock()
        if let cached = cachedDigests[path], cached.identity == identity {
            cacheLock.unlock()
            return cached.digest
        }
        cacheLock.unlock()

        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            throw ManagedRuntimeDigestError.unreadableFile
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()

        cacheLock.lock()
        cachedDigests[path] = (identity, digest)
        cacheLock.unlock()
        return digest
    }
}
