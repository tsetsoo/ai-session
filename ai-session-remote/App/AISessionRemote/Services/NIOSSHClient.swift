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
        SSHSignInRecord.clear(hostID: hostID)
        var map = storedFingerprints()
        guard map.removeValue(forKey: hostID) != nil else { return }
        defaults.set(map, forKey: Self.defaultsKey)
    }

    private func storedFingerprints() -> [String: String] {
        (defaults.dictionary(forKey: Self.defaultsKey) as? [String: String]) ?? [:]
    }
}

/// The sign-in problem the newest handshake with a host ran into, if any. A terminal's channel
/// fails the same way whether the network, the host's identity or the key was the problem, so
/// the handshake notes the two sign-in problems here as they happen and the frame words the
/// failure from them. Each handshake starts by checking the host's identity, which replaces
/// whatever an earlier attempt noted.
enum SSHSignInRecord {
    enum Problem: Equatable {
        /// The host's key isn't the one trusted on first use.
        case hostKeyChanged
        /// The host turned this device's key down.
        case keyRejected
    }

    private static let lock = NSLock()
    private static var problems: [String: Problem] = [:]

    static func problem(hostID: String) -> Problem? {
        lock.withLock { problems[hostID] }
    }

    static func hostKeyChecked(hostID: String, matched: Bool) {
        lock.withLock { problems[hostID] = matched ? nil : .hostKeyChanged }
    }

    static func keyRejected(hostID: String) {
        lock.withLock { problems[hostID] = .keyRejected }
    }

    static func clear(hostID: String) {
        lock.withLock { problems[hostID] = nil }
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
        let matched = store.evaluate(hostID: hostID, publicKey: hostKey)
        SSHSignInRecord.hostKeyChecked(hostID: hostID, matched: matched)
        if matched {
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
    /// Where a rejected key is recorded (`SSHSignInRecord`); nil records nothing.
    private let hostID: String?
    private var hasOffered = false

    init(username: String, privateKey: NIOSSHPrivateKey, hostID: String? = nil) {
        self.username = username
        self.privateKey = privateKey
        self.hostID = hostID
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !hasOffered, availableMethods.contains(.publicKey) else {
            // Out of offers: the host turned the key down (or takes no keys at all).
            if let hostID { SSHSignInRecord.keyRejected(hostID: hostID) }
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
        guard let exitCode else {
            // The channel went away without ever reporting an exit status, and this wasn't the
            // deliberate timeout case above. Every host this app manages runs OpenSSH's `sshd`
            // (see `SSHRemoteError.tmuxMissing`'s Homebrew/apt install hint elsewhere in this
            // codebase — this isn't a generic SSH client aimed at arbitrary server
            // implementations), and a compliant OpenSSH server always sends exit-status before
            // closing the channel for a command that actually ran to completion. So a missing
            // exit code here is evidence the *connection* died (peer
            // RST/FIN, a Wi-Fi/cellular handoff, a network drop mid-command), not evidence the
            // command quietly succeeded. Synthesizing `exitCode: -1` for that case used to let
            // `SessionService` misreport it as a "command failed" alert for something that was
            // never a remote failure, and it silently skipped the pool's retry-once path (which
            // only ever sees a *thrown* error). Failing with `.unreachable` instead fixes both:
            // an honest, existing user-facing message, and a real error the pool can act on.
            //
            // (A command killed by a signal is reported over a distinct `ExitSignal` request
            // this handler doesn't track, not by omitting `ExitStatus` — and `exec` here is only
            // ever used for this app's own short, app-controlled management commands (tmux
            // new-session/list/kill, mkdir, test -d, ...), never an interactive user shell, so
            // that case is not a realistic concern for this path either way.)
            promise.fail(SSHRemoteError.unreachable)
            return
        }
        promise.succeed(
            SSHExecResult(
                exitCode: exitCode,
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
/// There is exactly **one** pool, shared by every `NIOSSHClient` instance, so a host that's both
/// reachability-probed (`ReachabilityProbe`) and running an active session (`SessionService` via
/// `SessionServiceFactory`) still holds a single parent SSH connection, not two. That's only
/// possible because the two timeouts that matter while *dialing* — `connectTimeoutSeconds` and
/// `handshakeDeadlineSeconds` — are fixed, app-level constants rather than something each
/// `NIOSSHClient` instance can override: if they were per-instance (as they used to be), whoever
/// dialed a given host first would silently decide those budgets for every other caller of that
/// same host too. The exec timeout doesn't have that problem, because it's a parameter of each
/// `exec(_:timeoutSeconds:)` call rather than baked into the connection at dial time (see
/// `PooledConnecting.exec`) — so it stays instance-configurable here without any
/// cross-contamination risk. `ReachabilityProbe` uses that to keep its own short exec timeout
/// while still sharing the one pooled connection, and layers its own overall deadline around the
/// whole call to get back the fast-fail behaviour the old per-instance connect/handshake timeouts
/// used to give it.
public struct NIOSSHClient: SSHExecuting {
    /// Fixed for every dial, regardless of which `NIOSSHClient` instance triggers it — see the
    /// type-level doc comment for why these two specifically cannot be per-instance.
    private static let connectTimeoutSeconds: Int64 = 10
    private static let handshakeDeadlineSeconds: Int64 = 15

    /// The single pool shared by every `NIOSSHClient` instance — see the type-level doc comment
    /// for why there must be exactly one. Also exposed as the default pool for
    /// `SSHTerminalSession`, so attaching a terminal to a host reuses the same authenticated
    /// connection as any `exec` (reachability probe, list/create/kill) against that host,
    /// instead of dialing its own.
    ///
    /// On the Mac, a host that is this Mac (`ThisMac`) gets a `LocalConnection`: its commands
    /// and terminals run locally, with no SSH at all.
    static let shared = SSHConnectionPool { config in
        #if os(macOS)
        if ThisMac.matches(config) { return LocalConnection() }
        #endif
        return try await PooledSSHConnection.dial(
            config,
            hostKeyStore: TOFUHostKeyStore(),
            connectTimeoutSeconds: connectTimeoutSeconds,
            handshakeDeadlineSeconds: handshakeDeadlineSeconds
        )
    }

    /// Bounds how long a remote command may run before it's forcibly killed. Safe to customize
    /// per instance/call — see the type-level doc comment.
    private let execTimeoutSeconds: Int64

    public init(execTimeoutSeconds: Int64 = 30) {
        self.execTimeoutSeconds = execTimeoutSeconds
    }

    public func exec(_ config: HostConnectionConfig, command: String) async throws -> SSHExecResult {
        try await Self.shared.exec(config, command: command, timeoutSeconds: execTimeoutSeconds)
    }
}
