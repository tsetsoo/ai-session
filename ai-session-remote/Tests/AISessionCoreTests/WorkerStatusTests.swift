import XCTest
@testable import AISessionCore

final class WorkerStatusTests: XCTestCase {
    private func decode(_ json: String) throws -> Conversation {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Conversation.self, from: Data(json.utf8))
    }

    private let base = #""todo_id":"t","computer":{"id":"m","name":"Mac","hostname":"mac","port":22,"username":"me","created_at":"","updated_at":""},"cwd":"~/a","tmux_name":"n","session_id":"s","status":"waiting""#

    func testDecodesTheHubsWorkers() throws {
        let c = try decode(#"{\#(base),"workers":[{"id":"a1","state":"working","needs_you":true,"message":"Claude needs approval"},{"id":"a2","state":"done"}]}"#)
        XCTAssertEqual(c.workers, [WorkerStatus(id: "a1", state: "working", needsYou: true, message: "Claude needs approval"),
                                   WorkerStatus(id: "a2", state: "done")])
        XCTAssertNil(try decode("{\(base)}").workers, "older hubs send none")
        XCTAssertNil(try decode(#"{\#(base),"workers":[{"state":3}]}"#).workers, "an unreadable list is dropped, not the conversation")
    }

    func testHubStatusCorrectsTheTranscripts() {
        let workers = [
            DelegatedWorker(id: "a1", state: .working),
            DelegatedWorker(id: "a2", state: .stale),
            DelegatedWorker(id: "a3", state: .done),
            DelegatedWorker(id: "a4", state: .working),
        ]
        let hub = [WorkerStatus(id: "a1", state: "working", needsYou: true, message: "Claude needs approval"),
                   WorkerStatus(id: "a2", state: "working"),
                   WorkerStatus(id: "a3", state: "working", needsYou: true)]
        let merged = DelegatedWorker.merging(workers, hub: hub)
        XCTAssertTrue(merged[0].needsYou)
        XCTAssertEqual(merged[0].statusText(), "Claude needs approval")
        XCTAssertEqual(merged[1].state, .working, "silent inside one long tool call, but its hooks say it runs")
        XCTAssertFalse(merged[2].needsYou, "the transcript's finish is written last")
        XCTAssertEqual(merged[3], workers[3])
        XCTAssertEqual(DelegatedWorker.merging(workers, hub: nil), workers)
    }

    func testStripText() {
        let tally = WorkerTally(hub: [WorkerStatus(id: "a", state: "working"), WorkerStatus(id: "b", state: "working"),
                                      WorkerStatus(id: "c", state: "working", needsYou: true), WorkerStatus(id: "d", state: "done")])
        XCTAssertEqual(tally.summary, "2 working · 1 needs you · 1 done")
        XCTAssertTrue(tally.showsStrip)
        XCTAssertEqual(tally.active, 3)
        XCTAssertFalse(WorkerTally(hub: [WorkerStatus(id: "a", state: "working")]).showsStrip, "one card says it all")
        let chat = WorkerTally(workers: [DelegatedWorker(id: "a", state: .failed), DelegatedWorker(id: "b", state: .stale)])
        XCTAssertEqual(chat.summary, "1 working · 1 failed")
    }
}
