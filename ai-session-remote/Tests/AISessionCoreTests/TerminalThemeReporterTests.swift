import XCTest
@testable import AISessionCore

final class TerminalThemeReporterTests: XCTestCase {
    private func text(_ bytes: [UInt8]?) -> String? {
        bytes.map { String(decoding: $0, as: UTF8.self) }
    }

    /// What tmux sends when a client attaches.
    private let attach = Array("\u{1B}[?2031h\u{1B}[?996n".utf8)

    func testAnswersTheThemeQuery() {
        var reporter = TerminalThemeReporter(theme: .light)
        XCTAssertEqual(text(reporter.scan(attach)), "\u{1B}[?997;2n")
        reporter = TerminalThemeReporter(theme: .dark)
        XCTAssertEqual(text(reporter.scan(Array("x\u{1B}[?99".utf8) + Array("6ny".utf8))), "\u{1B}[?997;1n")
    }

    func testNotifiesASubscribedHostOfAChange() {
        var reporter = TerminalThemeReporter(theme: .dark)
        _ = reporter.scan(attach)
        XCTAssertNil(reporter.pendingNotice())
        reporter.setTheme(.light)
        XCTAssertEqual(text(reporter.pendingNotice()), "\u{1B}[?997;2n")
        XCTAssertNil(reporter.pendingNotice())
        reporter.setTheme(.dark)
        XCTAssertEqual(text(reporter.pendingNotice()), "\u{1B}[?997;1n")
    }

    /// A surface that was hidden through two flips has nothing to tell the host.
    func testFlipsThatCancelOutSendNothing() {
        var reporter = TerminalThemeReporter(theme: .dark)
        _ = reporter.scan(attach)
        reporter.setTheme(.light)
        reporter.setTheme(.dark)
        XCTAssertNil(reporter.pendingNotice())
    }

    func testStaysQuietWithoutASubscription() {
        var reporter = TerminalThemeReporter(theme: .dark)
        reporter.setTheme(.light)
        XCTAssertNil(reporter.pendingNotice())
        for unsubscribe in ["\u{1B}[?2031l", "\u{1B}c", "\u{1B}[!p"] {
            _ = reporter.scan(attach)
            _ = reporter.scan(Array(unsubscribe.utf8))
            reporter.setTheme(reporter.theme == .dark ? .light : .dark)
            XCTAssertNil(reporter.pendingNotice(), unsubscribe.debugDescription)
        }
        _ = reporter.scan(attach)
        reporter.reset()
        reporter.setTheme(.light)
        XCTAssertNil(reporter.pendingNotice())
    }

    func testIgnoresOtherStatusReportsAndStrings() {
        var reporter = TerminalThemeReporter(theme: .dark)
        XCTAssertEqual(reporter.scan(Array("\u{1B}[996n\u{1B}[?6n\u{1B}]2;[?996n\u{07}".utf8)).count, 0)
    }
}
