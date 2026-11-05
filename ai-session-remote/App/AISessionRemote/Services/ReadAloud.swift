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

/// The Read Aloud speed, set in Settings → Read Aloud.
enum ReadAloudSettings {
    static let rateKey = "readAloud.rate"
    static let normalRate = Double(AVSpeechUtteranceDefaultSpeechRate)
    static let rates: [(name: String, value: Double)] = [
        ("Slower", normalRate - 0.06), ("Normal", normalRate), ("Faster", normalRate + 0.05), ("Fastest", normalRate + 0.1),
    ]

    static var rate: Float {
        let stored = UserDefaults.standard.object(forKey: rateKey) as? Double
        return Float(stored ?? normalRate)
    }
}

/// A voice as far as choosing one goes; `best` is plain logic so it can be tested.
struct VoiceCandidate: Equatable {
    enum Quality: Int, Comparable {
        case basic, enhanced, premium
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let identifier: String
    let name: String
    let language: String
    let quality: Quality
    /// Novelty voices (Bells, Bubbles…) and the user's Personal Voice are never picked.
    let isExcluded: Bool

    init(identifier: String, name: String, language: String, quality: Quality, isExcluded: Bool = false) {
        self.identifier = identifier
        self.name = name
        self.language = language
        self.quality = quality
        self.isExcluded = isExcluded
    }

    init(_ voice: AVSpeechSynthesisVoice) {
        let quality: Quality = switch voice.quality {
        case .premium: .premium
        case .enhanced: .enhanced
        default: .basic
        }
        self.init(
            identifier: voice.identifier, name: voice.name, language: voice.language, quality: quality,
            isExcluded: voice.voiceTraits.contains(.isNoveltyVoice) || voice.voiceTraits.contains(.isPersonalVoice)
        )
    }

    /// NaturalLanguage names some languages differently from the voices ("zh-Hans").
    private static let aliases = ["zh-Hans": "zh-CN", "zh-Hant": "zh-TW", "nb": "nb-NO"]

    /// The highest quality voice whose language matches. Among equals: the exact code asked
    /// for, then the region of `locale` (English read on an en-GB phone prefers an en-GB voice).
    static func best(for language: String, among voices: [VoiceCandidate], locale: Locale) -> VoiceCandidate? {
        let code = aliases[language] ?? language
        let base = String(code.prefix { $0 != "-" })
        let region = locale.region?.identifier
        let matching = voices.filter { !$0.isExcluded && ($0.language == code || $0.language.hasPrefix(base + "-") || $0.language == base) }
        func rank(_ voice: VoiceCandidate) -> (Int, Int, Int) {
            let exact = voice.language == code ? 1 : 0
            let local = region.map { voice.language == "\(base)-\($0)" } == true ? 1 : 0
            return (voice.quality.rawValue, exact, local)
        }
        return matching.max { rank($0) < rank($1) }
    }
}

/// `AVSpeechSynthesizer` with the best voice for the message's language. Plays with the ring/silent
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

    /// Each line is its own utterance with a short pause after it, so headings and list items
    /// end like sentences. `current` is the last one: its end is the reading's end.
    func speak(_ text: String, language: String?) {
        let parts = SpokenText.parts(text)
        guard !parts.isEmpty else { return }
        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
        try? audio.setActive(true)
        let voice = Self.voice(for: language)
        let rate = ReadAloudSettings.rate
        for part in parts {
            let utterance = AVSpeechUtterance(string: part.text)
            utterance.voice = voice
            utterance.rate = rate
            utterance.postUtteranceDelay = part.pause
            current = utterance
            synthesizer.speak(utterance)
        }
    }

    /// The audio session is given back from the delegate once the synthesizer has really
    /// stopped: deactivating right after `stopSpeaking` can fail while its output still runs.
    func stop() {
        current = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// The best installed voice for the language (premium, then enhanced, then the basic one),
    /// in the user's own region when there's a choice.
    static func voice(for language: String?) -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let candidates = voices.map(VoiceCandidate.init)
        let wanted = language ?? AVSpeechSynthesisVoice.currentLanguageCode()
        guard let best = VoiceCandidate.best(for: wanted, among: candidates, locale: Locale.current) else {
            return AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        }
        return AVSpeechSynthesisVoice(identifier: best.identifier)
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
