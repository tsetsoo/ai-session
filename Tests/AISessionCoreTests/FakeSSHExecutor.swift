import AISessionCore

/// Test double mapping command prefixes to canned exec results or errors.
struct FakeSSHExecutor: SSHExecuting, Sendable {
    private let responsesByPrefix: [String: SSHExecResult]
    private let errorsByPrefix: [String: SSHRemoteError]
    private let defaultResult: SSHExecResult

    init(
        responsesByPrefix: [String: SSHExecResult] = [:],
        errorsByPrefix: [String: SSHRemoteError] = [:],
        defaultResult: SSHExecResult = SSHExecResult(exitCode: 127, stdout: "", stderr: "command not found")
    ) {
        self.responsesByPrefix = responsesByPrefix
        self.errorsByPrefix = errorsByPrefix
        self.defaultResult = defaultResult
    }

    func exec(_ config: HostConnectionConfig, command: String) async throws -> SSHExecResult {
        for (needle, error) in errorsByPrefix.sorted(by: { $0.key.count > $1.key.count }) {
            if command.contains(needle) {
                throw error
            }
        }

        for (needle, result) in responsesByPrefix.sorted(by: { $0.key.count > $1.key.count }) {
            if command.contains(needle) {
                return result
            }
        }

        return defaultResult
    }
}
