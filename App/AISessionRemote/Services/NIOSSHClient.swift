import AISessionCore
import Crypto
import Foundation
import NIOCore
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
/// A thin adapter over `SSHConnectionPool`/`PooledSSHConnection`: the dial/auth/exec machinery
/// itself (including the error-mapping heuristic — failures before TCP is established map to
/// `.unreachable`; failures after TCP connects map to `.authenticationFailed`; a non-zero remote
/// exit code is not an error at this layer) now lives in `PooledSSHConnection`, which keeps one
/// authenticated connection open per host across many commands instead of dialing fresh for
/// every `exec`.
///
/// Pools are keyed by their timeout configuration, not just shared globally. Every call site
/// that constructs `NIOSSHClient()` with the defaults (`SessionServiceFactory`) lands on the same
/// pool and so shares one connection per host across the whole app — the main goal here. But
/// `ReachabilityProbe` deliberately constructs `NIOSSHClient` with tighter timeouts so a
/// reachability check fails fast; if it shared a pool bucket with the default-timeout instances,
/// whichever timeout configuration happened to dial a given host first would silently apply to
/// every future caller of that host through the *other* instance too — e.g. a probe's 5-second
/// exec timeout would apply to real session commands if the probe won the race, spuriously
/// failing a legitimately slow command with "exec timed out". Keying pools by timeout
/// configuration keeps each configuration's connections isolated, exactly like each got its own
/// fully independent connection before pooling existed.
public struct NIOSSHClient: SSHExecuting {
    private struct PoolKey: Hashable {
        let connectTimeoutSeconds: Int64
        let handshakeDeadlineSeconds: Int64
        let execTimeoutSeconds: Int64
    }

    /// Owns the lazily-created pool for each distinct timeout configuration. An actor rather
    /// than a lock-guarded static var so the mutable registry stays concurrency-safe without
    /// `nonisolated(unsafe)` (Swift 5.9 target, no availability for that attribute).
    private actor PoolRegistry {
        static let shared = PoolRegistry()

        private var pools: [PoolKey: SSHConnectionPool] = [:]

        func pool(
            key: PoolKey,
            hostKeyStore: TOFUHostKeyStore,
            connectTimeoutSeconds: Int64,
            handshakeDeadlineSeconds: Int64,
            execTimeoutSeconds: Int64
        ) -> SSHConnectionPool {
            if let existing = pools[key] {
                return existing
            }
            let created = SSHConnectionPool { config in
                try await PooledSSHConnection.dial(
                    config,
                    hostKeyStore: hostKeyStore,
                    connectTimeoutSeconds: connectTimeoutSeconds,
                    handshakeDeadlineSeconds: handshakeDeadlineSeconds,
                    execTimeoutSeconds: execTimeoutSeconds
                )
            }
            pools[key] = created
            return created
        }
    }

    private let hostKeyStore: TOFUHostKeyStore
    /// Bounds the raw TCP connect (handled by NIO itself via `ClientBootstrap.connectTimeout`).
    private let connectTimeoutSeconds: Int64
    /// Bounds SSH handshake + user auth + session-channel-open. See `PooledSSHConnection.exec`
    /// for how this is applied once the connection is kept open across commands.
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
        let key = PoolKey(
            connectTimeoutSeconds: connectTimeoutSeconds,
            handshakeDeadlineSeconds: handshakeDeadlineSeconds,
            execTimeoutSeconds: execTimeoutSeconds
        )
        let pool = await PoolRegistry.shared.pool(
            key: key,
            hostKeyStore: hostKeyStore,
            connectTimeoutSeconds: connectTimeoutSeconds,
            handshakeDeadlineSeconds: handshakeDeadlineSeconds,
            execTimeoutSeconds: execTimeoutSeconds
        )
        return try await pool.exec(config, command: command)
    }
}
