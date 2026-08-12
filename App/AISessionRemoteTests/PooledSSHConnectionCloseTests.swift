import AISessionCore
import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import XCTest

@testable import AISessionRemote

/// Regression test for the bug fixed alongside wiring `SSHConnectionPool.closeAll()` to app
/// lifecycle notifications: closing a `PooledSSHConnection` while a command is genuinely still
/// running on it used to force-close the channel without failing that command's promise, so
/// `ExecOutputHandler.complete()` resolved it with a synthetic, misleading `exitCode: -1`
/// "success" instead of a thrown error — which `SessionService` then turned into
/// `SSHRemoteError.commandFailed`, surfaced to the user as a spurious "command failed" alert for
/// something that was never a remote failure at all.
///
/// Exercising this needs a genuinely open channel with a command actually in flight, which
/// `SSHConnectionPool`'s `FakeConnection`-based tests can't provide — that fake stands in for the
/// whole `PooledConnecting` protocol and never touches the real NIO/SSH plumbing this bug lives
/// in. So this test dials a real (loopback, in-process) SSH server instead of mocking anything,
/// using the same real `PooledSSHConnection.dial`/`exec`/`close` the pool itself calls.
///
/// Deterministic and event-driven throughout: the test waits for the server to have actually
/// received the exec request (via `execRequestGate`, a one-shot signal — never a sleep) before
/// closing the connection, and the whole flow is wrapped in `fulfillment(of:timeout:)` — which
/// has its own real, independent timeout — so a regression that hangs (e.g. a dial that never
/// completes, or a request the fake server never receives) fails this test after the timeout
/// instead of hanging the suite forever, mirroring the pattern already used in
/// `ReachabilityProbeTests`.
final class PooledSSHConnectionCloseTests: XCTestCase {
    // Same throwaway, unencrypted ed25519 fixture used by `OpenSSHPrivateKeyParserTests` —
    // duplicated here (rather than shared) since that one is `private` to its own file.
    // Generated with `ssh-keygen -t ed25519 -N "" -f fixture_ed25519 -C fixture`.
    private static let clientPEM = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
    QyNTUxOQAAACDtbSsk4hYzctZhwgMSTNYDEr81wgAn5xYVuhfEtg/S5wAAAJAlxIljJcSJ
    YwAAAAtzc2gtZWQyNTUxOQAAACDtbSsk4hYzctZhwgMSTNYDEr81wgAn5xYVuhfEtg/S5w
    AAAECKPcrTMRISYmyaj3mfc+cLi8BY3ywf/mqJ4tZRl98yue1tKyTiFjNy1mHCAxJM1gMS
    vzXCACfnFhW6F8S2D9LnAAAAB2ZpeHR1cmUBAgMEBQY=
    -----END OPENSSH PRIVATE KEY-----
    """

    func testCloseFailsAnInFlightExecWithUnreachableInsteadOfASyntheticSuccess() async throws {
        let execRequestGate = SignalGate()
        let serverGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        let hostKey = NIOSSHPrivateKey(ed25519Key: .init())
        let serverChannel = try await ServerBootstrap(group: serverGroup)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        NIOSSHHandler(
                            role: .server(
                                .init(hostKeys: [hostKey], userAuthDelegate: AcceptAnyPublicKeyDelegate())
                            ),
                            allocator: channel.allocator,
                            inboundChildChannelInitializer: { childChannel, channelType in
                                guard channelType == .session else {
                                    return childChannel.eventLoop.makeFailedFuture(TestServerError.unexpectedChannelType)
                                }
                                return childChannel.eventLoop.makeCompletedFuture {
                                    try childChannel.pipeline.syncOperations.addHandler(
                                        // Deliberately never sends output or an exit status, so
                                        // the client's `exec()` stays genuinely pending — a
                                        // stand-in for a real long-running remote command — until
                                        // this test closes the connection out from under it.
                                        HangingExecHandler(onExecRequest: { Task { await execRequestGate.open() } })
                                    )
                                }
                            }
                        )
                    )
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()

        defer {
            try? serverChannel.close().wait()
            try? serverGroup.syncShutdownGracefully()
        }

        guard let port = serverChannel.localAddress?.port else {
            XCTFail("expected the test server to have a bound port")
            return
        }

        let config = HostConnectionConfig(
            host: "127.0.0.1",
            port: port,
            username: "tester",
            privateKeyPEM: Data(Self.clientPEM.utf8),
            hostID: "pooled-connection-close-test-\(UUID())"
        )
        // A fresh, isolated defaults suite per run so trust-on-first-use has nothing stored yet
        // for this host — the test's freshly generated server host key is accepted on its first
        // (and only) connection, exactly like a brand-new host would be in the app.
        guard let defaults = UserDefaults(suiteName: "com.aisessionremote.tests.\(UUID())") else {
            XCTFail("expected a usable UserDefaults suite")
            return
        }
        let hostKeyStore = TOFUHostKeyStore(defaults: defaults)

        let returned = expectation(description: "close() fails the in-flight exec instead of hanging or succeeding")
        let outcome = OutcomeBox()

        Task {
            do {
                let connection = try await PooledSSHConnection.dial(
                    config,
                    hostKeyStore: hostKeyStore,
                    connectTimeoutSeconds: 5,
                    handshakeDeadlineSeconds: 5
                )

                async let execResult: Result<SSHExecResult, Error> = {
                    do {
                        return .success(try await connection.exec("sleep 100", timeoutSeconds: 30))
                    } catch {
                        return .failure(error)
                    }
                }()

                // Don't close until the server has genuinely received the exec request —
                // otherwise this could pass merely because `close()` won the race against a
                // channel that was never actually open yet, which would prove nothing about the
                // fix.
                await execRequestGate.wait()
                await connection.close()

                await outcome.set(await execResult)
            } catch {
                // A dial failure isn't what this test is about, but capturing it (rather than
                // letting the Task silently swallow it) still lets the assertion below report a
                // clear, specific failure instead of just "the flow never completed".
                await outcome.set(.failure(error))
            }
            returned.fulfill()
        }

        await fulfillment(of: [returned], timeout: 15)

        guard let result = await outcome.value else {
            XCTFail("the dial/exec/close flow never completed")
            return
        }
        switch result {
        case .success(let execResult):
            XCTFail("expected close() to fail the in-flight command, got a synthetic result instead: \(execResult)")
        case .failure(let error):
            guard let sshError = error as? SSHRemoteError else {
                XCTFail("expected SSHRemoteError.unreachable, got an internal error type: \(error)")
                return
            }
            XCTAssertEqual(
                sshError, .unreachable,
                "a command interrupted by close() must read the same as a genuinely dead connection, "
                    + "not a bogus non-zero exit code"
            )
        }
    }
}

private enum TestServerError: Error {
    case unexpectedChannelType
}

/// Accepts any public-key offer. Good enough for a test server whose only job is to let the real
/// client dial in — this test isn't about authentication, it's about what `close()` does to a
/// command already running once a connection exists.
private final class AcceptAnyPublicKeyDelegate: NIOSSHServerUserAuthenticationDelegate {
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .publicKey

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        switch request.request {
        case .publicKey:
            responsePromise.succeed(.success)
        default:
            responsePromise.succeed(.failure)
        }
    }
}

/// Installed on the server's session channel. Reports the moment an `ExecRequest` arrives (via
/// `onExecRequest`) and then does nothing else at all — no output, no `ChannelSuccessEvent`, no
/// `ExitStatus` — so the channel stays open and the client's `exec()` stays genuinely pending,
/// simulating a real command still running when the connection is torn down.
private final class HangingExecHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private let onExecRequest: @Sendable () -> Void

    init(onExecRequest: @escaping @Sendable () -> Void) {
        self.onExecRequest = onExecRequest
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is SSHChannelRequestEvent.ExecRequest {
            onExecRequest()
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }
}

/// A single-use, async-safe signal: `wait()` suspends until `open()` is called, however many
/// times `wait()` itself is called. Lets `HangingExecHandler`'s NIO-thread callback hand off to
/// the test's `Task` deterministically, without a sleep on either side.
private actor SignalGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

/// Hands the dial/exec/close `Task`'s final result back to the test method across the `await
/// fulfillment(of:timeout:)` boundary.
private actor OutcomeBox {
    private(set) var value: Result<SSHExecResult, Error>?
    func set(_ value: Result<SSHExecResult, Error>) { self.value = value }
}
