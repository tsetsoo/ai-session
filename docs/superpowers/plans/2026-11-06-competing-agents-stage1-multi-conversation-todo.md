# Competing agents, stage 1: one todo, several conversations — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A todo with several conversations is easy to use: a switcher (one at a time, or side by side on the Mac), "Continue with this", closed attempts that can be reopened, and Duplicate replaced by "Add agent" whose hand-off actually arrives.

**Architecture:**
1. **Hand-off.** It becomes the new agent's *first prompt*. The app writes it to a file on the computer and starts the agent with `ai-todo-open --prompt-file`, which already passes it as the tool's first message for Claude and Codex. This replaces the timing-sensitive terminal paste. The fork case (Claude → Claude, "Full conversation") still resumes with no message.
2. **Hub.** It gains:
   - a conversation's `model` and `worktree_base`;
   - a todo's `main_conversation_id`;
   - "add agent" (its own worktree for the new conversation);
   - "continue with" (choose one and close the rest);
   - "reopen" by id.
3. **Computer.** `ai-todo-workspace ensure` and `ai-todo-open --worktree` learn a base commit. The source's current state, uncommitted work included, comes from `ai-todo-review status`/`keep`, which already make stable snapshot commits.
4. **App.** A per-todo switcher and pane header in `TodoConversationScreen`, side by side on the Mac only, and an Add agent sheet replacing `DuplicateInMenu`/`DuplicateSummarySheet`.

**Tech Stack:** Rust (actix-web, rusqlite) in `todo-app/crates`; Python 3 / POSIX sh in `ai-session-remote/scripts/todo`; Swift (AISessionCore, SwiftUI app for macOS and iOS).

**Spec:** `docs/superpowers/specs/2026-11-06-competing-agents-design.md` (stage 1). Stage 0 is `main`'s worktree per conversation (855de62, e861274) plus `keep_worktrees` (130d944). Use `main`'s names: `worktree_source`, `ai-todo-workspace ensure`, `--worktree <folder> <branch>`.

## Global Constraints

- **Agent count:** 1 to 10 conversations per todo (spec goal 5). Add agent refuses an 11th with 409 "A todo has at most 10 agents".
- **Default hand-off:** Add agent defaults to **Summary**, which is editable before it's sent. The other choices are **Full conversation** (Claude → Claude forks, others get the transcript, falling back to Summary over budget) and **Fresh with the same first message**.
- **Worktrees:** in a project with worktrees on, an added agent always gets **its own worktree**: path `~/.ai-remote/worktrees/<project>/<conversation>`, branch `ai/<title>-<id8>`.
  - Summary and Full start from the **source's current state**: a snapshot commit including uncommitted and untracked files.
  - Fresh starts from the **source's base commit**, its `worktree_base`, or `origin/HEAD` when unknown.
- **No worktrees:** without worktrees (project off, or not a git repo), Add agent shares the folder as Duplicate does today, and the sheet warns "Both agents will work in the same folder."
- **Continue with this:** closes every other open conversation of the todo. It stops their tmux sessions and sets hub status `closed`, but keeps the rows, sessions, worktrees and branches. Cleanup keeps those worktrees until the todo is Done (`keep_worktrees`, already on main).
- **Side by side:** Mac only. The iPhone gets the switcher as tabs. Mount only visible terminals (see memory "Mac inspector renders hidden": hidden views still lay out).
- **Schema:** bump to the next free version (25 on main today).
- **Compatibility:** older apps keep working. An older app calling the old duplicate endpoint gets today's behaviour.
- **Commits:** end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Add agent while the source is busy.** The snapshot is taken at that moment; edits the source makes afterwards are not in the new worktree. Expected: it starts from the state at the click, with no error.
2. **Continue with a conversation while another one is busy.** Expected: confirm first ("Codex is still working. Close it?"), as closing a busy conversation does today.
3. **Reopen a closed attempt whose worktree the sweep removed after the todo was Done and then un-done.** Expected: `ensure` re-creates it from its branch, which main already does.
4. **A todo with 4+ open conversations on the Mac.** Expected: side by side is a 2-column grid, and only those panes' terminals are mounted.
5. **Summary sheet cancelled.** Expected: nothing is created, no hub row, no worktree. Today's `DuplicateIn.perform` rule is kept.

---

### Task 1: Hand-off as the first prompt (fixes "no summary, no transcript")

**Root cause (from the code map):**
- Claude → Claude Duplicate forks and sends nothing.
- Other hand-offs paste into the terminal: on `.connected`, wait ≤ 8 s for bracketed-paste mode, then paste and CR in one write. A tool that isn't ready yet, or that collapses a big paste into a placeholder, drops or never submits it.

**Files:**
- Modify: `ai-session-remote/Sources/AISessionCore/Tmux/TmuxCommandBuilder.swift`: new `writePromptFile(text:) -> String`, a command that writes base64-decoded text to `mktemp ~/.ai-remote/prompts/handoff.XXXXXX` and prints the path. `openTodoConversation` and `freshTodoConversation` gain `promptFile: String? = nil`, emitted as `--prompt-file '<path>'` after `--mcp`.
- Modify: `ai-session-remote/App/AISessionRemote/Services/TodoHubStore.swift`: `prepareDuplicate` / `.captureFresh` and the Claude `.resume` start pass the prompt file.
- Modify: `ai-session-remote/App/AISessionRemote/Views/Frame/ConversationFrame.swift`: `startDuplicate` no longer sets `duplicateLaunch.paste` for Claude/Codex. It keeps paste only for Cursor, whose `ai-todo-open` has no first-prompt support.
- Test: `ai-session-remote/Tests/AISessionCoreTests/TmuxCommandBuilderTests.swift`, and `scripts/todo/test-todo-scripts.sh` (a Claude start without `--detached` gets the prompt as its last argument).

- [ ] **Step 1:** Write the failing tests:
  - `testWritePromptFileDecodesBase64IntoAPrivateFile`: the command contains `base64` decoding, `umask 077` and `mktemp`.
  - `testOpenPassesThePromptFile`: `--prompt-file '/p'` appears before the tmux name.
  - Shell: `ai-todo-open --prompt-file F <name> <cwd> <sid>` (attached start) → the fake claude's argv ends with the file's text, and F is deleted.
- [ ] **Step 2:** Run `swift test --filter TmuxCommandBuilderTests` and `scripts/todo/test-todo-scripts.sh`. Expected: the Swift tests FAIL (no such API). The shell test may already PASS, since `ai-todo-open` reads `--prompt-file` on any start. If so, record a ruling and keep the test as a regression guard.
- [ ] **Step 3:** Implement. `TodoHubStore.startWithHandoff(conversation:text:config:) async throws -> String` runs `writePromptFile` over SSH (`remoteStdout`) and returns the path. The duplicate start passes it to the open or fresh command.
- [ ] **Step 4:** Run `swift test` (all) and the script suite. Expected: PASS.
- [ ] **Step 5:** Commit `fix(app): duplicate hand-off is the new agent's first prompt, not a paste`.

### Task 2: Hub: model, base, main conversation, add agent, continue, reopen

**Files:**
- Modify: `todo-app/crates/todo-server/src/db.rs`. New migration step:
  - `conversations.model TEXT`, `conversations.worktree_base TEXT`;
  - `todos.main_conversation_id TEXT`;
  - bump `SCHEMA_VERSION` and the sniff function, following the existing pattern.
- Modify: `todo-app/crates/todo-shared/src/lib.rs`:
  - `Conversation.model: Option<String>`, `Conversation.worktree_base: Option<String>`;
  - `DuplicateConversationRequest` gains `#[serde(default)] own_worktree: bool`, `model: Option<String>`, `base_sha: Option<String>`;
  - `Todo`/`TodoWithConversation` expose `main_conversation_id: Option<String>` where todos are serialized.
- Modify: `todo-app/crates/todo-server/src/conversations.rs`:
  - `duplicate_in`: with `own_worktree` and a source that has `worktree_source`, plan a new worktree via `plan_worktree` and store `worktree_base = base_sha`. Otherwise keep today's sharing. Store `model` when it matches `[A-Za-z0-9._-]+`. Enforce the 10-conversation cap.
  - New `continue_with_db(conn, id) -> Result<Vec<Conversation>, OpenError>`: sets `todos.main_conversation_id`, sets every other non-closed conversation of the todo to `closed`, and returns the conversations it closed so the app can stop their tmux sessions.
  - New `reopen_db(conn, id) -> Result<Conversation, OpenError>`: a closed row becomes `unknown`; any other row is returned as is.
- Modify: `todo-app/crates/todo-server/src/main.rs`: routes `POST /api/conversations/{id}/continue` and `POST /api/conversations/{id}/reopen`.
- Test: in-file test modules.

**Interfaces (produced):** JSON fields `model`, `worktree_base`, `main_conversation_id`; endpoints as above; `POST /api/todos/{id}/conversations` body `{source_id, tool, label, own_worktree?, model?, base_sha?}`.

- [ ] **Step 1:** Write the failing tests:
  - `add_agent_gets_own_worktree`: source in a worktree; `own_worktree: true` → a different cwd under `~/.ai-remote/worktrees/<p>/<new id>`, a new branch, `worktree_base == base_sha`.
  - `add_agent_without_own_worktree_shares`: today's behaviour.
  - `add_agent_cap_is_10` → 409 on the 11th.
  - `continue_closes_the_others`: 3 rows, continue on #2 → #1 and #3 are `closed`, the todo's `main_conversation_id` is #2's id, the response lists #1 and #3.
  - `reopen_by_id`: a closed #1 becomes `unknown`, and the others are untouched.
  - The migration test, in the style of `migrates_to_v22`.
- [ ] **Step 2:** Run `cargo test` in `todo-app/`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `cargo test`. Expected: all pass.
- [ ] **Step 5:** Commit `feat(hub): add agent in its own worktree, continue with one conversation, reopen by id`.

### Task 3: Computer: worktrees from a base commit

**Files:**
- Modify: `ai-session-remote/scripts/todo/ai_todo_workspace.py`: `create(folder, path, branch, base=None)` and `ensure(registry_path, path, folder, branch, log=..., base=None)`. `base` is used only when the branch doesn't exist yet. An existing branch is still reused, as now.
- Modify: `ai-session-remote/scripts/todo/ai-todo-workspace`: `ensure <path> <folder> <branch> [--base <sha>]`, where sha must match `[0-9a-f]{7,40}`.
- Modify: `ai-session-remote/scripts/todo/ai-todo-open`: leading option `--worktree-base <sha>`, passed through to `ensure --base`.
- Test: `scripts/todo/test-todo-scripts.sh`.

- [ ] **Step 1:** Write failing tests:
  - Make a snapshot of a dirty worktree with `ai-todo-review status <cwd>` (`revision`), then `keep` it.
  - `ensure --base <revision>` on a new path → the new worktree's HEAD is that snapshot, and the uncommitted file from the source is present and committed.
  - `ai-todo-open --worktree F B --worktree-base <sha>` passes `--base` through (via the `AI_TODO_WORKSPACE_BIN` stub).
  - A malformed sha → exit 64.
- [ ] **Step 2:** Run the suite. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run the suite. Expected: all pass.
- [ ] **Step 5:** Commit `feat(scripts): a conversation worktree can start from a given commit`.

### Task 4: Core: add-agent plan, models, client calls

**Files:**
- Create: `ai-session-remote/Sources/AISessionCore/Board/AddAgent.swift`. It replaces the decision part of `DuplicateHandoff.swift`, keeping `ForkCommand`/`TranscriptBudget`.
  - `enum AddAgentHandoff { case summary, full, fresh }` (default `.summary`).
  - `struct AddAgentPlan` with: `tool`, `model: String?`, `label`, `ownWorktree: Bool`, `base: Base` (`enum Base { case sourceSnapshot, sourceBase }`), and `start: Start` (`enum Start { case fork(sourceSessionId:), firstPrompt(String), cancelled }`).
  - `static func plan(source: Conversation, tool: String, model: String?, label: String, handoff: AddAgentHandoff, projectWorktrees: Bool, transcript: String, firstUserMessage: String?, confirmedSummary: String?) -> AddAgentPlan`.
  - Rules:
    - Summary needs `confirmedSummary`; without it, `.cancelled`.
    - Full: same tool with a fork → `.fork`; otherwise the transcript within budget → `.firstPrompt(transcript)`; otherwise behaves as Summary.
    - Fresh → `.firstPrompt(firstUserMessage)`. Without a first message, `.cancelled` with the reason "No first message found".
    - `ownWorktree = projectWorktrees && source.worktreeSource != nil`.
    - `base = handoff == .fresh ? .sourceBase : .sourceSnapshot`.
- Modify: `ai-session-remote/Sources/AISessionCore/TodoHub/TodoHubModels.swift`: `Conversation.model`, `.worktreeBase`; the todo's `mainConversationId`; `DuplicateConversationRequest` fields.
- Modify: `ai-session-remote/Sources/AISessionCore/TodoHub/TodoHubClient.swift`: `duplicateConversation(..., ownWorktree:model:baseSha:)`, `continueWith(conversationId:) -> [Conversation]`, `reopenConversation(id:) -> Conversation`.
- Modify: `TmuxCommandBuilder`: `--model` and `--worktree-base` on the open/fresh builders, plus `reviewStatus(cwd:)` / `reviewKeep(cwd:sha:)` wrappers for `ai-todo-review`.
- Test: `ai-session-remote/Tests/AISessionCoreTests/AddAgentTests.swift`, plus client body tests in `TodoHubClientTests.swift`.

- [ ] **Step 1:** Write failing tests for every rule above, the request bodies, and the decoding of the new fields (present and absent).
- [ ] **Step 2:** Run `swift test`. Expected: FAIL.
- [ ] **Step 3:** Implement. `DuplicateHandoff.decide`'s callers move to `AddAgent.plan`. Delete what becomes unused.
- [ ] **Step 4:** Run `swift test`. Expected: all pass.
- [ ] **Step 5:** Commit `feat(core): add-agent plan (summary by default, full, fresh), new hub fields and calls`.

### Task 5: App: Add agent sheet and flow

**Files:**
- Create: `ai-session-remote/App/AISessionRemote/Views/Frame/AddAgentSheet.swift`, replacing `DuplicateInMenu.swift` and `DuplicateSummarySheet.swift` (delete both and their tests' dead parts). It contains:
  - a tool picker (Claude, Codex, Cursor where the computer has it, as `DuplicateInMenu` decides today);
  - a model field (empty = default);
  - a name field (`DuplicateName.proposal`);
  - a hand-off picker: Summary (default), Full conversation, Fresh with the same first message;
  - for Summary, the editable summary text, filled by `summarizeConversation` with a progress indicator;
  - the no-worktree warning when applicable.
- Modify: `ConversationFrame.swift`. `beginDuplicate`/`confirmSummary`/`startDuplicate` become `beginAddAgent`/`startAddAgent`:
  1. Snapshot when `plan.base == .sourceSnapshot`: `reviewStatus` → `revision`, then `reviewKeep`.
  2. `store.duplicateConversation(... ownWorktree, model, baseSha)`.
  3. Start: fork as today; or `startWithHandoff` (Task 1) with the plan's first prompt and `--worktree-base`.
  4. Select the new conversation.
- Modify: `MacShell.swift` (column toolbar), `ConversationActions.swift`: the "Duplicate" action becomes "Add Agent…" (same shortcut).
- Test: `App/AISessionRemoteTests/DuplicateInTests.swift` → `AddAgentFlowTests.swift`: the cancelled summary creates nothing, and the request carries `own_worktree`/`base_sha` (with a stub store or client, the way `DuplicateInTests` does today).

- [ ] **Step 1:** Write the failing tests.
- [ ] **Step 2:** Run the app test target (`xcodebuild test -scheme AISessionRemote -destination 'platform=iOS Simulator,name=iPhone 16'`, the existing iOS test target). Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run the tests, plus Mac and iOS Debug builds. Expected: pass, both build.
- [ ] **Step 5:** Commit `feat(app): Add agent replaces Duplicate: summary by default, own worktree, first-prompt hand-off`.

### Task 6: App: switcher, side by side, Continue with this, reopen

**Files:**
- Create: `ai-session-remote/App/AISessionRemote/Views/Shell/ConversationSwitcher.swift`:
  - `struct ConversationSwitcher` (Mac: segmented, one segment per open conversation labelled `tool · model` with a status glyph — ✓ idle/done, … busy, ! waiting — plus "Side by Side"; iPhone: the same as tabs, no side by side);
  - `struct ConversationPaneHeader` (tool · model, status, elapsed since `createdAt`, "Continue with This").
- Create: `ai-session-remote/App/AISessionRemote/Views/Shell/ConversationGrid.swift`: side by side. Two panes are two columns; 3–10 panes make a 2-column grid. Each pane is its own `ConversationLoader` + `ConversationFrame` for that conversation, keyed by `listKey`, and only these panes are mounted.
- Modify: `ai-session-remote/App/AISessionRemote/Views/Shell/TodoConversationScreen.swift`:
  - shows the switcher when the todo has ≥ 2 non-closed conversations;
  - `@SceneStorage` per todo for one/side-by-side;
  - after Continue, or with ≤ 1 open, the normal single view plus a trailing note button: "Codex attempt · closed" (one) or "3 other attempts · closed" (several). The button reopens them all (`reopenConversation` for each, then the switcher comes back).
- Modify: `ai-session-remote/App/AISessionRemote/Services/TodoHubStore.swift`:
  - `continueWith(_ conversation: Conversation, config:) async throws`: calls the hub, then `killSessionExact` for each closed conversation's tmux, ignoring exit 1;
  - `displayed(forTodo:)` prefers `mainConversationId` when that conversation is open.
- Modify: `PhoneShell.swift` / `ConversationFrame.swift` where the phone frame is built, so the tabs show above the conversation.
- Test: `App/AISessionRemoteTests/ConversationSwitcherTests.swift` (pure logic, extracted as `ConversationSwitcherModel`):
  - which conversations get segments (non-closed only);
  - the label format;
  - the note text for 1 and 3 closed;
  - grid columns for 2/3/4/10;
  - `displayed` preferring the main conversation.

- [ ] **Step 1:** Write the failing tests.
- [ ] **Step 2:** Run them. Expected: FAIL.
- [ ] **Step 3:** Implement. Continue on a busy conversation asks first, reusing the busy-close confirmation.
- [ ] **Step 4:** Run the tests and the Mac/iOS builds. Expected: pass, both build.
- [ ] **Step 5:** Commit `feat(app): one todo, several conversations: switcher, side by side, continue with this, reopen`.

### Task 7: End-to-end check and hand-over

- [ ] Run a local hub on a temp DB and the scripts from the worktree with a fake claude, as in the stage 0 check. Add an agent with Summary from a dirty source worktree. Confirm:
  - the new worktree holds the source's uncommitted file;
  - the fake claude got the summary as its last argument;
  - continue closes the source;
  - reopen brings it back.
- [ ] Report. Installing waits for the user's go, in the order hosts → hub → apps.
