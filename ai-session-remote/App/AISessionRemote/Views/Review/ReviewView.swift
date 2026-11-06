#if os(macOS)
import AISessionCore
import AppKit
import SwiftData
import SwiftUI

/// Which conversation a review window is for.
struct ReviewTarget: Codable, Hashable {
    var todoID: String
    /// `Conversation.listKey`.
    var conversationKey: String
}

/// ⋯ ▸ Review Changes…: the conversation's worktree changes in a window of their own.
struct ReviewWindow: View {
    static let id = "review"
    /// The conversation each window was opened for, until the hub lists it (one just started
    /// is known to its frame before the store has it).
    @MainActor static var opened: [String: Conversation] = [:]

    let target: ReviewTarget?

    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let target, let conversation = model.store.conversations(forTodo: target.todoID)
                .first(where: { $0.listKey == target.conversationKey }) ?? Self.opened[target.conversationKey] {
                let title = model.store.todos.first { $0.id == target.todoID }?.title ?? "Conversation"
                ReviewView(conversation: conversation)
                    .navigationTitle("Review · \(title)")
            } else if model.isConfigured, !model.store.hasLoadedOnce {
                FrameLoadingView(title: "Loading conversation…")
            } else {
                ContentUnavailableView("Conversation Not Found", systemImage: "bubble.left.and.bubble.right")
            }
        }
        .tint(DS.accent)
        .task { await model.startSync() }
    }
}

extension AppModel {
    func openReview(todoID: String, conversation: Conversation?, openWindow: OpenWindowAction) {
        guard let conversation else { return }
        ReviewWindow.opened[conversation.listKey] = conversation
        openWindow(id: ReviewWindow.id, value: ReviewTarget(todoID: todoID, conversationKey: conversation.listKey))
    }
}

/// Lines picked in the diff for a new comment.
struct LineSelection: Equatable {
    var path: String
    var side: DiffSide
    var lines: ClosedRange<Int>
}

struct ReviewView: View {
    let conversation: Conversation

    @Query private var hosts: [HostEntity]
    @State private var session: ReviewSession
    @State private var selectedPath: String?
    @State private var showingSend = false

    init(conversation: Conversation) {
        self.conversation = conversation
        _session = State(initialValue: ReviewSession(conversation: conversation))
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
        } detail: {
            detail
        }
        .toolbar { toolbar }
        // Another commit in Compare With is a new load too, though the scope stays `.commit`.
        .task(id: "\(session.scope.rawValue)|\(session.baseCommit?.sha ?? "")") { await reload() }
        .onChange(of: conversation) { _, updated in session.refresh(updated) }
        .sheet(isPresented: $showingSend) {
            // A failed send is shown in the sheet: macOS doesn't present the window's alert over it.
            SendPreview(message: session.message(), count: session.drafts.count, isSending: session.isSending,
                        error: session.failure?.errorDescription) {
                Task {
                    session.failure = nil
                    var sent = false
                    await withConfig { sent = await session.send(config: $0) }
                    if sent { showingSend = false }
                }
            } onCancel: {
                session.failure = nil
                showingSend = false
            }
        }
        .alert("Review", isPresented: Binding(get: { session.failure != nil && !showingSend },
                                              set: { if !$0 { session.failure = nil } })) {
            Button("OK", role: .cancel) { session.failure = nil }
        } message: {
            Text(session.failure?.errorDescription ?? "")
        }
    }

    private func reload() async {
        await withConfig { await session.load(config: $0) }
        if selectedPath == nil || !session.diff.files.contains(where: { $0.path == selectedPath }) {
            selectedPath = session.diff.files.first?.path
        }
    }

    private func withConfig(_ body: (HostConnectionConfig) async -> Void) async {
        do {
            await body(try HostLookup.config(for: conversation.computer, in: hosts))
        } catch {
            session.failure = .init(errorDescription: ConversationRowActions.message(for: error, computer: conversation.computer))
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selectedPath) {
            if let notice = session.notice {
                Section {
                    Label(notice, systemImage: "paperplane")
                        .foregroundStyle(.secondary)
                }
            }
            if session.agentAnswered, session.scope != .since {
                Section {
                    Button {
                        session.scope = .since
                    } label: {
                        Label("The agent answered. Show changes since feedback", systemImage: "arrow.uturn.backward.circle")
                    }
                    .buttonStyle(.link)
                }
            }
            if session.result?.truncated == true {
                Section {
                    Label("This diff is too large to show whole. Files after the last one listed are left out.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(DS.warning)
                }
            }
            Section(filesHeader) {
                ForEach(session.diff.files) { file in
                    FileRow(file: file, comments: session.commentCount(file: file))
                        .tag(file.path)
                }
            }
            let elsewhere = session.commentsOutsideDiff()
            if !elsewhere.isEmpty {
                // In a cut-off diff these files may have changes that just aren't listed.
                Section(session.result?.truncated == true ? "Comments on Files Not Listed" : "Comments on Other Files") {
                    ForEach(elsewhere) { comment in
                        CommentCard(comment: comment, isStale: session.isStale(comment), session: session)
                    }
                }
            }
            if !session.record.batches.isEmpty {
                Section("Sent") {
                    ForEach(session.record.batches.sorted { $0.sentAt > $1.sentAt }) { batch in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(batch.commentIDs.count == 1 ? "1 comment" : "\(batch.commentIDs.count) comments")
                            Text("\(batch.sentAt, style: .relative) ago · \(batch.revision.prefix(8))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .overlay {
            if session.diff.files.isEmpty, !session.isLoading, session.failure == nil, session.result != nil {
                ContentUnavailableView(emptyTitle, systemImage: "checkmark.circle", description: Text(emptyDetail))
            }
        }
    }

    private var filesHeader: String {
        let count = session.diff.files.count
        return count == 1 ? "1 File" : "\(count) Files"
    }

    private var emptyTitle: String {
        switch session.scope {
        case .uncommitted: "Nothing Uncommitted"
        case .conversation: "No Changes Since the Conversation Started"
        case .branch: "No Changes on This Branch"
        case .since: "No Changes Since Feedback"
        case .commit: "No Changes Since That Commit"
        }
    }

    private var emptyDetail: String {
        switch session.scope {
        case .uncommitted: "Choose Conversation to see everything it changed, committed or not."
        case .branch: "This branch has nothing the default branch doesn't. Choose Conversation, or a commit in Compare With."
        default: ""
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let path = selectedPath, let file = session.diff.files.first(where: { $0.path == path }) {
            FileDiffView(file: file, session: session)
                // By file only: a reload with new revisions keeps a half-written comment.
                .id(path)
        } else if session.isLoading {
            ProgressView()
        } else if session.result?.truncated == true {
            ContentUnavailableView("Diff Too Large", systemImage: "doc.text.magnifyingglass")
        } else {
            Color.clear
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("Changes", selection: $session.scope) {
                ForEach(ReviewScope.segments) { scope in
                    Text(scope.title).tag(scope)
                        .disabled((scope == .since && session.record.lastBatch == nil)
                                  || (scope == .uncommitted && session.keptBranch != nil))
                }
            }
            .pickerStyle(.segmented)
            .help("Uncommitted: what isn't committed yet. Conversation: everything since the conversation started, committed or not (in a shared folder, others' commits since then too). Branch: what this branch has that the default branch doesn't. Since Feedback: what changed after the last comments were sent.")
        }
        ToolbarItem(placement: .navigation) {
            Menu {
                if session.commits.isEmpty {
                    Text("No commits yet")
                }
                ForEach(session.commits) { commit in
                    Button {
                        session.compare(from: commit)
                    } label: {
                        Text(commitLabel(commit))
                    }
                }
            } label: {
                Label(session.scope == .commit ? "From \(session.baseCommit.map { String($0.sha.prefix(7)) } ?? "")" : "Compare With",
                      systemImage: "clock.arrow.circlepath")
            }
            .help("Review everything since a commit you pick, up to the worktree now.")
        }
        ToolbarItem(placement: .status) {
            Text(statusLine)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await reload() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(session.isLoading)
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                showingSend = true
            } label: {
                Label(sendTitle, systemImage: "paperplane")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .disabled(session.sendBlocker != nil || session.result == nil)
            .help(session.sendBlocker ?? "Type these comments into the conversation as one message.")
        }
    }

    private var sendTitle: String {
        let count = session.drafts.count
        return count == 0 ? "Send to Agent" : "Send \(count) to Agent"
    }

    /// `a1b2c3d  Subject · 2 h ago · not pushed`
    private func commitLabel(_ commit: ReviewLog.Commit) -> String {
        var parts = ["\(commit.sha.prefix(7))  \(commit.subject.prefix(72))"]
        if let date = HubDates.date(from: commit.date) {
            parts.append(date.formatted(.relative(presentation: .named)))
        }
        if commit.pushed == false { parts.append("not pushed") }
        if commit.sha == session.conversationStart { parts.append("conversation started after this") }
        return parts.joined(separator: " · ")
    }

    private var statusLine: String {
        guard let status = session.status else { return session.isLoading ? "Loading…" : "" }
        var parts = [status.branch ?? "detached HEAD"]
        if session.keptBranch != nil { parts.append("worktree removed, branch kept") }
        if let base = status.base, session.scope == .branch { parts.append("vs \(base.ref)") }
        if let from = session.result?.from, session.scope == .conversation || session.scope == .commit {
            parts.append("from \(from.prefix(7))")
        }
        if let ahead = status.ahead, ahead > 0 { parts.append("\(ahead) unpushed") }
        parts.append(status.clean ? "nothing uncommitted" : "uncommitted changes")
        parts.append(conversation.computer.name)
        return parts.joined(separator: " · ")
    }
}

// MARK: - Rows

private struct FileRow: View {
    let file: DiffFile
    let comments: Int

    var body: some View {
        HStack(spacing: DS.spacing.s) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .help(file.change.rawValue.capitalized)
            VStack(alignment: .leading, spacing: 1) {
                Text((file.path as NSString).lastPathComponent)
                    .lineLimit(1)
                let folder = (file.path as NSString).deletingLastPathComponent
                if !folder.isEmpty {
                    Text(folder)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 0)
            if comments > 0 {
                Label("\(comments)", systemImage: "text.bubble")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !file.isBinary {
                Text("+\(file.additions) −\(file.deletions)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var symbol: String {
        switch file.change {
        case .added: "plus.square"
        case .deleted: "minus.square"
        case .renamed, .copied: "arrow.right.square"
        case .modified: "pencil.and.list.clipboard"
        }
    }

    private var color: Color {
        switch file.change {
        case .added: .green
        case .deleted: DS.error
        default: .secondary
        }
    }
}

/// One file's hunks, with comments under the lines they end on.
private struct FileDiffView: View {
    let file: DiffFile
    let session: ReviewSession

    @State private var selection: LineSelection?
    @State private var draft = ""
    @State private var fileComment = false

    var body: some View {
        ScrollView([.vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                let others = session.otherComments(file: file)
                if !others.isEmpty || fileComment {
                    VStack(alignment: .leading, spacing: DS.spacing.s) {
                        ForEach(others) { comment in
                            CommentCard(comment: comment, isStale: session.isStale(comment), session: session)
                        }
                        if fileComment {
                            CommentComposer(text: $draft, title: "Comment on \(file.path)") {
                                session.addComment(path: file.path, side: .new, lines: nil, quote: [], body: draft)
                                draft = ""
                                fileComment = false
                            } onCancel: {
                                draft = ""
                                fileComment = false
                            }
                        }
                    }
                    .padding(DS.spacing.m)
                }
                if file.isBinary {
                    Text("Binary file")
                        .foregroundStyle(.secondary)
                        .padding(DS.spacing.l)
                }
                ForEach(Array(file.hunks.enumerated()), id: \.offset) { _, hunk in
                    Text("@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@ \(hunk.section)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, DS.spacing.s)
                        .padding(.vertical, DS.spacing.xs)
                        .background(Color.secondary.opacity(0.08))
                    ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                        lineRow(line)
                    }
                }
            }
            .padding(.bottom, DS.spacing.xl)
        }
        .onExitCommand { selection = nil }
    }

    private var header: some View {
        HStack {
            Text(file.change == .renamed ? "\(file.oldPath ?? "") → \(file.path)" : file.path)
                .font(.headline)
                .textSelection(.enabled)
            Spacer()
            Button {
                selection = nil
                fileComment = true
            } label: {
                Label("Comment on File", systemImage: "text.bubble")
            }
            .disabled(file.change == .deleted)
        }
        .padding(DS.spacing.m)
    }

    @ViewBuilder
    private func lineRow(_ line: DiffLine) -> some View {
        let side: DiffSide = line.kind == .removed ? .old : .new
        let number = side == .old ? line.oldLine : line.newLine
        // Removed lines are in the old revision, where a renamed file had its old name.
        let path = side == .old ? file.oldPath ?? file.path : file.path
        let isSelected = number.map { n in selection.map { $0.side == side && $0.lines.contains(n) } ?? false } ?? false
        DiffLineRow(line: line, isSelected: isSelected)
            .contentShape(Rectangle())
            .onTapGesture {
                guard let number, line.kind != .noNewline else { return }
                select(number, side: side)
            }
        if let number {
            ForEach(session.comments(atPath: path, side: side, endLine: number)) { comment in
                CommentCard(comment: comment, isStale: false, session: session)
                    .padding(.horizontal, DS.spacing.m)
                    .padding(.vertical, DS.spacing.xs)
            }
            if let selection, selection.side == side, selection.lines.upperBound == number {
                CommentComposer(text: $draft, title: title(selection)) {
                    session.addComment(path: path, side: side, lines: selection.lines,
                                       quote: quote(selection), body: draft)
                    draft = ""
                    self.selection = nil
                } onCancel: {
                    draft = ""
                    self.selection = nil
                }
                .padding(.horizontal, DS.spacing.m)
                .padding(.vertical, DS.spacing.xs)
            }
        }
    }

    /// Click picks a line; Shift-click extends the selection on the same side.
    private func select(_ number: Int, side: DiffSide) {
        fileComment = false
        if NSEvent.modifierFlags.contains(.shift), let current = selection, current.side == side {
            let low = min(current.lines.lowerBound, number)
            let high = max(current.lines.upperBound, number)
            selection = LineSelection(path: file.path, side: side, lines: low...high)
        } else {
            selection = LineSelection(path: file.path, side: side, lines: number...number)
        }
    }

    private func title(_ selection: LineSelection) -> String {
        let lines = selection.lines.count == 1 ? "line \(selection.lines.lowerBound)"
            : "lines \(selection.lines.lowerBound)–\(selection.lines.upperBound)"
        return selection.side == .old ? "Comment on removed \(lines)" : "Comment on \(lines)"
    }

    private func quote(_ selection: LineSelection) -> [String] {
        file.hunks.flatMap(\.lines).filter { line in
            switch selection.side {
            case .old: line.kind == .removed && line.oldLine.map(selection.lines.contains) == true
            case .new: line.kind != .removed && line.newLine.map(selection.lines.contains) == true
            }
        }.map(\.text)
    }
}

private struct DiffLineRow: View {
    let line: DiffLine
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            number(line.oldLine)
            number(line.newLine)
            Text(marker)
                .frame(width: 16)
                .foregroundStyle(.secondary)
            Text(line.text.isEmpty ? " " : line.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(line.kind == .noNewline ? .secondary : .primary)
        }
        .font(.system(.body, design: .monospaced))
        .padding(.vertical, 1)
        .background(background)
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .frame(width: 48, alignment: .trailing)
            .padding(.trailing, DS.spacing.s)
            .foregroundStyle(.tertiary)
    }

    private var marker: String {
        switch line.kind {
        case .added: "+"
        case .removed: "−"
        case .context, .noNewline: " "
        }
    }

    private var background: Color {
        if isSelected { return DS.accent.opacity(0.25) }
        switch line.kind {
        case .added: return Color.green.opacity(0.12)
        case .removed: return DS.error.opacity(0.12)
        case .context, .noNewline: return .clear
        }
    }
}

private struct CommentCard: View {
    let comment: ReviewComment
    let isStale: Bool
    let session: ReviewSession

    @State private var editing = false
    @State private var text = ""

    var body: some View {
        if editing {
            CommentComposer(text: $text, title: "Edit comment on \(comment.location)") {
                session.editComment(comment.id, body: text)
                editing = false
            } onCancel: { editing = false }
        } else {
            VStack(alignment: .leading, spacing: DS.spacing.xs) {
                HStack(spacing: DS.spacing.s) {
                    Text(comment.location)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    stateLabel
                    if isStale {
                        Text("Lines changed since")
                            .font(.caption)
                            .foregroundStyle(DS.warning)
                    }
                    Spacer()
                    if comment.state == .draft {
                        Button("Edit") {
                            text = comment.body
                            editing = true
                        }
                        .buttonStyle(.link)
                        Button("Delete", role: .destructive) { session.deleteComment(comment.id) }
                            .buttonStyle(.link)
                    } else {
                        Button("Hide") { session.dismissComment(comment.id) }
                            .buttonStyle(.link)
                            .help("Stop showing this sent comment. It stays in what was sent.")
                    }
                }
                if !comment.quote.isEmpty, isStale || comment.side == .old {
                    Text(comment.quote.prefix(4).joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
                Text(comment.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(DS.spacing.s)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(comment.state == .draft ? DS.accent.opacity(0.5) : Color.secondary.opacity(0.2)))
        }
    }

    @ViewBuilder
    private var stateLabel: some View {
        switch comment.state {
        case .draft:
            Text("Draft")
                .font(.caption.weight(.semibold))
                .foregroundStyle(DS.accent)
        case .sent:
            if let sentAt = comment.sentAt {
                Text("Sent \(sentAt, style: .relative) ago")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .dismissed:
            EmptyView()
        }
    }
}

private struct CommentComposer: View {
    @Binding var text: String
    let title: String
    let onSave: () -> Void
    let onCancel: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.spacing.s) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 64, maxHeight: 200)
                .focused($focused)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Add Comment", action: onSave)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(DS.spacing.s)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .onAppear { focused = true }
    }
}

/// The exact text that will be typed into the conversation. Publishing to GitHub/GitLab is a
/// different action; this only talks to the agent.
private struct SendPreview: View {
    let message: String
    let count: Int
    let isSending: Bool
    let error: String?
    let onSend: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.spacing.m) {
            Text(count == 1 ? "Send 1 Comment to the Agent" : "Send \(count) Comments to the Agent")
                .font(.headline)
            Text("Typed into the conversation as one message. Nothing is posted to GitHub or GitLab.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(message)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DS.spacing.s)
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(DS.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(action: onSend) {
                    if isSending { ProgressView().controlSize(.small) } else { Text("Send") }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isSending)
            }
        }
        .padding(DS.spacing.l)
        .frame(minWidth: 520, idealWidth: 640, minHeight: 360, idealHeight: 480)
    }
}
#endif
