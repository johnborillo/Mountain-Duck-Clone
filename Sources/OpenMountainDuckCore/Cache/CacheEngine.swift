import Foundation

/// Statistical snapshot of local cache state.
public struct CacheStatistics: Sendable {
    public let totalItems: Int
    public let materializedItems: Int
    public let pinnedItems: Int
    public let dirtyItems: Int
    public let totalSizeBytes: Int64
    public let maxCapacityBytes: Int64

    public init(
        totalItems: Int = 0,
        materializedItems: Int = 0,
        pinnedItems: Int = 0,
        dirtyItems: Int = 0,
        totalSizeBytes: Int64 = 0,
        maxCapacityBytes: Int64 = 5 * 1024 * 1024 * 1024
    ) {
        self.totalItems = totalItems
        self.materializedItems = materializedItems
        self.pinnedItems = pinnedItems
        self.dirtyItems = dirtyItems
        self.totalSizeBytes = totalSizeBytes
        self.maxCapacityBytes = maxCapacityBytes
    }

    public static let empty = CacheStatistics()
}

/// Central controller orchestrating local file caching, on-demand hydration, and background synchronization.
public final class CacheEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var index: [String: CacheEntry] = [:] // Keyed by itemIdentifier
    private var pathToIdentifier: [String: String] = [:]

    public let cacheDirectory: URL
    public let evictionPolicy: LRUEvictionPolicy
    public let journal: UploadJournal

    public init(
        cacheDirectory: URL,
        evictionPolicy: LRUEvictionPolicy = LRUEvictionPolicy(),
        journalURL: URL? = nil
    ) {
        self.cacheDirectory = cacheDirectory
        self.evictionPolicy = evictionPolicy
        self.journal = UploadJournal(persistenceURL: journalURL)
        createDirectoriesIfNeeded()
    }

    private func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Register or update a remote item's metadata placeholder.
    public func registerPlaceholder(for entry: RemoteFileEntry) -> CacheEntry {
        sync {
            let identifier = makeIdentifier(for: entry.path)
            pathToIdentifier[entry.path] = identifier

            if var existing = index[identifier] {
                existing.remoteModificationDate = entry.modificationDate
                existing.fileSize = entry.size
                index[identifier] = existing
                return existing
            }

            let newEntry = CacheEntry(
                itemIdentifier: identifier,
                remotePath: entry.path,
                localFileName: entry.name,
                fileSize: entry.size,
                remoteModificationDate: entry.modificationDate,
                state: .placeholder
            )
            index[identifier] = newEntry
            return newEntry
        }
    }

    /// Retrieve local cached file URL if materialized, or download from remote adapter on demand.
    public func getOrHydrate(
        itemIdentifier: String,
        remotePath: String,
        adapter: RemoteFilesystemAdapter,
        progress: Progress? = nil
    ) async throws -> URL {
        let localURL = fileURL(for: itemIdentifier)

        let shouldDownload: Bool = sync {
            var entry = index[itemIdentifier] ?? CacheEntry(
                itemIdentifier: itemIdentifier,
                remotePath: remotePath,
                localFileName: (remotePath as NSString).lastPathComponent,
                fileSize: 0,
                state: .placeholder
            )

            if entry.state == .materialized || entry.state == .dirty {
                if FileManager.default.fileExists(atPath: localURL.path) {
                    entry.lastAccessedDate = Date()
                    index[itemIdentifier] = entry
                    return false
                }
            }

            entry.state = .downloading
            index[itemIdentifier] = entry
            return true
        }

        if !shouldDownload {
            return localURL
        }

        // Perform download
        do {
            try await adapter.download(remotePath: remotePath, to: localURL, progress: progress)

            let attributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
            let actualSize = (attributes[.size] as? Int64) ?? 0

            sync {
                if var entry = index[itemIdentifier] {
                    entry.fileSize = actualSize
                    entry.lastAccessedDate = Date()
                    entry.localModificationDate = (attributes[.modificationDate] as? Date) ?? Date()
                    entry.state = .materialized
                    index[itemIdentifier] = entry
                }
            }

            // Run cache eviction if threshold exceeded
            enforceEvictionPolicy()

            return localURL
        } catch {
            sync {
                if var entry = index[itemIdentifier] {
                    entry.state = .placeholder
                    index[itemIdentifier] = entry
                }
            }
            throw error
        }
    }

    /// Mark a local file as dirty when written by Finder or a user application.
    public func markDirty(itemIdentifier: String, newLocalURL: URL? = nil) {
        sync {
            guard var entry = index[itemIdentifier] else { return }
            entry.state = .dirty
            entry.localModificationDate = Date()

            let targetURL = newLocalURL ?? fileURL(for: itemIdentifier)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: targetURL.path) {
                entry.fileSize = (attrs[.size] as? Int64) ?? entry.fileSize
            }

            index[itemIdentifier] = entry

            journal.append(JournalEntry(
                action: .upload,
                itemIdentifier: itemIdentifier,
                localFileURL: targetURL,
                remotePath: entry.remotePath
            ))
        }
    }

    /// Commit dirty files to remote storage through the adapter.
    public func syncPendingWrites(with adapter: RemoteFilesystemAdapter) async throws {
        let pending = journal.pendingEntries()
        for op in pending {
            switch op.action {
            case .upload:
                if let localURL = op.localFileURL, FileManager.default.fileExists(atPath: localURL.path) {
                    try await adapter.upload(from: localURL, to: op.remotePath, progress: nil)
                    sync {
                        if var entry = index[op.itemIdentifier] {
                            entry.state = .materialized
                            entry.remoteModificationDate = Date()
                            index[op.itemIdentifier] = entry
                        }
                    }
                }
            case .createDirectory:
                try await adapter.createDirectory(path: op.remotePath)
            case .delete:
                try await adapter.delete(remotePath: op.remotePath)
            case .move:
                if let dest = op.destinationRemotePath {
                    try await adapter.move(from: op.remotePath, to: dest)
                }
            }
            journal.remove(id: op.id)
        }
    }

    /// Pin an item so it will never be evicted during cache pressure.
    public func setPinned(_ isPinned: Bool, for itemIdentifier: String) {
        sync {
            if var entry = index[itemIdentifier] {
                entry.isPinned = isPinned
                index[itemIdentifier] = entry
            }
        }
    }

    /// Evict local content for a specific item, returning it to placeholder state.
    public func evict(itemIdentifier: String) throws {
        let shouldRemove: Bool = sync {
            guard var entry = index[itemIdentifier], !entry.isPinned else {
                return false
            }
            entry.state = .evicted
            index[itemIdentifier] = entry
            return true
        }

        if shouldRemove {
            let localURL = fileURL(for: itemIdentifier)
            if FileManager.default.fileExists(atPath: localURL.path) {
                try FileManager.default.removeItem(at: localURL)
            }
        }
    }

    /// Compute statistics regarding current cache footprint.
    public func statistics() -> CacheStatistics {
        sync {
            var totalBytes: Int64 = 0
            var materialized = 0
            var pinned = 0
            var dirty = 0

            for entry in index.values {
                if entry.isPinned { pinned += 1 }
                if entry.state == .dirty { dirty += 1 }
                if entry.state == .materialized || entry.state == .dirty {
                    materialized += 1
                    totalBytes += entry.fileSize
                }
            }

            return CacheStatistics(
                totalItems: index.count,
                materializedItems: materialized,
                pinnedItems: pinned,
                dirtyItems: dirty,
                totalSizeBytes: totalBytes,
                maxCapacityBytes: evictionPolicy.maxCacheSizeBytes
            )
        }
    }

    public func fileURL(for itemIdentifier: String) -> URL {
        return cacheDirectory.appendingPathComponent(itemIdentifier)
    }

    public func itemIdentifier(for remotePath: String) -> String {
        sync {
            if let id = pathToIdentifier[remotePath] { return id }
            let id = makeIdentifier(for: remotePath)
            pathToIdentifier[remotePath] = id
            return id
        }
    }

    private func enforceEvictionPolicy() {
        let allEntries: [CacheEntry] = sync {
            Array(index.values)
        }

        let victims = evictionPolicy.selectEntriesForEviction(from: allEntries)
        for victim in victims {
            try? evict(itemIdentifier: victim.itemIdentifier)
        }
    }

    private func makeIdentifier(for path: String) -> String {
        return Data(path.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
    }

    private func createDirectoriesIfNeeded() {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
}
