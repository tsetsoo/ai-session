#if os(iOS)
import AVFoundation
import Foundation
import Observation
import Speech

/// One listening run: permission, then microphone → recognizer. `Dictation` owns the state
/// machine; tests substitute a fake.
@MainActor
protocol SpeechSession: AnyObject {
    /// Speech and microphone permission (asked the first time).
    func authorize() async -> Bool
    /// Starts listening. `onResult` gets the text so far and whether it is final. Throws
    /// `Dictation.Failure.unavailable` with everything torn down.
    func begin(onResult: @escaping @MainActor (String?, Bool) -> Void) throws
    /// Stops the microphone; the recognizer still delivers its final result.
    func finish()
    /// Stops everything; no more results.
    func cancel()
}

/// In-app speech-to-text for the quick-add field, on-device when the recognizer supports it.
/// `transcript` grows while it runs.
/// - `stop()` (a second tap) ends listening and lets the final result land.
/// - `cancel()` (adding the todo, leaving, going offline) drops anything still to come.
///
/// iOS only: on the Mac the keyboard's own dictation covers it.
@MainActor
@Observable
final class Dictation {
    enum Failure: LocalizedError {
        case notAllowed
        case unavailable

        var errorDescription: String? {
            switch self {
            case .notAllowed: "Allow Microphone and Speech Recognition in Settings to dictate."
            case .unavailable: "Dictation isn't available right now."
            }
        }
    }

    enum Phase {
        case idle
        /// Waiting for permission; a second tap or a cancel abandons the start.
        case starting
        case running
    }

    var transcript = ""
    private(set) var phase = Phase.idle
    /// Starting counts as running, so the mic button stops rather than starting twice.
    var isRunning: Bool { phase != .idle }

    @ObservationIgnored private let makeSession: @MainActor () -> SpeechSession
    @ObservationIgnored private var session: SpeechSession?
    /// Incremented per start and per cancel; anything from an older run is dropped.
    @ObservationIgnored private var generation = 0

    init(makeSession: @escaping @MainActor () -> SpeechSession = { LiveSpeechSession() }) {
        self.makeSession = makeSession
    }

    /// Asks for permission the first time, then listens. Ignored while starting or running.
    func start() async throws {
        guard phase == .idle else { return }
        session?.cancel()
        session = nil
        phase = .starting
        generation += 1
        let run = generation
        transcript = ""
        let session = makeSession()
        let allowed = await session.authorize()
        // Stopped or cancelled while permission was pending: never touch the microphone.
        guard run == generation, phase == .starting else { return }
        guard allowed else {
            phase = .idle
            throw Failure.notAllowed
        }
        do {
            try session.begin { [weak self] text, isFinal in
                self?.receive(text: text, isFinal: isFinal, run: run)
            }
        } catch {
            phase = .idle
            throw (error as? Failure) ?? Failure.unavailable
        }
        self.session = session
        phase = .running
    }

    /// Stops listening; the final result still lands in `transcript`.
    func stop() {
        switch phase {
        case .idle:
            return
        case .starting:
            cancel()
        case .running:
            phase = .idle
            session?.finish()
        }
    }

    /// Stops listening and drops any result still to come.
    func cancel() {
        generation += 1
        phase = .idle
        session?.cancel()
        session = nil
    }

    private func receive(text: String?, isFinal: Bool, run: Int) {
        guard run == generation else { return }
        if let text { transcript = text }
        guard isFinal else { return }
        phase = .idle
        session?.cancel()
        session = nil
    }
}

/// The microphone through `AVAudioEngine` into `SFSpeechRecognizer`.
@MainActor
final class LiveSpeechSession: SpeechSession {
    private let recognizer = SFSpeechRecognizer()
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapInstalled = false

    func authorize() async -> Bool {
        guard await Self.speechAuthorized() else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    func begin(onResult: @escaping @MainActor (String?, Bool) -> Void) throws {
        guard let recognizer, recognizer.isAvailable else { throw Dictation.Failure.unavailable }
        let audio = AVAudioSession.sharedInstance()
        do {
            try audio.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audio.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            tearDown()
            throw Dictation.Failure.unavailable
        }
        // No input (e.g. during a call): installing a tap would raise an exception.
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            tearDown()
            throw Dictation.Failure.unavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        Self.installTap(on: engine.inputNode, format: format, feeding: request)
        tapInstalled = true
        self.request = request
        engine.prepare()
        do {
            try engine.start()
        } catch {
            tearDown()
            throw Dictation.Failure.unavailable
        }
        task = recognizer.recognitionTask(with: request, resultHandler: Self.resultHandler(onResult))
    }

    func finish() {
        tearDown()
    }

    func cancel() {
        task?.cancel()
        task = nil
        tearDown()
    }

    /// Microphone off, tap removed, audio session back to the default. Safe to repeat.
    private func tearDown() {
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        request?.endAudio()
        request = nil
        let audio = AVAudioSession.sharedInstance()
        try? audio.setActive(false, options: .notifyOthersOnDeactivation)
        try? audio.setCategory(.soloAmbient, mode: .default, options: [])
    }

    // The tap and result callbacks run off the main actor; build them outside it.

    private nonisolated static func installTap(on node: AVAudioInputNode, format: AVAudioFormat,
                                               feeding request: SFSpeechAudioBufferRecognitionRequest) {
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
    }

    private nonisolated static func resultHandler(
        _ onResult: @escaping @MainActor (String?, Bool) -> Void
    ) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = (result?.isFinal ?? false) || error != nil
            Task { @MainActor in onResult(text, isFinal) }
        }
    }

    private nonisolated static func speechAuthorized() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}
#endif
