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

    private func resolvePath(_ relativeOrAbsPath: String) -> String {
        if relativeOrAbsPath.hasPrefix("/") {
            return relativeOrAbsPath
        }
        let root = configuration.rootPath.hasSuffix("/") ? configuration.rootPath : configuration.rootPath + "/"
        return root + relativeOrAbsPath
    }

    public func listDirectory(path: String) async throws -> [RemoteFileEntry] {
        let sftp = try getSFTP()
        let resolved = resolvePath(path)

        do {
            let names = try await sftp.listDirectory(atPath: resolved)
            var entries: [RemoteFileEntry] = []

            for nameMsg in names {
                for item in nameMsg.components {
                    let filename = item.filename
                    if filename == "." || filename == ".." { continue }

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
            throw AdapterError.fileNotFound(path)
        }
    }

    public func stat(path: String) async throws -> RemoteFileEntry {
        let sftp = try getSFTP()
        let resolved = resolvePath(path)

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
            throw AdapterError.fileNotFound(path)
        }
    }

    public func upload(from localURL: URL, to remotePath: String, progress: Progress?) async throws {
        let sftp = try getSFTP()
        let resolved = resolvePath(remotePath)

        guard FileManager.default.fileExists(atPath: localURL.path) else {
            throw AdapterError.fileNotFound(localURL.path)
        }

        let localAttrs = try? FileManager.default.attributesOfItem(atPath: localURL.path)
        let localSize = (localAttrs?[.size] as? Int64) ?? 0

        // SAFEGUARD: Refuse 0-byte overwrite over non-empty remote file
        if localSize == 0 {
            if let remoteStat = try? await stat(path: resolved), remoteStat.size > 0 {
                throw AdapterError.invalidPath("SAFETY SHIELD BLOCKED: Refusing to overwrite remote file '\(resolved)' (\(remoteStat.size) bytes) with local 0-byte file.")
            }
        }

        progress?.totalUnitCount = localSize
        progress?.completedUnitCount = 0

        // Atomic Staging: upload to staging file first
        let stagingSuffix = ".openduck_staging_\(UUID().uuidString.prefix(8))"
        let stagingRemotePath = resolved + stagingSuffix

        let stagingFile = try await sftp.openFile(
            filePath: stagingRemotePath,
            flags: [.write, .create, .truncate]
        )

        do {
            let fileHandle = try FileHandle(forReadingFrom: localURL)
            defer { try? fileHandle.close() }

            let chunkSize = 128 * 1024 // 128 KB streaming chunks
            var offset: UInt64 = 0

            while let chunk = try fileHandle.read(upToCount: chunkSize), !chunk.isEmpty {
                var buffer = ByteBufferAllocator().buffer(capacity: chunk.count)
                buffer.writeBytes(chunk)
                try await stagingFile.write(buffer, at: offset)
                offset += UInt64(chunk.count)
                progress?.completedUnitCount = Int64(offset)
            }

            try await stagingFile.close()
        } catch {
            try? await stagingFile.close()
            try? await sftp.remove(at: stagingRemotePath)
            throw error
        }

        // Atomic Rename staging -> final destination
        do {
            try await sftp.rename(at: stagingRemotePath, to: resolved)
        } catch {
            try? await sftp.remove(at: stagingRemotePath)
            throw AdapterError.networkError("SFTP atomic commit failed: \(error.localizedDescription)")
        }

        progress?.completedUnitCount = localSize
    }

    public func download(remotePath: String, to localURL: URL, progress: Progress?) async throws {
        let sftp = try getSFTP()
        let resolved = resolvePath(remotePath)

        let remoteFile = try await sftp.openFile(filePath: resolved, flags: [.read])
        let attrs = try? await sftp.getAttributes(at: resolved)
        let totalSize = Int64(attrs?.size ?? 0)
        progress?.totalUnitCount = totalSize
        progress?.completedUnitCount = 0

        let byteBuffer = try await remoteFile.readAll()
        try await remoteFile.close()

        let parentDir = localURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        let tempURL = parentDir.appendingPathComponent(".openduck_dl_\(UUID().uuidString)")
        let data = Data(byteBuffer.readableBytesView)
        try data.write(to: tempURL, options: .atomic)

        _ = try? FileManager.default.removeItem(at: localURL)
        try FileManager.default.moveItem(at: tempURL, to: localURL)

        progress?.completedUnitCount = totalSize > 0 ? totalSize : Int64(data.count)
    }

    public func createDirectory(path: String) async throws {
        let sftp = try getSFTP()
        let resolved = resolvePath(path)
        try await sftp.createDirectory(atPath: resolved)
    }

    public func delete(remotePath: String) async throws {
        let sftp = try getSFTP()
        let resolved = resolvePath(remotePath)

        // Try file remove, then directory remove
        do {
            try await sftp.remove(at: resolved)
        } catch {
            try await sftp.rmdir(at: resolved)
        }
    }

    public func move(from sourcePath: String, to destinationPath: String) async throws {
        let sftp = try getSFTP()
        let src = resolvePath(sourcePath)
        let dst = resolvePath(destinationPath)
        try await sftp.rename(at: src, to: dst)
    }
}
