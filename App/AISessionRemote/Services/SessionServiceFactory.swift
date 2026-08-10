import AISessionCore
import Foundation

enum SessionServiceFactoryError: LocalizedError {
    case missingPrivateKey

    var errorDescription: String? {
        switch self {
        case .missingPrivateKey:
            "The private key for this host is unavailable. Edit the host and save its key again."
        }
    }
}

struct SessionServiceFactory {
    private let keychain: KeychainPrivateKeyStore

    init(keychain: KeychainPrivateKeyStore = .init()) {
        self.keychain = keychain
    }

    func make(for host: HostEntity) throws -> (service: SessionService, config: HostConnectionConfig) {
        let pem = try keychain.load(account: host.privateKeyKeychainRef)
        guard !pem.isEmpty else {
            throw SessionServiceFactoryError.missingPrivateKey
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
