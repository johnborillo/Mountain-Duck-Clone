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
        self.cacheEngine.setOperationCompletionHandler { [weak self] operation in
            self?.reconcileCompletedOperation(operation)
        }
    }

    public func invalidate() {
        cacheEngine.stopRetryScheduler()
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
                completionHandler(nil, FileProviderErrorMapper.map(error))
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
                completionHandler(nil, nil, FileProviderErrorMapper.map(error))
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
                let isDir = itemTemplate.contentType == .folder
                let remotePath = self.appendPath(self.resolveRemotePath(for: itemTemplate.parentItemIdentifier), itemTemplate.filename)
                let fileSize: Int64 = {
                    guard let url else { return 0 }
                    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                    return (attributes?[.size] as? Int64) ?? 0
                }()
                let provisionalEntry = RemoteFileEntry(
                    name: itemTemplate.filename,
                    path: remotePath,
                    itemType: isDir ? .directory : .file,
                    size: fileSize
                )
                let provisional = self.metadataStore.upsert(
                    domainIdentifier: self.domain.identifier.rawValue,
                    parentItemIdentifier: itemTemplate.parentItemIdentifier.rawValue,
                    entry: provisionalEntry
                )

                if isDir {
                    self.cacheEngine.enqueue(JournalEntry(
                        action: .createDirectory,
                        itemIdentifier: provisional.itemIdentifier,
                        remotePath: remotePath
                    ))
                } else if let localURL = url {
                    try self.cacheEngine.enqueueUpload(
                        itemIdentifier: provisional.itemIdentifier,
                        remotePath: remotePath,
                        sourceURL: localURL
                    )
                } else {
                    throw AdapterError.invalidPath("File Provider create for '\(itemTemplate.filename)' did not include file contents.")
                }

                let adapter = try await self.adapterForDomain()

                if isDir {
                    do {
                        try await adapter.createDirectory(path: remotePath)
                    } catch let error {
                        if let adapterError = error as? AdapterError, case .alreadyExists = adapterError {
                            // Finder may retry a create after a response was lost.
                        } else {
                            throw error
                        }
                    }
                } else {
                    await self.transferQueue.acquire()
                    defer { Task { await self.transferQueue.release() } }
                    try await adapter.upload(from: self.cacheEngine.fileURL(for: provisional.itemIdentifier), to: remotePath, progress: progress)
                }

                let entry = try await adapter.stat(path: remotePath)
                let metadata = self.metadataStore.upsert(
                    domainIdentifier: self.domain.identifier.rawValue,
                    parentItemIdentifier: itemTemplate.parentItemIdentifier.rawValue,
                    entry: entry
                )
                self.cacheEngine.markClean(itemIdentifier: provisional.itemIdentifier, remotePath: remotePath)
                let newItem = FileProviderItem(from: metadata, isDownloaded: isDir || url != nil)
                completionHandler(newItem, fields, false, nil)
            } catch {
                completionHandler(nil, [], false, FileProviderErrorMapper.map(error))
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
                guard let existing = self.metadataStore.item(for: item.itemIdentifier.rawValue, domainIdentifier: self.domain.identifier.rawValue) else {
                    throw AdapterError.fileNotFound(item.itemIdentifier.rawValue)
                }
                var remotePath = existing.remotePath
                let hasMove = changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier)
                var destinationPath: String?

                if hasMove {
                    let destinationParent = self.resolveRemotePath(for: item.parentItemIdentifier)
                    let targetPath = self.appendPath(destinationParent, item.filename)
                    if let conflicting = self.metadataStore.item(forRemotePath: targetPath, domainIdentifier: self.domain.identifier.rawValue), conflicting.itemIdentifier != item.itemIdentifier.rawValue, !conflicting.isDeleted {
                        throw AdapterError.alreadyExists(targetPath)
                    }
                    destinationPath = targetPath
                    self.cacheEngine.enqueue(JournalEntry(
                        action: .move,
                        itemIdentifier: item.itemIdentifier.rawValue,
                        remotePath: existing.remotePath,
                        destinationRemotePath: targetPath
                    ))
                }

                if let fileURL = newContents {
                    try self.cacheEngine.enqueueUpload(
                        itemIdentifier: item.itemIdentifier.rawValue,
                        remotePath: destinationPath ?? existing.remotePath,
                        sourceURL: fileURL
                    )
                }

                let adapter = try await self.adapterForDomain()
                let currentRemote = try await adapter.stat(path: existing.remotePath)
                let requestedContentVersion = String(data: baseVersion.contentVersion, encoding: .utf8)
                if let requestedContentVersion, !requestedContentVersion.isEmpty, requestedContentVersion != currentRemote.contentVersion {
                    let conflict = DomainConflict(
                        domainIdentifier: self.domain.identifier.rawValue,
                        itemIdentifier: item.itemIdentifier.rawValue,
                        remotePath: existing.remotePath,
                        localVersion: requestedContentVersion,
                        remoteVersion: currentRemote.contentVersion
                    )
                    self.metadataStore.recordConflict(conflict)
                    self.cacheEngine.journal.block(itemIdentifier: item.itemIdentifier.rawValue, remotePath: existing.remotePath)
                    throw AdapterError.conflict(localVersion: requestedContentVersion, remoteVersion: currentRemote.contentVersion)
                }

                if let destinationPath {
                    try await adapter.move(from: existing.remotePath, to: destinationPath)
                    self.cacheEngine.markClean(itemIdentifier: item.itemIdentifier.rawValue, remotePath: existing.remotePath)
                    _ = self.metadataStore.move(
                        domainIdentifier: self.domain.identifier.rawValue,
                        itemIdentifier: item.itemIdentifier.rawValue,
                        parentItemIdentifier: item.parentItemIdentifier.rawValue,
                        filename: item.filename,
                        remotePath: destinationPath
                    )
                    remotePath = destinationPath
                }

                if newContents != nil {
                    await self.transferQueue.acquire()
                    defer { Task { await self.transferQueue.release() } }
                    try await adapter.upload(from: self.cacheEngine.fileURL(for: item.itemIdentifier.rawValue), to: remotePath, progress: progress)
                    self.cacheEngine.markClean(itemIdentifier: item.itemIdentifier.rawValue, remotePath: remotePath)
                }

                let updatedEntry = try await adapter.stat(path: remotePath)
                if newContents != nil {
                    let attributes = try? FileManager.default.attributesOfItem(atPath: self.cacheEngine.fileURL(for: item.itemIdentifier.rawValue).path)
                    let localSize = (attributes?[.size] as? Int64) ?? 0
                    guard localSize == updatedEntry.size else {
                        throw AdapterError.networkError("Remote upload size mismatch for '\(remotePath)': \(updatedEntry.size) != \(localSize).")
                    }
                }
                let metadata = self.metadataStore.upsert(
                    domainIdentifier: self.domain.identifier.rawValue,
                    parentItemIdentifier: item.parentItemIdentifier.rawValue,
                    entry: updatedEntry,
                    itemIdentifier: item.itemIdentifier.rawValue
                )
                let updatedItem = FileProviderItem(from: metadata, isDownloaded: true)
                completionHandler(updatedItem, [], false, nil)
            } catch {
                completionHandler(nil, [], false, FileProviderErrorMapper.map(error))
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
            let journalEntry = JournalEntry(
                action: .delete,
                itemIdentifier: identifier.rawValue,
                remotePath: self.resolveRemotePath(for: identifier)
            )
            do {
                let remotePath = journalEntry.remotePath
                // Persist first so an offline delete survives Finder callback
                // teardown; if the server is reachable, protect against deleting
                // a version changed by another client since Finder's base anchor.
                self.cacheEngine.enqueue(journalEntry)
                let adapter = try await self.adapterForDomain()
                if let currentRemote = try? await adapter.stat(path: remotePath) {
                    let requestedVersion = String(data: baseVersion.contentVersion, encoding: .utf8)
                    if let requestedVersion, !requestedVersion.isEmpty, requestedVersion != currentRemote.contentVersion {
                        self.cacheEngine.journal.remove(id: journalEntry.id)
                        let conflict = DomainConflict(
                            domainIdentifier: self.domain.identifier.rawValue,
                            itemIdentifier: identifier.rawValue,
                            remotePath: remotePath,
                            localVersion: requestedVersion,
                            remoteVersion: currentRemote.contentVersion
                        )
                        self.metadataStore.recordConflict(conflict)
                        throw AdapterError.conflict(localVersion: requestedVersion, remoteVersion: currentRemote.contentVersion)
                    }
                }
                do {
                    try await adapter.delete(remotePath: remotePath)
                } catch let error {
                    if let adapterError = error as? AdapterError, case .fileNotFound = adapterError {
                        // A replayed Finder delete is already applied remotely.
                    } else {
                        throw error
                    }
                }
                self.cacheEngine.markClean(itemIdentifier: identifier.rawValue, remotePath: remotePath)
                try? self.cacheEngine.evict(itemIdentifier: identifier.rawValue)
                self.metadataStore.markDeleted(domainIdentifier: self.domain.identifier.rawValue, itemIdentifier: identifier.rawValue)
                completionHandler(nil)
            } catch {
                completionHandler(FileProviderErrorMapper.map(error))
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
        cacheEngine.startRetryScheduler { [weak self] in
            guard let self else { throw AdapterError.notConnected }
            return try await self.connectAdapterForDomain()
        }
        return try await connectAdapterForDomain()
    }

    private func connectAdapterForDomain() async throws -> RemoteFilesystemAdapter {
        try await connectionManager.connect(to: try profileIdentifier())
    }

    private func reconcileCompletedOperation(_ operation: JournalEntry) {
        switch operation.action {
        case .move:
            guard let destination = operation.destinationRemotePath else { break }
            let parentPath = (destination as NSString).deletingLastPathComponent
            let parentIdentifier = metadataStore.item(forRemotePath: parentPath, domainIdentifier: domain.identifier.rawValue)?.itemIdentifier
                ?? NSFileProviderItemIdentifier.rootContainer.rawValue
            let filename = (destination as NSString).lastPathComponent
            _ = metadataStore.move(
                domainIdentifier: domain.identifier.rawValue,
                itemIdentifier: operation.itemIdentifier,
                parentItemIdentifier: parentIdentifier,
                filename: filename,
                remotePath: destination
            )
        case .delete:
            metadataStore.markDeleted(domainIdentifier: domain.identifier.rawValue, itemIdentifier: operation.itemIdentifier)
        case .upload, .createDirectory:
            break
        }

        // Wake Finder immediately after an offline operation is replayed. The
        // next enumeration will stat/reconcile uploads and newly-created folders.
        if let profile = connectionManager.profile(for: (try? profileIdentifier()) ?? UUID()) {
            Task { try? await FileProviderDomainCoordinator.signalWorkingSet(profile: profile) }
        }
    }

    private func resolveRemotePath(for identifier: NSFileProviderItemIdentifier) -> String {
        if identifier == .rootContainer { return rootRemotePath() }
        if identifier == .workingSet { return rootRemotePath() }
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
        RemotePath.normalize(RemotePath.join(parent, child))
    }
}
