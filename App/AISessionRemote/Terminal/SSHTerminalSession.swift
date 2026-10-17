import AISessionCore
import Foundation

enum SSHTerminalSessionError: Error {
    case invalidPrivateKey
    case connectionFailed
    case channelSetupFailed
}

enum TerminalMode: Equatable {
    case attach(String)
    case plainShell
}

/// Drives an interactive SSH PTY session (`tmux attach -t '<name>'`) for `TerminalScreen`.
///
/// Opens its PTY on the host's pooled SSH connection (`SSHConnectionPool.openPTY`) rather than
/// dialing its own — attaching to tmux no longer pays its own full SSH handshake, since
/// `SSHConnectionPool`/`PooledSSHConnection` already keep one authenticated connection open per
/// host across every command and terminal. All of the NIO-level channel work (requesting a PTY,
/// exec'ing the attach command, translating `SSHChannelData` to plain bytes) now lives in
/// `PTYChannelHandler`/`PooledSSHConnection`, which keeps this type free of SwiftNIO types so it
/// can conform to the NIO-free `TerminalTransport` protocol.
final class SSHTerminalSession: TerminalTransport {
    /// Invoked off the main thread. `TerminalCoordinator` hops back to the main thread before
    /// touching UI.
    var onOutput: (([UInt8]) -> Void)?
    /// Invoked once, the first time the connection goes away for any reason other than an
    /// explicit `disconnect()` call (network drop, remote-side `exit`, TOFU mismatch, etc).
    var onDisconnect: ((Int?) -> Void)?

    private let config: HostConnectionConfig
    private let mode: TerminalMode
    private let pool: SSHConnectionPool

    /// Guards `_handle` and `_isDisconnecting`. `connect()`'s continuation can resume on
    /// whatever thread the pool/NIO machinery lands it on, `disconnect()` is called
    /// synchronously from the main actor (`TerminalScreen.onDisappear`), and
    /// `notifyDisconnectedIfNeeded()` runs from the pool's `onClose` callback on yet another
    /// thread — so all three must go through this lock rather than relying on any of them
    /// running on one consistent thread.
    private let stateLock = NSLock()
    private var _handle: PTYHandle?
    private var _isDisconnecting = false

    init(
        config: HostConnectionConfig,
        mode: TerminalMode,
        pool: SSHConnectionPool = NIOSSHClient.shared
    ) {
        self.config = config
        self.mode = mode
        self.pool = pool
    }

    /// Opens a PTY on the pooled connection for `config`, sized `cols`x`rows`, and execs the
    /// attach command. Returns once the channel is open and ready to send/receive; call
    /// `resize` afterwards once the real terminal view size is known (this initial size is just
    /// a reasonable starting guess).
    ///
    /// Holds a pool lease for as long as the terminal stays attached — see
    /// `SSHConnectionPool.openPTY` — released exactly once by whichever of `disconnect()` or
    /// the channel dying on its own happens first.
    ///
    /// `disconnect()` (or the `deinit` backstop) can run while this call is still suspended
    /// inside `pool.openPTY` — e.g. `TerminalScreen.onDisappear` firing while its
    /// `.task { await coordinator.connect() }` is still mid-handshake. At that point there is
    /// nothing yet in `_handle` for `disconnect()` to close, so it just latches
    /// `_isDisconnecting` and returns. This method must not then blindly store the handle it
    /// gets back once it resumes — that would silently orphan it, along with the one lease
    /// `SSHConnectionPool.openPTY` already took on the shared pooled connection, since every
    /// other path that could ever close it is gated on that same already-true flag. So: check
    /// `_isDisconnecting` under the same lock used everywhere else in this class before
    /// deciding whether to store the handle or hand it straight back to `close()` — whichever
    /// of this check or `disconnect()`/`deinit` wins the lock first is the one that ends up
    /// closing it, and exactly one of them does, because they all share the same lock and the
    /// same one-way flag.
    func connect(cols: Int, rows: Int) async throws {
        let handle = try await pool.openPTY(
            config,
            mode: mode,
            cols: cols,
            rows: rows,
            onOutput: { [weak self] bytes in self?.onOutput?(bytes) },
            onClose: { [weak self] exitStatus in self?.notifyDisconnectedIfNeeded(exitStatus) }
        )
        let shouldCloseImmediately: Bool = stateLock.withLock {
            if _isDisconnecting {
                return true
            }
            _handle = handle
            return false
        }
        if shouldCloseImmediately {
            handle.close()
        }
    }

    /// Sends raw input bytes (keystrokes, soft-key bytes) to the remote PTY.
    func send(_ bytes: ArraySlice<UInt8>) {
        stateLock.withLock { _handle }?.send(bytes)
    }

    /// Sends an SSH `window-change` request so the remote PTY (and whatever's inside it, e.g.
    /// tmux) knows the terminal was resized.
    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        stateLock.withLock { _handle }?.resize(cols: cols, rows: rows)
    }

    /// Closes the PTY channel only — the pooled SSH connection stays open for other commands
    /// against this host, and `tmux` on the remote host keeps the session running so it can be
    /// reattached later, which is the whole point of exec'ing `tmux attach` rather than running
    /// an interactive login shell.
    func disconnect() {
        let handle: PTYHandle? = stateLock.withLock {
            guard !_isDisconnecting else { return nil }
            _isDisconnecting = true
            let handle = _handle
            _handle = nil
            return handle
        }
        handle?.close()
    }

    private func notifyDisconnectedIfNeeded(_ exitStatus: Int?) {
        let shouldNotify: Bool = stateLock.withLock {
            guard !_isDisconnecting else { return false }
            _isDisconnecting = true
            return true
        }
        guard shouldNotify else { return }
        onDisconnect?(exitStatus)
    }

    /// Backstop in case this object is ever deallocated without `disconnect()` having run
    /// (e.g. an owner that forgets to call it): still releases the pool lease taken in
    /// `connect()` rather than leaving the pooled connection permanently un-evictable.
    deinit {
        let handle: PTYHandle? = stateLock.withLock {
            guard !_isDisconnecting else { return nil }
            _isDisconnecting = true
            let handle = _handle
            _handle = nil
            return handle
        }
        handle?.close()
    }
}
