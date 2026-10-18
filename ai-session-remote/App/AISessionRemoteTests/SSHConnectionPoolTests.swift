import AISessionCore
import XCTest
@testable import AISessionRemote

private final class FakeConnection: PooledConnecting, @unchecked Sendable {
    var isAlive = true
    var closeCount = 0
    /// When set, the next `exec` throws this once (wrapped as `SSHChannelOpenFailure`, exactly
    /// as the real `PooledSSHConnection` does for a failure that happens before the command is
    /// delivered) and then clears it, and also marks the connection dead — simulates a
    /// channel-open failure that genuinely took the transport down, e.g. a cached connection
    /// that turns out to be dead the moment a new channel is attempted on it.
    var failNextExecWith: Error?
    /// When set, the next `exec` throws this once (also wrapped as `SSHChannelOpenFailure`) and
    /// then clears it, *without* marking the connection dead — simulates a narrow, per-channel
    /// open failure (e.g. the host transiently refusing a new session) that leaves an
    /// otherwise-healthy connection alive.
    var failNextExecKeepingAliveWith: Error?
    /// When set, the next `exec` throws this once **unwrapped** — exactly as a failure that
    /// happened *after* the command was already delivered to the host is reported for real
    /// (a command timeout, the channel dying mid-command) — and then clears it, without marking
    /// the connection dead (mirrors a half-open socket: `isAlive` can still read `true` even
    /// though the command that ran over it is never coming back). The pool must never retry
    /// this automatically: the command may already have run on the host.
    var failNextExecMidCommandWith: Error?
    /// Every `timeoutSeconds` value `exec` was called with, in call order. Lets a test assert
    /// that the timeout is threaded through per call rather than fixed at construction time, and
    /// its `count` doubles as a call counter for asserting a retry did or didn't happen.
    private(set) var recordedTimeouts: [Int64] = []

    private let lock = NSLock()
    private var closeContinuations: [CheckedContinuation<Void, Never>] = []

    // Lets a test hold `exec` calls open until it explicitly releases them, so it can observe
    // pool behaviour while N commands are genuinely, simultaneously still in flight instead of
    // guessing at timing. Off by default — `isExecGated` must be opted into — so the existing
    // tests that never call `releaseExec(matching:)` are unaffected and don't hang.
    //
    // Keyed by command rather than by arrival order: which of two racing callers becomes the
    // dial's "owner" (and so reaches `exec` first) is scheduling-dependent, not declaration-
    // order-dependent, so a test must release a specific command, not "whichever is next".
    var isExecGated = false
    private var pendingExecs: [(command: String, continuation: CheckedContinuation<Void, Never>)] = []
    private var pendingExecCount = 0
    private var pendingCountWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func exec(_ command: String, timeoutSeconds: Int64) async throws -> SSHExecResult {
        lock.lock()
        recordedTimeouts.append(timeoutSeconds)
        lock.unlock()
        if let error = failNextExecWith {
            failNextExecWith = nil
            isAlive = false
            // Match `PooledSSHConnection`: a failure before the command is delivered is wrapped
            // so the pool can tell it apart from a mid-command failure and safely retry once.
            throw SSHChannelOpenFailure(underlying: error)
        }
        if let error = failNextExecKeepingAliveWith {
            failNextExecKeepingAliveWith = nil
            throw SSHChannelOpenFailure(underlying: error)
        }
        if let error = failNextExecMidCommandWith {
            failNextExecMidCommandWith = nil
            // Unwrapped on purpose: the command may already have run on the host.
            throw error
        }
        if isExecGated {
            await holdExec(command: command)
        }
        return SSHExecResult(exitCode: 0, stdout: "ok", stderr: "")
    }

    /// Honors the `PooledConnecting.close()` contract: safe to call more than once, including
    /// concurrently from multiple callers that never coordinate with each other (exactly what
    /// happens when several coalesced waiters on one superseded dial each independently decide
    /// to close the connection they were handed). All the mutation is under `lock`, so
    /// concurrent calls serialize instead of racing on `closeCount`/`isAlive`.
    func close() async {
        lock.lock()
        closeCount += 1
        isAlive = false
        let pending = closeContinuations
        closeContinuations.removeAll()
        lock.unlock()

        for continuation in pending {
            continuation.resume()
        }
    }

    /// Suspends until `close()` has run at least once, or `timeout` elapses. Returns `true` if
    /// close was observed; `false` on timeout so the caller can `XCTFail` with a clear message
    /// instead of hanging CI forever on a regression.
    func waitForClose(timeout: Duration = .seconds(5)) async -> Bool {
        await withTimeout(timeout) {
            self.lock.lock()
            if self.closeCount > 0 {
                self.lock.unlock()
                return
            }
            await withCheckedContinuation { continuation in
                self.closeContinuations.append(continuation)
                self.lock.unlock()
            }
        }
    }

    /// Blocks the calling `exec` until `releaseExec(matching: command)` is called for it.
    private func holdExec(command: String) async {
        lock.lock()
        pendingExecCount += 1
        var toResume: [CheckedContinuation<Void, Never>] = []
        pendingCountWaiters.removeAll { waiter in
            if pendingExecCount >= waiter.target {
                toResume.append(waiter.continuation)
                return true
            }
            return false
        }
        lock.unlock()

        for continuation in toResume {
            continuation.resume()
        }

        await withCheckedContinuation { continuation in
            lock.lock()
            pendingExecs.append((command: command, continuation: continuation))
            lock.unlock()
        }
    }

    /// Releases the currently-blocked `exec` call for `command`, letting it return its result.
    func releaseExec(matching command: String) {
        lock.lock()
        guard let index = pendingExecs.firstIndex(where: { $0.command == command }) else {
            lock.unlock()
            return
        }
        let continuation = pendingExecs.remove(at: index).continuation
        lock.unlock()
        continuation.resume()
    }

    /// Suspends until at least `count` `exec` calls are simultaneously blocked in `holdExec`,
    /// or `timeout` elapses. Returns `true` if the count was reached.
    func waitForPendingExecCount(_ count: Int, timeout: Duration = .seconds(5)) async -> Bool {
        await withTimeout(timeout) {
            self.lock.lock()
            if self.pendingExecCount >= count {
                self.lock.unlock()
                return
            }
            await withCheckedContinuation { continuation in
                self.pendingCountWaiters.append((target: count, continuation: continuation))
                self.lock.unlock()
            }
        }
    }

    // MARK: - PTY

    /// When set, the next `openPTY` throws this once and then clears it.
    var failNextOpenPTYWith: Error?
    private(set) var openPTYCount = 0
    /// The `onClose` callback `SSHConnectionPool.openPTY` wired up for each PTY this connection
    /// has opened, in call order. A test "kills" a PTY's channel (simulating a remote exit or
    /// network drop, independent of the caller ever calling `PTYHandle.close()`) by invoking
    /// one of these directly.
    private var ptyOnCloseCallbacks: [(Int?) -> Void] = []

    /// When set, `openPTY` suspends on this gate before returning — lets a test hold a
    /// `connect()` call genuinely suspended mid-`openPTY` (rather than guessing at timing) so it
    /// can race something else — e.g. `disconnect()` — against it.
    var openPTYGate: OneShotGate?
    private var openPTYStarted = false
    private var openPTYStartedWaiters: [CheckedContinuation<Void, Never>] = []

    func openPTY(
        mode: TerminalMode,
        cols: Int,
        rows: Int,
        onOutput: @escaping ([UInt8]) -> Void,
        onClose: @escaping (Int?) -> Void
    ) async throws -> PTYHandle {
        lock.lock()
        openPTYStarted = true
        let waiters = openPTYStartedWaiters
        openPTYStartedWaiters.removeAll()
        lock.unlock()
        for waiter in waiters { waiter.resume() }

        if let gate = openPTYGate {
            await gate.wait()
        }

        lock.lock()
        if let error = failNextOpenPTYWith {
            failNextOpenPTYWith = nil
            lock.unlock()
            throw error
        }
        openPTYCount += 1
        ptyOnCloseCallbacks.append(onClose)
        lock.unlock()

        return PTYHandle(send: { _ in }, resize: { _, _ in }, close: {})
    }

    /// Suspends until `openPTY` has been called at least once — and, if `openPTYGate` is set,
    /// is now genuinely blocked on it rather than merely about to be called — or until
    /// `timeout` elapses. Returns `true` if openPTY has started.
    func waitForOpenPTYStarted(timeout: Duration = .seconds(5)) async -> Bool {
        await withTimeout(timeout) {
            self.lock.lock()
            if self.openPTYStarted {
                self.lock.unlock()
                return
            }
            await withCheckedContinuation { continuation in
                self.openPTYStartedWaiters.append(continuation)
                self.lock.unlock()
            }
        }
    }

    /// Simulates the most recently opened PTY's channel dying on its own (remote exit, network
    /// drop) by invoking the `onClose` callback the pool wired up when it was opened.
    func killMostRecentPTY(exitStatus: Int? = nil) {
        lock.lock()
        let callback = ptyOnCloseCallbacks.last
        lock.unlock()
        callback?(exitStatus)
    }
}

/// Races `operation` against a sleep of `timeout`. Returns `true` if the operation finished
/// first, `false` if the timeout won — so a hung wait becomes a fast, clear test failure
/// instead of hanging CI.
private func withTimeout(
    _ timeout: Duration,
    operation: @escaping @Sendable () async -> Void
) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            await operation()
            return true
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return false
        }
        let won = await group.next() ?? false
        group.cancelAll()
        return won
    }
}

/// A single-use gate an injected `dial` closure can `wait()` on. Lets a test hold a dial open
/// deterministically (rather than via a sleep) until it has confirmed other callers have had a
/// chance to coalesce onto it.
private actor OneShotGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

final class SSHConnectionPoolTests: XCTestCase {
    private func config(
        host: String = "example.com",
        user: String = "tester",
        key: Data = Data([1, 2, 3])
    ) -> HostConnectionConfig {
        HostConnectionConfig(host: host, port: 22, username: user, privateKeyPEM: key)
    }

    /// Runs `pool.exec` and captures success/failure as a value instead of a thrown error, so
    /// several racing calls can be started with `async let` and their outcomes inspected
    /// afterwards without the first failure aborting the others via `try`.
    private func captured(
        _ pool: SSHConnectionPool,
        _ config: HostConnectionConfig,
        command: String
    ) async -> Result<SSHExecResult, Error> {
        do {
            return .success(try await pool.exec(config, command: command))
        } catch {
            return .failure(error)
        }
    }

    /// Polls `condition` until it returns `true`, or fails the test after `timeout`. Replaces
    /// unbounded `while { await Task.yield() }` spin loops so a regression fails fast.
    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        condition: @escaping () async -> Bool
    ) async {
        let reached = expectation(description: description)
        Task {
            while !(await condition()) {
                await Task.yield()
            }
            reached.fulfill()
        }
        await fulfillment(of: [reached], timeout: timeout)
    }

    /// The core promise: a burst of concurrent commands pays one handshake, not N.
    ///
    /// Strengthened beyond "dial count == 1": that alone would still pass if coalescing were
    /// deleted, because serialized callers would hit the cache after the first dial and still
    /// dial once. The dial is gated open only after `coalescedJoinCount` confirms at least one
    /// waiter has joined the in-flight dial — the same gate used by the lease-invariant tests —
    /// so this actually requires the coalescing branch.
    func testConcurrentCallsShareASingleDial() async throws {
        let dialCount = Counter()
        let dialGate = OneShotGate()
        let pool = SSHConnectionPool(
            sleep: { _ in try await Task.sleep(nanoseconds: 1_000_000) },
            dial: { _ in
                await dialCount.increment()
                await dialGate.wait()
                return FakeConnection()
            }
        )
        let config = config()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask { _ = try await pool.exec(config, command: "tmux ls") }
            }

            await waitUntil("at least one caller coalesced onto the shared dial") {
                await pool.coalescedJoinCount() >= 1
            }
            await dialGate.open()
            try await group.waitForAll()
        }

        let count = await dialCount.value
        XCTAssertEqual(count, 1)
    }

    func testDifferentPrivateKeyForcesANewDial() async throws {
        let dialCount = Counter()
        let pool = SSHConnectionPool(
            sleep: { _ in try await Task.sleep(nanoseconds: 1_000_000) },
            dial: { _ in await dialCount.increment(); return FakeConnection() }
        )

        _ = try await pool.exec(config(key: Data([1])), command: "a")
        _ = try await pool.exec(config(key: Data([2])), command: "b")

        let count = await dialCount.value
        XCTAssertEqual(count, 2, "rotating the key must not reuse a connection authed with the old one")
    }

    /// Without this, pooling trades slowness for spurious "Could not reach the host" errors.
    func testDeadCachedConnectionIsEvictedAndRetriedOnce() async throws {
        let dialCount = Counter()
        let connections = ConnectionBox()
        let pool = SSHConnectionPool(
            sleep: { _ in try await Task.sleep(nanoseconds: 1_000_000) },
            dial: { _ in
                await dialCount.increment()
                let connection = FakeConnection()
                await connections.add(connection)
                return connection
            }
        )
        let config = config()

        _ = try await pool.exec(config, command: "first")
        await connections.failNextExecOnLast(SSHRemoteError.unreachable)

        let result = try await pool.exec(config, command: "second")

        XCTAssertEqual(result.stdout, "ok")
        let count = await dialCount.value
        XCTAssertEqual(count, 2, "one original dial plus one re-dial after eviction")
    }

    /// A command's timeout must reach the connection as a per-call argument, not something fixed
    /// when the connection was dialed — that's what lets one connection safely serve callers with
    /// different timeout expectations (e.g. a fast-fail reachability probe alongside a real
    /// session command) without either one's budget leaking onto the other's command.
    func testExecTimeoutIsThreadedPerCommandNotFixedAtDialTime() async throws {
        let connections = ConnectionBox()
        let pool = SSHConnectionPool(
            sleep: { _ in try await Task.sleep(nanoseconds: 1_000_000) },
            dial: { _ in
                let connection = FakeConnection()
                await connections.add(connection)
                return connection
            }
        )
        let config = config()

        _ = try await pool.exec(config, command: "a", timeoutSeconds: 5)
        _ = try await pool.exec(config, command: "b", timeoutSeconds: 60)

        guard let connection = await connections.last() else {
            XCTFail("expected a dialed connection")
            return
        }
        XCTAssertEqual(
            connection.recordedTimeouts, [5, 60],
            "each call's timeout must reach the connection independently"
        )
    }

    /// Regression test for a channel-open failure that does not implicate the shared transport —
    /// e.g. sshd transiently refusing a new session (MaxSessions/MaxStartups) while the
    /// connection itself is healthy. That must not evict/close the connection out from under
    /// every other caller sharing it; the pool's retry-once logic should reuse the same
    /// connection instead of redialing.
    func testChannelOpenFailureThatLeavesConnectionAliveIsNotEvicted() async throws {
        let dialCount = Counter()
        let connections = ConnectionBox()
        let pool = SSHConnectionPool(
            sleep: { _ in try await Task.sleep(nanoseconds: 1_000_000) },
            dial: { _ in
                await dialCount.increment()
                let connection = FakeConnection()
                await connections.add(connection)
                return connection
            }
        )
        let config = config()

        _ = try await pool.exec(config, command: "first")
        await connections.failNextExecKeepingAliveOnLast(SSHRemoteError.authenticationFailed)

        let result = try await pool.exec(config, command: "second")

        XCTAssertEqual(result.stdout, "ok", "the retry must succeed by reusing the still-alive connection")
        let count = await dialCount.value
        XCTAssertEqual(count, 1, "a failure that leaves the connection alive must not trigger a redial")
        guard let connection = await connections.last() else {
            XCTFail("expected a dialed connection")
            return
        }
        XCTAssertEqual(connection.closeCount, 0, "must not be evicted/closed when it reports itself still alive")
    }

    func testSecondFailurePropagates() async throws {
        let pool = SSHConnectionPool(
            sleep: { _ in try await Task.sleep(nanoseconds: 1_000_000) },
            dial: { _ in
                let connection = FakeConnection()
                connection.failNextExecWith = SSHRemoteError.unreachable
                return connection
            }
        )

        do {
            _ = try await pool.exec(config(), command: "boom")
            XCTFail("expected the retry to surface the underlying error")
        } catch let error as SSHRemoteError {
            XCTAssertEqual(error, .unreachable)
        }
    }

    /// The brief's version of this test paired a short idle timeout with a real `Task.sleep` in
    /// the test and hoped the eviction had happened by the time it woke up. That's a race: on a
    /// loaded CI machine the eviction task might not have been scheduled yet, or on a fast local
    /// run the sleep duration is just guesswork. Instead, the injected `sleep` closure returns
    /// immediately (there is nothing to gain from actually waiting out the timeout in a unit
    /// test) and the test awaits the real event it cares about — `close()` being called — via a
    /// continuation on the fake connection. This makes the test both instant and non-flaky.
    func testIdleConnectionIsClosedAfterTimeout() async throws {
        let connections = ConnectionBox()
        let pool = SSHConnectionPool(
            idleTimeout: .milliseconds(1),
            sleep: { _ in /* no-op: resolve the idle timer immediately, deterministically */ },
            dial: { _ in
                let connection = FakeConnection()
                await connections.add(connection)
                return connection
            }
        )

        _ = try await pool.exec(config(), command: "a")

        guard let connection = await connections.last() else {
            XCTFail("expected a dialed connection")
            return
        }
        let _ok1 = await connection.waitForClose()
        XCTAssertTrue(_ok1, "idle eviction must close the connection")
        let closes = await connections.lastCloseCount()
        XCTAssertEqual(closes, 1)
    }

    /// Idle connections are still torn down eagerly on backgrounding, which is the whole point
    /// of wiring `closeAll` to `didEnterBackgroundNotification`.
    func testCloseAllClosesEveryIdleConnection() async throws {
        let connections = ConnectionBox()
        let pool = SSHConnectionPool(
            sleep: { _ in try await Task.sleep(nanoseconds: 50_000_000) },
            dial: { _ in
                let connection = FakeConnection()
                await connections.add(connection)
                return connection
            }
        )

        _ = try await pool.exec(config(host: "a"), command: "x")
        _ = try await pool.exec(config(host: "b"), command: "y")
        await pool.closeAll()

        let total = await connections.totalCloseCount()
        XCTAssertEqual(total, 2)
    }

    /// Regression for the final-review finding that `closeAll()` used to ignore lease counts and
    /// tear down an attached terminal PTY on brief app backgrounding. A leased entry must survive;
    /// an idle one for a different host must still be closed.
    func testCloseAllSkipsLeasedConnectionsButClosesIdleOnes() async throws {
        let connections = ConnectionBox()
        let pool = SSHConnectionPool(
            idleTimeout: .milliseconds(1),
            sleep: { _ in },
            dial: { _ in
                let connection = FakeConnection()
                await connections.add(connection)
                return connection
            }
        )
        let terminalHost = config(host: "terminal.example")
        let idleHost = config(host: "idle.example")

        let handle = try await pool.openPTY(
            terminalHost, mode: .plainShell, cols: 80, rows: 24,
            onOutput: { _ in }, onClose: { _ in }
        )
        _ = try await pool.exec(idleHost, command: "warm")

        await pool.closeAll()

        let terminalConnection = await connections.connection(at: 0)
        let idleConnection = await connections.connection(at: 1)
        XCTAssertEqual(terminalConnection.closeCount, 0, "a leased terminal connection must survive closeAll()")
        XCTAssertEqual(idleConnection.closeCount, 1, "an idle connection must still be eager-closed")

        let leaseWhileAttached = await pool.leaseCount(for: terminalHost)
        XCTAssertEqual(leaseWhileAttached, 1)

        handle.close()
        let closedAfterRelease = await terminalConnection.waitForClose()
        XCTAssertTrue(
            closedAfterRelease,
            "after the PTY releases its lease, ordinary idle eviction must still close the connection"
        )
    }

    /// A mid-command failure (timeout, channel death after the command was delivered) must not
    /// be retried — re-running could duplicate a side-effecting command like `tmux new-session`.
    func testMidCommandFailureIsNotRetried() async throws {
        let dialCount = Counter()
        let connections = ConnectionBox()
        let pool = SSHConnectionPool(
            sleep: { _ in },
            dial: { _ in
                await dialCount.increment()
                let connection = FakeConnection()
                await connections.add(connection)
                return connection
            }
        )
        let config = config()

        _ = try await pool.exec(config, command: "first")
        await connections.failNextExecMidCommandOnLast(
            SSHRemoteError.commandFailed(exitCode: -1, stderr: "exec timed out")
        )

        do {
            _ = try await pool.exec(config, command: "tmux new-session")
            XCTFail("expected the mid-command failure to propagate")
        } catch let error as SSHRemoteError {
            XCTAssertEqual(error, .commandFailed(exitCode: -1, stderr: "exec timed out"))
        }

        let count = await dialCount.value
        XCTAssertEqual(count, 1, "a mid-command failure must not trigger a redial/retry")
        guard let connection = await connections.last() else {
            XCTFail("expected a dialed connection")
            return
        }
        XCTAssertEqual(
            connection.recordedTimeouts.count, 2,
            "first success + one failed attempt — never a second attempt after mid-command failure"
        )
    }

    /// `SSHConnectionPool.warm` is deliberately fire-and-forget (see its doc comment): dialing
    /// ahead of time is speculative, so a failure must never surface to the caller — the real
    /// action that follows is what should report any genuine problem. `warm` isn't even declared
    /// `throws`, which is a compile-time guarantee of that on its own; this test additionally
    /// confirms a failed warm leaves no stray bookkeeping behind (no leaked lease, no phantom
    /// entry) that could corrupt a later, real call for the same host.
    func testWarmSwallowsADialFailureAndLeavesNoTraceBehind() async throws {
        let dialAttempts = Counter()
        let pool = SSHConnectionPool(
            sleep: { _ in },
            dial: { _ in
                await dialAttempts.increment()
                throw SSHRemoteError.unreachable
            }
        )
        let config = config()

        await pool.warm(config)

        // `warm` fires its dial on an unstructured Task and exposes no completion signal — wait
        // until that dial has actually run before asserting it left nothing behind.
        await waitUntil("warm's fire-and-forget dial has run") {
            await dialAttempts.value >= 1
        }

        let leases = await pool.leaseCount(for: config)
        XCTAssertNil(leases, "a failed warm must not leave a dangling lease/entry")
    }

    /// `warm` dials ahead of time but must give its lease straight back once the connection is
    /// established (per its doc comment) — pinning the connection open until the idle timer
    /// would have fired anyway would defeat the point of having an idle timer. Uses the same
    /// "await close() as an event" pattern as `testIdleConnectionIsClosedAfterTimeout`.
    func testWarmReleasesItsLeaseSoTheConnectionRemainsIdleEvictable() async throws {
        let connections = ConnectionBox()
        let pool = SSHConnectionPool(
            idleTimeout: .milliseconds(1),
            sleep: { _ in /* resolve the idle timer immediately, deterministically */ },
            dial: { _ in
                let connection = FakeConnection()
                await connections.add(connection)
                return connection
            }
        )
        let config = config()

        await pool.warm(config)

        let connection = await connections.waitForFirst()
        let _ok2 = await connection.waitForClose()
        XCTAssertTrue(_ok2, "warm's lease must be released so idle eviction can close")
        XCTAssertEqual(connection.closeCount, 1, "warm's lease must be released, not held open")
    }

    /// Regression test for a reentrancy bug: a caller that *coalesces* onto an already
    /// in-flight dial (rather than owning it) could return from the pool's internals without
    /// ever having its lease counted, because the entry didn't exist yet when its continuation
    /// happened to resume. Its later release would then decrement a lease it never took, which
    /// could drive the count to zero — and trigger idle eviction — while another caller was
    /// still genuinely mid-command.
    ///
    /// Made deterministic (no sleeps, no scheduling assumptions) by gating the dial open only
    /// after confirming, via the pool's `coalescedJoinCount()` test hook, that a second caller
    /// has actually joined the first caller's in-flight dial — and by gating each `exec` so both
    /// commands are provably in flight at once before either is allowed to finish.
    func testCoalescedCallersEachHoldALeaseUntilTheyFinish() async throws {
        let connections = ConnectionBox()
        let dialGate = OneShotGate()
        let pool = SSHConnectionPool(
            idleTimeout: .milliseconds(1),
            sleep: { _ in /* resolve the idle timer immediately, deterministically */ },
            dial: { _ in
                let connection = FakeConnection()
                connection.isExecGated = true
                await connections.add(connection)
                await dialGate.wait()
                return connection
            }
        )
        let config = config()

        async let first: SSHExecResult = pool.exec(config, command: "a")
        async let second: SSHExecResult = pool.exec(config, command: "b")

        // Don't let the dial resolve until a second caller has genuinely joined it — otherwise
        // this test could pass merely because both callers happened to take the fast (already
        // cached) path, which never exercised the buggy branch in the first place.
        await waitUntil("second caller coalesced onto the shared dial") {
            await pool.coalescedJoinCount() >= 1
        }
        await dialGate.open()

        let connection = await connections.waitForFirst()
        let _ok3 = await connection.waitForPendingExecCount(2)
        XCTAssertTrue(_ok3, "both execs must be gated in flight")
        let leasesWhileBothInFlight = await pool.leaseCount(for: config)
        XCTAssertEqual(
            leasesWhileBothInFlight, 2,
            "both in-flight commands must be counted, including the one that coalesced onto the shared dial"
        )

        // Release by command name, not position: which of the two racing callers ends up
        // owning the dial (and so reaches `exec` first) is scheduling-dependent, not
        // declaration-order-dependent.
        connection.releaseExec(matching: "a")
        _ = try await first

        let leasesWithOneInFlight = await pool.leaseCount(for: config)
        XCTAssertEqual(leasesWithOneInFlight, 1)
        XCTAssertEqual(connection.closeCount, 0, "must not be evicted while the other caller is still mid-command")
        XCTAssertTrue(connection.isAlive)

        connection.releaseExec(matching: "b")
        _ = try await second

        let _ok4 = await connection.waitForClose()

        XCTAssertTrue(_ok4, "both leases released — idle eviction must close")
        XCTAssertEqual(connection.closeCount, 1)
    }

    /// Regression test for the "Important" half of the same reentrancy area: a dial that is
    /// still in flight when `closeAll()` runs must not resurrect the pool by registering itself
    /// after the fact. Deterministic: the dial is gated open only after `closeAll()` has
    /// already run, rather than raced against it.
    ///
    /// Also pins down that the failure a caller sees is the pool's ordinary, user-facing
    /// `SSHRemoteError.unreachable` — not an internal bookkeeping error type. An upcoming task
    /// wires `closeAll()` to app backgrounding, at which point a command in flight when the app
    /// backgrounds must fail the same way a genuinely dropped connection would, not with
    /// something that leaks pool internals into the UI.
    func testCloseAllDoesNotResurrectAConnectionFromAnInFlightDial() async throws {
        let connections = ConnectionBox()
        let dialGate = OneShotGate()
        let pool = SSHConnectionPool(
            sleep: { _ in },
            dial: { _ in
                let connection = FakeConnection()
                await connections.add(connection)
                await dialGate.wait()
                return connection
            }
        )
        let config = config()

        async let result = captured(pool, config, command: "a")

        await waitUntil("in-flight dial registered a connection") {
            await connections.count() >= 1
        }
        let connection = await connections.waitForFirst()
        await pool.closeAll()
        await dialGate.open()

        switch await result {
        case .success:
            XCTFail("a dial superseded by closeAll() must surface as a failure, not a stale success")
        case .failure(let error):
            guard let sshError = error as? SSHRemoteError else {
                XCTFail("expected SSHRemoteError.unreachable, got an internal error type: \(error)")
                return
            }
            XCTAssertEqual(sshError, .unreachable, "a superseded dial must read the same as a genuinely dead connection")
        }

        let _ok5 = await connection.waitForClose()

        XCTAssertTrue(_ok5, "a dial that finishes after teardown must still be closed")
        XCTAssertEqual(connection.closeCount, 1, "a dial that finishes after teardown must still be closed")

        let leases = await pool.leaseCount(for: config)
        XCTAssertNil(leases, "a late-completing dial must not resurrect an entry in the pool")
    }

    /// Regression test for a second defect in the same fix: when a superseded dial has *more
    /// than one* coalesced waiter, each of them independently observes `.stale` and calls
    /// `close()` on the same connection — nobody coordinates who "owns" closing it. This pins
    /// down both that every waiter sees the pool-facing `.unreachable` error and that closing
    /// the same connection multiple times (here: concurrently, from three racing callers) is
    /// harmless, per the idempotency contract on `PooledConnecting.close()`.
    func testCloseAllSupersedesEveryCoalescedWaiterAndRepeatedCloseIsHarmless() async throws {
        let connections = ConnectionBox()
        let dialGate = OneShotGate()
        let pool = SSHConnectionPool(
            sleep: { _ in },
            dial: { _ in
                let connection = FakeConnection()
                await connections.add(connection)
                await dialGate.wait()
                return connection
            }
        )
        let config = config()

        async let first = captured(pool, config, command: "a")
        async let second = captured(pool, config, command: "b")
        async let third = captured(pool, config, command: "c")

        // Wait for at least two of the three to have genuinely coalesced onto the one dial
        // (the third is the dial's owner) before tearing down, so this test exercises multiple
        // waiters racing the same superseded dial, not just one.
        await waitUntil("two callers coalesced onto the shared dial") {
            await pool.coalescedJoinCount() >= 2
        }

        await waitUntil("in-flight dial registered a connection") {
            await connections.count() >= 1
        }
        let connection = await connections.waitForFirst()
        await pool.closeAll()
        await dialGate.open()

        for result in await [first, second, third] {
            switch result {
            case .success:
                XCTFail("every caller racing a superseded dial must fail, none should get a stale success")
            case .failure(let error):
                XCTAssertEqual(error as? SSHRemoteError, .unreachable)
            }
        }

        let _ok6 = await connection.waitForClose()

        XCTAssertTrue(_ok6, "superseded connection must be closed")
        XCTAssertGreaterThanOrEqual(
            connection.closeCount, 1,
            "each of the three waiters independently closes the connection; that must be harmless, not a crash"
        )
        XCTAssertFalse(connection.isAlive)
    }

    // MARK: - PTY lease lifetime

    /// The core promise of running the terminal over the pool: an attached PTY must hold a
    /// lease for as long as it stays open, or the pool's idle timer would close the connection
    /// out from under a terminal that can legitimately stay attached for hours. Deterministic:
    /// the idle-eviction sleep resolves instantly, so if the lease were missing or given back
    /// too early, the connection would already be closed by the time this test checks it.
    func testOpenPTYHoldsALeaseThatPreventsIdleEvictionWhileAttached() async throws {
        let connections = ConnectionBox()
        let pool = SSHConnectionPool(
            idleTimeout: .milliseconds(1),
            sleep: { _ in /* resolve the idle timer immediately, deterministically */ },
            dial: { _ in
                let connection = FakeConnection()
                await connections.add(connection)
                return connection
            }
        )
        let config = config()

        let handle = try await pool.openPTY(
            config, mode: .plainShell, cols: 80, rows: 24,
            onOutput: { _ in }, onClose: { _ in }
        )

        let leaseWhileAttached = await pool.leaseCount(for: config)
        XCTAssertEqual(leaseWhileAttached, 1, "an attached PTY must hold exactly one lease")

        guard let connection = await connections.last() else {
            XCTFail("expected a dialed connection")
            return
        }
        // Give the idle-eviction machinery every chance to run erroneously; it must not fire,
        // because the lease above is still held.
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(connection.closeCount, 0, "must not be idle-evicted while the terminal is attached")

        handle.close()
        let _ok7 = await connection.waitForClose()
        XCTAssertTrue(_ok7, "closing the PTY must release the lease and allow eviction")
        XCTAssertEqual(connection.closeCount, 1, "closing the PTY must release the lease and allow eviction")
    }

    /// Regression test for double release: `disconnect()` (an explicit `close()`) and the
    /// channel dying on its own can both fire for the same PTY. If the lease they guard were
    /// released twice, the second release would silently steal a lease legitimately held by
    /// some other, genuinely concurrent use of the same connection — evicting it out from under
    /// that other caller. Here that other caller is a concurrent `exec`, held open so there is
    /// a real second lease available to (incorrectly) clobber.
    func testClosingPTYTwiceReleasesTheLeaseOnlyOnce() async throws {
        let connections = ConnectionBox()
        let pool = SSHConnectionPool(
            idleTimeout: .milliseconds(1),
            sleep: { _ in },
            dial: { _ in
                let connection = FakeConnection()
                connection.isExecGated = true
                await connections.add(connection)
                return connection
            }
        )
        let config = config()

        let handle = try await pool.openPTY(
            config, mode: .plainShell, cols: 80, rows: 24,
            onOutput: { _ in }, onClose: { _ in }
        )
        async let exec: SSHExecResult = pool.exec(config, command: "concurrent")

        guard let connection = await connections.last() else {
            XCTFail("expected a dialed connection")
            return
        }
        let _ok8 = await connection.waitForPendingExecCount(1)
        XCTAssertTrue(_ok8, "concurrent exec must be gated in flight")
        let leaseWithBothInFlight = await pool.leaseCount(for: config)
        XCTAssertEqual(leaseWithBothInFlight, 2, "the PTY and the concurrent exec must each hold their own lease")

        // Simulates `disconnect()` racing the channel's own exit callback: close the PTY twice.
        handle.close()
        handle.close()

        await waitUntil("PTY lease released exactly once") {
            await pool.leaseCount(for: config) == 1
        }
        let lease = await pool.leaseCount(for: config)
        XCTAssertEqual(
            lease, 1,
            "the PTY's lease must drop by exactly one, not two, leaving the concurrent exec's lease intact"
        )
        XCTAssertEqual(connection.closeCount, 0, "must not be evicted while the concurrent exec is still in flight")

        connection.releaseExec(matching: "concurrent")
        _ = try await exec
    }

    /// The PTY's remote exit status (e.g. 127 from `ai-todo-open` when helpers are missing) must
    /// reach the caller's `onClose` unchanged, and the lease must still be released exactly once.
    func testPTYCloseForwardsExitStatus() async throws {
        let connections = ConnectionBox()
        let pool = SSHConnectionPool(
            idleTimeout: .milliseconds(1),
            sleep: { _ in },
            dial: { _ in
                let connection = FakeConnection()
                connection.isExecGated = true
                await connections.add(connection)
                return connection
            }
        )
        let config = config()

        var observedStatus: Int?? = .none
        let handle = try await pool.openPTY(
            config, mode: .plainShell, cols: 80, rows: 24,
            onOutput: { _ in }, onClose: { observedStatus = .some($0) }
        )
        async let exec: SSHExecResult = pool.exec(config, command: "concurrent")

        guard let connection = await connections.last() else {
            XCTFail("expected a dialed connection")
            return
        }
        let ready = await connection.waitForPendingExecCount(1)
        XCTAssertTrue(ready, "concurrent exec must be gated in flight")
        connection.killMostRecentPTY(exitStatus: 127)

        await waitUntil("channel-death released the PTY lease") {
            await pool.leaseCount(for: config) == 1
        }
        XCTAssertEqual(observedStatus, .some(127), "the exit status must reach the caller's onClose")
        let lease = await pool.leaseCount(for: config)
        XCTAssertEqual(lease, 1, "the lease must still be released exactly once")

        handle.close()
        await waitUntil("explicit close after channel death does not release again") {
            await pool.leaseCount(for: config) == 1
        }
        let leaseAfterClose = await pool.leaseCount(for: config)
        XCTAssertEqual(leaseAfterClose, 1)

        connection.releaseExec(matching: "concurrent")
        _ = try await exec
    }

    /// The other ordering of the same regression: the channel can die on its own (remote exit,
    /// network drop) before `disconnect()` ever gets a chance to call `close()`. Both together
    /// must still add up to exactly one release, and the pool must still forward `onClose` to
    /// the caller (so `SSHTerminalSession`/`TerminalCoordinator` learns the terminal dropped).
    func testPTYChannelDyingOnItsOwnReleasesTheLeaseExactlyOnceEvenIfCloseIsCalledAfterward() async throws {
        let connections = ConnectionBox()
        let pool = SSHConnectionPool(
            idleTimeout: .milliseconds(1),
            sleep: { _ in },
            dial: { _ in
                let connection = FakeConnection()
                connection.isExecGated = true
                await connections.add(connection)
                return connection
            }
        )
        let config = config()

        var observedDisconnect = false
        let handle = try await pool.openPTY(
            config, mode: .plainShell, cols: 80, rows: 24,
            onOutput: { _ in }, onClose: { _ in observedDisconnect = true }
        )
        async let exec: SSHExecResult = pool.exec(config, command: "concurrent")

        guard let connection = await connections.last() else {
            XCTFail("expected a dialed connection")
            return
        }
        let _ok9 = await connection.waitForPendingExecCount(1)
        XCTAssertTrue(_ok9, "concurrent exec must be gated in flight")
        connection.killMostRecentPTY()

        await waitUntil("channel-death released the PTY lease") {
            await pool.leaseCount(for: config) == 1
        }
        let lease = await pool.leaseCount(for: config)
        XCTAssertEqual(lease, 1, "the channel dying on its own must release exactly one lease")
        XCTAssertTrue(observedDisconnect, "the pool must still forward onClose to the caller")

        // `disconnect()` can still call `close()` after the channel already died on its own.
        handle.close()
        await waitUntil("explicit close after channel death does not steal the exec lease") {
            await pool.leaseCount(for: config) == 1
        }
        // A few yields after the condition already holds — the assertion is the lease staying at 1,
        // not that something else happens. The waitUntil above already confirmed it settled at 1;
        // this second check catches a delayed double-release that would otherwise race past a
        // single sample.
        let leaseAfterExplicitCloseToo = await pool.leaseCount(for: config)
        XCTAssertEqual(
            leaseAfterExplicitCloseToo, 1,
            "an explicit close() after the channel already died must not double-release"
        )
        XCTAssertEqual(connection.closeCount, 0, "must not be evicted while the concurrent exec is still in flight")

        connection.releaseExec(matching: "concurrent")
        _ = try await exec
    }

    /// Regression test for a `connect()`/`disconnect()` race in `SSHTerminalSession` (not the
    /// pool directly): `disconnect()` firing while `connect()` is still suspended inside
    /// `pool.openPTY` used to latch `_isDisconnecting` while there was nothing yet in `_handle`
    /// to close, then get silently ignored once `connect()` resumed and unconditionally stored
    /// the now-orphaned handle — leaking the one lease `SSHConnectionPool.openPTY` had already
    /// taken on the shared pooled connection forever. Concretely:
    /// `TerminalScreen.onDisappear { coordinator.disconnect() }` firing while its
    /// `.task { await coordinator.connect() }` is still mid-handshake (e.g. backing out of a
    /// session on a slow network).
    ///
    /// Deterministic: `FakeConnection.openPTY` is gated so `connect()` is provably still
    /// suspended inside it (confirmed via `waitForOpenPTYStarted()`) before `disconnect()` runs,
    /// and a genuinely concurrent `exec` provides a second, real lease so the assertion can tell
    /// "released correctly" (settles at 1) apart from "leaked" (stuck at 2) or "double-released,
    /// stole the other caller's lease" (would go to 0).
    func testDisconnectDuringConnectDoesNotLeakTheLease() async throws {
        let connections = ConnectionBox()
        let openPTYGate = OneShotGate()
        let pool = SSHConnectionPool(
            idleTimeout: .milliseconds(1),
            sleep: { _ in },
            dial: { _ in
                let connection = FakeConnection()
                connection.isExecGated = true
                connection.openPTYGate = openPTYGate
                await connections.add(connection)
                return connection
            }
        )
        let config = config()
        let session = SSHTerminalSession(config: config, mode: .plainShell, pool: pool)

        async let connectOutcome: Void = session.connect(cols: 80, rows: 24)

        let connection = await connections.waitForFirst()
        let _ok10 = await connection.waitForOpenPTYStarted()
        XCTAssertTrue(_ok10, "connect() must reach openPTY")
        // A second, genuinely concurrent use of the same connection, so there is a real lease
        // available to prove the fix neither leaks its own lease nor steals this one.
        async let exec: SSHExecResult = pool.exec(config, command: "concurrent")
        let _ok11 = await connection.waitForPendingExecCount(1)
        XCTAssertTrue(_ok11, "concurrent exec must be gated in flight")
        let leaseWithBothInFlight = await pool.leaseCount(for: config)
        XCTAssertEqual(
            leaseWithBothInFlight, 2,
            "the in-flight connect() and the concurrent exec must each hold their own lease"
        )

        // `connect()` is suspended inside `pool.openPTY` -> `connection.openPTY`, holding the
        // lease `connection(for:)` already took for it, with nothing yet stored in `_handle`.
        // Disconnect while it's still stuck there.
        session.disconnect()

        // Let the gated `openPTY` resolve now that `disconnect()` has already run.
        await openPTYGate.open()
        try await connectOutcome

        await waitUntil("connect/disconnect race released the leaked lease") {
            await pool.leaseCount(for: config) == 1
        }
        let lease = await pool.leaseCount(for: config)
        XCTAssertEqual(
            lease, 1,
            "connect() losing the race to disconnect() must still release the lease it was holding, "
                + "leaving only the concurrent exec's"
        )

        connection.releaseExec(matching: "concurrent")
        _ = try await exec

        // With both leases now given back, the connection must become idle-evictable — it would
        // not if connect() had orphaned the handle it got back from the race.
        let _ok12 = await connection.waitForClose()
        XCTAssertTrue(_ok12, "both leases released — idle eviction must close")
        XCTAssertEqual(connection.closeCount, 1)
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor ConnectionBox {
    private var connections: [FakeConnection] = []
    private var firstWaiters: [CheckedContinuation<FakeConnection, Never>] = []

    func add(_ connection: FakeConnection) {
        connections.append(connection)
        if connections.count == 1 {
            let pending = firstWaiters
            firstWaiters.removeAll()
            for waiter in pending {
                waiter.resume(returning: connection)
            }
        }
    }

    func last() -> FakeConnection? { connections.last }
    func connection(at index: Int) -> FakeConnection {
        connections[index]
    }
    func failNextExecOnLast(_ error: Error) { connections.last?.failNextExecWith = error }
    func failNextExecKeepingAliveOnLast(_ error: Error) { connections.last?.failNextExecKeepingAliveWith = error }
    func failNextExecMidCommandOnLast(_ error: Error) { connections.last?.failNextExecMidCommandWith = error }
    func lastCloseCount() -> Int { connections.last?.closeCount ?? 0 }
    func totalCloseCount() -> Int { connections.reduce(0) { $0 + $1.closeCount } }
    func count() -> Int { connections.count }

    /// Suspends until at least one connection has been dialed, then returns the first one.
    /// Avoids polling while a gated dial is still in flight.
    ///
    /// Callers that need a hard timeout should wrap this with the test-case `waitUntil` against
    /// `count() > 0` first (or use a dial gate that is guaranteed to open); the continuation
    /// itself cannot be abandoned mid-wait without risking a double-resume when `add` later fires.
    func waitForFirst() async -> FakeConnection {
        if let existing = connections.first { return existing }
        return await withCheckedContinuation { continuation in
            firstWaiters.append(continuation)
        }
    }
}
