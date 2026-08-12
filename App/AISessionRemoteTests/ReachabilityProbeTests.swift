import AISessionCore
import XCTest
@testable import AISessionRemote

/// An `SSHExecuting` that never completes and never even checks cancellation — models a dial
/// that hangs (or would only unblock after its own internal, multi-second deadlines), which is
/// exactly the shape of failure `ReachabilityProbe`'s own deadline exists to bound.
private struct HangingExecutor: SSHExecuting {
    func exec(_ config: HostConnectionConfig, command: String) async throws -> SSHExecResult {
        try await withCheckedThrowingContinuation { (_: CheckedContinuation<SSHExecResult, Error>) in
            // Deliberately never resumed.
        }
    }
}

private actor ResultBox {
    private(set) var value: Bool?
    func set(_ value: Bool) { self.value = value }
}

final class ReachabilityProbeTests: XCTestCase {
    /// Regression test for a deadline implementation that raced the operation against a timer
    /// inside a `withThrowingTaskGroup`: a task group's body cannot return until every child task
    /// finishes, even a cancelled one, so a hung operation silently defeated the deadline and the
    /// call only ever returned once the operation itself gave up (which, for a real dial, could
    /// be up to the NIO connect timeout or handshake deadline). The injected `sleep` resolves
    /// immediately so the deadline "wins" as fast as the test scheduler allows, and the whole
    /// assertion is wrapped in `fulfillment(of:timeout:)` — which has its own real, independent
    /// timeout — rather than a bare `await`, so if `isReachable` regresses back to blocking on
    /// the hung executor, this test fails after 5s instead of hanging the suite forever.
    func testIsReachableReturnsPromptlyWhenTheUnderlyingCallNeverCompletes() async throws {
        let config = HostConnectionConfig(host: "example.com", port: 22, username: "tester", privateKeyPEM: Data([1, 2, 3]))
        let probe = ReachabilityProbe(
            executor: HangingExecutor(),
            deadlineSeconds: 8,
            sleep: { _ in /* resolve the deadline immediately, deterministically */ }
        )
        let box = ResultBox()
        let returned = expectation(description: "isReachable returns despite a hung underlying call")

        Task {
            let result = await probe.isReachable(config)
            await box.set(result)
            returned.fulfill()
        }

        await fulfillment(of: [returned], timeout: 5)
        let result = await box.value
        XCTAssertEqual(result, false, "a hung underlying call must be treated as unreachable, not left unresolved")
    }
}
