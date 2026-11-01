#if os(iOS)
import AVFoundation
import Foundation
import Speech

/// Picks the engine when listening starts: Apple's `SpeechAnalyzer` on iOS 26 when it covers
/// this device and language, otherwise `SFSpeechRecognizer`. Also falls back when the new
/// engine can't start, e.g. its model isn't downloaded yet and the phone is offline.
@MainActor
final class AdaptiveSpeechSession: SpeechSession {
    private var inner: SpeechSession?
    private var cancelled = false

    func authorize() async -> Bool {
        await LiveSpeechSession.authorizeSpeechAndMicrophone()
    }

    func begin(onResult: @escaping @MainActor (String?, Bool) -> Void) async throws {
        if #available(iOS 26.0, *), let locale = await AnalyzerSpeechSession.supportedLocale() {
            guard !cancelled else { throw Dictation.Failure.unavailable }
            let analyzer = AnalyzerSpeechSession(locale: locale)
            inner = analyzer
            do {
                try await analyzer.begin(onResult: onResult)
                return
            } catch {
                analyzer.cancel()
                if cancelled { throw Dictation.Failure.unavailable }
            }
        }
        guard !cancelled else { throw Dictation.Failure.unavailable }
        let legacy = LiveSpeechSession()
        inner = legacy
        try await legacy.begin(onResult: onResult)
    }

    func finish() { inner?.finish() }

    func cancel() {
        cancelled = true
        inner?.cancel()
    }
}

/// Shared by both engines: the audio session while the microphone is on.
enum RecordingAudioSession {
    static func activate() throws {
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audio.setActive(true, options: .notifyOthersOnDeactivation)
    }

    static func deactivate() {
        let audio = AVAudioSession.sharedInstance()
        try? audio.setActive(false, options: .notifyOthersOnDeactivation)
        try? audio.setCategory(.soloAmbient, mode: .default, options: [])
    }
}

/// Builds the running transcript from `SpeechTranscriber` results: finalized text accumulates,
/// the latest volatile (still changing) text sits after it until it is replaced or finalized.
struct TranscriptAccumulator {
    private(set) var finalized = ""
    private var volatile = ""

    var text: String { Self.join(finalized, volatile) }

    mutating func receive(_ segment: String, isFinal: Bool) {
        if isFinal {
            finalized = Self.join(finalized, segment)
            volatile = ""
        } else {
            volatile = segment
        }
    }

    /// Segments may or may not carry their own leading space.
    static func join(_ head: String, _ tail: String) -> String {
        guard let last = head.last, let first = tail.first else { return head + tail }
        if last.isWhitespace || first.isWhitespace { return head + tail }
        return head + " " + tail
    }
}

/// The microphone through `AVAudioEngine` into `SpeechAnalyzer` + `SpeechTranscriber` (iOS 26):
/// the on-device model behind Notes and Voice Memos transcription, with punctuation.
@available(iOS 26.0, *)
@MainActor
final class AnalyzerSpeechSession: SpeechSession {
    private let locale: Locale
    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var tapInstalled = false
    private var ownsAudio = false
    private var cancelled = false
    /// The analyzer is running; until then an ending results stream means a failed start.
    private var started = false
    private var resultsEndedEarly = false

    init(locale: Locale) {
        self.locale = locale
    }

    /// The transcriber's locale for the user's language, or nil when this device or language
    /// isn't covered.
    static func supportedLocale() async -> Locale? {
        guard SpeechTranscriber.isAvailable else { return nil }
        return await SpeechTranscriber.supportedLocale(equivalentTo: .current)
    }

    func authorize() async -> Bool {
        await LiveSpeechSession.authorizeSpeechAndMicrophone()
    }

    func begin(onResult: @escaping @MainActor (String?, Bool) -> Void) async throws {
        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [.volatileResults],
                                            attributeOptions: [])
        do {
            // First use per language downloads the model; later runs return nil here.
            if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await install.downloadAndInstall()
            }
        } catch {
            throw Dictation.Failure.unavailable
        }
        guard !cancelled else { throw Dictation.Failure.unavailable }

        do {
            ownsAudio = true
            try RecordingAudioSession.activate()
        } catch {
            tearDown()
            throw Dictation.Failure.unavailable
        }
        // No input (e.g. during a call): installing a tap would raise an exception.
        let micFormat = engine.inputNode.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0, micFormat.channelCount > 0,
              let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber],
                                                                                  considering: micFormat),
              !cancelled
        else {
            tearDown()
            throw Dictation.Failure.unavailable
        }
        let converter: AVAudioConverter?
        if micFormat == analyzerFormat {
            converter = nil
        } else {
            guard let made = AVAudioConverter(from: micFormat, to: analyzerFormat) else {
                tearDown()
                throw Dictation.Failure.unavailable
            }
            made.primeMethod = .none
            converter = made
        }

        let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.input = input
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        resultsTask = Task { [weak self] in
            var transcript = TranscriptAccumulator()
            do {
                for try await result in transcriber.results {
                    if Task.isCancelled { return }
                    transcript.receive(String(result.text.characters), isFinal: result.isFinal)
                    onResult(transcript.text, false)
                }
            } catch {}
            // Cancelled (including a failed start that fell back to the old engine): report nothing.
            guard !Task.isCancelled, let self else { return }
            if self.started {
                onResult(nil, true)
            } else {
                // Reported by `begin` as a failed start, so the caller can fall back.
                self.resultsEndedEarly = true
            }
        }

        Self.installTap(on: engine.inputNode, format: micFormat, converter: converter,
                        to: analyzerFormat, feeding: input)
        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
            try await analyzer.start(inputSequence: stream)
        } catch {
            cancel()
            throw Dictation.Failure.unavailable
        }
        guard !cancelled, !resultsEndedEarly else {
            cancel()
            throw Dictation.Failure.unavailable
        }
        started = true
    }

    /// Microphone off; the analyzer finishes what it heard and the results end.
    func finish() {
        tearDown()
        guard let analyzer else { return }
        Task { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
    }

    func cancel() {
        cancelled = true
        resultsTask?.cancel()
        resultsTask = nil
        tearDown()
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil
    }

    /// Microphone off, tap removed, input ended, audio session back to the default. Safe to repeat.
    private func tearDown() {
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        input?.finish()
        input = nil
        // Only its own: a late cancel must not cut off a newer run's microphone.
        if ownsAudio {
            ownsAudio = false
            RecordingAudioSession.deactivate()
        }
    }

    // The tap runs on the audio thread; build it outside the main actor.

    private nonisolated static func installTap(on node: AVAudioInputNode, format: AVAudioFormat,
                                               converter: AVAudioConverter?, to target: AVAudioFormat,
                                               feeding input: AsyncStream<AnalyzerInput>.Continuation) {
        node.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            guard let converter else {
                input.yield(AnalyzerInput(buffer: buffer))
                return
            }
            let ratio = target.sampleRate / format.sampleRate
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var consumed = false
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                if consumed {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                inputStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, out.frameLength > 0 else { return }
            input.yield(AnalyzerInput(buffer: out))
        }
    }
}
#endif
