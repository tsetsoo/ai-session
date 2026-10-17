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
        XCTAssertEqual(counts.runningNow, 5)
        XCTAssertEqual(counts.sections, [
            .init(section: .sp, openTodos: 3, needsYou: true),
            .init(section: .i, openTodos: 2, needsYou: true),
            .init(section: .si, openTodos: 1, needsYou: false),
            .init(section: .p, openTodos: 2, needsYou: false),
        ])
        XCTAssertEqual(counts.computers, [
            .init(id: "mac-studio", name: "mac-studio", running: 3),
            .init(id: "linux-box", name: "linux-box", running: 2),
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
        XCTAssertEqual(counts.runningNow, 2)
        XCTAssertEqual(counts.computers.map(\.running), [0, 2])
        XCTAssertFalse(counts.sections[0].needsYou)
    }

    func testZeroShowsNoCount() {
        XCTAssertNil(SidebarCounts.label(0))
        XCTAssertEqual(SidebarCounts.label(12), "12")
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
        XCTAssertEqual(ContentHeader.title(for: .runningNow, computers: computers), "Running now")
        XCTAssertEqual(ContentHeader.title(for: .section(.si), computers: computers), "Si")
        XCTAssertEqual(ContentHeader.title(for: .computer("linux-box"), computers: computers), "linux-box")
    }

    func testHeaderSubtitles() {
        let computer: (TodoSection) -> String? = { $0 == .sp ? "mac-studio" : nil }
        XCTAssertEqual(ContentHeader.subtitle(for: .runningNow, board: board, sectionComputer: computer),
                       "5 conversations · 2 need you")
        XCTAssertEqual(ContentHeader.subtitle(for: .needsYou, board: board, sectionComputer: computer),
                       "2 conversations")
        XCTAssertEqual(ContentHeader.subtitle(for: .section(.sp), board: board, sectionComputer: computer),
                       "3 open · mac-studio")
        XCTAssertEqual(ContentHeader.subtitle(for: .section(.p), board: board, sectionComputer: computer), "2 open")
        XCTAssertEqual(ContentHeader.subtitle(for: .computer("mac-studio"), board: board, sectionComputer: computer),
                       "3 running · 1 needs you")
    }

    func testRunningNowWithOneNeedingYou() {
        let board = ConversationBoard(
            todos: DemoFixtures.todos,
            conversations: Dictionary(uniqueKeysWithValues: DemoFixtures.conversations.map { ($0.todoId, $0) }),
            liveTmux: ["linux-box": []]
        )
        XCTAssertEqual(ContentHeader.subtitle(for: .runningNow, board: board) { _ in nil },
                       "3 conversations · 1 needs you")
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

    // MARK: Demo launch

    func testDemoSidebarArgument() {
        XCTAssertEqual(AppModel.SidebarItem(demoArgument: "needsyou"), .needsYou)
        XCTAssertEqual(AppModel.SidebarItem(demoArgument: "running"), .runningNow)
        XCTAssertEqual(AppModel.SidebarItem(demoArgument: "Si"), .section(.si))
        XCTAssertEqual(AppModel.SidebarItem(demoArgument: "computer:mac-studio"), .computer("mac-studio"))
        XCTAssertNil(AppModel.SidebarItem(demoArgument: "sp"))
    }
}
