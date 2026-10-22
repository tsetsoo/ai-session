import AISessionCore
import Foundation

struct SessionServiceFactory {
    private let keychain: KeychainPrivateKeyStore

    init(keychain: KeychainPrivateKeyStore = .init()) {
        self.keychain = keychain
    }

    func make(for host: HostEntity) throws -> (service: SessionService, config: HostConnectionConfig) {
        let pem = try keychain.load(account: host.privateKeyKeychainRef)
        // An empty item is as good as none; ComputerErrorText words both as a missing key.
        guard !pem.isEmpty else {
            throw KeychainPrivateKeyStoreError.itemNotFound
        }

        let config = HostConnectionConfig(
            host: host.hostname,
            port: host.port,
            username: host.username,
            privateKeyPEM: pem,
            hostID: host.id.uuidString
        )
        return (
            service: SessionService(
                ssh: NIOSSHClient(),
                binaryOverrides: host.cliBinaries
            ),
            config: config
        )
    }
}
