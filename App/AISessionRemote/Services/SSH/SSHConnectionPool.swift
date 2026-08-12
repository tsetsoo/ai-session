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
    /// `timeoutSeconds` bounds this command only — it is not baked into the connection, so two
    /// callers with different timeout expectations against the same host (e.g. a fast-fail
    /// reachability probe and a real session command) can safely share the one pooled
    /// connection without either one's budget leaking onto the other's command.
    ///
    /// The retry is scoped to failures that are provably free of side effects: only a failure
    /// that happened while *opening the child channel* for this command — reported by a
    /// `PooledConnecting` implementation as `SSHChannelOpenFailure` rather than a plain
    /// `SSHRemoteError` — is retried, because in that case the command was never delivered to
    /// the host. If the cached connection also turns out to be dead — Wi-Fi/cellular handoff,
    /// Tailscale re-route, iOS suspension — it is evicted first and the retry dials a fresh one;
    /// if instead the connection reports itself still alive (a transient, per-command failure —
    /// e.g. the host briefly refused a new channel), the retry reuses that same connection
    /// rather than tearing it down for every other caller currently sharing it. Only a second
    /// failure reaches the caller.
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
            guard (try? await self.connection(for: config)) != nil else { return }
            await self.releaseLease(Self.key(for: config))
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
        onClose: @escaping () -> Void
    ) async throws -> PTYHandle {
        // Mirrors `run(_:command:...)`'s use of `connection(for:)` below: it never returns
        // without the caller already holding exactly one counted lease, taken with no
        // suspension point between the entry being created/found and the lease itself (see its
        // doc comment). Unlike `exec`, which gives that lease straight back the moment the
        // command finishes, the PTY holds onto this one lease for as long as the terminal
        // stays attached — there is deliberately no *second* `acquireLease` call here to back
        // that persistence; taking one would leave this lease permanently un-balanced by the
        // single release below, and the connection would never become idle-evictable again
        // even after the terminal disconnects.
        let connection = try await connection(for: config)
        let key = Self.key(for: config)

        let releaseOnce = OnceFlag()
        let release: @Sendable () -> Void = { [weak self] in
            Task { [weak self] in
                guard await releaseOnce.claim() else { return }
                await self?.releaseLease(key)
            }
        }

        do {
            let handle = try await connection.openPTY(
                mode: mode,
                cols: cols,
                rows: rows,
                onOutput: onOutput,
                onClose: {
                    onClose()
                    release()
                }
            )
            return PTYHandle(
                send: { handle.send($0) },
                resize: { handle.resize(cols: $0, rows: $1) },
                close: {
                    handle.close()
                    release()
                }
            )
        } catch {
            // The lease taken by `connection(for:)` above must still be given back if opening
            // the channel itself fails — otherwise a failed `connect()` would leak it forever.
            release()
            throw error
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
        let pendingDials = Array(dialsInFlight.values)
        dialsInFlight.removeAll()
        for task in pendingDials {
            task.cancel()
        }
        let idleKeys = entries.filter { $0.value.leases == 0 }.map(\.key)
        for key in idleKeys {
            await evict(key)
        }
    }

    // MARK: - Testing hooks
    //
    // Small, internal-only accessors so tests can assert on the pool's bookkeeping directly
    // instead of inferring it indirectly from eviction timing.

    /// The number of leases currently held on the entry for `config`, or `nil` if there is no
    /// entry. Exists for testing the lease-count invariant across a coalesced dial.
    func leaseCount(for config: HostConnectionConfig) -> Int? {
        entries[Self.key(for: config)]?.leases
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
        allowRetry: Bool
    ) async throws -> SSHExecResult {
        // `connection(for:)` never returns without the caller holding exactly one counted
        // lease on a registered entry — including for a coalesced dial, where the entry and
        // the first lease on it are created in the same synchronous tail that observes the
        // shared dial's result (see `connection(for:)`). There is deliberately no separate
        // lease-acquisition step here: adding one would reintroduce the gap between
        // "connection produced" and "lease taken" that a coalesced waiter used to fall through,
        // silently running with zero recorded lease.
        let connection = try await connection(for: config)
        let key = Self.key(for: config)

        do {
            let result = try await connection.exec(command, timeoutSeconds: timeoutSeconds)
            releaseLease(key)
            return result
        } catch {
            releaseLease(key)
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
            // healthy connection in place, so the retry reuses it instead of evicting it.
            if !connection.isAlive {
                await evict(key)
            }
            return try await run(config, command: command, timeoutSeconds: timeoutSeconds, allowRetry: false)
        }
    }

    /// Returns a connection for `config`, dialing one if needed. The caller always ends up
    /// holding exactly one counted lease on a registered entry when this returns successfully;
    /// it throws instead of returning if the dial fails, or if a `closeAll()` happened while
    /// the dial was in flight (in which case the freshly-dialled connection is closed rather
    /// than resurrecting the pool, and this surfaces to the caller as
    /// `SSHRemoteError.unreachable` — the same thing the caller would see if the host genuinely
    /// dropped off the network, not some internal bookkeeping type it has no business seeing).
    private func connection(for config: HostConnectionConfig) async throws -> any PooledConnecting {
        let key = Self.key(for: config)

        if let entry = entries[key], entry.connection.isAlive {
            acquireLease(key)
            return entry.connection
        }
        if entries[key] != nil {
            await evict(key)
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
            let connection = try await inFlight.value
            switch registerDialedConnection(key: key, connection: connection, dialGeneration: dialGeneration) {
            case .registered(let registered):
                return registered
            case .stale:
                // Closing a superseded connection more than once (every coalesced waiter that
                // observes `.stale` calls this independently) must be harmless — see the
                // idempotency contract on `PooledConnecting.close()`.
                await connection.close()
                throw SSHRemoteError.unreachable
            }
        }

        let task = Task { [dial] in try await dial(config) }
        dialsInFlight[key] = task

        do {
            let connection = try await task.value
            switch registerDialedConnection(key: key, connection: connection, dialGeneration: dialGeneration) {
            case .registered(let registered):
                return registered
            case .stale:
                await connection.close()
                throw SSHRemoteError.unreachable
            }
        } catch {
            // Only clear the slot if it's still ours: a stale dial superseded by `closeAll()`
            // must not clobber a newer dial that may have since started for the same key.
            if generation == dialGeneration {
                dialsInFlight[key] = nil
            }
            throw error
        }
    }

    private enum DialOutcome {
        case registered(any PooledConnecting)
        case stale
    }

    /// Runs synchronously (no `await`, so no suspension point) the moment a dial for `key`
    /// resolves, whether for the dial's own continuation or a coalesced waiter's. See the call
    /// site in `connection(for:)` for why this must stay synchronous.
    private func registerDialedConnection(
        key: String,
        connection: any PooledConnecting,
        dialGeneration: Int
    ) -> DialOutcome {
        guard generation == dialGeneration else {
            // `closeAll()` ran while this dial was in flight. The pool has moved on; don't
            // resurrect it, and don't touch `dialsInFlight` — it may already hold a newer dial
            // for this same key.
            return .stale
        }

        dialsInFlight[key] = nil

        if let entry = entries[key] {
            // A faster resumer for this same key already created the entry.
            acquireLease(key)
            return .registered(entry.connection)
        }

        entries[key] = Entry(connection: connection, leases: 1, idleTask: nil)
        return .registered(connection)
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
