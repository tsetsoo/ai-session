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

    /// Closes the connection and releases its underlying resources.
    ///
    /// Must be idempotent, including under concurrent calls: more than one caller can decide to
    /// close the same connection independently, with no coordination between them — for
    /// example, several callers coalesced onto one dial that gets superseded by a pool
    /// teardown while they were all still waiting on it, each of which reacts by closing the
    /// connection it was handed. A second (or third, ...) `close()` must be a safe no-op, not
    /// a crash or a thrown error.
    func close() async
}
