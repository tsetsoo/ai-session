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
    init(
        executor: SSHExecuting = NIOSSHClient(execTimeoutSeconds: 5),
        deadlineSeconds: Int64 = 8
    ) {
        self.executor = executor
        self.deadlineSeconds = deadlineSeconds
    }

    func isReachable(_ config: HostConnectionConfig) async -> Bool {
        do {
            let result = try await Self.withDeadline(seconds: deadlineSeconds) {
                try await executor.exec(config, command: "true")
            }
            return result.exitCode == 0
        } catch {
            return false
        }
    }

    /// Races `operation` against a timer, returning whichever finishes first. Used instead of a
    /// connection-level timeout because the pooled connection `executor` runs on may be shared
    /// with other callers using different timeout expectations (see `NIOSSHClient`), so this
    /// probe's fail-fast requirement has to be enforced by the probe itself, around the whole
    /// call, rather than by configuring the connection.
    private static func withDeadline<T: Sendable>(
        seconds: Int64,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw SSHRemoteError.unreachable
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}
