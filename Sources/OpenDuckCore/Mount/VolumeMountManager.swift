import Foundation
import Darwin

/// Manages native macOS virtual volumes mounted under `/Volumes/<ProfileName>`.
/// Implements live bidirectional synchronization with strict 5-layer safety safeguards:
/// - Extended attribute (xattr) placeholder tagging (placeholders are never uploaded)
/// - Hard 0-byte overwrite rejection in the upload engine
/// - In-memory placeholder tracking
/// - Automatic atomic staging & verified rename on the remote host
public final class VolumeMountManager: @unchecked Sendable {
    public static let shared = VolumeMountManager()

    private let lock = NSLock()
    private var mountedVolumes: [String: URL] = [:]
    private var populatedDirs: Set<String> = []
    private var selfInitiatedRemovals: Set<String> = [] // Local paths removed intentionally by OpenDuck (eviction, reconcile)
    private var hydratingPaths: Set<String> = [] // Local paths currently being hydrated (download in progress)
    private var activeStreams: [String: FSEventStreamRef] = [:]
    private var activeContexts: [String: WatcherContext] = [:]
    private let baseStorageDir: URL

    public static let placeholderXAttrName = "com.openduck.placeholder"

    public init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("OpenDuck/Volumes")
        self.baseStorageDir = appSupport
        try? FileManager.default.createDirectory(at: baseStorageDir, withIntermediateDirectories: true)
    }

    public func recordSelfInitiatedRemoval(path: String) {
        sync { selfInitiatedRemovals.insert(path) }
        // Persist to SQLite for crash resilience
        MetadataDatabase.shared.recordSelfInitiatedRemoval(localPath: path)
    }

    public func isSelfInitiatedRemoval(path: String) -> Bool {
        // Check in-memory first (fast path), then fall back to persisted tokens
        let inMemory: Bool = sync { selfInitiatedRemovals.remove(path) != nil }
        if inMemory {
            // Also consume the persisted token
            _ = MetadataDatabase.shared.consumeSelfInitiatedRemoval(localPath: path)
            return true
        }
        // Fall back to persisted token (crash recovery scenario)
        return MetadataDatabase.shared.consumeSelfInitiatedRemoval(localPath: path)
    }

    /// Register a path as currently being hydrated (download in progress).
    /// FSEvents writes during hydration should not trigger uploads.
    public func recordHydratingPath(_ path: String) {
        sync { hydratingPaths.insert(path) }
    }

    /// Check and consume a hydrating path token. Returns true if the path was being hydrated.
    public func isHydratingPath(_ path: String) -> Bool {
        sync { hydratingPaths.remove(path) != nil }
    }

    @discardableResult
    private func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Mounts a virtual volume at `/Volumes/<name>`.
    /// - Note: Write access is opt-in (`isReadOnly` defaults to `true`) for remote storage safety.
    public func mount(name: String, sizeGB: Int = 100, isReadOnly: Bool = true) throws -> URL {
        let cleanName = name.replacingOccurrences(of: "/", with: "-")
        try FileManager.default.createDirectory(at: baseStorageDir, withIntermediateDirectories: true)
        let imageURL = baseStorageDir.appendingPathComponent("\(cleanName).dmg.sparseimage")

        // 1. Create sparse image if it does not exist
        if !FileManager.default.fileExists(atPath: imageURL.path) {
            let createProcess = Process()
            createProcess.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            createProcess.arguments = [
                "create",
                "-size", "\(sizeGB)g",
                "-type", "SPARSE",
                "-fs", "APFS",
                "-volname", cleanName,
                baseStorageDir.appendingPathComponent("\(cleanName).dmg").path
            ]
            try createProcess.run()
            createProcess.waitUntilExit()
        }

        // 2. Detach if previously attached
        _ = try? unmount(name: cleanName)

        // 3. Attach image via Disk Arbitration (auto mounts to /Volumes/<cleanName> without root permission)
        let attachProcess = Process()
        attachProcess.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        attachProcess.arguments = [
            "attach",
            "-plist",
            imageURL.path
        ]

        let pipe = Pipe()
        attachProcess.standardOutput = pipe
        try attachProcess.run()
        attachProcess.waitUntilExit()

        var resolvedMountURL = URL(fileURLWithPath: "/Volumes/\(cleanName)")

        // Parse plist output to extract exact mount point
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let entities = plist["system-entities"] as? [[String: Any]] {
            for entity in entities {
                if let mp = entity["mount-point"] as? String, !mp.isEmpty {
                    resolvedMountURL = URL(fileURLWithPath: mp)
                    break
                }
            }
        }

        guard FileManager.default.fileExists(atPath: resolvedMountURL.path) else {
            throw AdapterError.invalidPath("Volume attachment failed: mount point not found at \(resolvedMountURL.path)")
        }

        // Enforce native POSIX read-only lock (dr-xr-xr-x) if mounted in read-only mode
        if isReadOnly {
            try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: resolvedMountURL.path)
        } else {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: resolvedMountURL.path)
        }

        sync {
            mountedVolumes[cleanName] = resolvedMountURL
            populatedDirs.removeAll()
        }

        return resolvedMountURL
    }

    /// Unmounts and detaches the virtual volume.
    public func unmount(name: String) throws {
        let cleanName = name.replacingOccurrences(of: "/", with: "-")
        stopWatching(name: cleanName)

        let detachProcess = Process()
        detachProcess.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        detachProcess.arguments = ["detach", "/Volumes/\(cleanName)", "-force"]
        try detachProcess.run()
        detachProcess.waitUntilExit()

        sync {
            _ = mountedVolumes.removeValue(forKey: cleanName)
            populatedDirs.removeAll()
        }
    }

    public func isMounted(name: String) -> Bool {
        let cleanName = name.replacingOccurrences(of: "/", with: "-")
        return FileManager.default.fileExists(atPath: "/Volumes/\(cleanName)")
    }

    // MARK: - Safe Lazy Directory Population

    /// Performs a single-level listing of a remote directory and creates local stubs.
    /// Placeholders are registered persistently in `MetadataDatabase`.
    /// When forceRefresh is true, synchronizes remote deletions by pruning removed placeholders.
    /// When isReadOnly is true, locks folder and files to native read-only permissions (555 / 444).
    public func populateDirectory(
        adapter: RemoteFilesystemAdapter,
        remotePath: String,
        localURL: URL,
        cacheEngine: CacheEngine,
        forceRefresh: Bool = false,
        isReadOnly: Bool = false
    ) async throws -> [RemoteFileEntry] {
        if !forceRefresh {
            let alreadyPopulated: Bool = sync { populatedDirs.contains(remotePath) }
            if alreadyPopulated { return [] }
        }

        // Temporarily unlock folder to write placeholder files
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: localURL.path)
        try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)

        // A listing failure is never proof that a directory was created locally.
        // Treating authentication, permission, or transport errors as an empty
        // directory made mounts look healthy while silently diverging from SFTP.
        let remoteItems = try await adapter.listDirectory(path: remotePath)
        let remoteNames = Set(remoteItems.map { $0.name })
        let volumeName = localURL.pathComponents.count > 2 ? localURL.pathComponents[2] : "OpenDuck"

        // 1. Reconcile Remote -> Local: Add new remote items or placeholders
        for item in remoteItems {
            let localItemURL = localURL.appendingPathComponent(item.name)
            _ = cacheEngine.registerPlaceholder(for: item)

            if item.isDirectory {
                try? FileManager.default.createDirectory(at: localItemURL, withIntermediateDirectories: true)
                if isReadOnly {
                    try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: localItemURL.path)
                }
            } else {
                if !FileManager.default.fileExists(atPath: localItemURL.path) {
                    FileManager.default.createFile(atPath: localItemURL.path, contents: nil)
                    if item.size > 0 {
                        if let handle = try? FileHandle(forWritingTo: localItemURL) {
                            try? handle.truncate(atOffset: UInt64(item.size))
                            try? handle.close()
                        }
                    }
                    Self.setPlaceholderXAttr(path: localItemURL.path)
                    MetadataDatabase.shared.markPlaceholder(
                        localPath: localItemURL.path,
                        remotePath: item.path,
                        volumeName: volumeName,
                        fileName: item.name,
                        size: item.size,
                        remoteMtime: item.modificationDate
                    )
                }
                if isReadOnly {
                    try? FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: localItemURL.path)
                }
            }
        }

        // 2. Reconcile Remote -> Local Deletions:
        // If a file exists locally (as placeholder or clean cached file) but no longer exists remotely (e.g. deleted on Cyberduck),
        // remove it locally so Finder reflects the remote state accurately.
        if let existingLocalFiles = try? FileManager.default.contentsOfDirectory(atPath: localURL.path) {
            for localFilename in existingLocalFiles {
                if localFilename == ".DS_Store" || localFilename.hasPrefix("._") || localFilename == ".Trashes" || localFilename == ".Trash" || localFilename.hasPrefix(".~") {
                    continue
                }
                if !remoteNames.contains(localFilename) {
                    let localItemURL = localURL.appendingPathComponent(localFilename)
                    let fileRemotePath = remotePath == "/" ? "/\(localFilename)" : "\(remotePath)/\(localFilename)"
                    let itemId = cacheEngine.itemIdentifier(for: fileRemotePath)
                    let isDirty = cacheEngine.entry(for: itemId)?.isDirty ?? false

                    if !isDirty {
                        recordSelfInitiatedRemoval(path: localItemURL.path)
                        try? FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: localItemURL.path)
                        try? FileManager.default.removeItem(at: localItemURL)
                        MetadataDatabase.shared.deleteRecord(localPath: localItemURL.path)
                        try? cacheEngine.evict(itemIdentifier: itemId)
                    }
                }
            }
        }

        // Lock the folder permissions natively (dr-xr-xr-x) in Read-Only mode so Finder blocks drops/pastes/edits
        if isReadOnly {
            try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: localURL.path)
        }

        sync { populatedDirs.insert(remotePath) }

        // Background progressive hydration: stream down real binary file data in bounded parallel task group
        Task.detached(priority: .utility) { [weak self, weak cacheEngine] in
            guard let self = self, let cacheEngine = cacheEngine else { return }
            let placeholders = remoteItems.filter { !$0.isDirectory }

            // Bounded parallel hydration: stream up to 3 files concurrently
            await withTaskGroup(of: Void.self) { group in
                var inFlight = 0
                let maxConcurrentHydrations = 3

                for item in placeholders {
                    let localItemURL = localURL.appendingPathComponent(item.name)
                    guard self.isPlaceholder(path: localItemURL.path) else { continue }

                    group.addTask {
                        try? await self.hydrateFile(
                            localPath: localItemURL.path,
                            remotePath: item.path,
                            adapter: adapter,
                            cacheEngine: cacheEngine,
                            isReadOnly: isReadOnly
                        )
                    }
                    inFlight += 1

                    if inFlight >= maxConcurrentHydrations {
                        await group.next()
                        inFlight -= 1
                    }
                }
                await group.waitForAll()
            }
        }

        return remoteItems
    }

    public func isPopulated(remotePath: String) -> Bool {
        sync { populatedDirs.contains(remotePath) }
    }

    public func isPlaceholder(path: String) -> Bool {
        return MetadataDatabase.shared.isPlaceholder(localPath: path)
    }

    public func removePlaceholder(path: String) {
        MetadataDatabase.shared.markMaterialized(localPath: path)
        Self.removePlaceholderXAttr(path: path)
    }

    public func markPopulated(remotePath: String) {
        sync { populatedDirs.insert(remotePath) }
    }

    public func invalidateDirectory(remotePath: String) {
        sync { populatedDirs.remove(remotePath) }
    }

    /// Synchronizes all currently populated directories in the volume, fetching new items and pruning remote deletions.
    public func syncAllPopulatedDirectories(
        adapter: RemoteFilesystemAdapter,
        rootRemotePath: String,
        volumeURL: URL,
        cacheEngine: CacheEngine,
        isReadOnly: Bool = false
    ) async throws {
        let currentDirs: [String] = sync { Array(populatedDirs) }
        let dirsToSync = Set([rootRemotePath] + currentDirs)

        for dirRemotePath in dirsToSync {
            var relPath = dirRemotePath
            if rootRemotePath != "/" && relPath.hasPrefix(rootRemotePath) {
                relPath = String(relPath.dropFirst(rootRemotePath.count))
            }
            if relPath.hasPrefix("/") { relPath = String(relPath.dropFirst()) }
            let localURL = relPath.isEmpty ? volumeURL : volumeURL.appendingPathComponent(relPath)

            if FileManager.default.fileExists(atPath: localURL.path) {
                _ = try await populateDirectory(
                    adapter: adapter,
                    remotePath: dirRemotePath,
                    localURL: localURL,
                    cacheEngine: cacheEngine,
                    forceRefresh: true,
                    isReadOnly: isReadOnly
                )
            }
        }
    }

    /// Hydrates a remote placeholder file with its full binary content.
    public func hydrateFile(
        localPath: String,
        remotePath: String,
        adapter: RemoteFilesystemAdapter,
        cacheEngine: CacheEngine,
        isReadOnly: Bool = false
    ) async throws {
        let localURL = URL(fileURLWithPath: localPath)
        // Register this path as being hydrated so FSEvents doesn't misclassify
        // the download write as a user edit that needs uploading back.
        recordHydratingPath(localPath)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: localURL.path)
        do {
            try await adapter.download(remotePath: remotePath, to: localURL, progress: nil)
        } catch {
            // Clear hydrating state on failure so path isn't permanently suppressed
            _ = isHydratingPath(localPath)
            throw error
        }
        Self.removePlaceholderXAttr(path: localPath)
        removePlaceholder(path: localPath)
        if isReadOnly {
            try? FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: localURL.path)
        }
        let itemId = cacheEngine.itemIdentifier(for: remotePath)
        cacheEngine.markClean(itemIdentifier: itemId, remotePath: remotePath)
    }

    // MARK: - Extended Attribute (xattr) Helpers

    public static func setPlaceholderXAttr(path: String) {
        let value = "1"
        _ = value.withCString { valPtr in
            setxattr(path, placeholderXAttrName, valPtr, strlen(valPtr), 0, 0)
        }
    }

    public static func isPlaceholderXAttr(path: String) -> Bool {
        let size = getxattr(path, placeholderXAttrName, nil, 0, 0, 0)
        return size > 0
    }

    public static func removePlaceholderXAttr(path: String) {
        _ = removexattr(path, placeholderXAttrName, 0)
    }

    // MARK: - Bidirectional FSEvents Watcher

    /// Starts real-time observation of file system events within `/Volumes/<name>`.
    public func startWatching(
        name: String,
        volumeURL: URL,
        remoteRootPath: String,
        adapter: RemoteFilesystemAdapter,
        cacheEngine: CacheEngine,
        isReadOnly: Bool = false,
        onStatusChange: (@Sendable (String) -> Void)? = nil,
        onTransferUpdate: (@Sendable (TransferProgress) -> Void)? = nil
    ) {
        let cleanName = name.replacingOccurrences(of: "/", with: "-")
        stopWatching(name: cleanName)

        let context = WatcherContext(
            volumeURL: volumeURL,
            remoteRootPath: remoteRootPath,
            adapter: adapter,
            cacheEngine: cacheEngine,
            manager: self,
            isReadOnly: isReadOnly,
            onStatusChange: onStatusChange,
            onTransferUpdate: onTransferUpdate
        )
        let contextPtr = Unmanaged.passRetained(context).toOpaque()

        var streamContext = FSEventStreamContext(
            version: 0,
            info: contextPtr,
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let pathsToWatch = [volumeURL.path] as CFArray
        let stream = FSEventStreamCreate(
            nil,
            fsEventsCallback,
            &streamContext,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        )!

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)

        sync {
            activeStreams[cleanName] = stream
            activeContexts[cleanName] = context
        }
    }

    public func stopWatching(name: String) {
        let cleanName = name.replacingOccurrences(of: "/", with: "-")
        let context: WatcherContext? = sync { activeContexts.removeValue(forKey: cleanName) }
        let stream: FSEventStreamRef? = sync { activeStreams.removeValue(forKey: cleanName) }

        context?.invalidate()

        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    public func resetCircuitBreaker(name: String) {
        let cleanName = name.replacingOccurrences(of: "/", with: "-")
        sync { activeContexts[cleanName]?.resetCircuitBreaker() }
    }

    public func isCircuitBreakerTripped(name: String) -> Bool {
        let cleanName = name.replacingOccurrences(of: "/", with: "-")
        return sync { activeContexts[cleanName]?.isCircuitBreakerTripped ?? false }
    }

    /// Cancels any active in-flight transfer for the given remote path and optionally deletes the local item.
    public func cancelTransfer(remotePath: String, localURL: URL? = nil, deleteLocal: Bool = false) {
        let contexts: [WatcherContext] = sync { Array(activeContexts.values) }
        for ctx in contexts {
            ctx.cancelTransfer(remotePath: remotePath, localURL: localURL, deleteLocal: deleteLocal)
        }
    }
}

// MARK: - Transfer Queue & Concurrency Control

/// Actor controlling maximum concurrent active file transfers to prevent socket exhaustion and TCP congestion collapse.
// AsyncTransferQueue is now defined in Concurrency/AsyncTransferQueue.swift

// MARK: - Watcher Context & Safe Event Dispatcher

public final class WatcherContext: @unchecked Sendable {
    public let volumeURL: URL
    public let remoteRootPath: String
    public let adapter: RemoteFilesystemAdapter
    public let cacheEngine: CacheEngine
    public let manager: VolumeMountManager
    public let isReadOnly: Bool
    public let onStatusChange: (@Sendable (String) -> Void)?
    public let onTransferUpdate: (@Sendable (TransferProgress) -> Void)?

    private var pendingPaths = Set<String>()
    private var syncDebounceWorkItems: [String: DispatchWorkItem] = [:]
    private var activeUploadTasks: [String: Task<Void, Never>] = [:]
    private var activeTrackers: [String: TransferTracker] = [:]
    private var deletionTimestamps: [Date] = []
    public private(set) var isCircuitBreakerTripped: Bool = false
    private var isStopped: Bool = false
    private let transferQueue = AsyncTransferQueue(maxConcurrent: 4)
    private let lock = NSLock()

    /// A path that disappeared via ItemRenamed, awaiting a matching arrival.
    private struct PendingDeparture {
        let localPath: String
        let remotePath: String
        let isDir: Bool
        let size: Int64          // -1 for directories (can't stat a departed dir)
        let mtime: Date?         // nil for directories
        let at: Date
    }
    private var pendingDepartures: [PendingDeparture] = []
    private var pendingArrivalWork: [String: DispatchWorkItem] = [:]
    /// How long to wait for the other half of a rename pair.
    private let renameCorrelationWindow: TimeInterval = 2.0

    public func invalidate() {
        lock.lock()
        isStopped = true
        for (_, item) in syncDebounceWorkItems {
            item.cancel()
        }
        syncDebounceWorkItems.removeAll()
        for (_, item) in pendingArrivalWork {
            item.cancel()
        }
        pendingArrivalWork.removeAll()
        pendingDepartures.removeAll()
        for (_, task) in activeUploadTasks {
            task.cancel()
        }
        activeUploadTasks.removeAll()
        activeTrackers.removeAll()
        lock.unlock()
    }

    public func cancelTransfer(remotePath: String, localURL: URL? = nil, deleteLocal: Bool = false) {
        lock.lock()
        syncDebounceWorkItems[remotePath]?.cancel()
        syncDebounceWorkItems.removeValue(forKey: remotePath)
        let task = activeUploadTasks.removeValue(forKey: remotePath)
        let tracker = activeTrackers.removeValue(forKey: remotePath)
        lock.unlock()

        task?.cancel()
        if let tracker = tracker {
            tracker.markFailed(error: AdapterError.unsupportedOperation("Transfer cancelled by user"))
        }

        if deleteLocal {
            let targetURL = localURL ?? tracker?.localURL
            if let targetURL = targetURL {
                manager.recordSelfInitiatedRemoval(path: targetURL.path)
                try? FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: targetURL.path)
                try? FileManager.default.removeItem(at: targetURL)
                let itemId = cacheEngine.itemIdentifier(for: remotePath)
                try? cacheEngine.evict(itemIdentifier: itemId)
                MetadataDatabase.shared.deleteRecord(localPath: targetURL.path)
                manager.removePlaceholder(path: targetURL.path)
                onStatusChange?("✓ Deleted local file and cancelled transfer: \(targetURL.lastPathComponent)")
            }
        } else {
            onStatusChange?("🛑 Cancelled upload for: \((remotePath as NSString).lastPathComponent)")
        }
    }

    public init(
        volumeURL: URL,
        remoteRootPath: String,
        adapter: RemoteFilesystemAdapter,
        cacheEngine: CacheEngine,
        manager: VolumeMountManager,
        isReadOnly: Bool = false,
        onStatusChange: (@Sendable (String) -> Void)? = nil,
        onTransferUpdate: (@Sendable (TransferProgress) -> Void)? = nil
    ) {
        self.volumeURL = volumeURL
        self.remoteRootPath = remoteRootPath
        self.adapter = adapter
        self.cacheEngine = cacheEngine
        self.manager = manager
        self.isReadOnly = isReadOnly
        self.onStatusChange = onStatusChange
        self.onTransferUpdate = onTransferUpdate
    }

    public func resetCircuitBreaker() {
        lock.lock()
        isCircuitBreakerTripped = false
        deletionTimestamps.removeAll()
        lock.unlock()
        onStatusChange?("✓ Safety circuit breaker reset.")
    }

    private func recordAndCheckCircuitBreaker() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if isCircuitBreakerTripped { return false }

        let now = Date()
        // Retain timestamps from the last 60 seconds for dual-window rate monitoring
        deletionTimestamps = deletionTimestamps.filter { now.timeIntervalSince($0) < 60.0 }
        deletionTimestamps.append(now)

        let burstDeletions = deletionTimestamps.filter { now.timeIntervalSince($0) < 1.0 }.count
        let sustainedDeletions = deletionTimestamps.count

        if burstDeletions > 10 || sustainedDeletions > 50 {
            isCircuitBreakerTripped = true
            let reason = burstDeletions > 10
                ? "Burst mass deletion (>10 files/sec) paused remote operations."
                : "Sustained mass deletion (>50 files/60sec) paused remote operations."
            MetadataDatabase.shared.recordDivergenceEvent(
                volumeName: volumeURL.lastPathComponent,
                path: "MASS_DELETION_BREAKER",
                reason: "\(reason) Remote storage protected."
            )
            self.onStatusChange?("⚠️ SAFETY CIRCUIT BREAKER TRIPPED: \(reason) Remote storage protected.")
            return false
        }
        return true
    }

    // MARK: - Rename & Move Correlation

    public func handleRenameEvent(
        localPath: String,
        remotePath: String,
        isDir: Bool,
        exists: Bool
    ) {
        if isReadOnly { return }
        if isDir {
            MetadataDatabase.shared.recordDivergenceEvent(
                volumeName: volumeURL.lastPathComponent,
                path: remotePath,
                reason: "Legacy mount directory rename/move is disabled until File Provider migration. Remote data was left unchanged."
            )
            onStatusChange?("⚠️ Folder move is not synced in Legacy Preview; remote data was preserved.")
            return
        }
        if lock.withLock({ isStopped }) { return }
        // Our own moves (staging renames, eviction) must never round-trip.
        if manager.isSelfInitiatedRemoval(path: localPath) { return }
        if !exists {
            recordDeparture(localPath: localPath, remotePath: remotePath, isDir: isDir)
        } else {
            handleArrival(localPath: localPath, remotePath: remotePath, isDir: isDir)
        }
    }

    private func recordDeparture(localPath: String, remotePath: String, isDir: Bool) {
        // Capture identity from the DB — the file is already gone from disk, so the
        // record is the only place its size and mtime still exist.
        let record = MetadataDatabase.shared.record(forLocalPath: localPath)
        let departure = PendingDeparture(
            localPath: localPath,
            remotePath: remotePath,
            isDir: isDir,
            size: isDir ? -1 : (record?.size ?? -1),
            mtime: isDir ? nil : record?.localMtime,
            at: Date()
        )
        lock.withLock { pendingDepartures.append(departure) }
        // Timeout: an unmatched departure is NOT treated as a delete.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let stillPending: Bool = self.lock.withLock {
                guard let idx = self.pendingDepartures.firstIndex(where: { $0.localPath == localPath }) else {
                    return false
                }
                self.pendingDepartures.remove(at: idx)
                self.pendingArrivalWork.removeValue(forKey: localPath)
                return true
            }
            guard stillPending else { return }
            // Deliberate policy: a move out of the watched tree, or a rename we failed to
            // pair, leaves a stale remote copy rather than risking a wrong delete. Stale
            // data is recoverable; a wrongly inferred delete is not.
            MetadataDatabase.shared.recordDivergenceEvent(
                volumeName: self.volumeURL.lastPathComponent,
                path: remotePath,
                reason: "Unmatched rename departure — remote copy left in place for manual review."
            )
            self.onStatusChange?("⚠️ Moved out of view: \((localPath as NSString).lastPathComponent) — remote copy kept.")
        }
        lock.withLock { pendingArrivalWork[localPath] = work }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + renameCorrelationWindow,
            execute: work
        )
    }

    private func handleArrival(localPath: String, remotePath: String, isDir: Bool) {
        let matched: PendingDeparture? = lock.withLock {
            guard let idx = matchIndex(for: localPath, isDir: isDir) else { return nil }
            let dep = pendingDepartures.remove(at: idx)
            pendingArrivalWork.removeValue(forKey: dep.localPath)?.cancel()
            return dep
        }
        guard let departure = matched else {
            // No pair — a genuine arrival from outside the volume. Let the normal
            // create/upload path own it.
            handleEvent(localPath: localPath, flags: UInt32(kFSEventStreamEventFlagItemCreated)
                                                  | (isDir ? UInt32(kFSEventStreamEventFlagItemIsDir) : 0))
            return
        }
        performRemoteMove(from: departure, toLocal: localPath, toRemote: remotePath, isDir: isDir)
    }

    /// Pair an arrival with a departure.
    ///
    /// Files match on (size, mtime) from the DB record — reliable in practice, since a move
    /// preserves both. Directories can't be stat'd after departure, so they match on basename
    /// alone within the window. That's the strongest signal the API makes available.
    private func matchIndex(for localPath: String, isDir: Bool) -> Int? {
        let name = (localPath as NSString).lastPathComponent
        let now = Date()
        let candidates = pendingDepartures.enumerated().filter { _, dep in
            dep.isDir == isDir
                && now.timeIntervalSince(dep.at) < renameCorrelationWindow
        }
        if isDir {
            return candidates.first { _, dep in
                (dep.localPath as NSString).lastPathComponent == name
            }?.offset
        }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: localPath),
              let sizeNumber = attrs[.size] as? NSNumber else {
            // Can't stat the arrival; fall back to basename.
            return candidates.first { _, dep in
                (dep.localPath as NSString).lastPathComponent == name
            }?.offset
        }
        let size = sizeNumber.int64Value
        // Prefer exact (size, mtime); accept size + basename; then basename alone.
        let mtime = attrs[.modificationDate] as? Date
        if let m = mtime,
           let hit = candidates.first(where: { _, dep in
               dep.size == size && dep.mtime.map { abs($0.timeIntervalSince(m)) < 2.0 } == true
           }) {
            return hit.offset
        }
        if let hit = candidates.first(where: { _, dep in
            dep.size == size && (dep.localPath as NSString).lastPathComponent == name
        }) {
            return hit.offset
        }
        return candidates.first { _, dep in
            (dep.localPath as NSString).lastPathComponent == name
        }?.offset
    }

    private func performRemoteMove(
        from departure: PendingDeparture,
        toLocal newLocalPath: String,
        toRemote newRemotePath: String,
        isDir: Bool
    ) {
        let oldRemote = departure.remotePath
        let oldLocal = departure.localPath
        Task {
            do {
                try await self.adapter.move(from: oldRemote, to: newRemotePath)
                // Rekey the DB for the item and, if a directory, every descendant.
                // Without this the whole moved subtree keeps stale local/remote paths
                // and becomes invisible to the uploader.
                MetadataDatabase.shared.rekeyPathPrefix(
                    oldLocalPrefix: oldLocal,
                    newLocalPrefix: newLocalPath,
                    oldRemotePrefix: oldRemote,
                    newRemotePrefix: newRemotePath
                )
                // Both parents' cached listings are now wrong.
                self.manager.invalidateDirectory(remotePath: (oldRemote as NSString).deletingLastPathComponent)
                self.manager.invalidateDirectory(remotePath: (newRemotePath as NSString).deletingLastPathComponent)
                if isDir {
                    self.manager.invalidateDirectory(remotePath: oldRemote)
                    self.manager.markPopulated(remotePath: newRemotePath)
                }
                self.onStatusChange?("✓ Moved \((newLocalPath as NSString).lastPathComponent) on server")
            } catch {
                // Server-side move failed. Do NOT fall back to copy-then-delete —
                // that's the duplication behaviour this whole change exists to fix.
                MetadataDatabase.shared.recordDivergenceEvent(
                    volumeName: self.volumeURL.lastPathComponent,
                    path: newRemotePath,
                    reason: "Remote move \(oldRemote) → \(newRemotePath) failed: \(error). Local and remote now differ."
                )
                self.onStatusChange?("❌ Move failed on server: \((newLocalPath as NSString).lastPathComponent) — see divergence log")
            }
        }
    }

    public func handleEvent(localPath: String, flags: UInt32) {
        let stopped: Bool = lock.withLock { isStopped }
        guard !stopped else { return }

        let volumePath = volumeURL.path
        guard localPath.hasPrefix(volumePath) else { return }

        let filename = (localPath as NSString).lastPathComponent

        // Ignore macOS system, metadata, swap files, atomic temp files, internal staging files, and Trash folders
        if filename == ".DS_Store" ||
           filename.hasPrefix("._") ||
           filename.hasPrefix(".openduck") ||
           filename.contains(".openduck_") ||
           filename.contains("openduck_dl_") ||
           filename == ".Spotlight-V100" ||
           filename.hasPrefix(".Trash") ||
           localPath.contains("/.Trashes") ||
           localPath.contains("/.Trash") ||
           filename.contains(".nosync") ||
           filename.contains(".sb-") ||
           filename == ".fseventsd" ||
           filename.hasSuffix(".tmp") ||
           filename.hasPrefix(".~") {
            return
        }

        var relativePath = String(localPath.dropFirst(volumePath.count))
        if relativePath.isEmpty { relativePath = "/" }
        if !relativePath.hasPrefix("/") { relativePath = "/" + relativePath }

        let remotePath: String
        if remoteRootPath == "/" {
            remotePath = relativePath
        } else if relativePath == "/" {
            remotePath = remoteRootPath
        } else {
            remotePath = remoteRootPath + relativePath
        }

        let isDir     = (flags & UInt32(kFSEventStreamEventFlagItemIsDir))    != 0
        let isRemoved = (flags & UInt32(kFSEventStreamEventFlagItemRemoved))  != 0
        let isRenamed = (flags & UInt32(kFSEventStreamEventFlagItemRenamed))  != 0
        let localURL  = URL(fileURLWithPath: localPath)
        let fileExists = FileManager.default.fileExists(atPath: localPath)

        // Renames are their own thing: FSEvents fires ItemRenamed twice (old path, new path)
        // with no correlation ID and neither carrying ItemRemoved. Must be handled before the
        // isDir / isRemoved branches, which would otherwise silently drop the departure half.
        if isRenamed && !isRemoved {
            handleRenameEvent(
                localPath: localPath,
                remotePath: remotePath,
                isDir: isDir,
                exists: fileExists
            )
            return
        }

        // Case 1: Directory Access / Creation / Deletion
        if isDir {
            if fileExists {
                // If directory is unpopulated, fetch remote listing
                if !manager.isPopulated(remotePath: remotePath) {
                    let shouldProcess: Bool = lock.withLock {
                        if pendingPaths.contains(remotePath) { return false }
                        pendingPaths.insert(remotePath)
                        return true
                    }
                    guard shouldProcess else { return }

                    Task {
                        defer { self.lock.withLock { _ = self.pendingPaths.remove(remotePath) } }
                        do {
                            _ = try await self.adapter.stat(path: remotePath)
                            _ = try await self.manager.populateDirectory(
                                adapter: self.adapter,
                                remotePath: remotePath,
                                localURL: localURL,
                                cacheEngine: self.cacheEngine,
                                isReadOnly: self.isReadOnly
                            )
                        } catch let error as AdapterError {
                            guard case .fileNotFound = error else {
                                self.onStatusChange?("⚠️ Cannot access folder \(filename): \(error.localizedDescription)")
                                return
                            }
                            do {
                                try await self.adapter.createDirectory(path: remotePath)
                                self.manager.markPopulated(remotePath: remotePath)
                                self.onStatusChange?("✓ Created folder \(filename)")
                            } catch {
                                self.cacheEngine.journal.append(JournalEntry(
                                    action: .createDirectory,
                                    itemIdentifier: self.cacheEngine.itemIdentifier(for: remotePath),
                                    remotePath: remotePath
                                ))
                                self.onStatusChange?("⚠️ Folder creation queued: \(filename)")
                            }
                        } catch {
                            self.onStatusChange?("⚠️ Cannot access folder \(filename): \(error.localizedDescription)")
                            return
                        }
                    }
                }
            } else if isRemoved {
                if isReadOnly { return }

                // PROVENANCE GUARD: Check if OpenDuck initiated this removal
                if manager.isSelfInitiatedRemoval(path: localPath) {
                    return
                }

                MetadataDatabase.shared.recordDivergenceEvent(
                    volumeName: volumeURL.lastPathComponent,
                    path: remotePath,
                    reason: "Legacy mount directory deletion is disabled to prevent unbounded recursive remote deletion."
                )
                self.onStatusChange?("⚠️ Folder deletion is not synced in Legacy Preview; remote data was preserved.")
            }
            return
        }

        // =====================================================================
        // SAFEGUARD LAYER 3 & 4: PLACEHOLDER SHIELD & ON-DEMAND HYDRATION
        // Check in-memory index FIRST (O(1) RAM lookup) before disk syscall
        // =====================================================================
        if manager.isPlaceholder(path: localPath) || VolumeMountManager.isPlaceholderXAttr(path: localPath) {
            Task {
                try? await self.manager.hydrateFile(
                    localPath: localPath,
                    remotePath: remotePath,
                    adapter: self.adapter,
                    cacheEngine: self.cacheEngine,
                    isReadOnly: self.isReadOnly
                )
            }
            return
        }

        // Case 2: User File Creation or Modification -> Push to Remote SFTP Server
        if fileExists {
            if isReadOnly {
                return
            }

            // HYDRATION LOOP GUARD: If this file was just hydrated (downloaded from remote),
            // the write to disk triggers an FSEvent. Suppress the upload to prevent a loop.
            if manager.isHydratingPath(localPath) {
                return
            }

            guard let attrs = try? FileManager.default.attributesOfItem(atPath: localPath),
                  let fileSize = attrs[.size] as? Int64 else {
                return
            }

            // SAFEGUARD LAYER 5: Never automatically upload placeholder stub files (0-byte with xattr).
            // Genuine empty files (e.g. .gitkeep, __init__.py) are allowed through.
            if fileSize == 0 && VolumeMountManager.isPlaceholderXAttr(path: localPath) {
                return
            }

            // Register in CacheEngine
            let entry = RemoteFileEntry(
                name: filename,
                path: remotePath,
                itemType: .file,
                size: fileSize,
                modificationDate: (attrs[.modificationDate] as? Date) ?? Date()
            )
            _ = cacheEngine.registerPlaceholder(for: entry)
            let itemId = cacheEngine.itemIdentifier(for: remotePath)
            cacheEngine.markDirty(itemIdentifier: itemId, newLocalURL: localURL)
            MetadataDatabase.shared.markDirty(localPath: localPath)

            // Debounce upload by 800ms
            lock.lock()
            syncDebounceWorkItems[remotePath]?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                let tracker = TransferTracker(
                    localURL: localURL,
                    remotePath: remotePath,
                    direction: .upload,
                    totalBytes: fileSize,
                    onUpdate: self.onTransferUpdate
                )

                let progress = Progress(totalUnitCount: fileSize)
                let observation = progress.observe(\.completedUnitCount) { p, _ in
                    tracker.update(bytesTransferred: p.completedUnitCount)
                }

                let uploadTask = Task {
                    await self.transferQueue.acquire()
                    defer {
                        Task { await self.transferQueue.release() }
                        self.lock.withLock {
                            self.activeUploadTasks.removeValue(forKey: remotePath)
                            self.activeTrackers.removeValue(forKey: remotePath)
                        }
                        _ = observation
                    }

                    do {
                        try Task.checkCancellation()
                        self.onStatusChange?("Uploading \(filename)...")
                        try await self.adapter.upload(from: localURL, to: remotePath, progress: progress)
                        tracker.markCompleted()
                        self.cacheEngine.markClean(itemIdentifier: itemId, remotePath: remotePath)
                        MetadataDatabase.shared.markClean(localPath: localPath, remoteMtime: Date(), size: fileSize)
                        self.onStatusChange?("✓ Uploaded \(filename)")
                    } catch is CancellationError {
                        tracker.markFailed(error: AdapterError.unsupportedOperation("Upload cancelled"))
                        self.onStatusChange?("🛑 Cancelled upload of \(filename)")
                    } catch {
                        tracker.markFailed(error: error)
                        self.onStatusChange?("🛑 Safety/Upload notice: \(error.localizedDescription)")
                    }
                }

                self.lock.lock()
                self.activeUploadTasks[remotePath] = uploadTask
                self.activeTrackers[remotePath] = tracker
                self.lock.unlock()
            }
            syncDebounceWorkItems[remotePath] = workItem
            lock.unlock()

            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.8, execute: workItem)

        } else {
            // Case 3: File Deleted or Moved to Trash in Finder -> Delete from Remote SFTP Server
            if isReadOnly {
                return
            }

            // PROVENANCE GUARD: Check if OpenDuck initiated this local removal (reconciliation, eviction, etc.)
            if manager.isSelfInitiatedRemoval(path: localPath) {
                return // OpenDuck initiated this local removal; NEVER send delete to remote!
            }

            // Cancel any pending debounced upload or active in-flight upload task immediately
            lock.lock()
            syncDebounceWorkItems[remotePath]?.cancel()
            syncDebounceWorkItems.removeValue(forKey: remotePath)
            let inFlightTask = activeUploadTasks.removeValue(forKey: remotePath)
            let inFlightTracker = activeTrackers.removeValue(forKey: remotePath)
            lock.unlock()

            inFlightTask?.cancel()
            inFlightTracker?.markFailed(error: AdapterError.unsupportedOperation("File deleted during upload"))

            let itemId = self.cacheEngine.itemIdentifier(for: remotePath)

            // SAFEGUARD LAYER 6: Mass Deletion Circuit Breaker
            guard recordAndCheckCircuitBreaker() else {
                print("🛡️ [OpenDuck] Mass deletion blocked by circuit breaker for: \(remotePath)")
                // JOURNAL THE BLOCKED DELETION instead of silently dropping it.
                // When the circuit breaker is reset, syncPendingWrites will process these.
                let journalEntry = JournalEntry(
                    action: .delete,
                    itemIdentifier: itemId,
                    remotePath: remotePath
                )
                self.cacheEngine.journal.append(journalEntry)
                self.onStatusChange?("⏸ Deletion queued (circuit breaker active): \(filename)")
                return
            }

            Task {
                do {
                    self.onStatusChange?("Deleting \(filename)...")
                    try await self.adapter.delete(remotePath: remotePath)
                    try? self.cacheEngine.evict(itemIdentifier: itemId)
                    self.manager.removePlaceholder(path: localPath)
                    MetadataDatabase.shared.deleteRecord(localPath: localPath)
                    self.onStatusChange?("✓ Deleted \(filename)")
                } catch {
                    // JOURNAL THE FAILED DELETION for retry instead of silently swallowing.
                    // On reconnect or next retry cycle, syncPendingWrites will process it.
                    let journalEntry = JournalEntry(
                        action: .delete,
                        itemIdentifier: itemId,
                        remotePath: remotePath
                    )
                    self.cacheEngine.journal.append(journalEntry)
                    self.onStatusChange?("⚠️ Delete failed, queued for retry: \(filename) — \(error.localizedDescription)")
                    print("🔄 [OpenDuck] Delete failed, journaled for retry: \(remotePath) — \(error)")
                }
            }
        }
    }
}

private func fsEventsCallback(
    streamRef: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let contextPtr = clientCallBackInfo else { return }
    let context = Unmanaged<WatcherContext>.fromOpaque(contextPtr).takeUnretainedValue()

    let paths = unsafeBitCast(eventPaths, to: NSArray.self)
    for i in 0..<numEvents {
        let flags = eventFlags[i]
        guard let path = paths[i] as? String else { continue }
        context.handleEvent(localPath: path, flags: flags)
    }
}
