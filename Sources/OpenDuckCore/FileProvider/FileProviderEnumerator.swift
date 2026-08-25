import Foundation
import FileProvider

/// Enumerator that fetches directory contents from remote adapter and provides them to Finder.
public final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    private let containerItemIdentifier: NSFileProviderItemIdentifier
    private let remotePath: String
    private let profileID: UUID
    private let connectionManager: ConnectionManager
    private let cacheEngine: CacheEngine

    public init(
        containerItemIdentifier: NSFileProviderItemIdentifier,
        remotePath: String,
        profileID: UUID,
        connectionManager: ConnectionManager,
        cacheEngine: CacheEngine
    ) {
        self.containerItemIdentifier = containerItemIdentifier
        self.remotePath = remotePath
        self.profileID = profileID
        self.connectionManager = connectionManager
        self.cacheEngine = cacheEngine
        super.init()
    }

    public func invalidate() {
        // Clean up resources if necessary
    }

    public func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        Task {
            do {
                let adapter = try await self.connectionManager.connect(to: self.profileID)
                let entries = try await adapter.listDirectory(path: self.remotePath)
                var items: [NSFileProviderItem] = []

                for entry in entries {
                    _ = self.cacheEngine.registerPlaceholder(for: entry)
                    let isDownloaded = FileManager.default.fileExists(atPath: self.cacheEngine.fileURL(for: self.cacheEngine.itemIdentifier(for: entry.path)).path)
                    let item = FileProviderItem(
                        from: entry,
                        parentIdentifier: self.containerItemIdentifier,
                        isDownloaded: isDownloaded
                    )
                    items.append(item)
                }

                observer.didEnumerate(items)
                observer.finishEnumerating(upTo: nil)
            } catch {
                observer.finishEnumeratingWithError(error)
            }
        }
    }

    public func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    public func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let anchorData = "\(Date().timeIntervalSince1970)".data(using: .utf8)
        let anchor = anchorData.map { NSFileProviderSyncAnchor($0) }
        completionHandler(anchor)
    }
}
