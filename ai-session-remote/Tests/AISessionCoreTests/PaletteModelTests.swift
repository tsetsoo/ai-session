import XCTest
@testable import AISessionCore

final class PaletteModelTests: XCTestCase {
    private let studio = Computer(id: "m1", name: "mac-studio", hostname: "studio", username: "me")
    private let box = Computer(id: "m2", name: "linux-box", hostname: "box", username: "me")

    /// Like the demo board: t1 and t3 need you, t2 and t4 work, t5 idles (running order t1…t5);
    /// t6 is done, t7–t9 have no conversation, t10's conversation is closed.
    private lazy var todos: [Todo] = [
        Todo(id: "t1", section: .sp, title: "Fix the rate import"),
        Todo(id: "t2", section: .sp, title: "Import Booking.com reviews"),
        Todo(id: "t3", section: .i, title: "Draft the HTIF follow-up"),
        Todo(id: "t4", section: .si, title: "Clean up scraper retries"),
        Todo(id: "t5", section: .sp, title: "Santé party-size rates"),
        Todo(id: "t6", section: .sp, title: "Renew the rate certificate", completed: true),
        Todo(id: "t7", section: .i, title: "Call the Bansko hotel"),
        Todo(id: "t8", section: .p, title: "Rate shopper comparison page"),
        Todo(id: "t9", section: .p, title: "Book the HTIF booth crew"),
        Todo(id: "t10", section: .si, title: "Old rate scraper"),
    ]

    private func conv(_ todo: String, _ status: ConversationStatus, on computer: Computer? = nil) -> Conversation {
        Conversation(todoId: todo, computer: computer ?? studio, cwd: "~/x", tool: "claude",
                     tmuxName: "todo-\(todo)", sessionId: "s-\(todo)", status: status,
                     createdAt: "2026-10-17T09:00:00Z")
    }

    private lazy var board = ConversationBoard(
        todos: todos,
        conversations: Dictionary(uniqueKeysWithValues: [
            conv("t1", .waiting), conv("t2", .busy), conv("t3", .waiting, on: box),
            conv("t4", .busy, on: box), conv("t5", .idle), conv("t10", .closed, on: box),
        ].map { ($0.todoId, $0) }),
        liveTmux: [:]
    )

    private let projects = [
        Project(id: "p1", name: "Website", computer: Computer(id: "m1", name: "mac-studio", hostname: "studio", username: "me"),
                folder: "~/code/website"),
        Project(id: "p2", name: "RMS backend", computer: Computer(id: "m1", name: "mac-studio", hostname: "studio", username: "me"),
                folder: "~/code/rms-backend"),
    ]

    private func groups(_ query: String, selected: String? = nil, canEdit: Bool = true) -> [PaletteGroup] {
        PaletteModel.groups(query: query, board: board, todos: todos, projects: projects,
                            selectedTodoID: selected, canEdit: canEdit)
    }

    private func ids(_ groups: [PaletteGroup], _ kind: PaletteGroup.Kind) -> [String] {
        groups.first { $0.kind == kind }?.items.map(\.id) ?? []
    }

    // MARK: Empty query

    func testEmptyQueryShowsConversationsNeedsYouFirstThenActions() {
        let result = groups("")
        XCTAssertEqual(result.map(\.kind), [.conversations, .actions])
        XCTAssertEqual(ids(result, .conversations), ["c:t1", "c:t3", "c:t2", "c:t4", "c:t5"])
        XCTAssertEqual(ids(result, .actions), ["a:newTodo", "a:newTodoFromConversation", "a:openSettings"])
    }

    func testConversationsCarryStatusAndTheirOpenListShortcut() {
        let items = groups("").first { $0.kind == .conversations }!.items
        // t3 is listed second (needs you) but is third among the open conversations: ⌘3.
        guard case let .conversation(todo, _, status, shortcut) = items[1] else { return XCTFail("\(items[1])") }
        XCTAssertEqual(todo.id, "t3")
        XCTAssertEqual(status, .needsYou)
        XCTAssertEqual(shortcut, 3)
        guard case let .conversation(_, _, idle, five) = items[4] else { return XCTFail("\(items[4])") }
        XCTAssertEqual(idle, .idle)
        XCTAssertEqual(five, 5)
    }

    func testShortcutsStopAtNine() {
        // Zero-padded ids: the open list orders equal start times by id.
        let many = (1...12).map { Todo(id: String(format: "n%02d", $0), section: .sp, title: "Task \($0)") }
        let board = ConversationBoard(
            todos: many,
            conversations: Dictionary(uniqueKeysWithValues: many.map { ($0.id, conv($0.id, .busy)) }),
            liveTmux: [:]
        )
        let items = PaletteModel.groups(query: "Task 1", board: board, todos: many, projects: [],
                                        selectedTodoID: nil, canEdit: true)
            .first { $0.kind == .conversations }!.items
        let shortcuts = items.compactMap { item -> Int?? in
            if case let .conversation(_, _, _, shortcut) = item { return shortcut }
            return nil
        }
        // "Task 1", "Task 10"…"Task 12": only Task 1 (⌘1) is within the first nine.
        XCTAssertEqual(shortcuts.count, 4)
        XCTAssertEqual(shortcuts.compactMap { $0 }, [1])
    }

    func testADuplicatedConversationGetsItsOwnRowTitledWithItsName() {
        let todo = Todo(id: "t1", section: .sp, title: "Fix the rate import")
        let original = Conversation(id: "c1", todoId: "t1", computer: studio, cwd: "~/x", tool: "claude",
                                    tmuxName: "todo-c1", sessionId: "s1", status: .busy,
                                    createdAt: "2026-10-17T09:00:00Z")
        let copy = Conversation(id: "c2", todoId: "t1", computer: studio, cwd: "~/x", tool: "codex",
                                tmuxName: "todo-c2", sessionId: "s2", status: .busy,
                                createdAt: "2026-10-17T09:05:00Z", label: "duplicate")
        let board = ConversationBoard(todos: [todo], conversations: ["c1": original, "c2": copy], liveTmux: [:])
        let items = PaletteModel.groups(query: "", board: board, todos: [todo], projects: [],
                                        selectedTodoID: nil, canEdit: true)
            .first { $0.kind == .conversations }!.items
        XCTAssertEqual(Set(items.map(\.id)), ["c:c1", "c:c2"])
        XCTAssertEqual(Set(items.map(\.title)), ["Fix the rate import", "Fix the rate import · duplicate"])
        // The tool is searchable: only the Codex copy matches "codex".
        let codex = PaletteModel.groups(query: "codex", board: board, todos: [todo], projects: [],
                                        selectedTodoID: nil, canEdit: true)
        XCTAssertEqual(ids(codex, .conversations), ["c:c2"])
    }

    // MARK: Query

    func testQueryRanksByScoreAndGroupsTodosAndProjects() {
        let result = groups("rate")
        XCTAssertEqual(result.map(\.kind), [.conversations, .todos, .actions])
        // Only whole "rate" matches: the scattered r…a…t…e in "Draft the HTIF follow-up" and
        // "Clean up scraper retries" is dropped once something matches contiguously.
        XCTAssertEqual(ids(result, .conversations), ["c:t1", "c:t5"])
        // Todos: not running and not done; t10's conversation is closed, so it is a todo here.
        // A title starting with the query ranks first.
        XCTAssertEqual(ids(result, .todos), ["t:t8", "t:t10"])
    }

    // MARK: Contiguous before fuzzy

    func testContiguousMatchOutranksAnyScatteredOne() {
        let whole = PaletteMatch.best(query: "rate", candidate: "Prepare Santé rates")!
        let scattered = PaletteMatch.best(query: "rate", candidate: "Draft the HTIF follow-up")!
        XCTAssertEqual(whole.kind, .substring)
        XCTAssertEqual(scattered.kind, .subsequence)
        XCTAssertGreaterThan(whole, scattered)
        // Even a scattered match at the very start loses to a contiguous one late in a title.
        XCTAssertGreaterThan(PaletteMatch.best(query: "rat", candidate: "A very long title that ends in rat")!,
                             PaletteMatch.best(query: "rat", candidate: "r a t")!)
    }

    func testWordStartBeatsMidWordWithinContiguous() {
        let todos = [Todo(id: "a", section: .i, title: "Pirate notes"),
                     Todo(id: "b", section: .i, title: "Rats in the attic"),
                     Todo(id: "c", section: .i, title: "Check the rats")]
        let result = PaletteModel.groups(query: "rat", board: board, todos: todos, projects: [],
                                         selectedTodoID: nil, canEdit: true)
        XCTAssertEqual(ids(result, .todos), ["t:b", "t:c", "t:a"])
    }

    func testShortQueriesKeepFuzzyRowsBelowContiguousOnes() {
        let todos = [Todo(id: "a", section: .i, title: "Fix the rate import"),
                     Todo(id: "b", section: .i, title: "Free the import")]
        let result = PaletteModel.groups(query: "fr", board: board, todos: todos, projects: [],
                                         selectedTodoID: nil, canEdit: true)
        // "Free" has "fr"; "Fix the rate" only f…r.
        XCTAssertEqual(ids(result, .todos), ["t:b", "t:a"])
    }

    func testFuzzyOnlyWhenNothingMatchesContiguously() {
        let result = groups("frimp")
        XCTAssertEqual(ids(result, .conversations), ["c:t1"])
        // The bold characters are the ones the fuzzy match used: F, r (rate), i, m, p (import).
        let group = result.first { $0.kind == .conversations }!
        XCTAssertEqual(group.highlights["c:t1"], [0..<1, 8..<9, 13..<16])
    }

    func testHighlightIsTheContiguousMatchThatRanked() {
        let group = groups("rate").first { $0.kind == .conversations }!
        XCTAssertEqual(group.highlights["c:t1"], [8..<12])
        // "Santé party-size rates": the word "rates", not the greedy r in "party".
        XCTAssertEqual(group.highlights["c:t5"], [17..<21])
        // Accents fold: "sante" bolds "Santé".
        XCTAssertEqual(groups("sante").first { $0.kind == .conversations }!.highlights["c:t5"], [0..<5])
        // Matched on the computer only: nothing in the title is bold.
        XCTAssertNil(groups("linux-box").first { $0.kind == .conversations }!.highlights["c:t3"])
    }

    func testActionsStayWhateverTheQuery() {
        XCTAssertEqual(ids(groups("zzzz"), .actions), ["a:newTodo", "a:newTodoFromConversation", "a:openSettings"])
        XCTAssertEqual(groups("zzzz").map(\.kind), [.actions])
    }

    func testDiacriticInsensitive() {
        XCTAssertEqual(ids(groups("sante"), .conversations).first, "c:t5")
        if case let .conversation(todo, _, _, _) = groups("sante")[0].items[0] {
            XCTAssertEqual(todo.title, "Santé party-size rates")
        } else {
            XCTFail("expected a conversation")
        }
    }

    func testMatchesSectionCodeAndComputerName() {
        // linux-box hosts t3 and t4 (running) and t10 (closed).
        XCTAssertEqual(Set(ids(groups("linux-box"), .conversations)), ["c:t3", "c:t4"])
        XCTAssertEqual(ids(groups("linux-box"), .todos), ["t:t10"])
        // "P" is t8 and t9's section (and starts other words too); both are listed.
        XCTAssertTrue(Set(ids(groups("P"), .todos)).isSuperset(of: ["t:t8", "t:t9"]))
    }

    func testProjectsMatchNameAndFolder() {
        XCTAssertEqual(ids(groups("website"), .projects), ["p:p1"])
        XCTAssertEqual(ids(groups("rms-back"), .projects), ["p:p2"])
        XCTAssertEqual(groups("").first { $0.kind == .projects }, nil)
    }

    func testAtMostFivePerGroup() {
        let many = (1...8).map { Todo(id: "x\($0)", section: .i, title: "Rate idea \($0)") }
        let result = PaletteModel.groups(query: "rate", board: board, todos: todos + many, projects: [],
                                         selectedTodoID: nil, canEdit: true)
        for group in result {
            XCTAssertLessThanOrEqual(group.items.count, PaletteModel.maxPerGroup, "\(group.kind)")
        }
        XCTAssertEqual(ids(result, .todos).count, 5)
    }

    // MARK: Actions

    func testLinkOnlyForASelectedTodoWithoutConversation() {
        XCTAssertEqual(ids(groups("", selected: "t7"), .actions),
                       ["a:newTodo", "a:link:t7", "a:newTodoFromConversation", "a:openSettings"])
        let link = groups("", selected: "t7").first { $0.kind == .actions }!.items[1]
        XCTAssertEqual(link, .action(.linkConversation(todoID: "t7", title: "Call the Bansko hotel")))
        XCTAssertEqual(PaletteAction.linkConversation(todoID: "t7", title: "Call the Bansko hotel").title,
                       "Link a conversation to “Call the Bansko hotel”…")
        // Running, closed (still linked) and unknown todos get no Link.
        XCTAssertFalse(ids(groups("", selected: "t1"), .actions).contains { $0.hasPrefix("a:link") })
        XCTAssertFalse(ids(groups("", selected: "t10"), .actions).contains { $0.hasPrefix("a:link") })
        XCTAssertFalse(ids(groups("", selected: "nope"), .actions).contains { $0.hasPrefix("a:link") })
    }

    func testOfflineKeepsOnlySettings() {
        XCTAssertEqual(ids(groups("", selected: "t7", canEdit: false), .actions), ["a:openSettings"])
    }

    // MARK: ⌘1–⌘9

    func testShortcutTargetFollowsRunningNow() {
        XCTAssertEqual(PaletteModel.shortcutTarget(1, board: board, todos: todos)?.id, "t1")
        XCTAssertEqual(PaletteModel.shortcutTarget(3, board: board, todos: todos)?.id, "t3")
        XCTAssertEqual(PaletteModel.shortcutTarget(5, board: board, todos: todos)?.id, "t5")
        XCTAssertNil(PaletteModel.shortcutTarget(6, board: board, todos: todos))
        XCTAssertNil(PaletteModel.shortcutTarget(0, board: board, todos: todos))
        // A running conversation whose todo isn't loaded has no target.
        XCTAssertNil(PaletteModel.shortcutTarget(2, board: board, todos: todos.filter { $0.id != "t2" }))
    }
}
