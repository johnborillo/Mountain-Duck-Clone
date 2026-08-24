import Foundation
import SwiftUI
import OpenDuckCore
import FileProvider
import AppKit

/// Screen navigation state inside the Menu Bar popover.
public enum AppScreen: Hashable, Sendable {
    case main
    case addConnection
    case preferences
}

/// Central UI view model managing desktop application state, mounted domains, and cache stats.
@MainActor
public final class AppViewModel: ObservableObject {
    @Published public var currentScreen: AppScreen = .main
    @Published public var profiles: [ServerProfile] = []
    @Published public var mountedDomainIDs: Set<UUID> = []
    @Published public var cacheStats: CacheStatistics = .empty
    @Published public var statusMessage: String? = nil
    @Published public var isMounting: Bool = false

    public let connectionManager: ConnectionManager
    public let cacheEngine: CacheEngine
    public let volumeManager: VolumeMountManager
    private var timer: Timer?

    public init(
        connectionManager: ConnectionManager = .shared,
        cacheEngine: CacheEngine? = nil,
        volumeManager: VolumeMountManager = .shared
    ) {
        self.connectionManager = connectionManager
        self.volumeManager = volumeManager
        // Decoupling Safety Guarantee: The local cache directory MUST be placed in user Caches,
        // separate from any /Volumes/ path, so cache evictions do not generate FSEvents in mounted volumes.
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.openduck.app/cache")
        assert(!cacheDir.path.hasPrefix("/Volumes/"), "cacheDir must not reside inside /Volumes")
        self.cacheEngine = cacheEngine ?? CacheEngine(cacheDirectory: cacheDir)

        loadInitialData()
        startPeriodicRefresh()
    }

    public func loadInitialData() {
        loadProfiles()
        refreshCacheStats()
        refreshMountedVolumes()
    }

    public func loadProfiles() {
        self.profiles = connectionManager.allProfiles()
    }

    public func addProfile(_ profile: ServerProfile, secret: String?) {
        connectionManager.registerProfile(profile)
        if let secret = secret, !secret.isEmpty {
            connectionManager.keychain.saveSecret(secret, for: profile.id, account: profile.username)
        }
        loadProfiles()
        currentScreen = .main
        statusMessage = "Profile '\(profile.name)' created."

        Task {
            await mount(profile: profile)
        }
    }

    public func deleteProfile(_ id: UUID) {
        Task {
            if mountedDomainIDs.contains(id) {
                if let profile = profiles.first(where: { $0.id == id }) {
                    await unmount(profile: profile)
                }
            }
            connectionManager.keychain.deleteSecret(for: id)
            loadProfiles()
        }
    }

    public func toggleMount(for profile: ServerProfile) {
        Task {
            if mountedDomainIDs.contains(profile.id) {
                await unmount(profile: profile)
            } else {
                await mount(profile: profile)
            }
        }
    }

    public func mount(profile: ServerProfile) async {
        isMounting = true
        defer { isMounting = false }

        do {
            statusMessage = "Connecting to \(profile.host)..."
            let adapter = try await connectionManager.connect(to: profile.id)

            statusMessage = "Mounting volume..."
            let volumeURL = try volumeManager.mount(name: profile.name, isReadOnly: profile.isReadOnly)

            // Shallow listing of root directory only — instant!
            statusMessage = "Listing \(profile.remoteRootPath)..."
            _ = try await volumeManager.populateDirectory(
                adapter: adapter,
                remotePath: profile.remoteRootPath,
                localURL: volumeURL,
                cacheEngine: cacheEngine,
                isReadOnly: profile.isReadOnly
            )

            // Start bidirectional FSEvents watcher (auto-uploads new/modified files and syncs deletes)
            volumeManager.startWatching(
                name: profile.name,
                volumeURL: volumeURL,
                remoteRootPath: profile.remoteRootPath,
                adapter: adapter,
                cacheEngine: cacheEngine,
                isReadOnly: profile.isReadOnly
            ) { [weak self] status in
                Task { @MainActor in
                    self?.statusMessage = status
                    self?.refreshCacheStats()
                }
            }

            mountedDomainIDs.insert(profile.id)
            let modeBadge = profile.isReadOnly ? " [Read-Only]" : ""
            statusMessage = "✓ Mounted '\(profile.name)'\(modeBadge)"

            openInFinder(for: profile)
        } catch {
            print("Mount error: \(error)")
            statusMessage = "❌ Mount failed: \(error.localizedDescription)"
        }
        refreshCacheStats()
    }

    public func unmount(profile: ServerProfile) async {
        try? volumeManager.unmount(name: profile.name)
        await connectionManager.disconnect(from: profile.id)
        mountedDomainIDs.remove(profile.id)
        statusMessage = "Unmounted '\(profile.name)'."
        refreshCacheStats()
    }

    public func resetCircuitBreaker(for profile: ServerProfile) {
        volumeManager.resetCircuitBreaker(name: profile.name)
        statusMessage = "✓ Circuit breaker reset for '\(profile.name)'"
    }

    public func isCircuitBreakerTripped(for profile: ServerProfile) -> Bool {
        volumeManager.isCircuitBreakerTripped(name: profile.name)
    }

    public func syncVolume(profile: ServerProfile) async {
        isMounting = true
        defer { isMounting = false }
        statusMessage = "Syncing with \(profile.host)..."

        do {
            let adapter = try await connectionManager.connect(to: profile.id)
            let volumeURL = URL(fileURLWithPath: "/Volumes/\(profile.name)")

            if !FileManager.default.fileExists(atPath: volumeURL.path) {
                await mount(profile: profile)
                return
            }

            _ = try await volumeManager.syncAllPopulatedDirectories(
                adapter: adapter,
                rootRemotePath: profile.remoteRootPath,
                volumeURL: volumeURL,
                cacheEngine: cacheEngine,
                isReadOnly: profile.isReadOnly
            )
            statusMessage = "✓ Synced with \(profile.name)"
            refreshCacheStats()
        } catch {
            statusMessage = "❌ Sync failed: \(error.localizedDescription)"
        }
    }

    public func openInFinder(for profile: ServerProfile) {
        let volumeURL = URL(fileURLWithPath: "/Volumes/\(profile.name)")
        if FileManager.default.fileExists(atPath: volumeURL.path) {
            NSWorkspace.shared.open(volumeURL)
        } else {
            Task {
                await mount(profile: profile)
            }
        }
    }

    public func refreshCacheStats() {
        self.cacheStats = cacheEngine.statistics()
    }

    public func purgeCache() {
        do {
            try cacheEngine.purgeUnpinned()
            statusMessage = "✓ Cleared unpinned cache."
            refreshCacheStats()
        } catch {
            statusMessage = "❌ Failed to clear cache: \(error.localizedDescription)"
        }
    }

    private func refreshMountedVolumes() {
        var mounted = Set<UUID>()
        for profile in profiles {
            if volumeManager.isMounted(name: profile.name) {
                mounted.insert(profile.id)
            }
        }
        self.mountedDomainIDs = mounted
    }

    private func startPeriodicRefresh() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshCacheStats()
                self?.refreshMountedVolumes()
            }
        }
    }
}
