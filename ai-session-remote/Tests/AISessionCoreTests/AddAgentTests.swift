import XCTest
@testable import AISessionCore

/// Add agent: what the new conversation starts with, where, and from which commit.
final class AddAgentTests: XCTestCase {
    private func conversation(tool: String = "claude", worktree: Bool = true) -> Conversation {
        Conversation(
            id: "src", todoId: "t", computer: Computer(id: "m", name: "Mac", hostname: "h", port: 22, username: "u"),
            cwd: "~/.ai-remote/worktrees/p/src", tool: tool, tmuxName: "ai/\(tool)/todo-1", sessionId: "s1",
            status: .idle, worktreeSource: worktree ? "~/app" : nil, branch: worktree ? "ai/do-it-src" : nil
        )
    }

    private func plan(
        _ handoff: AddAgentHandoff, tool: String = "codex", source: Conversation? = nil, projectWorktrees: Bool = true,
        transcript: String = "the transcript", firstUserMessage: String? = "Fix the login", summary: String? = "the summary"
    ) -> AddAgentPlan {
        AddAgent.plan(
            source: source ?? conversation(), tool: tool, model: "m1", label: "Codex", handoff: handoff,
            projectWorktrees: projectWorktrees, transcript: transcript, firstUserMessage: firstUserMessage,
            confirmedSummary: summary
        )
    }

    func testSummaryIsTheDefault() {
        XCTAssertEqual(AddAgentHandoff.defaultChoice, .summary)
    }

    func testSummaryStartsWithTheConfirmedSummaryFromASnapshot() {
        let p = plan(.summary)
        XCTAssertEqual(p.start, .firstPrompt("the summary"))
        XCTAssertEqual(p.base, .sourceSnapshot)
        XCTAssertTrue(p.ownWorktree)
        XCTAssertEqual(p.model, "m1")
        XCTAssertEqual(p.label, "Codex")
    }

    func testACancelledSummaryCreatesNothing() {
        XCTAssertEqual(plan(.summary, summary: nil).start, .cancelled(reason: nil))
        XCTAssertEqual(plan(.summary, summary: "  \n").start, .cancelled(reason: nil))
    }

    func testFullForksTheSameToolAndSendsTheTranscriptToAnother() {
        // Sharing the folder: a native fork. In a worktree of its own a fork can't follow
        // (`claude --resume` finds sessions by folder), so the transcript goes in instead.
        XCTAssertEqual(plan(.full, tool: "claude", projectWorktrees: false).start, .fork(sourceSessionId: "s1"))
        XCTAssertEqual(plan(.full, tool: "claude").start, .firstPrompt("the transcript"))
        XCTAssertEqual(plan(.full, tool: "codex").start, .firstPrompt("the transcript"))
        XCTAssertEqual(plan(.full, tool: "codex").base, .sourceSnapshot)
    }

    func testFullOverBudgetFallsBackToTheSummary() {
        let long = String(repeating: "x", count: 200_000)
        XCTAssertEqual(plan(.full, tool: "codex", transcript: long).start, .firstPrompt("the summary"))
        XCTAssertEqual(plan(.full, tool: "codex", transcript: long, summary: nil).start, .cancelled(reason: nil))
    }

    func testFreshStartsWithTheFirstMessageFromTheSourcesBase() {
        let p = plan(.fresh)
        XCTAssertEqual(p.start, .firstPrompt("Fix the login"))
        XCTAssertEqual(p.base, .sourceBase)
        XCTAssertEqual(plan(.fresh, firstUserMessage: nil).start, .cancelled(reason: "No first message found"))
    }

    func testOwnWorktreeOnlyWhenTheSourceHasOneAndTheProjectWantsIt() {
        XCTAssertFalse(plan(.summary, source: conversation(worktree: false)).ownWorktree)
        XCTAssertFalse(plan(.summary, projectWorktrees: false).ownWorktree)
        XCTAssertTrue(plan(.summary).sharesFolderWarning == false)
        XCTAssertTrue(plan(.summary, projectWorktrees: false).sharesFolderWarning)
    }

    func testAnEmptyModelIsTheDefault() {
        let p = AddAgent.plan(
            source: conversation(), tool: "codex", model: "  ", label: "x", handoff: .summary, projectWorktrees: true,
            transcript: "", firstUserMessage: nil, confirmedSummary: "s"
        )
        XCTAssertNil(p.model)
    }

    func testFirstUserMessageIsTheFirstUserTurn() {
        let messages = [
            ConversationMessage(id: "1", role: .activity, text: "read file", time: nil),
            ConversationMessage(id: "2", role: .user, text: "  Fix the login  ", time: nil),
            ConversationMessage(id: "3", role: .user, text: "and tests", time: nil),
        ]
        XCTAssertEqual(AddAgent.firstUserMessage(messages), "Fix the login")
        XCTAssertNil(AddAgent.firstUserMessage([]))
    }

    /// Claude Code records `/clear` and similar as user turns: a note, the command, its output.
    /// They are not what the user asked, so Fresh skips them (seen 2026-11-07: Codex got the note).
    func testFirstUserMessageSkipsCommandRecordsAndSystemNotes() {
        let messages = [
            ConversationMessage(id: "1", role: .user, text: "<local-command-caveat>The command below was run directly in Claude Code.</local-command-caveat>", time: nil),
            ConversationMessage(id: "2", role: .user, text: "<command-name>/clear</command-name>\n  <command-message>clear</command-message>\n  <command-args></command-args>", time: nil),
            ConversationMessage(id: "3", role: .user, text: "<local-command-stdout></local-command-stdout>", time: nil),
            ConversationMessage(id: "4", role: .user, text: "<system-reminder>notes</system-reminder>\n\n# Handover: stage 2", time: nil),
        ]
        XCTAssertEqual(AddAgent.firstUserMessage(messages), "# Handover: stage 2")
        XCTAssertNil(AddAgent.firstUserMessage(Array(messages.prefix(3))))
    }

    func testThePlanMapsOntoTheDuplicateStart() {
        XCTAssertEqual(plan(.summary).duplicatePlan, .start(text: "the summary", label: "Codex"))
        XCTAssertEqual(plan(.full, tool: "claude", projectWorktrees: false).duplicatePlan, .fork(sourceSessionId: "s1", label: "Codex"))
        XCTAssertEqual(plan(.summary, summary: nil).duplicatePlan, .cancelled)
    }

    // MARK: Hub fields and calls

    func testConversationDecodesModelBaseAndMain() throws {
        let json = #"{"id":"c","todo_id":"t","computer":{"id":"m","name":"Mac","hostname":"h","port":22,"username":"u","created_at":"","updated_at":""},"cwd":"~/x","tool":"codex","tmux_name":"n","session_id":"s","status":"closed","created_at":"","model":"m1","worktree_base":"abc1234","main":true}"#
        let c = try TodoHubClient.makeDecoder().decode(Conversation.self, from: Data(json.utf8))
        XCTAssertEqual(c.model, "m1")
        XCTAssertEqual(c.worktreeBase, "abc1234")
        XCTAssertTrue(c.main)
        let bare = #"{"id":"c","todo_id":"t","computer":{"id":"m","name":"Mac","hostname":"h","port":22,"username":"u","created_at":"","updated_at":""},"cwd":"~/x","tool":"codex","tmux_name":"n","session_id":"s","status":"idle","created_at":""}"#
        let old = try TodoHubClient.makeDecoder().decode(Conversation.self, from: Data(bare.utf8))
        XCTAssertNil(old.model)
        XCTAssertFalse(old.main)
    }

    func testAddAgentRequestBody() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = .sortedKeys
        let body = DuplicateConversationRequest(sourceId: "s", tool: "codex", label: "x", ownWorktree: true, model: "m1", baseSha: "abc1234")
        XCTAssertEqual(
            String(decoding: try encoder.encode(body), as: UTF8.self),
            #"{"base_sha":"abc1234","label":"x","model":"m1","own_worktree":true,"source_id":"s","tool":"codex"}"#
        )
        let plain = DuplicateConversationRequest(sourceId: "s", tool: "codex", label: "x")
        XCTAssertEqual(String(decoding: try encoder.encode(plain), as: UTF8.self), #"{"label":"x","source_id":"s","tool":"codex"}"#)
    }

    func testOpenPassesModelAndWorktreeBase() {
        let command = TmuxCommandBuilder.freshTodoConversation(
            tmuxName: "ai/codex/todo-1", cwd: "~/x", tool: "codex", worktree: ("~/w", "ai/b"), promptFile: "/p",
            model: "m1", worktreeBase: "abc1234"
        )
        XCTAssertTrue(command.contains("--worktree '~/w' 'ai/b' --worktree-base 'abc1234' --model 'm1' --prompt-file '/p' 'ai/codex/todo-1'"), command)
        let open = TmuxCommandBuilder.openTodoConversation(
            tmuxName: "n", cwd: "~/x", sessionId: "s", worktree: ("~/w", "ai/b"), model: "m1", worktreeBase: "abc1234"
        )
        XCTAssertTrue(open.contains("--worktree '~/w' 'ai/b' --worktree-base 'abc1234' --model 'm1' 'n'"), open)
    }
}
