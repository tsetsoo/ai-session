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
        XCTAssertEqual(fake.spoken.first?.text, "The status service is running on all three Macs.\n\nCode block.")
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

    func testNothingIsReadWhileDictating() {
        let fake = FakeOutput()
        let reader = ReadAloud(output: fake)
        reader.read(id: "m1", markdown: "first message here")
        reader.isDictating = true
        XCTAssertNil(reader.speakingID, "dictation starting stops the reading")
        reader.read(id: "m2", markdown: "second message here")
        XCTAssertNil(reader.speakingID)
        XCTAssertEqual(fake.spoken.count, 1)
        reader.isDictating = false
        reader.read(id: "m2", markdown: "second message here")
        XCTAssertEqual(reader.speakingID, "m2")
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

#if os(iOS)
final class VoiceCandidateTests: XCTestCase {
    private let samantha = VoiceCandidate(identifier: "samantha", name: "Samantha", language: "en-US", quality: .basic)
    private let ava = VoiceCandidate(identifier: "ava", name: "Ava", language: "en-US", quality: .premium)
    private let serena = VoiceCandidate(identifier: "serena", name: "Serena", language: "en-GB", quality: .premium)
    private let daniel = VoiceCandidate(identifier: "daniel", name: "Daniel", language: "en-GB", quality: .enhanced)
    private let bubbles = VoiceCandidate(identifier: "bubbles", name: "Bubbles", language: "en-US", quality: .premium, isExcluded: true)
    private let daria = VoiceCandidate(identifier: "daria", name: "Daria", language: "bg-BG", quality: .basic)
    private let us = Locale(identifier: "en_US")
    private let gb = Locale(identifier: "en_GB")

    func testHigherQualityWinsOverRegion() {
        XCTAssertEqual(VoiceCandidate.best(for: "en", among: [samantha, daniel], locale: us), daniel)
    }

    func testAmongEqualQualityTheUsersRegionWins() {
        XCTAssertEqual(VoiceCandidate.best(for: "en", among: [ava, serena], locale: gb), serena)
        XCTAssertEqual(VoiceCandidate.best(for: "en", among: [serena, ava], locale: us), ava)
    }

    func testAnExactCodeWinsOverTheRegion() {
        XCTAssertEqual(VoiceCandidate.best(for: "en-US", among: [ava, serena], locale: gb), ava)
    }

    func testNoveltyAndPersonalVoicesAreSkipped() {
        XCTAssertEqual(VoiceCandidate.best(for: "en", among: [bubbles, samantha], locale: us), samantha)
    }

    func testOtherLanguagesAndNoMatch() {
        XCTAssertEqual(VoiceCandidate.best(for: "bg", among: [ava, daria], locale: us), daria)
        XCTAssertNil(VoiceCandidate.best(for: "fr", among: [ava, daria], locale: us))
    }
}
#endif
