import Foundation
import FileProvider

/// Enumerator that fetches directory contents from remote adapter and provides them to Finder.
public final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    private let containerItemIdentifier: NSFileProviderItemIdentifier
    private let remotePath: String
    private let profileID: UUID
    private let domainIdentifier: String
    private let connectionManager: ConnectionManager
    private let cacheEngine: CacheEngine
    private let metadataStore: DomainMetadataStore

    public init(
        containerItemIdentifier: NSFileProviderItemIdentifier,
        remotePath: String,
        profileID: UUID,
        connectionManager: ConnectionManager,
        cacheEngine: CacheEngine,
        metadataStore: DomainMetadataStore,
        domainIdentifier: String
    ) {
        self.containerItemIdentifier = containerItemIdentifier
        self.remotePath = remotePath
        self.profileID = profileID
        self.domainIdentifier = domainIdentifier
        self.connectionManager = connectionManager
        self.cacheEngine = cacheEngine
        self.metadataStore = metadataStore
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
                let visiblePaths = Set(entries.map(\.path))

                // A successful listing is authoritative for this parent. Retain tombstones
                // for items that disappeared remotely so Finder receives a durable delete
                // change on the next anchor request instead of resurrecting stale metadata.
                for existing in self.metadataStore.items(forParentItemIdentifier: self.containerItemIdentifier.rawValue, domainIdentifier: self.domainIdentifier)
                    where !existing.isDeleted && !visiblePaths.contains(existing.remotePath) {
                    self.metadataStore.markDeleted(domainIdentifier: self.domainIdentifier, itemIdentifier: existing.itemIdentifier)
                }

                for entry in entries {
                    let metadata = self.metadataStore.upsert(
                        domainIdentifier: self.domainIdentifier,
                        parentItemIdentifier: self.containerItemIdentifier.rawValue,
                        entry: entry
                    )
                    _ = self.cacheEngine.registerPlaceholder(for: entry, itemIdentifier: metadata.itemIdentifier)
                    let isDownloaded = FileManager.default.fileExists(atPath: self.cacheEngine.fileURL(for: metadata.itemIdentifier).path)
                    let item = FileProviderItem(from: metadata, isDownloaded: isDownloaded)
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
        let previous = self.metadataStore.sequence(from: anchor as NSData as Data)
        let changes = self.metadataStore.changes(domainIdentifier: self.domainIdentifier, after: previous)
        let deleted = changes.filter { $0.kind == DomainMetadataChange.Kind.delete }.map { NSFileProviderItemIdentifier($0.itemIdentifier) }
        if !deleted.isEmpty { observer.didDeleteItems(withIdentifiers: deleted) }

        let updatedIDs = changes.filter { $0.kind == DomainMetadataChange.Kind.upsert }.map { $0.itemIdentifier }
        let updated = self.metadataStore.items(for: updatedIDs, domainIdentifier: self.domainIdentifier).filter { !$0.isDeleted }.map { FileProviderItem(from: $0) }
        if !updated.isEmpty { observer.didUpdate(updated) }

        let nextSequence = changes.last?.sequence ?? self.metadataStore.currentSequence(domainIdentifier: self.domainIdentifier)
        observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(self.metadataStore.anchor(for: nextSequence)), moreComing: changes.count >= 500)
    }

    public func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(metadataStore.anchor(for: metadataStore.currentSequence(domainIdentifier: domainIdentifier))))
    }
}
