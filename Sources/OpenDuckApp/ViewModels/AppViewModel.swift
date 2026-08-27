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
    @Published public var editingProfile: ServerProfile? = nil
    @Published public var mountedDomainIDs: Set<UUID> = []
    @Published public var registeredDomainIDs: Set<UUID> = []
    @Published public var cacheStats: CacheStatistics = .empty
    @Published public var statusMessage: String? = nil
    @Published public var isMounting: Bool = false
    @Published public var activeTransfers: [TransferProgress] = []
    @Published public var recentTransfers: [TransferProgress] = []
    @Published public var pendingOperations: [JournalEntry] = []
    @Published public var conflicts: [DomainConflict] = []

    public let connectionManager: ConnectionManager
    public let cacheEngine: CacheEngine
    public let volumeManager: VolumeMountManager
    private var timer: Timer?
    private var lastRemoteSignal = Date.distantPast
    private let finderDomainSchemaKey = "com.openduck.finderDomainSchemaVersion"
    private let currentFinderDomainSchemaVersion = 3

    public init(
        connectionManager: ConnectionManager = .shared,
        cacheEngine: CacheEngine? = nil,
        volumeManager: VolumeMountManager = .shared
    ) {
        self.connectionManager = connectionManager
        self.volumeManager = volumeManager
        // Decoupling Safety Guarantee: The local cache directory MUST be placed in user Caches,
        // separate from any /Volumes/ path, so cache evictions do not generate FSEvents in mounted volumes.
        let cacheDir = OpenDuckSharedStorage.cacheDirectory
        assert(!cacheDir.path.hasPrefix("/Volumes/"), "cacheDir must not reside inside /Volumes")
        self.cacheEngine = cacheEngine ?? CacheEngine(
            cacheDirectory: cacheDir,
            journalURL: OpenDuckSharedStorage.uploadJournalURL
        )

        loadInitialData()
        startPeriodicRefresh()
    }

    public func loadInitialData() {
        loadProfiles()
        refreshCacheStats()
        refreshOperationalState()
        refreshMountedVolumes()
        refreshRegisteredDomains()
        migrateLegacyCredentials()
        repairLegacyFinderDomainsIfNeeded()
    }

    public func loadProfiles() {
        self.profiles = connectionManager.allProfiles()
    }

    public func addProfile(
        _ profile: ServerProfile,
        secret: String?,
        privateKeyBookmark: Data? = nil
    ) {
        connectionManager.registerProfile(profile)
        if let privateKeyBookmark {
            connectionManager.savePrivateKeyBookmark(privateKeyBookmark, for: profile.id)
        }
        if let secret = secret, !secret.isEmpty {
            do {
                try connectionManager.keychain.saveSecretOrThrow(
                    secret,
                    for: profile.id,
                    account: profile.username
                )
            } catch {
                statusMessage = "❌ \(error.localizedDescription)"
                return
            }
        }
        loadProfiles()
        currentScreen = .main
        statusMessage = "Profile '\(profile.name)' created."

        Task { await registerFinderDomain(for: profile) }
    }

    public func deleteProfile(_ id: UUID) {
        Task {
            if mountedDomainIDs.contains(id) {
                if let profile = profiles.first(where: { $0.id == id }) {
                    await unmount(profile: profile)
                }
            }
            if registeredDomainIDs.contains(id), let profile = profiles.first(where: { $0.id == id }) {
                guard await unregisterFinderDomain(for: profile) else { return }
            }
            connectionManager.deleteProfile(id: id)
            statusMessage = "✓ Connection profile deleted."
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

    public func toggleFinderDomain(for profile: ServerProfile) {
        Task {
            if registeredDomainIDs.contains(profile.id) {
                await unregisterFinderDomain(for: profile)
            } else {
                await registerFinderDomain(for: profile)
            }
        }
    }

    @discardableResult
    public func registerFinderDomain(for profile: ServerProfile) async -> Bool {
        do {
            let result = try await FileProviderDomainCoordinator.register(profile: profile)
            registeredDomainIDs.insert(profile.id)
            statusMessage = result.repairedLegacyDomain
                ? "✓ Repaired and added '\(profile.name)' to Finder."
                : "✓ Added '\(profile.name)' to Finder."
            return true
        } catch {
            statusMessage = "❌ Finder registration failed: \(FileProviderDomainCoordinator.diagnosticDescription(for: error))"
            return false
        }
    }

    @discardableResult
    public func unregisterFinderDomain(for profile: ServerProfile) async -> Bool {
        do {
            try await FileProviderDomainCoordinator.unregister(profile: profile)
            registeredDomainIDs.remove(profile.id)
            statusMessage = "Removed '\(profile.name)' from Finder."
            return true
        } catch {
            statusMessage = "❌ Finder removal failed: \(FileProviderDomainCoordinator.diagnosticDescription(for: error))"
            return false
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
                isReadOnly: profile.isReadOnly,
                onStatusChange: { [weak self] status in
                    Task { @MainActor in
                        self?.statusMessage = status
                        self?.refreshCacheStats()
                    }
                },
                onTransferUpdate: { [weak self] transfer in
                    Task { @MainActor in
                        self?.handleTransferUpdate(transfer)
                    }
                }
            )

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
            try await cacheEngine.syncPendingWrites(with: adapter)
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
        Task { @MainActor in
            guard registeredDomainIDs.contains(profile.id) else {
                _ = await registerFinderDomain(for: profile)
                return
            }

            do {
                guard let nativeURL = try await FileProviderDomainCoordinator.userVisibleURL(profile: profile) else {
                    throw FileProviderDomainError.userVisibleURLUnavailable(profile.name)
                }
                // Ask Finder to reveal the File Provider root. Opening the URL
                // directly makes LaunchServices treat the sandboxed host as the
                // reader and can produce a misleading permission dialog even
                // though Finder itself owns and can browse the domain.
                NSWorkspace.shared.activateFileViewerSelecting([nativeURL])
            } catch {
                statusMessage = "❌ Could not open Finder location: \(FileProviderDomainCoordinator.diagnosticDescription(for: error))"
            }
        }
    }

    public func refreshCacheStats() {
        self.cacheStats = cacheEngine.statistics()
    }

    public func refreshOperationalState() {
        var operations = cacheEngine.journal.pendingEntries()
        for profile in profiles {
            let domainJournal = UploadJournal(persistenceURL: OpenDuckSharedStorage.uploadJournalURL(forDomain: profile.id.uuidString))
            operations.append(contentsOf: domainJournal.pendingEntries())
        }
        pendingOperations = operations.sorted { $0.timestamp < $1.timestamp }
        conflicts = profiles.flatMap { DomainMetadataStore.shared.conflicts(domainIdentifier: $0.id.uuidString) }
    }

    /// Resolve a surfaced native-domain conflict without hiding the underlying
    /// journal entry. Keeping local leaves the durable upload for the extension's
    /// retry scheduler; keeping remote removes only operations for this item and
    /// lets the next working-set refresh hydrate the server copy.
    public func resolveConflict(_ conflict: DomainConflict, resolution: DomainConflict.Resolution) {
        let journals = [cacheEngine.journal] + profiles.map {
            UploadJournal(persistenceURL: OpenDuckSharedStorage.uploadJournalURL(forDomain: $0.id.uuidString))
        }
        if resolution == .keepLocal {
            for journal in journals {
                journal.unblock(itemIdentifier: conflict.itemIdentifier, remotePath: conflict.remotePath)
            }
        } else if resolution == .keepRemote {
            for journal in journals {
                for entry in journal.pendingEntries() where entry.itemIdentifier == conflict.itemIdentifier || entry.remotePath == conflict.remotePath {
                    journal.remove(id: entry.id)
                }
            }
            try? cacheEngine.evict(itemIdentifier: conflict.itemIdentifier)
        }
        DomainMetadataStore.shared.resolveConflict(id: conflict.id, resolution: resolution)
        statusMessage = resolution == .keepLocal
            ? "✓ Local changes kept; retrying \(conflict.remotePath)."
            : resolution == .keepRemote
                ? "✓ Remote version kept for \(conflict.remotePath)."
                : "✓ Conflict acknowledged for \(conflict.remotePath)."
        refreshOperationalState()
        if let profile = profiles.first(where: { $0.id.uuidString == conflict.domainIdentifier }) {
            Task { try? await FileProviderDomainCoordinator.signalWorkingSet(profile: profile) }
        }
    }

    @discardableResult
    public func exportDiagnostics() -> URL? {
        do {
            let url = try DiagnosticsExporter.writeReport(
                profiles: profiles,
                cacheStats: cacheStats,
                pendingOperations: pendingOperations,
                conflicts: conflicts
            )
            NSWorkspace.shared.activateFileViewerSelecting([url])
            statusMessage = "✓ Diagnostics report created."
            return url
        } catch {
            statusMessage = "❌ Could not create diagnostics report: \(error.localizedDescription)"
            return nil
        }
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

    private func refreshRegisteredDomains() {
        Task {
            guard let domains = try? await FileProviderDomainCoordinator.registeredDomains() else { return }
            let ids = domains.compactMap { UUID(uuidString: $0.identifier.rawValue) }
            await MainActor.run { self.registeredDomainIDs = Set(ids) }
        }
    }

    private func startPeriodicRefresh() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshCacheStats()
                self?.refreshMountedVolumes()
                self?.refreshOperationalState()
                if Date().timeIntervalSince(self?.lastRemoteSignal ?? .distantPast) > 30 {
                    self?.lastRemoteSignal = Date()
                    self?.signalNativeDomains()
                }
            }
        }
    }

    private func signalNativeDomains() {
        for profile in profiles where registeredDomainIDs.contains(profile.id) {
            Task { try? await FileProviderDomainCoordinator.signalWorkingSet(profile: profile) }
        }
    }

    // MARK: - Live Transfer Metrics
    
    public var totalTransferSpeedFormatted: String? {
        let activeSpeed = activeTransfers.reduce(0.0) { $0 + $1.bytesPerSecond }
        guard activeSpeed > 1024 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: Int64(activeSpeed)))/s"
    }

    public func handleTransferUpdate(_ progress: TransferProgress) {
        if progress.state == .completed || progress.state == .failed {
            activeTransfers.removeAll { $0.id == progress.id }
            recentTransfers.removeAll { $0.id == progress.id }
            recentTransfers.insert(progress, at: 0)
            if recentTransfers.count > 5 {
                recentTransfers = Array(recentTransfers.prefix(5))
            }
        } else {
            if let index = activeTransfers.firstIndex(where: { $0.id == progress.id }) {
                activeTransfers[index] = progress
            } else {
                activeTransfers.append(progress)
            }
        }
    }

    public func startEditing(profile: ServerProfile) {
        self.editingProfile = profile
        self.currentScreen = .addConnection
    }

    public func updateProfile(
        _ profile: ServerProfile,
        secret: String?,
        privateKeyBookmark: Data? = nil
    ) {
        let wasRegistered = registeredDomainIDs.contains(profile.id)
        if let privateKeyBookmark {
            connectionManager.savePrivateKeyBookmark(privateKeyBookmark, for: profile.id)
        }
        if let secret, !secret.isEmpty {
            do {
                try connectionManager.keychain.saveSecretOrThrow(
                    secret,
                    for: profile.id,
                    account: profile.username
                )
            } catch {
                statusMessage = "❌ \(error.localizedDescription)"
                return
            }
        }
        connectionManager.updateProfile(profile, secret: nil)
        loadProfiles()
        self.editingProfile = nil
        self.currentScreen = .main
        statusMessage = "✓ Profile '\(profile.name)' updated."
        if wasRegistered {
            Task { await registerFinderDomain(for: profile) }
        }
    }

    public func cancelTransfer(_ transfer: TransferProgress, deleteItem: Bool = false) {
        let localURL = URL(fileURLWithPath: transfer.remotePath)
        volumeManager.cancelTransfer(remotePath: transfer.remotePath, localURL: localURL, deleteLocal: deleteItem)
        activeTransfers.removeAll { $0.id == transfer.id }
        statusMessage = deleteItem ? "✓ Transfer cancelled and file deleted." : "✓ Transfer cancelled."
    }

    private func migrateLegacyCredentials() {
        do {
            let migrated = try connectionManager.migrateLegacyCredentials()
            if migrated > 0 {
                statusMessage = "✓ Migrated \(migrated) credential\(migrated == 1 ? "" : "s") for Finder access."
            }
        } catch {
            statusMessage = "❌ Credential migration failed: \(error.localizedDescription)"
        }
    }

    private func repairLegacyFinderDomainsIfNeeded() {
        guard UserDefaults.standard.integer(forKey: finderDomainSchemaKey) < currentFinderDomainSchemaVersion else {
            return
        }

        Task {
            do {
                let repaired = try await FileProviderDomainCoordinator.recreateRegisteredDomains(for: profiles)
                UserDefaults.standard.set(currentFinderDomainSchemaVersion, forKey: finderDomainSchemaKey)
                refreshRegisteredDomains()
                if repaired > 0 {
                    statusMessage = "✓ Repaired \(repaired) Finder connection\(repaired == 1 ? "" : "s") for native Cloud Storage."
                }
            } catch {
                statusMessage = "❌ Finder repair failed: \(FileProviderDomainCoordinator.diagnosticDescription(for: error))"
            }
        }
    }
}
