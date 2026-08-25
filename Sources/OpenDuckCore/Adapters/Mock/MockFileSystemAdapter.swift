import Foundation

/// In-memory Mock Adapter for deterministic unit testing, benchmarking, and offline simulation.
public final class MockFileSystemAdapter: RemoteFilesystemAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private var _isConnected: Bool = false
    private var fileStore: [String: (data: Data, entry: RemoteFileEntry)] = [:]
    private var directories: Set<String> = ["/"]
    private var _uploadedPaths: [String] = []
    private var _deletedPaths: [String] = []
    private var _movedPaths: [(String, String)] = []

    public let endpointDescription: String
    public var simulatedLatencyMs: UInt32 = 0
    public var simulatedError: AdapterError?
    /// Fault-injection hook used by tests to mutate the remote between a stat
    /// and the completion of a download.
    public var onDownload: (() -> Void)?

    public init(endpointDescription: String = "mock://local.test") {
        self.endpointDescription = endpointDescription
        directories.insert("/")
    }

    private func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    public var isConnected: Bool {
        sync { _isConnected }
    }

    /// Operation traces support assertions about filesystem intent without
    /// inspecting private in-memory state in tests.
    public var uploadedPaths: [String] { sync { _uploadedPaths } }
    public var deletedPaths: [String] { sync { _deletedPaths } }
    public var movedPaths: [(String, String)] { sync { _movedPaths } }

    public func connect() async throws {
        try await simulateNetwork()
        try sync {
            if let error = simulatedError { throw error }
            _isConnected = true
        }
    }

    public func disconnect() async {
        sync {
            _isConnected = false
        }
    }

    public func listDirectory(path: String) async throws -> [RemoteFileEntry] {
        try await simulateNetwork()

        return try sync {
            guard _isConnected else { throw AdapterError.notConnected }
            if let error = simulatedError { throw error }

            let normalized = normalizePath(path)
            guard directories.contains(normalized) else {
                throw AdapterError.fileNotFound(path)
            }

            var results: [RemoteFileEntry] = []

            for dir in directories where dir != normalized {
                let parent = (dir as NSString).deletingLastPathComponent
                let parentNorm = normalizePath(parent)
                if parentNorm == normalized {
                    let name = (dir as NSString).lastPathComponent
                    results.append(RemoteFileEntry(
                        name: name,
                        path: dir,
                        itemType: .directory,
                        size: 0,
                        modificationDate: Date()
                    ))
                }
            }

            for (filePath, item) in fileStore {
                let parent = (filePath as NSString).deletingLastPathComponent
                let parentNorm = normalizePath(parent)
                if parentNorm == normalized {
                    results.append(item.entry)
                }
            }

            return results.sorted { $0.name < $1.name }
        }
    }

    public func stat(path: String) async throws -> RemoteFileEntry {
        try await simulateNetwork()

        return try sync {
            guard _isConnected else { throw AdapterError.notConnected }
            if let error = simulatedError { throw error }

            let normalized = normalizePath(path)
            if normalized == "/" {
                return RemoteFileEntry(name: "/", path: "/", itemType: .directory, size: 0, modificationDate: Date())
            }

            if directories.contains(normalized) {
                let name = (normalized as NSString).lastPathComponent
                return RemoteFileEntry(name: name, path: normalized, itemType: .directory, size: 0, modificationDate: Date())
            }

            if let file = fileStore[normalized] {
                return file.entry
            }

            throw AdapterError.fileNotFound(path)
        }
    }

    public func download(remotePath: String, to localURL: URL, progress: Progress?) async throws {
        try await simulateNetwork()

        let data: Data = try sync {
            guard _isConnected else { throw AdapterError.notConnected }
            if let error = simulatedError { throw error }

            let normalized = normalizePath(remotePath)
            guard let file = fileStore[normalized] else {
                throw AdapterError.fileNotFound(remotePath)
            }
            return file.data
        }

        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let downloadHook = sync { onDownload }
        downloadHook?()
        progress?.totalUnitCount = Int64(data.count)
        progress?.completedUnitCount = 0
        try data.write(to: localURL, options: .atomic)
        progress?.completedUnitCount = Int64(data.count)
    }

    public func upload(from localURL: URL, to remotePath: String, progress: Progress?) async throws {
        let data = try Data(contentsOf: localURL)
        progress?.totalUnitCount = Int64(data.count)
        progress?.completedUnitCount = 0
        try await simulateNetwork()

        try sync {
            guard _isConnected else { throw AdapterError.notConnected }
            if let error = simulatedError { throw error }

            let normalized = normalizePath(remotePath)
            let parent = (normalized as NSString).deletingLastPathComponent
            let parentNorm = normalizePath(parent)
            guard directories.contains(parentNorm) else {
                throw AdapterError.fileNotFound(parent)
            }

            let name = (normalized as NSString).lastPathComponent
            let entry = RemoteFileEntry(
                name: name,
                path: normalized,
                itemType: .file,
                size: Int64(data.count),
                modificationDate: Date()
            )
            fileStore[normalized] = (data: data, entry: entry)
            _uploadedPaths.append(normalized)
        }

        progress?.completedUnitCount = Int64(data.count)
    }

    public func createDirectory(path: String) async throws {
        try await simulateNetwork()

        try sync {
            guard _isConnected else { throw AdapterError.notConnected }
            if let error = simulatedError { throw error }

            let normalized = normalizePath(path)
            let parent = (normalized as NSString).deletingLastPathComponent
            let parentNorm = normalizePath(parent)
            guard directories.contains(parentNorm) else {
                throw AdapterError.fileNotFound(parent)
            }

            if directories.contains(normalized) || fileStore[normalized] != nil {
                throw AdapterError.alreadyExists(path)
            }

            directories.insert(normalized)
        }
    }

    public func delete(remotePath: String) async throws {
        try await simulateNetwork()

        try sync {
            guard _isConnected else { throw AdapterError.notConnected }
            if let error = simulatedError { throw error }

            let normalized = normalizePath(remotePath)
            if fileStore.removeValue(forKey: normalized) != nil {
                _deletedPaths.append(normalized)
                return
            }

            if directories.contains(normalized) {
                directories.remove(normalized)
                let prefix = normalized.hasSuffix("/") ? normalized : normalized + "/"
                directories = directories.filter { !$0.hasPrefix(prefix) }
                fileStore = fileStore.filter { !$0.key.hasPrefix(prefix) }
                _deletedPaths.append(normalized)
                return
            }

            throw AdapterError.fileNotFound(remotePath)
        }
    }

    public func move(from sourcePath: String, to destinationPath: String) async throws {
        try await simulateNetwork()

        try sync {
            guard _isConnected else { throw AdapterError.notConnected }
            if let error = simulatedError { throw error }

            let srcNorm = normalizePath(sourcePath)
            let dstNorm = normalizePath(destinationPath)

            if let file = fileStore.removeValue(forKey: srcNorm) {
                let dstName = (dstNorm as NSString).lastPathComponent
                let newEntry = RemoteFileEntry(
                    name: dstName,
                    path: dstNorm,
                    itemType: .file,
                    size: file.entry.size,
                    modificationDate: Date()
                )
                fileStore[dstNorm] = (data: file.data, entry: newEntry)
                _movedPaths.append((srcNorm, dstNorm))
                return
            }

            if directories.contains(srcNorm) {
                directories.remove(srcNorm)
                directories.insert(dstNorm)
                _movedPaths.append((srcNorm, dstNorm))
                return
            }

            throw AdapterError.fileNotFound(sourcePath)
        }
    }

    public func seedFile(path: String, content: String) {
        sync {
            let normalized = normalizePath(path)
            let parent = (normalized as NSString).deletingLastPathComponent
            ensureDirectoryTree(parent)

            let data = Data(content.utf8)
            let name = (normalized as NSString).lastPathComponent
            let entry = RemoteFileEntry(
                name: name,
                path: normalized,
                itemType: .file,
                size: Int64(data.count),
                modificationDate: Date()
            )
            fileStore[normalized] = (data: data, entry: entry)
        }
    }

    private func ensureDirectoryTree(_ path: String) {
        let norm = normalizePath(path)
        if norm.isEmpty || norm == "/" {
            directories.insert("/")
            return
        }
        var current = ""
        let parts = norm.split(separator: "/")
        directories.insert("/")
        for part in parts {
            current += "/" + part
            directories.insert(current)
        }
    }

    private func normalizePath(_ path: String) -> String {
        let clean = (path as NSString).standardizingPath
        if clean.isEmpty { return "/" }
        return clean.hasPrefix("/") ? clean : "/" + clean
    }

    private func simulateNetwork() async throws {
        if simulatedLatencyMs > 0 {
            try await Task.sleep(nanoseconds: UInt64(simulatedLatencyMs) * 1_000_000)
        }
    }
}
