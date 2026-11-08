# Competing agents, stage 2: Research Now with agents — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Research Now asks which agents to use (1–10 rows of tool + model, on a chosen computer). One run starts per agent, all from one base commit and each in its own worktree. Each saves its own findings on the idea, and all of them show as one todo with the stage 1 switcher.

**Architecture:**
1. **Hub (schema v34).** A new `run_groups` row ties together an idea, its one todo, the chosen computer, the shared base sha and the chosen run. Each attempt is a `job_runs` row carrying `group_id`, `attempt_tool` and `attempt_model`. Per-attempt findings live in `idea_findings`, keyed by run. `ideas.findings` stays, as the "chosen, else first" copy, so older apps, the weekly recap and scheduled research keep working.
2. **Runner.** It handles a group run like a scheduled run, with four differences:
   - the job's tool comes from the attempt (the hub rewrites it in the due answer);
   - the runner proposes a base sha on claim, the first claim wins, and every run then gets `create(..., base=<sha>)`;
   - the conversation goes into the group's todo;
   - Codex reports its session by conversation id.
   Runners report their installed tools the way they report watchers.
3. **Attempt identity.** Attempts are told apart by their worktree folder, `<trees>/<project>/<run id>`. `ai-todo-idea findings` sends that run id as `attempt`, so every attempt's prompt is byte-identical.
4. **App.** A `ResearchAgentsSheet` opens from Research Now in `IdeaDetailPane`, which the Mac and iPhone share. Its rules live in `AISessionCore/Board/ResearchAgents.swift`. The idea page lists findings per attempt. The stage 1 switcher also shows failed attempts, with Retry.

**Tech Stack:** Rust (actix-web, rusqlite) in `todo-app/crates`; Python 3 / POSIX sh in `ai-session-remote/scripts/todo`; Swift (AISessionCore, SwiftUI app for macOS and iOS).

**Spec:** `docs/superpowers/specs/2026-11-06-competing-agents-design.md`, section "Stage 2" (read the whole spec). Stage 1 is on main 46b8435: `add_agent_db`, `continue_with_db`, `ConversationSwitcherModel`, `AddAgentSheet`.

## Global Constraints

- **Agents:** 1 to 10 attempts per Research Now. An 11th, or an empty list, gets 400 "Choose 1 to 10 agents". The same tool may appear more than once.
- **Defaults:** the sheet opens with **Claude** and **Codex**, both at their default models, each kept only if installed on the chosen computer. There is no "auto" choice.
- **Computer:** defaults to the project's usual one (`store.sectionComputers[project.section]?.computer ?? project.computer`). The group's runs are pinned to it. Tools offered = that computer's reported tools. When it has reported none (`tools == nil`), all of claude/codex/cursor are offered, with a note.
- **Scheduled research is unchanged:** one Claude run, no sheet, no group. `POST /api/ideas/{id}/research` with no body (older app) makes a group of one Claude attempt on the default computer.
- **Same prompt:** every attempt's research text is the same `RESEARCH_PROMPT` render. Only the preamble's `{folder}` differs, because it names the attempt's own worktree.
- **Researched:** the idea becomes `researched` when the first attempt saves findings, and stays researched.
- **Base:** one sha per group, resolved on this computer when the group's first run is claimed: a best-effort `git fetch --quiet origin` (30 s timeout), then `origin/HEAD`, else `HEAD`.
- **Usage guard:** the runner's guard runs per attempt, for that attempt's tool. Research Now's limit is `always`, so in practice it never waits.
- **Model names:** `[A-Za-z0-9._\-\[\]]{1,80}`, so `opus[1m]` is accepted (fixes a stage 1 open item). The same rule applies in hub validation, the runner's argv filter and the Swift sheet.
- **Schema:** v34 (main is at v33 on 2026-11-08). Re-check `SCHEMA_VERSION` on `origin/main` before committing Task 1, and take the next free number.
- **Copy:** plain words, short sentences.
- **Commits:** end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **More attempts than one tick starts (`MAX_STARTS = 3`).** With 5 agents, two start a minute later. Expected: they use the same base sha, join the same todo, and still start after the idea is already `researched`. Test: `group_runs_started_after_findings_still_start` (Task 2).
2. **Every attempt fails.** Expected: the idea goes back to `new` so Research Now works again, and the group's todo is deleted when it has no conversations. One failed attempt among others leaves the idea `researching`. Tests in Task 2.
3. **An attempt fails after its conversation row exists** (`ai-todo-open` exits non-zero). Expected: the hub closes that conversation, so it isn't left as a dead tab, and the switcher shows the attempt as failed with Retry. Test: `failed_group_run_closes_its_conversation` (Task 2).
4. **A newer app talks to an older hub.** The old hub ignores the body and starts one Claude run. Expected: the app says "This hub started Claude only. Update the hub to research with several agents." Test: `testLegacyResearchAnswerIsReported` (Task 5).
5. **Findings saved from a folder that isn't an attempt:** a stage 0 conversation worktree, a scheduled run, or an old helper with no `attempt`. Expected: today's behaviour (`ideas.findings`, researched), with no error. Test: `findings_with_unknown_attempt_saves_on_idea` (Task 1).

---

### Task 1: Hub schema v34, research groups, per-attempt findings

**Files:**
- Modify: `todo-app/crates/todo-server/src/db.rs`: migration step to v34:
  - `CREATE TABLE run_groups (id TEXT PRIMARY KEY, idea_id TEXT REFERENCES ideas(id) ON DELETE SET NULL, todo_id TEXT, computer_id TEXT, base_sha TEXT, chosen_run_id TEXT, created_at TEXT NOT NULL DEFAULT (datetime('now')))`;
  - `job_runs` gains `group_id`, `attempt_tool`, `attempt_model`, `conversation_id` and `retry_of`;
  - `ideas` gains `group_id`;
  - `CREATE TABLE idea_findings (run_id TEXT PRIMARY KEY REFERENCES job_runs(id) ON DELETE CASCADE, idea_id TEXT NOT NULL REFERENCES ideas(id) ON DELETE CASCADE, findings TEXT NOT NULL, created_at TEXT NOT NULL DEFAULT (datetime('now')), updated_at TEXT NOT NULL DEFAULT (datetime('now')))`;
  - `computers` gains `tools` (JSON) and `tools_at`;
  - fresh-schema DDL updated to match.
- Modify: `todo-app/crates/todo-shared/src/lib.rs`:
  - `JobRun` gains `group_id`, `attempt_tool` and `attempt_model`, all `Option<String>` with `#[serde(default, skip_serializing_if = "Option::is_none")]`;
  - `Idea` gains `attempts: Vec<IdeaAttempt>` (`#[serde(default)]`);
  - new `IdeaAttempt { run_id, tool, model: Option<String>, state, result: Option<String>, conversation_id: Option<String>, findings: Option<String>, chosen: bool }`;
  - `Computer` gains `tools: Option<Vec<String>>`;
  - new `ResearchRequest { computer_id: Option<String>, attempts: Vec<AttemptSpec> }`, where `AttemptSpec { tool: String, model: Option<String> }`;
  - new `ResearchStart { group_id, todo_id, runs: Vec<JobRun> }`.
  - `UpdateIdeaRequest` gains `attempt: Option<String>`.
- Modify: `todo-app/crates/todo-server/src/jobs.rs`: `load_run` selects the new columns.
- Modify: `todo-app/crates/todo-server/src/ideas.rs`: `research_now_db(conn, id, req: &ResearchRequest)`, `update_idea_db` attempt branch, `attach_attempts`, and the `research_idea` handler takes `Option<web::Json<ResearchRequest>>`.
- Modify: `todo-app/crates/todo-server/src/conversations.rs`: `pub(crate) fn valid_model(m: &str) -> bool`, shared by add agent and research (allows `[` and `]`).

**Interfaces:**
- Produces:
  - `research_now_db(&Connection, &str, &ResearchRequest) -> Result<ResearchStart, IdeaError>`.
  - It creates the todo with `insert_scheduled_todo(..., job_id, first_run_id)`, titled `Research: <idea title>`.
  - It mutes pushes when the job is background priority.
  - It sets `ideas.status='researching', group_id, run_id=<first run>, todo_id=<group todo>`.
  - `IdeaAttempt` lists exclude runs that a retry replaced (`EXISTS run WHERE retry_of = id`), ordered by `created_at, rowid`.

- [ ] **Step 1: Write the failing tests** in `ideas.rs`:
  - `research_with_agents_makes_one_group_and_todo`: POST `{"computer_id":"mac","attempts":[{"tool":"claude"},{"tool":"codex","model":"gpt-6.1-terra"}]}` → 201. Assert:
    - `runs.len()==2`, sharing `group_id`;
    - `attempt_tool` is `["claude","codex"]`;
    - one new todo row, with `ideas.todo_id == todo_id`;
    - `run_groups.computer_id=="mac"`;
    - `GET /api/ideas` → `attempts.len()==2`, both `state=="due"`.
  - `research_without_body_is_one_claude_attempt`: no body → one run, `attempt_tool=="claude"`, `run_groups.computer_id` NULL.
  - `research_agent_count_and_model_validation`: 0 attempts → 400; 11 → 400; `"model":"a b"` → 400; `"model":"opus[1m]"` → 201; tool `"auto"` → 400; an unknown computer → 404.
  - `research_rejects_tool_not_installed`: `computers.tools='["claude"]'`, attempt codex → 400 "Codex isn't installed on Mac". `tools` NULL → accepted.
  - `findings_per_attempt`:
    - PATCH `{"findings":"A","attempt":<run1>}` → `idea_findings` has run1, idea `researched`, `ideas.findings=="A"`;
    - then PATCH `{"findings":"B","attempt":<run2>}` → `ideas.findings` still "A";
    - attempts show "A" and "B".
  - `findings_with_unknown_attempt_saves_on_idea`: `attempt` = an unrelated id → saved on `ideas.findings` as today, no `idea_findings` row.
  - db.rs: `v33_migrates_to_v34` (new columns and tables exist; existing runs and ideas are untouched).
- [ ] **Step 2:** Run `cd todo-app && PATH=$HOME/.cargo/bin:$PATH cargo test -p todo-server ideas db::`. Expected: FAIL (no such fields).
- [ ] **Step 3: Implement** the migration, the types, `research_now_db`, the attempt branch of `update_idea_db` (upsert by `run_id` when the run's `group_id == idea.group_id`, else today's path), and `attach_attempts` in `list_ideas_db`/`load_idea` (one query per call, not per idea). The rule for `ideas.findings` is: set to the chosen run's findings once the group has `chosen_run_id`; otherwise to the first saved findings.
- [ ] **Step 4:** Run `cargo test` (all). Expected: PASS, including stage 1's add-agent tests with the shared `valid_model`.
- [ ] **Step 5:** Commit `feat(hub): research groups, per-attempt findings (schema v34)`.

### Task 2: Hub runner API for group runs, Retry, Continue marks chosen

**Files:**
- Modify: `todo-app/crates/todo-server/src/runner_api.rs`.
- Modify: `todo-app/crates/todo-server/src/conversations.rs` (`continue_with_db`).
- Modify: `todo-app/crates/todo-server/src/main.rs`: routes `POST /api/runs/{id}/retry` and `PUT /api/computers/{id}/tools`.
- Modify: `todo-app/crates/todo-server/src/watch.rs`: a `put_tools` beside `put_watchers`.

**Interfaces:**
- Produces:
  - `DueRun` gains `group: Option<DueGroup { id: String, base_sha: Option<String> }>`.
  - For a group run, `due_db` and `claim_in` set `job.action`'s `tool` to `attempt_tool`.
  - `ClaimRequest` gains `base_sha: Option<String>` (7–40 hex). `claim_in` does `UPDATE run_groups SET base_sha = COALESCE(base_sha, ?)` and answers the stored value.
  - `StartRequest` is unchanged.
  - `StartResponse` gains `conversation_id: String` and `base_sha: Option<String>`.
  - `retry_run_db(&Connection, run_id) -> Result<JobRun, RunError>`.
  - `PUT /api/computers/{id}/tools` with body `["claude","codex"]` takes only claude/codex/cursor; anything else → 400.

- [ ] **Step 1: Write the failing tests** in `runner_api.rs`:
  - `due_lists_all_group_runs_on_group_computer`: 3 attempts of one job, group computer `spread` → `due?computer_id=spread` lists all 3. The one-run-per-job gate and `previous_still_working` don't apply. `mac` lists none, even though the section's computer is mac. The codex attempt's `job.action.tool=="codex"`.
  - `first_claim_sets_group_base`: claim run1 with `base_sha:"aaaaaaa"` → its `group.base_sha=="aaaaaaa"`. Claim run2 with `"bbbbbbb"` → it answers `"aaaaaaa"`.
  - `group_run_start_joins_group_todo`:
    - start run1 and run2 → both conversations are in the group todo, with labels `Claude` and `Codex · gpt-6.1-terra`;
    - `conversations.model` and `worktree_base` are set;
    - `job_runs.conversation_id` and `todo_id` are set;
    - both answers' `prompt` contain the same `RESEARCH_PROMPT` text, and that text includes no run id;
    - the codex answer's `model=="gpt-6.1-terra"`.
  - `group_runs_started_after_findings_still_start`: after findings from run1, start run3 → 200.
  - `failed_group_run_closes_its_conversation`: run2 started, then finish `failed` → its conversation `status=='closed'`, and the idea stays `researching`.
  - `all_failed_group_resets_idea_and_drops_empty_todo`: both runs fail before start → idea `new`, `group_id` NULL, and the todo is deleted.
  - `retry_makes_a_new_run_in_group`:
    - retry of failed run2 → a new due run with the same group, tool, model and note, and `retry_of = run2`;
    - the attempts list shows the new run instead of run2;
    - a retry of a non-failed run → 409, and a second retry of run2 → 409.
  - `continue_marks_chosen_findings` (in `conversations.rs`): continue on run2's conversation → `run_groups.chosen_run_id == run2`, `ideas.findings ==` run2's, and attempts show `chosen` on run2 only.
  - `continue_closed_conversation_conflicts`: continue on a `closed` conversation → 409 (stage 1 open item).
  - `put_tools_round_trip`: PUT `["claude","codex"]` → `GET /api/computers` shows `tools`. `["vim"]` → 400.
- [ ] **Step 2:** Run `cargo test -p todo-server runner_api conversations`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - `fn apply_attempt(job: &mut Job, run: &JobRun)` sets the action's tool from the attempt. It is used in `due_db`, `claim_in` and `start_db`.
  - `due_db` handles a group run before the per-job gates. The group's computer comes from `run_groups.computer_id`, else `resolved_computer`.
  - `start_db` for a group run:
    - finds its idea by `ideas.group_id`, accepting status `researching` or `researched`;
    - uses `run_groups.todo_id`;
    - inserts the conversation via `insert_conversation`, with label = `ConversationSwitcherModel.label` style (`Codex · <model>`), then sets `model` and `worktree_base`;
    - returns that conversation's tmux name and session.
    - Model precedence: `attempt_model`, else the action's.
  - `finish_db` failed: close the run's conversation if it has one. When no run of the group is left in due/waiting/running/done and none has findings, reset the idea and delete the group todo if it has no conversations.
  - `continue_with_db`: return 409 when the conversation is `closed`. Set `chosen_run_id` when the conversation belongs to a group run.
- [ ] **Step 4:** Run `cargo test` (all). Expected: PASS.
- [ ] **Step 5:** Commit `feat(hub): group research runs share a computer, base and todo; retry; chosen findings`.

### Task 3: Runner — group runs, shared base, tools report

**Files:**
- Modify: `ai-session-remote/scripts/todo/ai-todo-runner`.
- Modify: `ai-session-remote/scripts/todo/ai_todo_workspace.py`: `resolve_base(folder) -> str` (best-effort fetch with a 30 s timeout, then `origin/HEAD`, else `HEAD`; returns the full sha).
- Modify: `ai-session-remote/scripts/todo/ai-todo-idea`: `cmd_findings` sends `attempt`.
- Modify: `ai-session-remote/scripts/todo/ai-todo-open`: Cursor takes `--prompt-file` (see Step 3).
- Test: `ai-session-remote/scripts/todo/test-todo-scripts.sh`, runner and idea sections (fake hub).

**Interfaces:**
- Consumes: Task 2's `DueRun.group`, `ClaimRequest.base_sha`, `StartResponse.conversation_id`/`base_sha`, and `PUT /api/computers/{id}/tools`.
- Produces:
  - `make_worktree(folder, project_id, run_id, job_name, base=None)`.
  - `tools_report() -> list[str]`: `claude` if `AI_TODO_CLAUDE_BIN` or `shutil.which("claude")`; `codex` likewise; `cursor` if `AI_TODO_AGENT_BIN` or `which("agent")`.
  - `report_tools(hub, computer_id)` follows the `report_watchers` pattern, with state file `tools.json`.

- [ ] **Step 1: Write the failing shell tests:**
  - `runner_group_run_proposes_base_and_uses_it`: the fake due answer has a run with `group: {id, base_sha: null}`. Assert:
    - the claim body has `base_sha` equal to the fixture repo's `origin/HEAD` sha;
    - the worktree's HEAD equals that sha.
    - A second run whose claim answers `group.base_sha = <older commit>` gets a worktree at that older commit.
  - `runner_group_session_reported_by_conversation`: a codex start answer with `conversation_id: c1` and `created <id>` from fake open → PUT `/api/conversations/c1/session`, not the todo route.
  - `runner_reports_installed_tools`: with fake `claude` and `codex` on PATH → PUT `/api/computers/<id>/tools` with `["claude","codex"]`. Not re-sent next tick. A 404 is retried a day later.
  - `runner_model_with_brackets_passed`: start answer `model: "opus[1m]"` → the fake open argv has `--model opus[1m]`.
  - `idea_findings_sends_attempt_from_worktree`: run from `~/.ai-remote/worktrees/proj/run-123/sub` → body `attempt == "run-123"`. From the project folder → no `attempt`.
  - `open_cursor_takes_prompt_file`: a fake `agent` records its argv. A new cursor session with `--prompt-file F` → the last argument is F's text, and F is removed.
- [ ] **Step 2:** Run `scripts/todo/test-todo-scripts.sh`. Expected: those tests FAIL.
- [ ] **Step 3: Implement.**
  - In `cmd_tick`, for a run with `group` and no `base_sha`, call `workspace.resolve_base(project folder)` before the claim and send it. Read `group.base_sha` from the claim answer and pass it as `base` to `make_worktree` → `workspace.create(..., base)`.
  - Use `conversation_id` for the session report when it is present.
  - Widen the model regex to `[A-Za-z0-9._\[\]-]+`.
  - Cursor: set `with_first_prompt=1` on a new cursor session, as the claude/codex branches do. First check by hand on this Mac that `agent "<text>"` starts interactively with that message. If it doesn't, leave `ai-todo-open` alone, record the ruling, and have Task 5's sheet offer Cursor nowhere.
- [ ] **Step 4:** Run `scripts/todo/test-todo-scripts.sh` (all; rerun the known flaky timing checks if they fail). Expected: PASS.
- [ ] **Step 5:** Commit `feat(host): runner starts research groups from one base; reports installed tools; findings name their attempt`.

### Task 4: Swift client and models

**Files:**
- Modify: `ai-session-remote/Sources/AISessionCore/TodoHub/IdeaModels.swift`: `IdeaAttempt` and `Idea.attempts` (`decodeIfPresent`, default `[]`), plus `ResearchRequest`, `AttemptSpec` and `ResearchStart`.
- Modify: `ai-session-remote/Sources/AISessionCore/TodoHub/TodoHubModels.swift`: `Computer.tools: [String]?` and `JobRun.groupId`.
- Modify: `ai-session-remote/Sources/AISessionCore/TodoHub/TodoHubClient.swift`:
  - `researchIdea(id:request:) async throws -> ResearchOutcome`, where `enum ResearchOutcome { case group(ResearchStart), legacy(JobRun) }`. It decodes `ResearchStart` and falls back to `JobRun`.
  - `retryRun(id:) async throws -> JobRun`.
- Test: `ai-session-remote/Tests/AISessionCoreTests/TodoHubClientTests.swift` (or the ideas client test file next to it).

- [ ] **Step 1: Write the failing tests:**
  - `testResearchSendsAttemptsAndDecodesGroup`: the request body is `{"computer_id":"mac","attempts":[{"tool":"claude"},{"tool":"codex","model":"m"}]}`, with no `model` key when it's nil. The response decodes to `.group`.
  - `testResearchDecodesLegacyRun`: an old hub's `JobRun` → `.legacy`.
  - `testIdeaDecodesAttemptsAndOldIdea`: with and without `attempts`.
  - `testComputerToolsOptional`.
- [ ] **Step 2:** Run `cd ai-session-remote && swift test --filter TodoHubClient`. Expected: FAIL.
- [ ] **Step 3: Implement**, following the existing `CodingKeys`/`decodeIfPresent` style in these files.
- [ ] **Step 4:** Run `swift test`. Expected: PASS.
- [ ] **Step 5:** Commit `feat(core): research with agents in the hub client`.

### Task 5: Research agents sheet, findings per attempt, failed attempts in the switcher

**Files:**
- Create: `ai-session-remote/Sources/AISessionCore/Board/ResearchAgents.swift`. Its rules:

  ```swift
  public struct ResearchAgentRow: Equatable, Identifiable { public var id: UUID; public var tool: String; public var model: String }
  public enum ResearchAgents {
      static let maxAgents = 10
      static func offeredTools(installed: [String]?, cursorSupported: Bool) -> [String]
      static func defaults(offered: [String]) -> [ResearchAgentRow]
      static func canAdd(_ rows: [ResearchAgentRow]) -> Bool
      static func canRemove(_ rows: [ResearchAgentRow]) -> Bool
      static func isValidModel(_ model: String) -> Bool
      static func countText(_ n: Int) -> String
      static func request(rows: [ResearchAgentRow], computerId: String) -> ResearchRequest
      static func legacyWarning(_ outcome: ResearchOutcome, rows: [ResearchAgentRow]) -> String?
  }
  ```

- Modify: `ai-session-remote/Sources/AISessionCore/Board/ConversationSwitcherModel.swift`: `failedAttempts(idea: Idea?, conversations: [Conversation]) -> [IdeaAttempt]`. It returns attempts in state `failed` that have no open conversation.
- Create: `ai-session-remote/App/AISessionRemote/Views/Automation/ResearchAgentsSheet.swift`:
  - a Form with a Computer picker;
  - rows of a tool `Picker` plus a model `TextField` (placeholder "Default"), each with a remove button;
  - an "Add Agent" button, disabled at 10;
  - a footer with `countText`;
  - Cancel and Start buttons.
- Modify: `ai-session-remote/App/AISessionRemote/Views/Automation/IdeasPanes.swift` (`IdeaDetailPane`, shared by Mac and iPhone):
  - Research Now opens the sheet;
  - the Findings section becomes one section per attempt when `idea.attempts` is non-empty, headed `Claude · default` / `Codex · gpt-6.1` with "Chosen" on the chosen one;
  - each attempt shows its findings, or "Working…" / "Waiting to start" / "Failed: <result>" plus Retry.
- Modify: `ai-session-remote/App/AISessionRemote/Services/TodoHubStore.swift`: `researchIdea(_:request:) async throws -> String?` (returns the legacy warning) and `retryRun(_:)`.
- Modify: the stage 1 switcher bar view (`ConversationSwitcherBar`, in `TodoConversationScreen.swift`):
  - one extra segment per failed attempt, reading `Codex · failed`;
  - selecting it shows the failure text and a Retry button instead of a terminal;
  - the idea is found with `store.allIdeas.first { $0.todoId == todo.id }`.
- Test: `ai-session-remote/Tests/AISessionCoreTests/ResearchAgentsTests.swift`, `ConversationSwitcherModelTests.swift`.

- [ ] **Step 1: Write the failing tests:**
  - `testDefaultsAreClaudeAndCodex`: offered `["claude","codex","cursor"]` → 2 rows, claude then codex, empty models. Offered `["claude"]` → 1 row.
  - `testOfferedTools`: `nil` → all three, minus cursor when `cursorSupported == false`. `["codex"]` → `["codex"]`.
  - `testRowLimits`: `canAdd` is false at 10; `canRemove` is false at 1.
  - `testModelValidation`: `"opus[1m]"` and `""` valid; `"a b"` and `"x;y"` invalid.
  - `testCountText`: 1 → "Starts 1 conversation."; 3 → "Starts 3 conversations."
  - `testRequestOmitsEmptyModel`.
  - `testLegacyResearchAnswerIsReported`:
    - `.legacy` with rows `[claude]` → nil;
    - `.legacy` with 2 rows → "This hub started Claude only. Update the hub to research with several agents.";
    - `.group` → nil.
  - `testFailedAttemptsWithoutOpenConversation`: a failed attempt whose conversation is closed is listed. A done one isn't. A failed one replaced by a retry isn't present, because the hub drops it.
- [ ] **Step 2:** Run `swift test --filter "ResearchAgents|ConversationSwitcherModel"`. Expected: FAIL.
- [ ] **Step 3: Implement** the core rules, then the sheet, idea page, store and switcher segment. Cursor support is the value Task 3 recorded: a `static let cursorTakesPrompt` in `ResearchAgents`.
- [ ] **Step 4:** Run `swift test`. Then `xcodegen generate` and build both apps with `CODE_SIGNING_ALLOWED=NO` (Mac scheme and `generic/platform=iOS`). Then `xcodebuild test -scheme AISessionRemote` on "iPhone 17 Pro". Expected: all PASS and build.
- [ ] **Step 5:** Commit `feat(app): Research Now asks which agents; findings per attempt; failed attempts with Retry`.

### Task 6: End-to-end check and final review

- [ ] **Step 1:** Run all three suites from a clean tree: `cargo test`, `test-todo-scripts.sh`, `swift test`. Expected: PASS.
- [ ] **Step 2:** Rebase on `origin/main`, re-check the schema number, and rerun the suites.
- [ ] **Step 3:** One fresh review of the whole branch on the most capable model (`superpowers:requesting-code-review`). Fix what it confirms, and record rulings on the rest.
- [ ] **Step 4:** Stop. Installing (scripts on all three Macs, push → Pi, Mac app, iPhone) waits for the user's go, as the handover says. The first live try is a Claude + Codex Research Now on a real idea. Check:
  - both attempts get the same base sha (`git -C <wt> rev-parse HEAD`);
  - findings arrive per attempt;
  - Continue with This marks the chosen findings.
