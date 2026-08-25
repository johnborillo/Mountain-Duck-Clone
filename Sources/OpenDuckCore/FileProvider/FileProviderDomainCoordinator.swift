import Foundation
import FileProvider

/// Owns the host-side lifecycle of native File Provider domains.
///
/// A domain identifier is the profile UUID, rather than the display name. Renaming a
/// connection therefore updates Finder's label without orphaning its metadata/cache.
public enum FileProviderDomainCoordinator {
    public static func domain(for profile: ServerProfile) -> NSFileProviderDomain {
        NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(profile.id.uuidString),
            displayName: profile.name
        )
    }

    public static func register(profile: ServerProfile) async throws {
        try await NSFileProviderManager.add(domain(for: profile))
    }

    public static func unregister(profile: ServerProfile) async throws {
        try await NSFileProviderManager.remove(domain(for: profile))
    }

    public static func registeredDomains() async throws -> [NSFileProviderDomain] {
        try await withCheckedThrowingContinuation { continuation in
            NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: domains) }
            }
        }
    }

    /// Ask the replicated provider to refresh its working set. SFTP has no push
    /// notification channel, so the host uses this as a low-frequency adaptive
    /// refresh while Finder is running.
    public static func signalWorkingSet(profile: ServerProfile) async throws {
        guard let manager = NSFileProviderManager(for: domain(for: profile)) else {
            throw AdapterError.notConnected
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.signalEnumerator(for: NSFileProviderItemIdentifier.workingSet, completionHandler: { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    /// Resolve the Finder-visible root for a registered domain. The File Provider
    /// framework owns this location, so callers must ask it instead of guessing a
    /// `~/Library/CloudStorage` path.
    public static func userVisibleURL(profile: ServerProfile) async throws -> URL? {
        guard let manager = NSFileProviderManager(for: domain(for: profile)) else {
            throw AdapterError.notConnected
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL?, Error>) in
            manager.getUserVisibleURL(for: .rootContainer) { url, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: url) }
            }
        }
    }
}
