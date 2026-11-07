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
                ReviewView(conversation: conversation, brief: "The todo this conversation works on: \(title)")
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

/// A line to bring into view in the diff (a finding picked in the Findings pane).
struct DiffFocus: Equatable {
    var path: String
    var side: DiffSide
    var line: Int
    /// A new value each pick, so picking the same line again scrolls again.
    var token = UUID()
}

struct ReviewView: View {
    let conversation: Conversation
    /// What the conversation is for, handed to a reviewer agent.
    let brief: String?

    @Query private var hosts: [HostEntity]
    @Environment(AppModel.self) private var model
    @State private var session: ReviewSession
    @State private var selectedPath: String?
    @State private var showingSend = false
    @State private var showingFindings = false
    @State private var showingPublish = false
    @State private var showingApprove = false
    @State private var showingMerge = false
    /// Option was held on Merge…: pending or failing checks don't stop it.
    @State private var mergeOverride = false
    /// Bumped by Refresh: the PR/MR is read when the window opens and on Refresh, not on
    /// every scope change.
    @State private var pullRequestReads = 0
    @State private var focus: DiffFocus?

    init(conversation: Conversation, brief: String? = nil) {
        self.conversation = conversation
        self.brief = brief
        _session = State(initialValue: ReviewSession(conversation: conversation))
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
        } detail: {
            detail
        }
        .inspector(isPresented: $showingFindings) {
            // A hidden inspector still lays its content out: build it only while shown.
            if showingFindings {
                FindingsPane(session: session, onPick: { pick($0) },
                             actions: .init(publish: { showingPublish = true },
                                            approve: { showingApprove = true },
                                            merge: { mergeOverride = $0; showingMerge = true }))
                    .inspectorColumnWidth(min: 280, ideal: 360, max: 560)
            }
        }
        .toolbar { toolbar }
        // Another commit in Compare With is a new load too, though the scope stays `.commit`.
        .task(id: "\(session.scope.rawValue)|\(session.baseCommit?.sha ?? "")") { await reload() }
        // The PR/MR and its threads, beside the diff: never holds it up; stops with the window.
        .task(id: pullRequestReads) {
            await withConfig { await session.loadPullRequest(config: $0) }
        }
        // A run started here or by an earlier window: followed while the window is open.
        .task(id: session.activeRun?.id) {
            guard session.activeRun != nil else { return }
            await withConfig { await session.followReview(config: $0) }
        }
        // Another device changed this review (the phone sent or dismissed an item).
        .onChange(of: model.store.reviewSummaries[conversation.listKey]) { _, _ in
            Task { await session.refreshFromHub() }
        }
        .onChange(of: model.store.isOffline, initial: true) { _, offline in
            session.hubOffline = offline
            // Back: whatever waited goes now, and the hub's copy comes in.
            if !offline { Task { await session.store.pushAll(); await session.refreshFromHub() } }
        }
        .onChange(of: session.record.lastRun?.state) { _, state in
            if state == .done, (session.record.lastRun?.findingCount ?? 0) > 0 { showingFindings = true }
        }
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
        .sheet(isPresented: $showingPublish) {
            PublishSheet(session: session) { event, summary, ids in
                var done = false
                await withConfig { done = await session.publish(event: event, summary: summary, ids: ids, config: $0) }
                return done
            }
        }
        .sheet(isPresented: $showingMerge) {
            MergeSheet(session: session, overrideChecks: mergeOverride, agentWorking: conversation.status == .busy) { method, deleteBranch in
                var done = false
                await withConfig {
                    done = await session.merge(method: method, deleteBranch: deleteBranch, overrideChecks: mergeOverride, config: $0)
                }
                return done
            }
        }
        .confirmationDialog(approveTitle, isPresented: $showingApprove, titleVisibility: .visible) {
            Button("Approve") {
                Task { await withConfig { await session.publish(event: .approve, summary: "", ids: [], config: $0) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Posted on \(session.pullRequest?.provider == "gitlab" ? "GitLab" : "GitHub") as \(session.pullRequest?.viewer ?? "the computer's account"), from \(conversation.computer.name). Nothing is typed into the conversation.")
        }
        .alert("Review", isPresented: Binding(get: { session.failure != nil && !showingSend && !showingPublish && !showingMerge },
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

    /// Shows a finding in the diff: its file, scrolled to its line.
    private func pick(_ comment: ReviewComment) {
        let place = session.place(of: comment)
        let path = session.diff.files.first { $0.path == place.path || $0.oldPath == place.path }?.path
        guard let path else { return }
        selectedPath = path
        if let line = place.line { focus = DiffFocus(path: path, side: place.side, line: line) }
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
            if let problem = session.store.problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(DS.warning)
                }
            }
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
            FileDiffView(file: file, session: session, focus: focus)
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
        if let pullRequest = conversation.pullRequest {
            ToolbarItem(placement: .status) {
                PullRequestChip(pullRequest: pullRequest)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            reviewControl
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                showingFindings.toggle()
            } label: {
                Label(findingsTitle, systemImage: "checklist")
            }
            .help("Show or hide the reviewer's findings.")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                pullRequestReads += 1
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

    @ViewBuilder
    private var reviewControl: some View {
        if let run = session.activeRun {
            HStack(spacing: DS.spacing.s) {
                ProgressView().controlSize(.small)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Reviewing with \(run.tool.capitalized)… \(Self.elapsed(from: run.startedAt, to: context.date))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Button("Cancel") {
                    Task { await withConfig { await session.cancelReview(config: $0) } }
                }
            }
            .help(session.reviewProblem.map { "Couldn't check on the review: \($0). Trying again." }
                  ?? "A reviewer agent is reading these changes on \(conversation.computer.name). It only reads; it changes nothing.")
        } else {
            Menu {
                ForEach(["claude", "codex"], id: \.self) { tool in
                    Button("Review with \(tool.capitalized)") {
                        Task {
                            await withConfig { await session.startReview(tool: tool, brief: brief, config: $0) }
                        }
                    }
                }
            } label: {
                Label("Review", systemImage: "sparkle.magnifyingglass")
                    .labelStyle(.titleAndIcon)
            } primaryAction: {
                Task { await withConfig { await session.startReview(tool: "claude", brief: brief, config: $0) } }
            }
            .disabled(session.reviewBlocker != nil || session.isLoading)
            .help(session.reviewBlocker ?? "Have a reviewer agent read the changes on screen and list what it would raise. "
                  + "Its findings go to you, not to the agent, until you send them.")
        }
    }

    private var findingsTitle: String {
        let count = session.findings(.new).count
        return count == 0 ? "Findings" : "Findings (\(count))"
    }

    private var approveTitle: String {
        guard let info = session.pullRequest, let pr = info.pr else { return "Approve?" }
        return "Approve \(pr.name(provider: info.provider))?"
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
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
    var focus: DiffFocus?

    @State private var selection: LineSelection?
    @State private var draft = ""
    @State private var fileComment = false

    var body: some View {
        let marks = session.findingMarks(file: file)
        ScrollViewReader { proxy in
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
                ForEach(Array(file.hunks.enumerated()), id: \.offset) { hunkIndex, hunk in
                    Text("@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@ \(hunk.section)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, DS.spacing.s)
                        .padding(.vertical, DS.spacing.xs)
                        .background(Color.secondary.opacity(0.08))
                    ForEach(Array(hunk.lines.enumerated()), id: \.offset) { lineIndex, line in
                        lineRow(line, mark: line.kind == .removed ? nil : line.newLine.flatMap { marks[$0] },
                                rowID: line.kind == .removed ? nil : line.newLine.map(Self.lineID) ?? "h\(hunkIndex)-\(lineIndex)")
                    }
                }
            }
            .padding(.bottom, DS.spacing.xl)
        }
        .onAppear { scroll(proxy) }
        .onChange(of: focus) { _, _ in scroll(proxy) }
        }
        .onExitCommand { selection = nil }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let focus, focus.path == file.path else { return }
        let id = focus.side == .old ? Self.oldLineID(focus.line) : Self.lineID(focus.line)
        withAnimation { proxy.scrollTo(id, anchor: .center) }
    }

    static func lineID(_ newLine: Int) -> String { "new-\(newLine)" }
    static func oldLineID(_ oldLine: Int) -> String { "old-\(oldLine)" }

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
    private func lineRow(_ line: DiffLine, mark: String?, rowID: String?) -> some View {
        let side: DiffSide = line.kind == .removed ? .old : .new
        let number = side == .old ? line.oldLine : line.newLine
        // Removed lines are in the old revision, where a renamed file had its old name.
        let path = side == .old ? file.oldPath ?? file.path : file.path
        let isSelected = number.map { n in selection.map { $0.side == side && $0.lines.contains(n) } ?? false } ?? false
        DiffLineRow(line: line, isSelected: isSelected, mark: mark)
            .id(rowID ?? Self.oldLineID(line.oldLine ?? 0))
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
    /// The highest severity of the unsent findings on this line, or nil.
    var mark: String?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(mark.map(FindingBadge.color) ?? .clear)
                .frame(width: 3)
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
            CommentComposer(text: $text, title: "Edit comment on \(comment.location)", saveTitle: "Save") {
                session.editComment(comment.id, body: text)
                editing = false
            } onCancel: { editing = false }
        } else {
            VStack(alignment: .leading, spacing: DS.spacing.xs) {
                HStack(spacing: DS.spacing.s) {
                    if comment.isFinding { FindingBadge(comment: comment) }
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
                    if comment.isFinding {
                        FindingActions(comment: comment, session: session) {
                            text = comment.body
                            editing = true
                        }
                    } else if comment.state == .draft {
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
                if let title = comment.title {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .textSelection(.enabled)
                }
                Text(comment.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(DS.spacing.s)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(border))
        }
    }

    private var border: Color {
        if comment.state == .draft { return DS.accent.opacity(0.5) }
        if comment.state == .new || comment.state == .stale { return FindingBadge.color(comment.severity ?? "medium").opacity(0.5) }
        return Color.secondary.opacity(0.2)
    }

    @ViewBuilder
    private var stateLabel: some View {
        switch comment.state {
        case .draft:
            Text(comment.isFinding ? "In next batch" : "Draft")
                .font(.caption.weight(.semibold))
                .foregroundStyle(DS.accent)
        case .new, .stale:
            EmptyView()
        case .addressed:
            Text("Addressed")
                .font(.caption)
                .foregroundStyle(.secondary)
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
    var saveTitle = "Add Comment"
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
                Button(saveTitle, action: onSave)
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
// MARK: - Findings

/// `HIGH` / `MED` / `LOW` and the reviewer's name.
private struct FindingBadge: View {
    let comment: ReviewComment

    var body: some View {
        if let author = comment.prAuthor {
            Text("PR")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(DS.accent, in: Capsule())
                .help("A review thread by \(author) on the pull/merge request")
        } else {
            reviewerBadge
        }
    }

    @ViewBuilder
    private var reviewerBadge: some View {
        let severity = comment.severity ?? "medium"
        Text(Self.short(severity))
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Self.color(severity), in: Capsule())
            .help("\(severity.capitalized) · \(comment.category ?? "finding") · found by \(comment.reviewer?.capitalized ?? "a reviewer")")
    }

    static func short(_ severity: String) -> String {
        switch severity {
        case "high": "HIGH"
        case "low": "LOW"
        default: "MED"
        }
    }

    static func color(_ severity: String) -> Color {
        switch severity {
        case "high": DS.error
        case "low": .secondary
        default: DS.warning
        }
    }
}

/// Send (joins the next batch) / Edit / Dismiss, or Remove from batch, or Restore.
private struct FindingActions: View {
    let comment: ReviewComment
    let session: ReviewSession
    let onEdit: () -> Void

    var body: some View {
        switch comment.state {
        case .new, .stale:
            Button("Send") { session.queueFinding(comment.id) }
                .buttonStyle(.link)
                .help("Add it to the comments that go to the agent with Send to Agent.")
            Button("Edit", action: onEdit)
                .buttonStyle(.link)
            Button("Dismiss") { session.dismissComment(comment.id) }
                .buttonStyle(.link)
                .help("Not worth raising. A later review won't bring it back.")
        case .draft:
            Button("Edit", action: onEdit)
                .buttonStyle(.link)
            Button("Remove from Batch") { session.queueFinding(comment.id, false) }
                .buttonStyle(.link)
        case .sent, .addressed:
            Button("Hide") { session.dismissComment(comment.id) }
                .buttonStyle(.link)
        case .dismissed:
            Button("Restore") { session.restoreFinding(comment.id) }
                .buttonStyle(.link)
        }
    }
}

/// The reviewers' findings beside the diff: the last run, a filter, findings by file.
/// What the PR/MR buttons do; the window shows the confirmations.
struct PullRequestActions {
    var publish: () -> Void
    var approve: () -> Void
    /// Whether Option was held.
    var merge: (Bool) -> Void
}

private struct FindingsPane: View {
    let session: ReviewSession
    let onPick: (ReviewComment) -> Void
    let actions: PullRequestActions

    @State private var filter: ReviewSession.FindingFilter = .new

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PullRequestSection(session: session, actions: actions)
            runHeader
                .padding(DS.spacing.m)
            Picker("Show", selection: $filter) {
                ForEach(ReviewSession.FindingFilter.allCases) { filter in
                    Text("\(filter.title) \(session.findings(filter).count)").tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, DS.spacing.m)
            .padding(.bottom, DS.spacing.s)
            Divider()
            let findings = session.findings(filter)
            if findings.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: "checklist")
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(byFile(findings), id: \.path) { group in
                        Section(group.path) {
                            ForEach(group.findings) { comment in
                                CommentCard(comment: comment, isStale: session.isStale(comment), session: session)
                                    .contentShape(Rectangle())
                                    .onTapGesture { onPick(comment) }
                                    .listRowSeparator(.hidden)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    private var emptyTitle: String {
        switch filter {
        case .new: session.record.runs.isEmpty ? "No Review Yet" : "Nothing New"
        case .sent: "None Sent"
        case .stale: "None Stale"
        case .dismissed: "None Dismissed"
        }
    }

    private func byFile(_ findings: [ReviewComment]) -> [(path: String, findings: [ReviewComment])] {
        var order: [String] = []
        var groups: [String: [ReviewComment]] = [:]
        for comment in findings {
            let path = session.place(of: comment).path
            if groups[path] == nil { order.append(path) }
            groups[path, default: []].append(comment)
        }
        return order.sorted().map { ($0, groups[$0] ?? []) }
    }

    @ViewBuilder
    private var runHeader: some View {
        if let run = session.record.lastRun {
            VStack(alignment: .leading, spacing: DS.spacing.xs) {
                HStack {
                    Text("\(run.tool.capitalized)\(run.model.map { " · \($0)" } ?? "")")
                        .font(.headline)
                    Spacer()
                    Text(run.startedAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(revisionLine(run))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                switch run.state {
                case .running:
                    Text("Reviewing…").foregroundStyle(.secondary)
                case .failed:
                    Label(run.error ?? "The review failed.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(DS.error)
                case .cancelled:
                    Text("Cancelled.").foregroundStyle(.secondary)
                case .done:
                    if let summary = run.summary, !summary.isEmpty {
                        Text(summary).font(.callout)
                    }
                    Text(countLine(run))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Review asks Claude or Codex to read the changes on screen. Its findings land here for you to send, edit or dismiss.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// `reviewed a1b2c3d · showing e4f5a6b` (the same: `reviewed a1b2c3d, on screen`).
    private func revisionLine(_ run: ReviewRun) -> String {
        let reviewed = String(run.reviewedSHA.prefix(7))
        guard let current = session.result?.to else { return "reviewed \(reviewed)" }
        if current == run.reviewedSHA { return "reviewed \(reviewed), the revision on screen" }
        return "reviewed \(reviewed) · on screen \(current.prefix(7))"
    }

    private func countLine(_ run: ReviewRun) -> String {
        var parts: [String] = []
        let found = run.findingCount ?? 0
        parts.append(found == 1 ? "1 finding" : "\(found) findings")
        if let added = run.addedCount, added != found { parts.append("\(found - added) already listed") }
        if let usage = run.usage, !usage.summary.isEmpty { parts.append(usage.summary) }
        return parts.joined(separator: " · ")
    }
}
/// The branch's PR/MR at the top of the Findings pane: state, reviews, checks, who gh/glab act
/// as, and its description as evidence for the review. Read-only.
private struct PullRequestSection: View {
    let session: ReviewSession
    let actions: PullRequestActions

    @State private var showsDescription = false

    var body: some View {
        if let problem = session.pullRequestProblem {
            Label(problem, systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding([.horizontal, .top], DS.spacing.m)
        } else if let info = session.pullRequest, let pr = info.pr {
            VStack(alignment: .leading, spacing: DS.spacing.xs) {
                HStack(alignment: .firstTextBaseline) {
                    if let url = pr.url.flatMap(URL.init(string:)) {
                        Link(pr.name(provider: info.provider), destination: url)
                            .font(.headline)
                    } else {
                        Text(pr.name(provider: info.provider)).font(.headline)
                    }
                    Text(pr.title)
                        .font(.headline)
                        .lineLimit(2)
                }
                Text(statusLine(pr))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: DS.spacing.s) {
                    Label(checksLine(pr.checks), systemImage: checksSymbol(pr.checks.state))
                        .foregroundStyle(pr.checks.state == "failing" ? DS.error : pr.checks.state == "pending" ? DS.warning : .secondary)
                    if let viewer = info.viewer {
                        Text("· you are \(viewer) there")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                if pr.state == "open" {
                    writeButtons(info: info)
                }
                if !pr.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    DisclosureGroup("Description", isExpanded: $showsDescription) {
                        if showsDescription {
                            ScrollView {
                                Text(Self.markdown(pr.body))
                                    .font(.callout)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 260)
                        }
                    }
                    .font(.caption)
                }
            }
            .padding([.horizontal, .top], DS.spacing.m)
        }
    }

    /// Publish, Approve and Merge: on GitHub/GitLab, apart from Send to Agent.
    private func writeButtons(info: ReviewPullRequestInfo) -> some View {
        HStack(spacing: DS.spacing.s) {
            Button("Publish Review…", action: actions.publish)
                .disabled(session.publishBlocker != nil || session.isWriting)
                .help(session.publishBlocker ?? "Post comments on the pull request as \(info.viewer ?? "the computer's account"). Separate from Send to Agent.")
            if session.canApprove {
                Button("Approve", action: actions.approve)
                    .disabled(session.approveBlocker != nil || session.isWriting)
                    .help(session.approveBlocker ?? "Approve as \(info.viewer ?? "the computer's account").")
            }
            Button("Merge…") {
                actions.merge(NSEvent.modifierFlags.contains(.option))
            }
            // Pending or failing checks keep it off unless Option is held: it stays clickable then.
            .disabled(session.mergeBlocker(overrideChecks: true) != nil || session.isWriting)
            .help(session.mergeBlocker(overrideChecks: false) ?? "Merge, pinned to the head shown here.")
            if session.isWriting { ProgressView().controlSize(.small) }
        }
        .controlSize(.small)
        .padding(.top, DS.spacing.xs)
    }

    private func statusLine(_ pr: ReviewPullRequestInfo.PullRequest) -> String {
        var parts = [pr.draft ? "\(pr.state) · draft" : pr.state]
        if let author = pr.author { parts.append("by \(author)") }
        switch pr.reviewDecision {
        case "approved": parts.append("approved")
        case "changes_requested": parts.append("changes requested")
        case "review_required": parts.append("review required")
        default: break
        }
        if !pr.approvals.isEmpty { parts.append("approved by \(pr.approvals.joined(separator: ", "))") }
        if let mergeable = pr.mergeable, pr.state == "open" { parts.append(mergeable.replacingOccurrences(of: "_", with: " ")) }
        return parts.joined(separator: " · ")
    }

    private func checksLine(_ checks: ReviewPullRequestInfo.Checks) -> String {
        switch checks.state {
        case "passing": return "checks passing"
        case "failing": return "\(checks.failed) of \(checks.total) checks failing"
        case "pending": return "\(checks.pending) of \(checks.total) checks running"
        default: return "no checks"
        }
    }

    private func checksSymbol(_ state: String) -> String {
        switch state {
        case "passing": "checkmark.circle"
        case "failing": "xmark.circle"
        case "pending": "clock"
        default: "circle.dashed"
        }
    }

    /// Markdown as far as Text shows it; the raw text when it doesn't parse.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
/// Publish Review…: the review that will be posted, as whom, with which comments.
private struct PublishSheet: View {
    let session: ReviewSession
    let onPublish: (ReviewPublishRequest.Event, String, Set<UUID>) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var event: ReviewPublishRequest.Event = .comment
    @State private var summary = ""
    @State private var chosen: Set<UUID> = []
    @State private var candidates: [ReviewSession.PublishCandidate] = []

    var body: some View {
        let info = session.pullRequest
        let provider = info?.provider == "gitlab" ? "GitLab" : "GitHub"
        VStack(alignment: .leading, spacing: DS.spacing.m) {
            Text("Publish a Review on \(info?.pr.map { $0.name(provider: info?.provider) } ?? "the Pull Request")")
                .font(.headline)
            Text("Posted on \(provider) as \(info?.viewer ?? "the computer's account"), from \(session.conversation.computer.name). Nothing is typed into the conversation.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Picker("Review", selection: $event) {
                ForEach(ReviewPublishRequest.Event.allCases.filter { info?.provider != "gitlab" || $0 != .requestChanges }, id: \.self) {
                    Text($0.title).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!session.canApprove)
            TextEditor(text: $summary)
                .frame(minHeight: 60, maxHeight: 120)
                .overlay(alignment: .topLeading) {
                    if summary.isEmpty {
                        Text("Summary (optional)").foregroundStyle(.tertiary).padding(6).allowsHitTesting(false)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
            List(candidates) { candidate in
                Toggle(isOn: Binding(get: { chosen.contains(candidate.id) },
                                     set: { if $0 { chosen.insert(candidate.id) } else { chosen.remove(candidate.id) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidate.line.map { "\(candidate.comment.path):\($0.start == $0.end ? "\($0.start)" : "\($0.start)-\($0.end)")" }
                             ?? candidate.comment.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text(candidate.comment.title ?? candidate.comment.body)
                            .lineLimit(2)
                        if let reason = candidate.reason {
                            Text(reason).font(.caption).foregroundStyle(DS.warning)
                        }
                    }
                }
                .disabled(candidate.line == nil && candidate.comment.startLine != nil)
            }
            .frame(minHeight: 160)
            if let error = session.failure?.errorDescription {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(DS.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    session.failure = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    Task {
                        session.failure = nil
                        if await onPublish(event, summary, chosen) { dismiss() }
                    }
                } label: {
                    if session.isWriting { ProgressView().controlSize(.small) } else { Text(publishTitle) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(session.isWriting || (event == .comment && chosen.isEmpty && summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(DS.spacing.l)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 480)
        .onAppear {
            candidates = session.publishCandidates()
            // Not yet published, on lines of the PR: picked to start with.
            chosen = Set(candidates.filter { ($0.line != nil || $0.comment.startLine == nil) && !session.publishedIDs.contains($0.id)
                && $0.comment.state != .sent }.map(\.id))
        }
    }

    private var publishTitle: String {
        let count = chosen.count
        let comments = count == 0 ? "" : " with \(count) Comment\(count == 1 ? "" : "s")"
        switch event {
        case .comment: return "Publish\(comments)"
        case .approve: return "Approve\(comments)"
        case .requestChanges: return "Request Changes\(comments)"
        }
    }
}

/// Merge…: method, branch, warnings, and who merges.
private struct MergeSheet: View {
    let session: ReviewSession
    let overrideChecks: Bool
    let agentWorking: Bool
    let onMerge: (String, Bool) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var method = "merge"
    @State private var deleteBranch = true

    var body: some View {
        let info = session.pullRequest
        let pr = info?.pr
        VStack(alignment: .leading, spacing: DS.spacing.m) {
            Text("Merge \(pr.map { $0.name(provider: info?.provider) } ?? "the Pull Request")?")
                .font(.headline)
            Text("As \(info?.viewer ?? "the computer's account") on \(info?.provider == "gitlab" ? "GitLab" : "GitHub"), only while its head is \(String((pr?.headSHA ?? "").prefix(7))): if anyone pushed since, nothing is merged. Branch protection is the forge's.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if agentWorking {
                Label("The agent is working in this conversation right now.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(DS.warning)
            }
            if overrideChecks, let blocker = session.mergeBlocker(overrideChecks: false) {
                Label(blocker.replacingOccurrences(of: " Hold Option to merge anyway.", with: " Merging anyway."),
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(DS.warning)
            }
            Picker("Method", selection: $method) {
                Text("Merge commit").tag("merge")
                Text("Squash").tag("squash")
                Text("Rebase").tag("rebase")
            }
            .pickerStyle(.segmented)
            Toggle("Delete the branch \(pr?.headRef ?? "") afterwards", isOn: $deleteBranch)
            if let error = session.failure?.errorDescription {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(DS.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    session.failure = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    Task {
                        session.failure = nil
                        if await onMerge(method, deleteBranch) { dismiss() }
                    }
                } label: {
                    if session.isWriting { ProgressView().controlSize(.small) } else { Text("Merge") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.isWriting || session.mergeBlocker(overrideChecks: overrideChecks) != nil)
            }
        }
        .padding(DS.spacing.l)
        .frame(minWidth: 480, idealWidth: 520)
    }
}
#endif
