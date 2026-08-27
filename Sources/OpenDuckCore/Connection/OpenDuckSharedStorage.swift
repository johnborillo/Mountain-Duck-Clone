import Foundation

public enum OpenDuckSharedStorageError: Error, LocalizedError, Sendable {
    case appGroupUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .appGroupUnavailable(let identifier):
            return "OpenDuck cannot access its shared App Group container '\(identifier)'. Reinstall a correctly signed copy of the app before adding it to Finder."
        }
    }
}

/// Resolves storage shared by the host app and its File Provider extension.
///
/// The bundled host and extension must share the App Group. Command-line tools
/// and tests may fall back to Application Support, but a production File Provider
/// registration fails closed instead of silently creating split state.
public enum OpenDuckSharedStorage {
    public static let appGroupIdentifier = "group.com.openduck"
    public static let hostBundleIdentifier = "com.openduck.app"
    public static let extensionBundleIdentifier = "com.openduck.app.fileprovider"
    public static let keychainAccessGroup = appGroupIdentifier

    public static var isBundledOpenDuckProcess: Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        return identifier == hostBundleIdentifier || identifier == extensionBundleIdentifier
    }

    public static var userDefaults: UserDefaults {
        if let shared = UserDefaults(suiteName: appGroupIdentifier) {
            return shared
        }
        if isBundledOpenDuckProcess {
            preconditionFailure(OpenDuckSharedStorageError.appGroupUnavailable(appGroupIdentifier).localizedDescription)
        }
        return .standard
    }

    public static var baseDirectory: URL {
        if let shared = try? requireSharedContainer() { return shared }

        if isBundledOpenDuckProcess {
            preconditionFailure(OpenDuckSharedStorageError.appGroupUnavailable(appGroupIdentifier).localizedDescription)
        }

        let supportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return supportURL.appendingPathComponent("OpenDuck", isDirectory: true)
    }

    /// Returns the only storage location that is safe for host/extension state.
    /// Registration calls this before touching File Provider so a signing or
    /// entitlement problem is reported in the app instead of creating a domain
    /// whose extension reads a different profile database.
    public static func requireSharedContainer(
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let groupURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw OpenDuckSharedStorageError.appGroupUnavailable(appGroupIdentifier)
        }
        return groupURL.appendingPathComponent("OpenDuck", isDirectory: true)
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
