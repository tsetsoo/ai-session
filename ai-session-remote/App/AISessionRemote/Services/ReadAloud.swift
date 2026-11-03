#if os(iOS)
import AISessionCore
import AVFoundation
import Foundation
import Observation

/// Speaks text; `ReadAloud` owns the state. Tests substitute a fake.
@MainActor
protocol SpeechOutput: AnyObject {
    /// Called when an utterance ends by itself (not after `stop()`).
    var onFinish: (@MainActor () -> Void)? { get set }
    func speak(_ text: String, language: String?)
    func stop()
}

/// Read Aloud for chat messages, one at a time across the app. `speakingID` is the message
/// being read. Starting dictation, leaving the chat or tapping Stop calls `stop()`.
@MainActor
@Observable
final class ReadAloud {
    static let shared = ReadAloud()

    private(set) var speakingID: String?
    var isSpeaking: Bool { speakingID != nil }

    @ObservationIgnored private let output: SpeechOutput

    init(output: SpeechOutput? = nil) {
        let output = output ?? SynthesizerOutput()
        self.output = output
        output.onFinish = { [weak self] in self?.speakingID = nil }
    }

    /// Reads one message, replacing whatever is being read.
    func read(id: String, markdown: String) {
        let text = SpokenText.make(markdown)
        output.stop()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            speakingID = nil
            return
        }
        speakingID = id
        output.speak(text, language: SpokenText.language(of: markdown))
    }

    func stop() {
        guard speakingID != nil else { return }
        speakingID = nil
        output.stop()
    }
}

/// `AVSpeechSynthesizer` with the voice for the message's language. Plays with the ring/silent
/// switch on, ducking other audio, and gives the audio session back when done.
@MainActor
final class SynthesizerOutput: NSObject, SpeechOutput, AVSpeechSynthesizerDelegate {
    var onFinish: (@MainActor () -> Void)?
    private let synthesizer = AVSpeechSynthesizer()
    /// The utterance whose end counts; one replaced or stopped doesn't clear the next.
    private var current: AVSpeechUtterance?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, language: String?) {
        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
        try? audio.setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = language.flatMap { AVSpeechSynthesisVoice(language: $0) }
            ?? AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        current = utterance
        synthesizer.speak(utterance)
    }

    func stop() {
        current = nil
        synthesizer.stopSpeaking(at: .immediate)
        release()
    }

    private func release() {
        // Dictation sets its own category when it starts; only give the session back otherwise.
        let audio = AVAudioSession.sharedInstance()
        guard audio.category == .playback else { return }
        try? audio.setActive(false, options: .notifyOthersOnDeactivation)
        try? audio.setCategory(.soloAmbient, mode: .default, options: [])
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard utterance === self.current else { return }
            self.current = nil
            self.release()
            self.onFinish?()
        }
    }
}
#endif
