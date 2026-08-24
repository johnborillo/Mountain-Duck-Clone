import Foundation

/// Manages native macOS virtual volumes mounted under `/Volumes/<ProfileName>`.
/// Appears directly under Finder sidebar "Locations" as a first-class native volume.
public final class VolumeMountManager: @unchecked Sendable {
    public static let shared = VolumeMountManager()

    private let lock = NSLock()
    private var mountedVolumes: [String: URL] = [:]
    private let baseStorageDir: URL

    public init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("OpenDuck/Volumes")
        self.baseStorageDir = appSupport
        try? FileManager.default.createDirectory(at: baseStorageDir, withIntermediateDirectories: true)
    }

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

        // 3. Attach image at /Volumes/<name>
        let attachProcess = Process()
        attachProcess.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        attachProcess.arguments = [
            "attach",
            imageURL.path,
            "-mountpoint", mountPoint.path
        ]

        let pipe = Pipe()
        attachProcess.standardError = pipe
        try attachProcess.run()
        attachProcess.waitUntilExit()

        if !FileManager.default.fileExists(atPath: mountPoint.path) {
            // Fallback: mount without explicit mountpoint
            let fallbackProcess = Process()
            fallbackProcess.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            fallbackProcess.arguments = ["attach", imageURL.path]
            try fallbackProcess.run()
            fallbackProcess.waitUntilExit()
        }

        sync {
            mountedVolumes[cleanName] = mountPoint
        }

        return mountPoint
    }

    /// Unmounts and detaches the virtual volume from `/Volumes/<name>`.
    public func unmount(name: String) throws {
        let cleanName = name.replacingOccurrences(of: "/", with: "-")
        let mountPoint = "/Volumes/\(cleanName)"

        let detachProcess = Process()
        detachProcess.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        detachProcess.arguments = [
            "detach",
            mountPoint,
            "-force"
        ]
        try detachProcess.run()
        detachProcess.waitUntilExit()

        sync {
            _ = mountedVolumes.removeValue(forKey: cleanName)
        }
    }

    public func isMounted(name: String) -> Bool {
        let cleanName = name.replacingOccurrences(of: "/", with: "-")
        let mountPoint = "/Volumes/\(cleanName)"
        return FileManager.default.fileExists(atPath: mountPoint)
    }

    /// Recursively synchronizes remote directory tree to local volume up to `maxDepth`.
    public func syncTree(
        adapter: RemoteFilesystemAdapter,
        remotePath: String,
        localURL: URL,
        cacheEngine: CacheEngine,
        currentDepth: Int = 0,
        maxDepth: Int = 4,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws {
        guard currentDepth <= maxDepth else { return }

        try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)

        let items = try await adapter.listDirectory(path: remotePath)
        onProgress?("Syncing \(remotePath) (\(items.count) items)...")

        for item in items {
            let localItemURL = localURL.appendingPathComponent(item.name)
            _ = cacheEngine.registerPlaceholder(for: item)

            if item.isDirectory {
                try? FileManager.default.createDirectory(at: localItemURL, withIntermediateDirectories: true)
                // Recurse into child subfolder
                try await syncTree(
                    adapter: adapter,
                    remotePath: item.path,
                    localURL: localItemURL,
                    cacheEngine: cacheEngine,
                    currentDepth: currentDepth + 1,
                    maxDepth: maxDepth,
                    onProgress: onProgress
                )
            } else {
                if !FileManager.default.fileExists(atPath: localItemURL.path) {
                    try? await adapter.download(remotePath: item.path, to: localItemURL, progress: nil)
                }
            }
        }
    }
}
