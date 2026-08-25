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
    private var retryTimer: DispatchSourceTimer?
    private let maxRetryCount = 10
    private var retryBackoffSeconds: TimeInterval = 5.0
    private var retryAdapterProvider: (@Sendable () async throws -> RemoteFilesystemAdapter)?
    private var operationCompletionHandler: (@Sendable (JournalEntry) -> Void)?
    /// Serializes journal replay with explicit sync calls so two recovery loops
    /// cannot upload/delete the same operation concurrently.
    private let synchronizationQueue = AsyncTransferQueue(maxConcurrent: 1)

    /// Initialize the CacheEngine.
    ///
    /// - Important: Decoupling Safety Guarantee
    ///   `cacheDirectory` must reside outside of any mounted `/Volumes/<name>` hierarchy.
    ///   Because evictions remove local files, having the cache inside a watched volume directory
    ///   would emit FSEvents deletions and inadvertently trigger remote deletions.
    public init(
        cacheDirectory: URL,
        evictionPolicy: LRUEvictionPolicy = LRUEvictionPolicy(),
        journalURL: URL? = nil
    ) {
        let standardizedPath = cacheDirectory.standardizedFileURL.path
        assert(!standardizedPath.hasPrefix("/Volumes/"), "CRITICAL SAFETY VIOLATION: cacheDirectory cannot reside inside a mounted /Volumes/ path, as evictions would trigger remote deletions via FSEvents.")
        precondition(!standardizedPath.hasPrefix("/Volumes/"), "CRITICAL SAFETY VIOLATION: cacheDirectory cannot reside inside /Volumes/")

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
        registerPlaceholder(for: entry, itemIdentifier: makeIdentifier(for: entry.path))
    }

    /// Register a placeholder using a caller-owned identity (used by native File Provider).
    public func registerPlaceholder(for entry: RemoteFileEntry, itemIdentifier: String) -> CacheEntry {
        sync {
            let identifier = itemIdentifier
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

    public func entry(for itemIdentifier: String) -> CacheEntry? {
        sync { index[itemIdentifier] }
    }

    public func isItemDirty(itemIdentifier: String) -> Bool {
        sync { index[itemIdentifier]?.isDirty ?? false }
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
        let stagingURL = localURL.appendingPathExtension("openduck-download-\(UUID().uuidString)")
        do {
            defer { try? FileManager.default.removeItem(at: stagingURL) }
            let remoteBefore = try await adapter.stat(path: remotePath)
            try await adapter.download(remotePath: remotePath, to: stagingURL, progress: progress)
            let remoteAfter = try await adapter.stat(path: remotePath)
            guard remoteBefore.contentVersion == remoteAfter.contentVersion else {
                throw AdapterError.conflict(localVersion: remoteBefore.contentVersion, remoteVersion: remoteAfter.contentVersion)
            }

            let attributes = try FileManager.default.attributesOfItem(atPath: stagingURL.path)
            let actualSize = (attributes[.size] as? Int64) ?? 0
            guard actualSize == remoteAfter.size else {
                throw AdapterError.networkError("Downloaded \(actualSize) bytes for '\(remotePath)', expected \(remoteAfter.size).")
            }
            if FileManager.default.fileExists(atPath: localURL.path) {
                try FileManager.default.removeItem(at: localURL)
            }
            try FileManager.default.moveItem(at: stagingURL, to: localURL)

            sync {
                if var entry = index[itemIdentifier] {
                    entry.fileSize = actualSize
                    entry.lastAccessedDate = Date()
                    entry.localModificationDate = (attributes[.modificationDate] as? Date) ?? Date()
                    entry.remoteModificationDate = remoteAfter.modificationDate
                    entry.etag = remoteAfter.etag
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

            journal.replacePendingUpload(with: JournalEntry(
                action: .upload,
                itemIdentifier: itemIdentifier,
                localFileURL: targetURL,
                remotePath: entry.remotePath
            ))
        }
    }

    /// Mark an item clean after it has been successfully synchronized to the remote adapter.
    public func markClean(itemIdentifier: String, remotePath: String) {
        sync {
            if var entry = index[itemIdentifier] {
                entry.state = .materialized
                entry.remoteModificationDate = Date()
                index[itemIdentifier] = entry
            }
        }
        if let op = journal.pendingEntries().first(where: { $0.itemIdentifier == itemIdentifier || $0.remotePath == remotePath }) {
            journal.remove(id: op.id)
        }
    }

    /// Commit dirty files to remote storage through the adapter.
    public func syncPendingWrites(with adapter: RemoteFilesystemAdapter) async throws {
        await synchronizationQueue.acquire()
        do {
            try await syncPendingWritesLocked(with: adapter)
            await synchronizationQueue.release()
        } catch {
            await synchronizationQueue.release()
            throw error
        }
    }

    private func syncPendingWritesLocked(with adapter: RemoteFilesystemAdapter) async throws {
        let pending = journal.pendingEntries()
        for op in pending where op.retryCount < maxRetryCount {
            try await replay(op, with: adapter)
            if op.action == .upload {
                sync {
                    if var entry = index[op.itemIdentifier] {
                        entry.state = .materialized
                        entry.remoteModificationDate = Date()
                        index[op.itemIdentifier] = entry
                    }
                }
            }
            notifyOperationCompleted(op)
            journal.remove(id: op.id)
        }
    }

    /// Queue a write operation even when a caller does not yet have a cache entry
    /// (for example, a native File Provider create that failed before stat).
    public func enqueue(_ entry: JournalEntry) {
        journal.replacePendingOperation(with: entry)
    }

    /// Observe successful durable replays so a File Provider extension can
    /// reconcile metadata immediately instead of waiting for the next periodic
    /// directory scan. The handler cannot block or fail the remote commit.
    public func setOperationCompletionHandler(_ handler: (@Sendable (JournalEntry) -> Void)?) {
        sync { operationCompletionHandler = handler }
    }

    private func notifyOperationCompleted(_ entry: JournalEntry) {
        let handler = sync { operationCompletionHandler }
        handler?(entry)
    }

    /// Stage a transient File Provider/Finder source URL into the durable cache
    /// before queuing its upload. File Provider may delete its temporary source
    /// as soon as the callback returns, so the journal must never point at it.
    public func enqueueUpload(itemIdentifier: String, remotePath: String, sourceURL: URL) throws {
        let durableURL = fileURL(for: itemIdentifier)
        if sourceURL.standardizedFileURL != durableURL.standardizedFileURL {
            try FileManager.default.createDirectory(at: durableURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: durableURL.path) {
                try FileManager.default.removeItem(at: durableURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: durableURL)
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: durableURL.path)
        let fileSize = (attributes?[.size] as? Int64) ?? 0
        sync {
            var entry = index[itemIdentifier] ?? CacheEntry(
                itemIdentifier: itemIdentifier,
                remotePath: remotePath,
                localFileName: durableURL.lastPathComponent,
                fileSize: fileSize,
                state: .dirty
            )
            entry.state = .dirty
            entry.fileSize = fileSize
            index[itemIdentifier] = entry
        }
        journal.replacePendingUpload(with: JournalEntry(
            action: .upload,
            itemIdentifier: itemIdentifier,
            localFileURL: durableURL,
            remotePath: remotePath
        ))
    }

    private func replay(_ op: JournalEntry, with adapter: RemoteFilesystemAdapter) async throws {
        switch op.action {
        case .upload:
            guard let localURL = op.localFileURL,
                  FileManager.default.fileExists(atPath: localURL.path) else {
                throw AdapterError.invalidPath("Queued upload content is unavailable for \(op.remotePath). The operation was retained for recovery.")
            }
            try await adapter.upload(from: localURL, to: op.remotePath, progress: nil)
        case .createDirectory:
            do {
                try await adapter.createDirectory(path: op.remotePath)
            } catch let error {
                guard let adapterError = error as? AdapterError,
                      case .alreadyExists = adapterError else { throw error }
            }
        case .delete:
            do {
                try await adapter.delete(remotePath: op.remotePath)
            } catch let error {
                guard let adapterError = error as? AdapterError,
                      case .fileNotFound = adapterError else { throw error }
            }
        case .move:
            guard let destination = op.destinationRemotePath else {
                throw AdapterError.invalidPath("Queued move has no destination for \(op.remotePath).")
            }
            do {
                try await adapter.move(from: op.remotePath, to: destination)
            } catch let error {
                // A crash after a successful remote move but before journal removal
                // leaves the source missing. Treat it as applied when the destination
                // is already present.
                guard let adapterError = error as? AdapterError,
                      case .fileNotFound = adapterError,
                      await remoteItemExists(destination, on: adapter) else { throw error }
            }
        }
    }

    private func remoteItemExists(_ path: String, on adapter: RemoteFilesystemAdapter) async -> Bool {
        (try? await adapter.stat(path: path)) != nil
    }

    // MARK: - Background Retry Scheduler

    /// Starts a background retry timer that processes pending journal entries with exponential backoff.
    /// Backoff schedule: 5s → 15s → 45s → 135s (capped at 300s), with ±20% jitter.
    public func startRetryScheduler(adapter: RemoteFilesystemAdapter) {
        startRetryScheduler(adapterProvider: { adapter })
    }

    /// Start retries with a provider that can reconnect instead of retaining a
    /// dead transport object after a network interruption.
    public func startRetryScheduler(adapterProvider: @escaping @Sendable () async throws -> RemoteFilesystemAdapter) {
        let shouldStart: Bool = sync {
            retryAdapterProvider = adapterProvider
            guard retryTimer == nil else { return false }
            retryBackoffSeconds = 5.0
            return true
        }
        if shouldStart { scheduleNextRetry() }
    }

    /// Stops the background retry timer.
    public func stopRetryScheduler() {
        sync {
            retryTimer?.cancel()
            retryTimer = nil
            retryAdapterProvider = nil
        }
    }

    private func scheduleNextRetry() {
        guard sync({ retryAdapterProvider != nil }) else { return }
        let backoff: TimeInterval = sync { retryBackoffSeconds }
        let jitter = backoff * Double.random(in: -0.2...0.2)
        let delay = max(1.0, backoff + jitter)

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            Task {
                await self.executeRetry()
            }
        }
        sync {
            retryTimer?.cancel()
            retryTimer = timer
        }
        timer.resume()
    }

    private func executeRetry() async {
        await synchronizationQueue.acquire()
        let pending = journal.pendingEntries()
        guard !pending.isEmpty else {
            // Nothing to retry — reset backoff and reschedule with base interval
            sync { retryBackoffSeconds = 5.0 }
            await synchronizationQueue.release()
            scheduleNextRetry()
            return
        }

        let provider: (@Sendable () async throws -> RemoteFilesystemAdapter)? = sync { retryAdapterProvider }
        guard let provider else {
            await synchronizationQueue.release()
            scheduleNextRetry()
            return
        }

        let adapter: RemoteFilesystemAdapter
        do {
            adapter = try await provider()
        } catch {
            incrementRetryCounts(for: pending)
            sync { retryBackoffSeconds = min(retryBackoffSeconds * 3.0, 300.0) }
            await synchronizationQueue.release()
            scheduleNextRetry()
            return
        }

        var allSucceeded = true
        for op in pending {
            if op.retryCount >= maxRetryCount {
                // Mark as permanently failed — leave in journal for UI visibility
                continue
            }

            do {
                try await replay(op, with: adapter)
                if op.action == .upload {
                    sync {
                        if var entry = index[op.itemIdentifier] {
                            entry.state = .materialized
                            entry.remoteModificationDate = Date()
                            index[op.itemIdentifier] = entry
                        }
                    }
                }
                notifyOperationCompleted(op)
                journal.remove(id: op.id)
            } catch {
                allSucceeded = false
                // Increment retry count
                var updated = op
                updated.retryCount += 1
                journal.remove(id: op.id)
                journal.append(updated)
            }
        }

        // Adjust backoff: reset on full success, increase on any failure
        sync {
            if allSucceeded {
                retryBackoffSeconds = 5.0
            } else {
                retryBackoffSeconds = min(retryBackoffSeconds * 3.0, 300.0)
            }
        }
        await synchronizationQueue.release()
        scheduleNextRetry()
    }

    private func incrementRetryCounts(for entries: [JournalEntry]) {
        for entry in entries {
            var updated = entry
            updated.retryCount += 1
            journal.remove(id: entry.id)
            journal.append(updated)
        }
    }

    /// Returns journal entries that have exceeded the maximum retry count.
    public func permanentlyFailedEntries() -> [JournalEntry] {
        return journal.pendingEntries().filter { $0.retryCount >= maxRetryCount }
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

    /// Purge all unpinned, non-dirty cached files and reset their states to placeholder.
    /// Pinned items and dirty items (pending write-back) are strictly preserved to prevent data loss.
    public func purgeUnpinned() throws {
        let unpinned: [String] = sync {
            index.values.filter { !$0.isPinned && $0.state != .dirty }.map { $0.itemIdentifier }
        }
        for id in unpinned {
            try? evict(itemIdentifier: id)
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
