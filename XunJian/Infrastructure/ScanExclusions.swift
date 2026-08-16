import Foundation

/// User-configurable folder names skipped during scanning.
///
/// The built-in list covers build output and caches that would otherwise
/// dominate an index. Users can add project-specific names (`vendor`,
/// `Pods`, …) without the app shipping an ever-growing hard-coded list.
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
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws -> [URL] {
        let canonicalRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let canonicalHome = homeDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard isSameOrDescendant(canonicalHome, of: canonicalRoot) else { return [] }

        var candidates = try fileManager.contentsOfDirectory(
            at: canonicalHome,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
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
            guard !isSensitivePath(canonical),
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
