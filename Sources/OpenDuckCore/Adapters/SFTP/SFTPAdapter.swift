import Foundation
import Citadel
import NIO
import NIOSSH
import Crypto

/// Authentication credentials for SFTP connections.
public enum SFTPAuthMethod: Sendable {
    case password(String)
    case privateKey(keyPath: String, passphrase: String?)
}

/// Configuration parameters for an SFTP remote endpoint.
public struct SFTPConfiguration: Sendable {
    public let host: String
    public let port: Int
    public let username: String
    public let authMethod: SFTPAuthMethod
    public let rootPath: String
    public let connectionTimeout: TimeInterval

    public init(
        host: String,
        port: Int = 22,
        username: String,
        authMethod: SFTPAuthMethod,
        rootPath: String = "/",
        connectionTimeout: TimeInterval = 15.0
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.rootPath = rootPath
        self.connectionTimeout = connectionTimeout
    }
}

/// Native Swift Citadel/NIO-backed SFTP Filesystem Adapter implementing `RemoteFilesystemAdapter`.
/// Completely eliminates string-based subprocess shell-outs and batch command injection vulnerabilities.
public final class SFTPAdapter: RemoteFilesystemAdapter, @unchecked Sendable {
    public let configuration: SFTPConfiguration
    private let lock = NSLock()
    private var sshClient: SSHClient?
    private var sftpClient: SFTPClient?

    public var endpointDescription: String {
        return "sftp://\(configuration.username)@\(configuration.host):\(configuration.port)\(configuration.rootPath)"
    }

    public init(configuration: SFTPConfiguration) {
        self.configuration = configuration
    }

    public var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sftpClient?.isActive ?? false
    }

    public func connect() async throws {
        let authMethod: SSHAuthenticationMethod
        switch configuration.authMethod {
        case .password(let password):
            authMethod = .passwordBased(username: configuration.username, password: password)
        case .privateKey(let keyPath, let passphrase):
            let expandedPath = NSString(string: keyPath).expandingTildeInPath
            guard let keyData = try? Data(contentsOf: URL(fileURLWithPath: expandedPath)) else {
                throw AdapterError.authenticationFailed("Could not read SSH private key file at '\(expandedPath)'")
            }
            if let keyString = String(data: keyData, encoding: .utf8) {
                let decKey = passphrase?.data(using: .utf8)
                if let privKey = try? Curve25519.Signing.PrivateKey(sshEd25519: keyString, decryptionKey: decKey) {
                    authMethod = .ed25519(username: configuration.username, privateKey: privKey)
                } else if let rsaKey = try? Insecure.RSA.PrivateKey(sshRsa: keyString, decryptionKey: decKey) {
                    authMethod = .rsa(username: configuration.username, privateKey: rsaKey)
                } else if let rawKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) {
                    authMethod = .ed25519(username: configuration.username, privateKey: rawKey)
                } else {
                    throw AdapterError.authenticationFailed("Failed to parse or decrypt private key at '\(expandedPath)'. If passphrase-protected, ensure the correct passphrase is provided.")
                }
            } else {
                throw AdapterError.authenticationFailed("Invalid private key format at '\(expandedPath)'")
            }
        }

        let validator = OpenDuckHostKeyValidator(
            host: configuration.host,
            port: configuration.port
        )

        do {
            let client = try await SSHClient.connect(
                host: configuration.host,
                port: configuration.port,
                authenticationMethod: authMethod,
                hostKeyValidator: .custom(validator),
                reconnect: .never,
                connectTimeout: .seconds(Int64(configuration.connectionTimeout))
            )
            let sftp = try await client.openSFTP()

            lock.withLock {
                self.sshClient = client
                self.sftpClient = sftp
            }
        } catch {
            if validator.mismatchDetected {
                let exp = validator.expectedFingerprint ?? "unknown"
                let rcv = validator.validatedFingerprint ?? "unknown"
                throw AdapterError.authenticationFailed("HOST KEY VERIFICATION FAILED: Remote host key mismatch for \(configuration.host):\(configuration.port)!\nExpected: \(exp)\nReceived: \(rcv)\nPossible Man-In-The-Middle attack or server key changed.")
            }
            throw AdapterError.authenticationFailed("SFTP connection failed: \(error.localizedDescription)")
        }
    }

    public func disconnect() async {
        let (sftp, ssh) = lock.withLock {
            let s = self.sftpClient
            let c = self.sshClient
            self.sftpClient = nil
            self.sshClient = nil
            return (s, c)
        }
        try? await sftp?.close()
        try? await ssh?.close()
    }

    private func getSFTP() throws -> SFTPClient {
        return try lock.withLock {
            guard let sftp = sftpClient, sftp.isActive else {
                throw AdapterError.notConnected
            }
            return sftp
        }
    }

    private func resolvePath(_ relativeOrAbsPath: String) throws -> String {
        let candidate = relativeOrAbsPath.hasPrefix("/")
            ? RemotePath.normalize(relativeOrAbsPath)
            : RemotePath.join(configuration.rootPath, relativeOrAbsPath)
        guard RemotePath.isWithin(candidate, root: configuration.rootPath) else {
            throw AdapterError.invalidPath("Path escapes configured remote root: \(relativeOrAbsPath)")
        }
        return candidate
    }

    public func listDirectory(path: String) async throws -> [RemoteFileEntry] {
        let sftp = try getSFTP()
        let resolved = try resolvePath(path)

        do {
            let names = try await sftp.listDirectory(atPath: resolved)
            var entries: [RemoteFileEntry] = []

            for nameMsg in names {
                for item in nameMsg.components {
                    let filename = item.filename
                    if filename == "." || filename == ".." { continue }
                    if filename.hasPrefix(".openduck_") || filename.contains(".openduck_stage_") || filename.contains(".openduck_dl_") {
                        continue
                    }

                    let itemPath = resolved == "/" ? "/\(filename)" : "\(resolved)/\(filename)"
                    let isDir = (item.attributes.permissions ?? 0) & 0o040000 != 0
                    let size = Int64(item.attributes.size ?? 0)
                    let modDate = item.attributes.accessModificationTime?.modificationTime ?? Date()

                    entries.append(RemoteFileEntry(
                        name: filename,
                        path: itemPath,
                        itemType: isDir ? .directory : .file,
                        size: isDir ? 0 : size,
                        modificationDate: modDate
                    ))
                }
            }
            return entries
        } catch {
            throw Self.mapSFTPError(error, context: "listing '\(resolved)'")
        }
    }

    public func stat(path: String) async throws -> RemoteFileEntry {
        let sftp = try getSFTP()
        let resolved = try resolvePath(path)

        if resolved == "/" || resolved.isEmpty {
            return RemoteFileEntry(name: "/", path: "/", itemType: .directory, size: 0, modificationDate: Date())
        }

        do {
            let attrs = try await sftp.getAttributes(at: resolved)
            let isDir = (attrs.permissions ?? 0) & 0o040000 != 0
            let name = (resolved as NSString).lastPathComponent
            let size = Int64(attrs.size ?? 0)
            let modDate = attrs.accessModificationTime?.modificationTime ?? Date()

            return RemoteFileEntry(
                name: name,
                path: resolved,
                itemType: isDir ? .directory : .file,
                size: isDir ? 0 : size,
                modificationDate: modDate
            )
        } catch {
            throw Self.mapSFTPError(error, context: "reading attributes for '\(resolved)'")
        }
    }

    public func upload(from localURL: URL, to remotePath: String, progress: Progress?) async throws {
        let sftp = try getSFTP()
        let resolved = try resolvePath(remotePath)

        guard FileManager.default.fileExists(atPath: localURL.path) else {
            throw AdapterError.fileNotFound(localURL.path)
        }

        let localAttrs = try? FileManager.default.attributesOfItem(atPath: localURL.path)
        let localSize = (localAttrs?[.size] as? Int64) ?? 0

        // Placeholder protection belongs at the Finder integration boundary.
        // A generic transport layer must permit intentional truncation of an
        // existing remote file to zero bytes once a real mutation is approved.

        progress?.totalUnitCount = localSize
        progress?.completedUnitCount = 0

        // A unique staging name prevents two overlapping saves from sharing a
        // partial file. Resume is deliberately deferred until it can be tied to
        // a durable operation ID and a verified source version.
        try await ensureRemoteDirectoryTree(for: resolved)
        let stagingRemotePath = "\(resolved).openduck_stage_\(UUID().uuidString.lowercased())"
        let openFlags: SFTPOpenFileFlags = [.write, .create, .truncate]

        let stagingFile = try await sftp.openFile(
            filePath: stagingRemotePath,
            flags: openFlags
        )

        var offset: UInt64 = 0
        do {
            let fileHandle = try FileHandle(forReadingFrom: localURL)
            defer { try? fileHandle.close() }

            let chunkSize = 64 * 1024 // 64 KB chunk (balanced with Citadel's 32 KB write slices)
            let maxConcurrentChunks = 8 // 512 KB in-flight per file window to prevent socket buffer exhaustion
            try await withThrowingTaskGroup(of: Int.self) { group in
                var inFlight = 0
                var totalUploaded: Int64 = 0

                while let chunk = try fileHandle.read(upToCount: chunkSize), !chunk.isEmpty {
                    try Task.checkCancellation()

                    let chunkOffset = offset
                    let byteCount = chunk.count
                    offset += UInt64(byteCount)

                    var buffer = ByteBufferAllocator().buffer(capacity: byteCount)
                    buffer.writeBytes(chunk)

                    group.addTask {
                        try Task.checkCancellation()
                        try await stagingFile.write(buffer, at: chunkOffset)
                        return byteCount
                    }
                    inFlight += 1

                    if inFlight >= maxConcurrentChunks {
                        if let completedBytes = try await group.next() {
                            inFlight -= 1
                            totalUploaded += Int64(completedBytes)
                            progress?.completedUnitCount = totalUploaded
                        }
                    }
                }

                while let completedBytes = try await group.next() {
                    totalUploaded += Int64(completedBytes)
                    progress?.completedUnitCount = totalUploaded
                }
            }

            try Task.checkCancellation()
            try await stagingFile.close()
        } catch {
            try? await stagingFile.close()
            // A failed fresh stage has no durable operation record yet, so clean
            // it up. A future operation ledger can retain verified stage IDs for
            // safe resume.
            try? await sftp.remove(at: stagingRemotePath)
            throw Self.mapSFTPError(error, context: "uploading to '\(resolved)'")
        }

        // Atomic rename-overwrite is supported by most modern SFTP servers. If
        // a server rejects that operation, retain the staged data and report a
        // recoverable failure. Unlinking the destination first would turn an
        // interrupted replacement into irreversible remote data loss.
        do {
            try await sftp.rename(at: stagingRemotePath, to: resolved)
        } catch {
            throw AdapterError.serverError(
                "Upload staged successfully but the server rejected an atomic replacement of '\(resolved)'. "
                + "The existing remote file was preserved; staged data remains for recovery. "
                + "Server error: \(error.localizedDescription)"
            )
        }

        progress?.completedUnitCount = localSize
    }

    public func download(remotePath: String, to localURL: URL, progress: Progress?) async throws {
        let sftp = try getSFTP()
        let resolved = try resolvePath(remotePath)

        let remoteFile = try await sftp.openFile(filePath: resolved, flags: [.read])

        let attrs = try? await sftp.getAttributes(at: resolved)
        let totalSize = Int64(attrs?.size ?? 0)
        progress?.totalUnitCount = totalSize
        progress?.completedUnitCount = 0

        let parentDir = localURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("openduck_dl_\(UUID().uuidString).tmp")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)

        let writeHandle = try FileHandle(forWritingTo: tempURL)
        if totalSize > 0 {
            try? writeHandle.truncate(atOffset: UInt64(totalSize))
        }

        let chunkSize = 256 * 1024 // 256 KB chunk
        let maxConcurrentChunks = 32 // 8 MB in-flight window
        let totalBytesToRead = UInt64(totalSize)
        var bytesWritten: Int64 = 0

        do {
            if totalBytesToRead > 0 {
                try await withThrowingTaskGroup(of: (UInt64, ByteBuffer).self) { group in
                    var inFlight = 0
                    var requestOffset: UInt64 = 0
                    var totalDownloaded: Int64 = 0

                    while requestOffset < totalBytesToRead {
                        try Task.checkCancellation()

                        let currentOffset = requestOffset
                        let bytesRemaining = totalBytesToRead - currentOffset
                        let currentLength = UInt32(Swift.min(UInt64(chunkSize), bytesRemaining))
                        requestOffset += UInt64(currentLength)

                        group.addTask {
                            try Task.checkCancellation()
                            let buffer = try await remoteFile.read(from: currentOffset, length: currentLength)
                            return (currentOffset, buffer)
                        }
                        inFlight += 1

                        if inFlight >= maxConcurrentChunks {
                            if let (offset, buffer) = try await group.next() {
                                inFlight -= 1
                                try writeHandle.seek(toOffset: offset)
                                try writeHandle.write(contentsOf: buffer.readableBytesView)
                                totalDownloaded += Int64(buffer.readableBytes)
                                bytesWritten = totalDownloaded
                                progress?.completedUnitCount = totalDownloaded
                            }
                        }
                    }

                    while let (offset, buffer) = try await group.next() {
                        try writeHandle.seek(toOffset: offset)
                        try writeHandle.write(contentsOf: buffer.readableBytesView)
                        totalDownloaded += Int64(buffer.readableBytes)
                        bytesWritten = totalDownloaded
                        progress?.completedUnitCount = totalDownloaded
                    }
                }
            }
            guard bytesWritten == totalSize else {
                throw AdapterError.networkError(
                    "Downloaded \(bytesWritten) bytes for '\(resolved)', expected \(totalSize)."
                )
            }
            try writeHandle.close()
            try await remoteFile.close()
        } catch {
            try? writeHandle.close()
            try? await remoteFile.close()
            try? FileManager.default.removeItem(at: tempURL)
            throw Self.mapSFTPError(error, context: "downloading '\(resolved)'")
        }

        _ = try? FileManager.default.removeItem(at: localURL)
        try FileManager.default.moveItem(at: tempURL, to: localURL)

        progress?.completedUnitCount = totalSize
    }

    public func createDirectory(path: String) async throws {
        let sftp = try getSFTP()
        let resolved = try resolvePath(path)
        do {
            try await sftp.createDirectory(atPath: resolved)
        } catch {
            throw Self.mapSFTPError(error, context: "creating directory '\(resolved)'")
        }
    }

    /// Recursively ensures that all parent directory components for a given remote file path exist on the remote server.
    private func ensureRemoteDirectoryTree(for remoteFilePath: String) async throws {
        let sftp = try getSFTP()
        let parentPath = (remoteFilePath as NSString).deletingLastPathComponent

        guard !parentPath.isEmpty, parentPath != "/" else { return }

        // Check if parent already exists
        if let _ = try? await sftp.getAttributes(at: parentPath) {
            return
        }

        // Recursively ensure grandparent exists first
        try await ensureRemoteDirectoryTree(for: parentPath)

        // Create the parent directory
        try? await sftp.createDirectory(atPath: parentPath)
    }

    public func delete(remotePath: String) async throws {
        let sftp = try getSFTP()
        let resolved = try resolvePath(remotePath)

        // Try file unlink first
        do {
            try await sftp.remove(at: resolved)
            return
        } catch {
            // Not a regular file — fall through to recursive directory removal
        }

        // Recursive directory deletion: SFTP rmdir requires an empty directory,
        // so we must list and remove all children depth-first before removing the parent.
        try await deleteDirectoryRecursive(sftp: sftp, path: resolved)
    }

    /// Recursively deletes a remote directory by removing all children depth-first,
    /// then removing the now-empty directory itself.
    private func deleteDirectoryRecursive(sftp: SFTPClient, path: String) async throws {
        let children: [RemoteFileEntry]
        do {
            children = try await listDirectory(path: path)
        } catch {
            // Directory may already be empty or inaccessible — try direct rmdir
            try await sftp.rmdir(at: path)
            return
        }

        for child in children {
            if child.isDirectory {
                try await deleteDirectoryRecursive(sftp: sftp, path: child.path)
            } else {
                try await sftp.remove(at: child.path)
            }
        }

        try await sftp.rmdir(at: path)
    }

    public func move(from sourcePath: String, to destinationPath: String) async throws {
        let sftp = try getSFTP()
        let src = try resolvePath(sourcePath)
        let dst = try resolvePath(destinationPath)
        try await sftp.rename(at: src, to: dst)
    }

    // MARK: - SFTP Error Translation

    /// Maps raw Citadel SFTP errors to human-readable `AdapterError` types.
    ///
    /// Without this mapping, errors like `SFTPMessage.Status error 1` propagate as
    /// cryptic messages to the UI. This translates known SFTP status codes into
    /// meaningful domain errors.
    internal static func mapSFTPError(_ error: Error, context: String) -> Error {
        // Preserve cancellation errors as-is
        if error is CancellationError { return error }
        // Preserve already-mapped AdapterErrors
        if error is AdapterError { return error }

        let description = String(describing: error)

        // Match Citadel SFTPMessage.Status errors by their string representation
        // Status 1 = SSH_FX_EOF: channel/handle exhaustion from too many concurrent requests
        if description.contains("Status error 1") || description.contains("eof") {
            return AdapterError.networkError(
                "SFTP channel closed unexpectedly (SSH_FX_EOF) while \(context). "
                + "This typically indicates too many concurrent operations overwhelmed the SSH channel."
            )
        }
        // Status 2 = SSH_FX_NO_SUCH_FILE
        if description.contains("Status error 2") {
            return AdapterError.fileNotFound(context)
        }
        // Status 3 = SSH_FX_PERMISSION_DENIED
        if description.contains("Status error 3") {
            return AdapterError.permissionDenied(context)
        }
        // Status 4 = SSH_FX_FAILURE (generic server-side failure)
        if description.contains("Status error 4") {
            return AdapterError.serverError("SFTP operation failed while \(context): \(description)")
        }

        // Catch-all for other Citadel/NIO errors
        return AdapterError.networkError("SFTP error while \(context): \(error.localizedDescription)")
    }
}
