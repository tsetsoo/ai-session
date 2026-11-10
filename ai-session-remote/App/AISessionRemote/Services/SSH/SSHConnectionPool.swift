import AISessionCore
import Crypto
import Foundation

/// Reuses authenticated SSH connections, opening another when all channels are occupied.
/// Reservations count both pending opens and live terminals so concurrent callers cannot
/// exceed the per-connection budget while a dial is in flight.
///
/// This is the same idea as OpenSSH's `ControlMaster`/`ControlPersist`.
actor SSHConnectionPool {
    private struct Entry {
        let id = UUID()
        var connection: any PooledConnecting
        var leases: Int
        var channelLimit: Int
        var idleTask: Task<Void, Never>?
    }

    private struct Lease {
        let key: String
        let id: UUID
        let connection: any PooledConnecting
    }

    private let maximumChannelsPerConnection: Int
    private let idleTimeout: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let dial: @Sendable (HostConnectionConfig) async throws -> any PooledConnecting

    private var entries: [String: Entry] = [:]
    private struct PendingDial {
        let id = UUID()
        let task: Task<any PooledConnecting, Error>
    }
    private var dialsInFlight: [String: PendingDial] = [:]

    /// Bumped by `closeAll()`. A dial that was still in flight when a teardown happened checks
    /// this the moment it resolves: if the generation has moved on, the pool has been torn
    /// down and the dial must not resurrect it, no matter how late it completes.
    private var generation = 0

    /// Count of times a caller resumed from an *already in-flight* dial (the coalescing branch
    /// of `connection(for:)`), rather than owning the dial itself. A genuine production counter
    /// — it is incremented on every real coalesced call, not just under test — kept small and
    /// cheap enough that there is no reason to gate it behind a test flag. It is exposed via
    /// `coalescedJoinCount()` so a test can deterministically wait for "a second caller has
    /// genuinely joined the first caller's dial" instead of guessing at scheduling order.
    private var coalescedDialJoinCount = 0

    init(
        maximumChannelsPerConnection: Int = 8,
        idleTimeout: Duration = .seconds(60),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        dial: @escaping @Sendable (HostConnectionConfig) async throws -> any PooledConnecting
    ) {
        precondition(maximumChannelsPerConnection > 0)
        self.maximumChannelsPerConnection = maximumChannelsPerConnection
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
    /// `timeoutSeconds` bounds this command only — it is not baked into the connection, so two
    /// callers with different timeout expectations against the same host (e.g. a fast-fail
    /// reachability probe and a real session command) can safely share the one pooled
    /// connection without either one's budget leaking onto the other's command.
    ///
    /// The retry is scoped to failures that are provably free of side effects: only a failure
    /// that happened while *opening the child channel* for this command — reported by a
    /// `PooledConnecting` implementation as `SSHChannelOpenFailure` rather than a plain
    /// `SSHRemoteError` — is retried, because in that case the command was never delivered to
    /// the host. A dead connection is evicted first. A still-live connection is preserved
    /// for its current users, and the retry reserves a channel on another connection. Only a
    /// second failure reaches the caller.
    ///
    /// A failure that happens *after* the child channel opened — a command timeout, the channel
    /// dying mid-command — is never retried here, no matter how it leaves `isAlive`: the command
    /// may already have run on the host (e.g. `tmux new-session`), and re-running it could double
    /// it up rather than merely retrying it. That failure still surfaces to the caller as the
    /// plain `SSHRemoteError` it actually is.
    func exec(_ config: HostConnectionConfig, command: String, timeoutSeconds: Int64 = 30) async throws -> SSHExecResult {
        return try await run(config, command: command, timeoutSeconds: timeoutSeconds, allowRetry: true)
    }

    /// Dials ahead of time so the next real action is fast. Failures are deliberately silent:
    /// the user did not ask for this, and the action that follows will report any real problem.
    func warm(_ config: HostConnectionConfig) {
        Task { [weak self] in
            guard let self else { return }
            // `connection(for:)` always hands back a held lease (see its doc comment); warming
            // isn't a real command, so give that lease straight back rather than pinning the
            // connection open until the idle timer would have fired anyway.
            guard let lease = try? await self.connection(for: config) else { return }
            await self.releaseLease(lease)
        }
    }

    /// Opens a PTY on the pooled connection for `config`, holding a lease for as long as the
    /// returned handle stays open — i.e. for the life of the attached terminal, which can run
    /// for hours — so the idle timer never closes the connection out from under an
    /// actively-used terminal (see the type-level doc comment on why that idle timer exists).
    ///
    /// The lease is released exactly once, whichever happens first: the caller closing the
    /// returned handle (a deliberate detach) or `onClose` firing on its own (remote exit,
    /// network drop). Both can fire — sometimes both, racing, for the same session — so the
    /// release is guarded against running twice; a second release would otherwise silently
    /// steal a lease legitimately held by some other concurrent use of the same connection.
    func openPTY(
        _ config: HostConnectionConfig,
        mode: TerminalMode,
        cols: Int,
        rows: Int,
        onOutput: @escaping ([UInt8]) -> Void,
        onClose: @escaping (Int?) -> Void
    ) async throws -> PTYHandle {
        return try await openPTY(config, mode: mode, cols: cols, rows: rows,
                                 onOutput: onOutput, onClose: onClose, excluding: nil, allowRetry: true)
    }

    private func openPTY(
        _ config: HostConnectionConfig, mode: TerminalMode, cols: Int, rows: Int,
        onOutput: @escaping ([UInt8]) -> Void, onClose: @escaping (Int?) -> Void,
        excluding: String?, allowRetry: Bool
    ) async throws -> PTYHandle {
        let lease = try await connection(for: config, excluding: excluding)
        let connection = lease.connection

        let delivery = PTYCloseDelivery(onClose)
        let releaseOnce = OnceFlag()
        let release: @Sendable () -> Void = { [weak self] in
            Task { [weak self] in
                guard await releaseOnce.claim() else { return }
                await self?.releaseLease(lease)
            }
        }

        do {
            let handle = try await connection.openPTY(
                mode: mode,
                cols: cols,
                rows: rows,
                onOutput: onOutput,
                onClose: { exitStatus in
                    delivery.receive(exitStatus)
                    release()
                }
            )
            delivery.activate()
            return PTYHandle(
                send: { handle.send($0) },
                resize: { handle.resize(cols: $0, rows: $1) },
                close: {
                    handle.close()
                    release()
                }
            )
        } catch {
            delivery.discard()
            // The lease taken by `connection(for:)` above must still be given back if opening
            // the channel itself fails — otherwise a failed `connect()` would leak it forever.
            // Release synchronously before reserving a replacement. Claiming here also
            // prevents a late onClose callback from releasing this reservation twice.
            if error is SSHChannelOpenFailure { noteChannelRejection(lease) }
            if await releaseOnce.claim() { releaseLease(lease) }
            guard allowRetry, error is SSHChannelOpenFailure else { throw error }
            return try await openPTY(config, mode: mode, cols: cols, rows: rows,
                                     onOutput: onOutput, onClose: onClose,
                                     excluding: lease.key, allowRetry: false)
        }
    }

    /// Called on `didEnterBackgroundNotification`: closes every connection this pool can afford
    /// to close right now, so a socket iOS is about to suspend anyway doesn't cost a full
    /// connect timeout the next time it's used.
    ///
    /// Deliberately does **not** touch an entry with `leases > 0` — most importantly, an
    /// attached terminal PTY, which holds its lease for as long as the terminal screen stays
    /// open (see `openPTY`). The terminal's channel is a child of the very same parent
    /// connection this closes, so closing a leased entry here would tear the terminal down on
    /// every brief backgrounding (switching apps for a few seconds, an incoming call), which is
    /// a regression against the app's behaviour before pooling existed — back then the terminal
    /// dialled its own connection and had nothing to do with this method. Only idle (unleased)
    /// connections are eager-closed, which is the actual point of doing this on backgrounding:
    /// there is no *use* being interrupted for those.
    ///
    /// A leased entry skipped here is not exempted forever: it is left fully registered, so the
    /// ordinary idle-eviction timer in `releaseLease`/`scheduleIdleEviction` takes over the
    /// moment its lease is later released — including while the app is still backgrounded — and
    /// closes it after `idleTimeout` exactly as it would have if `closeAll()` had never run.
    func closeAll() async {
        generation += 1
        let pendingDials = dialsInFlight.values.map(\.task)
        dialsInFlight.removeAll()
        for task in pendingDials {
            task.cancel()
        }
        let idleKeys = entries.filter { $0.value.leases == 0 }.map(\.key)
        for key in idleKeys {
            await evictIfIdle(key)
        }
    }

    // MARK: - Testing hooks
    //
    // Small, internal-only accessors so tests can assert on the pool's bookkeeping directly
    // instead of inferring it indirectly from eviction timing.

    /// Total reservations across connections for `config`, or `nil` if there are none. Exists for testing the lease-count invariant across a coalesced dial.
    func leaseCount(for config: HostConnectionConfig) -> Int? {
        let base = Self.key(for: config)
        let matching = entries.filter { $0.key == base || $0.key.hasPrefix(base + "|slot:") }
        return matching.isEmpty ? nil : matching.values.reduce(0) { $0 + $1.leases }
    }

    /// See `coalescedDialJoinCount`.
    func coalescedJoinCount() -> Int {
        coalescedDialJoinCount
    }

    // MARK: - Internals

    private func run(
        _ config: HostConnectionConfig,
        command: String,
        timeoutSeconds: Int64,
        allowRetry: Bool,
        excluding: String? = nil
    ) async throws -> SSHExecResult {
        let lease = try await connection(for: config, excluding: excluding)
        let connection = lease.connection

        do {
            let result = try await connection.exec(command, timeoutSeconds: timeoutSeconds)
            releaseLease(lease)
            return result
        } catch {
            if error is SSHChannelOpenFailure { noteChannelRejection(lease) }
            releaseLease(lease)
            // Only a channel-open failure is provably free of side effects — see the doc comment
            // on `exec` and on `SSHChannelOpenFailure` itself. Anything else (a command timeout,
            // the channel dying mid-command) is unwrapped and rethrown as-is, with no retry: the
            // command may already have run on the host.
            guard allowRetry, error is SSHChannelOpenFailure else {
                throw (error as? SSHChannelOpenFailure)?.underlying ?? error
            }
            // Only tear the connection down for every other caller currently sharing it if it
            // actually reports itself dead. A channel-open failure for a narrower, per-channel
            // reason (e.g. the host transiently refused a new session) leaves an otherwise
            // healthy connection in place. Retry elsewhere in case this one hit MaxSessions.
            if !connection.isAlive {
                await evict(lease.key, expectedID: lease.id)
            }
            return try await run(config, command: command, timeoutSeconds: timeoutSeconds,
                                 allowRetry: false, excluding: connection.isAlive ? lease.key : nil)
        }
    }

    /// Returns a connection for `config`, dialing one if needed. The caller always ends up
    /// holding exactly one counted lease on a registered entry when this returns successfully;
    /// it throws instead of returning if the dial fails, or if a `closeAll()` happened while
    /// the dial was in flight (in which case the freshly-dialled connection is closed rather
    /// than resurrecting the pool, and this surfaces to the caller as
    /// `SSHRemoteError.unreachable` — the same thing the caller would see if the host genuinely
    /// dropped off the network, not some internal bookkeeping type it has no business seeing).
    private func connection(for config: HostConnectionConfig, excluding: String? = nil) async throws -> Lease {
        let base = Self.key(for: config)
        var slot = 0
        var key = base
        // Never suspend between selecting an available slot and reserving it. Coalesced
        // dial waiters recheck capacity when they resume, before opening their channel.
        while key == excluding || (entries[key].map { $0.connection.isAlive && $0.leases >= $0.channelLimit } ?? false) {
            slot += 1
            key = base + "|slot:\(slot)"
        }

        if let entry = entries[key], entry.connection.isAlive {
            return acquireLease(key)
        }
        if let entry = entries[key] {
            await evict(key, expectedID: entry.id)
            // Closing a dead transport suspends; another caller may have replaced it.
            return try await self.connection(for: config, excluding: excluding)
        }

        let dialGeneration = generation

        // Coalesce: everyone arriving during a dial awaits the same task, so a list refresh
        // racing an attach produces one handshake rather than two. Both the dial's own
        // continuation and every coalesced waiter resume from the *same* underlying `Task`,
        // and nothing guarantees which one is scheduled onto the actor first. Whichever one
        // runs first executes `registerDialedConnection` — a synchronous, non-suspending call
        // — which creates the entry (with its first lease already taken) if it doesn't exist
        // yet; every later resumer for this key then just takes its own lease on the entry the
        // first one created. That keeps "connection produced" and "lease taken" atomic from
        // the idle-eviction task's perspective, for every caller, not just the dial's owner.
        if let inFlight = dialsInFlight[key] {
            coalescedDialJoinCount += 1
            let connection = try await inFlight.task.value
            switch registerDialedConnection(key: key, connection: connection, dialGeneration: dialGeneration, dialID: inFlight.id) {
            case .registered(let registered):
                return registered
            case .full:
                return try await self.connection(for: config, excluding: excluding)
            case .stale:
                // Closing a superseded connection more than once (every coalesced waiter that
                // observes `.stale` calls this independently) must be harmless — see the
                // idempotency contract on `PooledConnecting.close()`.
                await connection.close()
                throw SSHRemoteError.unreachable
            }
        }

        let pending = PendingDial(task: Task { [dial] in try await dial(config) })
        dialsInFlight[key] = pending
        let connection: any PooledConnecting
        do {
            connection = try await pending.task.value
        } catch {
            if dialsInFlight[key]?.id == pending.id { dialsInFlight[key] = nil }
            throw error
        }
        switch registerDialedConnection(key: key, connection: connection,
                                        dialGeneration: dialGeneration, dialID: pending.id) {
        case .registered(let registered): return registered
        case .full: return try await self.connection(for: config, excluding: excluding)
        case .stale:
            await connection.close()
            throw SSHRemoteError.unreachable
        }
    }

    private enum DialOutcome {
        case registered(Lease)
        case full
        case stale
    }

    /// Runs synchronously (no `await`, so no suspension point) the moment a dial for `key`
    /// resolves, whether for the dial's own continuation or a coalesced waiter's. See the call
    /// site in `connection(for:)` for why this must stay synchronous.
    private func registerDialedConnection(
        key: String,
        connection: any PooledConnecting,
        dialGeneration: Int,
        dialID: UUID
    ) -> DialOutcome {
        guard generation == dialGeneration else {
            // `closeAll()` ran while this dial was in flight. The pool has moved on; don't
            // resurrect it, and don't touch `dialsInFlight` — it may already hold a newer dial
            // for this same key.
            return .stale
        }

        if let entry = entries[key] {
            // A faster resumer registered this dial. A later replacement must not be
            // overwritten or have its pending dial cleared by an old waiter.
            guard entry.connection === connection, connection.isAlive else { return .stale }
            guard entry.leases < entry.channelLimit else { return .full }
            return .registered(acquireLease(key))
        }
        guard dialsInFlight[key]?.id == dialID else { return .stale }
        dialsInFlight[key] = nil

        entries[key] = Entry(connection: connection, leases: 0, channelLimit: maximumChannelsPerConnection, idleTask: nil)
        return .registered(acquireLease(key))
    }

    /// Treat a rejected open as evidence that this connection's usable capacity is lower
    /// than our default. Retain the lower ceiling for its lifetime so later requests skip
    /// it while full, but can reuse slots as existing channels close. Never update a newer
    /// connection that happens to occupy the same pool slot.
    private func noteChannelRejection(_ lease: Lease) {
        guard var entry = entries[lease.key], entry.id == lease.id else { return }
        entry.channelLimit = min(entry.channelLimit, max(1, entry.leases - 1))
        entries[lease.key] = entry
    }

    private func acquireLease(_ key: String) -> Lease {
        var entry = entries[key]!
        entry.leases += 1
        entry.idleTask?.cancel()
        entry.idleTask = nil
        entries[key] = entry
        return Lease(key: key, id: entry.id, connection: entry.connection)
    }

    private func releaseLease(_ lease: Lease) {
        let key = lease.key
        // A late close from an evicted connection must not steal a new connection's lease.
        guard var entry = entries[key], entry.id == lease.id else { return }
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

    private func evict(_ key: String, expectedID: UUID? = nil) async {
        guard let entry = entries[key], expectedID == nil || entry.id == expectedID else { return }
        entries.removeValue(forKey: key)
        entry.idleTask?.cancel()
        await entry.connection.close()
    }
}

/// Guards a lease release that can arrive twice for the same PTY — once from the caller
/// explicitly closing it, once from the channel dying on its own — so `SSHConnectionPool.openPTY`
/// can release its one lease exactly once no matter which order those two arrive in, or whether
/// both do.
private actor OnceFlag {
    private var claimed = false

    func claim() -> Bool {
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

/// A rejected child channel can close while openPTY is still pending. Do not report that
/// as a terminal disconnect if the pool can recover on another connection. A successful
/// channel that exits immediately still delivers its buffered exit status.
private final class PTYCloseDelivery: @unchecked Sendable {
    private enum State { case pending, active, discarded }
    private let lock = NSLock()
    private var state: State = .pending
    private var pendingStatus: Int??
    private let callback: (Int?) -> Void

    init(_ callback: @escaping (Int?) -> Void) { self.callback = callback }

    func receive(_ status: Int?) {
        lock.lock()
        switch state {
        case .pending:
            pendingStatus = .some(status)
            lock.unlock()
        case .active:
            state = .discarded
            lock.unlock()
            callback(status)
        case .discarded:
            lock.unlock()
        }
    }

    func activate() {
        lock.lock()
        let pending = pendingStatus
        pendingStatus = nil
        state = pending == nil ? .active : .discarded
        lock.unlock()
        if let status = pending { callback(status) }
    }

    func discard() {
        lock.lock()
        state = .discarded
        pendingStatus = nil
        lock.unlock()
    }
}
