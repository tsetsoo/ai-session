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
    private var sequencedResponsesByPrefix: [String: [SSHExecResult]] = [:]

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

    /// Registers a sequence of results to hand out, one per matching call, for commands
    /// containing `prefix` — e.g. a duplicate-name failure followed by a success, so a test
    /// can pin the exec count of a retry loop. Once the queue is exhausted, the last result
    /// repeats. Added after `init` (rather than as an init parameter) so no existing call site
    /// needs to change.
    func enqueueResponses(_ results: [SSHExecResult], forPrefix prefix: String) {
        precondition(!results.isEmpty, "enqueueResponses requires at least one result")
        lock.withLock { sequencedResponsesByPrefix[prefix] = results }
    }

    func exec(_ config: HostConnectionConfig, command: String) async throws -> SSHExecResult {
        lock.withLock { _recordedCommands.append(command) }

        let sequenced: SSHExecResult? = lock.withLock {
            for (prefix, queue) in sequencedResponsesByPrefix.sorted(by: { $0.key.count > $1.key.count })
            where command.contains(prefix) {
                let next = queue[0]
                if queue.count > 1 {
                    sequencedResponsesByPrefix[prefix] = Array(queue.dropFirst())
                }
                return next
            }
            return nil
        }
        if let sequenced {
            return sequenced
        }

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
