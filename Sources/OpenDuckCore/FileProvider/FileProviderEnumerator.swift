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
                self.startRetryScheduler()
                let adapter = try await self.connectionManager.connect(to: self.profileID)
                let entries = try await adapter.listDirectory(path: self.remotePath)
                let items = self.reconcile(entries: entries)

                observer.didEnumerate(items)
                observer.finishEnumerating(upTo: nil)
            } catch {
                observer.finishEnumeratingWithError(FileProviderErrorMapper.map(error))
            }
        }
    }

    public func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        // SFTP has no push channel. A working-set signal asks us to refresh the
        // current directory before replaying the durable change log, so Finder can
        // discover remote edits/deletes made by another client as well as local writes.
        Task {
            await self.refreshRemoteMetadata()
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
    }

    public func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(metadataStore.anchor(for: metadataStore.currentSequence(domainIdentifier: domainIdentifier))))
    }

    private func refreshRemoteMetadata() async {
        do {
            startRetryScheduler()
            let adapter = try await connectionManager.connect(to: profileID)
            let entries = try await adapter.listDirectory(path: remotePath)
            _ = reconcile(entries: entries)
        } catch {
            // Preserve the last known metadata/change anchor when the network is
            // unavailable. The next signal or Finder request will retry.
        }
    }

    private func startRetryScheduler() {
        cacheEngine.startRetryScheduler { [connectionManager, profileID] in
            try await connectionManager.connect(to: profileID)
        }
    }

    private func reconcile(entries: [RemoteFileEntry]) -> [NSFileProviderItem] {
        var items: [NSFileProviderItem] = []
        let visiblePaths = Set(entries.map { RemotePath.normalize($0.path) })
        let pendingIDs = Set(cacheEngine.journal.pendingEntries().map(\.itemIdentifier))

        // A successful listing is authoritative for this parent, except for
        // mutations still in the durable journal. Keeping those rows prevents an
        // offline create/upload from being tombstoned by a background refresh.
        for existing in metadataStore.items(forParentItemIdentifier: containerItemIdentifier.rawValue, domainIdentifier: domainIdentifier)
            where !existing.isDeleted && !visiblePaths.contains(existing.remotePath) && !pendingIDs.contains(existing.itemIdentifier) {
            metadataStore.markDeleted(domainIdentifier: domainIdentifier, itemIdentifier: existing.itemIdentifier)
        }

        for entry in entries {
            let existing = metadataStore.item(forRemotePath: entry.path, domainIdentifier: domainIdentifier)
            if let existing, pendingIDs.contains(existing.itemIdentifier) {
                items.append(FileProviderItem(from: existing, isDownloaded: FileManager.default.fileExists(atPath: cacheEngine.fileURL(for: existing.itemIdentifier).path)))
                continue
            }
            let metadata = metadataStore.upsert(
                domainIdentifier: domainIdentifier,
                parentItemIdentifier: containerItemIdentifier.rawValue,
                entry: entry
            )
            _ = cacheEngine.registerPlaceholder(for: entry, itemIdentifier: metadata.itemIdentifier)
            let isDownloaded = FileManager.default.fileExists(atPath: cacheEngine.fileURL(for: metadata.itemIdentifier).path)
            items.append(FileProviderItem(from: metadata, isDownloaded: isDownloaded))
        }
        return items
    }
}
