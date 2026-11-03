import XCTest
@testable import AISessionCore

final class SpokenTextTests: XCTestCase {
    func testMarkdownIsReadAsProseAndCodeIsNamedNotRead() {
        let text = "## Done\nThe **fix** is in `status.py`.\n```swift\nlet a = 1\n```\n- one\n- two"
        XCTAssertEqual(SpokenText.make(text), "Done\nThe fix is in status.py.\nCode block.\none\ntwo")
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
