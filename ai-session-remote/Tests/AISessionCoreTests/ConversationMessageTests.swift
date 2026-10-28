import XCTest
@testable import AISessionCore

final class ConversationMessageTests: XCTestCase {
    func testTranscriptPreservesWhitespaceAndRoles() throws {
        let json = #"[{"id":"0","role":"user","text":"  first\n\n    code  \n"},{"id":"1","role":"assistant","text":"reply"}]"#
        let messages = try JSONDecoder().decode([ConversationMessage].self, from: Data(json.utf8))
        XCTAssertEqual(messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(messages[0].text, "  first\n\n    code  \n")
    }
}
