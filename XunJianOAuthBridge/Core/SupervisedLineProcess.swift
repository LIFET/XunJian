import Darwin
import Foundation

enum CodexAppServerHomeError: Error, Equatable, Sendable {
    case unsafePath
    case unavailable
    case busy
}

struct CodexAppServerHome: Equatable, Sendable {
    let rootURL: URL

    private let lockFileURL: URL

    static func prepare(userHomeDirectoryURL: URL) throws -> Self {
        guard userHomeDirectoryURL.isFileURL,
              userHomeDirectoryURL.path.hasPrefix("/"),
              !userHomeDirectoryURL.path.utf8.contains(0) else {
            throw CodexAppServerHomeError.unsafePath
        }
        let userHome = userHomeDirectoryURL.standardizedFileURL
        let library = userHome.appending(path: "Library", directoryHint: .isDirectory)
        let applicationSupport = library.appending(
            path: "Application Support",
            directoryHint: .isDirectory
        )
        let applicationRoot = applicationSupport.appending(
            path: "com.xingmingbo.XunJian",
            directoryHint: .isDirectory
        )
        let root = applicationRoot.appending(
            path: "CodexAppServer",
            directoryHint: .isDirectory
        )

        try requireDirectory(userHome, createIfMissing: false, makePrivate: false)
        try requireDirectory(library, createIfMissing: true, makePrivate: false)
        try requireDirectory(applicationSupport, createIfMissing: true, makePrivate: false)
        try requireDirectory(applicationRoot, createIfMissing: true, makePrivate: true)
        try requireDirectory(root, createIfMissing: true, makePrivate: true)
        try rejectExecutableConfiguration(in: root)
        try validateCredentialFileIfPresent(root.appending(path: "auth.json"))
        return Self(
            rootURL: root.standardizedFileURL,
            lockFileURL: applicationRoot.appending(path: ".codex-app-server.lock")
        )
    }

    func acquireLease() throws -> GrokCLIHomeLease {
        do {
            return try GrokCLIHomeLease(lockFileURL: lockFileURL)
        } catch GrokCLIHomeError.busy {
            throw CodexAppServerHomeError.busy
        } catch GrokCLIHomeError.unsafePath {
            throw CodexAppServerHomeError.unsafePath
        } catch {
            throw CodexAppServerHomeError.unavailable
        }
    }

    private static func requireDirectory(
        _ url: URL,
        createIfMissing: Bool,
        makePrivate: Bool
    ) throws {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw CodexAppServerHomeError.unsafePath
        }
        if createIfMissing, Darwin.mkdir(path, 0o700) != 0, errno != EEXIST {
            throw CodexAppServerHomeError.unavailable
        }
        let descriptor = Darwin.open(
            path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw errno == ELOOP
                ? CodexAppServerHomeError.unsafePath
                : CodexAppServerHomeError.unavailable
        }
        defer { Darwin.close(descriptor) }
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              information.st_uid == Darwin.getuid(),
              information.st_mode & S_IFMT == S_IFDIR else {
            throw CodexAppServerHomeError.unsafePath
        }
        if makePrivate, Darwin.fchmod(descriptor, 0o700) != 0 {
            throw CodexAppServerHomeError.unavailable
        }
    }

    private static func rejectExecutableConfiguration(in root: URL) throws {
        let forbiddenNames = [
            "config.toml", "AGENTS.md", "hooks",
            "rules", "commands", "agents", ".mcp.json", "mcp.json"
        ]
        for name in forbiddenNames {
            var information = stat()
            if Darwin.lstat(root.appending(path: name).path, &information) == 0 {
                throw CodexAppServerHomeError.unsafePath
            }
            guard errno == ENOENT else {
                throw CodexAppServerHomeError.unavailable
            }
        }
        try validateManagedSystemSkillsIfPresent(
            root.appending(path: "skills", directoryHint: .isDirectory)
        )
        try validateManagedPluginsIfPresent(
            root.appending(path: "plugins", directoryHint: .isDirectory)
        )
    }

    private static func validateManagedSystemSkillsIfPresent(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        var linkInformation = stat()
        guard Darwin.lstat(path, &linkInformation) == 0 else {
            if errno == ENOENT { return }
            throw CodexAppServerHomeError.unavailable
        }
        guard linkInformation.st_mode & S_IFMT == S_IFDIR,
              linkInformation.st_uid == Darwin.getuid(),
              linkInformation.st_mode & 0o022 == 0 else {
            throw CodexAppServerHomeError.unsafePath
        }

        let descriptor = Darwin.open(
            path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw CodexAppServerHomeError.unsafePath }
        defer { Darwin.close(descriptor) }
        var openedInformation = stat()
        guard Darwin.fstat(descriptor, &openedInformation) == 0,
              openedInformation.st_dev == linkInformation.st_dev,
              openedInformation.st_ino == linkInformation.st_ino,
              openedInformation.st_uid == Darwin.getuid(),
              openedInformation.st_mode & S_IFMT == S_IFDIR,
              openedInformation.st_mode & 0o022 == 0 else {
            throw CodexAppServerHomeError.unsafePath
        }

        let enumerationDescriptor = Darwin.dup(descriptor)
        guard enumerationDescriptor >= 0 else {
            throw CodexAppServerHomeError.unavailable
        }
        guard let directory = Darwin.fdopendir(enumerationDescriptor) else {
            Darwin.close(enumerationDescriptor)
            throw CodexAppServerHomeError.unavailable
        }
        defer { Darwin.closedir(directory) }
        var foundSystemDirectory = false
        errno = 0
        while let entry = Darwin.readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            guard name == ".system", !foundSystemDirectory else {
                throw CodexAppServerHomeError.unsafePath
            }
            foundSystemDirectory = true
        }
        guard errno == 0 else { throw CodexAppServerHomeError.unavailable }
        guard Darwin.fchmod(descriptor, 0o700) == 0 else {
            throw CodexAppServerHomeError.unavailable
        }

        guard foundSystemDirectory else { return }
        let systemURL = url.appending(path: ".system", directoryHint: .isDirectory)
        let systemPath = systemURL.standardizedFileURL.path
        var systemLinkInformation = stat()
        guard Darwin.lstat(systemPath, &systemLinkInformation) == 0,
              systemLinkInformation.st_mode & S_IFMT == S_IFDIR,
              systemLinkInformation.st_uid == Darwin.getuid(),
              systemLinkInformation.st_dev == openedInformation.st_dev,
              systemLinkInformation.st_mode & 0o022 == 0 else {
            throw CodexAppServerHomeError.unsafePath
        }
        let systemDescriptor = Darwin.open(
            systemPath,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard systemDescriptor >= 0 else {
            throw CodexAppServerHomeError.unsafePath
        }
        defer { Darwin.close(systemDescriptor) }
        var openedSystemInformation = stat()
        guard Darwin.fstat(systemDescriptor, &openedSystemInformation) == 0,
              openedSystemInformation.st_dev == systemLinkInformation.st_dev,
              openedSystemInformation.st_ino == systemLinkInformation.st_ino,
              openedSystemInformation.st_uid == Darwin.getuid(),
              openedSystemInformation.st_mode & S_IFMT == S_IFDIR,
              openedSystemInformation.st_mode & 0o022 == 0,
              Darwin.fchmod(systemDescriptor, 0o700) == 0 else {
            throw CodexAppServerHomeError.unsafePath
        }
    }

    private static func validateManagedPluginsIfPresent(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        var linkInformation = stat()
        guard Darwin.lstat(path, &linkInformation) == 0 else {
            if errno == ENOENT { return }
            throw CodexAppServerHomeError.unavailable
        }
        guard linkInformation.st_mode & S_IFMT == S_IFDIR,
              linkInformation.st_uid == Darwin.getuid(),
              linkInformation.st_mode & 0o022 == 0 else {
            throw CodexAppServerHomeError.unsafePath
        }

        let descriptor = Darwin.open(
            path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw CodexAppServerHomeError.unsafePath }
        defer { Darwin.close(descriptor) }
        var openedInformation = stat()
        guard Darwin.fstat(descriptor, &openedInformation) == 0,
              openedInformation.st_dev == linkInformation.st_dev,
              openedInformation.st_ino == linkInformation.st_ino,
              openedInformation.st_uid == Darwin.getuid(),
              openedInformation.st_mode & S_IFMT == S_IFDIR,
              openedInformation.st_mode & 0o022 == 0,
              Darwin.fchmod(descriptor, 0o700) == 0 else {
            throw CodexAppServerHomeError.unsafePath
        }

        let rootEntries = try directoryEntryNames(descriptor)
        guard Set(rootEntries).isSubset(of: [".remote-plugin-install-staging", "cache"]) else {
            throw CodexAppServerHomeError.unsafePath
        }

        if rootEntries.contains(".remote-plugin-install-staging") {
            let stagingDescriptor = try openOwnedDirectory(
                at: descriptor,
                named: ".remote-plugin-install-staging",
                expectedDevice: openedInformation.st_dev
            )
            defer { Darwin.close(stagingDescriptor) }
            guard try directoryEntryNames(stagingDescriptor).isEmpty else {
                throw CodexAppServerHomeError.unsafePath
            }
        }

        if rootEntries.contains("cache") {
            let cacheDescriptor = try openOwnedDirectory(
                at: descriptor,
                named: "cache",
                expectedDevice: openedInformation.st_dev
            )
            defer { Darwin.close(cacheDescriptor) }
            let cacheEntries = try directoryEntryNames(cacheDescriptor)
            guard Set(cacheEntries).isSubset(of: ["openai-curated-remote"]) else {
                throw CodexAppServerHomeError.unsafePath
            }
            if cacheEntries.contains("openai-curated-remote") {
                let remoteDescriptor = try openOwnedDirectory(
                    at: cacheDescriptor,
                    named: "openai-curated-remote",
                    expectedDevice: openedInformation.st_dev
                )
                Darwin.close(remoteDescriptor)
            }
        }
    }

    private static func openOwnedDirectory(
        at parentDescriptor: Int32,
        named name: String,
        expectedDevice: dev_t
    ) throws -> Int32 {
        let descriptor = name.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw CodexAppServerHomeError.unsafePath
        }
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              information.st_dev == expectedDevice,
              information.st_uid == Darwin.getuid(),
              information.st_mode & S_IFMT == S_IFDIR,
              information.st_mode & 0o022 == 0,
              Darwin.fchmod(descriptor, 0o700) == 0 else {
            Darwin.close(descriptor)
            throw CodexAppServerHomeError.unsafePath
        }
        return descriptor
    }

    private static func directoryEntryNames(_ descriptor: Int32) throws -> [String] {
        let enumerationDescriptor = Darwin.dup(descriptor)
        guard enumerationDescriptor >= 0 else {
            throw CodexAppServerHomeError.unavailable
        }
        guard let directory = Darwin.fdopendir(enumerationDescriptor) else {
            Darwin.close(enumerationDescriptor)
            throw CodexAppServerHomeError.unavailable
        }
        defer { Darwin.closedir(directory) }
        var names: [String] = []
        errno = 0
        while let entry = Darwin.readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." {
                names.append(name)
            }
        }
        guard errno == 0 else { throw CodexAppServerHomeError.unavailable }
        return names
    }

    private static func validateCredentialFileIfPresent(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        var linkInformation = stat()
        guard Darwin.lstat(path, &linkInformation) == 0 else {
            if errno == ENOENT { return }
            throw CodexAppServerHomeError.unavailable
        }
        guard linkInformation.st_mode & S_IFMT == S_IFREG,
              linkInformation.st_uid == Darwin.getuid(),
              linkInformation.st_nlink == 1,
              linkInformation.st_mode & 0o077 == 0 else {
            throw CodexAppServerHomeError.unsafePath
        }
        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CodexAppServerHomeError.unsafePath }
        defer { Darwin.close(descriptor) }
        var openedInformation = stat()
        guard Darwin.fstat(descriptor, &openedInformation) == 0,
              openedInformation.st_dev == linkInformation.st_dev,
              openedInformation.st_ino == linkInformation.st_ino,
              openedInformation.st_uid == Darwin.getuid(),
              openedInformation.st_nlink == 1,
              openedInformation.st_mode & S_IFMT == S_IFREG,
              openedInformation.st_mode & 0o077 == 0 else {
            throw CodexAppServerHomeError.unsafePath
        }
    }
}

enum GrokCLIHomeError: Error, Equatable, Sendable {
    case unsafePath
    case unavailable
    case busy
}

struct GrokCLIHome: Equatable, Sendable {
    private enum ConfigurationState: Equatable {
        case absent
        case initialBootstrap
        case officialBootstrap
        case canonical
    }

    let rootURL: URL

    private let lockFileURL: URL

    private static let initialBootstrapConfiguration = Data(
        "[marketplace]\ndefault_skills_installs_purged = true\n".utf8
    )
    private static let officialBootstrapConfiguration = Data(
        """
        [marketplace]
        default_skills_installs_purged = true
        official_marketplace_auto_installed = true

        [[marketplace.sources]]
        name = "xAI Official"
        git = "https://github.com/xai-org/plugin-marketplace.git"

        """.utf8
    )

    static func prepare(userHomeDirectoryURL: URL) throws -> Self {
        guard userHomeDirectoryURL.isFileURL,
              userHomeDirectoryURL.path.hasPrefix("/"),
              !userHomeDirectoryURL.path.utf8.contains(0) else {
            throw GrokCLIHomeError.unsafePath
        }

        let userHome = userHomeDirectoryURL.standardizedFileURL
        let library = userHome.appending(path: "Library", directoryHint: .isDirectory)
        let applicationSupport = library.appending(
            path: "Application Support",
            directoryHint: .isDirectory
        )
        let applicationRoot = applicationSupport.appending(
            path: "com.xingmingbo.XunJian",
            directoryHint: .isDirectory
        )
        let root = applicationRoot.appending(
            path: "GrokCLI",
            directoryHint: .isDirectory
        )

        try requireDirectory(userHome, createIfMissing: false, makePrivate: false)
        try requireDirectory(library, createIfMissing: true, makePrivate: false)
        try requireDirectory(applicationSupport, createIfMissing: true, makePrivate: false)
        try requireDirectory(applicationRoot, createIfMissing: true, makePrivate: true)
        try requireDirectory(root, createIfMissing: true, makePrivate: true)
        try rejectSystemConfiguration()
        try rejectExecutableConfiguration(in: root)
        _ = try configurationState(in: root)
        try validateEmptyHooksDirectoryIfPresent(root.appending(path: "hooks"))
        try validateEmptyHooksRegistryIfPresent(root.appending(path: "hooks-paths"))
        try validateCredentialFileIfPresent(root.appending(path: "auth.json"))

        return Self(
            rootURL: root.standardizedFileURL,
            lockFileURL: applicationRoot.appending(path: ".grok-cli.lock")
        )
    }

    func acquireLease() throws -> GrokCLIHomeLease {
        try GrokCLIHomeLease(lockFileURL: lockFileURL)
    }

    func hardenForIsolatedRuntime() throws {
        let originalState = try Self.configurationState(in: rootURL)
        try Self.validateBundledSkillDirectoriesIfPresent(in: rootURL)
        if originalState != .canonical {
            try Self.replaceConfigurationAtomically(
                in: rootURL,
                expectedState: originalState
            )
        }
        guard try Self.configurationState(in: rootURL) == .canonical else {
            throw GrokCLIHomeError.unsafePath
        }
        try Self.validateBundledSkillDirectoriesIfPresent(in: rootURL)
    }

    private static func requireDirectory(
        _ url: URL,
        createIfMissing: Bool,
        makePrivate: Bool
    ) throws {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw GrokCLIHomeError.unsafePath
        }
        if createIfMissing, Darwin.mkdir(path, 0o700) != 0, errno != EEXIST {
            throw GrokCLIHomeError.unavailable
        }
        let descriptor = Darwin.open(
            path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw errno == ELOOP
                ? GrokCLIHomeError.unsafePath
                : GrokCLIHomeError.unavailable
        }
        defer { Darwin.close(descriptor) }

        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              information.st_uid == Darwin.getuid(),
              information.st_mode & S_IFMT == S_IFDIR else {
            throw GrokCLIHomeError.unsafePath
        }
        if makePrivate, Darwin.fchmod(descriptor, 0o700) != 0 {
            throw GrokCLIHomeError.unavailable
        }
    }

    private static func validateCredentialFileIfPresent(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        var linkInformation = stat()
        guard Darwin.lstat(path, &linkInformation) == 0 else {
            if errno == ENOENT { return }
            throw GrokCLIHomeError.unavailable
        }
        guard linkInformation.st_mode & S_IFMT == S_IFREG,
              linkInformation.st_uid == Darwin.getuid(),
              linkInformation.st_nlink == 1,
              linkInformation.st_mode & 0o077 == 0 else {
            throw GrokCLIHomeError.unsafePath
        }

        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw GrokCLIHomeError.unsafePath }
        defer { Darwin.close(descriptor) }
        var openedInformation = stat()
        guard Darwin.fstat(descriptor, &openedInformation) == 0,
              openedInformation.st_dev == linkInformation.st_dev,
              openedInformation.st_ino == linkInformation.st_ino,
              openedInformation.st_uid == Darwin.getuid(),
              openedInformation.st_nlink == 1,
              openedInformation.st_mode & S_IFMT == S_IFREG,
              openedInformation.st_mode & 0o077 == 0 else {
            throw GrokCLIHomeError.unsafePath
        }
    }

    private static func rejectSystemConfiguration() throws {
        var information = stat()
        if Darwin.lstat("/etc/grok", &information) == 0 {
            throw GrokCLIHomeError.unsafePath
        }
        guard errno == ENOENT else { throw GrokCLIHomeError.unavailable }
    }

    private static func rejectExecutableConfiguration(in root: URL) throws {
        let forbiddenNames = [
            "plugins", "rules", "skills", "commands", "agents",
            "managed_config.toml", "settings.json",
            "managed-settings.json", "requirements.toml",
            ".mcp.json", "mcp.json", "lsp.json", ".lsp.json", ".grok-plugin"
        ]
        for name in forbiddenNames {
            var information = stat()
            let path = root.appending(path: name).path
            if Darwin.lstat(path, &information) == 0 {
                throw GrokCLIHomeError.unsafePath
            }
            guard errno == ENOENT else { throw GrokCLIHomeError.unavailable }
        }
    }

    private static func configurationState(in root: URL) throws -> ConfigurationState {
        let url = root.appending(path: "config.toml")
        let canonical = try canonicalConfiguration(in: root)
        let path = url.standardizedFileURL.path
        var linkInformation = stat()
        guard Darwin.lstat(path, &linkInformation) == 0 else {
            if errno == ENOENT { return .absent }
            throw GrokCLIHomeError.unavailable
        }
        let candidates: [(ConfigurationState, Data)] = [
            (.initialBootstrap, initialBootstrapConfiguration),
            (.officialBootstrap, officialBootstrapConfiguration),
            (.canonical, canonical)
        ]
        let candidateSizes = Set(candidates.map { $0.1.count })
        let linkPermissions = linkInformation.st_mode & 0o777
        guard linkInformation.st_mode & S_IFMT == S_IFREG,
              linkInformation.st_uid == Darwin.getuid(),
              linkInformation.st_nlink == 1,
              linkInformation.st_size >= 0,
              candidateSizes.contains(Int(linkInformation.st_size)),
              linkPermissions == 0o600 || linkPermissions == 0o644 else {
            throw GrokCLIHomeError.unsafePath
        }

        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw GrokCLIHomeError.unsafePath }
        defer { Darwin.close(descriptor) }
        var openedInformation = stat()
        guard Darwin.fstat(descriptor, &openedInformation) == 0 else {
            throw GrokCLIHomeError.unavailable
        }
        let openedPermissions = openedInformation.st_mode & 0o777
        guard openedInformation.st_dev == linkInformation.st_dev,
              openedInformation.st_ino == linkInformation.st_ino,
              openedInformation.st_uid == Darwin.getuid(),
              openedInformation.st_nlink == 1,
              openedInformation.st_mode & S_IFMT == S_IFREG,
              openedInformation.st_size == linkInformation.st_size,
              openedPermissions == 0o600 || openedPermissions == 0o644 else {
            throw GrokCLIHomeError.unsafePath
        }

        let contents: Data
        do {
            contents = try FileHandle(
                fileDescriptor: descriptor,
                closeOnDealloc: false
            ).read(upToCount: (candidateSizes.max() ?? 0) + 1) ?? Data()
        } catch {
            throw GrokCLIHomeError.unavailable
        }
        guard let state = candidates.first(where: { $0.1 == contents })?.0 else {
            throw GrokCLIHomeError.unsafePath
        }
        guard Darwin.fchmod(descriptor, 0o600) == 0 else {
            throw GrokCLIHomeError.unavailable
        }

        var finalInformation = stat()
        guard Darwin.fstat(descriptor, &finalInformation) == 0,
              finalInformation.st_dev == openedInformation.st_dev,
              finalInformation.st_ino == openedInformation.st_ino,
              finalInformation.st_uid == Darwin.getuid(),
              finalInformation.st_nlink == 1,
              finalInformation.st_mode & S_IFMT == S_IFREG,
              finalInformation.st_mode & 0o777 == 0o600,
              finalInformation.st_size == contents.count else {
            throw GrokCLIHomeError.unsafePath
        }
        return state
    }

    private static func canonicalConfiguration(in root: URL) throws -> Data {
        let skillsPath = root
            .appending(path: "bundled", directoryHint: .isDirectory)
            .appending(path: "skills", directoryHint: .isDirectory)
            .standardizedFileURL
            .path
        let escapedSkillsPath = try escapeTOMLBasicString(skillsPath)
        var configuration = officialBootstrapConfiguration
        configuration.append(Data(
            """

            [skills]
            ignore = [
              "\(escapedSkillsPath)",
            ]
            """.utf8
        ))
        configuration.append(0x0A)
        return configuration
    }

    private static func escapeTOMLBasicString(_ value: String) throws -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22:
                escaped.append("\\\"")
            case 0x5C:
                escaped.append("\\\\")
            case 0x00 ... 0x1F, 0x7F:
                throw GrokCLIHomeError.unsafePath
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }

    private static func replaceConfigurationAtomically(
        in root: URL,
        expectedState: ConfigurationState
    ) throws {
        let rootPath = root.standardizedFileURL.path
        let directoryDescriptor = Darwin.open(
            rootPath,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else { throw GrokCLIHomeError.unsafePath }
        defer { Darwin.close(directoryDescriptor) }
        var directoryInformation = stat()
        guard Darwin.fstat(directoryDescriptor, &directoryInformation) == 0,
              directoryInformation.st_uid == Darwin.getuid(),
              directoryInformation.st_mode & S_IFMT == S_IFDIR,
              directoryInformation.st_mode & 0o077 == 0 else {
            throw GrokCLIHomeError.unsafePath
        }

        let temporaryName = ".xunjian-config-\(UUID().uuidString).tmp"
        let temporaryDescriptor = Darwin.openat(
            directoryDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard temporaryDescriptor >= 0 else { throw GrokCLIHomeError.unavailable }
        var shouldRemoveTemporaryFile = true
        defer {
            Darwin.close(temporaryDescriptor)
            if shouldRemoveTemporaryFile {
                _ = Darwin.unlinkat(directoryDescriptor, temporaryName, 0)
            }
        }

        let canonical = try canonicalConfiguration(in: root)
        try canonical.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    temporaryDescriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw GrokCLIHomeError.unavailable }
                offset += written
            }
        }
        guard Darwin.fchmod(temporaryDescriptor, 0o600) == 0,
              Darwin.fsync(temporaryDescriptor) == 0 else {
            throw GrokCLIHomeError.unavailable
        }
        var temporaryInformation = stat()
        guard Darwin.fstat(temporaryDescriptor, &temporaryInformation) == 0,
              temporaryInformation.st_uid == Darwin.getuid(),
              temporaryInformation.st_nlink == 1,
              temporaryInformation.st_mode & S_IFMT == S_IFREG,
              temporaryInformation.st_mode & 0o777 == 0o600,
              temporaryInformation.st_size == canonical.count else {
            throw GrokCLIHomeError.unsafePath
        }
        guard try configurationState(in: root) == expectedState else {
            throw GrokCLIHomeError.unsafePath
        }

        guard Darwin.renameat(
            directoryDescriptor,
            temporaryName,
            directoryDescriptor,
            "config.toml"
        ) == 0 else {
            throw GrokCLIHomeError.unavailable
        }
        shouldRemoveTemporaryFile = false
        guard Darwin.fsync(directoryDescriptor) == 0 else {
            throw GrokCLIHomeError.unavailable
        }
    }

    private static func validateBundledSkillDirectoriesIfPresent(in root: URL) throws {
        let bundled = root.appending(path: "bundled", directoryHint: .isDirectory)
        try validateOwnedDirectoryIfPresent(bundled)
        try validateOwnedDirectoryIfPresent(
            bundled.appending(path: "skills", directoryHint: .isDirectory)
        )
    }

    private static func validateOwnedDirectoryIfPresent(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        var linkInformation = stat()
        guard Darwin.lstat(path, &linkInformation) == 0 else {
            if errno == ENOENT { return }
            throw GrokCLIHomeError.unavailable
        }
        guard linkInformation.st_mode & S_IFMT == S_IFDIR,
              linkInformation.st_uid == Darwin.getuid() else {
            throw GrokCLIHomeError.unsafePath
        }
        let descriptor = Darwin.open(
            path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw GrokCLIHomeError.unsafePath }
        defer { Darwin.close(descriptor) }
        var openedInformation = stat()
        guard Darwin.fstat(descriptor, &openedInformation) == 0,
              openedInformation.st_dev == linkInformation.st_dev,
              openedInformation.st_ino == linkInformation.st_ino,
              openedInformation.st_uid == Darwin.getuid(),
              openedInformation.st_mode & S_IFMT == S_IFDIR,
              Darwin.fchmod(descriptor, 0o700) == 0 else {
            throw GrokCLIHomeError.unsafePath
        }
    }

    private static func validateEmptyHooksDirectoryIfPresent(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        var linkInformation = stat()
        guard Darwin.lstat(path, &linkInformation) == 0 else {
            if errno == ENOENT { return }
            throw GrokCLIHomeError.unavailable
        }
        guard linkInformation.st_mode & S_IFMT == S_IFDIR,
              linkInformation.st_uid == Darwin.getuid() else {
            throw GrokCLIHomeError.unsafePath
        }

        let descriptor = Darwin.open(
            path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw GrokCLIHomeError.unsafePath }
        defer { Darwin.close(descriptor) }
        var openedInformation = stat()
        guard Darwin.fstat(descriptor, &openedInformation) == 0,
              openedInformation.st_dev == linkInformation.st_dev,
              openedInformation.st_ino == linkInformation.st_ino,
              openedInformation.st_uid == Darwin.getuid(),
              openedInformation.st_mode & S_IFMT == S_IFDIR else {
            throw GrokCLIHomeError.unsafePath
        }

        let enumerationDescriptor = Darwin.dup(descriptor)
        guard enumerationDescriptor >= 0 else { throw GrokCLIHomeError.unavailable }
        guard let directory = Darwin.fdopendir(enumerationDescriptor) else {
            Darwin.close(enumerationDescriptor)
            throw GrokCLIHomeError.unavailable
        }
        defer { Darwin.closedir(directory) }
        errno = 0
        while let entry = Darwin.readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." {
                throw GrokCLIHomeError.unsafePath
            }
        }
        guard errno == 0 else { throw GrokCLIHomeError.unavailable }
        guard Darwin.fchmod(descriptor, 0o700) == 0 else {
            throw GrokCLIHomeError.unavailable
        }
    }

    private static func validateEmptyHooksRegistryIfPresent(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        var linkInformation = stat()
        guard Darwin.lstat(path, &linkInformation) == 0 else {
            if errno == ENOENT { return }
            throw GrokCLIHomeError.unavailable
        }
        guard linkInformation.st_mode & S_IFMT == S_IFREG,
              linkInformation.st_uid == Darwin.getuid(),
              linkInformation.st_nlink == 1 else {
            throw GrokCLIHomeError.unsafePath
        }

        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw GrokCLIHomeError.unsafePath }
        defer { Darwin.close(descriptor) }
        var openedInformation = stat()
        guard Darwin.fstat(descriptor, &openedInformation) == 0,
              openedInformation.st_dev == linkInformation.st_dev,
              openedInformation.st_ino == linkInformation.st_ino,
              openedInformation.st_uid == Darwin.getuid(),
              openedInformation.st_nlink == 1,
              openedInformation.st_mode & S_IFMT == S_IFREG,
              openedInformation.st_size == 0,
              Darwin.fchmod(descriptor, 0o600) == 0 else {
            throw GrokCLIHomeError.unsafePath
        }
    }
}

final class GrokCLIHomeLease: @unchecked Sendable {
    private final class LeaseRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var heldPaths = Set<String>()

        func insert(_ path: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return heldPaths.insert(path).inserted
        }

        func remove(_ path: String) {
            lock.lock()
            heldPaths.remove(path)
            lock.unlock()
        }
    }

    private static let registry = LeaseRegistry()
    private let stateLock = NSLock()
    private let lockPath: String
    private var descriptor: Int32?

    fileprivate init(lockFileURL: URL) throws {
        let path = lockFileURL.standardizedFileURL.path
        guard path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw GrokCLIHomeError.unsafePath
        }
        guard Self.registry.insert(path) else { throw GrokCLIHomeError.busy }

        let descriptor = Darwin.open(
            path,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else {
            Self.registry.remove(path)
            throw errno == ELOOP
                ? GrokCLIHomeError.unsafePath
                : GrokCLIHomeError.unavailable
        }

        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              information.st_uid == Darwin.getuid(),
              information.st_nlink == 1,
              information.st_mode & S_IFMT == S_IFREG,
              Darwin.fchmod(descriptor, 0o600) == 0 else {
            Darwin.close(descriptor)
            Self.registry.remove(path)
            throw GrokCLIHomeError.unsafePath
        }
        var fileLock = flock()
        fileLock.l_type = Int16(F_WRLCK)
        fileLock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(descriptor, F_SETLK, &fileLock) != -1 else {
            let lockError = errno
            Darwin.close(descriptor)
            Self.registry.remove(path)
            throw lockError == EACCES || lockError == EAGAIN
                ? GrokCLIHomeError.busy
                : GrokCLIHomeError.unavailable
        }
        lockPath = path
        self.descriptor = descriptor
    }

    func release() {
        stateLock.lock()
        let descriptor = descriptor
        self.descriptor = nil
        stateLock.unlock()
        guard let descriptor else { return }
        var fileLock = flock()
        fileLock.l_type = Int16(F_UNLCK)
        fileLock.l_whence = Int16(SEEK_SET)
        _ = Darwin.fcntl(descriptor, F_SETLK, &fileLock)
        Darwin.close(descriptor)
        Self.registry.remove(lockPath)
    }

    deinit {
        release()
    }
}

final class GrokCLIHomeLeaseOwnership: @unchecked Sendable {
    enum InitialOwner: Equatable {
        case login
        case runtimeBuilder
    }

    private enum State: Equatable {
        case login
        case runtimeBuilder
        case finalizing
        case runtime
        case released
    }

    private let lock = NSLock()
    private let lease: GrokCLIHomeLease
    private var state: State

    init(lease: GrokCLIHomeLease, initialOwner: InitialOwner) {
        self.lease = lease
        state = initialOwner == .login ? .login : .runtimeBuilder
    }

    func beginFinalization() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .login else { return false }
        state = .finalizing
        return true
    }

    func isFinalizing() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .finalizing
    }

    func transferToRuntime() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .runtimeBuilder || state == .finalizing else {
            return false
        }
        state = .runtime
        return true
    }

    func releaseLogin() {
        release(if: { $0 == .login })
    }

    func releaseBuilderOrFinalizer() {
        release(if: { $0 == .runtimeBuilder || $0 == .finalizing })
    }

    func releaseRuntime() {
        release(if: { $0 == .runtime })
    }

    private func release(if ownsLease: (State) -> Bool) {
        lock.lock()
        let shouldRelease = ownsLease(state)
        if shouldRelease { state = .released }
        lock.unlock()
        if shouldRelease { lease.release() }
    }

    deinit {
        release(if: { $0 != .released })
    }
}

enum OAuthCLIProcessProvider: Sendable {
    case codex
    case grok
}

struct SupervisedLineProcessConfiguration: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let currentDirectoryURL: URL
    let environment: [String: String]
    let maximumLineBytes: Int
    let terminationGraceNanoseconds: UInt64
    let allowsSuccessfulExit: Bool

    fileprivate let ownedTemporaryDirectories: [OwnedTemporaryDirectory]
    fileprivate let requiredImmutableFiles: [OwnedImmutableFile]

    init(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL,
        environment: [String: String],
        maximumLineBytes: Int,
        terminationGraceNanoseconds: UInt64,
        allowsSuccessfulExit: Bool = true
    ) {
        self.init(
            executableURL: executableURL,
            arguments: arguments,
            currentDirectoryURL: currentDirectoryURL,
            environment: environment,
            maximumLineBytes: maximumLineBytes,
            terminationGraceNanoseconds: terminationGraceNanoseconds,
            allowsSuccessfulExit: allowsSuccessfulExit,
            ownedTemporaryDirectories: [],
            requiredImmutableFiles: []
        )
    }

    fileprivate init(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL,
        environment: [String: String],
        maximumLineBytes: Int,
        terminationGraceNanoseconds: UInt64,
        allowsSuccessfulExit: Bool = true,
        ownedTemporaryDirectories: [OwnedTemporaryDirectory],
        requiredImmutableFiles: [OwnedImmutableFile] = []
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.currentDirectoryURL = currentDirectoryURL
        self.environment = environment
        self.maximumLineBytes = maximumLineBytes
        self.terminationGraceNanoseconds = terminationGraceNanoseconds
        self.allowsSuccessfulExit = allowsSuccessfulExit
        self.ownedTemporaryDirectories = ownedTemporaryDirectories
        self.requiredImmutableFiles = requiredImmutableFiles
    }
}

enum SupervisedLineProcessError: Error, Equatable, Sendable {
    case invalidConfiguration
    case alreadyStarted
    case notStarted
    case closed
    case launchFailed
    case writeFailed
    case readFailed
    case lineTooLarge
    case outputBufferExceeded
    case processExited(Int32)
}

extension SupervisedLineProcessError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "The supervised process configuration is invalid."
        case .alreadyStarted:
            "The supervised process has already started."
        case .notStarted:
            "The supervised process has not started."
        case .closed:
            "The supervised process is closed."
        case .launchFailed:
            "The supervised process could not be launched."
        case .writeFailed:
            "The supervised process input could not be written."
        case .readFailed:
            "The supervised process output could not be read."
        case .lineTooLarge:
            "The supervised process emitted an oversized line."
        case .outputBufferExceeded:
            "The supervised process output buffer limit was exceeded."
        case let .processExited(code):
            "The supervised process exited with status \(code)."
        }
    }
}

actor SupervisedLineProcess: JSONLineTransport {
    private enum State {
        case idle
        case running(RunningProcess)
        case closing(Task<Void, Never>)
        case finished
    }

    private struct RunningProcess: Sendable {
        let identifier: pid_t
        let input: LockedFileDescriptor
        let control: ProcessControl
        let lifecycle: Task<Void, Never>
    }

    private static let permittedEnvironmentKeys = Set([
        "HOME", "PATH", "LANG", "LC_ALL", "TMPDIR", "CODEX_HOME", "GROK_HOME",
        "GROK_CURSOR_SKILLS_ENABLED", "GROK_CURSOR_RULES_ENABLED",
        "GROK_CURSOR_AGENTS_ENABLED", "GROK_CURSOR_MCPS_ENABLED",
        "GROK_CURSOR_HOOKS_ENABLED", "GROK_CURSOR_SESSIONS_ENABLED",
        "GROK_CLAUDE_SKILLS_ENABLED", "GROK_CLAUDE_RULES_ENABLED",
        "GROK_CLAUDE_AGENTS_ENABLED", "GROK_CLAUDE_MCPS_ENABLED",
        "GROK_CLAUDE_HOOKS_ENABLED", "GROK_CLAUDE_SESSIONS_ENABLED",
        "GROK_CODEX_SESSIONS_ENABLED"
    ])

    private let configuration: SupervisedLineProcessConfiguration
    private let lineChannel: BoundedLineChannel
    private var state: State = .idle
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    init(configuration: SupervisedLineProcessConfiguration) throws {
        guard configuration.executableURL.isFileURL,
              configuration.executableURL.path.hasPrefix("/"),
              configuration.currentDirectoryURL.isFileURL,
              configuration.currentDirectoryURL.path.hasPrefix("/"),
              configuration.maximumLineBytes > 0,
              configuration.maximumLineBytes <= 1_048_576,
              Set(configuration.environment.keys).isSubset(of: Self.permittedEnvironmentKeys),
              Self.containsNoNullByte(configuration.executableURL.path),
              configuration.arguments.allSatisfy(Self.containsNoNullByte),
              configuration.environment.allSatisfy({
                  Self.containsNoNullByte($0.key)
                      && !$0.key.contains("=")
                      && Self.containsNoNullByte($0.value)
              }),
              Self.isDirectory(configuration.currentDirectoryURL) else {
            throw SupervisedLineProcessError.invalidConfiguration
        }

        self.configuration = configuration
        lineChannel = BoundedLineChannel(
            maximumLineBytes: configuration.maximumLineBytes,
            maximumBufferedBytes: max(2_097_152, configuration.maximumLineBytes)
        )
    }

    var processIdentifier: pid_t? {
        switch state {
        case let .running(process):
            process.control.hasExited ? nil : process.identifier
        case .idle, .closing, .finished:
            nil
        }
    }

    func start() async throws {
        switch state {
        case .idle:
            break
        case .running, .closing:
            throw SupervisedLineProcessError.alreadyStarted
        case .finished:
            throw SupervisedLineProcessError.closed
        }

        guard configuration.requiredImmutableFiles.allSatisfy({ $0.isValid() }) else {
            throw SupervisedLineProcessError.invalidConfiguration
        }

        let spawned = try Self.spawn(configuration: configuration)
        let control = spawned.control
        let input = LockedFileDescriptor(spawned.standardInput)
        let lineChannel = lineChannel

        let standardOutputTask = Task.detached(priority: .userInitiated) {
            await Self.consumeStandardOutput(
                descriptor: spawned.standardOutput,
                channel: lineChannel,
                control: control
            )
        }
        let standardErrorTask = Task.detached(priority: .utility) {
            Self.discardStandardError(
                descriptor: spawned.standardError,
                control: control
            )
        }
        let processMonitor = control.takeProcessMonitor()
        let waitTask = Task.detached(priority: .userInitiated) {
            Self.waitForExit(
                of: spawned.identifier,
                processMonitor: processMonitor
            )
        }
        let allowsSuccessfulExit = configuration.allowsSuccessfulExit
        let lifecycle = Task.detached(priority: .userInitiated) {
            let exitCode = await waitTask.value
            control.markExited(exitCode: exitCode)
            input.close()
            let outputError = await standardOutputTask.value
            await standardErrorTask.value
            control.markFullyDrained()

            if control.wasClosedIntentionally {
                await lineChannel.finish(with: nil)
            } else if let outputError {
                await lineChannel.finish(with: outputError)
            } else if exitCode == 0, allowsSuccessfulExit {
                await lineChannel.finish(with: nil)
            } else {
                // A protocol runtime is expected to remain available until
                // `close()` marks the shutdown intentional. Even exit(0) is
                // therefore an unexpected transport termination and must not
                // be collapsed into an ambiguous EOF.
                await lineChannel.finish(with: .processExited(exitCode))
            }
        }

        state = .running(
            RunningProcess(
                identifier: spawned.identifier,
                input: input,
                control: control,
                lifecycle: lifecycle
            )
        )
    }

    func writeLine(_ data: Data) async throws {
        guard data.count <= configuration.maximumLineBytes,
              !data.contains(0x0A),
              !data.contains(0x0D) else {
            throw SupervisedLineProcessError.lineTooLarge
        }

        guard case let .running(process) = state else {
            switch state {
            case .idle:
                throw SupervisedLineProcessError.notStarted
            case .running:
                preconditionFailure("Unreachable state")
            case .closing, .finished:
                throw SupervisedLineProcessError.closed
            }
        }
        guard !process.control.hasExited else {
            throw SupervisedLineProcessError.processExited(
                process.control.exitCode ?? -1
            )
        }

        var framedData = data
        framedData.append(0x0A)
        let input = process.input
        let didWrite = await Task.detached(priority: .userInitiated) {
            input.writeAll(framedData)
        }.value
        guard didWrite else {
            throw SupervisedLineProcessError.writeFailed
        }
    }

    func readLine() async throws -> Data? {
        switch state {
        case .idle:
            throw SupervisedLineProcessError.notStarted
        case .running, .closing, .finished:
            return try await lineChannel.next()
        }
    }

    func close() async {
        let running: RunningProcess
        switch state {
        case .idle:
            state = .finished
            await lineChannel.finish(with: nil)
            removeOwnedTemporaryDirectories()
            return
        case let .running(process):
            running = process
            state = .closing(process.lifecycle)
        case .closing:
            await withCheckedContinuation { continuation in
                closeWaiters.append(continuation)
            }
            return
        case .finished:
            return
        }

        running.control.beginIntentionalClose()
        running.input.close()
        var hasLivingProcesses = running.control.signalOwnedProcesses(SIGTERM)

        let graceNanoseconds = configuration.terminationGraceNanoseconds
        let terminationDeadline = DispatchTime.now().uptimeNanoseconds + graceNanoseconds
        // The full-system pid scan inside signalOwnedProcesses is expensive;
        // within the drain loops re-run it at most every 100ms and signal the
        // cached tracked set in between. The first SIGTERM, the SIGTERM→SIGKILL
        // transition, and the final SIGKILL always rescan.
        var lastScanNanoseconds = DispatchTime.now().uptimeNanoseconds
        while (!running.control.isFullyDrained || hasLivingProcesses),
              DispatchTime.now().uptimeNanoseconds < terminationDeadline {
            try? await Task.sleep(nanoseconds: min(100_000_000, graceNanoseconds))
            let now = DispatchTime.now().uptimeNanoseconds
            let shouldRescan = now - lastScanNanoseconds >= 100_000_000
            hasLivingProcesses = running.control.signalOwnedProcesses(
                SIGTERM,
                rescan: shouldRescan
            )
            if shouldRescan { lastScanNanoseconds = now }
        }
        hasLivingProcesses = running.control.signalOwnedProcesses(SIGKILL)
        lastScanNanoseconds = DispatchTime.now().uptimeNanoseconds

        let drainDeadline = DispatchTime.now().uptimeNanoseconds
            + max(graceNanoseconds, 100_000_000)
        while (!running.control.isFullyDrained || hasLivingProcesses),
              DispatchTime.now().uptimeNanoseconds < drainDeadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            let now = DispatchTime.now().uptimeNanoseconds
            let shouldRescan = now - lastScanNanoseconds >= 100_000_000
            hasLivingProcesses = running.control.signalOwnedProcesses(
                SIGKILL,
                rescan: shouldRescan
            )
            if shouldRescan { lastScanNanoseconds = now }
        }
        _ = running.control.signalOwnedProcesses(SIGKILL)
        if !running.control.isFullyDrained {
            running.control.stopDraining()
        }

        await running.lifecycle.value
        running.control.stopMonitoring()
        state = .finished
        removeOwnedTemporaryDirectories()
        let waiters = closeWaiters
        closeWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func removeOwnedTemporaryDirectories() {
        let fileManager = FileManager.default
        for owned in configuration.ownedTemporaryDirectories {
            let root = owned.rootURL.standardizedFileURL
            let directory = owned.directoryURL.standardizedFileURL
            guard directory.deletingLastPathComponent() == root,
                  directory.lastPathComponent.hasPrefix("xunjian-oauth-") else {
                continue
            }
            try? fileManager.removeItem(at: directory)
        }
    }

    private static func containsNoNullByte(_ value: String) -> Bool {
        !value.utf8.contains(0)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
    }

    private static func consumeStandardOutput(
        descriptor: Int32,
        channel: BoundedLineChannel,
        control: ProcessControl
    ) async -> SupervisedLineProcessError? {
        defer { Darwin.close(descriptor) }
        var buffer = [UInt8](repeating: 0, count: 16_384)
        // Adaptive idle backoff: 10ms while data is flowing so responses
        // stay snappy, backing off to 100ms when the pipe is quiet so a
        // long-lived idle runtime does not wake the drain task 100 times a
        // second.
        var consecutiveEmptyPolls = 0

        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                consecutiveEmptyPolls = 0
                let outcome = await channel.append(Data(buffer.prefix(count)))
                if let outcome {
                    _ = control.signalOwnedProcesses(SIGKILL)
                    return outcome
                }
            } else if count == 0 {
                return await channel.finishPartialLine()
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                if control.shouldStopDraining { return nil }
                consecutiveEmptyPolls += 1
                try? await Task.sleep(
                    nanoseconds: consecutiveEmptyPolls > 3
                        ? 100_000_000
                        : 10_000_000
                )
            } else {
                _ = control.signalOwnedProcesses(SIGKILL)
                return .readFailed
            }
        }
    }

    private static func discardStandardError(
        descriptor: Int32,
        control: ProcessControl
    ) {
        defer { Darwin.close(descriptor) }
        var buffer = [UInt8](repeating: 0, count: 16_384)
        var consecutiveEmptyPolls = 0
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { return }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                if control.shouldStopDraining { return }
                consecutiveEmptyPolls += 1
                Thread.sleep(
                    forTimeInterval: consecutiveEmptyPolls > 3 ? 0.1 : 0.01
                )
                continue
            }
            if count < 0 { return }
            consecutiveEmptyPolls = 0
        }
    }

    /// Polls with WNOHANG instead of blocking: a child stuck in an
    /// uninterruptible state (D-state I/O) survives SIGKILL and would make a
    /// Waits for the actual process-exit event. The previous implementation
    /// started a five-second reap deadline at launch, so every healthy,
    /// long-lived OAuth runtime was incorrectly marked exited after five
    /// seconds. EVFILT_PROC also keeps this reliable in XPC hosts that may
    /// reap SIGCHLD before `waitpid` can observe the child.
    private static func waitForExit(
        of identifier: pid_t,
        processMonitor: Int32?
    ) -> Int32 {
        if let processMonitor {
            defer { Darwin.close(processMonitor) }
            var event = Darwin.kevent()
            while true {
                let result = kevent(
                    processMonitor,
                    nil,
                    0,
                    &event,
                    1,
                    nil
                )
                if result == -1, errno == EINTR { continue }
                guard result == 1,
                      event.filter == Int16(EVFILT_PROC) else {
                    return -1
                }
                // Grok forks helper processes during a prompt. NOTE_FORK is
                // informational for ownership tracking and must not be
                // mistaken for termination of the supervised root process.
                guard event.fflags & UInt32(NOTE_EXIT) != 0 else { continue }

                var processStatus: Int32 = 0
                let waited = waitpid(identifier, &processStatus, WNOHANG)
                if waited == identifier {
                    return decodedExitCode(from: processStatus)
                }
                guard event.fflags & UInt32(NOTE_EXITSTATUS) != 0 else {
                    return -1
                }
                return decodedExitCode(
                    from: Int32(truncatingIfNeeded: event.data)
                )
            }
        }

        var processStatus: Int32 = 0
        while true {
            let result = waitpid(identifier, &processStatus, 0)
            if result == identifier { break }
            if result == -1, errno == EINTR { continue }
            return -1
        }
        return decodedExitCode(from: processStatus)
    }

    private static func decodedExitCode(from processStatus: Int32) -> Int32 {
        let terminatingSignal = processStatus & 0x7F
        if terminatingSignal == 0 {
            return (processStatus >> 8) & 0xFF
        }
        return 128 + terminatingSignal
    }

    private struct SpawnedProcess {
        let identifier: pid_t
        let standardInput: Int32
        let standardOutput: Int32
        let standardError: Int32
        let control: ProcessControl
    }

    private static func spawn(
        configuration: SupervisedLineProcessConfiguration
    ) throws -> SpawnedProcess {
        let standardInput = try makePipe()
        let standardOutput: (read: Int32, write: Int32)
        do {
            standardOutput = try makePipe()
        } catch {
            closePipe(standardInput)
            throw error
        }
        let standardError: (read: Int32, write: Int32)
        do {
            standardError = try makePipe()
        } catch {
            closePipe(standardInput)
            closePipe(standardOutput)
            throw error
        }

        var shouldCloseAllDescriptors = true
        defer {
            if shouldCloseAllDescriptors {
                closePipe(standardInput)
                closePipe(standardOutput)
                closePipe(standardError)
            }
        }

        var fileActions: posix_spawn_file_actions_t? = nil
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw SupervisedLineProcessError.launchFailed
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        let fileActionResults = [
            posix_spawn_file_actions_adddup2(
                &fileActions,
                standardInput.read,
                STDIN_FILENO
            ),
            posix_spawn_file_actions_adddup2(
                &fileActions,
                standardOutput.write,
                STDOUT_FILENO
            ),
            posix_spawn_file_actions_adddup2(
                &fileActions,
                standardError.write,
                STDERR_FILENO
            ),
            posix_spawn_file_actions_addclose(&fileActions, standardInput.write),
            posix_spawn_file_actions_addclose(&fileActions, standardOutput.read),
            posix_spawn_file_actions_addclose(&fileActions, standardError.read),
            posix_spawn_file_actions_addclose(&fileActions, standardInput.read),
            posix_spawn_file_actions_addclose(&fileActions, standardOutput.write),
            posix_spawn_file_actions_addclose(&fileActions, standardError.write),
            posix_spawn_file_actions_addchdir_np(
                &fileActions,
                configuration.currentDirectoryURL.path
            )
        ]
        guard fileActionResults.allSatisfy({ $0 == 0 }) else {
            throw SupervisedLineProcessError.launchFailed
        }

        var attributes: posix_spawnattr_t? = nil
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw SupervisedLineProcessError.launchFailed
        }
        defer { posix_spawnattr_destroy(&attributes) }

        let spawnFlags = Int16(
            POSIX_SPAWN_START_SUSPENDED
                | POSIX_SPAWN_SETSID
                | POSIX_SPAWN_CLOEXEC_DEFAULT
        )
        guard posix_spawnattr_setflags(&attributes, spawnFlags) == 0 else {
            throw SupervisedLineProcessError.launchFailed
        }

        let arguments = [configuration.executableURL.path] + configuration.arguments
        var normalizedEnvironment = configuration.environment
        let temporaryDirectoryMarker = canonicalTemporaryDirectoryMarker(
            configuration: configuration
        )
        if let temporaryDirectoryMarker {
            normalizedEnvironment["TMPDIR"] = String(
                decoding: temporaryDirectoryMarker.dropFirst("TMPDIR=".utf8.count),
                as: UTF8.self
            )
        }
        let environment = normalizedEnvironment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        var identifier = pid_t()
        let spawnResult = withMutableCStringArray(arguments) { argumentPointer in
            withMutableCStringArray(environment) { environmentPointer in
                configuration.executableURL.path.withCString { executablePointer in
                    posix_spawn(
                        &identifier,
                        executablePointer,
                        &fileActions,
                        &attributes,
                        argumentPointer,
                        environmentPointer
                    )
                }
            }
        }
        guard spawnResult == 0 else {
            throw SupervisedLineProcessError.launchFailed
        }

        var processMonitor: Int32?
        do {
            let monitor = try makeProcessMonitor(identifier: identifier)
            processMonitor = monitor
            guard let rootIdentity = ProcessIdentity.capture(identifier),
                  let rootSessionIdentifier = validSessionIdentifier(for: identifier) else {
                throw SupervisedLineProcessError.launchFailed
            }
            let control = ProcessControl(
                rootIdentity: rootIdentity,
                rootSessionIdentifier: rootSessionIdentifier,
                temporaryDirectoryMarker: temporaryDirectoryMarker,
                processMonitor: monitor
            )
            processMonitor = nil

            guard Darwin.kill(identifier, SIGCONT) == 0 else {
                control.stopMonitoring()
                throw SupervisedLineProcessError.launchFailed
            }

            Darwin.close(standardInput.read)
            Darwin.close(standardOutput.write)
            Darwin.close(standardError.write)
            _ = fcntl(standardInput.write, F_SETNOSIGPIPE, 1)
            setNonblocking(standardOutput.read)
            setNonblocking(standardError.read)
            shouldCloseAllDescriptors = false
            return SpawnedProcess(
                identifier: identifier,
                standardInput: standardInput.write,
                standardOutput: standardOutput.read,
                standardError: standardError.read,
                control: control
            )
        } catch {
            if let processMonitor {
                Darwin.close(processMonitor)
            }
            terminateSuspendedProcess(identifier)
            throw error
        }
    }

    private static func canonicalTemporaryDirectoryMarker(
        configuration: SupervisedLineProcessConfiguration
    ) -> [UInt8]? {
        guard let path = configuration.environment["TMPDIR"],
              path.hasPrefix("/"),
              containsNoNullByte(path) else {
            return nil
        }

        let canonicalURL = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let ownsDirectory = configuration.ownedTemporaryDirectories.contains { owned in
            owned.directoryURL.standardizedFileURL.resolvingSymlinksInPath() == canonicalURL
        }
        let markerPrefix = "xunjian-oauth-tmp-"
        let markerName = canonicalURL.lastPathComponent
        let markerIdentifier = String(markerName.dropFirst(markerPrefix.count))
        let isUniqueMarker = markerName.hasPrefix(markerPrefix)
            && UUID(uuidString: markerIdentifier) != nil
        let isUnclaimedMarker = !FileManager.default.fileExists(atPath: canonicalURL.path)
        guard isUniqueMarker, ownsDirectory || isUnclaimedMarker else {
            return nil
        }
        return Array("TMPDIR=\(canonicalURL.path)".utf8)
    }

    private static func validSessionIdentifier(for identifier: pid_t) -> pid_t? {
        let sessionIdentifier = getsid(identifier)
        return sessionIdentifier == identifier ? sessionIdentifier : nil
    }

    private static func makeProcessMonitor(identifier: pid_t) throws -> Int32 {
        let descriptor = kqueue()
        guard descriptor >= 0 else {
            throw SupervisedLineProcessError.launchFailed
        }

        let flags = UInt16(EV_ADD)
            | UInt16(EV_ENABLE)
            | UInt16(EV_CLEAR)
            | UInt16(EV_RECEIPT)
        let notes = UInt32(NOTE_FORK)
            | UInt32(NOTE_EXIT)
            | UInt32(NOTE_EXITSTATUS)
        var change = Darwin.kevent(
            ident: UInt(identifier),
            filter: Int16(EVFILT_PROC),
            flags: flags,
            fflags: notes,
            data: 0,
            udata: nil
        )
        var receipt = Darwin.kevent()
        var timeout = timespec(tv_sec: 0, tv_nsec: 0)
        let result = kevent(
            descriptor,
            &change,
            1,
            &receipt,
            1,
            &timeout
        )
        guard result == 1,
              receipt.flags & UInt16(EV_ERROR) != 0,
              receipt.data == 0 else {
            Darwin.close(descriptor)
            throw SupervisedLineProcessError.launchFailed
        }
        return descriptor
    }

    private static func terminateSuspendedProcess(_ identifier: pid_t) {
        guard identifier > 1, identifier != getpid() else { return }
        _ = Darwin.kill(identifier, SIGKILL)
        var processStatus: Int32 = 0
        while waitpid(identifier, &processStatus, 0) == -1, errno == EINTR {}
    }

    private static func makePipe() throws -> (read: Int32, write: Int32) {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard Darwin.pipe(&descriptors) == 0 else {
            throw SupervisedLineProcessError.launchFailed
        }
        guard fcntl(descriptors[0], F_SETFD, FD_CLOEXEC) == 0,
              fcntl(descriptors[1], F_SETFD, FD_CLOEXEC) == 0 else {
            Darwin.close(descriptors[0])
            Darwin.close(descriptors[1])
            throw SupervisedLineProcessError.launchFailed
        }
        return (descriptors[0], descriptors[1])
    }

    private static func closePipe(_ pipe: (read: Int32, write: Int32)) {
        Darwin.close(pipe.read)
        Darwin.close(pipe.write)
    }

    private static func setNonblocking(_ descriptor: Int32) {
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 {
            _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        }
    }

    private static func withMutableCStringArray<Result>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
    ) -> Result {
        var pointers = strings.map { strdup($0) }
        pointers.append(nil)
        defer {
            for pointer in pointers.dropLast() {
                free(pointer)
            }
        }
        return pointers.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }
}

enum OAuthCLIProcessSecurity {
    private static let grokAgentProfileName = "xunjian-connection-verifier.md"
    private static let grokAgentProfileContents = Data(
        (
            "---\n"
                + "name: xunjian-connection-verifier\n"
                + "description: Connection verification with no executable tools.\n"
                + "permissionMode: dontAsk\n"
                + "tools:\n"
                + "  - read_file\n"
                + "disallowedTools:\n"
                + "  - read_file\n"
                + "  - search_tool\n"
                + "  - use_tool\n"
                + "discoverSkills: false\n"
                + "inheritSkills: false\n"
                + "injectDefaultTools: false\n"
                + "---\n"
                + "Connection verification only.\n"
        ).utf8
    )
    private static let grokDisallowedToolIdentifiers = [
        "run_terminal_command",
        "read_file",
        "search_replace",
        "list_dir",
        "grep",
        "kill_command_or_subagent",
        "todo_write",
        "get_command_or_subagent_output",
        "spawn_subagent",
        "scheduler_create",
        "scheduler_delete",
        "scheduler_list",
        "monitor",
        "search_tool",
        "use_tool",
        "workflow",
        "enter_plan_mode",
        "exit_plan_mode",
        "ask_user_question",
        "image_gen",
        "image_edit",
        "image_to_video",
        "reference_to_video",
        "write",
        "Agent"
    ]

    static func makeConfiguration(
        provider: OAuthCLIProcessProvider,
        executableURL: URL,
        homeDirectoryURL: URL,
        codexHomeDirectoryURL: URL? = nil,
        grokHomeDirectoryURL: URL? = nil,
        temporaryRootURL: URL
    ) throws -> SupervisedLineProcessConfiguration {
        if provider == .grok {
            guard let grokHomeDirectoryURL else {
                throw SupervisedLineProcessError.invalidConfiguration
            }
            return try makeGrokConfiguration(
                executableURL: executableURL,
                grokHomeDirectoryURL: grokHomeDirectoryURL,
                temporaryRootURL: temporaryRootURL,
                arguments: [
                    "--no-auto-update",
                    "--permission-mode", "dontAsk",
                    "--deny", "*",
                    "--disallowed-tools",
                    grokDisallowedToolIdentifiers.joined(separator: ","),
                    "--disable-web-search",
                    "--no-memory",
                    "--no-subagents",
                    "--sandbox", "strict",
                    "--cwd", "__XUNJIAN_WORKING_DIRECTORY__",
                    "agent", "--no-leader",
                    "--model", GrokACPClient.fixedModelID,
                    "--reasoning-effort", "high",
                    "--agent-profile", "__XUNJIAN_AGENT_PROFILE__",
                    "stdio"
                ],
                substitutesWorkingDirectory: true,
                agentProfileContents: grokAgentProfileContents,
                maximumLineBytes: 1_048_576,
                allowsSuccessfulExit: false
            )
        }

        guard let codexHomeDirectoryURL,
              isPrivateOwnedDirectory(codexHomeDirectoryURL) else {
            throw SupervisedLineProcessError.invalidConfiguration
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: temporaryRootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: temporaryRootURL.path
        )

        let workingDirectoryURL = temporaryRootURL.appending(
            path: "xunjian-oauth-cwd-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let processTemporaryURL = temporaryRootURL.appending(
            path: "xunjian-oauth-tmp-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let processHomeURL = temporaryRootURL.appending(
            path: "xunjian-oauth-home-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        for directory in [workingDirectoryURL, processTemporaryURL, processHomeURL] {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }

        let root = temporaryRootURL.standardizedFileURL
        let ownedDirectories = [workingDirectoryURL, processTemporaryURL, processHomeURL].map {
            OwnedTemporaryDirectory(rootURL: root, directoryURL: $0.standardizedFileURL)
        }
        return SupervisedLineProcessConfiguration(
            executableURL: executableURL.standardizedFileURL,
            arguments: [
                "--config", "skills.bundled.enabled=false",
                "--config", "features.plugins=false",
                "--listen", "stdio://"
            ],
            currentDirectoryURL: workingDirectoryURL,
            environment: [
                "HOME": processHomeURL.path,
                "CODEX_HOME": codexHomeDirectoryURL.standardizedFileURL.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "LANG": "en_US.UTF-8",
                "LC_ALL": "en_US.UTF-8",
                "TMPDIR": processTemporaryURL.path
            ],
            maximumLineBytes: 1_048_576,
            terminationGraceNanoseconds: 1_000_000_000,
            allowsSuccessfulExit: false,
            ownedTemporaryDirectories: ownedDirectories
        )
    }

    private static func isPrivateOwnedDirectory(_ url: URL) -> Bool {
        guard url.isFileURL,
              url.path.hasPrefix("/"),
              !url.path.utf8.contains(0) else {
            return false
        }
        let descriptor = Darwin.open(
            url.standardizedFileURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var information = stat()
        return Darwin.fstat(descriptor, &information) == 0
            && information.st_uid == Darwin.getuid()
            && information.st_mode & S_IFMT == S_IFDIR
            && information.st_mode & 0o777 == 0o700
    }

    static func makeGrokLoginConfiguration(
        executableURL: URL,
        grokHomeDirectoryURL: URL,
        temporaryRootURL: URL
    ) throws -> SupervisedLineProcessConfiguration {
        try makeGrokConfiguration(
            executableURL: executableURL,
            grokHomeDirectoryURL: grokHomeDirectoryURL,
            temporaryRootURL: temporaryRootURL,
            arguments: ["--no-auto-update", "login", "--oauth"],
            substitutesWorkingDirectory: false,
            maximumLineBytes: 1_048_576
        )
    }

    static func makeGrokLogoutConfiguration(
        executableURL: URL,
        grokHomeDirectoryURL: URL,
        temporaryRootURL: URL
    ) throws -> SupervisedLineProcessConfiguration {
        try makeGrokConfiguration(
            executableURL: executableURL,
            grokHomeDirectoryURL: grokHomeDirectoryURL,
            temporaryRootURL: temporaryRootURL,
            arguments: ["--no-auto-update", "logout"],
            substitutesWorkingDirectory: false,
            maximumLineBytes: 16_384
        )
    }

    static func makeGrokInspectionConfiguration(
        executableURL: URL,
        grokHomeDirectoryURL: URL,
        processHomeDirectoryURL: URL,
        temporaryRootURL: URL
    ) throws -> SupervisedLineProcessConfiguration {
        try makeGrokConfiguration(
            executableURL: executableURL,
            grokHomeDirectoryURL: grokHomeDirectoryURL,
            processHomeDirectoryURL: processHomeDirectoryURL,
            temporaryRootURL: temporaryRootURL,
            arguments: ["--no-auto-update", "inspect", "--json"],
            substitutesWorkingDirectory: false,
            maximumLineBytes: 262_144
        )
    }

    static func makeGrokSessionDeletionConfiguration(
        executableURL: URL,
        grokHomeDirectoryURL: URL,
        sessionID: String,
        temporaryRootURL: URL
    ) throws -> SupervisedLineProcessConfiguration {
        guard sessionID.utf8.count == 36,
              let identifier = UUID(uuidString: sessionID),
              identifier.uuidString.caseInsensitiveCompare(sessionID) == .orderedSame else {
            throw SupervisedLineProcessError.invalidConfiguration
        }
        return try makeGrokConfiguration(
            executableURL: executableURL,
            grokHomeDirectoryURL: grokHomeDirectoryURL,
            temporaryRootURL: temporaryRootURL,
            arguments: [
                "--no-auto-update", "sessions", "delete", sessionID
            ],
            substitutesWorkingDirectory: false,
            maximumLineBytes: 16_384
        )
    }

    private static func makeGrokConfiguration(
        executableURL: URL,
        grokHomeDirectoryURL: URL,
        processHomeDirectoryURL suppliedProcessHomeURL: URL? = nil,
        temporaryRootURL: URL,
        arguments: [String],
        substitutesWorkingDirectory: Bool,
        agentProfileContents: Data? = nil,
        maximumLineBytes: Int,
        allowsSuccessfulExit: Bool = true
    ) throws -> SupervisedLineProcessConfiguration {
        guard isPrivateDirectory(grokHomeDirectoryURL) else {
            throw SupervisedLineProcessError.invalidConfiguration
        }
        if let suppliedProcessHomeURL {
            guard isPrivateDirectory(suppliedProcessHomeURL),
                  suppliedProcessHomeURL.standardizedFileURL
                    != grokHomeDirectoryURL.standardizedFileURL else {
                throw SupervisedLineProcessError.invalidConfiguration
            }
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: temporaryRootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: temporaryRootURL.path
        )

        let workingDirectoryURL = temporaryRootURL.appending(
            path: "xunjian-oauth-cwd-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let processTemporaryURL = temporaryRootURL.appending(
            path: "xunjian-oauth-tmp-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let processHomeURL = suppliedProcessHomeURL?.standardizedFileURL
            ?? temporaryRootURL.appending(
                path: "xunjian-oauth-home-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        let ownedDirectoriesToCreate = [workingDirectoryURL, processTemporaryURL]
            + (suppliedProcessHomeURL == nil ? [processHomeURL] : [])
        for directory in ownedDirectoriesToCreate {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }

        let agentProfile: OwnedImmutableFile?
        if let agentProfileContents {
            agentProfile = try OwnedImmutableFile.create(
                in: workingDirectoryURL,
                name: grokAgentProfileName,
                contents: agentProfileContents
            )
        } else {
            agentProfile = nil
        }

        let resolvedArguments = arguments.map {
            if $0 == "__XUNJIAN_WORKING_DIRECTORY__", substitutesWorkingDirectory {
                return workingDirectoryURL.path
            }
            if $0 == "__XUNJIAN_AGENT_PROFILE__", let agentProfile {
                return agentProfile.fileURL.path
            }
            return $0
        }
        guard !resolvedArguments.contains("__XUNJIAN_AGENT_PROFILE__") else {
            throw SupervisedLineProcessError.invalidConfiguration
        }
        let root = temporaryRootURL.standardizedFileURL
        let ownedDirectories = ownedDirectoriesToCreate.map {
            OwnedTemporaryDirectory(rootURL: root, directoryURL: $0.standardizedFileURL)
        }
        return SupervisedLineProcessConfiguration(
            executableURL: executableURL.standardizedFileURL,
            arguments: resolvedArguments,
            currentDirectoryURL: workingDirectoryURL,
            environment: grokEnvironment(
                processHomeURL: processHomeURL,
                grokHomeDirectoryURL: grokHomeDirectoryURL,
                processTemporaryURL: processTemporaryURL
            ),
            maximumLineBytes: maximumLineBytes,
            terminationGraceNanoseconds: 1_000_000_000,
            allowsSuccessfulExit: allowsSuccessfulExit,
            ownedTemporaryDirectories: ownedDirectories,
            requiredImmutableFiles: agentProfile.map { [$0] } ?? []
        )
    }

    private static func grokEnvironment(
        processHomeURL: URL,
        grokHomeDirectoryURL: URL,
        processTemporaryURL: URL
    ) -> [String: String] {
        [
            "HOME": processHomeURL.standardizedFileURL.path,
            "GROK_HOME": grokHomeDirectoryURL.standardizedFileURL.path,
            "GROK_CURSOR_SKILLS_ENABLED": "0",
            "GROK_CURSOR_RULES_ENABLED": "0",
            "GROK_CURSOR_AGENTS_ENABLED": "0",
            "GROK_CURSOR_MCPS_ENABLED": "0",
            "GROK_CURSOR_HOOKS_ENABLED": "0",
            "GROK_CURSOR_SESSIONS_ENABLED": "0",
            "GROK_CLAUDE_SKILLS_ENABLED": "0",
            "GROK_CLAUDE_RULES_ENABLED": "0",
            "GROK_CLAUDE_AGENTS_ENABLED": "0",
            "GROK_CLAUDE_MCPS_ENABLED": "0",
            "GROK_CLAUDE_HOOKS_ENABLED": "0",
            "GROK_CLAUDE_SESSIONS_ENABLED": "0",
            "GROK_CODEX_SESSIONS_ENABLED": "0",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "TMPDIR": processTemporaryURL.standardizedFileURL.path
        ]
    }

    private static func isPrivateDirectory(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        var information = stat()
        return path.hasPrefix("/")
            && !path.utf8.contains(0)
            && Darwin.lstat(path, &information) == 0
            && information.st_uid == Darwin.getuid()
            && information.st_mode & S_IFMT == S_IFDIR
            && information.st_mode & 0o077 == 0
    }
}

enum GrokSafetyInspectionPolicy {
    static func isSafe(
        _ data: Data,
        expectedWorkingDirectoryURL: URL? = nil,
        expectedGrokHomeDirectoryURL: URL
    ) -> Bool {
        guard !data.isEmpty,
              data.count <= 262_144,
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let root = value.objectValue,
              Set(root.keys) == expectedRootKeys,
              root["grokVersion"] == .string("1.0.0"),
              root["channel"] == .string("unknown"),
              let reportedWorkingDirectory = root["cwd"]?.stringValue,
              reportedWorkingDirectory.hasPrefix("/"),
              root["projectRoot"] == .null,
              root["projectTrusted"] == .bool(true),
              root["projectInstructions"] == .array([]),
              root["skills"] == .array([]),
              root["marketplaces"] == .array([]) else {
            return false
        }
        if let expectedWorkingDirectoryURL,
           URL(fileURLWithPath: reportedWorkingDirectory, isDirectory: true)
            .standardizedFileURL != expectedWorkingDirectoryURL.standardizedFileURL {
            return false
        }

        for key in ["hooks", "plugins", "mcpServers", "lspServers"] {
            guard root[key] == .array([]) else { return false }
        }

        guard validateBuiltInAgents(root["agents"]),
              let permissions = root["permissions"]?.objectValue,
              Set(permissions.keys) == expectedPermissionKeys,
              permissions["sources"] == .array([]),
              permissions["loaded"] == .integer(0),
              permissions["skipped"] == .array([]),
              permissions["mcpServerAllowlist"] == .array([]),
              permissions["marketplaceAllowlist"] == .array([]),
              permissions["managedSettingsPath"]
                == .string("/Library/Application Support/ClaudeCode/managed-settings.json"),
              permissions["managedSettingsExists"] == .bool(false),
              permissions["managedSettingsActive"] == .bool(false),
              let loginPolicy = root["loginPolicy"]?.objectValue,
              Set(loginPolicy.keys) == Set([
                "disableApiKeyAuth", "forceLoginTeamUuid", "apiKeyAuthDisabled"
              ]),
              loginPolicy["disableApiKeyAuth"] == .null,
              loginPolicy["forceLoginTeamUuid"] == .null,
              loginPolicy["apiKeyAuthDisabled"] == .bool(false),
              validateConfigurationSources(
                root["configSources"],
                expectedGrokHomeDirectoryURL: expectedGrokHomeDirectoryURL
              ),
              let externalCompat = root["externalCompat"]?.objectValue,
              Set(externalCompat.keys) == Set(["remoteSettingsLoaded", "cells"]),
              externalCompat["remoteSettingsLoaded"] == .bool(false),
              let cells = externalCompat["cells"]?.arrayValue,
              cells.count == expectedExternalCompatCells.count else {
            return false
        }

        var observedCells = Set<ExternalCompatCell>()
        for value in cells {
            guard let cell = value.objectValue,
                  Set(cell.keys) == Set(["vendor", "surface", "enabled", "source"]),
                  let vendor = cell["vendor"]?.stringValue,
                  let surface = cell["surface"]?.stringValue,
                  cell["enabled"] == .bool(false),
                  cell["source"] == .string("env") else {
                return false
            }
            guard observedCells.insert(
                ExternalCompatCell(vendor: vendor, surface: surface)
            ).inserted else {
                return false
            }
        }
        return observedCells == expectedExternalCompatCells
    }

    private static func validateConfigurationSources(
        _ value: JSONValue?,
        expectedGrokHomeDirectoryURL: URL
    ) -> Bool {
        guard let sources = value?.objectValue,
              Set(sources.keys) == Set(["layers"]),
              let layers = sources["layers"]?.arrayValue,
              layers.count == 1,
              let layer = layers[0].objectValue,
              Set(layer.keys) == Set(["path", "role"]),
              layer["role"] == .string("user"),
              let reportedPath = layer["path"]?.stringValue else {
            return false
        }
        let expectedPath = expectedGrokHomeDirectoryURL
            .standardizedFileURL
            .appending(path: "config.toml")
            .path
        return reportedPath == expectedPath
    }

    private static func validateBuiltInAgents(_ value: JSONValue?) -> Bool {
        guard let agents = value?.arrayValue,
              agents.count == expectedBuiltInAgents.count else {
            return false
        }
        var observed = Set<BuiltInAgent>()
        for value in agents {
            guard let agent = value.objectValue,
                  Set(agent.keys) == Set(["description", "name", "source"]),
                  let name = agent["name"]?.stringValue,
                  let description = agent["description"]?.stringValue,
                  let source = agent["source"]?.objectValue,
                  Set(source.keys) == Set(["type"]),
                  source["type"] == .string("builtin"),
                  observed.insert(
                    BuiltInAgent(name: name, description: description)
                  ).inserted else {
                return false
            }
        }
        return observed == expectedBuiltInAgents
    }

    private struct ExternalCompatCell: Hashable, Sendable {
        let vendor: String
        let surface: String
    }

    private struct BuiltInAgent: Hashable, Sendable {
        let name: String
        let description: String
    }

    private static let expectedBuiltInAgents: Set<BuiltInAgent> = [
        BuiltInAgent(
            name: "general-purpose",
            description: "General purpose agent for multi-step tasks."
        ),
        BuiltInAgent(
            name: "explore",
            description: "Fast, read-only agent specialized for codebase exploration."
        ),
        BuiltInAgent(
            name: "plan",
            description: "Software architect for planning implementation strategies."
        )
    ]

    private static let expectedExternalCompatCells: Set<ExternalCompatCell> = {
        var cells = Set<ExternalCompatCell>()
        for vendor in ["cursor", "claude"] {
            for surface in ["skills", "rules", "agents", "mcps", "hooks", "sessions"] {
                cells.insert(ExternalCompatCell(vendor: vendor, surface: surface))
            }
        }
        cells.insert(ExternalCompatCell(vendor: "codex", surface: "sessions"))
        return cells
    }()

    private static let expectedRootKeys = Set([
        "agents", "channel", "configSources", "cwd", "externalCompat",
        "grokVersion", "hooks", "loginPolicy", "lspServers", "marketplaces",
        "mcpServers", "permissions", "plugins", "projectInstructions",
        "projectRoot", "projectTrusted", "skills"
    ])

    private static let expectedPermissionKeys = Set([
        "sources", "loaded", "skipped", "mcpServerAllowlist",
        "marketplaceAllowlist", "managedSettingsPath", "managedSettingsExists",
        "managedSettingsActive"
    ])
}

private struct OwnedTemporaryDirectory: Equatable, Sendable {
    let rootURL: URL
    let directoryURL: URL
}

fileprivate struct OwnedImmutableFile: Equatable, Sendable {
    let fileURL: URL
    let contents: Data
    let device: UInt64
    let inode: UInt64

    static func create(
        in directoryURL: URL,
        name: String,
        contents: Data
    ) throws -> Self {
        guard directoryURL.isFileURL,
              directoryURL.path.hasPrefix("/"),
              !directoryURL.path.utf8.contains(0),
              !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.utf8.contains(0),
              !contents.isEmpty else {
            throw SupervisedLineProcessError.invalidConfiguration
        }

        let directoryDescriptor = Darwin.open(
            directoryURL.standardizedFileURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            throw SupervisedLineProcessError.invalidConfiguration
        }
        defer { Darwin.close(directoryDescriptor) }

        var directoryInformation = stat()
        guard Darwin.fstat(directoryDescriptor, &directoryInformation) == 0,
              directoryInformation.st_uid == Darwin.getuid(),
              directoryInformation.st_mode & S_IFMT == S_IFDIR,
              directoryInformation.st_mode & 0o777 == 0o700 else {
            throw SupervisedLineProcessError.invalidConfiguration
        }

        let descriptor = Darwin.openat(
            directoryDescriptor,
            name,
            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else {
            throw SupervisedLineProcessError.invalidConfiguration
        }
        var shouldRemove = true
        defer {
            Darwin.close(descriptor)
            if shouldRemove {
                _ = Darwin.unlinkat(directoryDescriptor, name, 0)
            }
        }

        try contents.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    throw SupervisedLineProcessError.invalidConfiguration
                }
                offset += written
            }
        }
        guard Darwin.fchmod(descriptor, 0o600) == 0,
              Darwin.fsync(descriptor) == 0 else {
            throw SupervisedLineProcessError.invalidConfiguration
        }

        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0 else {
            throw SupervisedLineProcessError.invalidConfiguration
        }
        let immutableFile = Self(
            fileURL: directoryURL.appending(path: name).standardizedFileURL,
            contents: contents,
            device: UInt64(information.st_dev),
            inode: UInt64(information.st_ino)
        )
        guard immutableFile.matches(descriptor: descriptor),
              Darwin.fsync(directoryDescriptor) == 0 else {
            throw SupervisedLineProcessError.invalidConfiguration
        }
        shouldRemove = false
        return immutableFile
    }

    func isValid() -> Bool {
        let descriptor = Darwin.open(
            fileURL.standardizedFileURL.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        return matches(descriptor: descriptor)
    }

    private func matches(descriptor: Int32) -> Bool {
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_uid == Darwin.getuid(),
              information.st_nlink == 1,
              information.st_mode & 0o777 == 0o600,
              information.st_size == contents.count,
              UInt64(information.st_dev) == device,
              UInt64(information.st_ino) == inode else {
            return false
        }

        var received = Data()
        var buffer = [UInt8](repeating: 0, count: min(4096, contents.count + 1))
        while received.count <= contents.count {
            let remaining = contents.count + 1 - received.count
            let requested = min(buffer.count, remaining)
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.pread(
                    descriptor,
                    bytes.baseAddress,
                    requested,
                    off_t(received.count)
                )
            }
            if count > 0 {
                received.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return received == contents
    }
}

private final class LockedFileDescriptor: @unchecked Sendable {
    private static let writeTimeoutNanoseconds: UInt64 = 5_000_000_000

    private let stateLock = NSLock()
    private let writeLock = NSLock()
    private var descriptor: Int32?

    init(_ descriptor: Int32) {
        self.descriptor = descriptor
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 {
            _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        }
    }

    func writeAll(_ data: Data) -> Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        let deadline = DispatchTime.now().uptimeNanoseconds
            + Self.writeTimeoutNanoseconds

        return data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return true }
            var written = 0
            while written < bytes.count {
                stateLock.lock()
                guard let descriptor else {
                    stateLock.unlock()
                    return false
                }
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    bytes.count - written
                )
                let writeError = errno
                stateLock.unlock()
                if count > 0 {
                    written += count
                } else if count < 0, writeError == EINTR {
                    continue
                } else if count < 0,
                          writeError == EAGAIN || writeError == EWOULDBLOCK {
                    guard DispatchTime.now().uptimeNanoseconds < deadline else {
                        return false
                    }
                    Thread.sleep(forTimeInterval: 0.01)
                } else {
                    return false
                }
            }
            return true
        }
    }

    func close() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let descriptor else { return }
        self.descriptor = nil
        Darwin.close(descriptor)
    }

    deinit {
        close()
    }
}

private struct ProcessIdentity: Equatable, Sendable {
    let identifier: pid_t
    let userIdentifier: uid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64

    static func capture(_ identifier: pid_t) -> ProcessIdentity? {
        guard identifier > 1, identifier != getpid() else { return nil }
        var information = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.size
        let actualSize = withUnsafeMutablePointer(to: &information) { pointer in
            proc_pidinfo(
                identifier,
                PROC_PIDTBSDINFO,
                0,
                pointer,
                Int32(expectedSize)
            )
        }
        guard actualSize == expectedSize,
              information.pbi_pid == UInt32(identifier) else {
            return nil
        }
        return ProcessIdentity(
            identifier: identifier,
            userIdentifier: information.pbi_uid,
            startSeconds: information.pbi_start_tvsec,
            startMicroseconds: information.pbi_start_tvusec
        )
    }
}

private final class ProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private let rootIdentity: ProcessIdentity
    private let rootSessionIdentifier: pid_t
    private let temporaryDirectoryMarker: [UInt8]?
    private var trackedIdentities: [pid_t: ProcessIdentity]
    private var processMonitor: Int32?
    private var exited = false
    private var recordedExitCode: Int32?
    private var intentionallyClosed = false
    private var fullyDrained = false
    private var drainingStopped = false

    init(
        rootIdentity: ProcessIdentity,
        rootSessionIdentifier: pid_t,
        temporaryDirectoryMarker: [UInt8]?,
        processMonitor: Int32
    ) {
        self.rootIdentity = rootIdentity
        self.rootSessionIdentifier = rootSessionIdentifier
        self.temporaryDirectoryMarker = temporaryDirectoryMarker
        trackedIdentities = [rootIdentity.identifier: rootIdentity]
        self.processMonitor = processMonitor
    }

    var hasExited: Bool {
        lock.withLock { exited }
    }

    var exitCode: Int32? {
        lock.withLock { recordedExitCode }
    }

    var wasClosedIntentionally: Bool {
        lock.withLock { intentionallyClosed }
    }

    var isFullyDrained: Bool {
        lock.withLock { fullyDrained }
    }

    var shouldStopDraining: Bool {
        lock.withLock { drainingStopped }
    }

    func beginIntentionalClose() {
        lock.withLock { intentionallyClosed = true }
    }

    func markExited(exitCode: Int32) {
        lock.withLock {
            recordedExitCode = exitCode
            exited = true
        }
    }

    func markFullyDrained() {
        lock.withLock { fullyDrained = true }
    }

    func stopDraining() {
        lock.withLock { drainingStopped = true }
    }

    @discardableResult
    func signalOwnedProcesses(_ signal: Int32, rescan: Bool = true) -> Bool {
        guard signal == SIGTERM || signal == SIGKILL else { return false }

        if rescan,
           let discovered = Self.scanOwnedProcesses(
            userIdentifier: rootIdentity.userIdentifier,
            sessionIdentifier: rootSessionIdentifier,
            temporaryDirectoryMarker: temporaryDirectoryMarker
        ) {
            lock.withLock {
                for identity in discovered {
                    if trackedIdentities[identity.identifier] == nil {
                        trackedIdentities[identity.identifier] = identity
                    }
                }
            }
        }

        let identities = lock.withLock {
            trackedIdentities.values.sorted { left, right in
                if left.identifier == rootIdentity.identifier { return true }
                if right.identifier == rootIdentity.identifier { return false }
                return left.identifier < right.identifier
            }
        }
        var livingProcessFound = false
        var staleIdentities: [ProcessIdentity] = []
        for identity in identities {
            guard identity.identifier > 1,
                  identity.identifier != getpid(),
                  ProcessIdentity.capture(identity.identifier) == identity else {
                staleIdentities.append(identity)
                continue
            }
            livingProcessFound = true
            if Darwin.kill(identity.identifier, signal) != 0, errno == ESRCH {
                staleIdentities.append(identity)
            }
        }

        if !staleIdentities.isEmpty {
            lock.withLock {
                for identity in staleIdentities
                    where trackedIdentities[identity.identifier] == identity {
                    trackedIdentities.removeValue(forKey: identity.identifier)
                }
            }
        }
        return livingProcessFound
    }

    func stopMonitoring() {
        let descriptor = lock.withLock { () -> Int32? in
            defer { processMonitor = nil }
            return processMonitor
        }
        if let descriptor {
            Darwin.close(descriptor)
        }
    }

    func takeProcessMonitor() -> Int32? {
        lock.withLock {
            defer { processMonitor = nil }
            return processMonitor
        }
    }

    deinit {
        if let descriptor = processMonitor {
            Darwin.close(descriptor)
        }
    }

    private static func scanOwnedProcesses(
        userIdentifier: uid_t,
        sessionIdentifier: pid_t,
        temporaryDirectoryMarker: [UInt8]?
    ) -> [ProcessIdentity]? {
        guard let identifiers = allProcessIdentifiers() else { return nil }
        var matches: [ProcessIdentity] = []
        matches.reserveCapacity(identifiers.count)

        for identifier in identifiers {
            guard identifier > 1,
                  identifier != getpid(),
                  let identity = ProcessIdentity.capture(identifier),
                  identity.userIdentifier == userIdentifier else {
                continue
            }
            let isSessionMember = getsid(identifier) == sessionIdentifier
            let hasTemporaryDirectoryMarker: Bool
            if !isSessionMember, let temporaryDirectoryMarker {
                hasTemporaryDirectoryMarker = processArguments(
                    for: identifier,
                    containExactSegment: temporaryDirectoryMarker
                )
            } else {
                hasTemporaryDirectoryMarker = false
            }
            if isSessionMember || hasTemporaryDirectoryMarker {
                matches.append(identity)
            }
        }
        return matches
    }

    private static func allProcessIdentifiers() -> [pid_t]? {
        let estimatedCount = proc_listallpids(nil, 0)
        guard estimatedCount > 0 else { return nil }

        var capacity = Int(estimatedCount) + 64
        for _ in 0..<3 {
            var identifiers = [pid_t](repeating: 0, count: capacity)
            let count = identifiers.withUnsafeMutableBytes { bytes in
                proc_listallpids(bytes.baseAddress, Int32(bytes.count))
            }
            guard count >= 0 else { return nil }
            if count < capacity {
                identifiers.removeSubrange(Int(count)..<identifiers.count)
                return identifiers
            }
            capacity *= 2
        }
        return nil
    }

    private static func processArguments(
        for identifier: pid_t,
        containExactSegment marker: [UInt8]
    ) -> Bool {
        guard !marker.isEmpty else { return false }
        var query = [CTL_KERN, KERN_PROCARGS2, identifier]
        var requiredSize = 0
        let sizeResult = query.withUnsafeMutableBufferPointer { queryBuffer in
            sysctl(
                queryBuffer.baseAddress,
                UInt32(queryBuffer.count),
                nil,
                &requiredSize,
                nil,
                0
            )
        }
        guard sizeResult == 0,
              requiredSize > MemoryLayout<Int32>.size,
              requiredSize <= 1_048_576 else {
            return false
        }

        var buffer = [UInt8](repeating: 0, count: requiredSize)
        return buffer.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return false }
            defer { explicitBzero(baseAddress, byteCount: bytes.count) }

            var outputSize = bytes.count
            let result = query.withUnsafeMutableBufferPointer { queryBuffer in
                sysctl(
                    queryBuffer.baseAddress,
                    UInt32(queryBuffer.count),
                    baseAddress,
                    &outputSize,
                    nil,
                    0
                )
            }
            guard result == 0,
                  outputSize > MemoryLayout<Int32>.size,
                  outputSize <= bytes.count else {
                return false
            }

            let start = MemoryLayout<Int32>.size
            var segmentStart = start
            for index in start..<outputSize where bytes[index] == 0 {
                let segmentLength = index - segmentStart
                if segmentLength == marker.count {
                    let matches = marker.withUnsafeBytes { markerBytes in
                        guard let markerAddress = markerBytes.baseAddress else {
                            return false
                        }
                        return memcmp(
                            baseAddress.advanced(by: segmentStart),
                            markerAddress,
                            marker.count
                        ) == 0
                    }
                    if matches { return true }
                }
                segmentStart = index + 1
            }
            return false
        }
    }

    private static func explicitBzero(
        _ pointer: UnsafeMutableRawPointer,
        byteCount: Int
    ) {
        _ = memset_s(pointer, byteCount, 0, byteCount)
    }
}

private actor BoundedLineChannel {
    private struct Waiter {
        let identifier: UUID
        let continuation: CheckedContinuation<Data?, any Error>
    }

    private let maximumLineBytes: Int
    private let maximumBufferedBytes: Int
    private var partialLine = Data()
    private var queuedLines: [Data] = []
    private var queuedLineIndex = 0
    private var bufferedBytes = 0
    private var waiters: [Waiter] = []
    private var terminalError: SupervisedLineProcessError?
    private var isFinished = false

    init(maximumLineBytes: Int, maximumBufferedBytes: Int) {
        self.maximumLineBytes = maximumLineBytes
        self.maximumBufferedBytes = maximumBufferedBytes
    }

    func append(_ data: Data) -> SupervisedLineProcessError? {
        guard !isFinished else { return nil }
        var segmentStart = data.startIndex

        for index in data.indices where data[index] == 0x0A {
            let segment = data[segmentStart..<index]
            guard partialLine.count <= maximumLineBytes - segment.count else {
                return .lineTooLarge
            }
            partialLine.append(segment)
            if partialLine.last == 0x0D {
                partialLine.removeLast()
            }
            if let error = enqueue(partialLine) { return error }
            partialLine.removeAll(keepingCapacity: true)
            segmentStart = data.index(after: index)
        }

        let remainder = data[segmentStart..<data.endIndex]
        guard partialLine.count <= maximumLineBytes - remainder.count else {
            return .lineTooLarge
        }
        partialLine.append(remainder)
        return nil
    }

    func finishPartialLine() -> SupervisedLineProcessError? {
        guard !isFinished, !partialLine.isEmpty else { return nil }
        guard partialLine.count <= maximumLineBytes else { return .lineTooLarge }
        let error = enqueue(partialLine)
        partialLine.removeAll()
        return error
    }

    func finish(with error: SupervisedLineProcessError?) {
        guard !isFinished else { return }
        isFinished = true
        terminalError = error
        flushWaiters()
    }

    func next() async throws -> Data? {
        try Task.checkCancellation()
        if let line = dequeue() { return line }
        if isFinished {
            if let terminalError { throw terminalError }
            return nil
        }

        let identifier = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(identifier: identifier, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(identifier) }
        }
    }

    private func enqueue(_ line: Data) -> SupervisedLineProcessError? {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.continuation.resume(returning: line)
            return nil
        }
        guard bufferedBytes <= maximumBufferedBytes - line.count else {
            return .outputBufferExceeded
        }
        queuedLines.append(line)
        bufferedBytes += line.count
        return nil
    }

    private func dequeue() -> Data? {
        guard queuedLineIndex < queuedLines.count else { return nil }
        let line = queuedLines[queuedLineIndex]
        queuedLineIndex += 1
        bufferedBytes -= line.count
        if queuedLineIndex >= 64, queuedLineIndex * 2 >= queuedLines.count {
            queuedLines.removeFirst(queuedLineIndex)
            queuedLineIndex = 0
        }
        return line
    }

    private func flushWaiters() {
        while !waiters.isEmpty, let line = dequeue() {
            let waiter = waiters.removeFirst()
            waiter.continuation.resume(returning: line)
        }
        guard queuedLineIndex == queuedLines.count else { return }
        let remaining = waiters
        waiters.removeAll()
        if let terminalError {
            remaining.forEach { $0.continuation.resume(throwing: terminalError) }
        } else {
            remaining.forEach { $0.continuation.resume(returning: nil) }
        }
    }

    private func cancelWaiter(_ identifier: UUID) {
        guard let index = waiters.firstIndex(where: { $0.identifier == identifier }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}
