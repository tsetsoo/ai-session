import AISessionCore
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

enum SSHTerminalSessionError: Error {
    case invalidPrivateKey
    case connectionFailed
    case channelSetupFailed
}

enum TerminalMode: Equatable {
    case attach(String)
    case plainShell
}

/// Bridges the SSH "session" channel used for an interactive PTY: requests a pseudo-terminal,
/// execs the attach command (e.g. `tmux attach -t '…'`), and translates raw bytes to/from the
/// channel's native `SSHChannelData` framing.
///
/// This is the same inbound/outbound boundary pattern as `apple/swift-nio-ssh`'s own
/// `ExampleExecHandler` (`NIOSSHClient` target): a `ChannelDuplexHandler` with
/// `InboundIn = SSHChannelData` / `OutboundOut = SSHChannelData` sits at the edge of the child
/// channel, so everything above it (this handler's own `write`) can deal in plain `ByteBuffer`s.
final class PTYChannelHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let mode: TerminalMode
    private let initialCols: Int
    private let initialRows: Int
    private let onOutput: (ByteBuffer) -> Void
    private let onExit: (Int?) -> Void
    private var exitStatus: Int?

    init(
        mode: TerminalMode,
        initialCols: Int,
        initialRows: Int,
        onOutput: @escaping (ByteBuffer) -> Void,
        onExit: @escaping (Int?) -> Void
    ) {
        self.mode = mode
        self.initialCols = initialCols
        self.initialRows = initialRows
        self.onOutput = onOutput
        self.onExit = onExit
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { _ in }
    }

    func channelActive(context: ChannelHandlerContext) {
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: false,
            term: "xterm-256color",
            terminalCharacterWidth: max(initialCols, 1),
            terminalRowHeight: max(initialRows, 1),
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        context.triggerUserOutboundEvent(pty, promise: nil)

        switch mode {
        case let .attach(command):
            let exec = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: false)
            context.triggerUserOutboundEvent(exec, promise: nil)
        case .plainShell:
            let shell = SSHChannelRequestEvent.ShellRequest(wantReply: false)
            context.triggerUserOutboundEvent(shell, promise: nil)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = payload.data else { return }
        onOutput(buffer)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let status = event as? SSHChannelRequestEvent.ExitStatus {
            exitStatus = status.exitStatus
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        onExit(exitStatus)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: promise)
    }
}

/// Drives an interactive SSH PTY session (`tmux attach -t '<name>'`) for `TerminalScreen`.
///
/// Reuses the connection/auth/TOFU/error-handling building blocks declared in `NIOSSHClient.swift`
/// (same app target, so its `internal` types are visible here) but, unlike `NIOSSHClient.exec`,
/// keeps the channel open for the life of the terminal screen instead of tearing it down after a
/// single command.
final class SSHTerminalSession {
    /// Invoked on the session's private NIO event loop thread — never the main thread. Callers
    /// (`TerminalScreen`'s coordinator) must hop back to the main thread before touching UI.
    var onOutput: ((ByteBuffer) -> Void)?
    /// Invoked once, on the event loop thread, the first time the connection goes away for any
    /// reason other than an explicit `disconnect()` call (network drop, remote-side `exit`, TOFU
    /// mismatch, etc).
    var onDisconnect: (() -> Void)?

    private let config: HostConnectionConfig
    private let mode: TerminalMode
    private let hostKeyStore: TOFUHostKeyStore
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    private var parentChannel: Channel?
    private var sessionChannel: Channel?
    private var isDisconnecting = false

    init(
        config: HostConnectionConfig,
        mode: TerminalMode,
        hostKeyStore: TOFUHostKeyStore = TOFUHostKeyStore()
    ) {
        self.config = config
        self.mode = mode
        self.hostKeyStore = hostKeyStore
    }

    /// Connects, requests a PTY sized `cols`x`rows`, and execs the attach command. Returns once
    /// the session channel is open and ready to send/receive; call `resize` afterwards once the
    /// real terminal view size is known (this initial size is just a reasonable starting guess).
    func connect(cols: Int, rows: Int) async throws {
        let privateKey: NIOSSHPrivateKey
        do {
            privateKey = try OpenSSHPrivateKeyParser.parse(pem: config.privateKeyPEM)
        } catch {
            throw SSHTerminalSessionError.invalidPrivateKey
        }

        let hostID = "\(config.host):\(config.port)"
        let authDelegate = SSHPrivateKeyAuthDelegate(username: config.username, privateKey: privateKey)
        let hostKeyDelegate = TOFUServerAuthenticationDelegate(hostID: hostID, store: hostKeyStore)

        let channel: Channel
        do {
            channel = try await ClientBootstrap(group: group)
                .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
                .connectTimeout(.seconds(10))
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
            throw SSHTerminalSessionError.connectionFailed
        }
        parentChannel = channel
        channel.closeFuture.whenComplete { [weak self] _ in
            self?.notifyDisconnectedIfNeeded()
        }

        do {
            sessionChannel = try await openSessionChannel(over: channel, cols: cols, rows: rows)
        } catch {
            try? await channel.close().get()
            parentChannel = nil
            throw SSHTerminalSessionError.channelSetupFailed
        }
    }

    private func openSessionChannel(over channel: Channel, cols: Int, rows: Int) async throws -> Channel {
        let sshHandler: NIOSSHHandler
        do {
            sshHandler = try await channel.pipeline.handler(type: NIOSSHHandler.self).get()
        } catch {
            throw SSHTerminalSessionError.channelSetupFailed
        }

        let channelPromise = channel.eventLoop.makePromise(of: Channel.self)
        sshHandler.createChannel(channelPromise, channelType: .session) { [mode] childChannel, channelType in
            guard channelType == .session else {
                return childChannel.eventLoop.makeFailedFuture(SSHTerminalSessionError.channelSetupFailed)
            }
            return childChannel.eventLoop.makeCompletedFuture {
                try childChannel.pipeline.syncOperations.addHandler(
                    PTYChannelHandler(
                        mode: mode,
                        initialCols: cols,
                        initialRows: rows,
                        onOutput: { [weak self] buffer in self?.onOutput?(buffer) },
                        onExit: { [weak self] _ in self?.notifyDisconnectedIfNeeded() }
                    )
                )
                try childChannel.pipeline.syncOperations.addHandler(SSHConnectionErrorHandler())
            }
        }

        do {
            return try await channelPromise.futureResult.get()
        } catch {
            throw SSHTerminalSessionError.channelSetupFailed
        }
    }

    /// Sends raw input bytes (keystrokes, soft-key bytes) to the remote PTY.
    func send(_ bytes: ArraySlice<UInt8>) {
        guard let sessionChannel else { return }
        sessionChannel.eventLoop.execute {
            var buffer = sessionChannel.allocator.buffer(capacity: bytes.count)
            buffer.writeBytes(bytes)
            sessionChannel.writeAndFlush(buffer, promise: nil)
        }
    }

    /// Sends an SSH `window-change` request so the remote PTY (and whatever's inside it, e.g.
    /// tmux) knows the terminal was resized.
    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0, let sessionChannel else { return }
        sessionChannel.eventLoop.execute {
            let event = SSHChannelRequestEvent.WindowChangeRequest(
                terminalCharacterWidth: cols,
                terminalRowHeight: rows,
                terminalPixelWidth: 0,
                terminalPixelHeight: 0
            )
            sessionChannel.triggerUserOutboundEvent(event, promise: nil)
        }
    }

    /// Closes the SSH connection only — `tmux` on the remote host keeps the session running so it
    /// can be reattached later, which is the whole point of exec'ing `tmux attach` rather than
    /// running an interactive login shell.
    func disconnect() {
        guard !isDisconnecting else { return }
        isDisconnecting = true
        sessionChannel?.close(promise: nil)
        parentChannel?.close(promise: nil)
        group.shutdownGracefully { _ in }
    }

    private func notifyDisconnectedIfNeeded() {
        guard !isDisconnecting else { return }
        isDisconnecting = true
        onDisconnect?()
        group.shutdownGracefully { _ in }
    }

    deinit {
        if !isDisconnecting {
            group.shutdownGracefully { _ in }
        }
    }
}
