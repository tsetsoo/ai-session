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

    private var needsApproval: Bool { status == .waiting }
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
        .task(id: pollID) {
            guard shouldPoll else { return }
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: pollInterval) } catch { return }
            }
        }
    }

    private var chat: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if isLoading && messages.isEmpty {
                            ProgressView("Loading conversation…").frame(maxWidth: .infinity)
                        } else if messages.isEmpty && pending.isEmpty && loadError == nil {
                            Text("Send a message to start the conversation.")
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 30)
                        }
                        let items = self.items
                        let liveActivity = isBusy ? Self.activityID(items.last) : nil
                        ForEach(items) { item in row(item, isLive: item.id == liveActivity) }
                        if isBusy { ChatWorkingLine() }
                        Color.clear.frame(height: 1).id(ChatFollowBottom.endID)
                            .onAppear { if !ChatFollowBottom.usesGeometry { follow.jumpToLatest() } }
                            .onDisappear { if !ChatFollowBottom.usesGeometry { follow.userScrolled(distanceFromBottom: .infinity) } }
                    }
                    .padding()
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .modifier(ChatFollowBottom(follow: $follow, proxy: proxy, contentVersion: contentVersion))
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

    private func send() {
        let text = draft
        let local = PendingSend(text: text, afterCount: messages.count)
        isSending = true
        sendError = nil
        pending.append(local)
        follow.jumpToLatest()
        sendTask = Task { @MainActor in
            defer { isSending = false }
            if await terminal.sendMessage(text) {
                if draft == text { draft = "" }
                await refresh()
            } else {
                pending.removeAll { $0.id == local.id }
                sendError = "The session isn’t ready for a message. Open Terminal to check it. Your draft is saved here."
            }
        }
    }
}
#endif
