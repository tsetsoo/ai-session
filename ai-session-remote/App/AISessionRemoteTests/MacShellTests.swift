import AISessionCore
import XCTest
@testable import AISessionRemote

@MainActor
final class MacShellTests: XCTestCase {
    /// The demo board: t1 and t3 need you (Sp, I), t2 and t4 work, t5 idles; t6 (Sp) is done.
    private var board: ConversationBoard {
        ConversationBoard(
            todos: DemoFixtures.todos,
            conversations: Dictionary(uniqueKeysWithValues: DemoFixtures.conversations.map { ($0.todoId, $0) }),
            liveTmux: [:]
        )
    }

    // MARK: Sidebar counts

    func testSidebarCountsFollowTheBoard() {
        let counts = SidebarCounts(board: board, computers: DemoFixtures.computers)
        XCTAssertEqual(counts.needsYou, 2)
        XCTAssertEqual(counts.review, 1)
        XCTAssertEqual(counts.working, 2)
        XCTAssertEqual(counts.sections, [
            .init(section: .sp, openTodos: 3, needsYou: true),
            .init(section: .i, openTodos: 2, needsYou: true),
            .init(section: .si, openTodos: 1, needsYou: false),
            .init(section: .p, openTodos: 2, needsYou: false),
        ])
        XCTAssertEqual(counts.computers, [
            .init(id: "mac-studio", name: "mac-studio", open: 3),
            .init(id: "linux-box", name: "linux-box", open: 2),
        ])
    }

    func testDeadTmuxSessionsLeaveTheCounts() {
        // mac-studio answered and has none of its sessions any more.
        let board = ConversationBoard(
            todos: DemoFixtures.todos,
            conversations: Dictionary(uniqueKeysWithValues: DemoFixtures.conversations.map { ($0.todoId, $0) }),
            liveTmux: ["mac-studio": []]
        )
        let counts = SidebarCounts(board: board, computers: DemoFixtures.computers)
        XCTAssertEqual(counts.needsYou, 1)
        XCTAssertEqual(counts.review, 0)
        XCTAssertEqual(counts.working, 1)
        XCTAssertEqual(counts.computers.map(\.open), [0, 2])
        XCTAssertFalse(counts.sections[0].needsYou)
    }

    func testZeroShowsNoCount() {
        XCTAssertNil(SidebarCounts.label(0))
        XCTAssertEqual(SidebarCounts.label(12), "12")
    }

    /// The detail column keeps several frames mounted. Only the column may install toolbar
    /// items, and those identifiers stay put when another conversation is selected. Each
    /// frame installing its own set makes AppKit throw while inserting a duplicate.
    /// The title and the actions are separate `ToolbarItem`s. A view `.id()` is not the
    /// identifier AppKit checks, so the Mac column passes these ids to `ToolbarItem`.
    func testSharedColumnOwnsOneStableToolbar() {
        XCTAssertFalse(ConversationToolbar.framePublishesToolbar(sharesColumn: true))
        XCTAssertTrue(ConversationToolbar.framePublishesToolbar(sharesColumn: false))
        let first = ConversationToolbar.columnItemIDs(todoID: "a")
        let second = ConversationToolbar.columnItemIDs(todoID: "b")
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, [ConversationToolbar.titleID, ConversationToolbar.actionsID])
        XCTAssertEqual(
            ConversationToolbar.frameItemIDs(showsTitle: true),
            [ConversationToolbar.titleID, ConversationToolbar.actionsID]
        )
        XCTAssertEqual(
            ConversationToolbar.frameItemIDs(showsTitle: false),
            [ConversationToolbar.actionsID]
        )
        XCTAssertGreaterThan(ConversationToolbar.controlSpacing, 0)
    }

    /// A click can land before the frame is mounted. The request stays until that frame
    /// is the one on screen.
    func testToolbarCommandWaitsForTheFrontmostFrame() {
        let request = ConversationToolbarRequest(command: .copyResume, todoID: "a")
        XCTAssertEqual(
            ConversationToolbar.commandToRun(pending: request, todoID: "a", isFrontmost: true),
            .copyResume
        )
        XCTAssertNil(ConversationToolbar.commandToRun(pending: request, todoID: "a", isFrontmost: false))
        XCTAssertNil(ConversationToolbar.commandToRun(pending: request, todoID: "b", isFrontmost: true))
        XCTAssertNil(ConversationToolbar.commandToRun(pending: nil, todoID: "a", isFrontmost: true))
    }

    func testWarmMountKeepsTheMostRecentConversations() {
        XCTAssertEqual(WarmConversationMount.capacity, 3)
        var ids: [String] = []
        ids = WarmConversationMount.select("a", in: ids)
        ids = WarmConversationMount.select("b", in: ids)
        ids = WarmConversationMount.select("c", in: ids)
        ids = WarmConversationMount.select("d", in: ids)
        XCTAssertEqual(ids, ["b", "c", "d"])
        // Coming back moves it to the end, so it is the last one dropped.
        ids = WarmConversationMount.select("b", in: ids)
        XCTAssertEqual(ids, ["c", "d", "b"])
    }

    /// A closed todo is shown in front of the warm terminals. It does not take one of the
    /// three slots, so arrowing through closed rows leaves the live terminals mounted.
    func testWarmMountKeepsRunningConversationsWhenClosedTodosAreSelected() {
        let running: Set = ["a", "b", "c"]
        var ids = ["a", "b", "c"]
        ids = WarmConversationMount.select("x", in: ids) { running.contains($0) }
        ids = WarmConversationMount.select("y", in: ids) { running.contains($0) }
        ids = WarmConversationMount.select("z", in: ids) { running.contains($0) }
        XCTAssertEqual(ids, ["a", "b", "c", "z"])
    }

    // MARK: Sync line

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func line(configured: Bool = true, loaded: Bool = true, offline: Bool = false,
                      rejected: Bool = false, ago seconds: TimeInterval? = 10) -> SyncLine {
        SyncLine.make(isConfigured: configured, hasLoadedOnce: loaded, isOffline: offline, tokenRejected: rejected,
                      lastSync: seconds.map { now.addingTimeInterval(-$0) }, now: now)
    }

    func testSyncedReadsJustNowThenMinutes() {
        XCTAssertEqual(line().text, "Synced · just now")
        XCTAssertEqual(line().kind, .synced)
        XCTAssertEqual(line(ago: 5 * 60).text, "Synced · 5m ago")
        XCTAssertEqual(line(ago: nil).text, "Synced")
    }

    func testOfflineShowsTheCacheAge() {
        XCTAssertEqual(line(offline: true, ago: 5 * 60).text, "Offline · showing todos from 5m ago")
        XCTAssertEqual(line(offline: true, ago: 3 * 3600).text, "Offline · showing todos from 3h ago")
        XCTAssertEqual(line(offline: true, ago: nil).text, "Offline · showing saved todos")
    }

    func testRejectedTokenWinsOverOffline() {
        let rejected = line(offline: true, rejected: true)
        XCTAssertEqual(rejected.kind, .tokenRejected)
        XCTAssertEqual(rejected.text, "The server didn't accept the API token")
    }

    func testNotConfiguredAndFirstLoad() {
        XCTAssertEqual(line(configured: false).kind, .notConfigured)
        XCTAssertEqual(line(loaded: false).text, "Syncing…")
    }

    func testAgo() {
        XCTAssertEqual(SyncLine.ago(now.addingTimeInterval(-59), now: now), "just now")
        XCTAssertEqual(SyncLine.ago(now.addingTimeInterval(-60), now: now), "1m ago")
        XCTAssertEqual(SyncLine.ago(now.addingTimeInterval(-2 * 86_400), now: now), "2d ago")
        // A clock that ran ahead never reads as negative.
        XCTAssertEqual(SyncLine.ago(now.addingTimeInterval(120), now: now), "just now")
    }

    // MARK: List column header

    func testHeaderTitles() {
        let computers = DemoFixtures.computers
        XCTAssertEqual(ContentHeader.title(for: .needsYou, computers: computers), "Needs you")
        XCTAssertEqual(ContentHeader.title(for: .review, computers: computers), "Ready for review")
        XCTAssertEqual(ContentHeader.title(for: .working, computers: computers), "Working")
        XCTAssertEqual(ContentHeader.title(for: .section(.si), computers: computers), "Si")
        XCTAssertEqual(ContentHeader.title(for: .projects, computers: computers), "Projects")
        XCTAssertEqual(ContentHeader.title(for: .computer("linux-box"), computers: computers), "linux-box")
    }

    func testHeaderSubtitles() {
        let computer: (TodoSection) -> String? = { $0 == .sp ? "mac-studio" : nil }
        XCTAssertEqual(ContentHeader.subtitle(for: .review, board: board, sectionComputer: computer),
                       "1 conversation")
        XCTAssertEqual(ContentHeader.subtitle(for: .working, board: board, sectionComputer: computer),
                       "2 conversations")
        XCTAssertEqual(ContentHeader.subtitle(for: .needsYou, board: board, sectionComputer: computer),
                       "2 conversations")
        XCTAssertEqual(ContentHeader.subtitle(for: .section(.sp), board: board, sectionComputer: computer),
                       "3 open · mac-studio")
        XCTAssertEqual(ContentHeader.subtitle(for: .section(.p), board: board, sectionComputer: computer), "2 open")
        XCTAssertEqual(ContentHeader.subtitle(for: .computer("mac-studio"), board: board, sectionComputer: computer),
                       "1 needs you · 1 to review · 1 working")
    }

    // MARK: Search

    func testSearchMatchesAnyFieldIgnoringCaseAndAccents() {
        XCTAssertTrue(ListSearch.matches("", "Fix the rate import"))
        XCTAssertTrue(ListSearch.matches("  ", nil))
        XCTAssertTrue(ListSearch.matches("RATE", "Fix the rate import"))
        XCTAssertTrue(ListSearch.matches("sante", "Santé party-size rates"))
        XCTAssertTrue(ListSearch.matches("linux", "Draft", "I · linux-box · Claude"))
        XCTAssertFalse(ListSearch.matches("codex", "Fix the rate import", nil))
    }

    // MARK: ⌘K and ⌘1–⌘9

    private func todo(_ id: String) -> Todo { DemoFixtures.todos.first { $0.id == id }! }

    func testShortcutTargetsFollowTheOpenConversations() {
        // Open: t1…t5 (same start time, by id); ⌘6 and beyond have no target.
        XCTAssertEqual(PaletteModel.shortcutTarget(1, board: board, todos: DemoFixtures.todos)?.id, "t1")
        XCTAssertEqual(PaletteModel.shortcutTarget(5, board: board, todos: DemoFixtures.todos)?.title,
                       "Santé party-size rates")
        XCTAssertNil(PaletteModel.shortcutTarget(6, board: board, todos: DemoFixtures.todos))
    }

    func testShortcutsNumberTheConversationListOnScreen() {
        let working = MacShell.shortcutList(for: .working, board: board)
        XCTAssertEqual(working.map(\.todoId), ["t2", "t4"])
        XCTAssertEqual(PaletteModel.shortcutTarget(1, board: board, todos: DemoFixtures.todos, in: working)?.id, "t2")
        XCTAssertNil(PaletteModel.shortcutTarget(3, board: board, todos: DemoFixtures.todos, in: working))
        XCTAssertEqual(MacShell.shortcutList(for: .review, board: board).map(\.todoId), ["t5"])
        XCTAssertEqual(MacShell.shortcutList(for: .needsYou, board: board).map(\.todoId), ["t1", "t3"])
        XCTAssertEqual(MacShell.shortcutList(for: .section(.sp), board: board).count, 5)
    }

    func testRateOnTheDemoBoardListsOnlyWholeMatches() {
        let groups = PaletteModel.groups(query: "rate", board: board, todos: DemoFixtures.todos, projects: [],
                                         selectedTodoID: nil, canEdit: true)
        let titles = groups.filter { $0.kind != .actions }.flatMap(\.items).compactMap { item -> String? in
            switch item {
            case let .conversation(todo, _, _, _), let .todo(todo, _, _): return todo.title
            default: return nil
            }
        }
        XCTAssertEqual(titles, ["Fix the rate import", "Santé party-size rates", "Rate shopper comparison page"])
    }

    func testGoingToATodoKeepsAListThatHasIt() {
        // Needs you, Ready for review and Working keep what they list; a section keeps its own todos.
        XCTAssertEqual(MacShell.sidebarTarget(showing: todo("t1"), from: .needsYou, board: board), .needsYou)
        XCTAssertEqual(MacShell.sidebarTarget(showing: todo("t5"), from: .review, board: board), .review)
        XCTAssertEqual(MacShell.sidebarTarget(showing: todo("t2"), from: .working, board: board), .working)
        XCTAssertEqual(MacShell.sidebarTarget(showing: todo("t5"), from: .section(.sp), board: board), .section(.sp))
        XCTAssertEqual(MacShell.sidebarTarget(showing: todo("t7"), from: .section(.i), board: board), .section(.i))
    }

    func testGoingToATodoElsewhereSwitchesList() {
        // Each goes to the list for its status; t7 has no conversation; Projects and computers
        // never list todos.
        XCTAssertEqual(MacShell.sidebarTarget(showing: todo("t2"), from: .needsYou, board: board), .working)
        XCTAssertEqual(MacShell.sidebarTarget(showing: todo("t5"), from: .working, board: board), .review)
        XCTAssertEqual(MacShell.sidebarTarget(showing: todo("t3"), from: .section(.sp), board: board), .needsYou)
        XCTAssertEqual(MacShell.sidebarTarget(showing: todo("t7"), from: .review, board: board), .section(.i))
        XCTAssertEqual(MacShell.sidebarTarget(showing: todo("t8"), from: .projects, board: board), .section(.p))
        XCTAssertEqual(MacShell.sidebarTarget(showing: todo("t1"), from: .computer("mac-studio"), board: board),
                       .needsYou)
    }

    func testGoingToOneOfATodosConversationsUsesThatConversationsList() {
        // t5 idles; a second, busy conversation makes the todo's most urgent status Working.
        let busy = Conversation(id: "c-t5b", todoId: "t5", computer: DemoFixtures.computers[0], cwd: "~/x",
                                tool: "claude", tmuxName: "todo-t5b", sessionId: "demo-t5b", status: .busy,
                                createdAt: "2026-10-16T10:00:00Z")
        var conversations = Dictionary(uniqueKeysWithValues: DemoFixtures.conversations.map { ($0.id, $0) })
        conversations[busy.id] = busy
        let board = ConversationBoard(todos: DemoFixtures.todos, conversations: conversations, liveTmux: [:])
        let idle = board.review.first { $0.todoId == "t5" }!
        XCTAssertEqual(MacShell.sidebarTarget(showing: todo("t5"), conversation: idle, from: .review, board: board),
                       .review)
        XCTAssertEqual(MacShell.sidebarTarget(showing: todo("t5"), from: .review, board: board), .working)
    }

    func testShortcutListsMatchTheListsOnScreen() {
        for item in [AppModel.SidebarItem.needsYou, .review, .working] {
            let filter = MacShell.conversationFilter(for: item)
            XCTAssertNotNil(filter)
            XCTAssertEqual(MacShell.shortcutList(for: item, board: board).map(\.listKey),
                           filter?.conversations(board).map(\.listKey))
        }
        XCTAssertNil(MacShell.conversationFilter(for: .projects))
    }

    func testDismissingThePaletteReturnsFocusToTheVisibleTerminal() {
        XCTAssertEqual(MacShell.terminalToFocus(visibleTodoID: "t1", poppedOut: []), "t1")
        // Popped out: the main window shows a placeholder, not a terminal.
        XCTAssertNil(MacShell.terminalToFocus(visibleTodoID: "t1", poppedOut: ["t1"]))
        XCTAssertNil(MacShell.terminalToFocus(visibleTodoID: nil, poppedOut: []))
    }

    // MARK: Demo launch

    func testDemoSidebarArgument() {
        XCTAssertEqual(AppModel.SidebarItem(demoArgument: "needsyou"), .needsYou)
        XCTAssertEqual(AppModel.SidebarItem(demoArgument: "review"), .review)
        XCTAssertEqual(AppModel.SidebarItem(demoArgument: "working"), .working)
        XCTAssertEqual(AppModel.SidebarItem(demoArgument: "running"), .working)
        XCTAssertEqual(AppModel.SidebarItem(demoArgument: "Si"), .section(.si))
        XCTAssertEqual(AppModel.SidebarItem(demoArgument: "computer:mac-studio"), .computer("mac-studio"))
        XCTAssertNil(AppModel.SidebarItem(demoArgument: "sp"))
    }
}
