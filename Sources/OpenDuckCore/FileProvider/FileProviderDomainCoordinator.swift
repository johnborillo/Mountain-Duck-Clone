import Foundation
import FileProvider

public enum FileProviderDomainError: Error, LocalizedError, Sendable {
    case providerDidNotCreateReplicatedDomain(String)
    case domainDisabled(String)
    case userVisibleURLUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .providerDidNotCreateReplicatedDomain(let name):
            return "Finder created '\(name)' with the legacy File Provider API. Reinstall OpenDuck 1.1 or later and add the connection again."
        case .domainDisabled(let name):
            return "Finder created '\(name)', but synchronization is disabled. Enable OpenDuck in System Settings > General > Login Items & Extensions > File Providers, then add it again."
        case .userVisibleURLUnavailable(let name):
            return "Finder registered '\(name)' but did not create a user-visible Cloud Storage location."
        }
    }
}

public struct FileProviderRegistrationResult: Sendable {
    public let repairedLegacyDomain: Bool
    public let userVisibleURL: URL
}

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

    @discardableResult
    public static func register(profile: ServerProfile) async throws -> FileProviderRegistrationResult {
        _ = try OpenDuckSharedStorage.requireSharedContainer()

        let identifier = profile.id.uuidString
        let existing = try await registeredDomains().first {
            $0.identifier.rawValue == identifier
        }
        let repairedLegacy = existing.map { !$0.isReplicated } ?? false

        if let existing, !existing.isReplicated {
            // Builds before 1.1 advertised the extension as non-enumerating.
            // Removing the unusable domain is remote-data safe and ensures
            // fileproviderd does not preserve the old NSFileProviderExtension API.
            try await NSFileProviderManager.remove(existing)
        }

        let replicatedDomain = domain(for: profile)
        if existing == nil || repairedLegacy {
            try await NSFileProviderManager.add(replicatedDomain)
        }

        guard let installed = try await registeredDomains().first(where: {
            $0.identifier.rawValue == identifier
        }), installed.isReplicated else {
            throw FileProviderDomainError.providerDidNotCreateReplicatedDomain(profile.name)
        }
        guard installed.userEnabled else {
            throw FileProviderDomainError.domainDisabled(profile.name)
        }

        if let manager = NSFileProviderManager(for: installed) {
            try await reconnect(manager)
        }

        guard let visibleURL = try await userVisibleURL(profile: profile) else {
            throw FileProviderDomainError.userVisibleURLUnavailable(profile.name)
        }

        return FileProviderRegistrationResult(
            repairedLegacyDomain: repairedLegacy,
            userVisibleURL: visibleURL
        )
    }

    /// One-time repair used when upgrading from a bundle that registered valid
    /// identifiers but omitted the enumeration metadata. It deliberately keeps
    /// the profile UUID and OpenDuck operation journal while asking Finder to
    /// rebuild only its unusable local domain state.
    @discardableResult
    public static func recreateRegisteredDomains(for profiles: [ServerProfile]) async throws -> Int {
        _ = try OpenDuckSharedStorage.requireSharedContainer()
        let registered = try await registeredDomains()
        let existingByID = Dictionary(uniqueKeysWithValues: registered.map {
            ($0.identifier.rawValue, $0)
        })
        let profileIDs = Set(profiles.map { $0.id.uuidString })

        // Remove UUID-backed domains whose profile no longer exists. Old builds
        // could leave these behind after a failed delete; they repeatedly launch
        // the extension with obsolete non-replicated configuration.
        for existing in registered {
            let identifier = existing.identifier.rawValue
            if UUID(uuidString: identifier) != nil && !profileIDs.contains(identifier) {
                try await NSFileProviderManager.remove(existing)
            }
        }

        var repaired = 0
        for profile in profiles {
            guard let existing = existingByID[profile.id.uuidString] else { continue }
            try await NSFileProviderManager.remove(existing)
            let replacement = domain(for: profile)
            try await NSFileProviderManager.add(replacement)

            guard let installed = try await registeredDomains().first(where: {
                $0.identifier.rawValue == profile.id.uuidString
            }), installed.isReplicated else {
                throw FileProviderDomainError.providerDidNotCreateReplicatedDomain(profile.name)
            }
            guard installed.userEnabled else {
                throw FileProviderDomainError.domainDisabled(profile.name)
            }
            if let manager = NSFileProviderManager(for: installed) {
                try await reconnect(manager)
            }
            repaired += 1
        }
        return repaired
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
    /// `~/Library/CloudStorage` or `/Volumes` path.
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

    /// Keeps the Cocoa/File Provider code and underlying cause visible. Finder's
    /// localized description is often only "application cannot be used right now,"
    /// which is insufficient to diagnose signing or extension-launch failures.
    public static func diagnosticDescription(for error: Error) -> String {
        var descriptions: [String] = []
        var current: NSError? = error as NSError
        var visited = Set<ObjectIdentifier>()

        while let nsError = current, visited.insert(ObjectIdentifier(nsError)).inserted {
            let message = nsError.localizedDescription
            descriptions.append("\(message) [\(nsError.domain) \(nsError.code)]")
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }

        return descriptions.joined(separator: " Caused by: ")
    }

    private static func reconnect(_ manager: NSFileProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.reconnect { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}
