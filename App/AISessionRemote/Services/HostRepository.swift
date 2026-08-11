import AISessionCore
import Foundation
import SwiftData

enum HostRepositoryError: LocalizedError {
    case invalidHostname
    case invalidUsername
    case invalidPort
    case missingPrivateKey

    var errorDescription: String? {
        switch self {
        case .invalidHostname: "Hostname is required."
        case .invalidUsername: "Username is required."
        case .invalidPort: "Port must be between 1 and 65535."
        case .missingPrivateKey: "A PEM private key is required."
        }
    }
}

@MainActor
final class HostRepository {
    private let modelContext: ModelContext
    private let keychain: KeychainPrivateKeyStore
    private let hostKeyStore: TOFUHostKeyStore

    init(
        modelContext: ModelContext,
        keychain: KeychainPrivateKeyStore = .init(),
        hostKeyStore: TOFUHostKeyStore = .init()
    ) {
        self.modelContext = modelContext
        self.keychain = keychain
        self.hostKeyStore = hostKeyStore
    }

    @discardableResult
    func create(
        displayName: String,
        hostname: String,
        port: Int,
        username: String,
        pem: String,
        defaultPaths: [String],
        cliBinaries: [AITool: String]
    ) throws -> HostEntity {
        try validate(hostname: hostname, port: port, username: username, pem: pem, requiresPEM: true)

        let host = HostEntity(
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            hostname: hostname.trimmingCharacters(in: .whitespacesAndNewlines),
            port: port,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            defaultPaths: defaultPaths,
            cliBinaries: cliBinaries
        )
        try keychain.save(account: host.privateKeyKeychainRef, pem: Data(pem.utf8))
        modelContext.insert(host)
        do {
            try modelContext.save()
        } catch {
            try? keychain.delete(account: host.privateKeyKeychainRef)
            throw error
        }
        return host
    }

    func update(
        _ host: HostEntity,
        displayName: String,
        hostname: String,
        port: Int,
        username: String,
        pem: String,
        defaultPaths: [String],
        cliBinaries: [AITool: String]
    ) throws {
        try validate(hostname: hostname, port: port, username: username, pem: pem, requiresPEM: true)
        try keychain.save(account: host.privateKeyKeychainRef, pem: Data(pem.utf8))
        host.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        host.hostname = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        host.port = port
        host.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        host.defaultPaths = defaultPaths
        host.cliBinaries = cliBinaries
        try modelContext.save()
    }

    func delete(_ host: HostEntity) throws {
        let pem: Data?
        do {
            pem = try keychain.load(account: host.privateKeyKeychainRef)
        } catch KeychainPrivateKeyStoreError.itemNotFound {
            pem = nil
        }
        try keychain.delete(account: host.privateKeyKeychainRef)
        modelContext.delete(host)
        do {
            try modelContext.save()
        } catch {
            let saveError = error
            modelContext.rollback()
            if let pem {
                try keychain.save(account: host.privateKeyKeychainRef, pem: pem)
            }
            throw saveError
        }
        // Only clear the TOFU fingerprint once the delete has actually committed — a future
        // host reusing this hostname/port shouldn't inherit a stale trusted key, but a host we
        // just restored above (after a failed save) still should.
        hostKeyStore.forget(hostID: host.id.uuidString)
    }

    /// Clears the trusted host-key fingerprint for `host` without deleting the host itself.
    /// Surfaced in the UI as "Forget host key" for when a host's key legitimately changed
    /// (reinstall, key rotation) and the stored TOFU fingerprint needs to be reset.
    func forgetHostKey(for host: HostEntity) {
        hostKeyStore.forget(hostID: host.id.uuidString)
    }

    func privateKey(for host: HostEntity) throws -> String {
        guard let pem = String(data: try keychain.load(account: host.privateKeyKeychainRef), encoding: .utf8) else {
            throw KeychainPrivateKeyStoreError.invalidData
        }
        return pem
    }

    private func validate(
        hostname: String,
        port: Int,
        username: String,
        pem: String,
        requiresPEM: Bool
    ) throws {
        guard !hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HostRepositoryError.invalidHostname
        }
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HostRepositoryError.invalidUsername
        }
        guard (1...65535).contains(port) else {
            throw HostRepositoryError.invalidPort
        }
        if requiresPEM && pem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw HostRepositoryError.missingPrivateKey
        }
    }
}
