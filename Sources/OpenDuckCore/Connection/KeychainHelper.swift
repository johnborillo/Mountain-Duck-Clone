import Foundation
import Security

public struct KeychainAccessError: Error, LocalizedError, Sendable {
    public let operation: String
    public let status: OSStatus

    public var errorDescription: String? {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "Keychain \(operation) failed (\(status)): \(detail)"
    }
}

/// macOS Keychain Services bridge for credentials shared by the containing app
/// and its File Provider extension.
public final class KeychainHelper: @unchecked Sendable {
    public static let shared = KeychainHelper()

    private let serviceName = "com.openduck.credentials"
    private let accessGroup: String?

    /// Bundled OpenDuck processes use the App Group as an explicit shared
    /// keychain access group. Tests and the standalone CLI use their default
    /// access group because they do not carry the app's entitlements.
    public init(accessGroup: String? = KeychainHelper.defaultAccessGroup) {
        self.accessGroup = accessGroup
    }

    public static var defaultAccessGroup: String? {
        guard OpenDuckSharedStorage.isBundledOpenDuckProcess,
              let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(
                task,
                "keychain-access-groups" as CFString,
                nil
              ) as? [String],
              groups.contains(OpenDuckSharedStorage.keychainAccessGroup) else {
            return nil
        }
        return OpenDuckSharedStorage.keychainAccessGroup
    }

    @discardableResult
    public func saveSecret(_ secret: String, for profileID: UUID, account: String) -> Bool {
        (try? saveSecretOrThrow(secret, for: profileID, account: account)) != nil
    }

    public func saveSecretOrThrow(_ secret: String, for profileID: UUID, account: String) throws {
        guard let data = secret.data(using: .utf8) else {
            throw KeychainAccessError(operation: "encoding", status: errSecParam)
        }

        let service = serviceIdentifier(for: profileID)
        let attributes: [String: Any] = [
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        var match = baseQuery(service: service)
        let updateStatus = SecItemUpdate(match as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainAccessError(operation: "update", status: updateStatus)
        }

        match.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(match as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainAccessError(operation: "save", status: addStatus)
        }
    }

    public func loadSecret(for profileID: UUID) -> String? {
        try? loadSecretOrThrow(for: profileID)
    }

    public func loadSecretOrThrow(for profileID: UUID) throws -> String? {
        var query = baseQuery(service: serviceIdentifier(for: profileID))
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainAccessError(operation: "read", status: status)
        }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public func deleteSecret(for profileID: UUID) -> Bool {
        let status = SecItemDelete(baseQuery(service: serviceIdentifier(for: profileID)) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Moves credentials written by pre-sharing builds from the host app's
    /// private keychain group into the group readable by the extension.
    @discardableResult
    public func migrateLegacySecret(for profileID: UUID, account: String) throws -> Bool {
        guard accessGroup != nil else { return false }
        if try loadSecretOrThrow(for: profileID) != nil { return false }

        let legacy = KeychainHelper(accessGroup: nil)
        guard let secret = try legacy.loadSecretOrThrow(for: profileID) else { return false }
        try saveSecretOrThrow(secret, for: profileID, account: account)
        _ = legacy.deleteSecret(for: profileID)
        return true
    }

    private func serviceIdentifier(for profileID: UUID) -> String {
        "\(serviceName).\(profileID.uuidString)"
    }

    private func baseQuery(service: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        addAccessGroup(to: &query)
        return query
    }

    private func addAccessGroup(to query: inout [String: Any]) {
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
    }
}
