import XCTest
@testable import AISessionCore

/// One todo, several conversations: which get a tab, how they're labelled, the closed note,
/// the side-by-side grid, and which one the todo shows.
final class ConversationSwitcherTests: XCTestCase {
    private func c(_ id: String, _ tool: String, _ status: ConversationStatus, model: String? = nil,
                   created: String = "2026-11-07T10:00:00Z", main: Bool = false) -> Conversation {
        Conversation(
            id: id, todoId: "t", computer: Computer(id: "m", name: "Mac", hostname: "h", port: 22, username: "u"),
            cwd: "~/x", tool: tool, tmuxName: "ai/\(tool)/todo-\(id)", sessionId: "s-\(id)", status: status,
            createdAt: created, model: model, main: main
        )
    }

    func testOpenConversationsGetTabsOldestFirst() {
        let all = [
            c("b", "codex", .busy, created: "2026-11-07T10:05:00Z"),
            c("x", "claude", .closed),
            c("a", "claude", .idle, created: "2026-11-07T10:00:00Z"),
        ]
        XCTAssertEqual(ConversationSwitcherModel.tabs(all).map(\.id), ["a", "b"])
        XCTAssertTrue(ConversationSwitcherModel.showsSwitcher(all))
        XCTAssertFalse(ConversationSwitcherModel.showsSwitcher([all[0], all[1]]))
    }

    func testLabelsNameToolModelAndStatus() {
        XCTAssertEqual(ConversationSwitcherModel.label(c("a", "codex", .busy, model: "gpt-6.1")), "Codex · gpt-6.1")
        XCTAssertEqual(ConversationSwitcherModel.label(c("a", "claude", .idle)), "Claude")
        XCTAssertEqual(ConversationSwitcherModel.statusGlyph(.idle), "✓")
        XCTAssertEqual(ConversationSwitcherModel.statusGlyph(.busy), "…")
        XCTAssertEqual(ConversationSwitcherModel.statusGlyph(.waiting), "!")
        XCTAssertEqual(ConversationSwitcherModel.statusGlyph(.unknown), "")
    }

    func testClosedNote() {
        XCTAssertNil(ConversationSwitcherModel.closedNote([c("a", "claude", .idle)]))
        XCTAssertEqual(ConversationSwitcherModel.closedNote([c("a", "claude", .idle), c("b", "codex", .closed)]), "Codex attempt · closed")
        XCTAssertEqual(
            ConversationSwitcherModel.closedNote([c("a", "claude", .idle), c("b", "codex", .closed), c("d", "claude", .closed), c("e", "codex", .closed)]),
            "3 other attempts · closed"
        )
        // While several are open the switcher shows them; the note is for after Continue.
        XCTAssertNil(ConversationSwitcherModel.closedNote([c("a", "claude", .idle), c("b", "codex", .busy), c("d", "claude", .closed)]))
    }

    func testGridColumns() {
        XCTAssertEqual(ConversationSwitcherModel.gridColumns(2), 2)
        XCTAssertEqual(ConversationSwitcherModel.gridColumns(3), 2)
        XCTAssertEqual(ConversationSwitcherModel.gridColumns(4), 2)
        XCTAssertEqual(ConversationSwitcherModel.gridColumns(10), 2)
        XCTAssertEqual(ConversationSwitcherModel.gridColumns(1), 1)
    }

    func testElapsed() {
        let start = "2026-11-07T10:00:00Z"
        let now = ISO8601DateFormatter().date(from: "2026-11-07T10:14:30Z")!
        XCTAssertEqual(ConversationSwitcherModel.elapsed(since: start, now: now), "14 min")
        let later = ISO8601DateFormatter().date(from: "2026-11-07T12:05:00Z")!
        XCTAssertEqual(ConversationSwitcherModel.elapsed(since: start, now: later), "2 h 5 min")
        XCTAssertNil(ConversationSwitcherModel.elapsed(since: "", now: now))
    }

    func testTheMainConversationIsShownWhenOpen() {
        let all = [c("a", "claude", .busy), c("b", "codex", .idle, main: true)]
        XCTAssertEqual(ConversationSwitcherModel.preferred(all)?.id, "b")
        XCTAssertNil(ConversationSwitcherModel.preferred([c("a", "claude", .busy), c("b", "codex", .closed, main: true)]))
    }

    func testOthersStillBusyWhenContinuing() {
        let all = [c("a", "claude", .busy), c("b", "codex", .idle), c("d", "claude", .closed)]
        XCTAssertEqual(ConversationSwitcherModel.busyOthers(continuing: all[1], in: all).map(\.id), ["a"])
        XCTAssertEqual(ConversationSwitcherModel.busyOthers(continuing: all[0], in: all).map(\.id), [])
    }
}
