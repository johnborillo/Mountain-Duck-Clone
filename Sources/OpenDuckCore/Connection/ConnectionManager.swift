import Foundation

/// Central registry managing the lifecycle of active remote connection adapters.
public final class ConnectionManager: @unchecked Sendable {
    public static let shared = ConnectionManager()

    private let lock = NSLock()
    private var activeAdapters: [UUID: RemoteFilesystemAdapter] = [:]
    private var profiles: [UUID: ServerProfile] = [:]

    private static let userDefaultsKey = "com.openduck.serverProfiles"
    public let keychain: KeychainHelper
    public let keyBookmarks: SSHKeyBookmarkStore
    private let userDefaults: UserDefaults

    public init(
        keychain: KeychainHelper = .shared,
        keyBookmarks: SSHKeyBookmarkStore = .shared,
        userDefaults: UserDefaults? = nil
    ) {
        self.keychain = keychain
        self.keyBookmarks = keyBookmarks
        self.userDefaults = userDefaults ?? OpenDuckSharedStorage.userDefaults
        loadPersistedProfiles()
    }

    private func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func loadPersistedProfiles() {
        guard let data = userDefaults.data(forKey: Self.userDefaultsKey),
              let decoded = try? JSONDecoder().decode([ServerProfile].self, from: data) else {
            return
        }
        sync {
            for profile in decoded {
                profiles[profile.id] = profile
            }
        }
    }

    private func saveProfilesToDisk() {
        let all = sync { Array(profiles.values) }
        if let data = try? JSONEncoder().encode(all) {
            userDefaults.set(data, forKey: Self.userDefaultsKey)
        }
    }

    /// Register a server profile configuration.
    public func registerProfile(_ profile: ServerProfile) {
        sync {
            profiles[profile.id] = profile
        }
        saveProfilesToDisk()
    }

    /// Update an existing server profile and optionally update its keychain secret.
    public func updateProfile(_ profile: ServerProfile, secret: String? = nil) {
        sync {
            profiles[profile.id] = profile
        }
        if let secret = secret, !secret.isEmpty {
            keychain.saveSecret(secret, for: profile.id, account: profile.username)
        }
        saveProfilesToDisk()
    }

    /// Delete a server profile, disconnect any active adapter, and purge credentials.
    public func deleteProfile(id: UUID) {
        let adapterToDisconnect: RemoteFilesystemAdapter? = sync {
            profiles.removeValue(forKey: id)
            return activeAdapters.removeValue(forKey: id)
        }
        if let adapter = adapterToDisconnect {
            Task {
                await adapter.disconnect()
            }
        }
        keychain.deleteSecret(for: id)
        keyBookmarks.deleteBookmark(for: id)
        saveProfilesToDisk()
    }

    public func savePrivateKeyBookmark(_ bookmark: Data, for profileID: UUID) {
        keyBookmarks.saveBookmark(bookmark, for: profileID)
    }

    public func savePrivateKeyAccess(
        bookmark: Data,
        keyData: Data,
        for profileID: UUID
    ) throws {
        try keyBookmarks.importPrivateKeyData(keyData, for: profileID)
        keyBookmarks.saveBookmark(bookmark, for: profileID)
    }

    public func hasPrivateKeyBookmark(for profileID: UUID) -> Bool {
        keyBookmarks.hasBookmark(for: profileID)
    }

    /// Run by the containing app after an upgrade from builds whose credentials
    /// were private to the host's keychain group.
    @discardableResult
    public func migrateLegacyCredentials() throws -> Int {
        var migrated = 0
        for profile in allProfiles() {
            if try keychain.migrateLegacySecret(for: profile.id, account: profile.username) {
                migrated += 1
            }
        }
        return migrated
    }

    /// Retrieve a specific server profile by its unique ID.
    public func profile(for id: UUID) -> ServerProfile? {
        sync {
            profiles[id]
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
            let secret: String
            do {
                secret = try keychain.loadSecretOrThrow(for: profile.id) ?? ""
            } catch {
                throw AdapterError.authenticationFailed(error.localizedDescription)
            }
            let authMethod: SFTPAuthMethod
            switch profile.authType {
            case .password:
                authMethod = .password(secret)
            case .sshKey:
                if keyBookmarks.hasBookmark(for: profile.id) {
                    do {
                        let keyData = try keyBookmarks.loadPrivateKeyData(for: profile.id)
                        authMethod = .privateKeyData(keyData, passphrase: secret.isEmpty ? nil : secret)
                    } catch {
                        throw AdapterError.authenticationFailed(error.localizedDescription)
                    }
                } else if OpenDuckSharedStorage.isBundledOpenDuckProcess {
                    throw AdapterError.authenticationFailed(SSHKeyBookmarkError.missingBookmark.localizedDescription)
                } else {
                    authMethod = .privateKey(
                        keyPath: profile.privateKeyPath ?? "",
                        passphrase: secret.isEmpty ? nil : secret
                    )
                }
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
