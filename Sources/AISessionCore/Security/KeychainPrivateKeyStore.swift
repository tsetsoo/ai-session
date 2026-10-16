import Foundation

#if canImport(Security)
import Security
#endif

public enum KeychainPrivateKeyStoreError: Error, Equatable, Sendable {
    case unavailable
    case itemNotFound
    case invalidData
    case saveFailed(OSStatus)
    case loadFailed(OSStatus)
    case deleteFailed(OSStatus)
}

/// Stores SSH private keys in the Keychain. Account = host id UUID string.
public struct KeychainPrivateKeyStore: Sendable {
    public static let service = "com.aisessionremote.keys"

    /// Keychain service the items are stored under (`KeychainStringStore` uses its own).
    public let service: String

    public init(service: String = KeychainPrivateKeyStore.service) {
        self.service = service
    }

    public func save(account: String, pem: Data) throws {
        #if canImport(Security)
        try delete(account: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: pem,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainPrivateKeyStoreError.saveFailed(status)
        }
        #else
        throw KeychainPrivateKeyStoreError.unavailable
        #endif
    }

    public func load(account: String) throws -> Data {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainPrivateKeyStoreError.invalidData
            }
            return data
        case errSecItemNotFound:
            throw KeychainPrivateKeyStoreError.itemNotFound
        default:
            throw KeychainPrivateKeyStoreError.loadFailed(status)
        }
        #else
        throw KeychainPrivateKeyStoreError.unavailable
        #endif
    }

    public func delete(account: String) throws {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainPrivateKeyStoreError.deleteFailed(status)
        }
        #else
        throw KeychainPrivateKeyStoreError.unavailable
        #endif
    }
}
