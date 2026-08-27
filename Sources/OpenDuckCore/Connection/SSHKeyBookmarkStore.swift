import Foundation

public enum SSHKeyBookmarkError: Error, LocalizedError, Sendable {
    case missingBookmark
    case staleBookmark
    case accessDenied
    case unreadableKey(String)

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
        }
    }
}

/// Stores security-scoped bookmarks that can be resolved by both the host app
/// and File Provider extension. The private key itself is never copied into the
/// App Group or persisted in the profile database.
public final class SSHKeyBookmarkStore: @unchecked Sendable {
    public static let shared = SSHKeyBookmarkStore()

    private let userDefaults: UserDefaults
    private let keyPrefix = "com.openduck.sshKeyBookmark."
    private let lock = NSLock()

    public init(userDefaults: UserDefaults? = nil) {
        self.userDefaults = userDefaults ?? OpenDuckSharedStorage.userDefaults
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

    public func deleteBookmark(for profileID: UUID) {
        lock.withLock {
            userDefaults.removeObject(forKey: storageKey(for: profileID))
        }
    }

    /// Resolves and reads a selected key while holding the sandbox extension.
    /// The returned data is passed directly to Citadel and the resource access
    /// is relinquished immediately after the read completes.
    public func loadPrivateKeyData(for profileID: UUID) throws -> Data {
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

    private func storageKey(for profileID: UUID) -> String {
        keyPrefix + profileID.uuidString
    }
}
