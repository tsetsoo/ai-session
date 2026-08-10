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
final class ExecOutputHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private let command: String
    private var resultPromise: EventLoopPromise<SSHExecResult>?
    private var stdout = Data()
    private var stderr = Data()
    private var exitCode: Int32?

    init(command: String, resultPromise: EventLoopPromise<SSHExecResult>) {
        self.command = command
        self.resultPromise = resultPromise
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
        guard let promise = resultPromise else { return }
        resultPromise = nil
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
    private static let connectTimeoutSeconds: Int64 = 10
    private static let execTimeoutSeconds: Int64 = 30

    private let hostKeyStore: TOFUHostKeyStore

    public init(hostKeyStore: TOFUHostKeyStore = TOFUHostKeyStore()) {
        self.hostKeyStore = hostKeyStore
    }

    public func exec(_ config: HostConnectionConfig, command: String) async throws -> SSHExecResult {
        let privateKey: NIOSSHPrivateKey
        do {
            privateKey = try OpenSSHPrivateKeyParser.parse(pem: config.privateKeyPEM)
        } catch {
            throw SSHRemoteError.authenticationFailed
        }

        let hostID = "\(config.host):\(config.port)"
        let authDelegate = SSHPrivateKeyAuthDelegate(username: config.username, privateKey: privateKey)
        let hostKeyDelegate = TOFUServerAuthenticationDelegate(hostID: hostID, store: hostKeyStore)

        let channel: Channel
        do {
            channel = try await ClientBootstrap(group: Self.eventLoopGroup)
                .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
                .connectTimeout(.seconds(Self.connectTimeoutSeconds))
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(
                            NIOSSHHandler(
                                role: .client(.init(userAuthDelegate: authDelegate, serverAuthDelegate: hostKeyDelegate)),
                                allocator: channel.allocator,
                                inboundChildChannelInitializer: nil
                            )
                        )
                    }
                }
                .connect(host: config.host, port: config.port)
                .get()
        } catch {
            throw SSHRemoteError.unreachable
        }

        do {
            let result = try await Self.runExec(command: command, over: channel)
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
        case execTimedOut
    }

    private static func runExec(command: String, over channel: Channel) async throws -> SSHExecResult {
        let sshHandler: NIOSSHHandler
        do {
            sshHandler = try await channel.pipeline.handler(type: NIOSSHHandler.self).get()
        } catch {
            throw SSHRemoteError.authenticationFailed
        }

        let resultPromise = channel.eventLoop.makePromise(of: SSHExecResult.self)

        let childChannel: Channel
        do {
            childChannel = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Channel, Error>) in
                let promise = channel.eventLoop.makePromise(of: Channel.self)
                sshHandler.createChannel(promise, channelType: .session) { childChannel, channelType in
                    guard channelType == .session else {
                        return childChannel.eventLoop.makeFailedFuture(InternalError.unexpectedChannelType)
                    }
                    return childChannel.eventLoop.makeCompletedFuture {
                        try childChannel.pipeline.syncOperations.addHandler(
                            ExecOutputHandler(command: command, resultPromise: resultPromise)
                        )
                    }
                }
                promise.futureResult.whenComplete { continuation.resume(with: $0) }
            }
        } catch {
            throw SSHRemoteError.authenticationFailed
        }

        let timeoutTask = channel.eventLoop.scheduleTask(in: .seconds(execTimeoutSeconds)) {
            resultPromise.fail(InternalError.execTimedOut)
            childChannel.close(promise: nil)
        }

        do {
            let result = try await resultPromise.futureResult.get()
            timeoutTask.cancel()
            return result
        } catch InternalError.execTimedOut {
            timeoutTask.cancel()
            throw SSHRemoteError.commandFailed(exitCode: -1, stderr: "exec timed out after \(execTimeoutSeconds)s")
        } catch {
            timeoutTask.cancel()
            throw SSHRemoteError.authenticationFailed
        }
    }
}
