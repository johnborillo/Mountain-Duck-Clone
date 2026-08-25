import Foundation

/// Represents the type of a remote item.
public enum RemoteItemType: String, Codable, Sendable {
    case file
    case directory
    case symbolicLink
    case unknown
}

/// Metadata entry representing a file or directory on a remote server.
public struct RemoteFileEntry: Codable, Sendable, Equatable {
    public let name: String
    public let path: String
    public let itemType: RemoteItemType
    public let size: Int64
    public let modificationDate: Date
    public let creationDate: Date?
    public let permissions: UInt16?
    public let owner: String?
    public let group: String?
    public let etag: String?

    public var isDirectory: Bool {
        return itemType == .directory
    }

    /// Stable-enough optimistic-concurrency fingerprint available from SFTP stat
    /// data without downloading the file. Servers that expose an etag win; other
    /// servers use type, size, and modification time.
    public var contentVersion: String {
        etag ?? "\(itemType.rawValue):\(size):\(modificationDate.timeIntervalSince1970)"
    }

    public var metadataVersion: String {
        "\(name)|\(itemType.rawValue)|\(size)|\(modificationDate.timeIntervalSince1970)|\(permissions.map { String($0) } ?? "")"
    }

    public init(
        name: String,
        path: String,
        itemType: RemoteItemType = .file,
        size: Int64 = 0,
        modificationDate: Date = Date(),
        creationDate: Date? = nil,
        permissions: UInt16? = nil,
        owner: String? = nil,
        group: String? = nil,
        etag: String? = nil
    ) {
        self.name = name
        self.path = path
        self.itemType = itemType
        self.size = size
        self.modificationDate = modificationDate
        self.creationDate = creationDate
        self.permissions = permissions
        self.owner = owner
        self.group = group
        self.etag = etag
    }
}

/// Errors produced during remote filesystem operations.
public enum AdapterError: Error, LocalizedError, Sendable {
    case notConnected
    case authenticationFailed(String)
    case fileNotFound(String)
    case permissionDenied(String)
    case alreadyExists(String)
    case networkError(String)
    case conflict(localVersion: String, remoteVersion: String)
    case invalidPath(String)
    case unsupportedOperation(String)
    case serverError(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Remote adapter is not connected to a server."
        case .authenticationFailed(let reason):
            return "Authentication failed: \(reason)"
        case .fileNotFound(let path):
            return "Remote file not found: \(path)"
        case .permissionDenied(let path):
            return "Permission denied for remote path: \(path)"
        case .alreadyExists(let path):
            return "Remote item already exists: \(path)"
        case .networkError(let msg):
            return "Network connection error: \(msg)"
        case .conflict(let localVersion, let remoteVersion):
            return "Remote content changed (local base \(localVersion), remote \(remoteVersion)); the local edit was preserved and not applied."
        case .invalidPath(let path):
            return "Invalid path requested: \(path)"
        case .unsupportedOperation(let op):
            return "Operation '\(op)' is unsupported by this remote backend."
        case .serverError(let msg):
            return "Remote server error: \(msg)"
        }
    }
}

/// The universal contract every remote backend (SFTP, S3, WebDAV, Mock) must fulfill.
public protocol RemoteFilesystemAdapter: Sendable {
    /// Identifier for this adapter instance (e.g. "sftp://user@host:22")
    var endpointDescription: String { get }

    /// Whether the adapter is currently connected and ready.
    var isConnected: Bool { get }

    /// Connect to remote host using credentials.
    func connect() async throws

    /// Disconnect and release all network resources.
    func disconnect() async

    /// List contents of a remote directory.
    func listDirectory(path: String) async throws -> [RemoteFileEntry]

    /// Get metadata for a single remote item.
    func stat(path: String) async throws -> RemoteFileEntry

    /// Download a remote file to a local destination URL.
    func download(remotePath: String, to localURL: URL, progress: Progress?) async throws

    /// Upload a local file from a local URL to a remote destination path.
    func upload(from localURL: URL, to remotePath: String, progress: Progress?) async throws

    /// Create a remote directory.
    func createDirectory(path: String) async throws

    /// Delete a remote file or directory.
    func delete(remotePath: String) async throws

    /// Move or rename a remote item.
    func move(from sourcePath: String, to destinationPath: String) async throws
}
