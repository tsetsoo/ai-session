import XCTest
@testable import AISessionCore

final class BoardTests: XCTestCase {
    private let mac = Computer(id: "m1", name: "Mac", hostname: "mac", username: "me")
    private let box = Computer(id: "m2", name: "Box", hostname: "box", username: "me")

    private func conv(_ todo: String, _ status: ConversationStatus, tmux: String? = nil,
                      created: String = "2026-10-16T10:00:00Z", computer: Computer? = nil) -> Conversation {
        Conversation(todoId: todo, computer: computer ?? mac, cwd: "~/x", tool: "claude",
                     tmuxName: tmux ?? "t-\(todo)", sessionId: "s-\(todo)", status: status, createdAt: created)
    }

    private func board(_ convs: [Conversation], todos: [Todo] = [], live: [String: Set<String>] = [:]) -> ConversationBoard {
        ConversationBoard(todos: todos, conversations: Dictionary(uniqueKeysWithValues: convs.map { ($0.todoId, $0) }), liveTmux: live)
    }

    func testDisplayStatusMapping() {
        XCTAssertEqual(ConversationDisplayStatus(.busy, tmuxAlive: nil), .working)
        XCTAssertEqual(ConversationDisplayStatus(.waiting, tmuxAlive: nil), .needsYou)
        XCTAssertEqual(ConversationDisplayStatus(.idle, tmuxAlive: nil), .idle)
        XCTAssertEqual(ConversationDisplayStatus(.unknown, tmuxAlive: nil), .idle)
        XCTAssertEqual(ConversationDisplayStatus(.closed, tmuxAlive: nil), .closed)
        XCTAssertEqual(ConversationDisplayStatus(.busy, tmuxAlive: true), .working)
        for s in ConversationStatus.allCases {
            XCTAssertEqual(ConversationDisplayStatus(s, tmuxAlive: false), .closed)
        }
        XCTAssertEqual(ConversationDisplayStatus.needsYou.label, "Needs you")
        XCTAssertEqual(ConversationDisplayStatus.working.label, "Working")
        XCTAssertEqual(ConversationDisplayStatus.idle.label, "Idle")
        XCTAssertEqual(ConversationDisplayStatus.closed.label, "Closed")
    }

    func testRunningNowExcludesClosedAndDeadTmux() {
        let b = board([
            conv("a", .busy), conv("b", .closed), conv("c", .idle, tmux: "gone"),
            conv("d", .idle, tmux: "other", computer: box),   // box not in liveTmux: unknown, kept
        ], live: ["m1": ["t-a"]])
        XCTAssertEqual(b.runningNow.map(\.todoId), ["a", "d"])
        XCTAssertEqual(b.status(forTodo: "c"), .closed)
        XCTAssertNil(b.status(forTodo: "zzz"))
    }

    func testOrderingAndShortcuts() {
        let all = [conv("b", .busy, created: "2026-10-16T10:00:00Z"),
                   conv("a", .busy, created: "2026-10-16T10:00:00Z"),
                   conv("c", .busy, created: "2026-10-16T11:00:00Z")]
        let b = board(all)
        XCTAssertEqual(b.runningNow.map(\.todoId), ["c", "a", "b"])
        XCTAssertEqual(b.conversation(atShortcut: 1)?.todoId, "c")
        XCTAssertNil(b.conversation(atShortcut: 0))
        XCTAssertNil(b.conversation(atShortcut: 4))
        let many = (0..<12).map { conv("t\(String(format: "%02d", $0))", .busy) }
        let bm = board(many)
        XCTAssertNotNil(bm.conversation(atShortcut: 9))
        XCTAssertNil(bm.conversation(atShortcut: 10))
    }

    func testNeedsYouKeepsRunningOrder() {
        let b = board([conv("a", .waiting, created: "2026-10-16T09:00:00Z"),
                       conv("b", .busy), conv("c", .waiting, created: "2026-10-16T11:00:00Z")])
        XCTAssertEqual(b.needsYou.map(\.todoId), ["c", "a"])
    }

    func testSectionCountsAndRunning() {
        let todos = [Todo(id: "a", section: .sp, title: "A"),
                     Todo(id: "b", section: .sp, title: "B", completed: true),
                     Todo(id: "c", section: .i, title: "C")]
        let b = board([conv("a", .waiting), conv("c", .busy), conv("x", .busy, computer: box)], todos: todos)
        XCTAssertEqual(b.openTodoCount(.sp), 1)
        XCTAssertEqual(b.openTodoCount(.i), 1)
        XCTAssertEqual(b.openTodoCount(.p), 0)
        XCTAssertTrue(b.sectionNeedsYou(.sp))
        XCTAssertFalse(b.sectionNeedsYou(.i))
        XCTAssertEqual(b.runningCount(computerID: "m1"), 2)
        XCTAssertEqual(b.runningCount(computerID: "m2"), 1)
        XCTAssertEqual(b.needsYouCount(computerID: "m1"), 1)
        XCTAssertEqual(b.needsYouCount(computerID: "m2"), 0)
    }

    func testAllListsRunningThenClosedNewestFirst() {
        let b = board([conv("a", .busy, created: "2026-10-16T09:00:00Z"),
                       conv("b", .closed, created: "2026-10-16T08:00:00Z"),
                       conv("c", .closed, created: "2026-10-16T12:00:00Z"),
                       conv("d", .idle, tmux: "gone", created: "2026-10-16T11:00:00Z")],
                      live: ["m1": ["t-a"]])
        XCTAssertEqual(b.all.map(\.todoId), ["a", "c", "d", "b"])
    }

    func testFirstSnapshotNeverNotifies() {
        XCTAssertEqual(StatusTransitions.newlyWaiting(previous: nil, current: [conv("a", .waiting)]), [])
    }

    func testNewlyWaiting() {
        let a = conv("a", .waiting), b = conv("b", .waiting), c = conv("c", .busy)
        let result = StatusTransitions.newlyWaiting(previous: ["a": .idle, "b": .waiting], current: [a, b, c])
        XCTAssertEqual(result, [a])
        // A conversation new since the last snapshot that is already waiting.
        XCTAssertEqual(StatusTransitions.newlyWaiting(previous: [:], current: [a]), [a])
    }

    /// Only a move *into* waiting counts: idle/busy → waiting and a new, already-waiting
    /// conversation do; still waiting and moves elsewhere don't.
    func testNewlyWaitingOnlyOnTransitionIntoWaiting() {
        let a = conv("a", .waiting), b = conv("b", .waiting), c = conv("c", .busy), d = conv("d", .waiting)
        XCTAssertEqual(
            StatusTransitions.newlyWaiting(previous: ["a": .busy, "b": .waiting, "c": .idle], current: [a, b, c, d]),
            [a, d]
        )
        XCTAssertEqual(StatusTransitions.newlyWaiting(previous: ["a": .waiting], current: [conv("a", .idle)]), [])
    }
}
