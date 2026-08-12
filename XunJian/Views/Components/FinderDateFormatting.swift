import Foundation

/// Shared "Finder-style" relative date formatting (F18).
///
/// Three views each cached their own identical `DateFormatter`; now there is
/// one per locale. Changing how dates render (e.g. adding seconds) happens
/// here, not in three places.
///
/// `DateFormatter` is thread-safe (per Apple, since macOS 10.9); the cache
/// dictionary is guarded so callers can use this from any isolation domain,
/// e.g. export code running off the main actor.
enum FinderDateFormatting {
    private static let lock = NSLock()
    /// Guarded by `lock`; `DateFormatter` itself is thread-safe.
    nonisolated(unsafe) private static var formatters: [String: DateFormatter] = [:]

    static func formatter(for locale: Locale) -> DateFormatter {
        lock.lock()
        defer { lock.unlock() }
        if let formatter = formatters[locale.identifier] {
            return formatter
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = .autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        formatters[locale.identifier] = formatter
        return formatter
    }

    /// One-call convenience for views that only need the string (e.g.
    /// `date.map(FinderDateFormatting.string(for:))`).
    static func string(for date: Date) -> String {
        formatter(for: .autoupdatingCurrent).string(from: date)
    }
}
