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
        ".trash", "tmp", "temp"
    ]

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
