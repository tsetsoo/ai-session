import AISessionCore
import XCTest

final class WeeklySectionTextTests: XCTestCase {
    private func section(_ states: [String], daysWithWork: Int = 3) -> WeeklySection {
        let days = states.enumerated().map { WeeklyDayState(day: String(format: "2026-11-%02d", 2 + $0.offset), state: $0.element) }
        return WeeklySection(projectId: "p", commits: 1, conversations: 5, daysWithWork: daysWithWork, days: days)
    }

    func testCountLineExcludesUntrackedDays() {
        let s = section(["untracked", "untracked", "update", "update", "quiet", "update", "missing"])
        XCTAssertEqual(s.countLine, "5 conversations · 1 commit · 3 of 5 days")
        XCTAssertEqual(s.updateCount, 3)
    }

    func testCountLineWithNoDaysIsOfSeven() {
        XCTAssertEqual(section([]).countLine, "5 conversations · 1 commit · 3 of 7 days")
    }

    func testGapsCaptionNamesWeekdaysInUTC() {
        // 2026-11-02 is a Monday.
        let s = section(["update", "update", "failed", "missing", "missing", "quiet", "update"])
        XCTAssertEqual(s.gapsCaption, "Thu and Fri missing · Wed couldn't be written")
        XCTAssertNil(section(["update", "quiet"]).gapsCaption)
        XCTAssertEqual(WeeklySection.list(["Mon", "Tue", "Thu"]), "Mon, Tue and Thu")
    }
}

final class WeeklyRecapDayTests: XCTestCase {
    func testRecapDayIsMondayInSofia() {
        let f = ISO8601DateFormatter()
        // Sun 8 Nov 22:30 UTC is Mon 9 Nov 00:30 in Sofia (UTC+2).
        XCTAssertTrue(WeeklyRecap.isRecapDay(f.date(from: "2026-11-08T22:30:00Z")!))
        // Mon 9 Nov 21:58 UTC is 23:58 Sofia; 21:59 UTC is 23:59.
        XCTAssertTrue(WeeklyRecap.isRecapDay(f.date(from: "2026-11-09T21:58:00Z")!))
        XCTAssertFalse(WeeklyRecap.isRecapDay(f.date(from: "2026-11-09T21:59:00Z")!))
        XCTAssertFalse(WeeklyRecap.isRecapDay(f.date(from: "2026-11-10T09:00:00Z")!))
    }
}
