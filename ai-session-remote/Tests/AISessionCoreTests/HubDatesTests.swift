import XCTest
@testable import AISessionCore

final class HubDatesTests: XCTestCase {
    private let iso = ISO8601DateFormatter()

    /// The hub's `YYYY-MM-DD HH:MM:SS` (UTC) reads as the same instant as its ISO 8601 form,
    /// across leap years and centuries.
    func testHubFormMatchesISO8601() {
        for year in stride(from: 1970, through: 2400, by: 7) {
            for (month, day) in [(1, 1), (2, 28), (2, 29), (3, 1), (6, 30), (12, 31)] {
                let date = String(format: "%04d-%02d-%02d", year, month, day)
                guard let expected = iso.date(from: "\(date)T13:07:59Z") else { continue }
                XCTAssertEqual(HubDates.date(from: "\(date) 13:07:59"), expected, date)
            }
        }
    }

    /// Days a month doesn't have read as the formatter reads them.
    func testOutOfRangeDayMatchesFormatter() {
        for date in ["2026-02-29", "2026-02-30", "2026-04-31", "2024-02-30"] {
            XCTAssertEqual(HubDates.date(from: "\(date) 08:00:00"), iso.date(from: "\(date)T08:00:00Z"), date)
        }
    }

    func testOtherFormsStillParse() {
        XCTAssertEqual(HubDates.date(from: "2026-10-16T10:30:00Z"), iso.date(from: "2026-10-16T10:30:00Z"))
        XCTAssertNotNil(HubDates.date(from: "2026-10-16T10:30:00.250Z"))
        XCTAssertEqual(HubDates.date(from: " 2026-10-16 10:30:00 "), iso.date(from: "2026-10-16T10:30:00Z"))
    }

    func testRejectsMalformed() {
        for text in [nil, "", "2026-10-16", "2026-13-16 10:30:00", "2026-1x-16 10:30:00"] {
            XCTAssertNil(HubDates.date(from: text), text ?? "nil")
        }
    }
}
