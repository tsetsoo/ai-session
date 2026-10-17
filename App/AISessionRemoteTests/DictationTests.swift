import XCTest
@testable import AISessionRemote

@MainActor
final class DictationTests: XCTestCase {
    private struct BeginFailed: Error {}

    private final class FakeSession: SpeechSession {
        /// Answer authorization at once; nil holds it until `grant(_:)`.
        var immediateAnswer: Bool? = true
        var failBegin = false
        private(set) var pendingAuthorization: CheckedContinuation<Bool, Never>?
        private(set) var beginCount = 0
        private(set) var finishCount = 0
        private(set) var cancelCount = 0
        private var onResult: (@MainActor (String?, Bool) -> Void)?

        func authorize() async -> Bool {
            if let immediateAnswer { return immediateAnswer }
            return await withCheckedContinuation { pendingAuthorization = $0 }
        }

        func grant(_ allowed: Bool) {
            pendingAuthorization?.resume(returning: allowed)
            pendingAuthorization = nil
        }

        func begin(onResult: @escaping @MainActor (String?, Bool) -> Void) throws {
            beginCount += 1
            if failBegin { throw BeginFailed() }
            self.onResult = onResult
        }

        func finish() { finishCount += 1 }
        func cancel() { cancelCount += 1 }

        /// What the recognizer would deliver (it keeps delivering after finish or cancel).
        func emit(_ text: String, final: Bool = false) {
            onResult?(text, final)
        }
    }

    private final class Counter {
        var value = 0
    }

    private func makeDictation(_ fake: FakeSession, made: Counter = Counter()) -> Dictation {
        Dictation(makeSession: {
            made.value += 1
            return fake
        })
    }

    /// Lets a start that is waiting for permission reach that point.
    private func waitForAuthorization(_ fake: FakeSession) async {
        while fake.pendingAuthorization == nil { await Task.yield() }
    }

    func testStartListensAndCollectsTheTranscript() async throws {
        let fake = FakeSession()
        let dictation = makeDictation(fake)
        try await dictation.start()
        XCTAssertEqual(dictation.phase, .running)
        fake.emit("call the")
        fake.emit("call the Bansko hotel")
        XCTAssertEqual(dictation.transcript, "call the Bansko hotel")
    }

    func testSecondStartWhileWaitingForPermissionIsIgnored() async throws {
        let fake = FakeSession()
        fake.immediateAnswer = nil
        let made = Counter()
        let dictation = makeDictation(fake, made: made)
        let first = Task { try await dictation.start() }
        await waitForAuthorization(fake)
        XCTAssertTrue(dictation.isRunning, "starting counts as running")

        try await dictation.start()
        fake.grant(true)
        try await first.value

        XCTAssertEqual(made.value, 1)
        XCTAssertEqual(fake.beginCount, 1)
        XCTAssertEqual(dictation.phase, .running)
    }

    func testStopWhileWaitingForPermissionNeverTurnsTheMicOn() async throws {
        let fake = FakeSession()
        fake.immediateAnswer = nil
        let dictation = makeDictation(fake)
        let start = Task { try await dictation.start() }
        await waitForAuthorization(fake)

        dictation.stop()
        fake.grant(true)
        try await start.value

        XCTAssertEqual(fake.beginCount, 0)
        XCTAssertEqual(dictation.phase, .idle)
    }

    func testStopLetsTheFinalResultLand() async throws {
        let fake = FakeSession()
        let dictation = makeDictation(fake)
        try await dictation.start()
        fake.emit("call the bansko")

        dictation.stop()
        XCTAssertEqual(dictation.phase, .idle)
        XCTAssertEqual(fake.finishCount, 1)
        fake.emit("Call the Bansko hotel.", final: true)

        XCTAssertEqual(dictation.transcript, "Call the Bansko hotel.")
        XCTAssertEqual(fake.cancelCount, 1, "torn down after the final result")
    }

    func testCancelDropsLateResults() async throws {
        let fake = FakeSession()
        let dictation = makeDictation(fake)
        try await dictation.start()
        fake.emit("call the bansko")

        dictation.cancel()
        fake.emit("Call the Bansko hotel.", final: true)

        XCTAssertEqual(dictation.transcript, "call the bansko")
        XCTAssertEqual(dictation.phase, .idle)
        XCTAssertEqual(fake.cancelCount, 1)
        XCTAssertEqual(fake.finishCount, 0)
    }

    func testFinalResultWhileListeningEndsTheRun() async throws {
        let fake = FakeSession()
        let dictation = makeDictation(fake)
        try await dictation.start()
        fake.emit("done", final: true)
        XCTAssertEqual(dictation.phase, .idle)
        XCTAssertEqual(fake.cancelCount, 1)
    }

    func testRefusedPermissionThrowsAndStaysOff() async {
        let fake = FakeSession()
        fake.immediateAnswer = false
        let dictation = makeDictation(fake)
        do {
            try await dictation.start()
            XCTFail("expected notAllowed")
        } catch {
            XCTAssertEqual(error as? Dictation.Failure, .notAllowed)
        }
        XCTAssertEqual(fake.beginCount, 0)
        XCTAssertEqual(dictation.phase, .idle)
    }

    func testUnavailableMicrophoneThrowsAndStaysOff() async {
        let fake = FakeSession()
        fake.failBegin = true
        let dictation = makeDictation(fake)
        do {
            try await dictation.start()
            XCTFail("expected unavailable")
        } catch {
            XCTAssertEqual(error as? Dictation.Failure, .unavailable)
        }
        XCTAssertEqual(dictation.phase, .idle)
    }
}
