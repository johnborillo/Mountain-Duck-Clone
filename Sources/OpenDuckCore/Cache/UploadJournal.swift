import Foundation

/// Defines a mutating filesystem operation awaiting synchronization to remote storage.
public enum JournalAction: String, Codable, Sendable {
    case upload
    case createDirectory
    case delete
    case move
}

/// A persistent log record representing an offline or queued write operation.
public struct JournalEntry: Codable, Sendable, Identifiable {
    public let id: UUID
    public let action: JournalAction
    public let itemIdentifier: String
    public let localFileURL: URL?
    public let remotePath: String
    public let destinationRemotePath: String?
    public let timestamp: Date
    public var retryCount: Int

    public init(
        id: UUID = UUID(),
        action: JournalAction,
        itemIdentifier: String,
        localFileURL: URL? = nil,
        remotePath: String,
        destinationRemotePath: String? = nil,
        timestamp: Date = Date(),
        retryCount: Int = 0
    ) {
        self.id = id
        self.action = action
        self.itemIdentifier = itemIdentifier
        self.localFileURL = localFileURL
        self.remotePath = remotePath
        self.destinationRemotePath = destinationRemotePath
        self.timestamp = timestamp
        self.retryCount = retryCount
    }
}

/// Thread-safe in-memory and disk-backed journal for crash-resilient write operations.
public final class UploadJournal: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [UUID: JournalEntry] = [:]
    private let persistenceURL: URL?

    public init(persistenceURL: URL? = nil) {
        self.persistenceURL = persistenceURL
        loadFromDisk()
    }

    public func append(_ entry: JournalEntry) {
        lock.lock()
        defer {
            saveToDisk()
            lock.unlock()
        }
        entries[entry.id] = entry
    }

    /// Records the latest pending upload for an item, replacing older upload
    /// intents. A burst of editor save events must never produce a replay queue
    /// that later uploads stale content over the newest version.
    public func replacePendingUpload(with entry: JournalEntry) {
        precondition(entry.action == .upload)
        replacePendingOperation(with: entry)
    }

    /// Replace an operation for the same item/path instead of allowing duplicate
    /// replay intents to accumulate after repeated Finder events.
    public func replacePendingOperation(with entry: JournalEntry) {
        lock.lock()
        defer {
            saveToDisk()
            lock.unlock()
        }
        entries = entries.filter { _, existing in
            guard existing.itemIdentifier == entry.itemIdentifier || existing.remotePath == entry.remotePath else {
                return true
            }

            // Uploads, deletes, directory creation, and moves are all safe to
            // coalesce for one item/path. Keep an existing operation only when it
            // represents a different path transition (e.g. unrelated move).
            // Coalesce repeated operations of the same kind, or operations
            // targeting the exact same remote path. Preserve different paths
            // for one item so a queued rename followed by a queued upload is
            // replayed in order rather than silently dropping one half.
            return !(existing.action == entry.action || existing.remotePath == entry.remotePath)
        }
        entries[entry.id] = entry
    }

    public func remove(id: UUID) {
        lock.lock()
        defer {
            saveToDisk()
            lock.unlock()
        }
        entries.removeValue(forKey: id)
    }

    public func pendingEntries() -> [JournalEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries.values.sorted { $0.timestamp < $1.timestamp }
    }

    /// Hold operations for an item after a version conflict. A blocked operation
    /// remains durable and visible, but replay loops skip it until the user
    /// explicitly chooses Keep Local or Keep Remote.
    public func block(itemIdentifier: String, remotePath: String? = nil, retryCount: Int = 10) {
        updateRetryCount(itemIdentifier: itemIdentifier, remotePath: remotePath, retryCount: retryCount)
    }

    public func unblock(itemIdentifier: String, remotePath: String? = nil) {
        updateRetryCount(itemIdentifier: itemIdentifier, remotePath: remotePath, retryCount: 0)
    }

    private func updateRetryCount(itemIdentifier: String, remotePath: String?, retryCount: Int) {
        lock.lock()
        defer {
            saveToDisk()
            lock.unlock()
        }
        for (id, var entry) in entries {
            guard entry.itemIdentifier == itemIdentifier || (remotePath != nil && entry.remotePath == remotePath) else { continue }
            entry.retryCount = retryCount
            entries[id] = entry
        }
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    public func clear() {
        lock.lock()
        defer {
            saveToDisk()
            lock.unlock()
        }
        entries.removeAll()
    }

    private func saveToDisk() {
        guard let url = persistenceURL else { return }
        do {
            let data = try JSONEncoder().encode(Array(entries.values))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            // Silently log or continue in memory
        }
    }

    private func loadFromDisk() {
        guard let url = persistenceURL, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let loaded = try JSONDecoder().decode([JournalEntry].self, from: data)
            lock.lock()
            for entry in loaded {
                entries[entry.id] = entry
            }
            lock.unlock()
        } catch {
            // Reset corrupted log
        }
    }
}
