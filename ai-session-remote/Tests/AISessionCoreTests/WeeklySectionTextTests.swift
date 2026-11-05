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
    func testRecapDayIsMondayFromEightInSofia() {
        let f = ISO8601DateFormatter()
        // Sun 8 Nov 22:30 UTC is Mon 9 Nov 00:30 in Sofia (UTC+2): the recap isn't written yet.
        XCTAssertFalse(WeeklyRecap.isRecapDay(f.date(from: "2026-11-08T22:30:00Z")!))
        // 05:59 UTC is 07:59 Sofia; 06:00 UTC is 08:00.
        XCTAssertFalse(WeeklyRecap.isRecapDay(f.date(from: "2026-11-09T05:59:00Z")!))
        XCTAssertTrue(WeeklyRecap.isRecapDay(f.date(from: "2026-11-09T06:00:00Z")!))
        // Mon 9 Nov 21:58 UTC is 23:58 Sofia; 21:59 UTC is 23:59.
        XCTAssertTrue(WeeklyRecap.isRecapDay(f.date(from: "2026-11-09T21:58:00Z")!))
        XCTAssertFalse(WeeklyRecap.isRecapDay(f.date(from: "2026-11-09T21:59:00Z")!))
        XCTAssertFalse(WeeklyRecap.isRecapDay(f.date(from: "2026-11-10T09:00:00Z")!))
    }
}

final class WeeklyDayKeptTests: XCTestCase {
    func testDaysOlderThanNinetyDaysInSofiaAreGone() {
        // 2026-11-04 22:30 UTC is already 5 Nov in Sofia; 90 days before is 7 Aug.
        let now = ISO8601DateFormatter().date(from: "2026-11-04T22:30:00Z")!
        XCTAssertTrue(WeeklyRecap.isDayKept("2026-08-07", now: now))
        XCTAssertFalse(WeeklyRecap.isDayKept("2026-08-06", now: now))
        XCTAssertTrue(WeeklyRecap.isDayKept("2026-11-02", now: now))
    }
}

final class WeeklyRewritableTests: XCTestCase {
    func testRewriteOnlyWhileTheWeeksMondayIsKept() {
        let f = ISO8601DateFormatter()
        // 90 days before Sofia's 31 Jan 2027 is 2 Nov 2026: the week's Monday is still kept.
        XCTAssertTrue(WeeklyRecap(week: "2026-11-02").isRewritable(now: f.date(from: "2027-01-31T10:00:00Z")!))
        XCTAssertFalse(WeeklyRecap(week: "2026-11-02").isRewritable(now: f.date(from: "2027-02-01T10:00:00Z")!))
    }
}
