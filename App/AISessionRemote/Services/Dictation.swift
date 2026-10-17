#if os(iOS)
import AVFoundation
import Foundation
import Observation
import Speech

/// In-app speech-to-text for the quick-add field: the microphone through `SFSpeechRecognizer`,
/// on-device when the recognizer supports it. `transcript` grows while it runs; `stop()` (a
/// second tap) ends it, and so does the recognizer finishing on its own. iOS only: on the Mac the
/// keyboard's own dictation covers it.
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

    var transcript = ""
    private(set) var isRunning = false

    @ObservationIgnored private let recognizer = SFSpeechRecognizer()
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    /// Incremented per start; results from an earlier run are dropped.
    @ObservationIgnored private var generation = 0

    /// Asks for speech and microphone permission the first time, then listens.
    func start() async throws {
        guard !isRunning else { return }
        guard await Self.speechAuthorized(), await AVAudioApplication.requestRecordPermission() else {
            throw Failure.notAllowed
        }
        guard let recognizer, recognizer.isAvailable else { throw Failure.unavailable }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        Self.installTap(on: engine.inputNode, feeding: request)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw Failure.unavailable
        }

        // A previous run still finishing must not write into this one.
        task?.cancel()
        generation += 1
        transcript = ""
        isRunning = true
        self.request = request
        task = recognizer.recognitionTask(
            with: request, resultHandler: Self.resultHandler(for: self, generation: generation)
        )
    }

    /// Stops listening; the recognizer still delivers what it heard so far.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func receive(text: String?, isFinal: Bool, generation: Int) {
        guard generation == self.generation else { return }
        if let text { transcript = text }
        if isFinal {
            stop()
            task = nil
        }
    }

    // The tap and result callbacks run off the main actor; build them outside it.

    private nonisolated static func installTap(on node: AVAudioInputNode,
                                               feeding request: SFSpeechAudioBufferRecognitionRequest) {
        node.installTap(onBus: 0, bufferSize: 1024, format: node.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
    }

    private nonisolated static func resultHandler(
        for dictation: Dictation, generation: Int
    ) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { [weak dictation] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = (result?.isFinal ?? false) || error != nil
            Task { @MainActor in dictation?.receive(text: text, isFinal: isFinal, generation: generation) }
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
