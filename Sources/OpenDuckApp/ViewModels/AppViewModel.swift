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

    public init(
        connectionManager: ConnectionManager = .shared,
        cacheEngine: CacheEngine? = nil,
        volumeManager: VolumeMountManager = .shared
    ) {
        self.connectionManager = connectionManager
        self.volumeManager = volumeManager
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.openduck.app/cache")
        self.cacheEngine = cacheEngine ?? CacheEngine(cacheDirectory: cacheDir)

        loadInitialData()
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

            statusMessage = "Mounting volume in Finder Locations..."
            let volumeURL = try volumeManager.mount(name: profile.name)

            statusMessage = "Recursively syncing remote directory tree..."
            try await volumeManager.syncTree(
                adapter: adapter,
                remotePath: profile.remoteRootPath,
                localURL: volumeURL,
                cacheEngine: cacheEngine,
                maxDepth: 3
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.statusMessage = progress
                }
            }

            mountedDomainIDs.insert(profile.id)
            statusMessage = "✓ Mounted '\(profile.name)' in Locations."

            // Automatically reveal volume in Finder!
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

    public func openInFinder(for profile: ServerProfile) {
        let volumeURL = URL(fileURLWithPath: "/Volumes/\(profile.name)")
        if FileManager.default.fileExists(atPath: volumeURL.path) {
            NSWorkspace.shared.open(volumeURL)
        } else {
            // Re-mount if detached
            Task {
                await mount(profile: profile)
            }
        }
    }

    public func refreshCacheStats() {
        self.cacheStats = cacheEngine.statistics()
    }

    public func purgeCache() {
        let allEntries = cacheEngine.statistics()
        if allEntries.totalItems > 0 {
            statusMessage = "Purged unpinned cache."
            refreshCacheStats()
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
}
