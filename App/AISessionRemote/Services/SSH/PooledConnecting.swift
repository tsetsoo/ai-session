import AISessionCore

/// Thrown by a `PooledConnecting.exec` implementation, instead of the plain `SSHRemoteError` it
/// wraps, when the failure happened while opening the child channel used to run the command —
/// i.e. provably *before* the command could have been delivered to the host, whether that's an
/// explicit channel-open rejection or the parent transport already being gone by the time `exec`
/// was called.
///
/// This is the only failure category `SSHConnectionPool`'s retry-once logic may safely re-run:
/// nothing was sent to the remote host, so re-running the command cannot duplicate a side
/// effect. Every other failure — in particular anything that happens *after* the child channel
/// opened, such as a command timeout or the channel dying mid-command — must propagate as the
/// plain `SSHRemoteError` instead, so the pool never mistakes "the command may already have run"
/// for "it's safe to try again" (e.g. re-running `tmux new-session` after a lost reply would
/// create a second, differently-named session instead of just retrying the failed one).
struct SSHChannelOpenFailure: Error {
    let underlying: Error
}

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

    /// Opens a PTY channel on this connection and execs the attach command, keeping the
    /// channel open for the life of the terminal screen instead of tearing it down after a
    /// single command the way `exec` does.
    ///
    /// `onOutput` delivers raw bytes read from the channel — converted from NIO's `ByteBuffer`
    /// at the conforming type's boundary, so nothing above `PooledConnecting` needs to know
    /// SwiftNIO exists. `onClose` fires once, the first time the channel goes away for any
    /// reason other than the caller closing the returned handle itself (remote exit, network
    /// drop, protocol error).
    func openPTY(
        mode: TerminalMode,
        cols: Int,
        rows: Int,
        onOutput: @escaping ([UInt8]) -> Void,
        onClose: @escaping (Int?) -> Void
    ) async throws -> PTYHandle

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

/// Handle on an open PTY channel returned by `PooledConnecting.openPTY`. Closing it tears down
/// only this one channel — the pooled parent connection is unaffected, exactly like a single
/// `exec` finishing does not close the parent.
///
/// `SSHConnectionPool.openPTY` wraps this in a second `PTYHandle` that additionally releases the
/// pool lease taken for the terminal, so callers above the pool (`SSHTerminalSession`) only ever
/// see that outer handle.
final class PTYHandle: @unchecked Sendable {
    private let sendBytes: (ArraySlice<UInt8>) -> Void
    private let resizeTo: (Int, Int) -> Void
    private let closeChannel: () -> Void

    init(
        send: @escaping (ArraySlice<UInt8>) -> Void,
        resize: @escaping (Int, Int) -> Void,
        close: @escaping () -> Void
    ) {
        self.sendBytes = send
        self.resizeTo = resize
        self.closeChannel = close
    }

    func send(_ bytes: ArraySlice<UInt8>) { sendBytes(bytes) }
    func resize(cols: Int, rows: Int) { resizeTo(cols, rows) }
    func close() { closeChannel() }
}
