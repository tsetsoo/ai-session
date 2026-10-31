import XCTest
@testable import AISessionCore

final class ChatTimelineTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_793_440_800)

    private func user(_ id: String, _ text: String, at minutes: Double? = nil) -> ConversationMessage {
        ConversationMessage(id: id, role: .user, text: text, time: minutes.map { start.addingTimeInterval($0 * 60) })
    }

    private func assistant(_ id: String, _ text: String = "reply", at minutes: Double? = nil) -> ConversationMessage {
        ConversationMessage(id: id, role: .assistant, text: text, time: minutes.map { start.addingTimeInterval($0 * 60) })
    }

    private func step(_ id: String, _ kind: ActivityKind, _ target: String) -> ConversationMessage {
        ConversationMessage(id: id, role: .activity, text: "", kind: kind, target: target)
    }

    private func kinds(_ items: [ChatItem]) -> [String] {
        items.map {
            switch $0 {
            case .time: return "time"
            case .message: return "message"
            case .activity: return "activity"
            case .pending: return "pending"
            case .note: return "note"
            }
        }
    }

    func testConsecutiveActivityCollapsesIntoOneItem() {
        let entries = [
            user("0", "go", at: 0),
            step("1", .read, "a"), step("2", .read, "b"), step("3", .edit, "a"), step("4", .run, "x"),
            assistant("5"),
        ]
        let items = ChatTimeline.items(entries: entries, pending: [], notes: [])
        XCTAssertEqual(kinds(items), ["time", "message", "activity", "message"])
        guard case let .activity(id, steps, summary) = items[2] else { return XCTFail("not activity") }
        XCTAssertEqual(id, "1")
        XCTAssertEqual(steps.map(\.id), ["1", "2", "3", "4"])
        XCTAssertEqual(summary, "Read 2 files · edited 1 file · ran 1 command")
    }

    func testSummaryCountsSearchAndOtherSteps() {
        let summary = ChatTimeline.summary([step("1", .search, "q"), step("2", .search, "q"), step("3", .other, "TodoWrite")])
        XCTAssertEqual(summary, "Searched 2 times · 1 other step")
    }

    func testTimestampsAtStartAndAfterThirtyMinuteGap() {
        let entries = [user("0", "a", at: 0), assistant("1", at: 10), user("2", "b", at: 41), assistant("3")]
        let items = ChatTimeline.items(entries: entries, pending: [], notes: [])
        XCTAssertEqual(kinds(items), ["time", "message", "message", "time", "message", "message"])
        guard case let .time(_, date) = items[3] else { return XCTFail("not time") }
        XCTAssertEqual(date, start.addingTimeInterval(41 * 60))
    }

    func testEntriesWithoutTimesAddNoTimestamps() {
        let items = ChatTimeline.items(entries: [user("0", "a"), assistant("1")], pending: [], notes: [])
        XCTAssertEqual(kinds(items), ["message", "message"])
    }

    func testPendingShowsUntilTranscriptHasALaterUserEntry() {
        let pending = PendingSend(id: UUID(), text: "fix it", afterCount: 2)
        let before = [user("0", "fix it"), assistant("1")]
        XCTAssertEqual(ChatTimeline.unconfirmed([pending], in: before), [pending])
        XCTAssertEqual(ChatTimeline.unconfirmed([pending], in: before + [user("2", "fix it\n")]), [])
    }

    func testPendingAndNotesAreOrderedByAfterCount() {
        let note = AnsweredNote(id: UUID(), text: "✓ Yes: npm test", afterCount: 1)
        let pending = PendingSend(id: UUID(), text: "next", afterCount: 3)
        let entries = [user("0", "a"), assistant("1"), assistant("2")]
        let items = ChatTimeline.items(entries: entries, pending: [pending], notes: [note])
        XCTAssertEqual(kinds(items), ["message", "note", "message", "message", "pending"])
    }

    func testRewrittenSlashCommandStillConfirmsTheSend() {
        let pending = PendingSend(id: UUID(), text: "/compact", afterCount: 1, sentAt: start)
        let entries = [user("0", "a"), user("1", "<command-name>/compact</command-name>")]
        XCTAssertEqual(ChatTimeline.unconfirmed([pending], in: entries, now: start), [])
    }

    func testEachUserEntryConfirmsOnlyOneSend() {
        let first = PendingSend(id: UUID(), text: "one", afterCount: 0, sentAt: start)
        let second = PendingSend(id: UUID(), text: "two", afterCount: 0, sentAt: start)
        XCTAssertEqual(ChatTimeline.unconfirmed([first, second], in: [user("0", "something else")], now: start), [second])
    }

    func testUnloggedSendGoesAwayAfterTimeout() {
        let pending = PendingSend(id: UUID(), text: "/status", afterCount: 0, sentAt: start)
        XCTAssertEqual(ChatTimeline.unconfirmed([pending], in: [], now: start.addingTimeInterval(10)), [pending])
        XCTAssertEqual(ChatTimeline.unconfirmed([pending], in: [], now: start.addingTimeInterval(ChatTimeline.pendingTimeout + 1)), [])
    }
}
