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
}
