import AISessionCore
import SwiftUI

/// One message, laid out like the Claude app: the user's in an accent bubble on the right, the
/// assistant's full width with rendered markdown. Long-press for Copy, Copy as plain text,
/// Select text, Read Aloud and Share. Long replies fold behind "Show more". A speaker button
/// under each reply reads it aloud in one tap.
struct ChatMessageView: View {
    let message: ConversationMessage
    let toolName: String
    /// Drawn faded: sent from the phone, not in the transcript yet.
    var isPending = false
    @State private var expanded = false
    @State private var selecting = false

    private var isUser: Bool { message.role == .user }
    #if os(iOS)
    private var isReading: Bool { ReadAloud.shared.speakingID == message.id }
    private var canRead: Bool { !ReadAloud.shared.isDictating }
    #endif
    private var isLong: Bool { ChatMarkdown.isLong(message.text) }
    private var shownText: String { isLong && !expanded ? ChatMarkdown.preview(message.text) : message.text }

    var body: some View {
        Group {
            if isUser { userBubble } else { assistantReply }
        }
        .contextMenu {
            Button { PlatformSupport.pasteboardString = message.text } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            Button { PlatformSupport.pasteboardString = ChatMarkdown.plainText(message.text) } label: {
                Label("Copy as Plain Text", systemImage: "text.alignleft")
            }
            #if os(iOS)
            Button { selecting = true } label: {
                Label("Select Text", systemImage: "selection.pin.in.out")
            }
            if isReading {
                Button { ReadAloud.shared.stop() } label: {
                    Label("Stop Reading", systemImage: "stop.circle")
                }
            } else if !ReadAloud.shared.isDictating {
                Button { ReadAloud.shared.read(id: message.id, markdown: message.text) } label: {
                    Label("Read Aloud", systemImage: "speaker.wave.2")
                }
            }
            #endif
            ShareLink(item: message.text) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        #if os(iOS)
        .sheet(isPresented: $selecting) { SelectTextSheet(text: message.text) }
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isUser ? "You" : toolName)
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 60)
            VStack(alignment: .trailing, spacing: 6) {
                Text(shownText)
                    .foregroundStyle(DS.onAccent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(DS.accentSolid, in: RoundedRectangle(cornerRadius: 18))
                if isLong { foldButton }
            }
        }
        .opacity(isPending ? 0.6 : 1)
    }

    private var assistantReply: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(ChatMarkdown.blocks(shownText).enumerated()), id: \.offset) { _, block in
                switch block {
                case let .text(lines):
                    Text(ChatStyledText.make(lines))
                        .lineSpacing(4)
                        #if os(macOS)
                        .textSelection(.enabled)
                        #endif
                        .frame(maxWidth: .infinity, alignment: .leading)
                case let .code(language, code):
                    ChatCodeBlock(language: language, code: code)
                case let .table(rows):
                    ChatTable(rows: rows)
                }
            }
            HStack(spacing: 18) {
                #if os(iOS)
                if canRead { readButton }
                #endif
                if isLong { foldButton }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    #if os(iOS)
    /// Reads the whole reply (not just the folded preview); turns into Stop while it reads.
    private var readButton: some View {
        Button {
            if isReading {
                ReadAloud.shared.stop()
            } else {
                ReadAloud.shared.read(id: message.id, markdown: message.text)
            }
        } label: {
            Image(systemName: isReading ? "stop.circle.fill" : "speaker.wave.2")
                .font(.callout)
                .foregroundStyle(isReading ? DS.accentSolid : .secondary)
                .frame(minWidth: 32, minHeight: 32, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isReading ? "Stop Reading" : "Read Aloud")
    }
    #endif

    private var foldButton: some View {
        Button(expanded ? "Show less" : "Show more") {
            withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
        }
        .font(.callout.weight(.medium))
    }
}
