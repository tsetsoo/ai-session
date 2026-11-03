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
    /// A photo pasted into the field; nil where photos can't be sent.
    var onPastePhoto: ((PastedPhoto) -> Void)?
    let onSend: () -> Void
    let onQuickReply: (String) -> Void
    /// "Uploading photo…" or why the last one failed.
    var photoStatus: String?

    @State private var dictation = Dictation()
    @State private var typedBeforeDictation = ""
    @State private var dictationError: String?

    static let quickReplies = ["continue", "yes", "run the tests", "/compact"]

    static func canSend(mode: ChatComposerMode, draft: String, connected: Bool, promptShowing: Bool) -> Bool {
        guard connected, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if case .answering = mode { return true }
        return !promptShowing
    }

    private var sendEnabled: Bool {
        !isSending && Self.canSend(mode: mode, draft: draft, connected: connected, promptShowing: promptShowing)
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
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.secondary.opacity(0.25)))
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
        .onChange(of: dictation.transcript) { _, transcript in
            draft = QuickAdd.text(typed: typedBeforeDictation, dictated: transcript)
        }
        .onDisappear { dictation.cancel() }
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
        .disabled(isSending || !connected || promptShowing)
        .opacity(isSending || !connected || promptShowing ? 0.4 : 1)
    }

    private func toggleDictation() {
        if dictation.isRunning {
            dictation.stop()
            return
        }
        dictationError = nil
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
