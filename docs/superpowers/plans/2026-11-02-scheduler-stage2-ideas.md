# Scheduler Stage 2 (Ideas and Research) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:**
- Each project gets an ideas list. Ideas can be added in the app, shaped with an agent, or proposed by an agent (pending approval).
- A research job picks the next idea, researches it in a scheduled conversation, and saves the findings back on the idea.

**Architecture:**
- **Hub:** stores ideas and adds a `research` job action. When a research run starts, the hub picks the idea (starred first, else oldest new) inside the start transaction and builds the research prompt. Conversations are started by the existing runner, unchanged.
- **Agents:** they write ideas and findings through a new helper, `ai-todo-idea`.
- **"Shape an idea with an agent":** a one-off run of a per-project manual job, carrying the user's starting hint in a new run `note`.

**Tech Stack:** Rust (actix-web, rusqlite), Python in shell wrappers, SwiftUI.

**Spec:** `docs/superpowers/specs/2026-11-02-scheduler-design.md` (section 6, stage 2). This builds on stage 1 (`docs/superpowers/plans/2026-11-02-scheduler-stage1-core.md`, shipped).

## Global Constraints

- **Idea statuses:** `new`, `researching`, `researched`, `dropped`.
  - An idea also has `starred` (bool) and `pending` (bool; agent proposals, hidden from research until approved).
  - Title is 1–200 chars, notes up to 4,000, findings up to 20,000.
- **Research picks** the starred `new` non-pending idea of the job's project, else the oldest `new` non-pending one. If none exists when a slot comes due, the run is recorded as `skipped` with result `no new ideas`.
- **Research prompt** (after the stage 1 preamble; `{id}`, `{title}` and `{notes}` are the idea's), verbatim:
  ```
  Research this idea for the project {project}: "{title}".
  {notes}

  Investigate it (code, docs, the web if useful), then write findings: what you learned, options with trade-offs, and a recommended next step. Save them with:
  ~/.ai-remote/bin/ai-todo-idea findings {id} -
  (pipe the findings text on stdin). Then stop.
  ```
  followed by the job's own prompt, if non-empty, after a blank line.
- **Shape prompt** (no worktree preamble beyond stage 1's; `{note}` is the user's hint), verbatim:
  ```
  Help me shape a new idea for the project {project}. My starting point: {note}

  Ask me short questions, one at a time, until the idea is clear. Then save it with:
  ~/.ai-remote/bin/ai-todo-idea add "<title>" --notes "<two or three sentences>"
  and tell me it is saved.
  ```
- **Shape job** settings: one manual job per project named `Shape an idea · <project name>`, Claude, priority `urgent`, limit `always`, created on first use.
- **Redaction:** `ai-todo-idea` redacts title, notes and findings with `ai_todo_redact.py` before posting.
- **Git:** branch `feat/scheduler-ideas` from `main` in `~/programming/ai-session-memory`. Push to `main` only at rollout, hub first.

## Review Focus

1. **Two research runs (two research jobs on one project) starting together** must pick different ideas, never the same one. Test: `start_research_picks_distinct_ideas` (Task 3).
2. **An idea deleted or dropped while it's being researched:** `findings` for it gets 404 or still saves, with no crash. The run isn't affected. Test: `findings_on_dropped_idea_saves` (Task 2).
3. **A project with only pending (unapproved) ideas** never researches them. Test: `research_skips_pending_ideas` (Task 3).
4. **Findings or notes containing a secret** are redacted before leaving the Mac. Test: `idea_add_redacts_secret` (Task 4).
5. **An old app build or old helpers seeing a `research` job** don't break. The Swift decoder treats unknown action kinds as unsupported instead of failing the whole jobs list. Test: `testJobListSkipsUnknownActionKind` (Task 5).

---

### Task 1: Schema v14 and shared types

**Files:**
- Modify: `todo-app/crates/todo-server/src/db.rs` (`SCHEMA_VERSION` 14; `create_v14_objects` run every start; `version == 13` step; sniff: `ideas` table → 14)
- Modify: `todo-app/crates/todo-shared/src/lib.rs`

**Interfaces:**
- Produces:
  - **Table `ideas`:**
    - `id TEXT PK`
    - `project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE`
    - `title TEXT NOT NULL`
    - `notes TEXT NOT NULL DEFAULT ''`
    - `status TEXT NOT NULL DEFAULT 'new' CHECK(status IN ('new','researching','researched','dropped'))`
    - `starred INTEGER NOT NULL DEFAULT 0`
    - `pending INTEGER NOT NULL DEFAULT 0`
    - `findings TEXT`
    - `todo_id TEXT REFERENCES todos(id) ON DELETE SET NULL`
    - `run_id TEXT`
    - `source TEXT NOT NULL DEFAULT 'manual' CHECK(source IN ('manual','agent'))`
    - `created_at`, `updated_at`

    Index `(project_id, status)`.
  - **`job_runs.note TEXT`** (`ALTER` when missing).
  - **Shared types:**
    - `Idea { id, project_id, title, notes, status: String, starred: bool, pending: bool, findings: Option<String>, todo_id: Option<String>, run_id: Option<String>, source: String, created_at, updated_at }`
    - `CreateIdeaRequest { project_id, title, notes: Option<String>, pending: Option<bool>, source: Option<String> }`
    - `UpdateIdeaRequest { title, notes, status, starred, pending, findings }` (all `Option`)
    - `JobAction::Research { project_id, computer_id: Option<String>, tool, folder: Option<String>, prompt: String, priority, limit }`. Same fields as `Conversation`; `prompt` is extra instructions and may be empty.
    - `JobRun.note: Option<String>` (`#[serde(default)]`)
    - `JobAction::conversation_parts(&self) -> Option<ConversationParts<'_>>`, where `ConversationParts { project_id, computer_id, tool, folder, prompt, priority, limit }` is borrowed from either variant (`None` for push and todo)

- [ ] **Step 1:** Write the failing tests:
  - `migrates_v13_to_v14_adds_ideas` (a v13 database becomes 14 with `ideas` and `job_runs.note`; one backup)
  - `fresh_database_has_v14_objects`
  - `research_action_round_trips_json` (shared), with exactly this JSON:
    `{"kind":"research","project_id":"p","computer_id":null,"tool":"claude","folder":null,"prompt":"","priority":"background","limit":{"mode":"always"}}`
    and asserting that `conversation_parts()` returns `Some` for research and conversation, and `None` for push.
- [ ] **Step 2:** Run `cd todo-app && cargo test`. Expected: the new tests FAIL.
- [ ] **Step 3:** Implement. Every `match` on `JobAction::Conversation` in `jobs.rs` (validation), `runner_api.rs` (due, start) and `scheduler.rs` uses `conversation_parts()`, so research is accepted everywhere a conversation is. Research validation is the same except an empty prompt is allowed.
- [ ] **Step 4:** Run `cd todo-app && cargo test` and `cargo clippy -p todo-shared -p todo-server -- -D warnings`. Expected: PASS, no warnings.
- [ ] **Step 5:** Commit: `feat(server): ideas schema v14 and research job action`

### Task 2: Ideas API

**Files:**
- Create: `todo-app/crates/todo-server/src/ideas.rs`
- Modify: `todo-app/crates/todo-server/src/main.rs` (routes)

**Interfaces:**
- Produces:
  - `GET /api/ideas?project_id=&status=&pending=`: `pending` defaults to false (pending ideas are hidden unless asked for). Order: starred first, then status order new, researching, researched, dropped, then newest. Max 500.
  - `POST /api/ideas` returns 201 with the `Idea`. It returns 400 for an empty or too-long title, 404 for an unknown project, and 400 for a `source` that isn't `manual` or `agent`.
  - `PATCH /api/ideas/{id}`:
    - Validates `status` against the four values.
    - `pending: false` approves.
    - Setting `findings` (non-empty) also sets `status = 'researched'` unless `status` is in the same request.
  - `DELETE /api/ideas/{id}`
  - `POST /api/ideas/{id}/todo` creates a todo in the idea's project (section = the project's section, title = the idea title, no scheduled marker), sets `ideas.todo_id`, returns 201 with `{"idea": Idea, "todo_id": "..."}`, and leaves the status unchanged.
  - Every change broadcasts.
  - Also produces `pub(crate) fn load_idea(conn, id) -> rusqlite::Result<Option<Idea>>`.

- [ ] **Step 1:** Write the failing handler tests:
  - `create_and_list_ideas_order`
  - `create_idea_validation`
  - `list_hides_pending_by_default`
  - `patch_approves_and_stars`
  - `findings_sets_researched`
  - `findings_on_dropped_idea_saves` (status `dropped` + findings PATCH: the findings are saved and the status stays `dropped`, because `status` was given, then a second PATCH with only findings sets it to researched; this pins the rule)
  - `idea_to_todo_links`
  - `delete_idea`
  - `deleting_project_cascades_ideas`
- [ ] **Step 2:** Run `cd todo-app && cargo test -p todo-server ideas::`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `cd todo-app && cargo test`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(server): ideas API`

### Task 3: Research runs and "shape an idea"

**Files:**
- Modify: `todo-app/crates/todo-server/src/scheduler.rs` (research slots: skip when no idea is eligible)
- Modify: `todo-app/crates/todo-server/src/runner_api.rs` (`start_db`: research picks the idea; prompts render `{note}`)
- Modify: `todo-app/crates/todo-server/src/ideas.rs` (`POST /api/ideas/shape`)

**Interfaces:**
- Consumes: Tasks 1 and 2; stage 1's `render`, `insert_scheduled_todo` and preamble.
- Produces:
  - **`tick_db`:** for a research job's slot with no eligible idea (new, not pending, in the project), insert the run as `skipped`, result `no new ideas`, without superseding.
  - **`start_db` for research,** in the same IMMEDIATE transaction:
    - pick the idea (starred new first, else oldest new, non-pending)
    - if none, return 409 `No new ideas` (the runner reports the run failed)
    - set the idea to `status = 'researching'`, with its `run_id` and (after the todo is created) `todo_id`
    - the todo title is `Research: <idea title>`
    - the prompt is the stage 1 preamble + a blank line + the research prompt from Global Constraints (+ a blank line + the job's prompt when non-empty)
  - **`render`** gets `{note}` from `job_runs.note` (empty when null).
  - **`POST /api/ideas/shape`** with `{"project_id": "...", "hint": "..."}`:
    - finds or creates the project's shape job (Global Constraints), whose prompt is the Shape prompt
    - creates a `due` run with `note = hint` (1–1,000 chars)
    - returns 201 with the `JobRun`
    - returns 404 for an unknown project and 400 for an empty hint
- **Shape runs** are ordinary conversation runs: the runner starts them, and the user opens the todo to talk.

- [ ] **Step 1:** Write the failing tests:
  - `tick_skips_research_without_ideas`
  - `research_skips_pending_ideas`
  - `start_research_picks_starred_then_oldest` (the todo title, the idea status, links, and the prompt containing the idea id and the exact first line `Research this idea for the project app: "<title>".`)
  - `start_research_picks_distinct_ideas` (two research jobs on one project, both claimed and started one after the other, link two different ideas)
  - `start_research_without_ideas_conflicts`
  - `shape_creates_job_once_and_runs_with_note` (two shape calls give one job, two runs, and a prompt containing `My starting point: <hint>`)
  - `shape_validation`
- [ ] **Step 2:** Run `cd todo-app && cargo test -p todo-server`. Expected: the new tests FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `cargo test` and clippy as in Task 1. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(server): research runs pick ideas; shape an idea with an agent`

### Task 4: `ai-todo-idea` and the runner on research jobs

**Files:**
- Create: `ai-session-remote/scripts/todo/ai-todo-idea` (shell wrapper + Python, same layout as `ai-todo-runner`; `Config`/`Hub` copied)
- Modify: `ai-session-remote/scripts/todo/install.sh` (`HELPERS` += `ai-todo-idea`)
- Modify: `ai-session-remote/scripts/todo/fixtures/fake-hub.py` (`GET/POST /api/ideas`, `PATCH /api/ideas/<id>`, from `state["ideas"]`)
- Test: `ai-session-remote/scripts/todo/test-todo-scripts.sh` (new section `--- ai-todo-idea`)

**Interfaces:**
- Consumes: the Task 2 API.
- Produces:
  - `ai-todo-idea add "<title>" [--notes "<text>"] [--pending] [--cwd PATH]`:
    - The project is the deepest project of this computer (`TODO_COMPUTER_ID`) whose folder contains the cwd, from `GET /api/projects`. Worktrees under `~/.ai-remote/worktrees/<project id>/…` map to that project id.
    - It redacts, then posts with `source: "agent"`.
    - It prints `Idea saved.` (or `Idea saved for approval in the app.` with `--pending`).
    - Exit codes: 64 bad arguments, 65 no project or config, 1 hub error.
  - `ai-todo-idea list [--cwd PATH] [--status S]` prints `<id8> [status] title`.
  - `ai-todo-idea findings <id> <text|->`: `-` reads stdin. It redacts, cuts to 20,000 chars, PATCHes `findings`, and prints `Findings saved.`
  - **Runner:** no code change expected. It treats `research` like `conversation`, because it only reads `tool`, `limit`, `project_id` and `folder`. This is pinned by `runner_starts_research_run`.

- [ ] **Step 1:** Write the failing tests:
  - `idea_add_posts_agent_idea_for_cwd_project`
  - `idea_add_from_worktree_maps_project` (cwd `~/.ai-remote/worktrees/proj-app/run1/sub`)
  - `idea_add_pending`
  - `idea_add_redacts_secret`
  - `idea_add_outside_project_exits_65`
  - `idea_findings_from_stdin`
  - `idea_list_prints_ids`
  - `runner_starts_research_run` (a due run whose action kind is `research` goes through the claim, worktree, start and open path)
- [ ] **Step 2:** Run `ai-session-remote/scripts/todo/test-todo-scripts.sh`. Expected: the new tests FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run the script. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(scripts): ai-todo-idea for agents; runner runs research jobs`

### Task 5: App models and client

**Files:**
- Modify: `ai-session-remote/Sources/AISessionCore/TodoHub/JobModels.swift`:
  - `JobAction.research(ConversationJobAction)`
  - `JobAction.unsupported(kind: String)` for unknown kinds; encoding it throws
  - `JobRun.note: String?`
  - `ScheduledMarker.triggerSummary` unchanged
- Create: `ai-session-remote/Sources/AISessionCore/TodoHub/IdeaModels.swift` (`Idea`, `CreateIdeaRequest`, `UpdateIdeaRequest`, `ShapeIdeaRequest`)
- Modify: `TodoHubClient.swift`:
  - `listIdeas(projectId:pending:)`
  - `createIdea(_:)`
  - `updateIdea(id:_:)`
  - `deleteIdea(id:)`
  - `ideaToTodo(id:) -> String` (todo id)
  - `shapeIdea(projectId:hint:) -> JobRun`
- Test: `ai-session-remote/Tests/AISessionCoreTests/IdeasClientTests.swift` and additions to `JobsClientTests.swift`

- [ ] **Step 1:** Write the failing tests:
  - `testIdeaDecodes`
  - `testListIdeasQuery` (`project_id`, `pending=true`)
  - `testUpdateIdeaBody`
  - `testIdeaToTodoReturnsTodoId`
  - `testShapeIdeaBody`
  - `testJobDecodesResearchAction`
  - `testJobListSkipsUnknownActionKind` (a list with a `{"kind":"watcher",…}` action decodes; that job's action is `.unsupported("watcher")`)
- [ ] **Step 2:** Run `cd ai-session-remote && swift test --filter "IdeasClientTests|JobsClientTests"`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `swift test`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(app): idea models and client; research and unknown job kinds`

### Task 6: App screens

**Files:**
- Create: `ai-session-remote/App/AISessionRemote/Views/Projects/IdeaViews.swift`:
  - `IdeasSection` for the project page:
    - pending ideas with Approve/Reject
    - then ideas with a star, a status chip and a findings marker
    - "New Idea" (a sheet with title and notes)
    - "Shape an Idea with an Agent" (a sheet with a hint field; on send it shows "Started — it will appear in Needs you")
  - `IdeaDetailView`:
    - edit title and notes
    - star
    - status picker (new, dropped, and the others)
    - findings text (selectable)
    - "Turn into Todo", and "Open Research Todo" when `todoId` is set
    - Delete
- Modify: `ProjectDetailView.swift` (load ideas with the page; the Ideas section above Memories)
- Modify: `TodoHubStore.swift` (idea wrappers through `perform`; `ideas(projectId:)` and `pendingIdeas(projectId:)` loaders)
- Modify: `Views/Jobs/JobEditorView.swift` (action kind "Research ideas": the same fields as a conversation, with the prompt labelled "Extra instructions (optional)"; `.unsupported` jobs show a read-only note)
- Modify: `Views/Jobs/JobsView.swift` (the summary shows "Research in <project>"; an unsupported kind shows "Needs a newer app")

- [ ] **Step 1:** Write a failing test for any pure logic added (status labels: `testIdeaStatusLabel` in `IdeasClientTests`).
- [ ] **Step 2:** Run `swift test --filter testIdeaStatusLabel`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `swift test`, then `xcodegen generate`, then build both apps with `CODE_SIGNING_ALLOWED=NO`. Expected: PASS, and both builds exit 0.
- [ ] **Step 5:** Commit: `feat(app): ideas on the project page, shaping with an agent, research jobs in the editor`

### Task 7: Roll out and try it

- [ ] **Step 1:** Whole-branch review and fixes. Check `origin/main` and merge if it moved (regenerate the Xcode project on conflict). Run clippy with the CI command. Push, wait for "Deploy Pi", and check `GET /api/ideas` answers.
- [ ] **Step 2:** Install the helpers on all three Macs.
- [ ] **Step 3:** In project ai-session:
  - add an idea "Try Hermes as a third agent tool" by hand
  - create a manual Research job (Claude, background, wait)
  - Run now

  Expect the idea to go `researching`, then `researched` with findings within a few minutes, and the todo `Research: …` to reach Ready for review.
- [ ] **Step 4:** Shape an idea: call `POST /api/ideas/shape` with a hint. Expect a conversation in Needs you that asks a question. Answer one question in tmux, and expect it to save an idea through `ai-todo-idea`.
- [ ] **Step 5:** Rebuild the Mac app and the iPhone app (if reachable). Leave the research job disabled.
