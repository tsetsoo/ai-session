import AISessionCore
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// One authenticated SSH connection kept open across many commands, vended by
/// `SSHConnectionPool`.
///
/// This carries across the dial/auth/exec machinery that used to live entirely inside
/// `NIOSSHClient.exec` (one connection per command) with two structural changes:
///
/// 1. The parent channel is kept open after a command finishes instead of being torn down, and a
///    fresh child "session" channel is opened per `exec(_:timeoutSeconds:)` call over that same
///    parent.
/// 2. The exec timeout is a parameter of each call rather than fixed at dial time, since it is a
///    property of the command being run, not of the transport — one connection can serve
///    commands with different timeout budgets without either one leaking onto the other.
///
/// Everything else — bootstrap/channel options and the error-mapping heuristic — is unchanged
/// from the original `NIOSSHClient.exec`:
///
/// - Failures before TCP is established (DNS failure, connection refused, connect timeout) map
///   to `.unreachable`.
/// - Failures after TCP connects (SSH handshake, host key rejection, user auth, channel setup)
///   map to `.authenticationFailed`.
/// - A non-zero remote exit code is not an error at this layer.
final class PooledSSHConnection: PooledConnecting, @unchecked Sendable {
    /// Single-threaded, matching the group `NIOSSHClient` used to create fresh per command; now
    /// shared across every pooled connection instead of one per exec.
    private static let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    private enum InternalError: Error {
        case unexpectedChannelType
    }

    private let channel: Channel
    /// Bounds SSH handshake + user auth + session-channel-open for the *first* command run over
    /// this connection, exactly as it did in the original single-shot `NIOSSHClient.exec`. Kept
    /// in force for every later command too (opening a new session channel over an already
    /// -authenticated transport is normally near-instant, so this never fires in the healthy
    /// case) so a wedged parent connection can't hang a later `exec(_:timeoutSeconds:)` forever
    /// either.
    private let handshakeDeadlineSeconds: Int64

    private let lock = NSLock()
    private var _isAlive = true

    var isAlive: Bool {
        lock.withLock { _isAlive && channel.isActive }
    }

    private init(channel: Channel, handshakeDeadlineSeconds: Int64) {
        self.channel = channel
        self.handshakeDeadlineSeconds = handshakeDeadlineSeconds
        channel.closeFuture.whenComplete { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { self._isAlive = false }
        }
    }

    /// Dials, authenticates, and returns a connection whose parent channel is left open for
    /// `exec(_:timeoutSeconds:)` to reuse. Same bootstrap and channel options as the original
    /// `NIOSSHClient.exec`, plus TCP keepalive (see the comment inline) which the original never
    /// needed because it never kept a connection open long enough for it to matter.
    static func dial(
        _ config: HostConnectionConfig,
        hostKeyStore: TOFUHostKeyStore,
        connectTimeoutSeconds: Int64,
        handshakeDeadlineSeconds: Int64
    ) async throws -> PooledSSHConnection {
        let privateKey: NIOSSHPrivateKey
        do {
            privateKey = try OpenSSHPrivateKeyParser.parse(pem: config.privateKeyPEM)
        } catch {
            throw SSHRemoteError.authenticationFailed
        }

        let authDelegate = SSHPrivateKeyAuthDelegate(username: config.username, privateKey: privateKey)
        let hostKeyDelegate = TOFUServerAuthenticationDelegate(hostID: config.hostID, store: hostKeyStore)

        let channel: Channel
        do {
            channel = try await ClientBootstrap(group: Self.eventLoopGroup)
                .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
                // swift-nio-ssh exposes no global-request API, so an SSH-level
                // `keepalive@openssh.com` isn't available here. TCP keepalive is the substitute:
                // without it, a connection that's kept open indefinitely (unlike the original
                // per-command connection) can die silently to a NAT/Tailscale idle timeout, and
                // `isAlive` — which only checks `channel.isActive` — won't catch a half-open
                // socket. Left unset, that failure would only surface on the next real command,
                // after burning up to the handshake deadline or the exec timeout before the
                // pool's single retry kicks in — exactly the latency this work exists to remove.
                .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_KEEPALIVE), value: 1)
                .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_KEEPALIVE), value: 20)
                .connectTimeout(.seconds(connectTimeoutSeconds))
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let sync = channel.pipeline.syncOperations
                        try sync.addHandler(
                            NIOSSHHandler(
                                role: .client(.init(userAuthDelegate: authDelegate, serverAuthDelegate: hostKeyDelegate)),
                                allocator: channel.allocator,
                                inboundChildChannelInitializer: nil
                            )
                        )
                        try sync.addHandler(SSHConnectionErrorHandler())
                    }
                }
                .connect(host: config.host, port: config.port)
                .get()
        } catch {
            throw SSHRemoteError.unreachable
        }

        return PooledSSHConnection(channel: channel, handshakeDeadlineSeconds: handshakeDeadlineSeconds)
    }

    /// Opens a fresh session channel over the shared parent channel and runs `command`, with the
    /// same two NIO-scheduled deadlines the original single-shot `exec` used: one bounding
    /// channel setup (handshake/auth), one bounding the remote command itself (now supplied per
    /// call via `timeoutSeconds` rather than fixed at dial time). Neither deadline ever completes
    /// an `EventLoopPromise` directly; each only closes a channel, so there's no "promise
    /// completed twice" risk regardless of how they race (unchanged from the original).
    func exec(_ command: String, timeoutSeconds: Int64) async throws -> SSHExecResult {
        let sshHandler: NIOSSHHandler
        do {
            sshHandler = try await channel.pipeline.handler(type: NIOSSHHandler.self).get()
        } catch {
            // The parent's SSH layer is gone even if the socket hasn't fully closed yet — don't
            // let the pool keep handing out a connection that can no longer open channels. This
            // is a parent-implicating failure (the handler is only ever removed when the
            // *pipeline* tears down), unlike an individual channel-open request being refused
            // below.
            markDead()
            throw SSHRemoteError.authenticationFailed
        }

        let resultPromise = channel.eventLoop.makePromise(of: SSHExecResult.self)
        let channelPromise = channel.eventLoop.makePromise(of: Channel.self)
        let execHandler = ExecOutputHandler(command: command, resultPromise: resultPromise)

        // If `createChannel` fails before the handler is installed (auth/TOFU/handshake
        // timeout), nothing else will complete `resultPromise` — fail it here so deinit cannot
        // trap with "leaking promise".
        channelPromise.futureResult.whenFailure { error in
            execHandler.failIfPending(error)
        }

        sshHandler.createChannel(channelPromise, channelType: .session) { childChannel, channelType in
            guard channelType == .session else {
                return childChannel.eventLoop.makeFailedFuture(InternalError.unexpectedChannelType)
            }
            return childChannel.eventLoop.makeCompletedFuture {
                try childChannel.pipeline.syncOperations.addHandler(execHandler)
                try childChannel.pipeline.syncOperations.addHandler(SSHConnectionErrorHandler())
            }
        }

        // Guards channel setup exactly like the original handshake deadline did. Firing this
        // closes the *parent* channel (not just this command's child channel): if a new session
        // channel can't be opened over an already-authenticated transport within this deadline,
        // the transport itself is wedged, not just this one command, so the whole pooled
        // connection is torn down rather than left for the pool to hand out again. (This is a
        // different failure mode from the one guarded against below: this one is "the parent
        // stopped responding at all", not "the parent is fine but declined this one channel".)
        let handshakeDeadlineTask = channel.eventLoop.scheduleTask(in: .seconds(handshakeDeadlineSeconds)) {
            self.channel.close(promise: nil)
        }
        channelPromise.futureResult.whenComplete { _ in handshakeDeadlineTask.cancel() }

        let childChannel: Channel
        do {
            childChannel = try await withTaskCancellationHandler {
                try await channelPromise.futureResult.get()
            } onCancel: {
                // Unlike the original single-shot flow, cancelling this one command must not
                // tear down the shared parent connection out from under other callers that may
                // be using it concurrently. Only close the child channel this command was
                // opening, if and once it actually opens.
                channelPromise.futureResult.whenSuccess { $0.close(promise: nil) }
            }
        } catch {
            execHandler.failIfPending(SSHRemoteError.authenticationFailed)
            // A single channel-open failing is not necessarily evidence the *parent* transport
            // is broken — e.g. sshd transiently refusing a new channel (MaxSessions/MaxStartups)
            // while the connection itself is perfectly healthy. Marking the whole connection
            // dead here would tear it down for every other command sharing it. Only do that when
            // there's actual evidence the transport itself is gone — the parent channel is no
            // longer active, whether because the handshake deadline above just fired, or the
            // connection genuinely dropped. Otherwise leave `isAlive` alone and let this error
            // propagate; the pool's retry-once logic checks `isAlive` itself and only evicts a
            // connection that really is dead, reusing this one for the retry otherwise.
            if !channel.isActive {
                markDead()
            }
            throw SSHRemoteError.authenticationFailed
        }

        // Bounds how long the remote command may run. Unlike the handshake deadline above, this
        // only closes the child channel for *this* command — a single slow/hung command does not
        // mean the parent connection is broken, so it stays alive for the pool to keep reusing.
        let execTimeoutTask = channel.eventLoop.scheduleTask(in: .seconds(timeoutSeconds)) {
            execHandler.markTimedOut()
            childChannel.close(promise: nil)
        }
        resultPromise.futureResult.whenComplete { _ in execTimeoutTask.cancel() }

        do {
            return try await withTaskCancellationHandler {
                try await resultPromise.futureResult.get()
            } onCancel: {
                self.channel.eventLoop.execute {
                    execHandler.markTimedOut()
                    childChannel.close(promise: nil)
                }
            }
        } catch let error as SSHRemoteError {
            throw error
        } catch {
            execHandler.failIfPending(SSHRemoteError.authenticationFailed)
            throw SSHRemoteError.authenticationFailed
        }
    }

    func close() async {
        markDead()
        try? await channel.close().get()
    }

    private func markDead() {
        lock.withLock { _isAlive = false }
    }
}
