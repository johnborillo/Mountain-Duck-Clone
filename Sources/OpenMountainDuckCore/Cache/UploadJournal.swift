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
