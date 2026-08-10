import AISessionCore
import Foundation

/// Cheap connectivity/auth check used to populate `HostEntity.lastReachableAt` and the
/// green/red status dot in `HostsListView`. Runs `true` over SSH (rather than a bare TCP
/// connect) so it validates authentication end-to-end, not just that the port is open.
struct ReachabilityProbe {
    private let executor: SSHExecuting

    init(executor: SSHExecuting = NIOSSHClient()) {
        self.executor = executor
    }

    @discardableResult
    func probe(host: HostEntity, privateKeyPEM: Data) async -> Bool {
        let config = HostConnectionConfig(
            host: host.hostname,
            port: host.port,
            username: host.username,
            privateKeyPEM: privateKeyPEM
        )

        let reachable: Bool
        do {
            let result = try await executor.exec(config, command: "true")
            reachable = result.exitCode == 0
        } catch {
            reachable = false
        }

        if reachable {
            // Hop back explicitly: `executor.exec` may resume on a SwiftNIO event loop thread
            // rather than the caller's actor, and `HostEntity` is a SwiftData model that should
            // only be mutated on the main actor (where its `ModelContext` lives).
            await MainActor.run {
                host.lastReachableAt = Date()
            }
        }

        return reachable
    }
}
