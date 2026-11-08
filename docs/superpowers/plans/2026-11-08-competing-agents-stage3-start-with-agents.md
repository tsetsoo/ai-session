# Competing Agents Stage 3: Start a Todo with Several Agents — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Start step of a todo with no conversation (Mac and iPhone) can start 1–10 agents (tool + model rows). One typed first message goes to each agent. Each agent gets its own worktree, and all of them start from one base, `origin/HEAD` on the todo's computer, which the sheet shows.

**Architecture:** App-driven, option (a) from the handover. Before Start, the app asks the todo's computer for the base (`ai-todo-workspace base <folder>`). Start opens the todo's first conversation through `POST /api/todos/{id}/conversation`, which now takes `model`, `base_sha` and `agents`. It then adds the others with stage 1's `POST /api/todos/{id}/conversations` (`own_worktree: true`, `base_sha`, `model`). Every agent is started detached with the text as `--prompt-file`, and then the first one is attached. The hub refuses a start with several agents unless the new conversation gets its own worktree. No schema change.

**Tech Stack:** Rust (actix-web, rusqlite) hub; Swift 6 / SwiftUI (AISessionCore package + Xcode app, macOS + iOS); bash/python host scripts.

**Spec:** `docs/superpowers/specs/2026-11-06-competing-agents-design.md`, section "Stage 3" and its anti-goals. Handover: `docs/superpowers/handovers/2026-11-08-competing-agents-stage3.md`.

## Global Constraints

- Never let several agents share one folder. Never start them from different commits. In either case, refuse instead.
- The base is `origin/HEAD` after a fetch, resolved **once per start** on the todo's computer. The sheet shows it as `from origin/main @ 8f5a29c` (7-character sha).
- 1–10 agents (`ResearchAgents.maxAgents`, hub `MAX_AGENTS`). The same tool may appear twice with different models. Model names: empty, or 1–80 of letters, digits and `._-[]`.
- **One agent and no text works exactly as today:** the same `confirmTool` → `startConversation` path, with no base lookup, no model and no prompt file.
- User-facing text is plain language: short sentences, no jargon.
- No new schema version. If one turns out to be needed, take the next free one (main is at v34).
- Don't add conversations to `DemoFixtures`.

## Rulings Ledger

| # | Ruling | Why |
|---|--------|-----|
| R1 | App-driven start (handover option a). The runner and hub run groups are not used. | Attended start. The runner's `--auto-approve` and detached sessions are for unattended jobs. |
| R2 | One row: today's segmented tool picker and MCP row stay, plus an optional first-message box and an **Add Agent** button. Two or more rows: the agent-row list (tool + model + remove), the base line and the count text. Removing back to one row returns to the one-row look, with `toolChoice = rows[0].tool`. | "One agent and no text looks and behaves exactly as today." The spec requires the text box, so it is visible but empty. |
| R3 | With several agents, the first message is **required**: Start stays disabled until there is text. The hint says "Every agent gets this as its first message." | Otherwise every agent sits idle and the user types the same thing several times. That is what this stage removes. |
| R4 | The base is looked up only when there are 2+ rows. With one agent (with or without text), stage 0 picks the base as today. | Keeps the one-agent path unchanged. |
| R5 | `ResearchAgentRow`/`ResearchAgents` are reused as they are, with no rename. The row UI moves into a shared `AgentRowsEditor` view used by both sheets. | Shares code without renaming across files other sessions are editing. |
| R6 | The added agents' labels come from `StartAgents.labels`: the tool name, with ` · model` when a model is set, and ` 2`, ` 3` added to repeats. The first agent has no label, because it is the todo's main conversation. | Tells the agents apart in the switcher. |
| R7 | `TmuxCommandBuilder.takesFirstPrompt` includes Cursor when `ResearchAgents.cursorTakesPrompt`. This also changes Add Agent, where Cursor now gets the text as `--prompt-file` instead of a paste. | Background agents can't receive a paste. Stage 2 checked Cursor's `--prompt-file` by hand, and every host has those scripts. |
| R8 | The hub refuses `agents > 1` (409) when the new conversation won't get its own worktree: the app says it can't make worktrees, worktrees are off, or the project has no `repo_url`. It also refuses (409) when the todo already has a conversation. `agents` outside 1–10 → 400. | The anti-goals are enforced on the hub as well as in the app. |
| R9 | The app refuses to continue if the hub's reply lacks the `worktreeBase` or `model` it asked for (an older hub). It discards the row and says "Update the hub to start several agents." | Prevents a silent different-commit start (anti-goal). |
| R10 | Added agents start concurrently once the first agent has started. If the first fails, nothing else starts and the error shows in the Start step. If an added agent fails, the others keep running, and an alert names each failure ("2 of 3 agents started. Codex didn't start: …"). | Spec: "If one attempt fails to start, the others continue". |
| R11 | MCP selection: the first agent gets the checklist's selection. Added agents copy it from the source on the hub (Cursor gets none), as Add Agent does. | Existing hub behaviour. Nothing new needed. |

## Review Focus

1. **One of three agents fails to start**: the other two keep running and show in the switcher. The user is told which one failed and why. Test: `StartAgentsTests.testStartedNoteNamesEachFailure`, plus the store's partial-failure handling in Task 4.
2. **An older hub ignores `base_sha`/`model`**: refuse instead of starting from a different commit (R9). Test: `StartAgentsTests.testHubIgnoredTheBase`.
3. **A computer whose scripts predate `base`**: the usage exit (64) says "Update the scripts on <computer>", not raw usage text. Test: `StartAgentsTests.testBaseFailureMessages`.
4. **Cursor among several agents**: it gets the first message through `--prompt-file`. A typed paste would be lost because the agent isn't on screen. Test: `HandoffPromptTests` (cursor now true).
5. **Start pressed twice, or while the base is still loading**: one group only, and no start without a resolved base. Test: `StartAgentsTests.testCanStart` (base nil → false). The view guards on `isStarting`.

---

### Task 1: Host helper `ai-todo-workspace base <folder>`

**Files:**
- Modify: `ai-session-remote/scripts/todo/ai_todo_workspace.py:116-125` (`resolve_base`)
- Modify: `ai-session-remote/scripts/todo/ai-todo-workspace` (docstring, `cmd_base`, `usage`, `main`)
- Test: `ai-session-remote/scripts/todo/test-todo-scripts.sh` (next to the existing `ai-todo-workspace ensure` tests, after line ~3450)

**Interfaces:**
- Produces: `resolve_base_ref(folder) -> (sha, ref) | None`, where `ref` is `git rev-parse --abbrev-ref origin/HEAD` (for example `origin/main`) or `"HEAD"` as the fallback. `resolve_base(folder)` returns `resolve_base_ref(folder)[0]`, unchanged for the runner.
- Produces (CLI): `ai-todo-workspace base <folder>` prints one line, `<full sha> <ref>`, and exits 0. Exit 66: not in a git repo. Exit 64: bad arguments.

- [ ] **Step 1: Write the failing shell test** `workspace_base_prints_origin_head`:
  - A repo with an `origin` remote (clone a bare repo made in the test), whose local branch has an extra commit the remote lacks: `base` prints `$(git -C clone rev-parse origin/HEAD) origin/main`.
  - A repo with no remote prints `<HEAD sha> HEAD`.
  - A plain folder exits 66.
  - `base` with no folder exits 64.
- [ ] **Step 2: Run `ai-session-remote/scripts/todo/test-todo-scripts.sh`.** Expected: FAIL at the new test (usage exit 64).
- [ ] **Step 3: Implement** `resolve_base_ref`, then `cmd_base` (`expand` the folder and print `"%s %s" % (sha, ref)`). Add `base <folder>` to the docstring and to `usage`.
- [ ] **Step 4: Run the script tests.** Expected: all pass.
- [ ] **Step 5: Commit** `feat(host): ai-todo-workspace base prints the commit new worktrees start from`.

### Task 2: Hub — the first open takes `model`, `base_sha` and `agents`

**Files:**
- Modify: `todo-app/crates/todo-shared/src/*.rs` (`OpenConversationRequest`, ~line 315)
- Modify: `todo-app/crates/todo-server/src/conversations.rs` (`open_conversation_db`, `open_conversation_in`, `duplicate_in`'s sha check, the `open_conversation` handler)
- Modify: the call sites `resume.rs:405` and the `conversations.rs` tests (~2378–2411) for the new parameter
- Test: `todo-app/crates/todo-server/src/conversations.rs` `#[cfg(test)]`

**Interfaces:**
- Produces: `OpenConversationRequest { tool, mcp_servers, worktrees, model: Option<String>, base_sha: Option<String>, agents: Option<u32> }`. All new fields are `#[serde(default, skip_serializing_if = "Option::is_none")]`.
- Produces: `pub(crate) struct OpenOptions<'a> { pub worktrees: bool, pub model: Option<&'a str>, pub base_sha: Option<&'a str>, pub agents: u32 }` (`Default`: worktrees false, agents 1). `open_conversation_db(conn, todo_id, tool, mcp_servers, &OpenOptions)` replaces the `worktrees: bool` parameter.
- Produces: `pub(crate) fn valid_base_sha(sha: &str) -> bool` (7–40 hex). `duplicate_in` uses it too.

- [ ] **Step 1: Write the failing tests:**
  - `open_with_agents_stores_model_and_base`: git project with worktrees on, `agents: 3`, `model: Some("opus[1m]")`, `base_sha: Some("8f5a29c0")`. The row has `model == Some("opus[1m]")`, `worktree_base == Some("8f5a29c0")`, and `worktree_source` set.
  - `open_with_agents_refused_without_worktrees`: `agents: 2` with project `worktrees = 0`, and again with an empty `repo_url`, and again with `OpenOptions.worktrees = false`. Each is `Err(OpenError::Conflict(_))` and no conversation row is created.
  - `open_with_agents_refused_when_a_conversation_exists`: open once, then `agents: 2` → `Conflict`.
  - `open_rejects_bad_agents_model_and_sha`: `agents: 0` and `agents: 11` → `BadRequest("agents must be 1 to 10")`; `model: Some("a b")` → `BadRequest(MODEL_RULE)`; `base_sha: Some("xyz")` → `BadRequest("base_sha must be a commit sha")`.
  - `open_with_one_agent_unchanged`: the existing open tests pass with `OpenOptions { worktrees, ..Default::default() }`.
- [ ] **Step 2: Run `cd todo-app && PATH=$HOME/.cargo/bin:$PATH cargo test`.** Expected: compile failure on `OpenOptions`.
- [ ] **Step 3: Implement.**
  - Validate before the transaction's inserts.
  - An existing conversation with `agents > 1` → `Conflict("This todo already has a conversation. Use Add Agent to start another.")`.
  - `agents > 1 && !(options.worktrees && own_worktree)` → `Conflict("Several agents need their own copy of the project. This project doesn't use worktrees or has no repository. Start with one agent, or turn worktrees on in the project's settings.")`.
  - After `plan_worktree`, set `worktree_base` (only when it has its own worktree) and `model`.
- [ ] **Step 4: Run cargo test.** Expected: all pass.
- [ ] **Step 5: Commit** `feat(hub): a todo's first conversation takes a model, a base and the agent count`.

### Task 3: Core — `StartAgents` rules, client fields, Cursor's first prompt

**Files:**
- Create: `ai-session-remote/Sources/AISessionCore/Board/StartAgents.swift`
- Modify: `ai-session-remote/Sources/AISessionCore/TodoHub/TodoHubModels.swift:639` (`OpenConversationRequest`)
- Modify: `ai-session-remote/Sources/AISessionCore/TodoHub/TodoHubClient.swift:183` (`openConversation`)
- Modify: `ai-session-remote/Sources/AISessionCore/Tmux/TmuxCommandBuilder.swift:245` (`takesFirstPrompt`), plus a new `workspaceBase(folder:)`
- Test: create `ai-session-remote/Tests/AISessionCoreTests/StartAgentsTests.swift`; modify `HandoffPromptTests.swift:43`, plus the client encoding test file for `OpenConversationRequest`, if one exists (`grep -rn OpenConversationRequest Tests`)

**Interfaces:**
- Produces: `OpenConversationRequest(tool:mcpServers:model:baseSha:agents:)`. `model`, `baseSha` and `agents` are omitted from the JSON when nil (snake_case keys `base_sha`, `agents`).
- Produces: `TodoHubClient.openConversation(todoId:tool:mcpServers:model:baseSha:agents:)`, with the new parameters defaulting to nil.
- Produces: `TmuxCommandBuilder.workspaceBase(folder: String) -> String` = `"$HOME/.ai-remote/bin/ai-todo-workspace" base <shellQuotePath(folder)>`.
- Produces, in `StartAgents.swift`:
  - `public struct StartBase: Equatable, Sendable { public let sha: String; public let ref: String }`
  - `public enum StartAgents`, with:
    - `static func parseBase(_ stdout: String) -> StartBase?`: the first line, `<sha> <ref>`. The sha must be 7–40 hex characters.
    - `static func baseLine(_ base: StartBase) -> String`: `"from origin/main @ 8f5a29c"`. Ref `HEAD` → `"from this computer's current commit @ 8f5a29c"`.
    - `static func baseFailure(exitCode: Int32, stderr: String, computer: String) -> String`:
      - 66 → `"This folder isn't a git repository, so several agents can't each get their own copy."`
      - 64 or 127 → `"Update the scripts on \(computer) to start several agents."`
      - Anything else → `"Couldn't find the latest main on \(computer). \(trimmed stderr)"`.
    - `static func refusal(project: Project?) -> String?`:
      - nil project → `"This todo has no project, so several agents can't each get their own copy."`
      - `!worktrees` → `"This project has worktrees turned off. Several agents can't share one folder. Start with one agent, or turn worktrees on in the project's settings."`
      - blank `repoUrl` → `"This project has no repository, so several agents can't each get their own copy. Start with one agent."`
      - Otherwise nil.
    - `static func addedRow(to rows: [ResearchAgentRow], offered: [String]) -> ResearchAgentRow`: the first offered tool not in `rows`, else the last row's tool.
    - `static func firstMessage(_ text: String) -> String?`: trimmed text, nil if empty.
    - `static func canStart(rows: [ResearchAgentRow], text: String, offered: [String], base: StartBase?, refusal: String?) -> Bool`:
      - One row: true.
      - 2–10 rows: every tool is offered, every model is valid, `firstMessage(text) != nil`, `base != nil` and `refusal == nil`.
    - `static func labels(_ rows: [ResearchAgentRow]) -> [String]`: labels for `rows.dropFirst()`, following R6. Uniqueness counts the first row's name too.
    - `static func hubIgnored(asked: (model: String?, baseSha: String?), got: Conversation) -> Bool`: true when a requested base or model is missing from or different in `got`.
    - `static func startedNote(total: Int, failures: [(label: String, message: String)]) -> String?`: nil with no failures; else `"\(total - failures.count) of \(total) agents started. "` followed by `"\(label) didn't start: \(message)"` for each failure, joined with `" "`.

- [ ] **Step 1: Write the failing tests** in `StartAgentsTests`:
  - `testParseBase`: `"8f5a29c0123 origin/main\n"` → `StartBase(sha: "8f5a29c0123", ref: "origin/main")`; `""` → nil; `"nothex origin/main"` → nil.
  - `testBaseLine`: `"from origin/main @ 8f5a29c"`; ref `"HEAD"` → `"from this computer's current commit @ 8f5a29c"`.
  - `testBaseFailureMessages`: exit 66, 64 and 127, and exit 1 with stderr `"fatal: x\n"`, each give the exact strings above.
  - `testRefusal`: nil project, worktrees off, blank `repoUrl`, and OK (nil).
  - `testAddedRow`: from `[claude]` with offered `[claude, codex]` → codex; from `[claude, codex]` → codex (the last row's tool).
  - `testCanStart`:
    - One row with empty text → true.
    - Two rows with empty text → false.
    - Two rows with text and base nil → false.
    - Two rows with text, a base and a refusal → false.
    - Two rows where one model is invalid (`"a b"`) → false.
    - Two rows where all checks pass → true.
  - `testLabels`: `[claude, codex, claude(opus), codex]` → `["Codex", "Claude · opus", "Codex 2"]`; `[claude, claude]` → `["Claude 2"]`.
  - `testHubIgnoredTheBase`: asked base `"8f5a29c"` and got `worktreeBase` nil → true; asked model `"o3"` and got model nil → true; both match → false; nothing asked → false.
  - `testStartedNoteNamesEachFailure`: `total: 3, failures: [("Codex", "No new codex conversation appeared")]` → `"2 of 3 agents started. Codex didn't start: No new codex conversation appeared"`; no failures → nil.
  - In `HandoffPromptTests`, cursor is now `XCTAssertTrue`.
  - An encoding test: `OpenConversationRequest(tool: "codex", model: "o3", baseSha: "8f5a29c", agents: 2)` encodes `"base_sha":"8f5a29c"` and `"agents":2`. With nil values, neither key appears.
- [ ] **Step 2: Run `cd ai-session-remote && swift test --filter 'StartAgentsTests|HandoffPromptTests'`.** Expected: compile failure.
- [ ] **Step 3: Implement** the interfaces above.
- [ ] **Step 4: Run `swift test`** (all of it: `takesFirstPrompt` has other users). Expected: all pass. If a Duplicate/AddAgent test assumed Cursor pastes, update it to R7.
- [ ] **Step 5: Commit** `feat(core): rules for starting a todo with several agents`.

### Task 4: Store — base lookup, first open with a first message, starting the group

**Files:**
- Modify: `ai-session-remote/App/AISessionRemote/Services/TodoHubStore.swift` (`openConversation` ~line 492, new `startBase`, new `startAgents`)
- Test: `ai-session-remote/App/AISessionRemoteMacTests/` (only if the store already has a fake-SSH seam there. Check `ReviewSessionTests.testAWorktreeConversationStartsAtItsBase` and follow it. Otherwise, the core tests and the hand check cover it, and that gets recorded in the ledger.)

**Interfaces:**
- Consumes: everything in Task 3; `writeHandoff`, `discardStart`, `duplicateConversation`, `prepareDuplicate`.
- Produces: `func startBase(folder: String, computer: Computer, config: HostConnectionConfig) async throws -> StartBase`. It runs `TmuxCommandBuilder.workspaceBase`, and a nonzero exit or unparseable output throws `TodoHubError.conflict(StartAgents.baseFailure(…))`.
- Produces: `openConversation(for:tool:config:mcpServers:model:baseSha:agents:firstMessage:)`. The new parameters default to nil, so existing callers are untouched. Behaviour:
  - It passes `model`, `baseSha` and `agents` to the client.
  - If `StartAgents.hubIgnored`, it calls `discardStart` and throws `TodoHubError.conflict("Update the hub to start several agents.")`.
  - Codex and Cursor: if `firstMessage` is set, it writes it with `writeHandoff` first. `freshTodoConversation` gets `promptFile:`, `model:` and `worktreeBase:` (the no-servers retry gets them too).
  - Claude with a `firstMessage`: it runs a detached `openTodoConversation(… promptFile:, detached: true, model:, worktreeBase:)` like `prepareDuplicate`'s `.resume`, and calls `discardStart` on failure.
  - Claude with no `firstMessage`: unchanged.
- Produces: `struct StartAgentsOutcome { let first: Conversation; let failures: [(label: String, message: String)] }` and `func startAgents(todo: Todo, rows: [ResearchAgentRow], firstMessage: String, base: StartBase, mcpServers: [String]?, config: HostConnectionConfig) async throws -> StartAgentsOutcome`:
  - The first row opens with `agents: rows.count`, `baseSha: base.sha`, its model, the MCP selection and `firstMessage`. This throws on failure, and nothing else starts.
  - The other rows start concurrently (`withTaskGroup`). Each runs `duplicateConversation(source: first, tool:, label: labels[i], ownWorktree: true, model:, baseSha: base.sha)`, then `prepareDuplicate(created, plan: .start(text: firstMessage, label:), config:)`. A failure is recorded as `(label, TodoHubStore.message(for: error))`.

- [ ] **Step 1:** If a store test seam exists, write `testStartAgentsKeepsGoingWhenOneFails`: three rows where the second add's SSH fails. The outcome has `first` set and one failure, labelled `"Codex"`, and the third conversation is remembered. Otherwise, record "no seam: covered by core + hand check" in the ledger and skip to Step 3.
- [ ] **Step 2: Run it.** Expected: FAIL.
- [ ] **Step 3: Implement** the interfaces above.
- [ ] **Step 4: Build the Mac app** (`cd ai-session-remote && xcodegen generate && xcodebuild -scheme AISessionRemoteMac -configuration Debug CODE_SIGNING_ALLOWED=NO build`), and run any new test. Expected: BUILD SUCCEEDED, tests pass.
- [ ] **Step 5: Commit** `feat(app): start a todo's agents from one base with one first message`.

### Task 5: UI — the Start step with agent rows, first message and base line (Mac + iPhone)

**Files:**
- Create: `ai-session-remote/App/AISessionRemote/Views/Shared/AgentRowsEditor.swift` (or next to `ResearchAgentsSheet` if there's no `Shared` folder)
- Modify: `ai-session-remote/App/AISessionRemote/Views/Automation/ResearchAgentsSheet.swift` (use `AgentRowsEditor`)
- Modify: `ai-session-remote/App/AISessionRemote/Views/Frame/ConversationFrame.swift` (`toolStep` ~line 582, `confirmTool` ~line 653)

**Interfaces:**
- Consumes: Tasks 3 and 4.
- Produces: `struct AgentRowsEditor: View { @Binding var rows: [ResearchAgentRow]; let offered: [String] }`. It contains the `ForEach` of tool picker + model field + remove button, and the **Add Agent** button, moved verbatim from `ResearchAgentsSheet`. It uses `StartAgents.addedRow` for the new row.

- [ ] **Step 1:** Extract `AgentRowsEditor` and use it in `ResearchAgentsSheet`. Build. Research Now must look unchanged.
- [ ] **Step 2: Extend `toolStep`.** New `@State`: `agentRows: [ResearchAgentRow] = []` (empty means one-row mode), `firstMessageText = ""`, `startBase: StartBase?`, `baseError: String?`.
  - **One-row mode:** today's view, plus a multi-line `TextField("First message", text:, prompt: Text("First message (optional)"), axis: .vertical)` with `lineLimit(3...8)`, and a borderless **Add Agent** button. Add Agent sets `agentRows = [ResearchAgentRow(tool: toolChoice), StartAgents.addedRow(…)]`.
  - **Multi-row mode** replaces the segmented picker with `AgentRowsEditor`. Under it:
    - the base line: `StartAgents.baseLine`, or "Finding the latest main…" while loading, or `baseError` in `DS.warning`;
    - the `StartAgents.refusal(project:)` text, when there is one;
    - `ResearchAgents.countText(n)`;
    - the hint "Every agent gets this as its first message."
    The MCP row stays.
  - When the rows drop to one: `toolChoice = agentRows[0].tool`, and `agentRows = []`.
  - `offered` = `ResearchAgents.offeredTools(installed: newConversationComputer?.tools)`.
- [ ] **Step 3: Base lookup.** `.task(id: agentRows.count > 1)`: when there are 2+ rows, the refusal is nil, and the base hasn't been found yet, call `store.startBase(folder: project.folder, computer:, config: HostLookup.config(for: computer, in: hosts))`. Store the result or the message. It runs once per sheet, and Start uses that sha.
- [ ] **Step 4: Start.** The Start button is disabled unless `StartAgents.canStart(…)`. `confirmTool`:
  - One row, no text: the existing code, untouched.
  - One row with text: the existing code, passing `firstMessage:` through `startConversation(tool:mcpServers:firstMessage:)` to `store.openConversation`.
  - Several rows: `store.startAgents(…)`, then `loader.attachOpened(outcome.first)` and `nameNewConversation(outcome.first)`. If `StartAgents.startedNote` is non-nil, set `failure = ActionFailure(title: "Some Agents Didn't Start", message: note)`.
  - A thrown error goes to `toolError`, as today. The title while starting is `isStarting ? "Starting…" : "Start"`. The existing `isStarting` guard prevents double starts.
- [ ] **Step 5: Build Mac and iOS:**
  - `xcodebuild -scheme AISessionRemoteMac … CODE_SIGNING_ALLOWED=NO build`
  - `xcodebuild -scheme AISessionRemote -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`
  - `xcodebuild test -scheme AISessionRemote -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
  - Expected: both build, and the tests pass. MacShellTests counts are unchanged.
- [ ] **Step 6: Commit** `feat(app): Start Conversation can start several agents with one first message`.

### Task 6: Full verification, review, handover

- [ ] **Step 1:** Run all suites: `cargo test`, `swift test`, `scripts/todo/test-todo-scripts.sh`, and the iOS app tests. Record the counts.
- [ ] **Step 2:** One fresh review of the whole branch, on the most capable model, against the spec's Stage 3 and this plan's Review Focus. Apply the confirmed fixes with tests.
- [ ] **Step 3:** Update the spec's Stage 3 with a "Built" note pointing to this plan, update the memory `competing-agents.md`, and commit.
- [ ] **Step 4:** Ask the user before installing. When the user says go, follow the order in the handover: scripts on 3 Macs → push (hub deploy) → Mac app rebuild → iPhone.
- [ ] **Step 5:** Hand check, with the user clicking: a todo in a worktree project started with Claude + Codex and a first message. Then check: both rows on the hub have the same `worktree_base`, there are two worktree folders at that sha, and both tmux panes received the text.
