import Foundation

public enum SSHKeyBookmarkError: Error, LocalizedError, Sendable {
    case missingBookmark
    case staleBookmark
    case accessDenied
    case unreadableKey(String)
    case importedKeyUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .missingBookmark:
            return "OpenDuck does not have persistent permission to read this SSH key. Edit the connection and choose the key again with Browse."
        case .staleBookmark:
            return "The saved SSH-key permission is stale. Edit the connection and choose the key again with Browse."
        case .accessDenied:
            return "macOS denied access to the saved SSH key. Edit the connection and choose the key again with Browse."
        case .unreadableKey(let reason):
            return "Could not read the selected SSH private key: \(reason)"
        case .importedKeyUnavailable(let reason):
            return "Could not access OpenDuck's protected SSH-key copy: \(reason)"
        }
    }
}

/// Stores the host app's security-scoped bookmark and a protected key copy for
/// the File Provider extension.
///
/// A security-scoped bookmark restores access only to the same sandboxed
/// process that created it. The containing app and File Provider extension are
/// separate processes, so the selected key is imported into their private App
/// Group with owner-only permissions. It is excluded from backups and removed
/// with the profile.
public final class SSHKeyBookmarkStore: @unchecked Sendable {
    public static let shared = SSHKeyBookmarkStore()

    private let userDefaults: UserDefaults
    private let keyPrefix = "com.openduck.sshKeyBookmark."
    private let keyMaterialDirectory: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(
        userDefaults: UserDefaults? = nil,
        keyMaterialDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.userDefaults = userDefaults ?? OpenDuckSharedStorage.userDefaults
        self.keyMaterialDirectory = keyMaterialDirectory
            ?? OpenDuckSharedStorage.baseDirectory.appendingPathComponent("SSHKeys", isDirectory: true)
        self.fileManager = fileManager
    }

    public func makeBookmark(for url: URL) throws -> Data {
        do {
            return try url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw SSHKeyBookmarkError.unreadableKey(error.localizedDescription)
        }
    }

    public func saveBookmark(_ bookmark: Data, for profileID: UUID) {
        lock.withLock {
            userDefaults.set(bookmark, forKey: storageKey(for: profileID))
        }
    }

    public func bookmark(for profileID: UUID) -> Data? {
        lock.withLock {
            userDefaults.data(forKey: storageKey(for: profileID))
        }
    }

    public func hasBookmark(for profileID: UUID) -> Bool {
        bookmark(for: profileID) != nil
    }

    public func hasImportedPrivateKey(for profileID: UUID) -> Bool {
        fileManager.fileExists(atPath: importedKeyURL(for: profileID).path)
    }

    /// Persist key material selected through NSOpenPanel where both signed
    /// OpenDuck processes can read it without broad filesystem entitlements.
    public func importPrivateKeyData(_ data: Data, for profileID: UUID) throws {
        guard !data.isEmpty else {
            throw SSHKeyBookmarkError.unreadableKey("The selected file is empty.")
        }

        do {
            try fileManager.createDirectory(
                at: keyMaterialDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: keyMaterialDirectory.path
            )

            let keyURL = importedKeyURL(for: profileID)
            try data.write(to: keyURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: keyURL.path
            )

            var directoryValues = URLResourceValues()
            directoryValues.isExcludedFromBackup = true
            var mutableDirectoryURL = keyMaterialDirectory
            try mutableDirectoryURL.setResourceValues(directoryValues)

            var keyValues = URLResourceValues()
            keyValues.isExcludedFromBackup = true
            var mutableKeyURL = keyURL
            try mutableKeyURL.setResourceValues(keyValues)
        } catch {
            throw SSHKeyBookmarkError.importedKeyUnavailable(error.localizedDescription)
        }
    }

    /// Host-side upgrade path for bookmarks created by an already signed build.
    /// The extension cannot perform this migration because it is a different
    /// sandboxed process.
    @discardableResult
    public func migrateBookmarkToImportedKey(for profileID: UUID) throws -> Bool {
        guard !hasImportedPrivateKey(for: profileID) else { return false }
        guard bookmark(for: profileID) != nil else { return false }
        let data = try loadBookmarkedPrivateKeyData(for: profileID)
        try importPrivateKeyData(data, for: profileID)
        return true
    }

    public func deleteBookmark(for profileID: UUID) {
        lock.withLock {
            userDefaults.removeObject(forKey: storageKey(for: profileID))
        }
        try? fileManager.removeItem(at: importedKeyURL(for: profileID))
    }

    /// Reads the protected App Group copy, or lets the containing app resolve a
    /// legacy bookmark so it can perform the one-time import.
    public func loadPrivateKeyData(for profileID: UUID) throws -> Data {
        let importedURL = importedKeyURL(for: profileID)
        if fileManager.fileExists(atPath: importedURL.path) {
            do {
                return try Data(contentsOf: importedURL)
            } catch {
                throw SSHKeyBookmarkError.importedKeyUnavailable(error.localizedDescription)
            }
        }

        // This fallback is usable by the containing app and permits migration
        // from older builds. A File Provider extension must use the imported
        // App Group copy because app-scoped bookmarks are process-specific.
        return try loadBookmarkedPrivateKeyData(for: profileID)
    }

    private func loadBookmarkedPrivateKeyData(for profileID: UUID) throws -> Data {
        guard let bookmark = bookmark(for: profileID) else {
            throw SSHKeyBookmarkError.missingBookmark
        }

        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw SSHKeyBookmarkError.unreadableKey(error.localizedDescription)
        }

        guard !isStale else { throw SSHKeyBookmarkError.staleBookmark }
        guard url.startAccessingSecurityScopedResource() else {
            throw SSHKeyBookmarkError.accessDenied
        }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw SSHKeyBookmarkError.unreadableKey(error.localizedDescription)
        }
    }

    private func importedKeyURL(for profileID: UUID) -> URL {
        keyMaterialDirectory.appendingPathComponent("\(profileID.uuidString).key", isDirectory: false)
    }

    private func storageKey(for profileID: UUID) -> String {
        keyPrefix + profileID.uuidString
    }
}
