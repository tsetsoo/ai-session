import AISessionCore
import XCTest
@testable import AI_Session_Remote

@MainActor
final class StatusFreshnessTests: XCTestCase {
    func testFreshnessTracksHeartbeatFailuresAndRecoveryWithoutChangingActivity() throws {
        var now = Date(timeIntervalSince1970: 10_000)
        let model = AppModel(store: TodoHubStore(cache: TodoHubStore.scratchCache()), demo: false,
                             listTmux: { _ in [] }, now: { now })
        let computer = Computer(id: "monitor-test", name: "Mac", hostname: "mac", username: "me")
        let conversation = Conversation(todoId: "test", computer: computer, cwd: "~", tool: "codex",
                                        tmuxName: "test", sessionId: "session", status: .busy)
        XCTAssertEqual(model.statusFreshness(for: conversation, at: now).state, .checking)
        model.store.seedForDemo(todos: [], conversations: [conversation], computers: [computer])
        let data = Data(#"{"host_time_s":100,"codex":{"checked_ns":99000000000,"runtime_connected":true},"codex_runtime":{"observed_ns":99000000000,"threads":{"session":["busy",null]}}}"#.utf8)
        let snapshot = try StatusMonitorSnapshot(data: data, receivedAt: now)
        model.applyStatusMonitorSnapshot(snapshot, computerID: computer.id)
        XCTAssertEqual(model.statusFreshness(for: conversation, at: now).state, .live)
        let confirmed = now.addingTimeInterval(-1)
        now.addTimeInterval(30)
        model.applyStatusMonitorSnapshot(nil, computerID: computer.id, failure: .offline)
        XCTAssertEqual(model.statusFreshness(for: conversation, at: now),
                       StatusFreshness(state: .offline, lastConfirmedAt: confirmed))
        now.addTimeInterval(61)
        XCTAssertEqual(model.statusFreshness(for: conversation, at: now).state, .stale)
        model.applyStatusMonitorSnapshot(try StatusMonitorSnapshot(data: data, receivedAt: now), computerID: computer.id)
        XCTAssertEqual(model.statusFreshness(for: conversation, at: now).state, .live)
        XCTAssertEqual(conversation.status, .busy)
    }

    func testConnectedComputerWithStoppedMonitorIsUnavailableRatherThanOffline() throws {
        let now = Date()
        let model = AppModel(store: TodoHubStore(cache: TodoHubStore.scratchCache()), demo: false,
                             listTmux: { _ in [] }, now: { now })
        let computer = Computer(id: "monitor-test", name: "Mac", hostname: "mac", username: "me")
        let conversation = Conversation(todoId: "test", computer: computer, cwd: "~", tool: "claude",
                                        tmuxName: "test", sessionId: "session", status: .waiting)
        let data = Data(#"{"host_time_s":100,"claude":{"checked_ns":99000000000,"runtime_connected":false}}"#.utf8)
        model.applyStatusMonitorSnapshot(try StatusMonitorSnapshot(data: data, receivedAt: now), computerID: computer.id)
        XCTAssertEqual(model.statusFreshness(for: conversation, at: now).state, .unavailable)
    }
}
