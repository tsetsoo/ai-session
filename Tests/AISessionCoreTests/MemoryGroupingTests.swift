import XCTest
@testable import AISessionCore

final class MemoryGroupingTests: XCTestCase {
    private func memory(_ id: String, _ kind: MemoryKind, pinned: Bool = false, session: String? = nil,
                        created: String) -> Memory {
        Memory(id: id, projectId: "p1", tool: session == nil ? nil : "claude", sessionId: session,
               kind: kind, text: id, pinned: pinned, createdAt: created)
    }

    func testGroupedOrdersKindsThenPinnedThenNewest() {
        let memories = [
            memory("files", .filesChanged, created: "2026-10-16 09:00:00"),
            memory("old-gotcha", .gotcha, created: "2026-10-01 09:00:00"),
            memory("new-gotcha", .gotcha, created: "2026-10-16 09:00:00"),
            memory("pinned-old-gotcha", .gotcha, pinned: true, created: "2026-09-01 09:00:00"),
            memory("thread", .openThread, created: "2026-10-10 09:00:00"),
            memory("decision", .decision, created: "2026-10-12T08:00:00Z"),
            memory("newer-decision", .decision, created: "2026-10-12T09:00:00Z"),
        ]
        let groups = MemoryGrouping.grouped(memories)
        XCTAssertEqual(groups.map(\.kind), [.openThread, .decision, .gotcha, .filesChanged], "empty kinds are left out")
        XCTAssertEqual(groups[1].memories.map(\.id), ["newer-decision", "decision"])
        XCTAssertEqual(groups[2].memories.map(\.id), ["pinned-old-gotcha", "new-gotcha", "old-gotcha"])
        XCTAssertTrue(MemoryGrouping.grouped([]).isEmpty)
    }

    func testMixedDateSpellingsSortByTime() {
        let memories = [
            memory("sqlite-later", .done, created: "2026-10-16 10:00:00"),
            memory("iso-earlier", .done, created: "2026-10-16T09:30:00Z"),
        ]
        XCTAssertEqual(MemoryGrouping.grouped(memories).first?.memories.map(\.id), ["sqlite-later", "iso-earlier"])
    }

    func testForConversationPutsThisSessionFirst() {
        let memories = [
            memory("other-new", .gotcha, session: "s2", created: "2026-10-16 09:00:00"),
            memory("mine-old", .decision, session: "s1", created: "2026-10-01 09:00:00"),
            memory("manual-pinned", .openThread, pinned: true, created: "2026-09-01 09:00:00"),
            memory("mine-new", .done, session: "s1", created: "2026-10-15 09:00:00"),
        ]
        XCTAssertEqual(
            MemoryGrouping.forConversation(memories, sessionId: "s1").map(\.id),
            ["mine-new", "mine-old", "manual-pinned", "other-new"]
        )
        XCTAssertEqual(
            MemoryGrouping.forConversation(memories, sessionId: nil).map(\.id),
            ["manual-pinned", "other-new", "mine-new", "mine-old"]
        )
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ text: String) -> Date {
        HubDates.date(from: text + "T12:00:00Z")!
    }

    func testMondayOfWeek() {
        XCTAssertEqual(WeekMath.monday(of: date("2026-10-18"), calendar: utc), "2026-10-12", "Sunday → previous Monday")
        XCTAssertEqual(WeekMath.monday(of: date("2026-10-12"), calendar: utc), "2026-10-12", "Monday → itself")
        XCTAssertEqual(WeekMath.monday(of: date("2026-10-16"), calendar: utc), "2026-10-12")
        XCTAssertEqual(WeekMath.monday(of: date("2027-01-01"), calendar: utc), "2026-12-28", "across a year")

        // A Monday-first or Sunday-first locale gives the same answer.
        var sundayFirst = utc
        sundayFirst.firstWeekday = 1
        XCTAssertEqual(WeekMath.monday(of: date("2026-10-18"), calendar: sundayFirst), "2026-10-12")
    }

    func testShiftWeek() {
        XCTAssertEqual(WeekMath.shift("2026-10-12", byWeeks: -1, calendar: utc), "2026-10-05")
        XCTAssertEqual(WeekMath.shift("2026-12-28", byWeeks: 1, calendar: utc), "2027-01-04")
        XCTAssertNil(WeekMath.shift("nope", byWeeks: 1, calendar: utc))
        XCTAssertEqual(WeekMath.addingDays(6, to: "2026-10-12", calendar: utc), "2026-10-18")
    }

    func testDurationAndTokenFormatting() {
        XCTAssertEqual(StatsFormat.duration(seconds: 0), "0m")
        XCTAssertEqual(StatsFormat.duration(seconds: 59), "0m")
        XCTAssertEqual(StatsFormat.duration(seconds: 5400), "1h 30m")
        XCTAssertEqual(StatsFormat.duration(seconds: 61200), "17h 0m")
        XCTAssertEqual(StatsFormat.tokens(nil), "–")
        XCTAssertEqual(StatsFormat.tokens(950), "950")
        XCTAssertEqual(StatsFormat.tokens(51234), "51.2k")
        XCTAssertEqual(StatsFormat.tokens(9_123_456), "9.1M")
    }
}
