import Foundation

/// Authentication credentials for SFTP connections.
public enum SFTPAuthMethod: Sendable {
    case password(String)
    case privateKey(keyPath: String, passphrase: String?)
    case agent
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
        authMethod: SFTPAuthMethod = .agent,
        rootPath: String = "/",
        connectionTimeout: TimeInterval = 10.0
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.rootPath = rootPath
        self.connectionTimeout = connectionTimeout
    }
}

/// Production OpenSSH-backed SFTP Filesystem Adapter implementing `RemoteFilesystemAdapter`.
public final class SFTPAdapter: RemoteFilesystemAdapter, @unchecked Sendable {
    public let configuration: SFTPConfiguration
    private let lock = NSLock()
    private var _isConnected: Bool = false

    public var endpointDescription: String {
        return "sftp://\(configuration.username)@\(configuration.host):\(configuration.port)\(configuration.rootPath)"
    }

    public init(configuration: SFTPConfiguration) {
        self.configuration = configuration
    }

    private func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    public var isConnected: Bool {
        sync { _isConnected }
    }

    public func connect() async throws {
        // Verify remote connectivity and authentication via quick SSH probe
        let probeResult = try await executeSSHCommand("true")
        if probeResult.exitCode != 0 {
            let errorMsg = probeResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AdapterError.authenticationFailed(errorMsg.isEmpty ? "SSH connection refused or authentication failed" : errorMsg)
        }

        sync {
            _isConnected = true
        }
    }

    public func disconnect() async {
        sync {
            _isConnected = false
        }
    }

    public func listDirectory(path: String) async throws -> [RemoteFileEntry] {
        guard isConnected else { throw AdapterError.notConnected }
        let resolved = resolvePath(path)

        // SFTP command: ls -la "<path>"
        let batchCommands = "ls -la \"\(escapePath(resolved))\"\n"
        let output = try await executeSFTPBatch(batchCommands)

        if output.exitCode != 0 && output.stdout.isEmpty {
            throw AdapterError.fileNotFound(path)
        }

        return parseSFTPDirectoryListing(output.stdout, parentPath: resolved)
    }

    public func stat(path: String) async throws -> RemoteFileEntry {
        guard isConnected else { throw AdapterError.notConnected }
        let resolved = resolvePath(path)

        if resolved == "/" || resolved.isEmpty {
            return RemoteFileEntry(name: "/", path: "/", itemType: .directory, size: 0, modificationDate: Date())
        }

        let batchCommands = "ls -l \"\(escapePath(resolved))\"\n"
        let output = try await executeSFTPBatch(batchCommands)

        if output.exitCode != 0 || output.stdout.contains("not found") || output.stderr.contains("not found") || output.stderr.contains("No such file") {
            throw AdapterError.fileNotFound(resolved)
        }

        let entries = parseSFTPDirectoryListing(output.stdout, parentPath: (resolved as NSString).deletingLastPathComponent)
        if let first = entries.first {
            return first
        }

        throw AdapterError.fileNotFound(resolved)
    }

    public func download(remotePath: String, to localURL: URL, progress: Progress?) async throws {
        guard isConnected else { throw AdapterError.notConnected }
        let resolved = resolvePath(remotePath)

        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let batchCommands = "get \"\(escapePath(resolved))\" \"\(escapePath(localURL.path))\"\n"
        let output = try await executeSFTPBatch(batchCommands)

        if output.exitCode != 0 || !FileManager.default.fileExists(atPath: localURL.path) {
            throw AdapterError.networkError(output.stderr.isEmpty ? "SFTP download failed for \(remotePath)" : output.stderr)
        }

        progress?.completedUnitCount = 100
        progress?.totalUnitCount = 100
    }

    public func upload(from localURL: URL, to remotePath: String, progress: Progress?) async throws {
        guard isConnected else { throw AdapterError.notConnected }
        let resolved = resolvePath(remotePath)

        guard FileManager.default.fileExists(atPath: localURL.path) else {
            throw AdapterError.fileNotFound(localURL.path)
        }

        let localAttrs = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let localSize = (localAttrs[.size] as? Int64) ?? 0

        // =========================================================================
        // SAFEGUARD LAYER 1: HARD OVERWRITE PROTECTION
        // Never allow a 0-byte local placeholder to overwrite an existing remote file
        // =========================================================================
        if let remoteStat = try? await stat(path: resolved) {
            if remoteStat.size > 0 && localSize == 0 {
                let errorMsg = "SAFETY SHIELD BLOCKED: Refusing to overwrite remote file '\(resolved)' (\(remoteStat.size) bytes) with local 0-byte file."
                print("🛑 [OpenDuck Safety Shield] \(errorMsg)")
                throw AdapterError.invalidPath(errorMsg)
            }
        }

        // =========================================================================
        // SAFEGUARD LAYER 2: ATOMIC STAGING UPLOAD & SAFE RENAME
        // Upload to a temporary staging file first, then atomically rename.
        // If upload is interrupted or fails, the original remote file is never corrupted.
        // =========================================================================
        let stagingSuffix = ".openduck_staging_\(UUID().uuidString.prefix(8))"
        let stagingRemotePath = resolved + stagingSuffix

        // Step 1: Put to staging path
        let uploadBatch = "put \"\(escapePath(localURL.path))\" \"\(escapePath(stagingRemotePath))\"\n"
        let uploadOutput = try await executeSFTPBatch(uploadBatch)

        if uploadOutput.exitCode != 0 {
            // Clean up staging file if any partial was left
            _ = try? await executeSFTPBatch("rm \"\(escapePath(stagingRemotePath))\"\n")
            throw AdapterError.networkError(uploadOutput.stderr.isEmpty ? "SFTP upload failed for \(remotePath)" : uploadOutput.stderr)
        }

        // Step 2: Atomic rename staging -> final destination
        let renameBatch = "rename \"\(escapePath(stagingRemotePath))\" \"\(escapePath(resolved))\"\n"
        let renameOutput = try await executeSFTPBatch(renameBatch)

        if renameOutput.exitCode != 0 {
            // Clean up staging file
            _ = try? await executeSFTPBatch("rm \"\(escapePath(stagingRemotePath))\"\n")
            throw AdapterError.networkError("SFTP atomic commit failed: \(renameOutput.stderr)")
        }

        progress?.completedUnitCount = 100
        progress?.totalUnitCount = 100
    }

    public func createDirectory(path: String) async throws {
        guard isConnected else { throw AdapterError.notConnected }
        let resolved = resolvePath(path)

        let batchCommands = "mkdir \"\(escapePath(resolved))\"\n"
        _ = try await executeSFTPBatch(batchCommands)
    }

    public func delete(remotePath: String) async throws {
        guard isConnected else { throw AdapterError.notConnected }
        let resolved = resolvePath(remotePath)

        // Try file remove then directory remove
        let batchCommands = "rm \"\(escapePath(resolved))\"\nrmdir \"\(escapePath(resolved))\"\n"
        _ = try await executeSFTPBatch(batchCommands)
    }

    public func move(from sourcePath: String, to destinationPath: String) async throws {
        guard isConnected else { throw AdapterError.notConnected }
        let src = resolvePath(sourcePath)
        let dst = resolvePath(destinationPath)

        let batchCommands = "rename \"\(escapePath(src))\" \"\(escapePath(dst))\"\n"
        let output = try await executeSFTPBatch(batchCommands)

        if output.exitCode != 0 {
            throw AdapterError.networkError("SFTP rename failed: \(output.stderr)")
        }
    }

    // MARK: - OpenSSH Subprocess Pipeline

    private func executeSFTPBatch(_ commands: String) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")

                var args = [
                    "-P", "\(self.configuration.port)",
                    "-o", "StrictHostKeyChecking=accept-new",
                    "-o", "ConnectTimeout=\(Int(self.configuration.connectionTimeout))",
                    "-b", "-"
                ]

                if case .privateKey(let keyPath, _) = self.configuration.authMethod, !keyPath.isEmpty {
                    args.append(contentsOf: ["-i", NSString(string: keyPath).expandingTildeInPath])
                }

                if case .agent = self.configuration.authMethod {
                    args.append(contentsOf: ["-o", "BatchMode=yes"])
                }

                let target = "\(self.configuration.username)@\(self.configuration.host)"
                args.append(target)
                process.arguments = args

                let stdinPipe = Pipe()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()

                process.standardInput = stdinPipe
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()

                    if let data = commands.data(using: .utf8) {
                        stdinPipe.fileHandleForWriting.write(data)
                    }
                    try? stdinPipe.fileHandleForWriting.close()

                    process.waitUntilExit()

                    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                    let stdoutStr = String(data: stdoutData, encoding: .utf8) ?? ""
                    let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""

                    continuation.resume(returning: (stdoutStr, stderrStr, process.terminationStatus))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func executeSSHCommand(_ command: String) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")

                var args = [
                    "-p", "\(self.configuration.port)",
                    "-o", "StrictHostKeyChecking=accept-new",
                    "-o", "ConnectTimeout=\(Int(self.configuration.connectionTimeout))",
                    "-o", "BatchMode=yes"
                ]

                if case .privateKey(let keyPath, _) = self.configuration.authMethod, !keyPath.isEmpty {
                    args.append(contentsOf: ["-i", NSString(string: keyPath).expandingTildeInPath])
                }

                let target = "\(self.configuration.username)@\(self.configuration.host)"
                args.append(target)
                args.append(command)
                process.arguments = args

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()

                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                    let stdoutStr = String(data: stdoutData, encoding: .utf8) ?? ""
                    let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""

                    continuation.resume(returning: (stdoutStr, stderrStr, process.terminationStatus))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - POSIX Listing Parser

    private func parseSFTPDirectoryListing(_ output: String, parentPath: String) -> [RemoteFileEntry] {
        var results: [RemoteFileEntry] = []
        let lines = output.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("sftp>") else { continue }

            // Line format: drwxr-xr-x  ? user  group  4096 Aug 23 19:30 /full/path/foldername
            //           or: drwxr-xr-x  2 user  group  4096 Aug 23 19:30 foldername
            let tokens = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard tokens.count >= 9 else { continue }

            let permissionsStr = String(tokens[0])
            guard permissionsStr.count >= 10 else { continue }

            let isDir = permissionsStr.hasPrefix("d")
            let isSymlink = permissionsStr.hasPrefix("l")
            let size = Int64(tokens[4]) ?? 0

            // Filename is everything after the 8th token (timestamp)
            // May be a full path (e.g. /var/data/files) or just a name (files)
            let rawName = tokens[8...].joined(separator: " ")

            // Extract basename — the actual file/folder name without path prefix
            let basename = (rawName as NSString).lastPathComponent

            // Filter out dot-entries (. and ..) using basename
            guard basename != "." && basename != ".." else { continue }

            // Skip hidden OS metadata files
            guard !basename.hasPrefix("._") else { continue }

            // Build full remote path:
            // If the server returned a full absolute path, use it directly
            // Otherwise, construct it from the parent path
            let fullPath: String
            if rawName.hasPrefix("/") {
                fullPath = rawName
            } else {
                fullPath = parentPath == "/" ? "/\(rawName)" : "\(parentPath)/\(rawName)"
            }

            let itemType: RemoteItemType = isDir ? .directory : (isSymlink ? .symbolicLink : .file)

            results.append(RemoteFileEntry(
                name: basename,
                path: fullPath,
                itemType: itemType,
                size: size,
                modificationDate: Date()
            ))
        }

        return results
    }

    private func resolvePath(_ path: String) -> String {
        if path == "/" || path.isEmpty {
            return configuration.rootPath
        }
        let clean = (path as NSString).standardizingPath
        if clean.hasPrefix("/") {
            return clean
        }
        return (configuration.rootPath as NSString).appendingPathComponent(clean)
    }

    private func escapePath(_ path: String) -> String {
        return path.replacingOccurrences(of: "\"", with: "\\\"")
    }
}
