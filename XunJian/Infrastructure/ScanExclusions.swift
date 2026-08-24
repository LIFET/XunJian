import Darwin
import Foundation

/// The user's account home, not the App Sandbox container returned by
/// `FileManager.homeDirectoryForCurrentUser` inside a sandboxed process.
enum SystemUserHomeDirectory {
    static var current: URL {
        resolved(
            accountHomePath: accountHomePath(),
            fallback: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    static func resolved(accountHomePath: String?, fallback: URL) -> URL {
        guard let accountHomePath,
              accountHomePath.hasPrefix("/"),
              accountHomePath != "/" else {
            return fallback.resolvingSymlinksInPath().standardizedFileURL
        }
        return URL(fileURLWithPath: accountHomePath, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    private static func accountHomePath() -> String? {
        var record = passwd()
        var result: UnsafeMutablePointer<passwd>?
        let recommendedCapacity = sysconf(_SC_GETPW_R_SIZE_MAX)
        let capacity = recommendedCapacity > 0
            ? min(Int(recommendedCapacity), 1_048_576)
            : 16_384
        var buffer = [CChar](repeating: 0, count: capacity)
        let lookupResult = buffer.withUnsafeMutableBufferPointer { pointer in
            getpwuid_r(
                getuid(),
                &record,
                pointer.baseAddress,
                pointer.count,
                &result
            )
        }
        guard lookupResult == 0,
              result != nil,
              let directory = record.pw_dir else { return nil }
        return String(cString: directory)
    }
}

/// User-configurable file or folder names skipped during scanning.
///
/// The built-in list covers build output and caches that would otherwise
/// dominate an index. Users can add project-specific names (`vendor`,
/// `Pods`, `index.sqlite3`, …) without the app shipping an ever-growing
/// hard-coded list.
enum ScanExclusions {
    static let storageKey = "scan.additionalExcludedNames"

    /// Always skipped. Not user-removable: these are never content the file
    /// browser should surface, and excluding them keeps scans fast.
    static let builtIn: Set<String> = [
        ".git", "node_modules", "deriveddata", "caches", ".cache",
        ".trash"
    ]

    /// Credential and communication stores are never useful file-browser
    /// results. This policy is deliberately independent from the "show hidden
    /// files" preference and is shared by full scans, incremental scans and
    /// explicit AI/text reads.
    private static let sensitiveComponentSequences: [[String]] = [
        [".ssh"], [".gnupg"], [".aws"], [".azure"], [".kube"],
        [".docker"],
        [".config", "gcloud"],
        [".config", "gh"],
        [".config", "glab"],
        [".config", "glab-cli"],
        [".config", "op"],
        [".config", "1password"],
        [".config", "rclone"],
        [".password-store"],
        [".local", "share", "keyrings"],
        ["library", "keychains"],
        ["library", "cookies"],
        ["library", "mail"],
        ["library", "messages"],
        ["library", "safari"],
        ["library", "accounts"],
        ["library", "application support", "google", "chrome"],
        ["library", "application support", "chromium"],
        ["library", "application support", "bravesoftware"],
        ["library", "application support", "microsoft edge"],
        ["library", "application support", "firefox"]
    ]

    private static let sensitiveFileNames: Set<String> = [
        ".env", ".git-credentials", ".netrc", ".npmrc", ".pypirc",
        ".zsh_history", ".bash_history", ".python_history",
        "auth.json", "credentials", "id_rsa", "id_ed25519"
    ]

    static func isSensitivePath(_ url: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents.map {
            $0.precomposedStringWithCanonicalMapping.lowercased()
        }
        if let fileName = components.last {
            if sensitiveFileNames.contains(fileName)
                || fileName.hasPrefix(".env.") {
                return true
            }
        }
        return sensitiveComponentSequences.contains { sequence in
            guard sequence.count <= components.count else { return false }
            for start in 0...(components.count - sequence.count) {
                if Array(components[start..<(start + sequence.count)]) == sequence {
                    return true
                }
            }
            return false
        }
    }

    /// Whole-Mac indexing means the current user's visible data, not the
    /// operating system, other users, mounted volumes or private Library
    /// stores. Visible custom folders in the home directory remain eligible;
    /// iCloud Drive is added explicitly because it lives below Library.
    static func wholeMacScopes(
        rootURL: URL,
        homeDirectory: URL = SystemUserHomeDirectory.current,
        includesHiddenFiles: Bool = false,
        excludedItemNames: Set<String> = [],
        fileManager: FileManager = .default
    ) throws -> [URL] {
        let canonicalRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let canonicalHome = homeDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard isSameOrDescendant(canonicalHome, of: canonicalRoot) else { return [] }

        let directoryOptions: FileManager.DirectoryEnumerationOptions = includesHiddenFiles
            ? []
            : [.skipsHiddenFiles]
        var candidates = try fileManager.contentsOfDirectory(
            at: canonicalHome,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: directoryOptions
        ).filter { $0.lastPathComponent.caseInsensitiveCompare("Library") != .orderedSame }

        candidates.append(
            canonicalHome
                .appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
        )
        candidates.append(
            canonicalRoot.appending(path: "Users/Shared", directoryHint: .isDirectory)
        )

        var seen = Set<String>()
        return candidates.compactMap { candidate in
            let canonical = candidate.resolvingSymlinksInPath().standardizedFileURL
            let itemName = canonical.lastPathComponent.lowercased()
            guard !builtIn.contains(itemName),
                  !excludedItemNames.contains(itemName),
                  !isSensitivePath(canonical),
                  seen.insert(canonical.path).inserted,
                  let values = try? canonical.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                  ),
                  values.isDirectory == true,
                  values.isSymbolicLink != true else {
                return nil
            }
            return canonical
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Visible regular files stored directly in the current user's home.
    /// They cannot be represented by the recursive directory scopes above:
    /// scanning the home itself would also enter Library and duplicate every
    /// top-level directory scan.
    static func wholeMacTopLevelFiles(
        rootURL: URL,
        homeDirectory: URL = SystemUserHomeDirectory.current,
        includesHiddenFiles: Bool = false,
        excludedItemNames: Set<String> = [],
        fileManager: FileManager = .default
    ) throws -> [URL] {
        let canonicalRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let canonicalHome = homeDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard isSameOrDescendant(canonicalHome, of: canonicalRoot) else { return [] }

        let options: FileManager.DirectoryEnumerationOptions = includesHiddenFiles
            ? []
            : [.skipsHiddenFiles]
        return try fileManager.contentsOfDirectory(
            at: canonicalHome,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: options
        ).compactMap { candidate in
            let canonical = candidate.resolvingSymlinksInPath().standardizedFileURL
            let itemName = canonical.lastPathComponent.lowercased()
            guard !builtIn.contains(itemName),
                  !excludedItemNames.contains(itemName),
                  !isSensitivePath(canonical),
                  let values = try? canonical.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                  ),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                return nil
            }
            return canonical
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func isSameOrDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return candidate.path == root.path || candidate.path.hasPrefix(rootPath)
    }

    static func current(defaults: UserDefaults = .standard) -> [String] {
        normalized(defaults.stringArray(forKey: storageKey) ?? [])
    }

    static func save(_ names: [String], defaults: UserDefaults = .standard) {
        defaults.set(normalized(names), forKey: storageKey)
    }

    /// Matching is case-insensitive, so entries are stored lowercased and
    /// de-duplicated. Names already built in are dropped rather than stored
    /// twice.
    static func normalized(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for entry in raw {
            let trimmed = entry
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !trimmed.isEmpty,
                  !builtIn.contains(trimmed),
                  seen.insert(trimmed).inserted else {
                continue
            }
            result.append(trimmed)
        }
        return result.sorted()
    }
}
