import Foundation

/// Small generic Keychain store for string secrets (e.g. the todo hub API token).
/// Reuses `KeychainPrivateKeyStore`'s storage rules under a different service name.
public struct KeychainStringStore: Sendable {
    public let service: String

    public init(service: String) {
        self.service = service
    }

    public func save(account: String, value: String) throws {
        try store.save(account: account, pem: Data(value.utf8))
    }

    /// Returns `nil` when nothing is stored.
    public func load(account: String) throws -> String? {
        do {
            return String(decoding: try store.load(account: account), as: UTF8.self)
        } catch KeychainPrivateKeyStoreError.itemNotFound {
            return nil
        }
    }

    public func delete(account: String) throws {
        try store.delete(account: account)
    }

    private var store: KeychainPrivateKeyStore { KeychainPrivateKeyStore(service: service) }
}
