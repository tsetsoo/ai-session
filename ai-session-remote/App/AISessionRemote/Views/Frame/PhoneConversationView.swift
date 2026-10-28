#if os(iOS)
import AISessionCore
import SwiftUI
import UIKit

/// The terminal stays mounted and connected while the transcript is read. Switching modes
/// neither reattaches tmux nor loses a draft, scroll position, or the terminal's paste mode.
struct PhoneConversationView<TerminalContent: View>: View {
    let conversation: Conversation
    let config: HostConnectionConfig
    let store: TodoHubStore
    let terminal: TerminalHandle
    let isFrontmost: Bool
    let needsApproval: Bool
    @Binding var showsChat: Bool
    @ViewBuilder let terminalContent: () -> TerminalContent

    @Environment(\.scenePhase) private var scenePhase
    @State private var messages: [ConversationMessage] = []
    @State private var draft = ""
    @State private var loadError: String?
    @State private var sendError: String?
    @State private var isLoading = true
    @State private var isSending = false
    @State private var sendTask: Task<Void, Never>?
    @State private var followsLatest = true
    @State private var copiedID: String?
    @State private var reviewedOnOpen = false
    @State private var composing = false
    @State private var draftEditor = ChatDraftEditorHandle()

    private var shouldPoll: Bool { showsChat && isFrontmost && scenePhase == .active }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Conversation view", selection: $showsChat) {
                Text("Chat").tag(true)
                Text("Terminal").tag(false)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            ZStack {
                terminalContent()
                    .opacity(showsChat ? 0 : 1)
                    .allowsHitTesting(!showsChat)
                    .accessibilityHidden(showsChat)
                if showsChat { chat }
            }
        }
        .onChange(of: showsChat, initial: true) { _, chat in
            if chat { terminal.resignFocus() }
            if !chat { reviewedOnOpen = false }
            composing = false
        }
        .onChange(of: isFrontmost) { _, front in
            if !front { reviewedOnOpen = false; sendTask?.cancel(); composing = false }
        }
        .onDisappear { sendTask?.cancel() }
        .task(id: shouldPoll) {
            guard shouldPoll else { return }
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }

    private var chat: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if isLoading && messages.isEmpty {
                            ProgressView("Loading conversation…").frame(maxWidth: .infinity)
                        } else if messages.isEmpty && loadError == nil {
                            Text("Send a message to start the conversation.")
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 30)
                        }
                        ForEach(messages) { message in bubble(message) }
                        Color.clear.frame(height: 1).id("latest")
                            .onAppear { followsLatest = true }
                            .onDisappear { followsLatest = false }
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: messages) { old, _ in
                    if old.isEmpty || followsLatest { proxy.scrollTo("latest", anchor: .bottom) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !followsLatest && !messages.isEmpty {
                        Button {
                            withAnimation { proxy.scrollTo("latest", anchor: .bottom) }
                        } label: {
                            Label("Latest", systemImage: "arrow.down")
                        }
                        .buttonStyle(.borderedProminent)
                        .padding()
                    }
                }
            }
            if let loadError {
                Text(loadError).font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
            }
            if needsApproval {
                Button("Needs your input — open Terminal") { showsChat = false }
                    .font(.callout.weight(.medium))
                    .padding(12)
            }
            if let sendError {
                Text(sendError).font(.footnote).foregroundStyle(.red).padding(.horizontal)
            }
            composer
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func bubble(_ message: ConversationMessage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(message.role == .user ? "You" : RowText.toolName(conversation.tool))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    PlatformSupport.pasteboardString = message.text
                    copiedID = message.id
                } label: {
                    Label(copiedID == message.id ? "Copied" : "Copy",
                          systemImage: copiedID == message.id ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .accessibilityLabel("Copy \(message.role == .user ? "your" : "assistant") message")
            }
            ChatMessageText(text: message.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(message.role == .user ? Color.accentColor.opacity(0.10) : Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 18))
        .padding(.leading, message.role == .user ? 24 : 0)
        .padding(.trailing, message.role == .assistant ? 12 : 0)
    }

    private var composer: some View {
        VStack(spacing: 8) {
            ChatDraftEditor(text: $draft, focused: $composing, handle: draftEditor)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("Message…").foregroundStyle(.tertiary).padding(12).allowsHitTesting(false)
                    }
                }
            HStack {
                PasteButton(payloadType: String.self) { strings in
                    draftEditor.insert(strings.joined(separator: "\n"))
                    composing = true
                }
                .labelStyle(.titleAndIcon)
                Spacer()
                Button(action: send) {
                    Label(isSending ? "Sending…" : "Send", systemImage: "arrow.up.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSending || !terminal.isConnected || needsApproval || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .background(.bar)
    }

    private func refresh() async {
        do {
            let result = try await store.conversationMessages(of: conversation, config: config)
            guard !Task.isCancelled else { return }
            if messages != result { messages = result }
            loadError = nil
            if !reviewedOnOpen, !result.isEmpty {
                reviewedOnOpen = true
                await store.review(conversation)
            }
        } catch {
            guard !Task.isCancelled else { return }
            if error is RemoteConversations.NoTranscript {
                loadError = messages.isEmpty ? "The transcript will appear after the first message." : nil
            } else {
                loadError = "Couldn’t load chat. Try Terminal, or update the todo helpers on \(conversation.computer.name)."
            }
        }
        isLoading = false
    }

    private func send() {
        let text = draft
        isSending = true
        sendError = nil
        sendTask = Task { @MainActor in
            defer { isSending = false }
            if await terminal.sendMessage(text) {
                if draft == text { draft = "" }
                followsLatest = true
                await refresh()
            } else {
                sendError = "The session isn’t ready for a message. Open Terminal to check it. Your draft is saved here."
            }
        }
    }
}
#endif
