import AISessionCore

/// One live, authenticated SSH connection that can vend child channels.
///
/// Exists as a protocol so `SSHConnectionPool` — which owns all the interesting logic around
/// coalescing, leases, eviction and retry — can be tested without a network.
protocol PooledConnecting: AnyObject, Sendable {
    /// `false` once the connection has been observed to fail or has been closed. The pool uses
    /// this to avoid handing out a connection it already knows is dead.
    ///
    /// A single command failing (e.g. the remote host transiently refused a new channel) must
    /// not, by itself, flip this to `false` — only evidence that the underlying transport itself
    /// is gone should. Conflating the two would tear down one shared connection out from under
    /// every other in-flight command on the same host just because one command's channel setup
    /// hit a transient, per-channel failure.
    var isAlive: Bool { get }

    /// Opens a session channel, runs `command`, and returns once it exits or `timeoutSeconds`
    /// elapses.
    ///
    /// The timeout is a property of this one command, not of the connection: it is passed on
    /// every call rather than fixed at dial time, so one connection can safely serve commands
    /// with different timeout expectations (e.g. a fast-fail reachability probe and a real
    /// session command against the same host) without either one silently inheriting the
    /// other's budget.
    func exec(_ command: String, timeoutSeconds: Int64) async throws -> SSHExecResult

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
