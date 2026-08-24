import Foundation

/// Central registry managing the lifecycle of active remote connection adapters.
public final class ConnectionManager: @unchecked Sendable {
    public static let shared = ConnectionManager()

    private let lock = NSLock()
    private var activeAdapters: [UUID: RemoteFilesystemAdapter] = [:]
    private var profiles: [UUID: ServerProfile] = [:]

    public let keychain: KeychainHelper

    public init(keychain: KeychainHelper = .shared) {
        self.keychain = keychain
    }

    private func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Register a server profile configuration.
    public func registerProfile(_ profile: ServerProfile) {
        sync {
            profiles[profile.id] = profile
        }
    }

    /// Retrieve all registered server profiles.
    public func allProfiles() -> [ServerProfile] {
        sync {
            Array(profiles.values).sorted { $0.name < $1.name }
        }
    }

    /// Connect to a profile and return the instantiated adapter.
    public func connect(to profileID: UUID) async throws -> RemoteFilesystemAdapter {
        let (profile, existing): (ServerProfile, RemoteFilesystemAdapter?) = try sync {
            guard let p = profiles[profileID] else {
                throw AdapterError.invalidPath("Server profile not found: \(profileID)")
            }
            if let active = activeAdapters[profileID], active.isConnected {
                return (p, active)
            }
            return (p, nil)
        }

        if let existing {
            return existing
        }

        let adapter = try createAdapter(for: profile)
        try await adapter.connect()

        sync {
            activeAdapters[profileID] = adapter
            var updated = profile
            updated.lastConnectedAt = Date()
            profiles[profileID] = updated
        }

        return adapter
    }

    /// Disconnect an active connection.
    public func disconnect(from profileID: UUID) async {
        let adapter: RemoteFilesystemAdapter? = sync {
            activeAdapters.removeValue(forKey: profileID)
        }

        if let adapter {
            await adapter.disconnect()
        }
    }

    /// Get active adapter for a given profile ID.
    public func activeAdapter(for profileID: UUID) -> RemoteFilesystemAdapter? {
        sync {
            activeAdapters[profileID]
        }
    }

    /// Register a pre-constructed adapter (useful for mock testing).
    public func registerActiveAdapter(_ adapter: RemoteFilesystemAdapter, for profileID: UUID) {
        sync {
            activeAdapters[profileID] = adapter
        }
    }

    private func createAdapter(for profile: ServerProfile) throws -> RemoteFilesystemAdapter {
        switch profile.protocolType {
        case .sftp:
            let secret = keychain.loadSecret(for: profile.id) ?? ""
            let authMethod: SFTPAuthMethod
            switch profile.authType {
            case .password:
                authMethod = .password(secret)
            case .sshKey:
                authMethod = .privateKey(keyPath: profile.privateKeyPath ?? "", passphrase: secret.isEmpty ? nil : secret)
            case .anonymous:
                authMethod = .agent
            }

            let config = SFTPConfiguration(
                host: profile.host,
                port: profile.port,
                username: profile.username,
                authMethod: authMethod,
                rootPath: profile.remoteRootPath
            )
            return SFTPAdapter(configuration: config)

        case .mock:
            return MockFileSystemAdapter(endpointDescription: "mock://\(profile.name)")

        case .s3, .webdav:
            throw AdapterError.unsupportedOperation("Protocol \(profile.protocolType.rawValue) is not yet supported in this build.")
        }
    }
}
