#if os(iOS)
@testable import AISessionRemote
import XCTest

@MainActor
final class ReadAloudTests: XCTestCase {
    final class FakeOutput: SpeechOutput {
        var onFinish: (@MainActor () -> Void)?
        var spoken: [(text: String, language: String?)] = []
        var stops = 0
        func speak(_ text: String, language: String?) { spoken.append((text, language)) }
        func stop() { stops += 1 }
    }

    func testReadsSpokenTextInTheMessagesLanguage() {
        let fake = FakeOutput()
        let reader = ReadAloud(output: fake)
        reader.read(id: "m1", markdown: "The **status** service is running on all three Macs.\n```\nx\n```")
        XCTAssertEqual(reader.speakingID, "m1")
        XCTAssertEqual(fake.spoken.first?.text, "The status service is running on all three Macs.\nCode block.")
        XCTAssertEqual(fake.spoken.first?.language, "en")
    }

    func testANewMessageReplacesTheOneBeingRead() {
        let fake = FakeOutput()
        let reader = ReadAloud(output: fake)
        reader.read(id: "m1", markdown: "first message here")
        reader.read(id: "m2", markdown: "second message here")
        XCTAssertEqual(reader.speakingID, "m2")
        XCTAssertEqual(fake.spoken.count, 2)
        XCTAssertGreaterThanOrEqual(fake.stops, 2, "the first is stopped before the second starts")
    }

    func testStopAndFinishClearTheMessage() {
        let fake = FakeOutput()
        let reader = ReadAloud(output: fake)
        reader.read(id: "m1", markdown: "first message here")
        reader.stop()
        XCTAssertNil(reader.speakingID)
        reader.read(id: "m2", markdown: "second message here")
        fake.onFinish?()
        XCTAssertNil(reader.speakingID)
        XCTAssertFalse(reader.isSpeaking)
    }

    func testStopWhenNothingIsReadDoesNothing() {
        let fake = FakeOutput()
        let reader = ReadAloud(output: fake)
        reader.stop()
        XCTAssertEqual(fake.stops, 0)
    }

    func testAMessageWithNothingToSayIsNotRead() {
        let fake = FakeOutput()
        let reader = ReadAloud(output: fake)
        reader.read(id: "m1", markdown: "   ")
        XCTAssertNil(reader.speakingID)
        XCTAssertTrue(fake.spoken.isEmpty)
    }
}
#endif
