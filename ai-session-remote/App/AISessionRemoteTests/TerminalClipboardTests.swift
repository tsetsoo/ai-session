import XCTest
@testable import AISessionRemote

final class TerminalClipboardTests: XCTestCase {
    func testUTF8PayloadBecomesPasteboardText() {
        let url = "https://claude.ai/oauth/authorize?code=abc"
        XCTAssertEqual(TerminalClipboard.pasteboardText(from: Data(url.utf8)), url)
    }

    func testEmptyPayloadIsAClear() {
        XCTAssertEqual(TerminalClipboard.pasteboardText(from: Data()), "")
    }

    func testInvalidUTF8DoesNotReplaceThePasteboard() {
        XCTAssertNil(TerminalClipboard.pasteboardText(from: Data([0xFF, 0xFE])))
    }
}
