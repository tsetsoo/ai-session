import AISessionCore
import Foundation

/// Cheap connectivity/auth check used to populate `HostEntity.lastReachableAt` and the
/// green/red status dot in `HostsListView`. Runs `true` over SSH (rather than a bare TCP
/// connect) so it validates authentication end-to-end, not just that the port is open.
///
/// Deliberately takes a `HostConnectionConfig` rather than `HostEntity`: `HostEntity` is a
/// non-`Sendable` SwiftData model, and `HostsListView` runs probes concurrently across hosts
/// (see `refreshReachability`), so callers build the `Sendable` config on the main actor and
/// apply the boolean result back to the model themselves.
struct ReachabilityProbe {
    private let executor: SSHExecuting
    private let deadlineSeconds: Int64
    private let sleep: @Sendable (Duration) async throws -> Void

    /// `NIOSSHClient`'s connect/handshake timeouts are fixed, app-level constants shared by
    /// every caller (so a probed host and an active session against the same host still share
    /// one pooled connection instead of two — see `NIOSSHClient`'s doc comment) — they can no
    /// longer be tightened per instance the way they used to be. The exec timeout has no such
    /// restriction, since it's a per-command parameter rather than something baked into the
    /// connection, so it's still tightened here. To get back the rest of the old fail-fast
    /// behaviour, `isReachable` additionally races the whole call (dial included) against
    /// `deadlineSeconds` itself: a probe that lands on an already-warm pooled connection returns
    /// almost immediately regardless, and a probe against a genuinely cold/unreachable host still
    /// gives up quickly instead of tying up a refresh for tens of seconds per host.
    ///
    /// `sleep` is injectable (defaulting to real `Task.sleep`) purely for testing: a test can
    /// resolve it immediately so it can assert the deadline actually wins against an operation
    /// that never completes, without a real multi-second wait.
    init(
        executor: SSHExecuting = NIOSSHClient(execTimeoutSeconds: 5),
        deadlineSeconds: Int64 = 8,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.executor = executor
        self.deadlineSeconds = deadlineSeconds
        self.sleep = sleep
    }

    func isReachable(_ config: HostConnectionConfig) async -> Bool {
        do {
            let result = try await Self.withDeadline(seconds: deadlineSeconds, sleep: sleep) {
                try await executor.exec(config, command: "true")
            }
            return result.exitCode == 0
        } catch {
            return false
        }
    }

    /// Races `operation` against a timer, returning as soon as either resolves — without waiting
    /// on whichever one loses. Used instead of a connection-level timeout because the pooled
    /// connection `executor` runs on may be shared with other callers using different timeout
    /// expectations (see `NIOSSHClient`), so this probe's fail-fast requirement has to be
    /// enforced by the probe itself, around the whole call, rather than by configuring the
    /// connection.
    ///
    /// Deliberately *not* a `withThrowingTaskGroup`: a task group's body cannot return until
    /// every child task has finished, even one it has cancelled — cancellation only sets a flag,
    /// it does not abort a child that never checks it. `PooledSSHConnection`'s dial path does not
    /// check `Task.isCancelled`, so a group here would still block the caller on the losing dial
    /// for up to its own internal deadlines (the NIO connect timeout / handshake deadline) —
    /// exactly what this function exists to avoid. Racing two independent, *unstructured* `Task`s
    /// instead lets the deadline path return the moment it wins, while the operation keeps
    /// running on its own: if it's a dial that eventually succeeds, it still populates the pool
    /// for the next real caller, which is a feature, not a leak.
    private static func withDeadline<T: Sendable>(
        seconds: Int64,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let resumeOnce = ResumeOnce()

            let timeoutTask = Task {
                try? await sleep(.seconds(seconds))
                guard !Task.isCancelled else { return }
                resumeOnce.run { continuation.resume(throwing: SSHRemoteError.unreachable) }
            }

            Task {
                do {
                    let value = try await operation()
                    timeoutTask.cancel()
                    resumeOnce.run { continuation.resume(returning: value) }
                } catch {
                    timeoutTask.cancel()
                    resumeOnce.run { continuation.resume(throwing: error) }
                }
            }
        }
    }
}

/// Guarantees a `CheckedContinuation` is resumed at most once even though two independent,
/// uncoordinated tasks (`withDeadline`'s operation and timeout races) may each try to resume it.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var didRun = false

    func run(_ body: () -> Void) {
        lock.lock()
        let shouldRun = !didRun
        didRun = true
        lock.unlock()
        if shouldRun {
            body()
        }
    }
}
