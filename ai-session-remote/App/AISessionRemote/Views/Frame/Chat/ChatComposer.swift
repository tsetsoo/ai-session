#if os(iOS)
import AISessionCore
import SwiftUI

enum ChatComposerMode: Equatable {
    case normal
    /// Typing the words for a prompt option that asks for them ("Type something").
    case answering(prompt: TerminalPrompt, option: Int)
}

/// The message field: grows with the text, send arrow inside, dictation beside it, and quick
/// replies above. While a question is on screen only its typed answer can be sent, so text
/// never lands in the agent's menu.
struct ChatComposer: View {
    @Binding var draft: String
    @Binding var focused: Bool
    @Binding var mode: ChatComposerMode
    let editor: ChatDraftEditorHandle
    let connected: Bool
    let promptShowing: Bool
    let isSending: Bool
    let attachmentsUploading: Bool
    /// A photo pasted into the field; nil where photos can't be sent.
    var onPastePhoto: ((PastedPhoto) -> Void)?
    let onSend: () -> Void
    let onQuickReply: (String) -> Void
    /// "Uploading photo…" or why the last one failed.
    var photoStatus: String?
    let voiceAvailable: Bool
    let voiceReady: Bool
    let latestReply: ConversationMessage?

    @State private var voiceEnabled = false
    @State private var voiceCapture = Dictation()
    @State private var voiceLease: UUID?
    @State private var lastSpokenReply: String?
    @State private var voicePreview = ""

    @State private var dictation = Dictation()
    @State private var typedBeforeDictation = ""
    @State private var dictationError: String?

    enum VoiceCommand: Equatable {
        case send(String?), discard, stop, dictate(String)

        init(_ phrase: String) {
            let text = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            let command = text.trimmingCharacters(in: CharacterSet(charactersIn: ".!?")).lowercased()
            switch command {
            case "send message", "send to agent", "voice send now": self = .send(nil)
            case "discard message": self = .discard
            case "stop voice mode": self = .stop
            default:
                if let cue = text.range(of: #"(?i)(?<=\s)voice send now[.!?]*$"#, options: .regularExpression) {
                    var message = text[..<cue.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                    if message.last == "," {
                        message.removeLast()
                        message = message.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    self = message.isEmpty ? .dictate(phrase) : .send(message)
                } else {
                    self = .dictate(phrase)
                }
            }
        }
    }

    static let quickReplies = ["continue", "yes", "run the tests", "/compact"]

    static func canSend(mode: ChatComposerMode, draft: String, connected: Bool, promptShowing: Bool) -> Bool {
        guard connected, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if case .answering = mode { return true }
        return !promptShowing
    }

    private var sendEnabled: Bool {
        !isSending && !attachmentsUploading && Self.canSend(mode: mode, draft: draft, connected: connected, promptShowing: promptShowing)
    }

    var body: some View {
        VStack(spacing: 8) {
            if case let .answering(prompt, option) = mode {
                HStack {
                    Text("Answering: \(prompt.options[option].label)")
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                    Spacer()
                    Button("Cancel") { mode = .normal }
                        .font(.footnote)
                }
            } else {
                quickReplies
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button(action: toggleDictation) {
                    Image(systemName: dictation.isRunning ? "stop.circle.fill" : "mic")
                        .font(.system(size: 20))
                        .frame(width: 32, height: 36)
                }
                .foregroundStyle(dictation.isRunning ? DS.accentSolid : .secondary)
                .accessibilityLabel(dictation.isRunning ? "Stop Dictation" : "Dictate")
                .disabled(voiceEnabled)

                Button(action: toggleVoice) {
                    Image(systemName: voiceEnabled ? "waveform.circle.fill" : "waveform.circle")
                        .font(.system(size: 22))
                        .frame(width: 32, height: 36)
                }
                .foregroundStyle(voiceEnabled ? DS.accentSolid : .secondary)
                .disabled(!voiceEnabled && (!voiceAvailable || !connected || dictation.isRunning))
                .accessibilityLabel(voiceEnabled ? "Stop Voice Mode" : "Start Voice Mode")

                ChatDraftEditor(text: $draft, focused: $focused, handle: editor, onPastePhoto: onPastePhoto)
                    .overlay(alignment: .topLeading) {
                        if draft.isEmpty {
                            Text(placeholder).foregroundStyle(.tertiary)
                                .padding(.horizontal, 12).padding(.vertical, 9)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(.trailing, 34)
                    .overlay(alignment: .bottomTrailing) {
                        Button(action: onSend) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 28))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(DS.onAccent, sendEnabled ? DS.accentSolid : Color.secondary.opacity(0.4))
                        }
                        .disabled(!sendEnabled)
                        .accessibilityLabel(isSending ? "Sending" : "Send")
                        .padding(4)
                    }
                    .background((DS.surface ?? Color(uiColor: .secondarySystemGroupedBackground)), in: RoundedRectangle(cornerRadius: DS.radius(20)))
                    .overlay(RoundedRectangle(cornerRadius: DS.radius(20)).stroke(Color.secondary.opacity(0.25)))
            }
            if voiceEnabled {
                Text(voicePreview.isEmpty ? voiceStatus : voicePreview)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let photoStatus {
                Text(photoStatus).font(.footnote).foregroundStyle(.secondary)
            }
            if let dictationError {
                Text(dictationError).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.bar)
        .onChange(of: dictation.isRunning) { _, running in ReadAloud.shared.isDictating = running }
        .onDisappear { ReadAloud.shared.isDictating = false }
        .onChange(of: dictation.transcript) { _, transcript in
            draft = QuickAdd.text(typed: typedBeforeDictation, dictated: transcript)
        }
        .onDisappear {
            dictation.cancel()
            stopVoice()
        }
        .onChange(of: voiceAvailable) { _, available in if !available { stopVoice() } }
        .onChange(of: connected) { _, connected in if !connected { stopVoice() } }
        .onChange(of: readyReply) { _, reply in
            guard voiceEnabled, let reply, reply.id != lastSpokenReply else { return }
            lastSpokenReply = reply.id
            voiceLease = nil
            voiceCapture.cancel()
            voicePreview = ""
            ReadAloud.shared.read(id: reply.id, markdown: reply.text)
        }
        .task(id: canListen) {
            if canListen { await listenForVoice() }
        }
    }

    private var placeholder: String {
        if case .answering = mode { return "Your answer…" }
        return "Message"
    }

    private var quickReplies: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Self.quickReplies, id: \.self) { reply in
                    Button(reply) { onQuickReply(reply) }
                        .font(.footnote)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(DS.chipFill, in: Capsule())
                }
            }
        }
        .disabled(isSending || attachmentsUploading || !connected || promptShowing)
        .opacity(isSending || attachmentsUploading || !connected || promptShowing ? 0.4 : 1)
    }

    private var readyReply: ConversationMessage? { voiceReady ? latestReply : nil }

    private var canListen: Bool {
        voiceEnabled && voiceAvailable && voiceReady && connected && !promptShowing
            && !isSending && !attachmentsUploading && !ReadAloud.shared.isSpeaking
    }

    private var voiceStatus: String {
        if promptShowing { return "Answer the prompt to resume Voice Mode." }
        if ReadAloud.shared.isSpeaking { return "Reading reply…" }
        if attachmentsUploading { return "Uploading attachments…" }
        if !voiceReady || isSending { return "Waiting for the agent…" }
        return "End your message with “Voice send now.”"
    }

    private func toggleVoice() {
        if voiceEnabled {
            stopVoice()
        } else {
            dictation.cancel()
            ReadAloud.shared.stop()
            ReadAloud.shared.isDictating = false
            lastSpokenReply = latestReply?.id
            dictationError = nil
            voiceEnabled = true
        }
    }

    private func stopVoice() {
        let wasEnabled = voiceEnabled
        voiceEnabled = false
        voiceLease = nil
        voiceCapture.cancel()
        voicePreview = ""
        if wasEnabled { ReadAloud.shared.stop() }
    }

    @MainActor
    private func listenForVoice() async {
        let lease = UUID()
        voiceLease = lease
        let capture = voiceCapture
        capture.cancel()
        defer {
            if voiceLease == lease {
                capture.cancel()
                voicePreview = ""
                voiceLease = nil
            }
        }
        while !Task.isCancelled && voiceLease == lease {
            do {
                try await capture.start()
                let clock = ContinuousClock()
                var changedAt = clock.now
                var previous = ""
                repeat {
                    try await Task.sleep(for: .milliseconds(150))
                    guard voiceLease == lease else { return }
                    if capture.transcript != previous {
                        previous = capture.transcript
                        voicePreview = previous
                        changedAt = clock.now
                    }
                } while capture.isRunning && (previous.isEmpty || clock.now - changedAt < .milliseconds(1400))
                if capture.isRunning {
                    capture.stop()
                    let deadline = clock.now + .seconds(3)
                    while !capture.didFinish && clock.now < deadline && voiceLease == lease {
                        try await Task.sleep(for: .milliseconds(100))
                    }
                }
                guard !Task.isCancelled, voiceLease == lease else { return }
                let final = capture.finalTranscript
                capture.cancel()
                voicePreview = ""
                if let final, !final.isEmpty {
                    handleVoice(final)
                    // Let the send and reply state update before opening the microphone again.
                    try await Task.sleep(for: .milliseconds(350))
                } else {
                    switch VoiceCommand(previous) {
                    case let .dictate(text), let .send(.some(text)):
                        draft = QuickAdd.text(typed: draft, dictated: text)
                    default: break
                    }
                    try await Task.sleep(for: .seconds(1))
                }
            } catch is CancellationError {
                return
            } catch {
                dictationError = error.localizedDescription
                stopVoice()
                return
            }
        }
    }

    private func handleVoice(_ phrase: String) {
        switch VoiceCommand(phrase) {
        case .stop:
            stopVoice()
        case .discard:
            draft = ""
        case let .send(message):
            if let message { draft = QuickAdd.text(typed: draft, dictated: message) }
            if Self.canSend(mode: mode, draft: draft, connected: connected, promptShowing: promptShowing) {
                onSend()
            }
        case let .dictate(text):
            draft = QuickAdd.text(typed: draft, dictated: text)
        }
    }

    private func toggleDictation() {
        if dictation.isRunning {
            dictation.stop()
            return
        }
        dictationError = nil
        ReadAloud.shared.stop()
        typedBeforeDictation = draft
        Task {
            do {
                try await dictation.start()
            } catch {
                dictationError = (error as? Dictation.Failure)?.errorDescription ?? Dictation.Failure.unavailable.errorDescription
            }
        }
    }
}
#endif
