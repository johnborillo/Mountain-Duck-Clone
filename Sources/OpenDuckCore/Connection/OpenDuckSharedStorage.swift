import Foundation

/// Resolves storage shared by the host app and its File Provider extension.
///
/// Production builds use the App Group container. Command-line diagnostics and
/// unsigned development builds fall back to Application Support so they remain
/// usable without silently switching back to ephemeral state.
public enum OpenDuckSharedStorage {
    public static let appGroupIdentifier = "group.com.openduck"

    public static var userDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    public static var baseDirectory: URL {
        if let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) {
            return groupURL.appendingPathComponent("OpenDuck", isDirectory: true)
        }

        let supportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return supportURL.appendingPathComponent("OpenDuck", isDirectory: true)
    }

    public static var cacheDirectory: URL {
        baseDirectory.appendingPathComponent("Cache", isDirectory: true)
    }

    public static var uploadJournalURL: URL {
        baseDirectory.appendingPathComponent("Operations/upload-journal.json")
    }

    public static func cacheDirectory(forDomain identifier: String) -> URL {
        cacheDirectory.appendingPathComponent(identifier, isDirectory: true)
    }

    public static func uploadJournalURL(forDomain identifier: String) -> URL {
        baseDirectory.appendingPathComponent("Operations/\(identifier).json")
    }
}
