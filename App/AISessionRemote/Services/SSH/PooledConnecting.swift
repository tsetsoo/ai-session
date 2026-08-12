import AISessionCore

/// One live, authenticated SSH connection that can vend child channels.
///
/// Exists as a protocol so `SSHConnectionPool` — which owns all the interesting logic around
/// coalescing, leases, eviction and retry — can be tested without a network.
protocol PooledConnecting: AnyObject, Sendable {
    /// `false` once the connection has been observed to fail or has been closed. The pool uses
    /// this to avoid handing out a connection it already knows is dead.
    var isAlive: Bool { get }

    /// Opens a session channel, runs `command`, and returns once it exits.
    func exec(_ command: String) async throws -> SSHExecResult

    func close() async
}
