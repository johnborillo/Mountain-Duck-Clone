import Foundation

/// Synchronization and caching state of a virtual file.
public enum CacheState: String, Codable, Sendable {
    case placeholder    // Metadata exists locally, file content resides only on remote server
    case downloading    // Content currently being fetched over network
    case materialized   // Content fully downloaded and valid in local cache
    case dirty          // Content modified locally; pending upload to remote
    case uploading      // Currently streaming modified content to remote
    case evicted        // Local content cleared to free disk space; downgraded to placeholder
}

/// Metadata record representing a cached filesystem item.
public struct CacheEntry: Codable, Sendable, Identifiable {
    public var id: String { itemIdentifier }

    public let itemIdentifier: String
    public let remotePath: String
    public var localFileName: String
    public var fileSize: Int64
    public var lastAccessedDate: Date
    public var localModificationDate: Date
    public var remoteModificationDate: Date
    public var isPinned: Bool
    public var state: CacheState
    public var etag: String?

    public init(
        itemIdentifier: String,
        remotePath: String,
        localFileName: String,
        fileSize: Int64,
        lastAccessedDate: Date = Date(),
        localModificationDate: Date = Date(),
        remoteModificationDate: Date = Date(),
        isPinned: Bool = false,
        state: CacheState = .placeholder,
        etag: String? = nil
    ) {
        self.itemIdentifier = itemIdentifier
        self.remotePath = remotePath
        self.localFileName = localFileName
        self.fileSize = fileSize
        self.lastAccessedDate = lastAccessedDate
        self.localModificationDate = localModificationDate
        self.remoteModificationDate = remoteModificationDate
        self.isPinned = isPinned
        self.state = state
        self.etag = etag
    }
}
