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

    /// Uses tighter deadlines than `NIOSSHClient`'s exec-oriented defaults: a reachability
    /// check should fail fast rather than tie up a refresh for tens of seconds per host.
    init(
        executor: SSHExecuting = NIOSSHClient(
            connectTimeoutSeconds: 5,
            handshakeDeadlineSeconds: 8,
            execTimeoutSeconds: 5
        )
    ) {
        self.executor = executor
    }

    func isReachable(_ config: HostConnectionConfig) async -> Bool {
        do {
            let result = try await executor.exec(config, command: "true")
            return result.exitCode == 0
        } catch {
            return false
        }
    }
}
