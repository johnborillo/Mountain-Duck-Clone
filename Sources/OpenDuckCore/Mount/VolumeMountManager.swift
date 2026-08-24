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
    private var knownPlaceholders: Set<String> = [] // Full local paths of OpenDuck-generated placeholders
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

    @discardableResult
    private func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Mounts a virtual volume at `/Volumes/<name>`.
    public func mount(name: String, sizeGB: Int = 100, isReadOnly: Bool = false) throws -> URL {
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
            knownPlaceholders.removeAll()
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
            knownPlaceholders.removeAll()
        }
    }

    public func isMounted(name: String) -> Bool {
        let cleanName = name.replacingOccurrences(of: "/", with: "-")
        return FileManager.default.fileExists(atPath: "/Volumes/\(cleanName)")
    }

    // MARK: - Safe Lazy Directory Population

    /// Performs a single-level listing of a remote directory and creates local stubs.
    /// Placeholders are tagged with `com.openduck.placeholder` xattr and registered in `knownPlaceholders`.
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

        let remoteItems = try await adapter.listDirectory(path: remotePath)
        let remoteNames = Set(remoteItems.map { $0.name })

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
                    sync { knownPlaceholders.insert(localItemURL.path) }
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
                        try? FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: localItemURL.path)
                        try? FileManager.default.removeItem(at: localItemURL)
                        sync { knownPlaceholders.remove(localItemURL.path) }
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

        // Background progressive hydration: stream down real binary file data in background
        Task.detached(priority: .utility) { [weak self, weak cacheEngine] in
            guard let self = self, let cacheEngine = cacheEngine else { return }
            for item in remoteItems where !item.isDirectory {
                let localItemURL = localURL.appendingPathComponent(item.name)
                if VolumeMountManager.isPlaceholderXAttr(path: localItemURL.path) || self.isPlaceholder(path: localItemURL.path) {
                    try? await self.hydrateFile(
                        localPath: localItemURL.path,
                        remotePath: item.path,
                        adapter: adapter,
                        cacheEngine: cacheEngine,
                        isReadOnly: isReadOnly
                    )
                }
            }
        }

        return remoteItems
    }

    public func isPopulated(remotePath: String) -> Bool {
        sync { populatedDirs.contains(remotePath) }
    }

    public func isPlaceholder(path: String) -> Bool {
        sync { knownPlaceholders.contains(path) }
    }

    public func removePlaceholder(path: String) {
        sync { knownPlaceholders.remove(path) }
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
                _ = try? await populateDirectory(
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
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: localURL.path)
        try await adapter.download(remotePath: remotePath, to: localURL, progress: nil)
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
        onStatusChange: (@Sendable (String) -> Void)? = nil
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
            onStatusChange: onStatusChange
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
        let stream: FSEventStreamRef? = sync {
            _ = activeContexts.removeValue(forKey: cleanName)
            return activeStreams.removeValue(forKey: cleanName)
        }
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
}

// MARK: - Watcher Context & Safe Event Dispatcher

private final class WatcherContext {
    let volumeURL: URL
    let remoteRootPath: String
    let adapter: RemoteFilesystemAdapter
    let cacheEngine: CacheEngine
    let manager: VolumeMountManager
    let isReadOnly: Bool
    let onStatusChange: (@Sendable (String) -> Void)?

    private var pendingPaths = Set<String>()
    private var syncDebounceWorkItems: [String: DispatchWorkItem] = [:]
    private var deletionTimestamps: [Date] = []
    private(set) var isCircuitBreakerTripped: Bool = false
    private let lock = NSLock()

    init(
        volumeURL: URL,
        remoteRootPath: String,
        adapter: RemoteFilesystemAdapter,
        cacheEngine: CacheEngine,
        manager: VolumeMountManager,
        isReadOnly: Bool = false,
        onStatusChange: (@Sendable (String) -> Void)?
    ) {
        self.volumeURL = volumeURL
        self.remoteRootPath = remoteRootPath
        self.adapter = adapter
        self.cacheEngine = cacheEngine
        self.manager = manager
        self.isReadOnly = isReadOnly
        self.onStatusChange = onStatusChange
    }

    func resetCircuitBreaker() {
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
        deletionTimestamps = deletionTimestamps.filter { now.timeIntervalSince($0) < 1.0 }
        deletionTimestamps.append(now)

        if deletionTimestamps.count > 10 {
            isCircuitBreakerTripped = true
            DispatchQueue.main.async {
                self.onStatusChange?("⚠️ SAFETY CIRCUIT BREAKER TRIPPED: Mass deletion (>10 files/sec) paused to protect remote storage.")
            }
            return false
        }
        return true
    }

    func handleEvent(localPath: String, flags: UInt32) {
        let volumePath = volumeURL.path
        guard localPath.hasPrefix(volumePath) else { return }

        let filename = (localPath as NSString).lastPathComponent

        // Ignore macOS system, metadata, swap files, atomic temp files, and Trash folders
        if filename == ".DS_Store" ||
           filename.hasPrefix("._") ||
           filename == ".Spotlight-V100" ||
           filename.hasPrefix(".Trash") ||
           localPath.contains("/.Trashes") ||
           localPath.contains("/.Trash") ||
           filename.contains(".nosync") ||
           filename.hasPrefix(".dat.") ||
           filename.hasPrefix(".dat") ||
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

        let isDir = (flags & UInt32(kFSEventStreamEventFlagItemIsDir)) != 0
        let isRemoved = (flags & UInt32(kFSEventStreamEventFlagItemRemoved)) != 0
        let localURL = URL(fileURLWithPath: localPath)
        let fileExists = FileManager.default.fileExists(atPath: localPath)

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
                        _ = try? await self.manager.populateDirectory(
                            adapter: self.adapter,
                            remotePath: remotePath,
                            localURL: localURL,
                            cacheEngine: self.cacheEngine
                        )
                    }
                }
            } else if isRemoved {
                if isReadOnly { return }
                guard recordAndCheckCircuitBreaker() else { return }
                Task {
                    try? await self.adapter.delete(remotePath: remotePath)
                    self.manager.invalidateDirectory(remotePath: remotePath)
                }
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

            guard let attrs = try? FileManager.default.attributesOfItem(atPath: localPath),
                  let fileSize = attrs[.size] as? Int64 else {
                return
            }

            // SAFEGUARD LAYER 5: Never automatically upload 0-byte files
            guard fileSize > 0 else {
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

            // Debounce upload by 800ms
            lock.lock()
            syncDebounceWorkItems[remotePath]?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                Task {
                    do {
                        self.onStatusChange?("Uploading \(filename)...")
                        try await self.adapter.upload(from: localURL, to: remotePath, progress: nil)
                        self.cacheEngine.markClean(itemIdentifier: itemId, remotePath: remotePath)
                        self.onStatusChange?("✓ Uploaded \(filename)")
                    } catch {
                        self.onStatusChange?("🛑 Safety/Upload notice: \(error.localizedDescription)")
                    }
                }
            }
            syncDebounceWorkItems[remotePath] = workItem
            lock.unlock()

            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.8, execute: workItem)

        } else {
            // Case 3: File Deleted or Moved to Trash in Finder -> Delete from Remote SFTP Server
            if isReadOnly {
                return
            }

            // SAFEGUARD LAYER 6: Mass Deletion Circuit Breaker
            guard recordAndCheckCircuitBreaker() else {
                print("🛡️ [OpenDuck] Mass deletion blocked by circuit breaker for: \(remotePath)")
                return
            }

            Task {
                do {
                    self.onStatusChange?("Deleting \(filename)...")
                    try await self.adapter.delete(remotePath: remotePath)
                    let itemId = self.cacheEngine.itemIdentifier(for: remotePath)
                    try? self.cacheEngine.evict(itemIdentifier: itemId)
                    self.manager.removePlaceholder(path: localPath)
                    self.onStatusChange?("✓ Deleted \(filename)")
                } catch {
                    // Ignore if already deleted on remote server
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
