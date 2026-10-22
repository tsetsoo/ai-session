#if os(macOS)
import AISessionCore
import Darwin
import Foundation
import SwiftTerm

/// Whether a host config points at this Mac as the user running the app. Such a host needs
/// no SSH: `SSHConnectionPool` hands out a `LocalConnection` for it instead of dialing.
///
/// Hosts are usually saved by Tailscale IP, so the address is matched against this Mac's own
/// interface addresses; names match this Mac's host name, with or without a domain
/// (`tsvetelins-macbook-pro.tail0fa5cc.ts.net`). The port is ignored: nothing listens on it.
enum ThisMac {
    static func matches(_ config: HostConnectionConfig) -> Bool {
        matches(hostname: config.host, username: config.username)
    }

    static func matches(hostname: String, username: String) -> Bool {
        guard username == NSUserName() else { return false }
        var host = hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard !host.isEmpty else { return false }
        if ["localhost", "127.0.0.1", "::1"].contains(host) { return true }
        if interfaceAddresses().contains(host) { return true }
        guard let name = hostName() else { return false }
        return host == name || firstLabel(host) == firstLabel(name)
    }

    private static func firstLabel(_ name: String) -> String {
        String(name.split(separator: ".", maxSplits: 1).first ?? "")
    }

    /// `gethostname`, lowercased: `tsvetelins-macbook-pro.local`. No DNS lookup.
    private static func hostName() -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
        guard gethostname(&buffer, buffer.count) == 0 else { return nil }
        let name = String(cString: buffer).lowercased()
        return name.isEmpty ? nil : name
    }

    /// Every IPv4 and IPv6 address on this Mac's interfaces, the Tailscale one included.
    private static func interfaceAddresses() -> Set<String> {
        var result: Set<String> = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(address, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            // A link-local IPv6 address carries its zone (`fe80::1%en0`).
            let text = String(cString: buffer).lowercased()
            result.insert(String(text.split(separator: "%").first ?? ""))
        }
        return result
    }
}

/// This Mac standing in for an SSH connection: commands run under the user's shell with
/// `Process`, and terminals run in a local pseudo-terminal. Same commands as over SSH (they
/// are already `TmuxCommandBuilder`-wrapped with PATH and locale), so `ai-todo-open` and tmux
/// behave the same; only the handshake and the network round trips are gone.
final class LocalConnection: PooledConnecting {
    var isAlive: Bool { true }

    func exec(_ command: String, timeoutSeconds: Int64) async throws -> SSHExecResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try Self.run(command, timeoutSeconds: timeoutSeconds) })
            }
        }
    }

    func openPTY(
        mode: TerminalMode,
        cols: Int,
        rows: Int,
        onOutput: @escaping ([UInt8]) -> Void,
        onClose: @escaping (Int?) -> Void
    ) async throws -> PTYHandle {
        let pty = LocalPTY(cols: cols, rows: rows, onOutput: onOutput, onClose: onClose)
        try pty.start(mode)
        return PTYHandle(
            send: { pty.send($0) },
            resize: { pty.resize(cols: $0, rows: $1) },
            close: { pty.close() }
        )
    }

    func close() async {}

    /// Like sshd: the login shell runs the command with `-c`, from the home folder.
    private static func run(_ command: String, timeoutSeconds: Int64) throws -> SSHExecResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", command]
        process.environment = environment(term: nil)
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            // Nothing ran, so the pool may retry it.
            throw SSHChannelOpenFailure(underlying: SSHRemoteError.unreachable)
        }

        // Both pipes drain while the command runs, so a chatty one can't fill and block it.
        let output = OutputBox()
        let reading = DispatchGroup()
        for (pipe, isError) in [(stdout, false), (stderr, true)] {
            reading.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                output.set(pipe.fileHandleForReading.readDataToEndOfFile(), isError: isError)
                reading.leave()
            }
        }
        if exited.wait(timeout: .now() + .seconds(Int(timeoutSeconds))) == .timedOut {
            process.terminate()
            throw SSHRemoteError.commandFailed(exitCode: -1, stderr: "exec timed out")
        }
        // Something the command left running in the background may hold the pipes open.
        _ = reading.wait(timeout: .now() + .seconds(2))
        let (out, err) = output.get()
        return SSHExecResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: out, as: UTF8.self),
            stderr: String(decoding: err, as: UTF8.self)
        )
    }

    static let shell: String = {
        if let entry = getpwuid(getuid()), let path = entry.pointee.pw_shell {
            let shell = String(cString: path)
            if !shell.isEmpty { return shell }
        }
        return "/bin/zsh"
    }()

    /// The app's environment without what would confuse tmux or a tool started inside it.
    static func environment(term: String?) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("TMUX") || key.hasPrefix("DYLD_") {
            environment[key] = nil
        }
        environment["TERM"] = term
        environment["TERM_PROGRAM"] = nil
        environment["HOME"] = environment["HOME"] ?? NSHomeDirectory()
        environment["SHELL"] = shell
        return environment
    }
}

private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    func set(_ data: Data, isError: Bool) {
        lock.withLock {
            if isError { stderr = data } else { stdout = data }
        }
    }

    func get() -> (Data, Data) {
        lock.withLock { (stdout, stderr) }
    }
}

/// One local terminal: SwiftTerm's `LocalProcess` forks the shell onto a new pseudo-terminal
/// (its own session, so tmux gets SIGWINCH on resize). `onClose` fires once, when the process
/// exits by itself; `close()` ends it quietly (the tmux client detaches, the session stays).
private final class LocalPTY: LocalProcessDelegate, @unchecked Sendable {
    private let onOutput: ([UInt8]) -> Void
    private let onClose: (Int?) -> Void
    private let lock = NSLock()
    private var size: winsize
    private var finished = false
    private var process: LocalProcess!

    init(cols: Int, rows: Int, onOutput: @escaping ([UInt8]) -> Void, onClose: @escaping (Int?) -> Void) {
        self.size = winsize(ws_row: UInt16(clamping: max(rows, 1)), ws_col: UInt16(clamping: max(cols, 1)),
                            ws_xpixel: 0, ws_ypixel: 0)
        self.onOutput = onOutput
        self.onClose = onClose
        // Output arrives off the main thread, as it does from SSH.
        process = LocalProcess(delegate: self, dispatchQueue: DispatchQueue(label: "LocalPTY"))
    }

    /// Held from `forkpty` until the new master is close-on-exec, so no other terminal forks
    /// in between and inherits it.
    private static let forkLock = NSLock()

    func start(_ mode: TerminalMode) throws {
        let environment = LocalConnection.environment(term: "xterm-256color").map { "\($0.key)=\($0.value)" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        Self.forkLock.lock()
        defer { Self.forkLock.unlock() }
        switch mode {
        case let .attach(command):
            process.startProcess(executable: LocalConnection.shell, args: ["-c", command],
                                 environment: environment, currentDirectory: home)
        case .plainShell:
            // A leading dash makes it a login shell, as sshd starts one.
            let name = "-" + (LocalConnection.shell.split(separator: "/").last.map(String.init) ?? "zsh")
            process.startProcess(executable: LocalConnection.shell, args: [],
                                 environment: environment, execName: name, currentDirectory: home)
        }
        guard process.running else {
            throw SSHChannelOpenFailure(underlying: SSHTerminalSessionError.channelSetupFailed)
        }
        // SwiftTerm's forkpty leaves the master inheritable, so every later terminal's child
        // would hold it open. Closing this terminal would then never hang up its tmux client,
        // which stays attached for good (SIGTERM alone does not end it).
        _ = fcntl(process.childfd, F_SETFD, FD_CLOEXEC)
    }

    func send(_ bytes: ArraySlice<UInt8>) {
        process.send(data: bytes)
    }

    func resize(cols: Int, rows: Int) {
        var next = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: cols), ws_xpixel: 0, ws_ypixel: 0)
        lock.withLock { size = next }
        let fd = process.childfd
        guard fd >= 0 else { return }
        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: fd, windowSize: &next)
    }

    func close() {
        let first = lock.withLock {
            defer { finished = true }
            return !finished
        }
        if first { process.terminate() }
    }

    // MARK: LocalProcessDelegate

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        let first = lock.withLock {
            defer { finished = true }
            return !finished
        }
        guard first else { return }
        // `exitCode` is the raw `waitpid` status. A signal leaves no exit status, as over SSH.
        let status = exitCode.flatMap { raw in raw & 0x7f == 0 ? Int((raw >> 8) & 0xff) : nil }
        onClose(status)
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        onOutput(Array(slice))
    }

    func getWindowSize() -> winsize {
        lock.withLock { size }
    }
}
#endif
