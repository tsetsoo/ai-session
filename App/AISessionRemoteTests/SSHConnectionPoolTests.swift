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

    func exec(_ command: String) async throws -> SSHExecResult {
        if let error = failNextExecWith {
            failNextExecWith = nil
            isAlive = false
            throw error
        }
        return SSHExecResult(exitCode: 0, stdout: "ok", stderr: "")
    }

    func close() async {
        closeCount += 1
        isAlive = false

        lock.lock()
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
}

final class SSHConnectionPoolTests: XCTestCase {
    private func config(
        host: String = "example.com",
        user: String = "tester",
        key: Data = Data([1, 2, 3])
    ) -> HostConnectionConfig {
        HostConnectionConfig(host: host, port: 22, username: user, privateKeyPEM: key)
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
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor ConnectionBox {
    private var connections: [FakeConnection] = []
    func add(_ connection: FakeConnection) { connections.append(connection) }
    func last() -> FakeConnection? { connections.last }
    func failNextExecOnLast(_ error: Error) { connections.last?.failNextExecWith = error }
    func lastCloseCount() -> Int { connections.last?.closeCount ?? 0 }
    func totalCloseCount() -> Int { connections.reduce(0) { $0 + $1.closeCount } }
}
