import Foundation

/// Manages native macOS virtual volumes mounted under `/Volumes/<ProfileName>`.
/// Uses lazy on-demand directory population via FSEvents — only lists the folder
/// the user is currently looking at in Finder, and never pre-downloads file contents.
public final class VolumeMountManager: @unchecked Sendable {
    public static let shared = VolumeMountManager()

    private let lock = NSLock()
    private var mountedVolumes: [String: URL] = [:]
    private var populatedDirs: Set<String> = []
    private var activeStreams: [String: FSEventStreamRef] = [:]
    private let baseStorageDir: URL

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
    public func mount(name: String, sizeGB: Int = 100) throws -> URL {
        let cleanName = name.replacingOccurrences(of: "/", with: "-")
        let mountPoint = URL(fileURLWithPath: "/Volumes/\(cleanName)")
        let imageURL = baseStorageDir.appendingPathComponent("\(cleanName).dmg.sparseimage")

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

        _ = try? unmount(name: cleanName)

        let attachProcess = Process()
        attachProcess.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        attachProcess.arguments = ["attach", imageURL.path, "-mountpoint", mountPoint.path]
        try attachProcess.run()
        attachProcess.waitUntilExit()

        if !FileManager.default.fileExists(atPath: mountPoint.path) {
            let fallbackProcess = Process()
            fallbackProcess.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            fallbackProcess.arguments = ["attach", imageURL.path]
            try fallbackProcess.run()
            fallbackProcess.waitUntilExit()
        }

        sync {
            mountedVolumes[cleanName] = mountPoint
            populatedDirs.removeAll()
        }

        return mountPoint
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

    // MARK: - Lazy Directory Population

    /// Performs a single-level listing of a remote directory and creates local stubs.
    /// Directories become real empty directories; files become zero-byte placeholders.
    /// NO file content is downloaded. NO recursion.
    public func populateDirectory(
        adapter: RemoteFilesystemAdapter,
        remotePath: String,
        localURL: URL,
        cacheEngine: CacheEngine
    ) async throws -> [RemoteFileEntry] {
        let alreadyPopulated: Bool = sync { populatedDirs.contains(remotePath) }
        if alreadyPopulated { return [] }

        try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)

        let items = try await adapter.listDirectory(path: remotePath)

        for item in items {
            let localItemURL = localURL.appendingPathComponent(item.name)
            _ = cacheEngine.registerPlaceholder(for: item)

            if item.isDirectory {
                try? FileManager.default.createDirectory(at: localItemURL, withIntermediateDirectories: true)
            } else {
                if !FileManager.default.fileExists(atPath: localItemURL.path) {
                    FileManager.default.createFile(atPath: localItemURL.path, contents: nil)
                }
            }
        }

        sync { populatedDirs.insert(remotePath) }
        return items
    }

    /// Check if a remote directory has been populated locally.
    public func isPopulated(remotePath: String) -> Bool {
        sync { populatedDirs.contains(remotePath) }
    }

    /// Reset populated state for a directory (forces re-listing on next access).
    public func invalidateDirectory(remotePath: String) {
        sync { populatedDirs.remove(remotePath) }
    }

    // MARK: - FSEvents Directory Watcher

    /// Starts watching the volume for directory access events.
    /// When Finder opens a subdirectory, we lazily populate it from the remote server.
    public func startWatching(
        name: String,
        volumeURL: URL,
        remoteRootPath: String,
        adapter: RemoteFilesystemAdapter,
        cacheEngine: CacheEngine
    ) {
        let cleanName = name.replacingOccurrences(of: "/", with: "-")
        stopWatching(name: cleanName)

        let context = WatcherContext(
            volumeURL: volumeURL,
            remoteRootPath: remoteRootPath,
            adapter: adapter,
            cacheEngine: cacheEngine,
            manager: self
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
            0.3,
            UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        )!

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)

        sync { activeStreams[cleanName] = stream }
    }

    public func stopWatching(name: String) {
        let cleanName = name.replacingOccurrences(of: "/", with: "-")
        let stream: FSEventStreamRef? = sync { activeStreams.removeValue(forKey: cleanName) }
        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

// MARK: - FSEvents Callback & Watcher Context

private final class WatcherContext {
    let volumeURL: URL
    let remoteRootPath: String
    let adapter: RemoteFilesystemAdapter
    let cacheEngine: CacheEngine
    let manager: VolumeMountManager
    private var pendingPaths = Set<String>()
    private let lock = NSLock()

    init(volumeURL: URL, remoteRootPath: String, adapter: RemoteFilesystemAdapter, cacheEngine: CacheEngine, manager: VolumeMountManager) {
        self.volumeURL = volumeURL
        self.remoteRootPath = remoteRootPath
        self.adapter = adapter
        self.cacheEngine = cacheEngine
        self.manager = manager
    }

    func handleDirectoryAccess(localPath: String) {
        let volumePath = volumeURL.path
        guard localPath.hasPrefix(volumePath) else { return }

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

        let shouldProcess: Bool = lock.withLock {
            if pendingPaths.contains(remotePath) { return false }
            pendingPaths.insert(remotePath)
            return true
        }
        guard shouldProcess else { return }

        guard !manager.isPopulated(remotePath: remotePath) else {
            lock.withLock { _ = pendingPaths.remove(remotePath) }
            return
        }

        let localURL = URL(fileURLWithPath: localPath)

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

        let isDir = (flags & UInt32(kFSEventStreamEventFlagItemIsDir)) != 0
        if isDir {
            context.handleDirectoryAccess(localPath: path)
        }
    }
}
