import XCTest
@testable import AISessionCore

final class TerminalPasteTests: XCTestCase {
    func testUnbracketedIsTheRawText() {
        XCTAssertEqual(TerminalPaste.bytes(for: "a\nb", bracketed: false), Array("a\nb".utf8))
    }

    func testBracketedWrapsTheText() {
        XCTAssertEqual(
            TerminalPaste.bytes(for: "a\nb", bracketed: true),
            Array("\u{1B}[200~a\nb\u{1B}[201~".utf8)
        )
    }

    func testBracketedDropsAnEndMarkerInsideTheText() {
        XCTAssertEqual(
            TerminalPaste.bytes(for: "x\u{1B}[201~rm -rf\n", bracketed: true),
            Array("\u{1B}[200~xrm -rf\n\u{1B}[201~".utf8)
        )
    }

    func testUnbracketedSubmissionEndsWithOneNewline() {
        XCTAssertEqual(TerminalPaste.submission("hi", bracketed: false), Array("hi\n".utf8))
        XCTAssertEqual(TerminalPaste.submission("hi\n", bracketed: false), Array("hi\n".utf8))
    }

    func testBracketedSubmissionSendsReturnAfterThePaste() {
        XCTAssertEqual(
            TerminalPaste.submission("line 1\nline 2\n\n", bracketed: true),
            Array("\u{1B}[200~line 1\nline 2\u{1B}[201~\r".utf8)
        )
    }
}
