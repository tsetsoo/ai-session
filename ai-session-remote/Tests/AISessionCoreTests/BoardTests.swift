import XCTest
@testable import AISessionCore

final class BoardTests: XCTestCase {
    private let mac = Computer(id: "m1", name: "Mac", hostname: "mac", username: "me")
    private let box = Computer(id: "m2", name: "Box", hostname: "box", username: "me")

    private func conv(_ todo: String, _ status: ConversationStatus, tmux: String? = nil,
                      created: String = "2026-10-16T10:00:00Z", computer: Computer? = nil,
                      id: String? = nil) -> Conversation {
        Conversation(id: id ?? "c-\(todo)", todoId: todo, computer: computer ?? mac, cwd: "~/x", tool: "claude",
                     tmuxName: tmux ?? "t-\(todo)", sessionId: "s-\(todo)", status: status, createdAt: created)
    }

    private func board(_ convs: [Conversation], todos: [Todo] = [], live: [String: Set<String>] = [:]) -> ConversationBoard {
        ConversationBoard(todos: todos, conversations: Dictionary(uniqueKeysWithValues: convs.map { ($0.id, $0) }), liveTmux: live)
    }

    func testBoardListsBothConversations() {
        let idle = conv("t", .idle, created: "2026-10-16T12:00:00Z", id: "idle")
        let waiting = conv("t", .waiting, created: "2026-10-16T09:00:00Z", id: "wait")
        let b = board([idle, waiting])
        XCTAssertEqual(Set(b.open.map(\.id)), ["idle", "wait"])
        XCTAssertEqual(b.status(forTodo: "t"), .needsYou)
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
        XCTAssertEqual(ConversationDisplayStatus.idle.label, "Ready for review")
        XCTAssertEqual(ConversationDisplayStatus.closed.label, "Closed")
    }

    func testOpenExcludesClosedAndDeadTmux() {
        let b = board([
            conv("a", .busy), conv("b", .closed), conv("c", .idle, tmux: "gone"),
            conv("d", .idle, tmux: "other", computer: box),   // box not in liveTmux: unknown, kept
        ], live: ["m1": ["t-a"]])
        XCTAssertEqual(b.open.map(\.todoId), ["a", "d"])
        XCTAssertEqual(b.status(forTodo: "c"), .closed)
        XCTAssertNil(b.status(forTodo: "zzz"))
    }

    func testConversationNewerThanListingIsUnknownNotClosed() {
        let listed = HubDates.date(from: "2026-10-16T10:30:00Z")!
        let started = conv("new", .busy, created: "2026-10-16T10:45:00Z")
        let old = conv("old", .busy, created: "2026-10-16T10:00:00Z")
        var reported = conv("rep", .waiting, created: "2026-10-16T10:00:00Z")
        reported.statusUpdatedAt = "2026-10-16 10:40:00"    // the hub's SQLite spelling
        let b = ConversationBoard(
            todos: [], conversations: ["new": started, "old": old, "rep": reported],
            liveTmux: ["m1": []], listedAt: ["m1": listed]
        )
        // Started or reported after the listing: trust the hub until listed again.
        XCTAssertEqual(b.status(forTodo: "new"), .working)
        XCTAssertEqual(b.status(forTodo: "rep"), .needsYou)
        XCTAssertEqual(Set(b.open.map(\.todoId)), ["new", "rep"])
        XCTAssertEqual(b.needsYou.map(\.todoId), ["rep"])
        XCTAssertEqual(b.conversation(atShortcut: 1)?.todoId, "new")
        // Older than the listing and missing from it: closed.
        XCTAssertEqual(b.status(forTodo: "old"), .closed)
        XCTAssertEqual(Set(b.newerThanListing.map(\.todoId)), ["new", "rep"])
    }

    func testListedConversationIsNeverNewerThanListing() {
        let listed = HubDates.date(from: "2026-10-16T10:30:00Z")!
        let b = ConversationBoard(
            todos: [], conversations: ["a": conv("a", .busy, created: "2026-10-16T10:45:00Z")],
            liveTmux: ["m1": ["t-a"]], listedAt: ["m1": listed]
        )
        XCTAssertEqual(b.status(forTodo: "a"), .working)
        XCTAssertTrue(b.newerThanListing.isEmpty)
    }

    func testOrderingAndShortcuts() {
        let all = [conv("b", .busy, created: "2026-10-16T10:00:00Z"),
                   conv("a", .busy, created: "2026-10-16T10:00:00Z"),
                   conv("c", .busy, created: "2026-10-16T11:00:00Z")]
        let b = board(all)
        XCTAssertEqual(b.open.map(\.todoId), ["c", "a", "b"])
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

    func testWorkingAndReviewSplitTheOpenConversations() {
        var early = conv("early", .idle, created: "2026-10-16T08:00:00Z")
        early.statusUpdatedAt = "2026-10-16 12:00:00"   // started first, finished last
        let late = conv("late", .idle, created: "2026-10-16T11:00:00Z")
        let unknown = conv("unk", .unknown, created: "2026-10-16T09:00:00Z")
        let b = board([early, late, unknown, conv("busy", .busy), conv("wait", .waiting),
                       conv("gone", .idle, tmux: "gone"), conv("busy2", .busy, computer: box)],
                      live: ["m1": ["t-early", "t-late", "t-unk", "t-busy", "t-wait"]])
        XCTAssertEqual(b.review.map(\.todoId), ["early", "late", "unk"])
        XCTAssertEqual(Set(b.working.map(\.todoId)), ["busy", "busy2"])
        XCTAssertEqual(b.needsYou.map(\.todoId), ["wait"])
        XCTAssertEqual(b.reviewCount(computerID: "m1"), 3)
        XCTAssertEqual(b.workingCount(computerID: "m1"), 1)
        XCTAssertEqual(b.workingCount(computerID: "m2"), 1)
        XCTAssertEqual(b.conversation(atShortcut: 1, in: b.review)?.todoId, "early")
        XCTAssertNil(b.conversation(atShortcut: 4, in: b.review))
        assertAgrees(b)
    }

    func testDoneTodosLeaveReviewButStayOpen() {
        let todos = [Todo(id: "done", section: .sp, title: "Done", completed: true),
                     Todo(id: "doneBusy", section: .sp, title: "Done busy", completed: true),
                     Todo(id: "todo", section: .sp, title: "Open")]
        let b = board([conv("done", .idle), conv("doneBusy", .busy), conv("todo", .idle)], todos: todos,
                      live: ["m1": ["t-done", "t-doneBusy", "t-todo"]])
        XCTAssertEqual(b.review.map(\.todoId), ["todo"])
        XCTAssertEqual(b.reviewCount(computerID: "m1"), 1)
        XCTAssertEqual(b.working.map(\.todoId), ["doneBusy"])
        XCTAssertEqual(Set(b.open.map(\.todoId)), ["done", "doneBusy", "todo"])
        assertAgrees(b, todos: todos)
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
        XCTAssertEqual(b.openCount(computerID: "m1"), 2)
        XCTAssertEqual(b.openCount(computerID: "m2"), 1)
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

    /// Stored status, needs-you, counts and `all` are one snapshot. A path that parsed dates again
    /// and disagreed with `status(forTodo:)` fails here, including the cases above.
    func testPrecomputedStatusAgreesAcrossNeedsYouCountsAndAll() {
        let dead = board([
            conv("a", .busy), conv("b", .closed), conv("c", .idle, tmux: "gone"),
            conv("d", .idle, tmux: "other", computer: box),
        ], live: ["m1": ["t-a"]])
        assertAgrees(dead)
        XCTAssertEqual(dead.status(forTodo: "c"), .closed)
        XCTAssertEqual(dead.needsYou.map(\.todoId), dead.open.filter { dead.status(forTodo: $0.todoId) == .needsYou }.map(\.todoId))
        XCTAssertEqual(dead.all.map(\.todoId), ["a", "d", "b", "c"])

        let listed = HubDates.date(from: "2026-10-16T10:30:00Z")!
        let started = conv("new", .busy, created: "2026-10-16T10:45:00Z")
        let old = conv("old", .busy, created: "2026-10-16T10:00:00Z")
        var reported = conv("rep", .waiting, created: "2026-10-16T10:00:00Z")
        reported.statusUpdatedAt = "2026-10-16 10:40:00"
        let fresh = ConversationBoard(
            todos: [], conversations: ["new": started, "old": old, "rep": reported],
            liveTmux: ["m1": []], listedAt: ["m1": listed]
        )
        assertAgrees(fresh)
        XCTAssertEqual(fresh.needsYou.map(\.todoId), ["rep"])
        XCTAssertEqual(fresh.status(forTodo: "new"), .working)
        XCTAssertEqual(fresh.status(forTodo: "old"), .closed)
        XCTAssertEqual(Set(fresh.newerThanListing.map(\.todoId)), ["new", "rep"])

        let present = ConversationBoard(
            todos: [], conversations: ["a": conv("a", .busy, created: "2026-10-16T10:45:00Z")],
            liveTmux: ["m1": ["t-a"]], listedAt: ["m1": listed]
        )
        assertAgrees(present)
        XCTAssertTrue(present.newerThanListing.isEmpty)
        XCTAssertEqual(present.status(forTodo: "a"), .working)

        let ordered = board([
            conv("a", .waiting, created: "2026-10-16T09:00:00Z"),
            conv("b", .busy),
            conv("c", .waiting, created: "2026-10-16T11:00:00Z"),
        ])
        assertAgrees(ordered)
        XCTAssertEqual(ordered.needsYou.map(\.todoId), ["c", "a"])

        let todos = [Todo(id: "a", section: .sp, title: "A"),
                     Todo(id: "b", section: .sp, title: "B", completed: true),
                     Todo(id: "c", section: .i, title: "C")]
        let counted = board([conv("a", .waiting), conv("c", .busy), conv("x", .busy, computer: box)], todos: todos)
        assertAgrees(counted, todos: todos)
        XCTAssertEqual(counted.openTodoCount(.sp), 1)
        XCTAssertTrue(counted.sectionNeedsYou(.sp))
        XCTAssertFalse(counted.sectionNeedsYou(.i))
        XCTAssertEqual(counted.openCount(computerID: "m1"), 2)
        XCTAssertEqual(counted.needsYouCount(computerID: "m1"), 1)
        XCTAssertEqual(counted.needsYouCount(computerID: "m2"), 0)
    }

    /// The change date is the later of the two timestamps, parsed once. Reading status and
    /// needs-you again returns that same snapshot.
    func testChangeDateIsTheLaterTimestampAndStaysStable() {
        let listed = HubDates.date(from: "2026-10-16T10:30:00Z")!
        var updatedLater = conv("u", .waiting, created: "2026-10-16T10:00:00Z")
        updatedLater.statusUpdatedAt = "2026-10-16T10:45:00.250Z"
        var createdLater = conv("c", .busy, created: "2026-10-16T10:45:00Z")
        createdLater.statusUpdatedAt = "2026-10-16T10:00:00Z"
        var unparseable = conv("x", .busy, created: "not-a-date")
        unparseable.statusUpdatedAt = "also-not"
        let b = ConversationBoard(
            todos: [],
            conversations: ["u": updatedLater, "c": createdLater, "x": unparseable],
            liveTmux: ["m1": []], listedAt: ["m1": listed]
        )
        XCTAssertEqual(b.status(forTodo: "u"), .needsYou)
        XCTAssertEqual(b.status(forTodo: "c"), .working)
        XCTAssertEqual(b.status(forTodo: "x"), .closed)
        XCTAssertEqual(Set(b.newerThanListing.map(\.todoId)), ["u", "c"])
        XCTAssertEqual(b.needsYou.map(\.todoId), ["u"])
        XCTAssertEqual(b.needsYou.map(\.todoId), b.open.filter { b.status(forTodo: $0.todoId) == .needsYou }.map(\.todoId))
        XCTAssertEqual(b.status(forTodo: "u"), b.status(forTodo: "u"))
        assertAgrees(b)
    }

    private func assertAgrees(_ board: ConversationBoard, todos: [Todo] = [],
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(
            board.needsYou.map(\.todoId),
            board.open.filter { board.status(forTodo: $0.todoId) == .needsYou }.map(\.todoId),
            "needsYou must be the running conversations whose stored status is needs you",
            file: file, line: line
        )
        let runningIDs = Set(board.open.map(\.todoId))
        for conversation in board.all {
            let status = board.status(forTodo: conversation.todoId)
            XCTAssertNotNil(status, file: file, line: line)
            if runningIDs.contains(conversation.todoId) {
                XCTAssertNotEqual(status, .closed, file: file, line: line)
            } else {
                XCTAssertEqual(status, .closed, file: file, line: line)
            }
        }
        for conversation in board.newerThanListing {
            XCTAssertNotEqual(board.status(forTodo: conversation.todoId), .closed, file: file, line: line)
            XCTAssertTrue(runningIDs.contains(conversation.todoId), file: file, line: line)
        }
        let doneTodoIDs = Set(todos.filter(\.completed).map(\.id))
        let reviewable = board.open.filter {
            !(board.status(of: $0) == .idle && doneTodoIDs.contains($0.todoId))
        }
        XCTAssertEqual(
            Set((board.needsYou + board.working + board.review).map(\.listKey)), Set(reviewable.map(\.listKey)),
            "needs you, working and review must split the open conversations, less done todos' finished ones",
            file: file, line: line
        )
        XCTAssertEqual(board.needsYou.count + board.working.count + board.review.count, reviewable.count,
                       file: file, line: line)
        var computerIDs = Set(board.open.map(\.computer.id))
        computerIDs.formUnion(board.needsYou.map(\.computer.id))
        computerIDs.insert("missing")
        for id in computerIDs {
            XCTAssertEqual(board.openCount(computerID: id), board.open.filter { $0.computer.id == id }.count,
                           file: file, line: line)
            XCTAssertEqual(board.needsYouCount(computerID: id), board.needsYou.filter { $0.computer.id == id }.count,
                           file: file, line: line)
            XCTAssertEqual(board.workingCount(computerID: id), board.working.filter { $0.computer.id == id }.count,
                           file: file, line: line)
            XCTAssertEqual(board.reviewCount(computerID: id), board.review.filter { $0.computer.id == id }.count,
                           file: file, line: line)
        }
        for section in TodoSection.allCases {
            XCTAssertEqual(board.openTodoCount(section), todos.filter { $0.section == section && !$0.completed }.count,
                           file: file, line: line)
            XCTAssertEqual(
                board.sectionNeedsYou(section),
                todos.contains { $0.section == section && board.status(forTodo: $0.id) == .needsYou },
                file: file, line: line
            )
        }
        for n in 1...9 {
            let expected = n <= board.open.count ? board.open[n - 1].todoId : nil
            XCTAssertEqual(board.conversation(atShortcut: n)?.todoId, expected, file: file, line: line)
        }
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
