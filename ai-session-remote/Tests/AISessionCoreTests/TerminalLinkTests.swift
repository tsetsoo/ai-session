import Foundation
import XCTest
@testable import AISessionCore

final class TerminalLinkTests: XCTestCase {
    func testLocalHTMLPathIsAFileURL() throws {
        let path = "/Users/tsvetelinpantev/programming/sigma-revenue/rosslyn-period-pricing.html"
        // Reproduce the old handler: this parses, but is not a file URL.
        XCTAssertFalse(try XCTUnwrap(URL(string: path)).isFileURL)
        let url = try XCTUnwrap(TerminalLink.url(for: path))
        XCTAssertTrue(url.isFileURL)
        XCTAssertEqual(url.path, path)
    }

    func testPathCharactersAreLiteralRatherThanURLSyntax() throws {
        let path = "/tmp/price reports/café #1?100%20.html"
        let url = try XCTUnwrap(TerminalLink.url(for: path))
        XCTAssertTrue(url.isFileURL)
        XCTAssertEqual(url.path, path)
        XCTAssertNil(url.query)
        XCTAssertNil(url.fragment)
    }

    func testHomePathIsExpanded() throws {
        let url = try XCTUnwrap(TerminalLink.url(for: "~/report.html"))
        XCTAssertTrue(url.isFileURL)
        XCTAssertEqual(url.path, FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("report.html").path)
    }

    func testExplicitURLsKeepTheirEscapingQueryAndFragment() throws {
        for link in ["file:///tmp/price%20report.html", "https://example.com/report?q=a%20b#prices",
                     "http://localhost:8080/report", "mailto:hello@example.com"] {
            XCTAssertEqual(try XCTUnwrap(TerminalLink.url(for: link)).absoluteString, link)
        }
    }

    func testUnresolvedRelativePathsAreNotPassedToLaunchServices() {
        for link in ["", "report.html", "./report.html", "../report.html"] {
            XCTAssertNil(TerminalLink.url(for: link))
        }
    }
}
