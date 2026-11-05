import XCTest
@testable import AISessionCore

final class SpokenTextTests: XCTestCase {
    func testMarkdownIsReadAsProseAndCodeIsNamedNotRead() {
        let text = "## Done\nThe **fix** is in `status.py`.\n```swift\nlet a = 1\n```\n- one\n- two"
        XCTAssertEqual(SpokenText.make(text), "Done\nThe fix is in status dot py.\n\nCode block.\n\none\ntwo")
    }

    func testInlineCodeIsSaidTheWayAPersonWould() {
        XCTAssertEqual(SpokenText.make("Edit `ReadAloud.swift` and `~/.ai-remote/bin`."),
                       "Edit Read Aloud dot swift and ~ slash dot ai-remote slash bin.")
        XCTAssertEqual(SpokenText.make("Run `/theme` with `max_tokens` on `v1.2`."),
                       "Run slash theme with max tokens on v1.2.")
        XCTAssertEqual(SpokenText.make("A plain e.g. stays."), "A plain e.g. stays.")
    }

    func testPartsPauseLongerBetweenParagraphs() {
        let parts = SpokenText.parts(SpokenText.make("## Done\nAll good.\n\nNext step.\n```\nx\n```"))
        XCTAssertEqual(parts, [
            SpokenPart(text: "Done", pause: SpokenText.linePause),
            SpokenPart(text: "All good.", pause: SpokenText.paragraphPause),
            SpokenPart(text: "Next step.", pause: SpokenText.paragraphPause),
            SpokenPart(text: "Code block.", pause: 0),
        ])
        XCTAssertEqual(SpokenText.parts("  \n"), [])
    }

    func testTableRowsAreReadAsSentences() {
        let text = "| Mac | State |\n|---|---|\n| spread | idle |"
        XCTAssertEqual(SpokenText.make(text), "Mac, State.\nspread, idle.")
    }

    func testLanguageIsDetectedPerMessage() {
        XCTAssertEqual(SpokenText.language(of: "The status service is running on all three Macs now."), "en")
        XCTAssertEqual(SpokenText.language(of: "Услугата за статус работи на всички три компютъра."), "bg")
    }

    func testTooLittleTextHasNoLanguage() {
        XCTAssertNil(SpokenText.language(of: "ok"))
        XCTAssertNil(SpokenText.language(of: "```\nx\n```"))
    }
}
