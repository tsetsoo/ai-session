#if os(iOS)
import AVFoundation
import SwiftUI

/// Settings → Read Aloud: the speed, the voice used for the phone's language, and how to get a
/// better one when only the basic voice is installed.
struct ReadAloudSettingsView: View {
    @AppStorage(ReadAloudSettings.rateKey) private var rate = ReadAloudSettings.normalRate
    @State private var voice: VoiceCandidate?

    private static let sample = "Here's how replies will sound. The fix is in `ReadAloud.swift`, and the tests pass."

    var body: some View {
        Form {
            Section {
                Picker("Speed", selection: $rate) {
                    ForEach(ReadAloudSettings.rates, id: \.value) { option in
                        Text(option.name).tag(option.value)
                    }
                }
                LabeledContent("Voice", value: voiceLabel)
                Button(isPreviewing ? "Stop" : "Preview") {
                    if isPreviewing {
                        ReadAloud.shared.stop()
                    } else {
                        ReadAloud.shared.read(id: Self.previewID, markdown: Self.sample)
                    }
                }
            } footer: {
                if voice.map({ $0.quality < .premium }) ?? true {
                    Text("For a more natural voice, download a Premium or Enhanced one in iOS Settings → Accessibility → Spoken Content → Voices. Read Aloud picks the best one installed.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Read Aloud")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { voice = Self.currentVoice() }
        .onDisappear { if isPreviewing { ReadAloud.shared.stop() } }
    }

    private static let previewID = "settings.preview"
    private var isPreviewing: Bool { ReadAloud.shared.speakingID == Self.previewID }

    private var voiceLabel: String {
        guard let voice else { return "System" }
        switch voice.quality {
        case .premium: return "\(voice.name) (Premium)"
        case .enhanced: return "\(voice.name) (Enhanced)"
        case .basic: return "\(voice.name) (Basic)"
        }
    }

    private static func currentVoice() -> VoiceCandidate? {
        let candidates = AVSpeechSynthesisVoice.speechVoices().map(VoiceCandidate.init)
        return VoiceCandidate.best(for: AVSpeechSynthesisVoice.currentLanguageCode(), among: candidates, locale: .current)
    }
}
#endif
