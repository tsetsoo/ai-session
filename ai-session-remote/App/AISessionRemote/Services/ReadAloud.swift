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
    /// Set by the composer while dictation runs: the microphone owns the audio session then,
    /// so Read Aloud is hidden and `read` does nothing.
    var isDictating = false {
        didSet { if isDictating { stop() } }
    }

    @ObservationIgnored private let output: SpeechOutput

    init(output: SpeechOutput? = nil) {
        let output = output ?? SynthesizerOutput()
        self.output = output
        output.onFinish = { [weak self] in self?.speakingID = nil }
    }

    /// Reads one message, replacing whatever is being read.
    func read(id: String, markdown: String) {
        guard !isDictating else { return }
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
        // A call or another app taking audio ends the reading; the Stop button must go too.
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue else { return }
            MainActor.assumeIsolated {
                guard let self, self.current != nil else { return }
                self.stop()
                self.onFinish?()
            }
        }
    }

    func speak(_ text: String, language: String?) {
        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
        try? audio.setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice(for: language)
        current = utterance
        synthesizer.speak(utterance)
    }

    /// The audio session is given back from the delegate once the synthesizer has really
    /// stopped: deactivating right after `stopSpeaking` can fail while its output still runs.
    func stop() {
        current = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// NaturalLanguage names some languages differently from the voices ("zh-Hans").
    static func voice(for language: String?) -> AVSpeechSynthesisVoice? {
        let fallback = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        guard let language else { return fallback }
        let aliases = ["zh-Hans": "zh-CN", "zh-Hant": "zh-TW", "nb": "nb-NO"]
        let base = String(language.prefix { $0 != "-" })
        let wanted = [language, aliases[language], base].compactMap { $0 }
        for code in wanted {
            if let voice = AVSpeechSynthesisVoice(language: code) { return voice }
        }
        return AVSpeechSynthesisVoice.speechVoices().first { $0.language.hasPrefix(base + "-") } ?? fallback
    }

    private func releaseIfIdle() {
        // Something new is being read, or dictation has taken the session: leave it alone.
        let audio = AVAudioSession.sharedInstance()
        guard current == nil, !synthesizer.isSpeaking, audio.category == .playback else { return }
        try? audio.setActive(false, options: .notifyOthersOnDeactivation)
        try? audio.setCategory(.soloAmbient, mode: .default, options: [])
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if utterance === self.current {
                self.current = nil
                self.onFinish?()
            }
            self.releaseIfIdle()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.releaseIfIdle() }
    }
}
#endif
