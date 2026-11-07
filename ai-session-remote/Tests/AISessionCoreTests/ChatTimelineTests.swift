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
            case let .delegation(worker): return "worker:" + worker.id
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

    private func worker(_ id: String, call: String?, startedAt minutes: Double? = nil, state: DelegatedWorker.State = .done) -> DelegatedWorker {
        DelegatedWorker(id: id, callId: call, state: state, startedAt: minutes.map { start.addingTimeInterval($0 * 60) })
    }

    func testWorkerReplacesTheCallThatStartedItAndSplitsTheSteps() {
        let entries = [
            user("0.0", "review it", at: 0),
            step("1.0", .read, "a"),
            ConversationMessage(id: "1.1", role: .activity, text: "", kind: .other, target: "Agent", name: "Agent"),
            step("2.0", .run, "ls"),
            assistant("3.0"),
        ]
        let items = ChatTimeline.items(entries: entries, pending: [], notes: [], workers: [worker("a1", call: "1.1")])
        XCTAssertEqual(kinds(items), ["time", "message", "activity", "worker:a1", "activity", "message"])
        XCTAssertEqual(items[3].id, "delegation-a1")
        guard case let .activity(_, before, _) = items[2], case let .activity(_, after, _) = items[4] else { return XCTFail("not activity") }
        XCTAssertEqual(before.map(\.id), ["1.0"])
        XCTAssertEqual(after.map(\.id), ["2.0"])
    }

    func testWithoutWorkersTheCallStaysAStep() {
        let call = ConversationMessage(id: "1.0", role: .activity, text: "", kind: .other, target: "Agent", name: "Agent")
        let items = ChatTimeline.items(entries: [user("0.0", "a"), call], pending: [], notes: [])
        XCTAssertEqual(kinds(items), ["message", "activity"])
    }

    func testWorkerWithoutItsCallGoesWhereItStartedOrAtTheEnd() {
        let entries = [user("0.0", "a", at: 0), assistant("1.0", at: 10), user("2.0", "b", at: 20)]
        let workers = [worker("late", call: nil), worker("mid", call: "9.9", startedAt: 15), worker("first", call: nil, startedAt: 5)]
        let items = ChatTimeline.items(entries: entries, pending: [], notes: [], workers: workers)
        XCTAssertEqual(kinds(items), ["time", "message", "worker:first", "message", "worker:mid", "message", "worker:late"])
    }

    func testRefreshOnlyForAChatThatDelegatedAndWhileSomethingWorks() {
        let call = ConversationMessage(id: "1.0", role: .activity, text: "", kind: .other, target: "spawn_agent", name: "spawn_agent")
        let plain = [user("0.0", "a"), step("1.0", .run, "ls")]
        XCTAssertFalse(Delegation.needsRefresh(entries: plain, workers: []))
        XCTAssertTrue(Delegation.needsRefresh(entries: [user("0.0", "a"), call], workers: []))
        XCTAssertFalse(Delegation.needsRefresh(entries: [user("0.0", "a"), call], workers: [worker("w", call: "1.0")]))
        XCTAssertTrue(Delegation.needsRefresh(entries: [user("0.0", "a"), call], workers: [worker("w", call: "1.0", state: .working)]))
        // A helper from before `name` reports the tool as the target.
        let old = ConversationMessage(id: "1.0", role: .activity, text: "", kind: .other, target: "Agent")
        XCTAssertTrue(Delegation.needsRefresh(entries: [old], workers: []))
        // Not on every 1 s poll.
        let working = [worker("w", call: "1.0", state: .working)]
        XCTAssertFalse(Delegation.needsRefresh(entries: [call], workers: working, lastFetch: start, now: start.addingTimeInterval(5)))
        XCTAssertTrue(Delegation.needsRefresh(entries: [call], workers: working, lastFetch: start, now: start.addingTimeInterval(10)))
        XCTAssertFalse(Delegation.needsRefresh(entries: [call], workers: [], lastFetch: start, now: start.addingTimeInterval(1)))
        XCTAssertTrue(Delegation.needsRefresh(entries: [call], workers: [], lastFetch: start, now: start.addingTimeInterval(3)))
    }

    func testWorkerListDecodesHelperOutput() throws {
        let json = #"[{"id":"a1","callId":"12.1","title":"Review branch","kind":"general-purpose","model":"claude-opus-5-5","background":true,"state":"done","evidence":"handed back its report","startedAt":"2026-11-06T21:00:00.123Z","lastSeenAt":"2026-11-06T21:10:00Z","durationMs":600000,"tokens":6000,"toolCount":16,"task":"Do it","result":"Found 2 bugs."},{"id":"x","callId":null,"title":null,"kind":null,"model":null,"background":null,"state":"waiting","evidence":null,"startedAt":null,"lastSeenAt":null,"durationMs":null,"tokens":null,"toolCount":null,"task":null,"result":null}]"#
        let workers = try DelegatedWorker.decodeList(Data(json.utf8))
        XCTAssertEqual(workers.map(\.id), ["a1", "x"])
        XCTAssertEqual(workers[0].callId, "12.1")
        XCTAssertEqual(workers[0].startedAt, ConversationMessage.parseTime("2026-11-06T21:00:00.123Z"))
        XCTAssertEqual(workers[0].statsLine, "10 min · 16 tools · 6k tokens")
        XCTAssertEqual(workers[1].state, .stale)
        XCTAssertEqual(workers[1].displayTitle, "Agent")
        XCTAssertEqual(workers[1].statsLine, "")
    }

    func testWorkerStatusInPlainWords() {
        let now = start.addingTimeInterval(3600)
        func make(_ state: DelegatedWorker.State, seen: TimeInterval?, evidence: String? = nil, result: String? = nil) -> DelegatedWorker {
            DelegatedWorker(id: "w", state: state, evidence: evidence, lastSeenAt: seen.map { now.addingTimeInterval(-$0) }, result: result)
        }
        XCTAssertEqual(make(.working, seen: 4, evidence: "no finish recorded; last write 4 s ago").statusText(now: now), "Last update 4 s ago")
        XCTAssertEqual(make(.working, seen: 130).statusText(now: now), "Last update 2 min ago")
        XCTAssertEqual(make(.working, seen: nil).statusText(now: now), nil)
        XCTAssertEqual(make(.stale, seen: 720).statusText(now: now), "No update for 12 min. It may still be running.")
        XCTAssertEqual(make(.failed, seen: 1, evidence: "stopped").statusText(now: now), "Stopped")
        XCTAssertEqual(make(.done, seen: 1, result: "ok").statusText(now: now), nil)
        XCTAssertEqual(make(.done, seen: 1).statusText(now: now), "Finished")
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

    func testWindowKeepsTheNewestItems() {
        let entries = (0..<200).map { user(String($0), "m\($0)") }
        let items = ChatTimeline.items(entries: entries, pending: [], notes: [])
        let window = ChatTimeline.window(items, limit: 80)
        XCTAssertEqual(window.items.count, 80)
        XCTAssertEqual(window.items.last, items.last)
        XCTAssertEqual(window.hidden, 120)
        XCTAssertEqual(ChatTimeline.window(Array(items.prefix(10)), limit: 80).hidden, 0)
    }
}
