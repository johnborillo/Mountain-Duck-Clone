import Foundation
import FileProvider

/// Root File Provider Replicated Extension orchestrating Finder interactions.
@objc(FileProviderExtension)
public final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, @unchecked Sendable {
    public let domain: NSFileProviderDomain
    public let cacheEngine: CacheEngine
    public let connectionManager: ConnectionManager
    public let metadataStore: DomainMetadataStore

    /// Bounds the number of concurrent file uploads to prevent SSH channel exhaustion.
    /// Without this, Finder can trigger 97+ simultaneous upload Tasks, each spawning
    /// 8 concurrent chunk writes = ~776 in-flight SFTP requests on a single channel.
    private let transferQueue = AsyncTransferQueue(maxConcurrent: 4)

    public required init(domain: NSFileProviderDomain) {
        self.domain = domain
        let domainID = domain.identifier.rawValue
        self.cacheEngine = CacheEngine(
            cacheDirectory: OpenDuckSharedStorage.cacheDirectory(forDomain: domainID),
            journalURL: OpenDuckSharedStorage.uploadJournalURL(forDomain: domainID)
        )
        self.connectionManager = ConnectionManager.shared
        self.metadataStore = .shared
        super.init()
    }

    public func invalidate() {
        // Cleanup domain resources
    }

    public func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Task {
            do {
                if identifier == .rootContainer {
                    let rootItem = FileProviderItem(
                        itemIdentifier: .rootContainer,
                        parentItemIdentifier: .rootContainer,
                        filename: self.domain.displayName,
                        isDirectory: true
                    )
                    completionHandler(rootItem, nil)
                    return
                }

                let remotePath = self.resolveRemotePath(for: identifier)
                let adapter = try await self.adapterForDomain()

                let entry = try await adapter.stat(path: remotePath)
                let metadata = self.metadataStore.upsert(
                    domainIdentifier: self.domain.identifier.rawValue,
                    parentItemIdentifier: self.metadataStore.item(for: identifier.rawValue, domainIdentifier: self.domain.identifier.rawValue)?.parentItemIdentifier ?? NSFileProviderItemIdentifier.rootContainer.rawValue,
                    entry: entry,
                    itemIdentifier: identifier.rawValue
                )
                let item = FileProviderItem(from: metadata)
                completionHandler(item, nil)
            } catch {
                completionHandler(nil, error)
            }
        }
        return progress
    }

    public func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)

        Task {
            do {
                let adapter = try await self.adapterForDomain()

                let remotePath = self.resolveRemotePath(for: itemIdentifier)
                let localURL = try await self.cacheEngine.getOrHydrate(
                    itemIdentifier: itemIdentifier.rawValue,
                    remotePath: remotePath,
                    adapter: adapter,
                    progress: progress
                )

                let entry = try await adapter.stat(path: remotePath)
                let metadata = self.metadataStore.upsert(
                    domainIdentifier: self.domain.identifier.rawValue,
                    parentItemIdentifier: self.metadataStore.item(for: itemIdentifier.rawValue, domainIdentifier: self.domain.identifier.rawValue)?.parentItemIdentifier ?? NSFileProviderItemIdentifier.rootContainer.rawValue,
                    entry: entry,
                    itemIdentifier: itemIdentifier.rawValue
                )
                let item = FileProviderItem(from: metadata, isDownloaded: true)
                completionHandler(localURL, item, nil)
            } catch {
                completionHandler(nil, nil, error)
            }
        }

        return progress
    }

    public func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)

        Task {
            do {
                let adapter = try await self.adapterForDomain()

                let isDir = itemTemplate.contentType == .folder
                let remotePath = self.appendPath(self.resolveRemotePath(for: itemTemplate.parentItemIdentifier), itemTemplate.filename)

                if isDir {
                    try await adapter.createDirectory(path: remotePath)
                } else if let localURL = url {
                    await self.transferQueue.acquire()
                    defer { Task { await self.transferQueue.release() } }
                    try await adapter.upload(from: localURL, to: remotePath, progress: progress)
                }

                let entry = try await adapter.stat(path: remotePath)
                let metadata = self.metadataStore.upsert(
                    domainIdentifier: self.domain.identifier.rawValue,
                    parentItemIdentifier: itemTemplate.parentItemIdentifier.rawValue,
                    entry: entry
                )
                let newItem = FileProviderItem(from: metadata, isDownloaded: isDir || url != nil)
                completionHandler(newItem, fields, false, nil)
            } catch {
                completionHandler(nil, [], false, error)
            }
        }

        return progress
    }

    public func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)

        Task {
            do {
                let adapter = try await self.adapterForDomain()

                guard let existing = self.metadataStore.item(for: item.itemIdentifier.rawValue, domainIdentifier: self.domain.identifier.rawValue) else {
                    throw AdapterError.fileNotFound(item.itemIdentifier.rawValue)
                }
                var remotePath = existing.remotePath

                if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
                    let destinationParent = self.resolveRemotePath(for: item.parentItemIdentifier)
                    let destinationPath = self.appendPath(destinationParent, item.filename)
                    if let conflicting = self.metadataStore.item(forRemotePath: destinationPath, domainIdentifier: self.domain.identifier.rawValue), conflicting.itemIdentifier != item.itemIdentifier.rawValue, !conflicting.isDeleted {
                        throw AdapterError.alreadyExists(destinationPath)
                    }
                    try await adapter.move(from: existing.remotePath, to: destinationPath)
                    _ = self.metadataStore.move(
                        domainIdentifier: self.domain.identifier.rawValue,
                        itemIdentifier: item.itemIdentifier.rawValue,
                        parentItemIdentifier: item.parentItemIdentifier.rawValue,
                        filename: item.filename,
                        remotePath: destinationPath
                    )
                    remotePath = destinationPath
                }

                if let fileURL = newContents {
                    self.cacheEngine.markDirty(itemIdentifier: item.itemIdentifier.rawValue, newLocalURL: fileURL)
                    await self.transferQueue.acquire()
                    defer { Task { await self.transferQueue.release() } }
                    try await adapter.upload(from: fileURL, to: remotePath, progress: progress)
                }

                let updatedEntry = try await adapter.stat(path: remotePath)
                let metadata = self.metadataStore.upsert(
                    domainIdentifier: self.domain.identifier.rawValue,
                    parentItemIdentifier: item.parentItemIdentifier.rawValue,
                    entry: updatedEntry,
                    itemIdentifier: item.itemIdentifier.rawValue
                )
                let updatedItem = FileProviderItem(from: metadata, isDownloaded: true)
                completionHandler(updatedItem, [], false, nil)
            } catch {
                completionHandler(nil, [], false, error)
            }
        }

        return progress
    }

    public func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)

        Task {
            do {
                let adapter = try await self.adapterForDomain()

                let remotePath = self.resolveRemotePath(for: identifier)
                try await adapter.delete(remotePath: remotePath)
                try? self.cacheEngine.evict(itemIdentifier: identifier.rawValue)
                self.metadataStore.markDeleted(domainIdentifier: self.domain.identifier.rawValue, itemIdentifier: identifier.rawValue)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }

        return progress
    }

    public func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        let profileID = try profileIdentifier()

        let remotePath = resolveRemotePath(for: containerItemIdentifier)

        return FileProviderEnumerator(
            containerItemIdentifier: containerItemIdentifier,
            remotePath: remotePath,
            profileID: profileID,
            connectionManager: connectionManager,
            cacheEngine: cacheEngine,
            metadataStore: metadataStore,
            domainIdentifier: domain.identifier.rawValue
        )
    }

    private func profileIdentifier() throws -> UUID {
        guard let profileID = UUID(uuidString: domain.identifier.rawValue) else {
            throw AdapterError.invalidPath("File Provider domain identifier is not a profile UUID: \(domain.identifier.rawValue)")
        }
        return profileID
    }

    private func adapterForDomain() async throws -> RemoteFilesystemAdapter {
        try await connectionManager.connect(to: try profileIdentifier())
    }

    private func resolveRemotePath(for identifier: NSFileProviderItemIdentifier) -> String {
        if identifier == .rootContainer { return rootRemotePath() }
        if let metadata = metadataStore.item(for: identifier.rawValue, domainIdentifier: domain.identifier.rawValue), !metadata.isDeleted {
            return metadata.remotePath
        }
        if let data = Data(base64Encoded: identifier.rawValue), let path = String(data: data, encoding: .utf8) {
            return path
        }
        return appendPath(rootRemotePath(), identifier.rawValue)
    }

    private func rootRemotePath() -> String {
        connectionManager.profile(for: (try? profileIdentifier()) ?? UUID())?.remoteRootPath ?? "/"
    }

    private func appendPath(_ parent: String, _ child: String) -> String {
        let cleanParent = parent.isEmpty ? "/" : parent
        if cleanParent == "/" { return "/" + child.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        return cleanParent.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/", omittingEmptySubsequences: true)
            .reduce(into: "/") { result, component in
                if result != "/" { result += "/" }
                result += component
            } + "/" + child.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
