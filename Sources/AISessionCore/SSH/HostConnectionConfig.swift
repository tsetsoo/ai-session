import Foundation

public struct HostConnectionConfig: Equatable, Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var privateKeyPEM: Data

    public init(host: String, port: Int, username: String, privateKeyPEM: Data) {
        self.host = host
        self.port = port
        self.username = username
        self.privateKeyPEM = privateKeyPEM
    }
}
