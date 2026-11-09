import XCTest
@testable import AISessionCore

/// Starting a todo with several agents: one base, one first message, each in its own worktree.
final class StartAgentsTests: XCTestCase {
    private func row(_ tool: String, _ model: String = "") -> ResearchAgentRow { ResearchAgentRow(tool: tool, model: model) }
    private let base = StartBase(sha: "8f5a29c0123", ref: "origin/main")

    func testParseBase() {
        XCTAssertEqual(StartAgents.parseBase("8f5a29c0123 origin/main\n"), base)
        XCTAssertNil(StartAgents.parseBase(""))
        XCTAssertNil(StartAgents.parseBase("nothex origin/main"))
    }

    func testBaseLine() {
        XCTAssertEqual(StartAgents.baseLine(base), "from origin/main @ 8f5a29c")
        XCTAssertEqual(StartAgents.baseLine(StartBase(sha: "8f5a29c0123", ref: "HEAD")), "from this computer's current commit @ 8f5a29c")
    }

    func testBaseFailureMessages() {
        XCTAssertEqual(StartAgents.baseFailure(exitCode: 66, stderr: "", computer: "Mac"),
                       "This folder isn't a git repository, so several agents can't each get their own copy.")
        XCTAssertEqual(StartAgents.baseFailure(exitCode: 64, stderr: "usage: …", computer: "Mac"),
                       "Update the scripts on Mac to start several agents.")
        XCTAssertEqual(StartAgents.baseFailure(exitCode: 127, stderr: "", computer: "Mac"),
                       "Update the scripts on Mac to start several agents.")
        XCTAssertEqual(StartAgents.baseFailure(exitCode: 1, stderr: "fatal: x\n", computer: "Mac"),
                       "Couldn't find the latest main on Mac. fatal: x")
    }

    func testRefusal() {
        let mac = Computer(id: "m", name: "Mac", hostname: "h", port: 22, username: "u")
        let ok = Project(id: "p", name: "app", computer: mac, folder: "~/app", repoUrl: "git@x:a.git")
        XCTAssertEqual(StartAgents.refusal(project: nil), "This todo has no project, so several agents can't each get their own copy.")
        var off = ok; off.worktrees = false
        XCTAssertEqual(StartAgents.refusal(project: off),
                       "This project has worktrees turned off. Several agents can't share one folder. Start with one agent, or turn worktrees on in the project's settings.")
        var noRepo = ok; noRepo.repoUrl = " "
        XCTAssertEqual(StartAgents.refusal(project: noRepo),
                       "This project has no repository, so several agents can't each get their own copy. Start with one agent.")
        var noFolder = ok; noFolder.folder = "  "
        XCTAssertEqual(StartAgents.refusal(project: noFolder),
                       "This project has no folder, so several agents can't each get their own copy. Set its folder in the project's settings.")
        XCTAssertNil(StartAgents.refusal(project: ok))
    }

    func testAddedRow() {
        XCTAssertEqual(StartAgents.addedRow(to: [row("claude")], offered: ["claude", "codex"]).tool, "codex")
        XCTAssertEqual(StartAgents.addedRow(to: [row("claude"), row("codex")], offered: ["claude", "codex"]).tool, "codex")
    }

    func testCanStart() {
        let offered = ["claude", "codex"]
        XCTAssertTrue(StartAgents.canStart(rows: [row("claude")], text: "", offered: offered, base: nil, refusal: nil))
        let two = [row("claude"), row("codex")]
        XCTAssertFalse(StartAgents.canStart(rows: two, text: " ", offered: offered, base: base, refusal: nil))
        XCTAssertFalse(StartAgents.canStart(rows: two, text: "Fix it", offered: offered, base: nil, refusal: nil))
        XCTAssertFalse(StartAgents.canStart(rows: two, text: "Fix it", offered: offered, base: base, refusal: "no"))
        XCTAssertFalse(StartAgents.canStart(rows: [row("claude"), row("codex", "a b")], text: "Fix it", offered: offered, base: base, refusal: nil))
        XCTAssertFalse(StartAgents.canStart(rows: [row("claude"), row("cursor")], text: "Fix it", offered: offered, base: base, refusal: nil))
        XCTAssertTrue(StartAgents.canStart(rows: two, text: "Fix it", offered: offered, base: base, refusal: nil))
    }

    func testLabels() {
        XCTAssertEqual(StartAgents.labels([row("claude"), row("codex"), row("claude", "opus"), row("codex")]),
                       ["Codex", "Claude · opus", "Codex 2"])
        XCTAssertEqual(StartAgents.labels([row("claude"), row("claude")]), ["Claude 2"])
    }

    func testHubIgnoredTheBase() {
        let mac = Computer(id: "m", name: "Mac", hostname: "h", port: 22, username: "u")
        func got(model: String? = nil, base: String? = nil) -> Conversation {
            Conversation(id: "c", todoId: "t", computer: mac, cwd: "~/w", tool: "claude", tmuxName: "ai/claude/todo-1",
                         sessionId: "s", status: .unknown, model: model, worktreeBase: base)
        }
        XCTAssertTrue(StartAgents.hubIgnored(asked: (model: nil, baseSha: "8f5a29c"), got: got()))
        XCTAssertTrue(StartAgents.hubIgnored(asked: (model: "o3", baseSha: nil), got: got()))
        XCTAssertFalse(StartAgents.hubIgnored(asked: (model: "o3", baseSha: "8f5a29c"), got: got(model: "o3", base: "8f5a29c")))
        XCTAssertFalse(StartAgents.hubIgnored(asked: (model: nil, baseSha: nil), got: got()))
    }

    func testStartedNoteNamesEachFailure() {
        XCTAssertEqual(StartAgents.startedNote(total: 3, failures: [(label: "Codex", message: "No new codex conversation appeared")]),
                       "2 of 3 agents started. Codex didn't start: No new codex conversation appeared")
        XCTAssertNil(StartAgents.startedNote(total: 3, failures: []))
    }

    func testFirstMessage() {
        XCTAssertEqual(StartAgents.firstMessage("  Fix it \n"), "Fix it")
        XCTAssertNil(StartAgents.firstMessage(" \n"))
    }

    /// Like every helper: with the PATH (Homebrew, linuxbrew) and UTF-8 locale set up.
    func testWorkspaceBaseCommand() {
        XCTAssertEqual(TmuxCommandBuilder.workspaceBase(folder: "~/my app"),
                       TmuxCommandBuilder.wrap("\"$HOME/.ai-remote/bin/ai-todo-workspace\" base \(TmuxCommandBuilder.shellQuotePath("~/my app"))"))
    }

    /// A fetch that failed: the commit is origin's as last seen, and the line says so.
    func testStaleBase() {
        let stale = StartBase(sha: "8f5a29c0123", ref: "origin/main", fresh: false)
        XCTAssertEqual(StartAgents.parseBase("8f5a29c0123 origin/main stale\n"), stale)
        XCTAssertEqual(StartAgents.parseBase("8f5a29c0123 origin/main")?.fresh, true)
        XCTAssertNil(StartAgents.parseBase("8f5a29c0123 origin/main other"))
        XCTAssertEqual(StartAgents.baseLine(stale),
                       "from origin/main @ 8f5a29c. Couldn't reach origin, so this may not be the latest.")
    }

    func testTrimmedModel() {
        XCTAssertNil(row("claude", "  ").trimmedModel)
        XCTAssertEqual(row("claude", " opus ").trimmedModel, "opus")
    }

    /// Add Agent from one agent: that agent's tool when the computer has it, else one it has.
    func testInitialRows() {
        XCTAssertEqual(StartAgents.initialRows(toolChoice: "cursor", offered: ["claude", "codex"]).map(\.tool), ["claude", "codex"])
        XCTAssertEqual(StartAgents.initialRows(toolChoice: "codex", offered: ["claude", "codex"]).map(\.tool), ["codex", "claude"])
    }

    /// The tool the next todo's Start preselects: the one that opened as the main conversation.
    func testRememberedTool() {
        XCTAssertEqual(StartAgents.rememberedTool([row("cursor"), row("claude")]), "claude")
        XCTAssertEqual(StartAgents.rememberedTool([row("cursor")]), "cursor")
    }

    func testCopyAndRemovePromptFile() {
        XCTAssertEqual(TmuxCommandBuilder.copyPromptFile(path: "/h/p/handoff.a"), TmuxCommandBuilder.wrap(
            "umask 077 && f=$(mktemp \"$HOME/.ai-remote/prompts/handoff.XXXXXX\") && cp '/h/p/handoff.a' \"$f\" && printf '%s\\n' \"$f\""
        ))
        XCTAssertEqual(TmuxCommandBuilder.removePromptFile(path: "/h/p/handoff.a"), TmuxCommandBuilder.wrap("rm -f '/h/p/handoff.a'"))
    }

    func testOpenedConversationReadsCreated() throws {
        let decoder = TodoHubClient.makeDecoder()
        let body = #"{"id":"c","todo_id":"t","computer":{"id":"m","name":"Mac","hostname":"h","port":22,"username":"u","created_at":"","updated_at":""},"cwd":"~/w","tool":"claude","tmux_name":"ai/claude/todo-1","session_id":"s","status":"unknown","created":true}"#
        let opened = try decoder.decode(OpenedConversation.self, from: Data(body.utf8))
        XCTAssertEqual(opened.conversation.id, "c")
        XCTAssertEqual(opened.created, true)
        let old = try decoder.decode(OpenedConversation.self, from: Data(body.replacingOccurrences(of: #","created":true"#, with: "").utf8))
        XCTAssertNil(old.created)
    }

    func testOpenRequestCarriesModelBaseAndAgents() throws {
        let encoder = TodoHubClient.makeEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let full = String(decoding: try encoder.encode(OpenConversationRequest(tool: "codex", model: "o3", baseSha: "8f5a29c", agents: 2)), as: UTF8.self)
        XCTAssertEqual(full, #"{"agents":2,"base_sha":"8f5a29c","model":"o3","tool":"codex","worktrees":true}"#)
        let plain = String(decoding: try encoder.encode(OpenConversationRequest(tool: "codex")), as: UTF8.self)
        XCTAssertEqual(plain, #"{"tool":"codex","worktrees":true}"#)
    }

    private struct Boom: Error {}

    private func conversation(_ id: String) -> Conversation {
        Conversation(id: id, todoId: "t", computer: Computer(id: "m", name: "Mac", hostname: "h", port: 22, username: "u"),
                     cwd: "~/w", tool: "claude", tmuxName: "ai/claude/todo-\(id)", sessionId: "s", status: .unknown)
    }

    func testStartAgentsKeepsGoingWhenOneFails() async throws {
        let added = Recorder()
        let outcome = try await StartAgents.run(
            rows: [row("claude"), row("codex"), row("claude", "opus")],
            openFirst: { _ in self.conversation("first") },
            add: { first, row, label in
                XCTAssertEqual(first.id, "first")
                if row.tool == "codex" { throw Boom() }
                await added.append(label)
            },
            message: { _ in "No new codex conversation appeared" }
        )
        XCTAssertEqual(outcome.first.id, "first")
        XCTAssertEqual(outcome.failures.map(\.label), ["Codex"])
        XCTAssertEqual(outcome.failures.map(\.message), ["No new codex conversation appeared"])
        let labels = await added.items
        XCTAssertEqual(labels, ["Claude · opus"])
    }

    /// Added agents copy the first one's MCP selection, and Cursor has none: a Claude or Codex
    /// row opens first so the selection reaches them.
    func testOpeningOrderPutsAToolWithServersFirst() {
        XCTAssertEqual(StartAgents.openingOrder([row("cursor"), row("claude"), row("codex")]).map(\.tool), ["claude", "cursor", "codex"])
        XCTAssertEqual(StartAgents.openingOrder([row("codex"), row("cursor")]).map(\.tool), ["codex", "cursor"])
        XCTAssertEqual(StartAgents.openingOrder([row("cursor"), row("cursor", "x")]).map(\.model), ["", "x"])
    }

    func testStartAgentsOpensAToolWithServersFirst() async throws {
        let opened = Recorder()
        _ = try await StartAgents.run(
            rows: [row("cursor"), row("claude")],
            openFirst: { row in await opened.append(row.tool); return self.conversation("first") },
            add: { _, row, _ in await opened.append(row.tool) },
            message: { _ in "" }
        )
        let tools = await opened.items
        XCTAssertEqual(tools, ["claude", "cursor"])
    }

    /// Only a row this device didn't know before the open is its own to start with a message
    /// or to remove when that start fails; another device's conversation is left alone.
    /// The hub says whether its open made the row. An older hub doesn't: then only an unseen
    /// row that never reported a status counts (best effort; install order avoids it).
    func testLeftoverStart() {
        let now = HubDates.date(from: "2026-11-09 10:00:00")!
        func unstarted(createdAt: String) -> Conversation {
            var c = conversation("c1"); c.tool = "codex"; c.sessionId = ""; c.createdAt = createdAt; return c
        }
        let old = unstarted(createdAt: "2026-11-09 09:49:59")
        XCTAssertEqual(StartAgents.leftover([old], now: now), .clear(old))
        XCTAssertEqual(StartAgents.leftover([unstarted(createdAt: "2026-11-09 09:51:00")], now: now), .starting)
        // A date it can't read counts as old: nothing else can clear the row.
        let unreadable = unstarted(createdAt: "")
        XCTAssertEqual(StartAgents.leftover([unreadable], now: now), .clear(unreadable))
        // One that reported a status ran: a runner agent whose id report failed.
        var ran = old; ran.status = .idle
        XCTAssertEqual(StartAgents.leftover([ran], now: now), .none)
        XCTAssertEqual(StartAgents.leftover([], now: now), .none)
        XCTAssertEqual(StartAgents.leftover([conversation("c1")], now: now), .none)
        XCTAssertEqual(StartAgents.leftover([old, conversation("c2")], now: now), .none)
    }

    func testStartAgentsStopsWhenTheFirstFails() async {
        let added = Recorder()
        do {
            _ = try await StartAgents.run(
                rows: [row("claude"), row("codex")],
                openFirst: { _ in throw Boom() },
                add: { _, _, label in await added.append(label) },
                message: { _ in "" }
            )
            XCTFail("the first failing should throw")
        } catch {}
        let labels = await added.items
        XCTAssertEqual(labels, [])
    }
}

private actor Recorder {
    var items: [String] = []
    func append(_ item: String) { items.append(item) }
}
