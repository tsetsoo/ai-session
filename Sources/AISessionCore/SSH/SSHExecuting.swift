public struct SSHExecResult: Equatable, Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol SSHExecuting: Sendable {
    func exec(_ config: HostConnectionConfig, command: String) async throws -> SSHExecResult
    // Interactive shell/PTY is app-layer (SwiftNIO + SwiftTerm); core only needs exec for list/create/kill/probes.
}

public enum SSHRemoteError: Error, Equatable, Sendable {
    case unreachable
    case authenticationFailed
    case tmuxMissing
    case binaryMissing(String)
    case commandFailed(exitCode: Int32, stderr: String)

    public var userMessage: String {
        switch self {
        case .unreachable:
            return "Could not reach the host. Check Tailscale and network, then try again."
        case .authenticationFailed:
            return "SSH authentication failed. Verify the username and private key, or the host's key may have changed — check with \"Forget Host Key\" in the host editor."
        case .tmuxMissing:
            return "tmux is required on this host. Install it with `brew install tmux` on macOS or `apt install tmux` on Debian/Ubuntu."
        case let .binaryMissing(binary):
            return "The required binary '\(binary)' was not found on this host. Install it and ensure it is on PATH."
        case let .commandFailed(exitCode, stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "The remote command failed (exit code \(exitCode))." : detail
        }
    }
}
