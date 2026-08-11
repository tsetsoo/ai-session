import Foundation

public struct HostConnectionConfig: Equatable, Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var privateKeyPEM: Data
    /// Stable identifier for this host — `HostEntity.id.uuidString` in practice — used by the
    /// app layer to key its TOFU host-key store. Keying by `id` rather than `host:port` means a
    /// host's trusted fingerprint moves (or is reset) with the host record itself: editing the
    /// hostname doesn't silently detach it from its trusted key, and deleting the host can
    /// reliably clear it. Defaults to `host:port` for callers (tests, older call sites) that
    /// don't have a durable host identity to pass.
    public var hostID: String

    public init(host: String, port: Int, username: String, privateKeyPEM: Data, hostID: String? = nil) {
        self.host = host
        self.port = port
        self.username = username
        self.privateKeyPEM = privateKeyPEM
        self.hostID = hostID ?? "\(host):\(port)"
    }
}
