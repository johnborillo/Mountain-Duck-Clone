import Foundation

/// Supported protocol schemes for remote connections.
public enum RemoteProtocol: String, Codable, Sendable, CaseIterable {
    case sftp = "SFTP"
    case s3 = "Amazon S3"
    case webdav = "WebDAV"
    case mock = "Mock / Offline Simulation"
}

/// Authentication type used for establishing a remote connection.
public enum AuthenticationType: String, Codable, Sendable {
    case password
    case sshKey
}

/// Persistent profile describing a remote server configuration.
public struct ServerProfile: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var protocolType: RemoteProtocol
    public var host: String
    public var port: Int
    public var username: String
    public var authType: AuthenticationType
    public var privateKeyPath: String?
    public var remoteRootPath: String
    public var autoConnect: Bool
    public var isReadOnly: Bool
    public var createdAt: Date
    public var lastConnectedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        protocolType: RemoteProtocol = .sftp,
        host: String = "localhost",
        port: Int = 22,
        username: String = "",
        authType: AuthenticationType = .password,
        privateKeyPath: String? = nil,
        remoteRootPath: String = "/",
        autoConnect: Bool = false,
        isReadOnly: Bool = true,
        createdAt: Date = Date(),
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.protocolType = protocolType
        self.host = host
        self.port = port
        self.username = username
        self.authType = authType
        self.privateKeyPath = privateKeyPath
        self.remoteRootPath = remoteRootPath
        self.autoConnect = autoConnect
        self.isReadOnly = isReadOnly
        self.createdAt = createdAt
        self.lastConnectedAt = lastConnectedAt
    }
}
