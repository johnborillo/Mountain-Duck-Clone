import Foundation
import Security

/// macOS Keychain Services bridge for securely persisting secrets without plain-text disk storage.
public final class KeychainHelper: Sendable {
    public static let shared = KeychainHelper()
    private let serviceName = "com.openduck.credentials"

    public init() {}

    /// Save or update a secret in the macOS Keychain.
    @discardableResult
    public func saveSecret(_ secret: String, for profileID: UUID, account: String) -> Bool {
        guard let data = secret.data(using: .utf8) else { return false }
        let service = "\(serviceName).\(profileID.uuidString)"

        // Delete existing item if present
        deleteSecret(for: profileID)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Read a secret from the macOS Keychain.
    public func loadSecret(for profileID: UUID) -> String? {
        let service = "\(serviceName).\(profileID.uuidString)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    /// Delete a secret from the macOS Keychain.
    @discardableResult
    public func deleteSecret(for profileID: UUID) -> Bool {
        let service = "\(serviceName).\(profileID.uuidString)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
