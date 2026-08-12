import AISessionCore
import Foundation

/// Test double mapping command substrings to canned exec results or errors, recording
/// every command it is asked to run so tests can assert on round-trip counts.
///
/// A `final class` rather than a `struct` because recording is mutation, and `exec` is
/// `nonmutating` by protocol. `@unchecked Sendable` is justified by the lock.
final class FakeSSHExecutor: SSHExecuting, @unchecked Sendable {
    private let responsesByPrefix: [String: SSHExecResult]
    private let errorsByPrefix: [String: SSHRemoteError]
    private let defaultResult: SSHExecResult
    private let lock = NSLock()
    private var _recordedCommands: [String] = []

    var recordedCommands: [String] {
        lock.withLock { _recordedCommands }
    }

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
        lock.withLock { _recordedCommands.append(command) }

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
