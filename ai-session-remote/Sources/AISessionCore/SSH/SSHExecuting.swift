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

    /// For screens that don't name the computer. Same wording as `ComputerErrorText`.
    public var userMessage: String {
        ComputerErrorText.message(for: self, computer: "the computer")
    }
}
