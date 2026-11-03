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
    let status: ConversationStatus?
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
    @State private var follow = ChatFollow()
    @State private var pending: [PendingSend] = []
    @State private var notes: [AnsweredNote] = []
    @State private var reviewedOnOpen = false
    @State private var composing = false
    @State private var draftEditor = ChatDraftEditorHandle()
    @State private var composerMode = ChatComposerMode.normal
    /// The last option tapped found a different question on screen.
    @State private var promptChanged = false
    /// How many of the newest items the chat draws; "Show earlier messages" raises it.
    @State private var windowLimit = ChatTimeline.windowSize
    /// "Uploading photo…" while a pasted photo goes to the computer, or why it didn't.
    @State private var photoStatus: String?
    @State private var photoTask: Task<Void, Never>?

    private var needsApproval: Bool { status == .waiting }
    /// The question on screen, read from the live terminal behind the chat.
    private var prompt: TerminalPrompt? { showsChat ? terminal.prompt : nil }
    /// Waiting on something the app can't read: show the bottom of the terminal instead.
    private var showsFallback: Bool { showsChat && prompt == nil && needsApproval }
    private var isBusy: Bool { status == .busy }
    private var shouldPoll: Bool { showsChat && isFrontmost && scenePhase == .active }
    private var pollID: String? {
        guard shouldPoll else { return nil }
        return "\(conversation.id):\(conversation.sessionId):\(conversation.statusRevision):\(status?.rawValue ?? "")"
    }
    /// Faster while the agent works or waits, so steps and answers show up promptly.
    private var pollInterval: Duration { isBusy || needsApproval ? .seconds(1) : .seconds(3) }
    private var items: [ChatItem] { ChatTimeline.items(entries: messages, pending: pending, notes: notes) }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Conversation view", selection: $showsChat) {
                Text("Chat").tag(true)
                Text("Terminal").tag(false)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            // The terminal gets exactly the space there is. Its own minimum height would otherwise
            // size the stack, and with the keyboard up the chat's messages got no room at all.
            GeometryReader { proxy in
                ZStack {
                    terminalContent()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .opacity(showsChat ? 0 : 1)
                        .allowsHitTesting(!showsChat)
                        .accessibilityHidden(showsChat)
                    if showsChat { chat(promptMaxHeight: proxy.size.height * 0.6) }
                }
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
        .onDisappear { sendTask?.cancel(); photoTask?.cancel() }
        #if DEBUG
        .task {
            // Screenshots: `-uiDemoCompose` focuses the message field, so the keyboard layout shows.
            guard DemoFixtures.isEnabled, ProcessInfo.processInfo.arguments.contains("-uiDemoCompose") else { return }
            try? await Task.sleep(for: .seconds(3))
            composing = true
        }
        #endif
        .task(id: pollID) {
            guard shouldPoll else { return }
            var full = true
            while !Task.isCancelled {
                // A full read whenever polling (re)starts; later polls fetch only what is new.
                await refresh(full: full)
                full = false
                do { try await Task.sleep(for: pollInterval) } catch { return }
            }
        }
    }

    private func chat(promptMaxHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    // Not lazy: a lazy stack guesses unseen rows' heights, and when the keyboard
                    // shrinks the view it can scroll past the real rows and show nothing.
                    // Drawing only the newest items keeps a long chat cheap instead.
                    VStack(alignment: .leading, spacing: 16) {
                        if isLoading && messages.isEmpty {
                            ProgressView("Loading conversation…").frame(maxWidth: .infinity)
                        } else if messages.isEmpty && pending.isEmpty && loadError == nil {
                            Text("Send a message to start the conversation.")
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 30)
                        }
                        let window = ChatTimeline.window(self.items, limit: windowLimit)
                        if window.hidden > 0 {
                            Button("Show earlier messages") { windowLimit += ChatTimeline.windowSize }
                                .font(.footnote.weight(.medium))
                                .frame(maxWidth: .infinity)
                        }
                        let liveActivity = isBusy ? Self.activityID(window.items.last) : nil
                        ForEach(window.items) { item in row(item, isLive: item.id == liveActivity) }
                        if isBusy { ChatWorkingLine() }
                        Color.clear.frame(height: 1).id(ChatFollowBottom.endID)
                            .onAppear { if !ChatFollowBottom.usesGeometry { follow.jumpToLatest() } }
                            .onDisappear { if !ChatFollowBottom.usesGeometry { follow.userScrolled(distanceFromBottom: .infinity) } }
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .modifier(ChatFollowBottom(follow: $follow, proxy: proxy, contentVersion: contentVersion))
            }
            if let loadError {
                Text(loadError).font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
            }
            if let prompt, composing {
                // While typing, the card would leave no room for the messages.
                ChatPromptBanner(question: prompt.question) { composing = false }
            } else if let prompt {
                ChatPromptCard(prompt: prompt, changed: promptChanged, onChoose: { choose($0, in: prompt) })
            } else if showsFallback, composing {
                ChatPromptBanner(question: "Needs your input") { composing = false }
            } else if showsFallback {
                ChatScreenFallbackCard(
                    lines: terminal.screenTail,
                    maxContentHeight: max(44, promptMaxHeight - 100),
                    onKey: { terminal.send($0.bytes(tool: conversation.tool)) },
                    onOpenTerminal: { showsChat = false }
                )
            }
            if let sendError {
                Text(sendError).font(.footnote).foregroundStyle(.red).padding(.horizontal)
            }
            ChatComposer(
                draft: $draft, focused: $composing, mode: $composerMode, editor: draftEditor,
                connected: terminal.isConnected, promptShowing: prompt != nil || showsFallback,
                isSending: isSending, onPastePhoto: pastePhoto,
                onSend: send, onQuickReply: { send($0, clearsDraft: false) }, photoStatus: photoStatus
            )
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .onChange(of: terminal.prompt?.signature) { _, signature in
            if case let .answering(answering, _) = composerMode, answering.signature != signature { composerMode = .normal }
            if signature == nil { promptChanged = false }
        }
    }

    /// An option without words is answered now; one that takes words opens the composer for them.
    private func choose(_ option: Int, in prompt: TerminalPrompt) {
        if prompt.options[option].needsText {
            composerMode = .answering(prompt: prompt, option: option)
            composing = true
            return
        }
        if terminal.answer(prompt, option: option, tool: conversation.tool) {
            answered(prompt, option: option)
        } else {
            promptChanged = true
        }
    }

    private func answered(_ prompt: TerminalPrompt, option: Int) {
        promptChanged = false
        notes.append(AnsweredNote(text: "✓ \(prompt.options[option].label) · \(prompt.question)", afterCount: messages.count))
        follow.jumpToLatest()
    }

    private static func activityID(_ item: ChatItem?) -> String? {
        guard let item, case .activity = item else { return nil }
        return item.id
    }

    /// Changes whenever something is added or a step arrives, for the iOS 17 follow.
    private var contentVersion: Int { messages.count &* 31 &+ pending.count &* 7 &+ notes.count &+ (isBusy ? 1 : 0) }

    @ViewBuilder
    private func row(_ item: ChatItem, isLive: Bool) -> some View {
        let tool = RowText.toolName(conversation.tool)
        switch item {
        case let .time(_, date):
            ChatTimestamp(date: date)
        case let .message(message):
            ChatMessageView(message: message, toolName: tool)
        case let .activity(_, steps, summary):
            ChatActivityRow(steps: steps, summary: summary, isLive: isLive)
        case let .pending(send):
            ChatMessageView(message: ConversationMessage(id: send.id.uuidString, role: .user, text: send.text), toolName: tool, isPending: true)
        case let .note(note):
            Text(note.text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func refresh(full: Bool = false) async {
        do {
            let result = try await store.conversationMessages(of: conversation, config: config, previous: full ? [] : messages)
            guard !Task.isCancelled else { return }
            if messages != result { messages = result }
            let stillPending = ChatTimeline.unconfirmed(pending, in: result)
            if stillPending != pending { pending = stillPending }
            loadError = nil
            if !reviewedOnOpen, !result.isEmpty {
                // A busy result or a failed request is not an acknowledgement. Retry
                // after loading the current result, including after a busy/idle turn.
                let acknowledged = await store.review(conversation)
                guard !Task.isCancelled else { return }
                reviewedOnOpen = acknowledged
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

    /// Copies the photo to the conversation's computer over SSH and puts its path in the draft
    /// at the caret, so the agent reads it when the message is sent.
    private func pastePhoto(_ image: UIImage) {
        guard photoTask == nil else { return }
        guard let data = Self.jpeg(image) else {
            photoStatus = "Couldn’t read that photo."
            return
        }
        photoStatus = "Uploading photo…"
        let name = "\(UUID().uuidString.lowercased()).jpg"
        photoTask = Task { @MainActor in
            defer { photoTask = nil }
            do {
                let path = try await PhotoUpload.upload(data, name: name, config: config, ssh: NIOSSHClient())
                photoStatus = nil
                draftEditor.insert(path + " ")
            } catch is CancellationError {
                photoStatus = nil
            } catch {
                photoStatus = "Couldn’t copy the photo to \(conversation.computer.name). Try pasting it again."
            }
        }
    }

    /// The model scales images down to about this long edge anyway, so a bigger one only
    /// costs upload time.
    private static func jpeg(_ image: UIImage, longEdge: CGFloat = 1568) -> Data? {
        let size = image.size
        let scale = min(1, longEdge / max(size.width, size.height, 1))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: 0.85)
    }

    private func send() {
        if case let .answering(prompt, option) = composerMode {
            sendAnswer(draft, to: prompt, option: option)
        } else {
            send(draft, clearsDraft: true)
        }
    }

    private func sendAnswer(_ text: String, to prompt: TerminalPrompt, option: Int) {
        isSending = true
        sendError = nil
        sendTask = Task { @MainActor in
            defer { isSending = false }
            if await terminal.answer(prompt, option: option, text: text, tool: conversation.tool) {
                if draft == text { draft = "" }
                composerMode = .normal
                answered(prompt, option: option)
            } else {
                promptChanged = true
                composerMode = .normal
                sendError = "That question changed before your answer was sent. Your answer is saved here."
            }
        }
    }

    private func send(_ text: String, clearsDraft: Bool) {
        let local = PendingSend(text: text, afterCount: messages.count)
        isSending = true
        sendError = nil
        pending.append(local)
        follow.jumpToLatest()
        sendTask = Task { @MainActor in
            defer { isSending = false }
            if await terminal.sendMessage(text) {
                if clearsDraft, draft == text { draft = "" }
                await refresh()
            } else {
                pending.removeAll { $0.id == local.id }
                sendError = terminal.prompt != nil
                    ? "\(RowText.toolName(conversation.tool)) is asking something first. Answer it above; your draft is saved here."
                    : "The session isn’t ready for a message. Open Terminal to check it. Your draft is saved here."
            }
        }
    }
}
#endif
