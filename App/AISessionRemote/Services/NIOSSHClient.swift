import AISessionCore
import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// Trust-on-first-use host key store backed by `UserDefaults`.
///
/// v1 stopgap per the plan: a `UserDefaults` restore-from-backup (or a compromised device)
/// could silently carry over or replace a trusted fingerprint, and there's no UI yet to let a
/// user review or reset a host's stored fingerprint. A hardened version should move this into
/// the Keychain (like `KeychainPrivateKeyStore`) so it can't be edited outside the app sandbox
/// as easily, and should expose "forget this host" in the UI.
public struct TOFUHostKeyStore: @unchecked Sendable {
    private static let defaultsKey = "com.aisessionremote.sshHostKeyFingerprints"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Returns `true` if `publicKey` matches the fingerprint already stored for `hostID`, or
    /// records it as trusted if this is the first time `hostID` has been seen.
    public func evaluate(hostID: String, publicKey: NIOSSHPublicKey) -> Bool {
        let fingerprint = fingerprint(of: publicKey)
        var map = storedFingerprints()
        if let existing = map[hostID] {
            return existing == fingerprint
        }
        map[hostID] = fingerprint
        defaults.set(map, forKey: Self.defaultsKey)
        return true
    }

    public func fingerprint(of publicKey: NIOSSHPublicKey) -> String {
        let serialized = String(openSSHPublicKey: publicKey)
        let digest = SHA256.hash(data: Data(serialized.utf8))
        return Data(digest).base64EncodedString()
    }

    /// Removes any trusted fingerprint recorded for `hostID`. Called when a host is deleted (so
    /// a future host reusing the same hostname/port isn't silently compared against a stale
    /// fingerprint) and available for a manual "Forget host key" action if a host's key
    /// legitimately changed.
    public func forget(hostID: String) {
        var map = storedFingerprints()
        guard map.removeValue(forKey: hostID) != nil else { return }
        defaults.set(map, forKey: Self.defaultsKey)
    }

    private func storedFingerprints() -> [String: String] {
        (defaults.dictionary(forKey: Self.defaultsKey) as? [String: String]) ?? [:]
    }
}

/// Accepts a host key on first connection and requires an exact fingerprint match afterward.
final class TOFUServerAuthenticationDelegate: NIOSSHClientServerAuthenticationDelegate {
    private let hostID: String
    private let store: TOFUHostKeyStore

    init(hostID: String, store: TOFUHostKeyStore) {
        self.hostID = hostID
        self.store = store
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        if store.evaluate(hostID: hostID, publicKey: hostKey) {
            validationCompletePromise.succeed(())
        } else {
            validationCompletePromise.fail(SSHRemoteError.authenticationFailed)
        }
    }
}

/// Ensures any SSH-layer error (host key rejection, auth failure, protocol violation) actually
/// tears down the TCP connection.
///
/// `apple/swift-nio-ssh`'s own client example always pairs `NIOSSHHandler` with a handler like
/// this. Without it, a failed `NIOSSHClientServerAuthenticationDelegate` (TOFU mismatch) or
/// `NIOSSHClientUserAuthenticationDelegate` promise can leave the connection sitting open
/// indefinitely instead of closing — which previously meant a pending `createChannel` promise,
/// and therefore `exec()`, would hang forever. `NIOSSHClient.exec` also wraps channel setup in
/// an explicit deadline as a second, independent backstop against exactly that failure mode.
final class SSHConnectionErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

/// Offers a single private key for public-key authentication and gives up if the server
/// doesn't advertise `publicKey` support (no password fallback is implemented).
final class SSHPrivateKeyAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let privateKey: NIOSSHPrivateKey
    private var hasOffered = false

    init(username: String, privateKey: NIOSSHPrivateKey) {
        self.username = username
        self.privateKey = privateKey
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !hasOffered, availableMethods.contains(.publicKey) else {
            nextChallengePromise.succeed(nil)
            return
        }
        hasOffered = true
        nextChallengePromise.succeed(
            NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "ssh-connection",
                offer: .privateKey(.init(privateKey: privateKey))
            )
        )
    }
}

/// Captures stdout/stderr and the exit status for a single SSH `exec` session channel.
///
/// `resultPromise` is only ever completed from inside `complete()`, guarded by nil-ing out
/// `resultPromise` first — that's deliberate: `EventLoopPromise.succeed`/`fail` trap if called
/// twice, so a caller wanting to force a timeout must go through `markTimedOut()` + closing the
/// channel (which drives `channelInactive`/`handlerRemoved` → `complete()`) rather than
/// completing the promise directly from outside.
final class ExecOutputHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private let command: String
    private let lock = NSLock()
    private var resultPromise: EventLoopPromise<SSHExecResult>?
    private var stdout = Data()
    private var stderr = Data()
    private var exitCode: Int32?
    private var timedOut = false

    init(command: String, resultPromise: EventLoopPromise<SSHExecResult>) {
        self.command = command
        self.resultPromise = resultPromise
    }

    /// Must be called on this handler's event loop (i.e. from a callback scheduled on the
    /// parent SSH channel's event loop, which child channels share) before force-closing the
    /// channel, so the resulting completion reports a timeout instead of a bare `exitCode: -1`.
    func markTimedOut() {
        lock.lock()
        timedOut = true
        lock.unlock()
    }

    /// Completes `resultPromise` if it is still pending. Safe to call more than once and from
    /// outside the pipeline — used when `createChannel` fails before this handler is installed,
    /// which would otherwise deallocate an incomplete `EventLoopPromise` and trap with
    /// "leaking promise".
    func failIfPending(_ error: Error) {
        lock.lock()
        let promise = resultPromise
        resultPromise = nil
        lock.unlock()
        promise?.fail(error)
    }

    func channelActive(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { _ in }
        let request = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
        context.triggerUserOutboundEvent(request, promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let sshData = unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = sshData.data else { return }
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        switch sshData.type {
        case .channel:
            stdout.append(contentsOf: bytes)
        case .stdErr:
            stderr.append(contentsOf: bytes)
        default:
            break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let status = event as? SSHChannelRequestEvent.ExitStatus {
            exitCode = Int32(status.exitStatus)
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        complete()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        complete()
    }

    private func complete() {
        lock.lock()
        let promise = resultPromise
        resultPromise = nil
        let timedOut = self.timedOut
        let exitCode = self.exitCode
        let stdout = self.stdout
        let stderr = self.stderr
        lock.unlock()

        guard let promise else { return }
        if timedOut {
            promise.fail(SSHRemoteError.commandFailed(exitCode: -1, stderr: "exec timed out"))
            return
        }
        promise.succeed(
            SSHExecResult(
                exitCode: exitCode ?? -1,
                stdout: String(decoding: stdout, as: UTF8.self),
                stderr: String(decoding: stderr, as: UTF8.self)
            )
        )
    }
}

/// Real `SSHExecuting` implementation backed by `apple/swift-nio-ssh`.
///
/// Error-mapping heuristic: `SSHRemoteError` has no generic "protocol/handshake" case, so
/// failures that occur *before* the TCP connection is established (DNS failure, connection
/// refused, connect timeout) map to `.unreachable`, while anything that fails *after* TCP
/// connects (SSH handshake, host key rejection, user auth, channel setup) maps to
/// `.authenticationFailed`. A non-zero remote exit code is not an error at this layer — it's
/// returned as a normal `SSHExecResult` and it's up to callers (e.g. `SessionService`) to decide
/// whether that counts as a failure.
public struct NIOSSHClient: SSHExecuting {
    private static let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    private let hostKeyStore: TOFUHostKeyStore
    /// Bounds the raw TCP connect (handled by NIO itself via `ClientBootstrap.connectTimeout`).
    private let connectTimeoutSeconds: Int64
    /// Bounds SSH handshake + user auth + session-channel-open, measured from when the TCP
    /// connection completes. This is the deadline that guards against the TOFU/auth-failure
    /// hang described on `NIOSSHClient.exec`: if it fires, the underlying channel is force
    /// -closed so the connection can't linger even if `SSHConnectionErrorHandler` somehow
    /// didn't already close it.
    private let handshakeDeadlineSeconds: Int64
    /// Bounds how long a remote command may run before it's forcibly killed.
    private let execTimeoutSeconds: Int64

    public init(
        hostKeyStore: TOFUHostKeyStore = TOFUHostKeyStore(),
        connectTimeoutSeconds: Int64 = 10,
        handshakeDeadlineSeconds: Int64 = 15,
        execTimeoutSeconds: Int64 = 30
    ) {
        self.hostKeyStore = hostKeyStore
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.handshakeDeadlineSeconds = handshakeDeadlineSeconds
        self.execTimeoutSeconds = execTimeoutSeconds
    }

    public func exec(_ config: HostConnectionConfig, command: String) async throws -> SSHExecResult {
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

        do {
            let result = try await Self.runExec(
                command: command,
                over: channel,
                handshakeDeadlineSeconds: handshakeDeadlineSeconds,
                execTimeoutSeconds: execTimeoutSeconds
            )
            try? await channel.close().get()
            return result
        } catch let error as SSHRemoteError {
            try? await channel.close().get()
            throw error
        } catch {
            try? await channel.close().get()
            throw SSHRemoteError.authenticationFailed
        }
    }

    private enum InternalError: Error {
        case unexpectedChannelType
    }

    /// Opens the `exec` session channel and runs the command, with two NIO-scheduled deadlines
    /// guarding against a hang: one bounding channel setup (handshake/auth), one bounding the
    /// remote command itself. Each deadline only ever *closes a channel*; it never completes an
    /// `EventLoopPromise` that something else might also complete, so there's no risk of the
    /// "promise completed twice" trap regardless of how the two race.
    private static func runExec(
        command: String,
        over channel: Channel,
        handshakeDeadlineSeconds: Int64,
        execTimeoutSeconds: Int64
    ) async throws -> SSHExecResult {
        let sshHandler: NIOSSHHandler
        do {
            sshHandler = try await channel.pipeline.handler(type: NIOSSHHandler.self).get()
        } catch {
            throw SSHRemoteError.authenticationFailed
        }

        let resultPromise = channel.eventLoop.makePromise(of: SSHExecResult.self)
        let channelPromise = channel.eventLoop.makePromise(of: Channel.self)
        let execHandler = ExecOutputHandler(command: command, resultPromise: resultPromise)

        // If `createChannel` fails before the handler is installed (auth/TOFU/handshake
        // timeout), nothing else will complete `resultPromise` — fail it here so deinit
        // cannot trap with "leaking promise".
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

        // `channelPromise` is only ever completed by `sshHandler.createChannel` itself (on
        // success, or on failure/disconnect). This deadline never touches it directly — it
        // just force-closes `channel`, which is what makes the *real* SSH stack fail the
        // pending channel-open on its own (this is the fix for the TOFU-mismatch hang: without
        // `SSHConnectionErrorHandler` already closing the connection, `channelPromise` would
        // otherwise never resolve).
        let handshakeDeadlineTask = channel.eventLoop.scheduleTask(in: .seconds(handshakeDeadlineSeconds)) {
            channel.close(promise: nil)
        }
        channelPromise.futureResult.whenComplete { _ in handshakeDeadlineTask.cancel() }

        let childChannel: Channel
        do {
            childChannel = try await withTaskCancellationHandler {
                try await channelPromise.futureResult.get()
            } onCancel: {
                channel.close(promise: nil)
            }
        } catch {
            execHandler.failIfPending(SSHRemoteError.authenticationFailed)
            throw SSHRemoteError.authenticationFailed
        }

        // Same pattern: never completes `resultPromise` directly, just marks the handler and
        // closes the child channel, so `ExecOutputHandler.complete()` remains the sole writer.
        let execTimeoutTask = channel.eventLoop.scheduleTask(in: .seconds(execTimeoutSeconds)) {
            execHandler.markTimedOut()
            childChannel.close(promise: nil)
        }
        resultPromise.futureResult.whenComplete { _ in execTimeoutTask.cancel() }

        do {
            return try await withTaskCancellationHandler {
                try await resultPromise.futureResult.get()
            } onCancel: {
                channel.eventLoop.execute {
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
}
