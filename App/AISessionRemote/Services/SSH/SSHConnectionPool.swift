import AISessionCore
import Crypto
import Foundation

/// Holds one authenticated SSH connection per host and multiplexes every remote command over
/// it, so only the first action on a host pays the ~7 round trips of TCP handshake, key
/// exchange and user authentication.
///
/// This is the same idea as OpenSSH's `ControlMaster`/`ControlPersist`.
actor SSHConnectionPool {
    private struct Entry {
        var connection: any PooledConnecting
        var leases: Int
        var idleTask: Task<Void, Never>?
    }

    private let idleTimeout: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let dial: @Sendable (HostConnectionConfig) async throws -> any PooledConnecting

    private var entries: [String: Entry] = [:]
    private var dialsInFlight: [String: Task<any PooledConnecting, Error>] = [:]

    init(
        idleTimeout: Duration = .seconds(60),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        dial: @escaping @Sendable (HostConnectionConfig) async throws -> any PooledConnecting
    ) {
        self.idleTimeout = idleTimeout
        self.sleep = sleep
        self.dial = dial
    }

    /// Identity of a poolable connection. Includes a digest of the private key so that editing
    /// a host or rotating its key cannot silently reuse a connection authenticated as the
    /// previous user.
    nonisolated static func key(for config: HostConnectionConfig) -> String {
        let digest = SHA256.hash(data: config.privateKeyPEM)
        let fingerprint = digest.map { String(format: "%02x", $0) }.joined()
        return "\(config.hostID)|\(config.host)|\(config.port)|\(config.username)|\(fingerprint)"
    }

    /// Runs `command` on the pooled connection for `config`, dialing one if needed.
    ///
    /// If the cached connection turns out to be dead — Wi-Fi/cellular handoff, Tailscale
    /// re-route, iOS suspension — it is evicted and the command retried **once** on a fresh
    /// connection. Only a second failure reaches the caller.
    func exec(_ config: HostConnectionConfig, command: String) async throws -> SSHExecResult {
        return try await run(config, command: command, allowRetry: true)
    }

    /// Dials ahead of time so the next real action is fast. Failures are deliberately silent:
    /// the user did not ask for this, and the action that follows will report any real problem.
    func warm(_ config: HostConnectionConfig) {
        Task { [weak self] in
            _ = try? await self?.connection(for: config)
        }
    }

    func closeAll() async {
        let current = entries
        entries.removeAll()
        dialsInFlight.removeAll()
        for (_, entry) in current {
            entry.idleTask?.cancel()
            await entry.connection.close()
        }
    }

    // MARK: - Internals

    private func run(
        _ config: HostConnectionConfig,
        command: String,
        allowRetry: Bool
    ) async throws -> SSHExecResult {
        // No suspension point between obtaining the connection and acquiring its lease: both
        // lines below run synchronously on the actor once `connection(for:)` returns, so the
        // idle-eviction task cannot close this connection out from under us.
        let connection = try await connection(for: config)
        let key = Self.key(for: config)
        acquireLease(key)

        do {
            let result = try await connection.exec(command)
            releaseLease(key)
            return result
        } catch {
            releaseLease(key)
            guard allowRetry else { throw error }
            await evict(key)
            return try await run(config, command: command, allowRetry: false)
        }
    }

    private func connection(for config: HostConnectionConfig) async throws -> any PooledConnecting {
        let key = Self.key(for: config)

        if let entry = entries[key], entry.connection.isAlive {
            return entry.connection
        }
        if entries[key] != nil {
            await evict(key)
        }

        // Coalesce: everyone arriving during a dial awaits the same task, so a list refresh
        // racing an attach produces one handshake rather than two.
        if let inFlight = dialsInFlight[key] {
            return try await inFlight.value
        }

        let task = Task { [dial] in try await dial(config) }
        dialsInFlight[key] = task

        do {
            let connection = try await task.value
            dialsInFlight[key] = nil
            entries[key] = Entry(connection: connection, leases: 0, idleTask: nil)
            scheduleIdleEviction(key)
            return connection
        } catch {
            dialsInFlight[key] = nil
            throw error
        }
    }

    private func acquireLease(_ key: String) {
        guard var entry = entries[key] else { return }
        entry.leases += 1
        entry.idleTask?.cancel()
        entry.idleTask = nil
        entries[key] = entry
    }

    private func releaseLease(_ key: String) {
        guard var entry = entries[key] else { return }
        entry.leases = max(0, entry.leases - 1)
        entries[key] = entry
        if entry.leases == 0 {
            scheduleIdleEviction(key)
        }
    }

    private func scheduleIdleEviction(_ key: String) {
        guard var entry = entries[key], entry.leases == 0 else { return }
        entry.idleTask?.cancel()
        entry.idleTask = Task { [weak self, sleep, idleTimeout] in
            try? await sleep(idleTimeout)
            guard !Task.isCancelled else { return }
            await self?.evictIfIdle(key)
        }
        entries[key] = entry
    }

    private func evictIfIdle(_ key: String) async {
        guard let entry = entries[key], entry.leases == 0 else { return }
        await evict(key)
    }

    private func evict(_ key: String) async {
        guard let entry = entries.removeValue(forKey: key) else { return }
        entry.idleTask?.cancel()
        await entry.connection.close()
    }
}
