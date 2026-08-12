import AISessionCore
import XCTest
@testable import AISessionRemote

private final class FakeConnection: PooledConnecting, @unchecked Sendable {
    var isAlive = true
    var closeCount = 0
    /// When set, the next `exec` throws this once and then clears it.
    var failNextExecWith: Error?

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

    func exec(_ command: String) async throws -> SSHExecResult {
        if let error = failNextExecWith {
            failNextExecWith = nil
            isAlive = false
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

    /// Suspends until `close()` has run at least once. Lets a test observe eviction as an event
    /// rather than guessing how long it takes to happen.
    func waitForClose() async {
        lock.lock()
        if closeCount > 0 {
            lock.unlock()
            return
        }
        await withCheckedContinuation { continuation in
            closeContinuations.append(continuation)
            lock.unlock()
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

    /// Suspends until at least `count` `exec` calls are simultaneously blocked in `holdExec`.
    func waitForPendingExecCount(_ count: Int) async {
        lock.lock()
        if pendingExecCount >= count {
            lock.unlock()
            return
        }
        await withCheckedContinuation { continuation in
            pendingCountWaiters.append((target: count, continuation: continuation))
            lock.unlock()
        }
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

    /// The core promise: a burst of concurrent commands pays one handshake, not N.
    func testConcurrentCallsShareASingleDial() async throws {
        let dialCount = Counter()
        let pool = SSHConnectionPool(
            sleep: { _ in try await Task.sleep(nanoseconds: 1_000_000) },
            dial: { _ in
                await dialCount.increment()
                try await Task.sleep(nanoseconds: 10_000_000)
                return FakeConnection()
            }
        )
        let config = config()

        await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask { _ = try await pool.exec(config, command: "tmux ls") }
            }
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
        await connection.waitForClose()

        let closes = await connections.lastCloseCount()
        XCTAssertEqual(closes, 1)
    }

    func testCloseAllClosesEveryConnection() async throws {
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
        while await pool.coalescedJoinCount() < 1 {
            await Task.yield()
        }
        await dialGate.open()

        let connection = await connections.waitForFirst()
        await connection.waitForPendingExecCount(2)

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

        await connection.waitForClose()
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

        await connection.waitForClose()
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
        while await pool.coalescedJoinCount() < 2 {
            await Task.yield()
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

        await connection.waitForClose()
        XCTAssertGreaterThanOrEqual(
            connection.closeCount, 1,
            "each of the three waiters independently closes the connection; that must be harmless, not a crash"
        )
        XCTAssertFalse(connection.isAlive)
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
    func failNextExecOnLast(_ error: Error) { connections.last?.failNextExecWith = error }
    func lastCloseCount() -> Int { connections.last?.closeCount ?? 0 }
    func totalCloseCount() -> Int { connections.reduce(0) { $0 + $1.closeCount } }

    /// Suspends until at least one connection has been dialed, then returns the first one.
    /// Avoids polling while a gated dial is still in flight.
    func waitForFirst() async -> FakeConnection {
        if let existing = connections.first { return existing }
        return await withCheckedContinuation { continuation in
            firstWaiters.append(continuation)
        }
    }
}
