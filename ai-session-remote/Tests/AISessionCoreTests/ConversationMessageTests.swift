import XCTest
@testable import AISessionCore

final class ConversationMessageTests: XCTestCase {
    func testTranscriptPreservesWhitespaceAndRoles() throws {
        let json = #"[{"id":"0","role":"user","text":"  first\n\n    code  \n"},{"id":"1","role":"assistant","text":"reply"}]"#
        let messages = try JSONDecoder().decode([ConversationMessage].self, from: Data(json.utf8))
        XCTAssertEqual(messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(messages[0].text, "  first\n\n    code  \n")
    }

    func testActivityEntriesDecodeWithKindTargetAndTime() throws {
        let json = #"[{"id":"0.1","role":"activity","text":"","kind":"run","target":"npm test","name":"Bash","time":"2026-10-31T10:00:00.123Z"},{"id":"0.2","role":"assistant","text":"ok","time":"2026-10-31T10:00:01Z"}]"#
        let entries = try ConversationMessage.decodeList(Data(json.utf8))
        XCTAssertEqual(entries[0].role, .activity)
        XCTAssertEqual(entries[0].kind, .run)
        XCTAssertEqual(entries[0].target, "npm test")
        XCTAssertEqual(entries[0].time?.timeIntervalSince1970 ?? 0, 1_793_440_800.123, accuracy: 0.001)
        XCTAssertEqual(entries[1].time?.timeIntervalSince1970, 1_793_440_801)
    }

    func testMissingTimeAndUnknownKindStillDecode() throws {
        let json = #"[{"id":"1","role":"activity","text":"","kind":"teleport","target":"x"},{"id":"2","role":"user","text":"hi"}]"#
        let entries = try ConversationMessage.decodeList(Data(json.utf8))
        XCTAssertEqual(entries[0].kind, .other)
        XCTAssertNil(entries[0].time)
        XCTAssertNil(entries[1].kind)
    }
}
